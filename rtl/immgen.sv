`timescale 1ns/1ps
// immgen: build the 32-bit immediate an instruction carries.
//
// RISC-V scatters immediate bits across the instruction so that rs1, rs2 and rd
// never move (spec section 2.2) and the sign bit is always instr[31]. This block
// gathers the pieces back together for the format the main decoder asks for.
// Bit placement follows "Base instruction formats immediate variants" and
// "Types of immediate produced by RISC-V instructions" (spec section 2.3).
//
// In hardware this is only wires plus a 5-input mux: all five immediates are
// built in parallel, and imm_src picks one.
module immgen (
  input  logic [31:7] instr,    // instruction bits 31..7 (the opcode, 6..0, holds no immediate bits)
  input  logic [2:0]  imm_src,  // which format to build: IMM_I/S/B/U/J from rv_pkg
  output logic [31:0] imm_ext   // the immediate, sign-extended to 32 bits
);
  import rv_pkg::*;

  logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;

  // I-type (OP-IMM, loads, JALR): imm[11:0] = instr[31:20]
  assign imm_i = {{20{instr[31]}}, instr[31:20]};

  // S-type (stores): imm[11:5] = instr[31:25], imm[4:0] = instr[11:7]
  assign imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};

  // B-type (branches): imm[12|10:5] = instr[31:25], imm[4:1|11] = instr[11:7].
  // imm[0] is always 0 (branch offsets are multiples of 2).
  assign imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};

  // U-type (LUI, AUIPC): imm[31:12] = instr[31:12], the low 12 bits are 0
  assign imm_u = {instr[31:12], 12'b0};

  // J-type (JAL): imm[20|10:1|11|19:12] = instr[31:12]. imm[0] is always 0.
  assign imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

  // The mux: pick the format the decoder asked for.
  always_comb begin
    case (imm_src)
      IMM_I:   imm_ext = imm_i;
      IMM_S:   imm_ext = imm_s;
      IMM_B:   imm_ext = imm_b;
      IMM_U:   imm_ext = imm_u;
      IMM_J:   imm_ext = imm_j;
      default: imm_ext = 32'b0;   // 101, 110, 111 are not used by any instruction
    endcase
  end

endmodule
