// =============================================================================
// cpu_single_cycle.v -- single-cycle RV32I processor core
// =============================================================================
//
// Every instruction executes in exactly one clock cycle.  During the cycle the
// signals flow combinationally through the whole datapath:
//
//      +----+   instr   +---------+  rs1/rs2  +-----+   result
//      | PC |---------->| decode  |---------->| ALU |----------+
//      +----+  (ROM)    | regfile |   imm     +-----+          |
//        ^              | imm_gen |                  address   v
//        |              +---------+               +-------------+
//        |                   |                    | load/store  |-- data RAM
//        |  next pc          | branch unit        |    unit     |
//        +-------------------+--------------------+-------------+
//                                                         | write-back
//                                              rd <-------+
//
// and on the rising clock edge that ends the cycle three state elements are
// updated at once: the pc, the destination register rd and (for a store) the
// data memory.  Nothing else holds state, which is what makes the design
// "single-cycle": the clock period must cover the longest path, a load
// (fetch -> register read -> address add -> memory read -> extend -> rd).
//
// The five steps of an instruction map onto the code below:
//   1. Fetch      the ROM is read at the address held in the pc register.
//   2. Decode     control.v decodes the opcode; regfile.v reads rs1 and rs2;
//                 imm_gen.v rebuilds the immediate.
//   3. Execute    alu.v computes; branch_unit.v evaluates branch conditions;
//                 a separate adder computes the pc-relative target pc + imm.
//   4. Memory     load_store_unit.v drives the data bus (address from the ALU).
//   5. Write-back a multiplexer selects ALU result / load data / pc + 4 for rd,
//                 and the next-pc multiplexer selects pc + 4 / target / jalr.
//
// Environment calls: ECALL raises "ecall" for its cycle and otherwise behaves
// like a no-op (pc <- pc + 4).  The system around the core -- here the
// testbench -- reads a7 / a0 and performs the service before the clock edge.
// EBREAK raises "ebreak" in the same way; the testbench stops on it.
//
// Traps: an illegal instruction, a misaligned load / store, an access outside
// the memory map, or a taken jump / branch to an address that is not a
// multiple of 4 raises "trap" with a cause code.  The faulting instruction
// does not retire: the register file, the memory and the pc are left
// unchanged.  This core has no exception handler (no CSRs), so the system is
// expected to stop; the testbench reports the cause.
//
// Commit port: in every cycle in which an instruction retires (commit_valid),
// the commit_* outputs describe its architectural effect.  The testbench
// prints them in the same format as the reference simulator's commit trace,
// which is how the core is verified instruction by instruction.
// =============================================================================
`timescale 1ns / 1ps
`include "rv32i_defs.vh"

