// =============================================================================
// branch_unit.v -- branch condition evaluation
// =============================================================================
//
// Compares rs1 with rs2 according to funct3 of a conditional branch and says
// whether the branch is taken.  The datapath combines "taken" with the
// "branch" control signal, so the output is meaningless for other opcodes.
//
//   funct3  instruction  condition
//   000     beq          rs1 == rs2
//   001     bne          rs1 != rs2
//   100     blt          rs1 <  rs2   (signed)
//   101     bge          rs1 >= rs2   (signed)
//   110     bltu         rs1 <  rs2   (unsigned)
//   111     bgeu         rs1 >= rs2   (unsigned)
//
// Each pair (beq/bne, blt/bge, bltu/bgeu) shares one comparator: funct3[0]
// simply inverts the result.  A separate comparator instead of reusing the
// ALU lets the ALU and the branch decision work in parallel.
// =============================================================================
`timescale 1ns / 1ps

module branch_unit (
    input  wire [2:0]  funct3,
    input  wire [31:0] rs1,
    input  wire [31:0] rs2,
    output reg         taken
);

    wire equal         = (rs1 == rs2);
    wire less_signed   = ($signed(rs1) < $signed(rs2));
    wire less_unsigned = (rs1 < rs2);

    reg condition;

    always @(*) begin
        case (funct3[2:1])
            2'b00:   condition = equal;          // beq / bne
            2'b10:   condition = less_signed;    // blt / bge
            2'b11:   condition = less_unsigned;  // bltu / bgeu
            default: condition = 1'b0;           // reserved (flagged as illegal by control)
        endcase
        taken = condition ^ funct3[0];           // odd funct3 = negated condition
    end

endmodule
