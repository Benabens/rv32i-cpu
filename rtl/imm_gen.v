// =============================================================================
// imm_gen.v -- immediate generator
// =============================================================================
//
// Reassembles the 32-bit immediate operand from the bits scattered across the
// instruction word.  Bit 31 of the instruction is always the sign of the
// immediate, so sign extension simply replicates instr[31].
//
//   I  imm[11:0]                      = instr[31:20]
//   S  imm[11:5] | imm[4:0]           = instr[31:25] | instr[11:7]
//   B  imm[12|10:5|4:1|11], imm[0]=0  = instr[31] | instr[30:25] | instr[11:8] | instr[7]
//   U  imm[31:12], imm[11:0]=0        = instr[31:12]
//   J  imm[20|10:1|11|19:12], imm[0]=0= instr[31] | instr[30:21] | instr[20] | instr[19:12]
//
// Branch and jump offsets are multiples of two, so their bit 0 is not stored
// in the instruction and is inserted here as a constant 0.  For OP-IMM shifts
// the I-format immediate is used as is: the ALU only looks at bits [4:0].
// =============================================================================
`timescale 1ns / 1ps
`include "rv32i_defs.vh"

module imm_gen (
    input  wire [31:0] instr,
    input  wire [2:0]  imm_sel,   // format, see `IMM_* in rv32i_defs.vh
    output reg  [31:0] imm
);

    always @(*) begin
        case (imm_sel)
            `IMM_I:  imm = {{21{instr[31]}}, instr[30:20]};
            `IMM_S:  imm = {{21{instr[31]}}, instr[30:25], instr[11:7]};
            `IMM_B:  imm = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
            `IMM_U:  imm = {instr[31:12], 12'd0};
            `IMM_J:  imm = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
            default: imm = 32'd0;
        endcase
    end

endmodule
