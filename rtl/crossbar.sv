// vim: sw=4 ts=4 et
// Wishbone crossbar
//
// License: MIT

module WishboneCrossbar
#(
    parameter Initiators = 1,
    parameter Targets = 2,
    parameter AddressWidth = 16,
    parameter DataWidth = 8, // bits
    parameter SelGranularity = 8, // bits
    parameter SelWidth = 1,  // grains
    parameter InitiatorTGDWidth = 1, // bits, TO the Initiator
    parameter TargetTGDWidth = 1, // TO the Target
    parameter TGAWidth = 1,
    parameter TGCWidth = 1
)
(
    output logic [Initiators-1:0][DataWidth-1:0] I_DAT_I,
    input logic [Initiators-1:0][DataWidth-1:0] I_DAT_O,
    output logic [Initiators-1:0][DataWidth-1:0] I_TGD_I,
    input logic [Initiators-1:0][DataWidth-1:0] I_TGD_O,
    
    output logic [Initiators-1:0] ACK_I,
    input logic [Initiators-1:0][AddressWidth-1:0] ADR_O,
    input logic [Initiators-1:0] CYC_O,
    output logic [Initiators-1:0] STALL_I,
    output logic [Initiators-1:0] ERR_I,
    input logic [Initiators-1:0] LOCK_O,
    output logic [Initiators-1:0] RTY_I
);
endmodule