`timescale 1ns/1ps
// load_unit: picks the addressed byte / halfword / word out of the 32-bit word
// that the data memory returns, and extends it to 32 bits for rd.
//
// Spec: RISC-V Unprivileged ISA v20260120, section 2.6 (p.33-34). LW loads 32 bits.
// LH loads 16 bits and sign-extends; LHU zero-extends; LB / LBU are the same
// for 8 bits. Little-endian: the lowest byte address holds the least-significant
// byte. funct3 values (LB 000, LH 001, LW 010, LBU 100, LHU 101) are from the
// RV32I listing, ch. 36, p.585.
//
//   addr_lo         :    3         2         1         0
//   rdata_word bits : [31:24]   [23:16]   [15:8]    [7:0]
//
// Misaligned LH/LHU (addr_lo 1 or 3) or LW (addr_lo != 0) is flagged and
// returns 0. section 2.6 (p.34) lets the environment handle a misaligned access or
// raise an exception; this core does neither, so they are out of scope.
module load_unit (
  input  logic [2:0]  funct3,      // 000 LB, 001 LH, 010 LW, 100 LBU, 101 LHU
  input  logic [1:0]  addr_lo,     // byte offset inside the word = addr[1:0]
  input  logic [31:0] rdata_word,  // the whole aligned word read from memory
  output logic [31:0] data,        // the value written to rd
  output logic        misaligned   // 1 = address not a multiple of the access size
);

  // Shift the word right by addr_lo * 8 bits so the addressed byte lands in
  // bits [7:0] (and, for a halfword, the byte above it lands in bits [15:8]).
  logic [31:0] shifted;
  assign shifted = rdata_word >> {addr_lo, 3'b000};

  // The four extended candidates. Sign-extend = copy the top bit upward.
  logic [31:0] lb_val, lbu_val, lh_val, lhu_val;
  assign lb_val  = {{24{shifted[7]}},  shifted[7:0]};
  assign lbu_val = {24'b0,             shifted[7:0]};
  assign lh_val  = {{16{shifted[15]}}, shifted[15:0]};
  assign lhu_val = {16'b0,             shifted[15:0]};

  // Naturally aligned = address divisible by the access size (section 2.6).
  logic half_aligned;
  logic word_aligned;
  assign half_aligned = (addr_lo[0] == 1'b0);   // offset 0 or 2
  assign word_aligned = (addr_lo == 2'b00);     // offset 0 only

  always_comb begin
    // Defaults: return 0. This also covers funct3 values that are not loads.
    data       = 32'h0000_0000;
    misaligned = 1'b0;

    case (funct3)
      3'b000: data = lb_val;                                  // LB
      3'b100: data = lbu_val;                                 // LBU

      3'b001: if (half_aligned) data = lh_val;                // LH
              else              misaligned = 1'b1;

      3'b101: if (half_aligned) data = lhu_val;               // LHU
              else              misaligned = 1'b1;

      3'b010: if (word_aligned) data = rdata_word;            // LW
              else              misaligned = 1'b1;

      default: ;                                              // 011, 110, 111: not a load
    endcase
  end

endmodule
