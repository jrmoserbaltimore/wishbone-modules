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
    logic RST;

    // Target signals
    logic [DataWidth-1:0] DAT_ToInitiator;
    logic [DataWidth-1:0] DAT_ToTarget;
    logic [TGDWidth-1:0] TGD_ToInitiator;
    logic [TGDWidth-1:0] TGD_ToTarget;
    
    logic ACK;
    logic [AddressWidth-1:0] ADDR;
    logic CYC;
    logic STALL;
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
        output CYC,
        output STB,
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
        input STALL
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
        output STALL
    );
endinterface