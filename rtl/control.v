// =============================================================================
// control.v -- main decoder and ALU control of the single-cycle processor
// =============================================================================
//
// Combinational.  From the instruction word it produces every control signal
// of the datapath for the current cycle:
//
//   reg_write   write the result to rd at the end of the cycle
//   imm_sel     immediate format (I, S, B, U, J) for imm_gen
//   src_a_sel   ALU operand A: rs1, pc (auipc) or 0 (lui)
//   src_b_sel   ALU operand B: rs2 or the immediate
//   alu_op      ALU operation (see "ALU control" below)
//   mem_read    the instruction is a load
//   mem_write   the instruction is a store
//   wb_sel      value written to rd: ALU result, load data or pc + 4
//   branch      conditional branch: the branch unit decides whether it is taken
//   jump        jal: unconditional pc-relative jump
//   jump_reg    jalr: jump to (rs1 + imm) with bit 0 cleared
//   is_ecall    environment call (serviced outside the core)
//   is_ebreak   breakpoint (stops the simulation)
//   illegal     the word is not a valid RV32I instruction
//
// Summary of the main decoder (x = don't care):
//
//   opcode    reg_write imm  srcA  srcB  mem r/w  wb   branch jump jump_reg
//   LUI           1      U   zero  imm    0  0   ALU    0     0     0
//   AUIPC         1      U   pc    imm    0  0   ALU    0     0     0
//   JAL           1      J    x     x     0  0   PC4    0     1     0
//   JALR          1      I   rs1   imm    0  0   PC4    0     0     1
//   BRANCH        0      B    x     x     0  0    x     1     0     0
//   LOAD          1      I   rs1   imm    1  0   MEM    0     0     0
//   STORE         0      S   rs1   imm    0  1    x     0     0     0
//   OP-IMM        1      I   rs1   imm    0  0   ALU    0     0     0
//   OP            1      x   rs1   rs2    0  0   ALU    0     0     0
//   FENCE         0      x    x     x     0  0    x     0     0     0
//
// The jal target and the branch target are both pc + imm and are computed by
// a dedicated adder in the datapath, which leaves the ALU free to evaluate
// the jalr target (rs1 + imm).  Branch conditions are evaluated by the
// branch unit, so the ALU is not involved in branches at all.
//
// An illegal instruction deasserts every state-changing signal, so the core
// cannot corrupt registers or memory while the trap is being reported.
// The legality rules match the reference simulator exactly: reserved funct3 /
// funct7 combinations, FENCE.I and SYSTEM words other than ECALL and EBREAK
// are all illegal.
// =============================================================================
`timescale 1ns / 1ps
`include "rv32i_defs.vh"

