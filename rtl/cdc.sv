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

    // Initiator ? I_Request[0] ? I_Request[1] ? Target  [Reply: T_Acknowledge]
    //                    ?              ?           ?
    //                    ----------------------------S_Target.Clk
    //                   ?              ?                   ?
    // Initiator ? I_Acknowledge[0] ? I_Acknowledge[1] ? Target
    //
    // Initiator ? T_Request[1] ? T_Request[0] ? Target  [Reply: I_Acknowledge]
    //     ?               ?               ?
    // S_Initiator.Clk---------------------
    //    ?               ?               ?
    // Initiator ? T_Acknowledge[1] ? T_Acknowledge[0] ? Target
    logic [1:0] I_Request [BufSzBits-1:0];
    logic [1:0] I_Acknowledge [BufSzBits-1:0];
    logic [1:0] T_Request [BufSzBits-1:0];
    logic [1:0] T_Acknowledge [BufSzBits-1:0];

    // assign o_valid = CYC_O & STB_O; // ?
    
    // Buffer to which Initiator is writing
    logic [BufSzBits-1:0] I_BufferIndex;
    // Buffer to which Target is reading
    logic [BufSzBits-1:0] T_BufferIndex;
    // =====================================
    // == Initiator ? Target skid buffer ==
    // =====================================
    // Uses:  I_Request, T_Acknowledge. I_BufferIndex
    //
    // This skid buffer uses multiple CDCs and multiple buffers in a ring.  Each looks as such:
    //
    //  r_valid?ff?ff?   
    //     data?ff——?
    //      Ack?ff?ff?
    //
    // Both sides walk around in a ring.  The sender checks if (!r_valid && !Ack) on the current
    // entry and, if so, sets r_valid and data; upon receiving Ack, it resets r_valid.
    //
    // The receiver checks r_valid and, if set, takes the data and sends an Ack.  Upon r_valid
    // resetting, the receiver resets Ack UNLESS it is in a stall condition.

    logic i_valid;
    assign i_valid = Initiator.CYC & Initiator.STB;

    // r_valid outputs to CYC_I and STB_I when forwarding the register
    logic r_valid [BufSzBits-1:0];
    logic r_ack [BufSzBits-1:0];
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
    assign Initiator.STALL = Stall;

    // Handle the handshake sending from Initiator to Target:
    //  - Set and clear r_valid when appropriate
    //  - propagate T_Acknowledge
    generate
        genvar i;
        for (i=0; i < 2**BufferSize; i++)
        always @(posedge S_Initiator.CLK)
        begin
            // Ready to store a new input into the currently-selected buffer
            if (!Stall && i_valid && (i == I_BufferIndex))
            begin
                r_valid[i] <= '1;
            // If not ready and received an ACK, clear r_valid
            end else if (T_Acknowledge[i][1])
                r_valid[i] <= '0;
            // Propagate the ack
            T_Acknowledge[i][1] <= T_Acknowledge[i][0];
            T_Acknowledge[i][0] <= r_ack[i]; // XXX:  Have to ack when not stalled
        end
    endgenerate

    // Put the data on the buffer
    always @(posedge S_Initiator.CLK)
    begin
        // Store a new input into the buffer
        if (!Stall && i_valid)
        begin
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
        end
        I_BufferIndex <= I_BufferIndex + (!Stall && i_valid);
    end

    // Propagate I_Request to the Target
    generate
    for (i=0; i < 2**BufSzBits; i++)
        always @(posedge S_Target.CLK)
        begin
            I_Request[i][1] <= I_Request[i][0];
            I_Request[i][0] <= r_valid[i];
        end
    endgenerate
    // ================================
    // == Target ? Initiator buffer ==
    // ================================

    

endmodule