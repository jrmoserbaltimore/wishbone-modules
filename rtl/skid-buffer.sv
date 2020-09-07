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
    IWishbone.SysCon SysCon,
    IWishbone.Target Initiator,
    IWishbone.Initiator Target
);

    localparam BufferBits = $clog2(BufferSize) ? $clog2(BufferSize) : '1;

    // Only need to buffer initiator-to-target because only target may stall.
    logic r_valid [BufferSize-1:0];
    logic r_cyc;
    logic [DataWidth-1:0] r_dat [BufferSize-1:0];
    logic [TGDWidth-1:0] r_tgd [BufferSize-1:0];
    logic [AddressWidth-1:0] r_addr [BufferSize-1:0];
    logic r_lock [BufferSize-1:0];
    logic [SELWidth-1:0] r_sel [BufferSize-1:0];
    logic [TGAWidth-1:0] r_tga [BufferSize-1:0];
    logic [TGCWidth-1:0] r_tgc [BufferSize-1:0];
    logic r_we [BufferSize-1:0];
    logic [2:0] r_cti [BufferSize-1:0];
    logic [1:0] r_bte [BufferSize-1:0];

    logic [BufferBits-1:0] BufferIndex;
    wire w_valid;
    wire w_cyc;
    wire w_dat;
    wire w_tgd;
    wire w_addr;
    wire w_lock;
    wire w_sel;
    wire w_tga;
    wire w_tgc;
    wire w_we;
    wire w_cti;
    wire w_bte;

    assign w_valid = r_valid[BufferIndex];
    assign w_dat = r_dat[BufferIndex];
    assign w_tgd = r_tgd[BufferIndex];
    assign w_addr = r_addr[BufferIndex];
    assign w_lock = r_lock[BufferIndex]; 
    assign w_sel = r_sel[BufferIndex];
    assign w_tga = r_tga[BufferIndex];
    assign w_tgc = r_tgc[BufferIndex];
    assign w_cti = r_cti[BufferIndex];
    assign w_bte = r_bte[BufferIndex];

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

    generate
    genvar i;
        if (BufferSize <= 1)
        begin
            assign BufferIndex = '0;
            // Only stall if buffer is full
            assign Initiator.STALL = w_valid;
            // r_valid outputs to Initiator.CYC and Initiator.STB when forwarding the register
            assign Target.CYC = Initiator.CYC | w_valid;
            assign Target.STB = i_valid | w_valid;
            assign i_valid = Initiator.CYC & Initiator.STB;
        end else
        begin
            // Only stall if buffer is full OR we're waiting to buffer a dropped CYC.
            assign Initiator.STALL = w_valid & ~r_CYCDrop;
            // Need to buffer CYC drops
            assign Target.CYC = (Initiator.CYC & !w_valid) | (w_valid & w_cyc);
            assign Target.STB = i_valid | (w_valid & w_cyc);
            assign i_valid = (Initiator.CYC & Initiator.STB) | r_CYCDrop;
            always_ff @(posedge SysCon.CLK)
            begin
                // If we're already waiting to log a dropped CYC, 
                LastCYC <= Initiator.CYC & ~r_CYCDrop;
                // If we're stalled and waiting to forward a dropped CYC
                // OR last CYC was on and current CYC is off, register a dropped CYC.
                // This ignores flapping during a stall. 
                r_CYCDrop <= (w_valid & r_CYCDrop) | (LastCYC & ~Initiator.CYC);
            end
        end
    endgenerate

    // assign the inputs or buffer to the outputs
    always_comb
    begin
        // Put the buffered data on the output bus
        if (w_valid)
        begin
            Target.DAT_ToTarget = w_dat;
            Target.TGD_ToTarget = w_tgd;
            Target.ADDR = w_addr;
            Target.LOCK = w_lock;
            Target.SEL = w_sel;
            Target.TGA = w_tga;
            Target.TGC = w_tgc;
            Target.WE = w_we;
            Target.CTI = w_cti;
            Target.BTE = w_bte;
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
    if (!Syscon.RST)
    begin
        // if LOWPOWER, these don't get set unless we have CYC&STB.  In all other conditions
        // when LOWPOWER, r_* |=> $last(r_*)  (or is it current r_*?)
        if ((!LOWPOWER || i_valid) && !w_valid)
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
        if (SysCon.RST) r_valid[BufferIndex] <= '0;
        // Wishbone B4 rule 3.2.0 disallows Target.CYC falling before Target.STB.  Nothing is said about
        // dropping before receiving Target.ACK, but it's implied that's invalid.   
        else if (Initiator.CYC)
        begin
            // Stall hasn't propagated, but incoming data, so buffer.
            if ((i_valid && !Initiator.STALL) && (o_valid && Target.STALL))
            begin
                r_valid[BufferIndex] <= '1;
                BufferIndex <= (BufferIndex == BufferSize + 1) ? '0 : BufferIndex + 1; 
            end else r_valid[BufferIndex] <= '0;
        end
        // Obviously didn't wait for a bus termination signal but terminated anyway.  If the buffer
        // is tolerant, clear the buffer; else this is trimmed and the bus may do broken things
        // like hold Target.CYC and Target.STB with unchanging data until Initiator.CYC is again asserted.  Doing so
        // MIGHT damage hardware!
        else if (!STRICT) r_valid[BufferIndex] <= '0;
    end

`ifdef FORMAL
    // TODO:  Formal verification
`endif
endmodule