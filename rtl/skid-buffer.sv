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
// the skid buffer only supports pipelined handshake; note that Registered Feedback must support
// Classic mode and RF adds several additional signals and complex logic to do everything Classic
// pipelined can do, so it's advisable to simply not attach CTI and BTE signals and let the
// synthesizer trim the logic to save logic area.

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
    parameter STRICT = 0, // If set, the bus doesn't clean up after invalid inputs
    localparam SELWidth = DataWidth / Granularity
)
(
    // Common from SYSCON between Initiator and Target
    IWishbone.Syscon Syscon,
    IWishbone.Target Initiator,
    IWishbone.Initiator Target
);

    // Only need to buffer initiator-to-target because only target may stall.
    // r_valid outputs to Initiator.CYC and Initiator.STB when forwarding the register
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
    assign i_valid = Initiator.CYC & Initiator.STB;
    assign o_valid = Target.CYC & Target.STB;

    // Only stall if buffer is full
    assign Initiator.STALL = r_valid;
    // Always send target's output to initiator
    assign Initiator.DAT_ToInitiator = Target.DAT_ToInitiator;
    assign Initiator.TGD_ToInitiator = Target.DAT_ToInitiator;
    assign Initiator.ACK = Target.ACK;
    assign Initiator.ERR = Target.ERR;
    assign Initiator.RTY = Target.RTY;

    // XXX: Initiator.CYC should be true whenever r_valid is true, so do I need to OR with r_valid?
    assign Target.CYC = Initiator.CYC | r_valid;
    assign Target.STB = i_valid | r_valid;

    // assign the inputs or buffer to the outputs
    always_comb
    begin
        // Put the buffered data on the output bus
        if (r_valid)
        begin
            Target.DAT_ToTarget = r_dat;
            Target.TGD_ToTarget = r_tgd;
            Target.ADDR = r_addr;
            Target.LOCK = r_lock;
            Target.SEL = r_sel;
            Target.TGA = r_tga;
            Target.TGC = r_tgc;
            Target.WE = r_we;
            Target.CTI = r_cti;
            Target.BTE = r_bte;
        end else
        begin
            if (!LOWPOWER || i_valid)
            begin
                // If LOWPOWER, this checks i_valid; else there is no check and this always happens
                Target.DAT_ToTarget = Initiator.DAT_ToTarget;
                Target.TGD_ToTarget = Initiator.TGD_ToTarget;
                Target.ADDR = Initiator.ADDR;
                Target.LOCK = Initiator.LOCK;
                Target.SEL = Initiator.SEL;
                Target.TGA = Initiator.TGA;
                Target.TGC = Initiator.TGC;
                Target.WE = Initiator.WE;
                Target.CTI = Initiator.CTI;
                Target.BTE = Initiator.BTE;
            end else
            begin
                // if !LOWPOWER this logic gets trimmed because the above is always true.
                // if LOWPOWER, these become zero when not outputting a strobe to avoid latches.
                Target.DAT_ToTarget = 0;
                Target.TGD_ToTarget = 0;
                Target.ADDR = 0;
                Target.LOCK = 0;
                Target.SEL = 0;
                Target.TGA = 0;
                Target.TGC = 0;
                Target.WE = 0;
                Target.CTI = 0;
                Target.BTE = 0;
            end
        end
    end

    // Store the data each clock cycle if not stalling
    always_ff @(posedge Syscon.CLK)
    if (!Syscon.RST)
    begin
        // if LOWPOWER, these don't get set unless we have CYC&STB.  In all other conditions
        // when LOWPOWER, r_* |=> $last(r_*)  (or is it current r_*?)
        if ((!LOWPOWER || i_valid) && !r_valid)
        begin
            r_dat <= Initiator.DAT_ToTarget;
            r_tgd <= Initiator.TGD_ToTarget;
            r_addr <= Initiator.ADDR;
            r_lock <= Initiator.LOCK;
            r_sel <= Initiator.SEL;
            r_tga <= Initiator.TGA;
            r_tgc <= Initiator.TGC;
            r_we <= Initiator.WE;
            r_cti <= Initiator.CTI;
            r_bte <= Initiator.BTE;
        end
    end

    always_ff @(posedge Syscon.CLK)
    begin
        // this satisfies all deassertions and clears the buffer 
        if (Syscon.RST) r_valid <= '0;
        // Wishbone B4 rule 3.2.0 disallows Target.CYC falling before Target.STB.  Nothing is said about
        // dropping before receiving Target.ACK, but it's implied that's invalid.   
        else if (Initiator.CYC)
        begin
            // Stall hasn't propagated, but incoming data, so buffer.
            if ((i_valid && !Initiator.STALL) && (o_valid && Target.STALL))
            begin
                r_valid <= '1;
            end else r_valid <= '0;
        end
        // Obviously didn't wait for a bus termination signal but terminated anyway.  If the buffer
        // is tolerant, clear the buffer; else this is trimmed and the bus may do broken things
        // like hold Target.CYC and Target.STB with unchanging data until Initiator.CYC is again asserted.  Doing so
        // MIGHT damage hardware!
        else if (!STRICT) r_valid <= '0;
    end

`ifdef FORMAL
    // TODO:  Formal verification
`endif
endmodule