// =============================================================================
// regfile.v -- the 32 general-purpose registers x0..x31
// =============================================================================
//
// Two asynchronous read ports (rs1 and rs2 are read in the same cycle as the
// instruction is fetched and decoded) and one synchronous write port (rd is
// written on the rising clock edge that ends the instruction).
//
// x0 is hard-wired to zero: the read ports return 0 for register 0 and the
// write port ignores writes to it, so "addi x0, ..." or "jal x0, ..." have no
// effect, exactly as the ISA requires.
//
// Because a single-cycle instruction reads its sources before the clock edge
// and writes its destination at the edge, "add x5, x5, x5" naturally reads
// the old value of x5: no bypassing is needed.
//
// Reset clears every register except sp (x2), which is initialised to the
// top of the stack so that programs can push frames immediately, matching
// the convention of the reference simulator.
// =============================================================================
`timescale 1ns / 1ps

module regfile #(
    parameter [31:0] SP_RESET = 32'h7FFF_FFF0   // initial stack pointer
) (
    input  wire        clk,
    input  wire        rst,        // synchronous, active high

    input  wire [4:0]  raddr1,     // rs1
    output wire [31:0] rdata1,
    input  wire [4:0]  raddr2,     // rs2
    output wire [31:0] rdata2,

    input  wire        we,         // write enable
    input  wire [4:0]  waddr,      // rd
    input  wire [31:0] wdata
);

    // regs[0] exists but is never written and never read.
    reg [31:0] regs [0:31];

    assign rdata1 = (raddr1 == 5'd0) ? 32'd0 : regs[raddr1];
    assign rdata2 = (raddr2 == 5'd0) ? 32'd0 : regs[raddr2];

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 32; i = i + 1)
                regs[i] <= 32'd0;
            regs[2] <= SP_RESET;
        end else if (we && waddr != 5'd0) begin
            regs[waddr] <= wdata;
        end
    end

endmodule
