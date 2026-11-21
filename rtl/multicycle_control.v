// =============================================================================
// multicycle_control.v -- finite-state machine of the multicycle RV32I core
// =============================================================================
//
// The multicycle core (cpu_multi_cycle.v) splits every instruction into a
// sequence of short steps, one per clock cycle.  This module is the state
// machine that sequences them.  It only knows the *class* of the current
// instruction (load, store, branch, jal, jalr, "no execute step", other),
// which the main decoder (control.v) derives from the instruction register;
// from the current state it produces the write enables of the datapath
// registers for this cycle and the next state.
//
// State diagram
// -------------
//
//                    +-----------+
//        +---------->|   FETCH   |  IR <- imem[pc]
//        |           +-----------+
//        |                 |
//        |                 v
//        |           +-----------+  A <- rs1, B <- rs2,
//        |<----------|  DECODE   |  target <- pc + imm (ALU otherwise idle)
//        | fence,    +-----------+
//        | ecall,      |       |
//        | ebreak      |       +------------------- jal ------------+
//        |             v                                            |
//        |           +-----------+  ALUOut <- ALU(A / pc / 0,       |
//        |<----------|  EXECUTE  |               B / imm)           |
//        | branch    +-----------+  branch: pc <- taken ? target    |
//        |             |       |                     : pc + 4       |
//        |  load,      |       +-- ALU op, lui, auipc, jalr --+     |
//        |  store      v                                      |     |
//        |           +-----------+                            |     |
//        |<----------|  MEMORY   |  load:  MDR <- dmem[ALUOut]|     |
//        | store     +-----------+  store: dmem[ALUOut] <- B  |     |
//        |             | load                                 |     |
//        |             v                                      v     v
//        |           +---------------------------------------------------+
//        +-----------|                     WRITEBACK                     |
//                    +---------------------------------------------------+
//                      rd <- ALUOut / MDR / pc + 4
//                      pc <- target (jal), ALUOut & ~1 (jalr), else pc + 4
//
// In every last state (an arrow back to FETCH) the pc takes its next value:
// pc + 4 unless the instruction is a taken branch or a jump.
//
// An instruction retires in the cycle whose next state is FETCH: that is
// when "done" is high, the pc takes its next value and the commit port of
// the core describes the instruction.  Register writes only happen in
// WRITEBACK and data-memory writes only in MEMORY, so an instruction that
// traps before its last state leaves no architectural trace.
//
// Cycles per instruction class
// ----------------------------
//
//   class                          states                       cycles
//   fence, ecall, ebreak           F D                            2
//   branch (taken or not)          F D E                          3
//   jal                            F D W                          3
//   store                          F D E M                        4
//   ALU reg/imm, lui, auipc, jalr  F D E W                        4
//   load                           F D E M W                      5
//
// Trap freeze: while the core reports a trap ("stall" high) the state does
// not advance and nothing is written; the system around the core stops.
// =============================================================================
`timescale 1ns / 1ps

module multicycle_control (
    input  wire       clk,
    input  wire       rst,          // synchronous, active high: back to FETCH
    input  wire       stall,        // trap reported: freeze the state

    // ---- class of the instruction in the instruction register ----
    input  wire       is_load,
    input  wire       is_store,
    input  wire       is_branch,
    input  wire       is_jal,
    input  wire       no_execute,   // fence, ecall, ebreak (and illegal words)

    // ---- per-cycle control of the datapath ----
    output reg  [2:0] state,
    output wire       ir_write,     // load the instruction register
    output wire       operands_write, // load the A and B registers
    output wire       target_write, // load the branch / jal target register
    output wire       alu_out_write,// load ALUOut
    output wire       mdr_write,    // load the memory data register
    output wire       mem_state,    // the data memory may be accessed
    output wire       rf_write_state, // the register file may be written
    output wire       decode_state, // the ALU computes pc + imm (target)
    output wire       pc_write,     // the pc takes its next value
    output wire       done          // the instruction retires this cycle
);

    // State encoding.
    localparam [2:0] S_FETCH     = 3'd0,
                     S_DECODE    = 3'd1,
                     S_EXECUTE   = 3'd2,
                     S_MEMORY    = 3'd3,
                     S_WRITEBACK = 3'd4;

    // ---------------------------------------------------------------------
    // Next-state logic
    // ---------------------------------------------------------------------
    reg [2:0] next_state;

    always @(*) begin
        case (state)
            S_FETCH:
                next_state = S_DECODE;

            S_DECODE:
                if (no_execute)
                    next_state = S_FETCH;        // nothing left to do
                else if (is_jal)
                    next_state = S_WRITEBACK;    // target already computed
                else
                    next_state = S_EXECUTE;

            S_EXECUTE:
                if (is_branch)
                    next_state = S_FETCH;        // branch resolved here
                else if (is_load || is_store)
                    next_state = S_MEMORY;
                else
                    next_state = S_WRITEBACK;

            S_MEMORY:
                if (is_load)
                    next_state = S_WRITEBACK;
                else
                    next_state = S_FETCH;        // store complete

            S_WRITEBACK:
                next_state = S_FETCH;

            default:
                next_state = S_FETCH;            // unused encodings recover
        endcase
    end

    // ---------------------------------------------------------------------
    // State register
    // ---------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst)
            state <= S_FETCH;
        else if (!stall)
            state <= next_state;
    end

    // ---------------------------------------------------------------------
    // Outputs: Moore-style enables decoded from the current state
    // ---------------------------------------------------------------------
    assign ir_write       = (state == S_FETCH);
    assign operands_write = (state == S_DECODE);
    assign target_write   = (state == S_DECODE);
    assign decode_state   = (state == S_DECODE);
    assign alu_out_write  = (state == S_EXECUTE);
    assign mdr_write      = (state == S_MEMORY);
    assign mem_state      = (state == S_MEMORY);
    assign rf_write_state = (state == S_WRITEBACK);

    // The last state of every instruction is the one that returns to FETCH.
    assign done     = (state != S_FETCH) && (next_state == S_FETCH);
    assign pc_write = done;

endmodule
