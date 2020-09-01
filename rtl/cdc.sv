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

    // Initiator -> I_Request[0] -> I_Request[1] -> Target  [Reply: T_Acknowledge]
    //                    ^                ^         ^
    //                    ----------------------------S_Target.Clk
    //                   v                v                   v
    // Initiator -> I_Acknowledge[0] -> I_Acknowledge[1] -> Target
    //
    // Initiator <- T_Request[1] <- T_Request[0] <- Target  [Reply: I_Acknowledge]
    //     ^               ^               ^
    // S_Initiator.Clk---------------------
    //    v               v               v
    // Initiator <- T_Acknowledge[1] <- T_Acknowledge[0] <- Target
    logic [1:0] I_Request [BufSzBits-1:0];
    logic [1:0] I_Acknowledge [BufSzBits-1:0];
    logic [1:0] T_Request [BufSzBits-1:0];
    logic [1:0] T_Acknowledge [BufSzBits-1:0];

    // assign o_valid = CYC_O & STB_O; // ?
    
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
    //      Ack>ff>ff>
    //
    // Both sides walk around in a ring.  The sender checks if (!r_valid && !Ack) on the current
    // entry and, if so, sets r_valid and data; upon receiving Ack, it resets r_valid.
    //
    // The receiver checks r_valid and, if set, takes the data and sends an Ack.  Upon r_valid
    // resetting, the receiver resets Ack UNLESS it is in a stall condition.

    // need to have the prior cycle's CYC to test for next cycle.
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

    // Stall whenever the current buffer is not acknowledged clear 
    wire Stall;
    assign Stall = r_valid[I_BufferIndex] | T_Acknowledge[1];
    // Stall until 
    assign Initiator.STALL = Stall | i_DroppedCYC;

    // Handle the handshake sending from Initiator to Target:
    //  - Set and clear r_valid when appropriate
    //  - propagate T_Acknowledge
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
        
        for (i = 0; i < 2**BufSzBits; i++)
        begin
            // Set up for request signal propagation
                            // if (r_v && T_A) r_v <= '0
            r_valid[i] <= !(r_valid[i] && T_Acknowledge[i][1])
                            // else if taking data into current buffer, r_v <= '1
                            // Also raise r_v when notifying CYC has negated
                        && (!Stall && (i_valid || i_DroppedCYC) && (i == I_BufferIndex));
            // Propagate the acknowledgement
            T_Acknowledge[i][1] <= T_Acknowledge[i][0];
            T_Acknowledge[i][0] <= r_ack[i]; // XXX:  Have to ack ONLY when Target not stalled
        end
    end

    // Propagate I_Request to the Target
    generate
    genvar i;
    for (i=0; i < 2**BufSzBits; i++)
        always @(posedge S_Target.CLK)
        begin
            I_Request[i][1] <= I_Request[i][0];
            I_Request[i][0] <= r_valid[i];
        end
    endgenerate
    
    // Receive data and pass to target, if not stalled
    always @(posedge S_Target.CLK)
    begin
        if (I_Request[T_BufferIndex][1] && !r_ack[T_BufferIndex])
        begin
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

            // Drop CYC if CYC is negated; else raise CYC and STB
            Target.CYC <= r_cyc;
            Target.STB <= r_cyc;            
            //ACK immediately
            r_ack[T_BufferIndex] <= '1;
        end else
        begin
            // De-assert ACK only after the request drops and we are NOT stalling
            r_ack[T_BufferIndex] <= !(Target.STALL || I_Request[T_BufferIndex][1]);
            // Advance on the tick we drop ACK
            T_BufferIndex <= T_BufferIndex + !(Target.STALL || I_Request[T_BufferIndex][1]);
            // Drop STB when dropping ACK
            Target.STB <= !(Target.STALL || I_Request[T_BufferIndex][1]);
        end        
    end
    // ================================
    // == Target -> Initiator buffer ==
    // ================================
    // Initiator receiving from Target
endmodule