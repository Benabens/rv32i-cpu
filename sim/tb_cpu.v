// =============================================================================
// tb_cpu.v -- system testbench for the RV32I processors
// =============================================================================
//
// Connects a processor core to memory, loads a program, runs the clock and
// plays the role of the operating system.  The core is chosen at compile
// time:
//
//   iverilog ...                        cpu_single_cycle (default)
//   iverilog -DCORE_MULTI_CYCLE ...     cpu_multi_cycle
//
// Both cores have the same ports and the same commit port, so everything
// below is shared:
//
//   * ECALL   the core raises "ecall"; the testbench reads a7 (service) and a0
//             (argument) straight from the register file and performs the
//             service exactly like the reference simulator rvsim:
//               a7 = 1   print a0 as a signed decimal integer
//               a7 = 4   print the NUL-terminated string at address a0
//               a7 = 11  print the character a0
//               a7 = 10  exit (code 0)        a7 = 93  exit with code a0
//   * EBREAK  stops the simulation.
//   * The program also stops when the pc reaches the end of .text, when the
//     core reports a trap, or after a maximum number of instructions.
//
// For every retired instruction the commit port is printed to the trace file
// in the format of rvsim's commit trace (see rvsim/trace.py); the last line
// says why the simulation ended.  Printed program output goes both to stdout
// and to the output file.
//
// Timing: the testbench samples the core on the falling edge, when all
// signals of the current cycle have settled; the state is updated on the
// next rising edge.  It acts only on "instruction boundaries", cycles in
// which an instruction retires (commit_valid) or a trap is reported.  For
// the single-cycle core every cycle is a boundary; for the multicycle core
// it is the last cycle of each instruction.  An ecall is therefore serviced
// while the core is "inside" the instruction, with a7 / a0 holding their
// architectural values.
//
// Cycle count: the number of clock cycles from the end of reset up to and
// including the cycle in which the last instruction retired (so it equals
// the instruction count for the single-cycle core).  A core that goes more
// than HANG_CYCLES cycles without retiring or trapping is stopped with
// "TRAP hang" (only a broken design can do that).
//
// Plusargs (all required unless a default is given):
//   +text=<file> +text_words=<n>    instruction ROM image and its length
//   +data=<file> +data_words=<n>    data RAM image and its length
//   +entry=<hex>                    initial pc
//   +text_end=<hex>                 address just past the last instruction
//   +trace=<file>                   commit trace output
//   +out=<file>                     program output (ecall prints)
//   +max=<n>                        instruction limit (default 1000000)
//   +stats=<file>                   write "instructions <n>" / "cycles <n>"
//   +quiet                          do not echo program output to stdout
// =============================================================================
`timescale 1ns / 1ps
`include "rv32i_defs.vh"

`ifdef CORE_MULTI_CYCLE
  `define TB_CORE cpu_multi_cycle
`else
  `define TB_CORE cpu_single_cycle
