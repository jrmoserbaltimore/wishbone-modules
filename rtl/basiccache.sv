// vim: sw=4 ts=4 et
// Basic cache exposed as Wishbone Classic Pipelined
//
// This accesses an address in Source via a simple cache, using Storage as the cache file.
// Storage may be WishboneBRAM, an SRAM, a piece of 166MHz HyperRAM, on-die eDRAM, memory-mapped
// I/O to main RAM (e.g. if the storage is slow, such as ROM), and so forth.  What is written is
// written back.
//
// The Storage and Source must use any clock-domain crossing adapters necessary.  In particular,
// Storage being an array of BRAMs, minimal logic can run at rather high speed—461MHz on a
// Spartan-7 speed grade -2, says Xilinx—allowing narrow 36-bit BRAMs to spit out 72 bits in one
// 230MHz clock cycle.
//
// Note this is a simple cache controller.  It can't simultaneously access multiple BRAMs, so it
// can't benefit from a Way Cache. Such a cache controller would require an array of BRAMs instead
// of a single Wishbone bus; Way Cache would save mondo power.
module WishboneCache
#(
    // e.g. 2^13 = 8192, x 64 bit = x 8 byte = 65536 byte = 16 bit bytewise address space
    parameter int AddressWidth = 13, // number of DataBusWidth addresses in Source
    parameter int DataBusWidth = 64,    // 8, 16, 32, 64
    parameter int CacheLineSize = 128,    // Bytes.  Must be a multiple of DataBusWidth ÷ 8
    parameter int CacheSize = 16,       // KBytes, must be a power of 2
    parameter int Associativity = 4,  // CacheSize must be a multiple of this
    parameter [0:0] Parity = 1
)
(
    Wishbone.Target Initiator,
    Wishbone.Initiator Source, // The thing to cache
    Wishbone.Initiator Storage // Use this to back the cache
);
    localparam SetSize = CacheSize / Associativity;
    // Cache line is made of word-size chunks.  128 bytes = 16 = 4 bits
    localparam CacheLineWidth = $clog2(CacheLineSize * 8) - $clog2(DataBusWidth/8);
    // Bits representing set size ÷ cache line size
    localparam int IndexBits = $clog2(SetSize * 1024) - $clog2(CacheLineSize); 
    // The Dirty map allows skipping non-dirtied data blocks in a dirty cache line
    //  Dirty[0] Dirty[1]   D V
    //     X        X       X 0
    // [XXXXXXXX XXXXXXXX]
    //     0        0       0 1
    // [nnnnnnnn nnnnnnnn]
    //     0        1       1 1
    // [nnnnnnnn nnn*nnnn]
    localparam DirtyEntries = (2**IndexBits) / DataBusWidth;
    bit [CacheLineWidth-1:0] DirtyMap [IndexBits-1:0][Associativity-1:0];
    //                         [    Tag      ]   [    Index   ]   [   Offset  ]
    localparam int TagLength = AddressWidth - IndexBits - CacheLineWidth;
    // Cache entry meta-data:  tag, valid 
    bit [TagLength-1:0] CacheMapping [IndexBits-1:0][Associativity-1:0];
    bit ValidMap [IndexBits-1:0][Associativity-1:0];
    
    wire Dirty [Associativity-1:0];
    wire Valid [Associativity-1:0];
    // Count how many units we've copied in/out
    bit [CacheLineWidth-1:0] CachePutCounter = '0;

    wire [AddressWidth-TagLength-1:CacheLineWidth] Address;
    wire [IndexBits-1:0] Index;
    wire [TagLength-1:0] Tag;
    wire [CacheLineWidth-1:0] Offset;

    wire CacheHit [Associativity-1:0];

    // Respective chunks
    assign Tag = Initiator.ADDR[AddressWidth-1:AddressWidth-TagLength];
    assign Index = Initiator.ADDR[AddressWidth-TagLength-1:CacheLineWidth];
    assign Offset = Initiator.ADDR[CacheLineWidth-1:0];

    // Address inside cache
    assign Address = {Index,Offset};

    // When there's a cache miss, DataReady remains 0 
    assign Storage.Dout = Cache.Din;
    assign Cache.Dout = Storage.Din;
    assign Storage.Write = Cache.Write && CacheHit;
 
    generate
        genvar i;
        // Simultaneous computation of cache hit in all sets
        for (i = 0; i < Associativity; i++)
        begin
            assign Valid[i] = ValidMap[Index][i];
            assign CacheHit[i] = (Valid[i] && CacheMapping[Index][i] == Tag);
            assign Dirty[i] = |DirtyMap[Index][i];
        end
    endgenerate

    // Cache miss strategy:
    //
    //   - Select an entry (Way) for replacement
    //     - Of the suitable, prefer !Valid[Way] to avoid write-back
    //   - Set position to requested position
    //   - If write, store in a buffer and ack immediately (unless buffer full already, then stall)
    //   - Begin a bus cycle to Source
    //     - Immediately read the requested data
    //     - Store in buffer
    //     - ACK immediately
    //   - On each clock
    //     - If Replacing && Dirty[Index][Way]
    //       - Write the first dirty address back
    //       - Unmark Dirty[Index][Way][Offset]
    //     - If not Dirty[Index][Way]
    //       - Unmark Valid[Index][Way]
    //       - Write buffer into Storage
    //       - Read next address from Source
    //         - If it's the first address and it's a write, write the buffer instead of reading
    //       - Increment offset
    //         - Once it's wrapped all the way back to start, mark Valid[Index][Way]
    //
    // It is technically possible to buffer multiple of these, but it's more logic.  It's also
    // possible to interleave read/write, but it's a waste of time and may cause row open and close
    // repeatedly, adding delay.
    //
    // It's also possible to continuously write back (write through), but this is slower.
    always_ff @(Cache.CLK)
    begin
        // TODO:  Implement cache
    end
endmodule