module cpu_single_cycle #(
    parameter [31:0] SP_RESET = 32'h7FFF_FFF0
) (
    input  wire        clk,
    input  wire        rst,             // synchronous, active high
    input  wire [31:0] boot_pc,         // pc loaded while rst is asserted

    // ---- instruction memory ----
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,

    // ---- data memory ----
    output wire [31:0] dmem_addr,
    output wire        dmem_req,        // load or store requested
    output wire [3:0]  dmem_be,         // lanes a store writes
    output wire        dmem_we,         // store committed at the clock edge
    output wire [31:0] dmem_wdata,
    input  wire [31:0] dmem_rdata,
    input  wire        dmem_fault,

    // ---- system events ----
    output wire        ecall,
    output wire        ebreak,
    output wire        trap,
    output reg  [2:0]  trap_cause,

    // ---- commit port ----
    output wire        commit_valid,
    output wire [31:0] commit_pc,
    output wire [31:0] commit_instr,
    output wire [4:0]  commit_rd,
    output wire        commit_rd_we,     // a register other than x0 is written
    output wire [31:0] commit_rd_wdata,
    output wire        commit_mem_we,
    output wire [31:0] commit_mem_addr,
    output wire [31:0] commit_mem_wdata, // rs2, truncated by the testbench to the size
    output wire [1:0]  commit_mem_size   // 0 byte, 1 halfword, 2 word
);

    // =====================================================================
    // 1. Fetch
    // =====================================================================
    reg  [31:0] pc;
    wire [31:0] instr = imem_rdata;
    assign imem_addr = pc;

    wire [31:0] pc_plus4 = pc + 32'd4;

    // =====================================================================
    // 2. Decode
    // =====================================================================
    wire [4:0] rs1_addr = instr[19:15];
    wire [4:0] rs2_addr = instr[24:20];
    wire [4:0] rd_addr  = instr[11:7];
    wire [2:0] funct3   = instr[14:12];

    wire       reg_write, src_b_sel, mem_read, mem_write;
    wire       branch, jump, jump_reg, is_ecall, is_ebreak, illegal;
    wire [2:0] imm_sel;
    wire [1:0] src_a_sel, wb_sel;
    wire [3:0] alu_op;

    control u_control (
        .instr     (instr),
        .reg_write (reg_write),
        .imm_sel   (imm_sel),
        .src_a_sel (src_a_sel),
        .src_b_sel (src_b_sel),
        .alu_op    (alu_op),
        .mem_read  (mem_read),
        .mem_write (mem_write),
        .wb_sel    (wb_sel),
        .branch    (branch),
        .jump      (jump),
        .jump_reg  (jump_reg),
        .is_ecall  (is_ecall),
        .is_ebreak (is_ebreak),
        .illegal   (illegal)
    );

    wire [31:0] rs1_data, rs2_data;
    wire [31:0] rd_wdata;
    wire        rd_we;

    regfile #(.SP_RESET(SP_RESET)) u_regfile (
        .clk    (clk),
        .rst    (rst),
        .raddr1 (rs1_addr),
        .rdata1 (rs1_data),
        .raddr2 (rs2_addr),
        .rdata2 (rs2_data),
        .we     (rd_we),
        .waddr  (rd_addr),
        .wdata  (rd_wdata)
    );

    wire [31:0] imm;

    imm_gen u_imm_gen (
        .instr   (instr),
        .imm_sel (imm_sel),
        .imm     (imm)
    );

    // =====================================================================
    // 3. Execute
    // =====================================================================
    reg  [31:0] alu_a;
    wire [31:0] alu_b = (src_b_sel == `SRCB_IMM) ? imm : rs2_data;

    always @(*) begin
        case (src_a_sel)
            `SRCA_PC:   alu_a = pc;
            `SRCA_ZERO: alu_a = 32'd0;
            default:    alu_a = rs1_data;
        endcase
    end

    wire [31:0] alu_result;

    alu u_alu (
        .alu_op (alu_op),
        .a      (alu_a),
        .b      (alu_b),
        .result (alu_result)
    );

    wire branch_taken;

    branch_unit u_branch_unit (
        .funct3 (funct3),
        .rs1    (rs1_data),
        .rs2    (rs2_data),
        .taken  (branch_taken)
    );

    // Target of jal and of taken branches.
    wire [31:0] pc_target = pc + imm;

    // =====================================================================
    // Next pc
    // =====================================================================
    // jalr: (rs1 + imm) computed by the ALU, with bit 0 forced to 0.
    reg [31:0] next_pc;
    always @(*) begin
        if (jump_reg)
            next_pc = {alu_result[31:1], 1'b0};
        else if (jump || (branch && branch_taken))
            next_pc = pc_target;
        else
            next_pc = pc_plus4;
    end

    // =====================================================================
    // 4. Memory
    // =====================================================================
    wire [31:0] load_data;
    wire        misaligned;

    load_store_unit u_lsu (
        .funct3     (funct3),
        .mem_read   (mem_read),
        .mem_write  (mem_write),
        .addr       (alu_result),
        .store_data (rs2_data),
        .byte_en    (dmem_be),
        .bus_wdata  (dmem_wdata),
        .bus_rdata  (dmem_rdata),
        .load_data  (load_data),
        .misaligned (misaligned)
    );

    assign dmem_addr = alu_result;
    assign dmem_req  = mem_read | mem_write;

    // =====================================================================
    // Traps: decide whether the instruction may retire
    // =====================================================================
    always @(*) begin
        if (illegal)
            trap_cause = `TRAP_ILLEGAL;
        else if (misaligned)
            trap_cause = `TRAP_MISALIGN;
        else if (dmem_fault)
            trap_cause = `TRAP_BUS;
        else if (next_pc[1:0] != 2'b00)
            trap_cause = `TRAP_JUMP;
        else
            trap_cause = `TRAP_NONE;
    end

    assign trap   = (trap_cause != `TRAP_NONE);
    wire   retire = ~rst & ~trap;

    assign ecall  = retire & is_ecall;
    assign ebreak = retire & is_ebreak;

    // =====================================================================
    // 5. Write-back
    // =====================================================================
    reg [31:0] wb_value;
    always @(*) begin
        case (wb_sel)
            `WB_MEM: wb_value = load_data;
            `WB_PC4: wb_value = pc_plus4;
            default: wb_value = alu_result;
        endcase
    end

    assign rd_wdata = wb_value;
    assign rd_we    = retire & reg_write;
    assign dmem_we  = retire & mem_write;

    // =====================================================================
    // Program counter
    // =====================================================================
    always @(posedge clk) begin
        if (rst)
            pc <= boot_pc;
        else if (!trap)
            pc <= next_pc;
    end

    // =====================================================================
    // Commit port
    // =====================================================================
    assign commit_valid     = retire;
    assign commit_pc        = pc;
    assign commit_instr     = instr;
    assign commit_rd        = rd_addr;
    assign commit_rd_we     = rd_we & (rd_addr != 5'd0);
    assign commit_rd_wdata  = rd_wdata;
    assign commit_mem_we    = dmem_we;
    assign commit_mem_addr  = alu_result;
    assign commit_mem_wdata = rs2_data;
    assign commit_mem_size  = funct3[1:0];

endmodule
