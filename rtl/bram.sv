// vim: sw=4 ts=4 et
// BRAM memory module exposed as Wishbone Classic Pipelined

module WishboneBRAM
#(
    parameter AddressBusWidth = 12,  // number of DataBusWidth entries (partial address decoding)
    parameter DataBusWidth = 8, // 8, 16, 32, 64
    parameter Parity = 1,
    parameter DeviceType = "Xilinx"
)
(
    IWishbone.SysCon System,
    IWishbone.Target Initiator
);
    assign Initiator.STALL = '0;

    generate
    if (DeviceType == "Xilinx")
    begin: Xilinx_BRAM_Inferred
        //  Xilinx Single Port Byte-Write Read First RAM
        //  This code implements a parameterizable single-port byte-write read-first memory where when data
        //  is written to the memory, the output reflects the prior contents of the memory location.
        //  If a reset or enable is not necessary, it may be tied off or removed from the code.
        //  Modify the parameters for the desired RAM characteristics.

        localparam NB_COL = DataBusWidth;            // Specify number of columns (number of bytes)
        localparam COL_WIDTH = 9;                   // Specify column width (byte width + parity bit)
        localparam RAM_DEPTH = 2**AddressBusWidth;   // Specify RAM depth (number of entries)

        // Uninitialized
        logic [(NB_COL*COL_WIDTH)-1:0] Bram [RAM_DEPTH-1:0];
        //logic [(NB_COL*COL_WIDTH)-1:0] BramData = {(NB_COL*COL_WIDTH){1'b0}};

        genvar i;
        for (i = 0; i < NB_COL; i = i+1) begin: byte_write
            // Parity is adjacent to the byte to avoid complicated computations of how many parity
            // bits there are, instead computing where the parity bits are.
            // xxxxxxxxPxxxxxxxxP…
            // Parity storage and TGD lines are trimmed out if !Parity
            always @(posedge System.CLK)
            if (Initiator.CYC && Initiator.STB && Initiator.SEL[i])
            begin
                // Organizing under the CYC & STB & SEL[i] test allows a 6-LUT output to select
                // between read and write.  Eliminating the else clause would use the above three
                // and not the WE for data reads, saving nothing since we still need two signls
                // to indicate whether anything is done and whether writing is done.  Moving the
                // read clause outside CYC & STB & SEL[i] would reduce usage to a 4-LUT and reclaim
                // a wire, at the expense of more transitions (dynamic power usage). 
                if (Initiator.WE)
                begin
                    // Extract data and parity
                    if (Parity) Bram[Initiator.ADDR][i*COL_WIDTH] <= Initiator.TGD_ToTarget[i];
                    Bram[Initiator.ADDR][(i+1)*COL_WIDTH-1:i*COL_WIDTH+1]
                      <= Initiator.DAT_ToTarget[(i+1)*COL_WIDTH-1:i*COL_WIDTH+1];
                end else
                begin
                    if (Parity) Initiator.TGD_ToInitiator[i] <= Bram[Initiator.ADDR][i*COL_WIDTH];
                    Initiator.DAT_ToInitiator[(i+1)*COL_WIDTH-1:i*COL_WIDTH+1]
                      <= Bram[Initiator.ADDR][(i+1)*COL_WIDTH-1:i*COL_WIDTH+1];
                end
            end
        end
    end
    endgenerate

    // Always returns the data on the next clock cycle, no stall    
    always @(posedge System.CLK)
        Initiator.ACK <= Initiator.CYC & Initiator.STB;

`ifdef FORMAL
    
`endif
endmodule