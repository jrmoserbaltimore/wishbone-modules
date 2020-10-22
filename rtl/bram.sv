// vim: sw=4 ts=4 et
// BRAM memory module exposed as Wishbone Classic Pipelined

module WishboneBRAM
#(
    parameter AddressWidth = 12,  // number of DataBusWidth entries (partial address decoding)
    parameter DataWidth = 8, // 8, 16, 32, 64
    parameter Parity = 1,
    parameter DeviceType = "Xilinx"
)
(
    ISysCon SysCon,
    IWishbone.Target Initiator
);
    assign Initiator.ForceStall = '0;

    generate
    if (DeviceType == "Xilinx")
    begin: Xilinx_BRAM_Inferred
        localparam RAM_WIDTH = DataWidth + (DataWidth / 8);
        localparam RAM_DEPTH = 1 << AddressWidth;                     //  (number of entries)
        localparam RAM_PERFORMANCE = "LOW_LATENCY"; // Select "HIGH_PERFORMANCE" or "LOW_LATENCY" 

        reg [RAM_WIDTH-1:0] BRAM [RAM_DEPTH-1:0];
        reg [RAM_WIDTH-1:0] ram_data = {RAM_WIDTH{1'b0}};

        // The following code either initializes the memory values to a specified file or to all zeros to match hardware
      
        begin: init_bram_to_zero
            integer ram_index;
            initial
            for (ram_index = 0; ram_index < RAM_DEPTH; ram_index = ram_index + 1)
                BRAM[ram_index] = {RAM_WIDTH{1'b0}};
        end

        always @(posedge SysCon.CLK)
        if (Initiator.RequestReady()) begin
            if (Initiator.WE)
                BRAM[Initiator.ADDR] <= {Initiator.GetRequest(), Initiator.GetRequestTGD()};
            ram_data <= BRAM[Initiator.ADDR];
        end

    //  The following code generates HIGH_PERFORMANCE (use output register) or LOW_LATENCY (no output register)
  
        begin: no_output_register

            // Always returns the data on the next clock cycle, no stall    
            always @(posedge SysCon.CLK)
            if (SysCon.RST)
            begin
                Initiator.PrepareResponse();
                Initiator.Unstall();
            end else
            begin
                Initiator.PrepareResponse();
                if (Initiator.RequestReady()) Initiator.SendResponse(BRAM[Initiator.ADDR]);
            end
        end
    end
    endgenerate

  //  The following function calculates the address width based on specified RAM depth
  function integer clogb2;
    input integer depth;
      for (clogb2=0; depth>0; clogb2=clogb2+1)
        depth = depth >> 1;
  endfunction

`ifdef FORMAL
    
`endif
endmodule