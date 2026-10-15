`timescale 1ns/1ps
// maindec: the main decoder. Looks only at the 7-bit opcode (instr[6:0]) and
// produces the control signals that steer the datapath for that instruction.
//
// Opcode values: RISC-V Unprivileged ISA v20260120, RV32I listing (ch. 36,
// pp. 585-586) and the base opcode map (Table 72, p. 584), via rv_pkg.
//
// Convention used in this design: every output starts at 0, and each opcode
// turns on only the controls it really needs. So a control an instruction does
// not care about is always 0 (never X), and an unknown opcode gives all 0 plus
// illegal=1, so it changes no state and acts like a NOP.
module maindec (
  input  logic [6:0] opcode,
  output logic       reg_write,   // 1: write the result to rd
  output logic [1:0] result_src,  // RES_ALU / RES_MEM / RES_PC4
  output logic       mem_write,   // 1: store
  output logic       branch,      // 1: conditional branch (BEQ..BGEU)
  output logic       jump,        // 1: JAL only
  output logic       jalr,        // 1: JALR only
  output logic [1:0] alu_src_a,   // SRCA_RS1 / SRCA_PC / SRCA_ZERO
  output logic       alu_src_b,   // 0: rs2, 1: immediate
  output logic [2:0] imm_src,     // IMM_I / IMM_S / IMM_B / IMM_U / IMM_J
  output logic [1:0] alu_op,      // ALUOP_ADD or ALUOP_FUNCT (see aludec)
  output logic       uses_rs1,    // 1: instruction reads rs1 (not needed by this datapath;
                                  //    checked by maindec_tb and decoder_adv_tb)
  output logic       uses_rs2,    // 1: instruction reads rs2 (same)
  output logic       illegal      // opcode is not an RV32I opcode
);
  import rv_pkg::*;

  always_comb begin
    // Defaults: "do nothing". Each case below only lists what it switches on.
    reg_write  = 1'b0;
    result_src = RES_ALU;
    mem_write  = 1'b0;
    branch     = 1'b0;
    jump       = 1'b0;
    jalr       = 1'b0;
    alu_src_a  = SRCA_RS1;
    alu_src_b  = 1'b0;
    imm_src    = 3'b000;    // same bits as IMM_I; ignored when no imm is used
    alu_op     = ALUOP_ADD;
    uses_rs1   = 1'b0;
    uses_rs2   = 1'b0;
    illegal    = 1'b0;

    case (opcode)
      OP_LUI: begin              // rd = 0 + U-imm
        reg_write = 1'b1;
        alu_src_a = SRCA_ZERO;
        alu_src_b = 1'b1;
        imm_src   = IMM_U;
      end
      OP_AUIPC: begin            // rd = pc + U-imm
        reg_write = 1'b1;
        alu_src_a = SRCA_PC;
        alu_src_b = 1'b1;
        imm_src   = IMM_U;
      end
      OP_JAL: begin              // rd = pc+4; pc = pc + J-imm (target adder)
        reg_write  = 1'b1;
        result_src = RES_PC4;
        jump       = 1'b1;
        imm_src    = IMM_J;
      end
      OP_JALR: begin             // rd = pc+4; pc = (rs1 + I-imm) & ~1
        reg_write  = 1'b1;
        result_src = RES_PC4;
        jalr       = 1'b1;
        imm_src    = IMM_I;
        uses_rs1   = 1'b1;
      end
      OP_BRANCH: begin           // if (rs1 ? rs2) pc = pc + B-imm
        branch   = 1'b1;
        imm_src  = IMM_B;
        uses_rs1 = 1'b1;
        uses_rs2 = 1'b1;
      end
      OP_LOAD: begin             // rd = mem[rs1 + I-imm]
        reg_write  = 1'b1;
        result_src = RES_MEM;
        alu_src_b  = 1'b1;
        imm_src    = IMM_I;
        uses_rs1   = 1'b1;
      end
      OP_STORE: begin            // mem[rs1 + S-imm] = rs2
        mem_write = 1'b1;
        alu_src_b = 1'b1;
        imm_src   = IMM_S;
        uses_rs1  = 1'b1;
        uses_rs2  = 1'b1;
      end
      OP_IMM: begin              // rd = rs1 op I-imm  (ADDI, SLTI, ..., SRAI)
        reg_write = 1'b1;
        alu_src_b = 1'b1;
        imm_src   = IMM_I;
        alu_op    = ALUOP_FUNCT;
        uses_rs1  = 1'b1;
      end
      OP_OP: begin               // rd = rs1 op rs2    (ADD, SUB, ..., AND)
        reg_write = 1'b1;
        alu_op    = ALUOP_FUNCT;
        uses_rs1  = 1'b1;
        uses_rs2  = 1'b1;
      end
      OP_FENCE,                  // legal, executed as a NOP (single hart,
      OP_SYSTEM: begin           // no caches); ECALL/EBREAK also NOPs here
        // nothing to switch on: all defaults (0) are already right
      end
      default: begin
        illegal = 1'b1;          // not RV32I: all controls stay 0
      end
    endcase
  end

endmodule
