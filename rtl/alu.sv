`timescale 1ns/1ps
// alu: the arithmetic/logic unit of the processor.
// Implements the ten RV32I integer operations of spec section 2.4 (ADD, SUB, AND, OR,
// XOR, SLT, SLTU, SLL, SRL, SRA). The same ALU serves the register-immediate
// (OP-IMM) and register-register (OP) forms; the decoder just picks b = imm or rs2.
// It is also used for address arithmetic (loads/stores), LUI (a = 0) and AUIPC (a = pc).
// Purely combinational: y follows a, b and alu_ctrl with no clock.
module alu (
  input  logic [31:0] a,         // operand A: rs1, pc or 0
  input  logic [31:0] b,         // operand B: rs2 or the immediate
  input  logic [3:0]  alu_ctrl,  // which operation (ALU_* in rv_pkg)
  output logic [31:0] y          // result
);
  import rv_pkg::*;

  // Shifts use only the low 5 bits of the shift amount (spec section 2.4.1, section 2.4.2).
  // Upper bits of b are ignored, so "shift by 32" is the same as "shift by 0".
  logic [4:0] shamt;
  assign shamt = b[4:0];

  always_comb begin
    case (alu_ctrl)
      ALU_ADD:  y = a + b;                         // overflow ignored: keep low 32 bits
      ALU_SUB:  y = a - b;                         // a minus b, low 32 bits
      ALU_AND:  y = a & b;
      ALU_OR:   y = a | b;
      ALU_XOR:  y = a ^ b;
      ALU_SLT:  y = {31'b0, $signed(a) < $signed(b)};  // signed compare -> 0 or 1
      ALU_SLTU: y = {31'b0, a < b};                    // unsigned compare -> 0 or 1
      ALU_SLL:  y = a << shamt;                    // zeros shifted in at the bottom
      ALU_SRL:  y = a >> shamt;                    // zeros shifted in at the top
      ALU_SRA:  y = $signed(a) >>> shamt;          // copies of a[31] shifted in at the top
      default:  y = 32'b0;                         // unused codes 10..15
    endcase
  end

endmodule
