// =============================================================================
// cpu_multi_cycle.v -- multicycle RV32I processor core
// =============================================================================
//
// Same instruction set, same external interface, same commit port and same
// ecall / trap behaviour as cpu_single_cycle.v, but each instruction is
// executed as a sequence of short steps, one per clock cycle, sequenced by
// the state machine in multicycle_control.v:
//
//   FETCH      IR <- imem[pc]
//   DECODE     A <- rs1, B <- rs2, target <- pc + imm   (ALU reused)
//   EXECUTE    ALUOut <- ALU(...); branches are resolved here
//   MEMORY     MDR <- load data, or the store is performed
//   WRITEBACK  rd <- ALUOut / MDR / pc + 4; jumps update the pc
//
// Cycles per instruction (see multicycle_control.v for the state diagram):
//
//   fence, ecall, ebreak           2      F D
//   branch (taken or not)          3      F D E
//   jal                            3      F D W
//   store                          4      F D E M
//   ALU reg/imm, lui, auipc, jalr  4      F D E W
//   load                           5      F D E M W
//
// Datapath registers added with respect to the single-cycle core:
//
//      +----+        +----+   rs1  +---+                +--------+
//      | PC |--imem->| IR |--RF--->| A |--+    +-----+  | ALUOut |--+
//      +----+        +----+  rs2   +---+  +--->|     |->+--------+  |
//        ^              |    ----->| B |------>| ALU |              |
//        |              +-imm_gen--------+---->|     |->+--------+  |
//        |                                     +-----+  | target |  |
//        |                                              +--------+  |
//        |                               dmem --> +-----+           |
//        +---- next pc <---------------------+    | MDR |-- rd <----+
//                                                 +-----+
//
// Because every intermediate value is held in a register, one ALU serves
// three purposes (target pc + imm in DECODE, the operation itself or the
// address in EXECUTE), and the clock period only has to cover the slowest
// single step instead of the whole instruction.
//
// Memory organisation: the core keeps the separate instruction and data
// ports of memory.v (Harvard).  The memory map, the memory model and the
// testbench are then shared unchanged with the single-cycle core, so the
// two cores are verified by exactly the same flow.  Note that the core never
// uses both ports in the same cycle: the instruction port is only sampled
// in FETCH (into IR) and the data port is only active in MEMORY.  A unified
// single-port memory could therefore be connected with nothing more than an
// address multiplexer (pc in FETCH, ALUOut in MEMORY); the state machine
// would not change.
//
// Commit port and system events: an instruction retires in its last state
// (the one whose next state is FETCH).  In that cycle commit_valid is high
// and the commit_* outputs describe the instruction exactly as the
// single-cycle core does; ecall / ebreak are raised in the same cycle, with
// the registers holding their architectural values.  The pc register keeps
// the address of the current instruction until the instruction retires.
//
// Traps are detected in the state where they arise -- illegal instruction
// in DECODE, misaligned taken branch in EXECUTE, misaligned or out-of-map
// data access in MEMORY, misaligned jal / jalr target in WRITEBACK -- and
// in each case before any architectural state has been written.  The state
// machine then freezes and "trap" stays high, with the same cause codes as
// the single-cycle core.
// =============================================================================
`timescale 1ns / 1ps
`include "rv32i_defs.vh"

