// vim: sw=4 ts=4 et
// Wishbone interface
//
// License: MIT

interface IWishbone
#(
    parameter AddressWidth = 16,
    parameter DataWidth = 8, // bits, 8, 16, 32, or 64
    parameter Granularity = 8, // bits, 8, 16, 32, or 64
    parameter TGDWidth = 1, // Tag data width
    parameter TGAWidth = 1,
    parameter TGCWidth = 1,
    localparam SELWidth = DataWidth / Granularity
);
    // Common from SYSCON
    logic CLK;
    logic RST = '0;

    // Target signals
    logic [DataWidth-1:0] DAT_ToInitiator;
    logic [DataWidth-1:0] DAT_ToTarget;
    logic [TGDWidth-1:0] TGD_ToInitiator;
    logic [TGDWidth-1:0] TGD_ToTarget;
    
    logic ACK;
    logic [AddressWidth-1:0] ADDR;
    logic CYC;
    wire STALL;
    logic ForceStall;
    logic InternalStall;
    logic ERR;
    logic LOCK;
    logic RTY;
    logic [SELWidth-1:0] SEL;
    logic STB;
    logic [TGAWidth-1:0] TGA;
    logic [TGCWidth-1:0] TGC;
    logic WE;
    // Registered Feedback
    logic [2:0] CTI;
    logic [1:0] BTE;

    assign STALL = ForceStall | InternalStall;

    // Hold the last response
    // XXX:  Is there any point to buffering?
    //logic [DataWidth-1:0] LastResponseBuffer;
    //wire LatestDAT_ToInitiator = ACK ? DAT_ToInitiator : LastResponseBuffer;
    //logic [TGDWidth-1:0] LastTGDBuffer;

    //logic ACKBuffer;
    //logic ERRBuffer;
    //logic RTYBuffer;

    // Initiator run every cycle
    task Prepare();
        //if (ACK) LastResponseBuffer <= DAT_ToInitiator;
        //if (ACK) LastTGDBuffer <= TGD_ToInitiator;
        //ACKBuffer <= ACK || ACKBuffer;
        //ERRBuffer <= ERR || ERRBuffer;
        //RTYBuffer <= RTY || RTYBuffer;
        STB <= STB & Stalled();
    endtask

    task Open();
        CYC <= '1;
        STB <= '0;
    endtask
    
    task Close();
        CYC <= '0;
        STB <= '0;
    endtask
    
    task SendData
    (
        input logic [AddressWidth-1:0] Address,
        input logic [DataWidth-1:0] Data,
        input logic [TGDWidth-1:0] TGD_o = '0,
        input logic [TGAWidth-1:0] TGA_o = '0,
        input logic [TGCWidth-1:0] TGC_o = '0,
        input logic [SELWidth-1:0] SEL_o = -1
    );
        ADDR <= Address;
        DAT_ToTarget <= Data;
        TGD_ToTarget <= TGD_o;
        TGA <= TGA_o;
        TGC <= TGC_o;
        WE <= '1;
        SEL <= SEL_o;
        STB <= '1;
        
        //ACKBuffer <= '0;
        //ERRBuffer <= '0;
        //RTYBuffer <= '0;
    endtask
    
    task RequestData
    (
        input logic [AddressWidth-1:0] Address,
        input logic [TGDWidth-1:0] TGD_o = '0,
        input logic [TGAWidth-1:0] TGA_o = '0,
        input logic [TGCWidth-1:0] TGC_o = '0
    );
        ADDR <= Address;
        TGD_ToTarget <= TGD_o;
        TGA <= TGA_o;
        TGC <= TGC_o;
        WE <= '0;
        STB <= '1;
    endtask

    function bit Stalled();
        return STALL;
    endfunction

    function bit ResponseReady();
        return ACK; // ? ACK : ACKBuffer;
    endfunction
    
    function bit ReceivedRetry();
        return RTY; // ? RTY : RTYBuffer;
    endfunction
    
    function bit ReceivedError();
        return ERR; // ? ERR : ERRBuffer;
    endfunction

    // does not check if a response has been received
    function logic [DataWidth-1:0] GetResponse();
        //ACKBuffer <= '0;
        return DAT_ToInitiator; // ACK ? DAT_ToInitiator : LastResponseBuffer; 
    endfunction;
    
    function logic [TGDWidth-1:0] GetResponseTGD();
        return TGD_ToInitiator; //ACK ? TGD_ToInitiator : LastTGDBuffer;
    endfunction
    
    // Target run every cycle
    task PrepareResponse();
        ACK <= '0;
        ERR <= '0;
        RTY <= '0;
    endtask
    
    function RequestReady();
        return STB & CYC;
    endfunction
    
    task SendResponse
    (
        input logic [DataWidth-1:0] Data,
        input logic [TGDWidth-1:0] TGD_o = '0
    );
        DAT_ToInitiator <= Data;
        TGD_ToInitiator <= TGD_o;
        ACK <= '1;
        ERR <= '0;
        RTY <= '0;
    endtask
    
    task SendError();
        ACK <= '0;
        ERR <= '1;
        RTY <= '0;
    endtask
    
    task SendRetry();
        ACK <= '0;
        ERR <= '0;
        RTY <= '1;
    endtask
    
    task Stall();
        InternalStall <= '1;
    endtask
    
    task Unstall();
        InternalStall  <= '0;
    endtask

    modport SysCon
    (
        input CLK,
        input RST
    );
    
    modport Initiator
    (
        input DAT_ToInitiator,
        output DAT_ToTarget,
        input TGD_ToInitiator,
        output TGD_ToTarget,
        
        // Bus control
        output CYC, // XXX Remove
        output STB, // XXX Remove
        output LOCK,

        // Command
        output ADDR,
        output SEL,
        output WE,

        // Tagging
        output TGA,
        output TGC,

        // Register Feedback
        output CTI,
        output BTE,

        // Bus termination signals
        input ACK,
        input ERR,
        input RTY,
        input STALL,
        import Prepare,
        import Open,
        import SendData,
        import RequestData,
        import Stalled,
        import ResponseReady,
        import ReceivedRetry,
        import ReceivedError,
        import GetResponse,
        import GetResponseTGD
    );

    modport Target
    (
        output DAT_ToInitiator,
        input DAT_ToTarget,
        output TGD_ToInitiator,
        input TGD_ToTarget,
        
        // Bus control
        input CYC,
        input STB,
        input LOCK,

        // Command
        input ADDR,
        input SEL,
        input WE,

        // Tagging
        input TGA,
        input TGC,

        // Register Feedback
        input CTI,
        input BTE,

        // Bus termination signals
        output ACK,
        output ERR,
        output RTY,
        output STALL,
        output ForceStall,
        import PrepareResponse,
        import RequestReady,
        import SendResponse,
        import SendError,
        import SendRetry,
        import Stall,
        import Unstall
    );

endinterface