module control (
    input  wire [31:0] instr,

    output reg         reg_write,
    output reg  [2:0]  imm_sel,
    output reg  [1:0]  src_a_sel,
    output reg         src_b_sel,
    output reg  [3:0]  alu_op,
    output reg         mem_read,
    output reg         mem_write,
    output reg  [1:0]  wb_sel,
    output reg         branch,
    output reg         jump,
    output reg         jump_reg,
    output reg         is_ecall,
    output reg         is_ebreak,
    output reg         illegal
);

    wire [6:0] opcode = instr[6:0];
    wire [2:0] funct3 = instr[14:12];
    wire [6:0] funct7 = instr[31:25];

    // ---------------------------------------------------------------------
    // Main decoder
    // ---------------------------------------------------------------------
    // "alu_from_funct" tells the ALU control below whether the operation
    // comes from the instruction's funct fields (OP / OP-IMM) or is a plain
    // ADD (address and pc arithmetic).
    reg alu_from_funct;

    always @(*) begin
        // Defaults: a no-op that changes nothing.
        reg_write      = 1'b0;
        imm_sel        = `IMM_I;
        src_a_sel      = `SRCA_RS1;
        src_b_sel      = `SRCB_IMM;
        alu_from_funct = 1'b0;
        mem_read       = 1'b0;
        mem_write      = 1'b0;
        wb_sel         = `WB_ALU;
        branch         = 1'b0;
        jump           = 1'b0;
        jump_reg       = 1'b0;
        is_ecall       = 1'b0;
        is_ebreak      = 1'b0;
        illegal        = 1'b0;

        case (opcode)
            `OPC_LUI: begin
                reg_write = 1'b1;
                imm_sel   = `IMM_U;
                src_a_sel = `SRCA_ZERO;
            end

            `OPC_AUIPC: begin
                reg_write = 1'b1;
                imm_sel   = `IMM_U;
                src_a_sel = `SRCA_PC;
            end

            `OPC_JAL: begin
                reg_write = 1'b1;
                imm_sel   = `IMM_J;
                wb_sel    = `WB_PC4;
                jump      = 1'b1;
            end

            `OPC_JALR: begin
                if (funct3 == 3'b000) begin
                    reg_write = 1'b1;
                    wb_sel    = `WB_PC4;
                    jump_reg  = 1'b1;
                end else begin
                    illegal = 1'b1;
                end
            end

            `OPC_BRANCH: begin
                imm_sel = `IMM_B;
                // funct3 = 010 and 011 are reserved
                if (funct3 == 3'b010 || funct3 == 3'b011)
                    illegal = 1'b1;
                else
                    branch = 1'b1;
            end

            `OPC_LOAD: begin
                // lb lh lw lbu lhu = 000 001 010 100 101
                if (funct3 == 3'b011 || funct3 == 3'b110 || funct3 == 3'b111) begin
                    illegal = 1'b1;
                end else begin
                    reg_write = 1'b1;
                    mem_read  = 1'b1;
                    wb_sel    = `WB_MEM;
                end
            end

            `OPC_STORE: begin
                imm_sel = `IMM_S;
                // sb sh sw = 000 001 010
                if (funct3[2] || funct3[1:0] == 2'b11)
                    illegal = 1'b1;
                else
                    mem_write = 1'b1;
            end

            `OPC_OP_IMM: begin
                // Shift-immediates keep funct7 in imm[11:5]: 0000000 for
                // slli / srli, 0100000 for srai; anything else is reserved.
                if ((funct3 == 3'b001 && funct7 != 7'b0000000) ||
                    (funct3 == 3'b101 && funct7 != 7'b0000000 && funct7 != 7'b0100000)) begin
                    illegal = 1'b1;
                end else begin
                    reg_write      = 1'b1;
                    alu_from_funct = 1'b1;
                end
            end

            `OPC_OP: begin
                // funct7 = 0100000 only exists for sub and sra.
                if (funct7 == 7'b0000000 ||
                    (funct7 == 7'b0100000 && (funct3 == 3'b000 || funct3 == 3'b101))) begin
                    reg_write      = 1'b1;
                    src_b_sel      = `SRCB_RS2;
                    alu_from_funct = 1'b1;
                end else begin
                    illegal = 1'b1;
                end
            end

            `OPC_MISC_MEM: begin
                // FENCE orders memory accesses between harts and devices.
                // This core executes one instruction at a time, in order, with
                // no cache and no write buffer: every access is complete before
                // the next instruction starts, so FENCE is a no-op.
                // FENCE.I (funct3 = 001, Zifencei) is not part of RV32I.
                if (funct3 != 3'b000)
                    illegal = 1'b1;
            end

            `OPC_SYSTEM: begin
                if (instr == `INSTR_ECALL)
                    is_ecall = 1'b1;
                else if (instr == `INSTR_EBREAK)
                    is_ebreak = 1'b1;
                else
                    illegal = 1'b1;    // CSR instructions are not implemented
            end

            default: illegal = 1'b1;
        endcase
    end

    // ---------------------------------------------------------------------
    // ALU control
    // ---------------------------------------------------------------------
    // OP:      the operation is {funct7[5], funct3} (add/sub, srl/sra).
    // OP-IMM:  same, except that bit 30 belongs to the immediate for every
    //          operation but the right shifts, so "alt" is only honoured for
    //          funct3 = 101 (addi with a negative immediate must not become
    //          a subtraction).
    // Others:  ADD (address computation, lui, auipc).
    wire alt = instr[30] && (opcode == `OPC_OP || funct3 == 3'b101);

    always @(*) begin
        if (alu_from_funct)
            alu_op = {alt, funct3};
        else
            alu_op = `ALU_ADD;
    end

endmodule
