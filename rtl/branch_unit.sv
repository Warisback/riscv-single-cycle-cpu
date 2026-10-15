`timescale 1ns/1ps
// branch_unit: decides whether a conditional branch is taken.
//
// RISC-V Unprivileged ISA v20260120, spec section 2.5.2 (p.31-32):
//   BEQ/BNE   take the branch if rs1 == rs2 / rs1 != rs2
//   BLT/BGE   take the branch if rs1 <  rs2 / rs1 >= rs2, signed compare
//   BLTU/BGEU take the branch if rs1 <  rs2 / rs1 >= rs2, unsigned compare
// funct3 values come from the RV32I listing (spec ch. 36, p.585).
// funct3 = 010 and 011 are not branches; this design returns taken = 0.
//
// In the single-cycle core it compares the rs1/rs2 values read from the
// register file in the same cycle (rtl/sc_core.sv).
module branch_unit (
  input  logic [31:0] a,       // rs1 value
  input  logic [31:0] b,       // rs2 value
  input  logic [2:0]  funct3,  // instr[14:12], picks the comparison
  output logic        taken    // 1 = branch condition is true
);

  // Only three comparators are needed: the other three branches are
  // just the opposite answer (BNE = !BEQ, BGE = !BLT, BGEU = !BLTU).
  logic eq;    // a == b
  logic lt;    // a <  b, both read as two's-complement signed numbers
  logic ltu;   // a <  b, both read as unsigned numbers

  assign eq  = (a == b);
  assign lt  = ($signed(a) < $signed(b));  // $signed changes how the bits are read, not the bits
  assign ltu = (a < b);                    // logic vectors compare unsigned by default

  always_comb begin
    case (funct3)
      3'b000:  taken =  eq;    // BEQ
      3'b001:  taken = ~eq;    // BNE
      3'b100:  taken =  lt;    // BLT
      3'b101:  taken = ~lt;    // BGE  (>= is "not less than")
      3'b110:  taken =  ltu;   // BLTU
      3'b111:  taken = ~ltu;   // BGEU
      default: taken = 1'b0;   // 010, 011: not a branch, never taken
    endcase
  end

endmodule
