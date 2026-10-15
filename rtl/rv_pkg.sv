`timescale 1ns/1ps
// rv_pkg: every encoding the core and its testbenches agree on.
// Opcode values come from the RISC-V Unprivileged ISA (v20260120), ch. 2 and the
// opcode map in the instruction-set listings chapter. Everything else (ImmSrc,
// ALU control, mux selects) is this design's own choice.
package rv_pkg;

  // ---- RV32I major opcodes (instr[6:0]) ----
  localparam logic [6:0] OP_LUI    = 7'b0110111;
  localparam logic [6:0] OP_AUIPC  = 7'b0010111;
  localparam logic [6:0] OP_JAL    = 7'b1101111;
  localparam logic [6:0] OP_JALR   = 7'b1100111;
  localparam logic [6:0] OP_BRANCH = 7'b1100011;
  localparam logic [6:0] OP_LOAD   = 7'b0000011;
  localparam logic [6:0] OP_STORE  = 7'b0100011;
  localparam logic [6:0] OP_IMM    = 7'b0010011;
  localparam logic [6:0] OP_OP     = 7'b0110011;
  localparam logic [6:0] OP_FENCE  = 7'b0001111;  // executed as a NOP
  localparam logic [6:0] OP_SYSTEM = 7'b1110011;  // ECALL/EBREAK: executed as a NOP

  // ---- ImmSrc: which immediate format immgen builds ----
  localparam logic [2:0] IMM_I = 3'b000;
  localparam logic [2:0] IMM_S = 3'b001;
  localparam logic [2:0] IMM_B = 3'b010;
  localparam logic [2:0] IMM_U = 3'b011;
  localparam logic [2:0] IMM_J = 3'b100;

  // ---- ALU control ----
  localparam logic [3:0] ALU_ADD  = 4'd0;
  localparam logic [3:0] ALU_SUB  = 4'd1;
  localparam logic [3:0] ALU_AND  = 4'd2;
  localparam logic [3:0] ALU_OR   = 4'd3;
  localparam logic [3:0] ALU_XOR  = 4'd4;
  localparam logic [3:0] ALU_SLT  = 4'd5;
  localparam logic [3:0] ALU_SLTU = 4'd6;
  localparam logic [3:0] ALU_SLL  = 4'd7;
  localparam logic [3:0] ALU_SRL  = 4'd8;
  localparam logic [3:0] ALU_SRA  = 4'd9;

  // ---- ALUOp: main decoder -> ALU decoder ----
  localparam logic [1:0] ALUOP_ADD   = 2'b00;  // address / LUI / AUIPC: always add
  localparam logic [1:0] ALUOP_FUNCT = 2'b10;  // OP and OP-IMM: decode funct3/funct7

  // ---- ALU operand A select ----
  localparam logic [1:0] SRCA_RS1  = 2'b00;
  localparam logic [1:0] SRCA_PC   = 2'b01;    // AUIPC
  localparam logic [1:0] SRCA_ZERO = 2'b10;    // LUI

  // ---- Write-back result select ----
  localparam logic [1:0] RES_ALU = 2'b00;
  localparam logic [1:0] RES_MEM = 2'b01;      // loads
  localparam logic [1:0] RES_PC4 = 2'b10;      // JAL / JALR link value

  // ---- Memory map ----
  localparam int          MEM_WORDS   = 16384;          // 64 KiB, addresses 0x0000-0xFFFF
  localparam logic [31:0] TOHOST_ADDR = 32'h0000_FFF0;  // a store here ends the test

endpackage
