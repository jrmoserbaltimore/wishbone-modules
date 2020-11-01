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
    parameter LOWPOWER = 1, // Reduces register transitions
    parameter STRICT = 0, // If set, the bus doesn't clean up after invalid inputs
    localparam SELWidth = DataWidth / Granularity
)
(
    // Common from SYSCON between Initiator and Target
    ISysCon SysCon,
    IWishbone.Target Initiator,
    IWishbone.Initiator Target
);
    logic r_valid;
    logic r_cyc;
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
    assign o_valid = Target.CYC & Target.STB;

    // Always send target's output to initiator
    assign Initiator.DAT_ToInitiator = Target.DAT_ToInitiator;
    assign Initiator.TGD_ToInitiator = Target.DAT_ToInitiator;
    assign Initiator.ACK = Target.ACK;
    assign Initiator.ERR = Target.ERR;
    assign Initiator.RTY = Target.RTY;

    logic r_CYCDrop;
    logic LastCYC;

    // Only stall if buffer is full OR we're waiting to buffer a dropped CYC.
    assign Initiator.ForceStall = r_valid & ~r_CYCDrop;
    // Need to buffer CYC drops
    assign Target.CYC = (Initiator.CYC & !r_valid) | (r_valid & r_cyc);
    assign Target.STB = i_valid | (r_valid & r_cyc);
    assign i_valid = (Initiator.CYC & Initiator.STB) | r_CYCDrop;
    always_ff @(posedge SysCon.CLK)
    begin
        // If we're already waiting to log a dropped CYC, 
        LastCYC <= Initiator.CYC & ~r_CYCDrop;
        // If we're stalled and waiting to forward a dropped CYC
        // OR last CYC was on and current CYC is off, register a dropped CYC.
        // This ignores flapping during a stall. 
        r_CYCDrop <= (r_valid & r_CYCDrop) | (LastCYC & ~Initiator.CYC);
    end

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
    always_ff @(posedge SysCon.CLK)
    if (!SysCon.RST)
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

    always_ff @(posedge SysCon.CLK)
    begin
        // this satisfies all deassertions and clears the buffer 
        if (SysCon.RST) r_valid <= '0;
        // Wishbone B4 rule 3.2.0 disallows Target.CYC falling before Target.STB.  Nothing is said about
        // dropping before receiving Target.ACK, but it's implied that's invalid.   
        else if (Initiator.CYC)
        begin
            // Stall hasn't propagated, but incoming data, so buffer.
            r_valid <= ((i_valid && !Initiator.Stalled()) && (o_valid && Target.Stalled()));
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