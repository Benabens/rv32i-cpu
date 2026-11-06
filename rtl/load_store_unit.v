// =============================================================================
// load_store_unit.v -- byte / halfword / word accesses on a 32-bit data bus
// =============================================================================
//
// The data memory is organised as 32-bit words with one write enable per
// byte lane.  RISC-V is little-endian: the byte at address 4k + n lives in
// lane n, i.e. bits [8n+7:8n] of word k.  This unit translates a load or a
// store of any size into word-bus signals.
//
// Stores: the rs2 value is replicated into every lane it could occupy
//   sb  -> {b, b, b, b}       sh -> {h, h}       sw -> w
// and the byte enables select the lanes actually written:
//   sb at offset n   -> 0001 << n
//   sh at offset 0/2 -> 0011 / 1100
//   sw               -> 1111
//
// Loads: the addressed byte or halfword is extracted from the word read
// from memory, then sign-extended (lb, lh) or zero-extended (lbu, lhu).
//
// Misalignment: a halfword must be at an even address and a word at a
// multiple of 4.  A misaligned access raises "misaligned"; the core then
// treats the instruction as a trap and suppresses the memory write.
//
// funct3 of loads and stores encodes the access: bits [1:0] give the size
// (00 byte, 01 halfword, 10 word) and bit 2 selects zero extension.
// =============================================================================
`timescale 1ns / 1ps
`include "rv32i_defs.vh"

module load_store_unit (
    input  wire [2:0]  funct3,
    input  wire        mem_read,      // the instruction is a load
    input  wire        mem_write,     // the instruction is a store
    input  wire [31:0] addr,          // byte address (rs1 + imm)
    input  wire [31:0] store_data,    // rs2

    // word-wide memory bus
    output reg  [3:0]  byte_en,       // lanes written by a store
    output reg  [31:0] bus_wdata,     // store data replicated into the lanes
    input  wire [31:0] bus_rdata,     // word containing the addressed bytes

    output reg  [31:0] load_data,     // aligned and extended load result
    output reg         misaligned
);

    wire [1:0] size     = funct3[1:0];
    wire       unsigned_load = funct3[2];
    wire [1:0] offset   = addr[1:0];

    // ---- alignment check --------------------------------------------------
    always @(*) begin
        case (size)
            `SIZE_HALF: misaligned = (mem_read | mem_write) & offset[0];
            `SIZE_WORD: misaligned = (mem_read | mem_write) & (offset != 2'b00);
            default:    misaligned = 1'b0;     // bytes are always aligned
        endcase
    end

    // ---- store path -----------------------------------------------------
    always @(*) begin
        case (size)
            `SIZE_BYTE: begin
                bus_wdata = {4{store_data[7:0]}};
                byte_en   = 4'b0001 << offset;
            end
            `SIZE_HALF: begin
                bus_wdata = {2{store_data[15:0]}};
                byte_en   = offset[1] ? 4'b1100 : 4'b0011;
            end
            default: begin
                bus_wdata = store_data;
                byte_en   = 4'b1111;
            end
        endcase
        if (!mem_write)
            byte_en = 4'b0000;
    end

    // ---- load path -----------------------------------------------------
    reg [7:0]  load_byte;
    reg [15:0] load_half;

    always @(*) begin
        case (offset)
            2'd0: load_byte = bus_rdata[7:0];
            2'd1: load_byte = bus_rdata[15:8];
            2'd2: load_byte = bus_rdata[23:16];
            default: load_byte = bus_rdata[31:24];
        endcase
        load_half = offset[1] ? bus_rdata[31:16] : bus_rdata[15:0];

        case (size)
            `SIZE_BYTE: load_data = {{24{load_byte[7]  & ~unsigned_load}}, load_byte};
            `SIZE_HALF: load_data = {{16{load_half[15] & ~unsigned_load}}, load_half};
            default:    load_data = bus_rdata;
        endcase
    end

endmodule
