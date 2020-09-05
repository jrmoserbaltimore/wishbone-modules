// vim: sw=4 ts=4 et
// Wishbone Clock Domain Crossing
//
// Based on https://zipcpu.com/blog/2017/10/20/cdc.html
// 
// License: MIT
//
// This is only applicable to pipeline mode.

module WishboneCDCSkidBuffer
#(
    parameter AddressWidth = 16,
    parameter DataWidth = 8, // bits, 8, 16, 32, or 64
    parameter Granularity = 8, // bits, 8, 16, 32, or 64
    parameter TGDWidth = 1, // Tag data width
    parameter TGAWidth = 1,
    parameter TGCWidth = 1,
    parameter BufferSize = 4, // For a slow Initiator to fast Target, 4 is a clear pipeline.
                              // For a fast Initiator
    parameter LOWPOWER = 1, // Reduces register transitions
    parameter STRICT = 0, // If set, the bus doesn't clean up after invalid inputs
    localparam SELWidth = DataWidth / Granularity
)
(
    // Common from SYSCON
    IWishbone.Syscon S_Initiator,
    IWishbone.Syscon S_Target,
    IWishbone.Target Initiator,
    IWishbone.Initiator Target
);
    // Buffer size is always at least 2
    localparam BufSzBits = $clog2(BufferSize);

    //                                      ---------------------> XOR -> STB 
    //                                      |                       ^
    // Initiator -> I_Request[0] -> I_Request[1] -> I_Request[2]----|
    //                                                              |
    //                        ---I_Ack[2] <- I_Ack[1] <- I_Ack[0] <-
    //                       v                 |
    //         REG<---ACK<--XOR<---------------

    logic [2:0] I_Request [BufSzBits-1:0];
    logic [2:0] I_Feedback [BufSzBits-1:0];

    // Pending ACKs, to ensure buffer space to hold all ACKs to be sent by Target
    logic [BufSzBits:0] T_Pending;
    wire T_Ready;
    
    // Buffer to which Initiator is writing
    logic [BufSzBits-1:0] I_BufferIndex;
    // Buffer from which Target is reading
    logic [BufSzBits-1:0] T_BufferIndex;
    // =====================================
    // == Initiator -> Target skid buffer ==
    // =====================================
    // Uses:  I_Request, T_Acknowledge. I_BufferIndex
    //
    // This skid buffer uses multiple CDCs and multiple buffers in a ring.  Each looks as such:
    //
    //  r_valid>ff>ff>
    //     data>ff——>
    //
    // Both sides walk around in a ring.  When the Target is pending as many acks as the CDC can
    // buffer, it withholds the strobe and the feedback signal, causing the Initiator to stall when
    // it reaches that entry in the buffer. 

    // CYC can't drop until after all ACKs are received; regardless, when CYC does drop, all
    // buffers are overwritten with CYC=0, and the CDC stalls until it can actually send a CYC=0
    // request.
    logic LastCYC;
    wire i_valid;
    wire i_DroppedCYC;
    logic r_DroppedCYC;
    assign i_valid = Initiator.CYC & Initiator.STB;
    assign i_DroppedCYC = (LastCYC & ~Initiator.CYC) | r_DroppedCYC;

    // r_valid indicates something has crossed
    logic r_valid [BufSzBits-1:0];
    logic r_ack [BufSzBits-1:0];
    // Need to actually propagate cyc; stb is implicit
    logic r_cyc [BufSzBits-1:0];
    logic [DataWidth-1:0] r_dat [BufSzBits-1:0];
    logic [TGDWidth-1:0] r_tgd [BufSzBits-1:0];
    logic [AddressWidth-1:0] r_addr [BufSzBits-1:0];
    logic r_lock [BufSzBits-1:0];
    logic [SELWidth-1:0] r_sel [BufSzBits-1:0];
    logic [TGAWidth-1:0] r_tga [BufSzBits-1:0];
    logic [TGCWidth-1:0] r_tgc [BufSzBits-1:0];
    logic r_we [BufSzBits-1:0];
    logic [2:0] r_cti [BufSzBits-1:0];
    logic [1:0] r_bte [BufSzBits-1:0];

    // Stall whenever waiting on feedback from current buffer
    wire Stall;
    assign Stall = !(I_Feedback[I_BufferIndex][1] ^ I_Feedback[I_BufferIndex][2]);
    // Stall until 
    assign Initiator.STALL = Stall | i_DroppedCYC;

    // Handle the handshake sending from Initiator to Target:
    //  - Set and clear r_valid when appropriate
    //  - propagate I_Feedback
    //  - Propagate Initiator.CYC negation
    always @(posedge S_Initiator.CLK)
    begin
        var i;
        // Store a new input into the buffer to make it available to the Target
        if (!Stall && i_valid && !i_DroppedCYC)
        begin
            r_cyc[I_BufferIndex] <= Initiator.CYC;
            r_dat[I_BufferIndex] <= Initiator.DAT_ToTarget;
            r_tgd[I_BufferIndex] <= Initiator.TGD_ToTarget;
            r_addr[I_BufferIndex] <= Initiator.ADDR;
            r_lock[I_BufferIndex] <= Initiator.LOCK;
            r_sel[I_BufferIndex] <= Initiator.SEL;
            r_tga[I_BufferIndex] <= Initiator.TGA;
            r_tgc[I_BufferIndex] <= Initiator.TGC;
            r_we[I_BufferIndex] <= Initiator.WE;
            r_cti[I_BufferIndex] <= Initiator.CTI;
            r_bte[I_BufferIndex] <= Initiator.BTE;
        end else if (i_DroppedCYC)
        begin
            // Zero r_cyc on all buffers regardless.  Metastability doesn't matter after abort, and
            // CYC only legally drops after receiving all ACKs, which requires sending the whole
            // buffer to the Target
            for (i = 0; i < 2**BufSzBits; i++)
                r_cyc[i] <= '0;
        end
        // Increment the buffer if we're not stalling.  Increments on the tick Stall resets when
        // we have waiting input OR a pending relay of a CYC negation.
        I_BufferIndex <= I_BufferIndex + (!Stall && (i_valid || i_DroppedCYC));
        // ignore CYC going high when stalling on a dropped CYC. No need to bounce on and off.
        LastCYC <= Initiator.CYC & ~i_DroppedCYC;
        // Register that we hit i_DroppedCYC if we're stalled.  This will continue to register
        // until the stall has passed (Initiator.STALL remains set as long as r_DroppedCYC does).
        // Once the stall passes, r_DroppedCYC resets, I_BufferIndex increments.
        //
        // Note if the next buffer is waiting on an ack or ack reset (not free), the i_DroppedCYC
        // maintains the Initiator.STALL this cycle, and Stall becomes true next cycle, so the
        // stall signal to the initiator doesn't deassert.
        r_DroppedCYC <= Stall && i_DroppedCYC;

        // If the current buffer is free and we have either a valid input or dropped CYC, so send
        r_valid[T_BufferIndex] <= (i_valid | i_DroppedCYC) ^ r_valid[T_BufferIndex];

        // Propagate feedback
        for (i = 0; i < 2**BufSzBits; i++)
        begin
            I_Feedback[i][2] <= I_Feedback[i][1];
            I_Feedback[i][1] <= I_Feedback[i][0];
            I_Feedback[i][0] <= I_Request[i][2];
        end
    end

    // Data is sitting on the current bus and we have room for the ACKs
    assign T_Ready = (I_Request[T_BufferIndex][1] ^ I_Request[T_BufferIndex][2])
                     && (T_Pending < 2**BufSzBits);
    // Propagate I_Request to the Target
    generate
    genvar i;
    for (i=0; i < 2**BufSzBits; i++)
        always @(posedge S_Target.CLK)
        begin
            // Stall the Initiator when:
            //   - We have as many outstanding ACKs as the buffer will hold; or
            //   - The current buffer is waiting to send due to Target.STALL 
            I_Request[i][2] <= (
                                (T_Ready && !Target.STALL)
                                && T_BufferIndex == i
                               )
                                ? I_Request[i][1]
                                : I_Request[i][2];
            // Advance these regardless, stalling at feedback
            I_Request[i][1] <= I_Request[i][0];
            I_Request[i][0] <= r_valid[i];
        end
    endgenerate

    logic [2:0] T_Request [BufSzBits-1:0];
    logic [2:0] T_Feedback [BufSzBits-1:0]; 
    // Receive data and pass to target, if not waiting on buffer space
    always @(posedge S_Target.CLK)
    begin
        var i,j;
        if (T_Ready)
        begin
            // Always put the data on the bus if valid.  This doesn't create a transition when
            // stalling
            Target.DAT_ToTarget <= r_dat[T_BufferIndex];
            Target.TGD_ToTarget <= r_tgd[T_BufferIndex];
            Target.ADDR <= r_addr[T_BufferIndex];
            Target.LOCK <= r_lock[T_BufferIndex];
            Target.SEL <= r_sel[T_BufferIndex];
            Target.TGA <= r_tga[T_BufferIndex];
            Target.TGC <= r_tgc[T_BufferIndex];
            Target.WE <= r_we[T_BufferIndex];
            Target.CTI <= r_cti[T_BufferIndex];
            Target.BTE <= r_bte[T_BufferIndex];

            // Raise and drop CYC only when instructed, hold otherwise
            Target.CYC <= r_cyc[T_BufferIndex];
        end
        // Strobe whenever data is ready and CYC is asserted
        Target.STB <= T_Ready && r_cyc[T_BufferIndex];
        // Increment T_Pending and T_BufferIndex each time we SEND data to the Target.
        // Decrement T_Pending each time we receive an ACK from the target and relay feedback.
        j = 0;
        for (i = 0; i < 2**BufSzBits; i++)
            j += T_Feedback[2] ^ T_Feedback[1];
        // If sending !CYC, there are no pending responses.
        T_Pending <= !r_cyc[T_BufferIndex]
                     ? '0
                     : T_Pending + (T_Ready && !Target.STALL) - j;
        T_BufferIndex <= T_BufferIndex + (T_Ready && !Target.STALL); 
    end
    // ================================
    // == Target -> Initiator buffer ==
    // ================================
    // Initiator receiving from Target

    // Buffer from which Initiator is reading
    logic [BufSzBits-1:0] I_TBufferIndex;
    // Buffer to which Target is writing
    logic [BufSzBits-1:0] T_TBufferIndex;

    // Buffer only collects what's coming from Target
    logic t_valid [BufferSize-1:0];
    logic [DataWidth-1:0] t_dat [BufferSize-1:0];
    logic [TGDWidth-1:0] t_tgd [BufferSize-1:0];
    logic t_ack [BufferSize-1:0];
    logic t_err [BufferSize-1:0];
    logic t_rty [BufferSize-1:0];
    
    wire ti_valid;
    wire I_Ready;
    assign ti_valid = Target.ACK | Target.ERR | Target.RTY;

    assign I_Ready = (T_Request[I_TBufferIndex][1] ^ T_Request[I_TBufferIndex][2]);

    wire [DataWidth-1:0] t_DAT;
    wire [TGDWidth-1:0] t_TGD;
    wire t_ACK, t_ERR, t_RTY;

    assign t_DAT = t_dat[I_TBufferIndex];
    assign t_TGD = t_tgd[I_TBufferIndex];
    // Block these until the request reaches the Initiator
    assign t_ACK = t_ack[I_TBufferIndex] & I_Ready;
    assign t_ERR = t_err[I_TBufferIndex] & I_Ready;
    assign t_RTY = t_rty[I_TBufferIndex] & I_Ready;
    
    // handles the handshake sending from target to initiator:
    //  - set and clear t_valid when appropriate
    //  - Propagate T_Feedback
    always @(posedge S_Target.CLK)
    begin
        var i;
        // Store a new input into the buffer to make it available to the Initiator
        // There is NO STALL CONDITION.  The Initiator stalls when the Target hasn't received
        // feedback on relaying an ACK after a full return buffer, and the Target shouldn't have
        // any responses pending until the buffer is not full.
        if (ti_valid)
        begin
            t_valid[T_TBufferIndex] <= ~t_valid[T_TBufferIndex];
            t_dat[T_TBufferIndex] <= Target.DAT_ToInitiator;
            t_tgd[T_TBufferIndex] <= Target.TGD_ToInitiator;
            t_ack[T_TBufferIndex] <= Target.ACK;
            t_err[T_TBufferIndex] <= Target.RTY;
            t_rty[T_TBufferIndex] <= Target.RTY;
        end
        // We sent something back, so increment the buffer index
        T_TBufferIndex <= T_TBufferIndex + ti_valid;
        t_valid[T_BufferIndex] <= ti_valid  ^ t_valid[T_BufferIndex];

        // Propagate feedback
        for (i = 0; i < 2**BufSzBits; i++)
        begin
            T_Feedback[i][2] <= T_Feedback[i][1];
            T_Feedback[i][1] <= T_Feedback[i][0];
            T_Feedback[i][0] <= T_Request[i][2];
        end
    end

    // Propagate T_Request to the Initiator
    generate
    for (i=0; i < 2**BufSzBits; i++)
        always @(posedge S_Initiator.CLK)
        begin
            T_Request[i][2] <= T_Request[i][1];
            T_Request[i][1] <= I_Request[i][0];
            T_Request[i][0] <= r_valid[i];
        end
    endgenerate
    
    // Receive data and pass to Initiator
    always @(posedge S_Initiator.CLK)
    begin
        var i,j;
        if (I_Ready)
        begin
            Initiator.DAT_ToInitiator <= t_DAT;
            Initiator.TGD_ToInitiator <= t_TGD;
        end
        // These remain 0 until I_Ready
        Initiator.ACK <= t_ACK;
        Initiator.ERR <= t_ERR;
        Initiator.RTY <= t_RTY;

        // Just sent data to the Initiator, next.
        I_TBufferIndex <= I_TBufferIndex + I_Ready; 
    end
endmodule
