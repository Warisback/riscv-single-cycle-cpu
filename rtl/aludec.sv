`timescale 1ns/1ps
// aludec: the ALU decoder. Turns alu_op (from maindec) plus the funct fields of
// the instruction into the 4-bit alu_ctrl the ALU understands.
//
//   alu_op   = ALUOP_ADD   -> always ADD (load/store address, LUI, AUIPC)
//   alu_op   = ALUOP_FUNCT -> decode funct3 / funct7 (OP and OP-IMM)
//   funct3   = instr[14:12]
//   funct7b5 = instr[30]  (funct7 bit 5: SUB vs ADD, SRA vs SRL)
//   opb5     = instr[5]   (1 = OP, register-register; 0 = OP-IMM)
//
// Why opb5 is needed: in OP-IMM, instr[30] is just bit 10 of the immediate,
// so "addi x1, x0, -1024" has instr[30]=1 and must still ADD. Only the
// register form (OP) has a SUB. For shifts, instr[30] really is the type bit
// in both forms (SRAI = 0100000 shamt, SRA = 0100000 rs2), so SRA/SRAI both
// look at funct7b5 alone. (Spec 2.4.1-2.4.2, pp. 28-29; listing p. 585-586.)
module aludec (
  input  logic [1:0] alu_op,
  input  logic [2:0] funct3,
  input  logic       funct7b5,
  input  logic       opb5,
  output logic [3:0] alu_ctrl
);
  import rv_pkg::*;

  always_comb begin
    case (alu_op)
      ALUOP_FUNCT: begin
        case (funct3)
          // SUB only for the register form (OP) with funct7 = 0100000
          3'b000:  alu_ctrl = (opb5 && funct7b5) ? ALU_SUB : ALU_ADD; // ADD/SUB/ADDI
          3'b001:  alu_ctrl = ALU_SLL;                         // SLL, SLLI
          3'b010:  alu_ctrl = ALU_SLT;                         // SLT, SLTI
          3'b011:  alu_ctrl = ALU_SLTU;                        // SLTU, SLTIU
          3'b100:  alu_ctrl = ALU_XOR;                         // XOR, XORI
          // right shifts: instr[30] picks arithmetic, in OP and OP-IMM alike
          3'b101:  alu_ctrl = funct7b5 ? ALU_SRA : ALU_SRL;   // SRL/SRA/SRLI/SRAI
          3'b110:  alu_ctrl = ALU_OR;                          // OR, ORI
          3'b111:  alu_ctrl = ALU_AND;                         // AND, ANDI
          default: alu_ctrl = ALU_ADD;                         // (unreachable)
        endcase
      end
      default: alu_ctrl = ALU_ADD;  // ALUOP_ADD (and unused codes 01, 11)
    endcase
  end

endmodule
