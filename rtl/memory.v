// =============================================================================
// memory.v -- instruction ROM and data RAM of the processor
// =============================================================================
//
// Harvard organisation, as in the textbook single-cycle datapath: the
// instruction port and the data port are independent, so an instruction can
// be fetched and a load / store performed in the same cycle.
//
// Memory map (byte addresses), matching the reference simulator:
//
//   0x0000_0000 .. ROM_BYTES-1          instruction ROM  (.text)
//   0x1000_0000 .. +DATA_BYTES-1        data RAM         (.data)
//   0x8000_0000-STACK_BYTES .. 0x7FFF_FFFF   stack RAM   (sp starts at 0x7FFF_FFF0)
//
// Every memory is an array of 32-bit words.  Reads are asynchronous (the word
// is available in the same cycle, as a single-cycle core requires) and
// writes happen on the rising clock edge, one write enable per byte lane.
// Byte-lane steering and sign extension are done by load_store_unit.v.
//
// The data port can also read the ROM, so that constant tables placed in
// .text can be loaded.  The ROM is read-only: a store to it, or any data
// access outside the three regions, raises "d_fault" and the core turns the
// instruction into a trap instead of executing it.
//
// Initial contents: the ROM is filled by the testbench with $readmemh
// (text.hex); the data RAM is cleared and then loaded from data.hex; the
// stack RAM starts cleared.  The clearing loops in the initial block are
// accepted by FPGA synthesis tools as memory initialisation.
// =============================================================================
`timescale 1ns / 1ps

module memory #(
    parameter ROM_WORDS   = 4096,           // 16 KiB of instructions
    parameter DATA_WORDS  = 16384,          // 64 KiB of data
    parameter STACK_WORDS = 16384,          // 64 KiB of stack
    parameter [31:0] DATA_BASE = 32'h1000_0000,
    parameter [31:0] STACK_END = 32'h8000_0000   // first address above the stack
) (
    input  wire        clk,

    // ---- instruction port (read only) ----
    input  wire [31:0] i_addr,
    output wire [31:0] i_rdata,

    // ---- data port ----
    input  wire [31:0] d_addr,      // byte address; bits [1:0] are handled by the LSU
    input  wire        d_req,       // a load or a store is requested this cycle
    input  wire [3:0]  d_be,        // byte lanes the store would write (0000 for a load)
    input  wire        d_we,        // commit the store at the clock edge
    input  wire [31:0] d_wdata,     // store data, already replicated into the lanes
    output wire [31:0] d_rdata,     // word at d_addr (rounded down to a multiple of 4)
    output wire        d_fault      // access outside the map, or a store to ROM
);

    localparam ROM_AW   = $clog2(ROM_WORDS);
    localparam DATA_AW  = $clog2(DATA_WORDS);
    localparam STACK_AW = $clog2(STACK_WORDS);

    localparam [31:0] ROM_BYTES   = ROM_WORDS * 4;
    localparam [31:0] DATA_BYTES  = DATA_WORDS * 4;
    localparam [31:0] STACK_BYTES = STACK_WORDS * 4;
    localparam [31:0] STACK_BASE  = STACK_END - STACK_BYTES;

    reg [31:0] rom   [0:ROM_WORDS-1];
    reg [31:0] dram  [0:DATA_WORDS-1];
    reg [31:0] stack [0:STACK_WORDS-1];

    integer k;
    initial begin
        for (k = 0; k < ROM_WORDS; k = k + 1)   rom[k]   = 32'd0;
        for (k = 0; k < DATA_WORDS; k = k + 1)  dram[k]  = 32'd0;
        for (k = 0; k < STACK_WORDS; k = k + 1) stack[k] = 32'd0;
    end

    // ---- instruction port ------------------------------------------------
    wire i_in_rom = (i_addr < ROM_BYTES);
    wire [ROM_AW-1:0] i_index = i_addr[ROM_AW+1:2];
    assign i_rdata = i_in_rom ? rom[i_index] : 32'd0;   // 0 decodes as an illegal instruction

    // ---- data port: address decoding --------------------------------------
    // The subtraction gives the offset inside each region; the comparison
    // tells whether the address falls in it.
    wire [31:0] data_off  = d_addr - DATA_BASE;
    wire [31:0] stack_off = d_addr - STACK_BASE;

    wire in_rom   = (d_addr    < ROM_BYTES);
    wire in_data  = (data_off  < DATA_BYTES);
    wire in_stack = (stack_off < STACK_BYTES);

    wire [ROM_AW-1:0]   rom_index   = d_addr[ROM_AW+1:2];
    wire [DATA_AW-1:0]  data_index  = data_off[DATA_AW+1:2];
    wire [STACK_AW-1:0] stack_index = stack_off[STACK_AW+1:2];

    wire is_store = (d_be != 4'b0000);

    assign d_fault = d_req & ~(in_data | in_stack | (in_rom & ~is_store));

    assign d_rdata = in_data  ? dram[data_index]   :
                     in_stack ? stack[stack_index] :
                     in_rom   ? rom[rom_index]     : 32'd0;

    // ---- data port: byte-lane writes --------------------------------------
    always @(posedge clk) begin
        if (d_we && in_data) begin
            if (d_be[0]) dram[data_index][7:0]   <= d_wdata[7:0];
            if (d_be[1]) dram[data_index][15:8]  <= d_wdata[15:8];
            if (d_be[2]) dram[data_index][23:16] <= d_wdata[23:16];
            if (d_be[3]) dram[data_index][31:24] <= d_wdata[31:24];
        end
        if (d_we && in_stack) begin
            if (d_be[0]) stack[stack_index][7:0]   <= d_wdata[7:0];
            if (d_be[1]) stack[stack_index][15:8]  <= d_wdata[15:8];
            if (d_be[2]) stack[stack_index][23:16] <= d_wdata[23:16];
            if (d_be[3]) stack[stack_index][31:24] <= d_wdata[31:24];
        end
    end

endmodule