module cpu_multi_cycle #(
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
    // Architectural and intermediate registers
    // =====================================================================
    reg [31:0] pc;        // address of the instruction being executed
    reg [31:0] ir;        // instruction register
    reg [31:0] reg_a;     // rs1 value, read in DECODE
    reg [31:0] reg_b;     // rs2 value, read in DECODE
    reg [31:0] target;    // pc + imm, computed in DECODE (branch / jal target)
    reg [31:0] alu_out;   // ALU result of EXECUTE
    reg [31:0] mdr;       // memory data register: aligned, extended load data

    wire [31:0] pc_plus4 = pc + 32'd4;

    // =====================================================================
    // Fetch: the instruction port always shows the word at pc; it is
    // captured into IR in the FETCH state.
    // =====================================================================
    assign imem_addr = pc;

    // =====================================================================
    // Decode (combinational, from IR)
    // =====================================================================
    wire [4:0] rs1_addr = ir[19:15];
    wire [4:0] rs2_addr = ir[24:20];
    wire [4:0] rd_addr  = ir[11:7];
    wire [2:0] funct3   = ir[14:12];

    wire       reg_write, src_b_sel, mem_read, mem_write;
    wire       branch, jump, jump_reg, is_ecall, is_ebreak, illegal;
    wire [2:0] imm_sel;
    wire [1:0] src_a_sel, wb_sel;
    wire [3:0] alu_op;

    control u_control (
        .instr     (ir),
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

    // Instructions that are complete after DECODE: fence, ecall and ebreak
    // change nothing in the datapath.  (An illegal word also falls in this
    // class; it traps in DECODE anyway.)
    wire no_execute = ~reg_write & ~mem_read & ~mem_write &
                      ~branch & ~jump & ~jump_reg;

    // =====================================================================
    // State machine
    // =====================================================================
    wire [2:0] state;     // current state, for waveform viewing
    wire       ir_write, operands_write, target_write, alu_out_write, mdr_write;
    wire       mem_state, rf_write_state, decode_state, pc_write, done;

    multicycle_control u_fsm (
        .clk            (clk),
        .rst            (rst),
        .stall          (trap),
        .is_load        (mem_read),
        .is_store       (mem_write),
        .is_branch      (branch),
        .is_jal         (jump),
        .no_execute     (no_execute),
        .state          (state),
        .ir_write       (ir_write),
        .operands_write (operands_write),
        .target_write   (target_write),
        .alu_out_write  (alu_out_write),
        .mdr_write      (mdr_write),
        .mem_state      (mem_state),
        .rf_write_state (rf_write_state),
        .decode_state   (decode_state),
        .pc_write       (pc_write),
        .done           (done)
    );

    // =====================================================================
    // Register file and immediate
    // =====================================================================
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
        .instr   (ir),
        .imm_sel (imm_sel),
        .imm     (imm)
    );

    // =====================================================================
    // ALU with its operand multiplexers
    // =====================================================================
    // In DECODE the ALU is free and computes pc + imm, the target of a
    // branch or jal (for other instructions the value is simply unused).
    // In EXECUTE it performs the operation selected by the decoder, on the
    // A / B registers, the pc or 0 and the immediate.
    reg  [31:0] alu_a;
    reg  [31:0] alu_b;
    wire [3:0]  alu_ctrl = decode_state ? `ALU_ADD : alu_op;

    always @(*) begin
        if (decode_state)
            alu_a = pc;
        else begin
            case (src_a_sel)
                `SRCA_PC:   alu_a = pc;
                `SRCA_ZERO: alu_a = 32'd0;
                default:    alu_a = reg_a;
            endcase
        end
    end

    always @(*) begin
        if (decode_state || src_b_sel == `SRCB_IMM)
            alu_b = imm;
        else
            alu_b = reg_b;
    end

    wire [31:0] alu_result;

    alu u_alu (
        .alu_op (alu_ctrl),
        .a      (alu_a),
        .b      (alu_b),
        .result (alu_result)
    );

    // Branch condition, evaluated on the A / B registers in EXECUTE.
    wire branch_taken;

    branch_unit u_branch_unit (
        .funct3 (funct3),
        .rs1    (reg_a),
        .rs2    (reg_b),
        .taken  (branch_taken)
    );

    // =====================================================================
    // Memory access (MEMORY state only)
    // =====================================================================
    wire load_now  = mem_read  & mem_state;
    wire store_now = mem_write & mem_state;

    wire [31:0] load_data;
    wire        misaligned;

    load_store_unit u_lsu (
        .funct3     (funct3),
        .mem_read   (load_now),
        .mem_write  (store_now),
        .addr       (alu_out),
        .store_data (reg_b),
        .byte_en    (dmem_be),
        .bus_wdata  (dmem_wdata),
        .bus_rdata  (dmem_rdata),
        .load_data  (load_data),
        .misaligned (misaligned)
    );

    assign dmem_addr = alu_out;
    assign dmem_req  = load_now | store_now;

    // =====================================================================
    // Next pc (used in the instruction's last state)
    // =====================================================================
    //   branch (last state EXECUTE): taken ? target : pc + 4
    //   jal    (last state WRITEBACK): target
    //   jalr   (last state WRITEBACK): ALUOut with bit 0 cleared
    //   everything else: pc + 4
    reg [31:0] next_pc;
    always @(*) begin
        if (jump_reg)
            next_pc = {alu_out[31:1], 1'b0};
        else if (jump || (branch && branch_taken))
            next_pc = target;
        else
            next_pc = pc_plus4;
    end

    // =====================================================================
    // Traps
    // =====================================================================
    // The LSU only flags misalignment and the memory only flags a fault
    // while the data port is active (MEMORY); the jump check applies to the
    // value about to be written into the pc.
    always @(*) begin
        if (decode_state && illegal)
            trap_cause = `TRAP_ILLEGAL;
        else if (misaligned)
            trap_cause = `TRAP_MISALIGN;
        else if (dmem_fault)
            trap_cause = `TRAP_BUS;
        else if (pc_write && next_pc[1:0] != 2'b00)
            trap_cause = `TRAP_JUMP;
        else
            trap_cause = `TRAP_NONE;
    end

    assign trap   = ~rst & (trap_cause != `TRAP_NONE);
    wire   retire = ~rst & ~trap & done;

    assign ecall  = retire & is_ecall;
    assign ebreak = retire & is_ebreak;

    // =====================================================================
    // Write-back
    // =====================================================================
    reg [31:0] wb_value;
    always @(*) begin
        case (wb_sel)
            `WB_MEM: wb_value = mdr;
            `WB_PC4: wb_value = pc_plus4;
            default: wb_value = alu_out;
        endcase
    end

    assign rd_wdata = wb_value;
    assign rd_we    = ~rst & ~trap & rf_write_state & reg_write;
    assign dmem_we  = ~rst & ~trap & store_now;

    // =====================================================================
    // Register updates
    // =====================================================================
    always @(posedge clk) begin
        if (rst) begin
            pc      <= boot_pc;
            ir      <= 32'd0;
            reg_a   <= 32'd0;
            reg_b   <= 32'd0;
            target  <= 32'd0;
            alu_out <= 32'd0;
            mdr     <= 32'd0;
        end else if (!trap) begin
            if (ir_write)       ir      <= imem_rdata;
            if (operands_write) begin
                                reg_a   <= rs1_data;
                                reg_b   <= rs2_data;
            end
            if (target_write)   target  <= alu_result;
            if (alu_out_write)  alu_out <= alu_result;
            if (mdr_write)      mdr     <= load_data;
            if (pc_write)       pc      <= next_pc;
        end
    end

    // =====================================================================
    // Commit port
    // =====================================================================
    assign commit_valid     = retire;
    assign commit_pc        = pc;
    assign commit_instr     = ir;
    assign commit_rd        = rd_addr;
    assign commit_rd_we     = rd_we & (rd_addr != 5'd0);
    assign commit_rd_wdata  = rd_wdata;
    assign commit_mem_we    = dmem_we & retire;
    assign commit_mem_addr  = alu_out;
    assign commit_mem_wdata = reg_b;
    assign commit_mem_size  = funct3[1:0];

endmodule