`endif

module tb_cpu;

    // Longest legal gap between two instruction boundaries, in cycles.
    localparam HANG_CYCLES = 64;

    // Memory geometry -- must match the memory instance below.
    localparam ROM_WORDS   = 4096;
    localparam DATA_WORDS  = 16384;
    localparam STACK_WORDS = 16384;
    localparam [31:0] DATA_BASE  = 32'h1000_0000;
    localparam [31:0] STACK_END  = 32'h8000_0000;
    localparam [31:0] STACK_BASE = STACK_END - STACK_WORDS * 4;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg [31:0] boot_pc  = 32'd0;
    reg [31:0] text_end = 32'd0;

    // ---------------------------------------------------------------------
    // Device under test
    // ---------------------------------------------------------------------
    wire [31:0] imem_addr, imem_rdata;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire [3:0]  dmem_be;
    wire        dmem_req, dmem_we, dmem_fault;
    wire        ecall, ebreak, trap;
    wire [2:0]  trap_cause;
    wire        commit_valid, commit_rd_we, commit_mem_we;
    wire [31:0] commit_pc, commit_instr, commit_rd_wdata, commit_mem_addr, commit_mem_wdata;
    wire [4:0]  commit_rd;
    wire [1:0]  commit_mem_size;

    `TB_CORE dut (
        .clk              (clk),
        .rst              (rst),
        .boot_pc          (boot_pc),
        .imem_addr        (imem_addr),
        .imem_rdata       (imem_rdata),
        .dmem_addr        (dmem_addr),
        .dmem_req         (dmem_req),
        .dmem_be          (dmem_be),
        .dmem_we          (dmem_we),
        .dmem_wdata       (dmem_wdata),
        .dmem_rdata       (dmem_rdata),
        .dmem_fault       (dmem_fault),
        .ecall            (ecall),
        .ebreak           (ebreak),
        .trap             (trap),
        .trap_cause       (trap_cause),
        .commit_valid     (commit_valid),
        .commit_pc        (commit_pc),
        .commit_instr     (commit_instr),
        .commit_rd        (commit_rd),
        .commit_rd_we     (commit_rd_we),
        .commit_rd_wdata  (commit_rd_wdata),
        .commit_mem_we    (commit_mem_we),
        .commit_mem_addr  (commit_mem_addr),
        .commit_mem_wdata (commit_mem_wdata),
        .commit_mem_size  (commit_mem_size)
    );

    memory #(
        .ROM_WORDS   (ROM_WORDS),
        .DATA_WORDS  (DATA_WORDS),
        .STACK_WORDS (STACK_WORDS),
        .DATA_BASE   (DATA_BASE),
        .STACK_END   (STACK_END)
    ) mem (
        .clk     (clk),
        .i_addr  (imem_addr),
        .i_rdata (imem_rdata),
        .d_addr  (dmem_addr),
        .d_req   (dmem_req),
        .d_be    (dmem_be),
        .d_we    (dmem_we),
        .d_wdata (dmem_wdata),
        .d_rdata (dmem_rdata),
        .d_fault (dmem_fault)
    );

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------
    integer fd_trace, fd_out;
    integer retired;
    integer cycles;           // clock cycles since the end of reset
    integer cycles_retired;   // value of "cycles" when the last instruction retired
    integer idle;             // cycles since the last instruction boundary
    integer fd_stats;
    reg     want_stats;
    integer max_instr;
    reg     quiet;

    // Architectural register value (x0 reads as zero).
    function [31:0] xreg;
        input [4:0] n;
        begin
            xreg = (n == 5'd0) ? 32'd0 : dut.u_regfile.regs[n];
        end
    endfunction

    // One byte of memory, read directly from the memory arrays (used by the
    // print-string service).  Unmapped addresses read as 0, like rvsim.
    function [7:0] mem_byte;
        input [31:0] addr;
        reg   [31:0] word;
        begin
            if (addr < ROM_WORDS * 4)
                word = mem.rom[addr[31:2]];
            else if (addr - DATA_BASE < DATA_WORDS * 4)
                word = mem.dram[(addr - DATA_BASE) >> 2];
            else if (addr - STACK_BASE < STACK_WORDS * 4)
                word = mem.stack[(addr - STACK_BASE) >> 2];
            else
                word = 32'd0;
            mem_byte = word >> (8 * addr[1:0]);
        end
    endfunction

    // line_open: the echoed output does not end with a newline yet.
    reg line_open = 1'b0;

    task print_char;
        input [7:0] c;
        begin
            $fwrite(fd_out, "%c", c);
            if (!quiet) $write("%c", c);
            line_open = (c != 8'h0A);
        end
    endtask

    task print_int;
        input [31:0] v;
        begin
            $fwrite(fd_out, "%0d", $signed(v));
            if (!quiet) $write("%0d", $signed(v));
            line_open = 1'b1;
        end
    endtask

    task end_simulation;
        begin
            $fclose(fd_trace);
            $fclose(fd_out);
            if (want_stats) begin
                fd_stats = $fopen(stats_file, "w");
                $fwrite(fd_stats, "instructions %0d\ncycles %0d\n", retired, cycles_retired);
                $fclose(fd_stats);
            end
            if (!quiet && line_open) $write("\n");   // like "rvsim run"
            $finish(0);
        end
    endtask

    // Print the commit port in rvsim's trace format.
    task log_commit;
        begin
            $fwrite(fd_trace, "%08x %08x ", commit_pc, commit_instr);
            if (commit_rd_we)
                $fwrite(fd_trace, "x%0d=%08x ", commit_rd, commit_rd_wdata);
            else
                $fwrite(fd_trace, "- ");
            if (commit_mem_we) begin
                case (commit_mem_size)
                    `SIZE_BYTE: $fwrite(fd_trace, "M[%08x]=%02x/1", commit_mem_addr, commit_mem_wdata[7:0]);
                    `SIZE_HALF: $fwrite(fd_trace, "M[%08x]=%04x/2", commit_mem_addr, commit_mem_wdata[15:0]);
                    default:    $fwrite(fd_trace, "M[%08x]=%08x/4", commit_mem_addr, commit_mem_wdata);
                endcase
            end else begin
                $fwrite(fd_trace, "-");
            end
            $fwrite(fd_trace, "\n");
            retired = retired + 1;
            cycles_retired = cycles;
        end
    endtask

    // ---------------------------------------------------------------------
    // Set-up
    // ---------------------------------------------------------------------
    reg [1023:0] text_file, data_file, trace_file, out_file, stats_file;
    integer text_words, data_words;

    initial begin
        if (!$value$plusargs("text=%s", text_file) || !$value$plusargs("data=%s", data_file) ||
            !$value$plusargs("text_words=%d", text_words) || !$value$plusargs("data_words=%d", data_words) ||
            !$value$plusargs("entry=%h", boot_pc) || !$value$plusargs("text_end=%h", text_end) ||
            !$value$plusargs("trace=%s", trace_file) || !$value$plusargs("out=%s", out_file)) begin
            $display("tb_cpu: missing plusarg (see the header of sim/tb_cpu.v)");
            $finish(0);
        end
        if (!$value$plusargs("max=%d", max_instr))
            max_instr = 1000000;
        quiet      = $test$plusargs("quiet");
        want_stats = $value$plusargs("stats=%s", stats_file);
        retired        = 0;
        cycles         = 0;
        cycles_retired = 0;
        idle           = 0;

        fd_trace = $fopen(trace_file, "w");
        fd_out   = $fopen(out_file, "w");

        // Load the images after memory.v has cleared its arrays at time 0.
        #1;
        $readmemh(text_file, mem.rom, 0, text_words - 1);
        $readmemh(data_file, mem.dram, 0, data_words - 1);

        // Hold reset over two rising edges: pc <- entry, registers cleared.
        @(posedge clk);
        @(posedge clk);
        #1 rst = 1'b0;
    end

    // ---------------------------------------------------------------------
    // Instruction boundaries, examined on the falling edge
    // ---------------------------------------------------------------------
    reg [31:0] service, arg, p;

    always @(negedge clk) begin
        if (!rst) begin
            cycles = cycles + 1;
            idle   = idle + 1;
        end
        if (!rst && !(commit_valid || trap)) begin
            // Inside a multicycle instruction: nothing to do, unless the
            // core has stopped making progress.
            if (idle > HANG_CYCLES) begin
                $fwrite(fd_trace, "TRAP hang\n");
                end_simulation;
            end
        end else if (!rst) begin
            idle = 0;
            if (commit_pc == text_end) begin
                // Ran off the end of .text: normal termination.
                $fwrite(fd_trace, "HALT end-of-text\n");
                end_simulation;
            end else if (retired >= max_instr) begin
                $fwrite(fd_trace, "TIMEOUT\n");
                end_simulation;
            end else if (commit_pc > text_end || commit_pc[1:0] != 2'b00) begin
                $fwrite(fd_trace, "TRAP fetch\n");
                end_simulation;
            end else if (trap) begin
                case (trap_cause)
                    `TRAP_ILLEGAL:  $fwrite(fd_trace, "TRAP illegal-instruction\n");
                    `TRAP_MISALIGN: $fwrite(fd_trace, "TRAP misaligned-access\n");
                    `TRAP_JUMP:     $fwrite(fd_trace, "TRAP misaligned-jump\n");
                    `TRAP_BUS:      $fwrite(fd_trace, "TRAP bus-error\n");
                    default:        $fwrite(fd_trace, "TRAP unknown\n");
                endcase
                end_simulation;
            end else if (ecall) begin
                service = xreg(5'd17);   // a7
                arg     = xreg(5'd10);   // a0
                case (service)
                    32'd1:  begin print_int(arg); log_commit; end
                    32'd4:  begin
                                p = arg;
                                while (mem_byte(p) != 8'd0) begin
                                    print_char(mem_byte(p));
                                    p = p + 1;
                                end
                                log_commit;
                            end
                    32'd11: begin print_char(arg[7:0]); log_commit; end
                    32'd10: begin
                                log_commit;
                                $fwrite(fd_trace, "HALT exit 0\n");
                                end_simulation;
                            end
                    32'd93: begin
                                log_commit;
                                $fwrite(fd_trace, "HALT exit %0d\n", $signed(arg));
                                end_simulation;
                            end
                    default: begin
                                $fwrite(fd_trace, "TRAP ecall-service\n");
                                end_simulation;
                            end
                endcase
            end else begin
                log_commit;
                if (ebreak) begin
                    $fwrite(fd_trace, "HALT ebreak\n");
                    end_simulation;
                end
            end
        end
    end

endmodule
