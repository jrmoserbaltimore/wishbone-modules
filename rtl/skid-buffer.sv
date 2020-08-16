// vim: sw=4 ts=4 et
// Wishbone skid buffer
//
// Based on https://zipcpu.com/blog/2019/05/22/skidbuffer.html
// 
// This skid buffer only provides registered input, not registered output.
//
// License: MIT
//
// Note skid buffers are only sensible with pipelined mode.  In Registered Feedback classic mode,
// the skid buffer only supports pipelined handshake.

module WishboneSkidBuffer
#(
    parameter AddressWidth = 16,
    parameter DataWidth = 8, // bits, 8, 16, 32, or 64
    parameter Granularity = 8, // bits, 8, 16, 32, or 64
    parameter TGDWidth = 1, // Tag data width
    parameter TGAWidth = 1,
    parameter TGCWidth = 1,
    parameter BufferSize = 1, // If bigger than 1
    parameter LOWPOWER = 1, // Reduces register transitions
    //parameter RegisteredFeedback = 0,
    parameter STRICT = 0, // If set, the bus doesn't clean up after invalid inputs
    localparam SELWidth = DataWidth / Granularity
)
(
    // Common from SYSCON
    input logic CLK_I,
    input logic RST_I,

    // Connection to Initiator, i.e. skid buffer is the target
    // e.g. I[nitiator]_DAT_I[nput]
    input logic [DataWidth-1:0] I_DAT_I,
    output logic [DataWidth-1:0] I_DAT_O,
    input logic [TGDWidth-1:0] I_TGD_I,
    output logic [TGDWidth-1:0] I_TGD_O,

    output logic ACK_O,
    input logic [AddressWidth-1:0] ADDR_I,
    input logic CYC_I,
    output logic STALL_O,
    output logic ERR_O,
    input logic LOCK_I,
    output logic RTY_O,
    input logic [SELWidth-1:0] SEL_I,
    input logic STB_I,
    input logic [TGAWidth-1:0] TGA_I,
    input logic [TGCWidth-1:0] TGC_I,
    input logic WE_I,
    // Registered Feedback
    input logic [2:0] CTI_I,
    input logic [1:0] BTE_I,
    
    // Connection to Target, i.e. skid buffer is the initiator
    input logic [DataWidth-1:0] T_DAT_I,
    output logic [DataWidth-1:0] T_DAT_O,
    input logic [TGDWidth-1:0] T_TGD_I,
    output logic [TGDWidth-1:0] T_TGD_O,
    
    input logic ACK_I,
    output logic [AddressWidth-1:0] ADDR_O,
    output logic CYC_O,
    input logic STALL_I,
    input logic ERR_I,
    output logic LOCK_O,
    input logic RTY_I,
    output logic [SELWidth-1:0] SEL_O,
    output logic STB_O,
    output logic [TGAWidth-1:0] TGA_O,
    output logic [TGCWidth-1:0] TGC_O,
    output logic WE_O,
    // Registered Feedback
    output logic [2:0] CTI_O,
    output logic [1:0] BTE_O
);

    // Only need to buffer initiator-to-target because only target may stall.
    // r_valid outputs to CYC_I and STB_I when forwarding the register
    logic r_valid;
    logic [DataWidth-1:0] r_dat;
    logic [TGDWidth-1:0] r_tgd;
    logic [AddressWidth-1:0] r_addr;
    logic r_lock;
    logic [SELWidth-1:0] r_sel;
    logic [TGAWidth-1:0] r_tga;
    logic [TGCWidth-1:0] r_tgc;
    logic r_we;
    logic [2:0] r_cti;
    logic [1:0] r_bte;

    logic i_valid, o_valid;
    assign i_valid = CYC_I & STB_I;
    assign o_valid = CYC_O & STB_O;

    // Only stall if buffer is full
    assign STALL_O = r_valid;
    // Always send target's output to initiator
    assign I_DAT_O = T_DAT_I;
    assign I_TGD_O = T_DAT_I;
    assign ACK_O = ACK_I;
    assign ERR_O = ERR_I;
    assign RTY_O = RTY_I;

    // XXX: CYC_I should be true whenever r_valid is true, so do I need to OR with r_valid?
    assign CYC_O = CYC_I | r_valid;
    assign STB_O = i_valid | r_valid;

    // assign the inputs or buffer to the outputs
    always_comb
    begin
        // Put the buffered data on the output bus
        if (r_valid)
        begin
            T_DAT_O = r_dat;
            T_TGD_O = r_tgd;
            ADDR_O = r_addr;
            LOCK_O = r_lock;
            SEL_O = r_sel;
            TGA_O = r_tga;
            TGC_O = r_tgc;
            WE_O = r_we;
            CTI_O = r_cti;
            BTE_O = r_bte;
        end else
        begin
            if (!LOWPOWER || i_valid)
            begin
                // If LOWPOWER, this checks i_valid; else there is no check and this always happens
                T_DAT_O = I_DAT_I;
                T_TGD_O = I_TGD_I;
                ADDR_O = ADDR_I;
                LOCK_O = LOCK_I;
                SEL_O = SEL_I;
                TGA_O = TGA_I;
                TGC_O = TGC_I;
                WE_O = WE_I;
                CTI_O = CTI_I;
                BTE_O = BTE_I;
            end else
            begin
                // if !LOWPOWER this logic gets trimmed because the above is always true.
                // if LOWPOWER, these become zero when not outputting a valid strobe.
                T_DAT_O = 0;
                T_TGD_O = 0;
                ADDR_O = 0;
                LOCK_O = 0;
                SEL_O = 0;
                TGA_O = 0;
                TGC_O = 0;
                WE_O = 0;
                CTI_O = 0;
                BTE_O = 0;
            end
        end
    end

    // Store the data each clock cycle if not stalling
    always_ff @(posedge CLK_I)
    if (!RST_I)
    begin
        // if LOWPOWER, these don't get set unless we have CYC&STB.  In all other conditions
        // when LOWPOWER, r_* |=> $last(r_*)  (or is it current r_*?)
        if ((!LOWPOWER || i_valid) && !r_valid)
        begin
            r_dat <= I_DAT_I;
            r_tgd <= I_TGD_I;
            r_addr <= ADDR_I;
            r_lock <= LOCK_I;
            r_sel <= SEL_I;
            r_tga <= TGA_I;
            r_tgc <= TGC_I;
            r_we <= WE_I;
            r_cti <= CTI_I;
            r_bte <= BTE_I;
        end
    end

    always_ff @(posedge CLK_I)
    begin
        // this satisfies all deassertions and clears the buffer 
        if (RST_I) r_valid <= '0;
        // Wishbone B4 rule 3.2.0 disallows CYC_O falling before STB_O.  Nothing is said about
        // dropping before receiving ACK_I, but it's implied that's invalid.   
        else if (CYC_I)
        begin
            // Stall hasn't propagated, but incoming data, so buffer
            if ((i_valid && !STALL_O) && (o_valid && STALL_I))
            begin
                r_valid <= '1;
            end else r_valid <= '0;
        end
        // Obviously didn't wait for a bus termination signal but terminated anyway.  If the buffer
        // is tolerant, clear the buffer; else this is trimmed and the bus may do broken things
        // like hold CYC_O and STB_O with unchanging data until CYC_I is again asserted.  Doing so
        // MIGHT damage hardware!
        else if (!STRICT) r_valid <= '0;
    end

`ifdef FORMAL
    // TODO:  Formal verification
`endif
endmodule