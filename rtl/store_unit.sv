`timescale 1ns/1ps
// store_unit: turns SB / SH / SW into the byte enables (be) and lane-placed
// write data (wdata) that the 32-bit-wide data memory needs.
//
// Spec: RISC-V Unprivileged ISA v20260120, section 2.6 (p.33-34). SW/SH/SB store the
// low 32/16/8 bits of rs2. Little-endian: the least-significant byte of rs2
// goes to the lowest byte address, the next byte to the next address, and so on.
// funct3 values (SB 000, SH 001, SW 010) are from the RV32I listing, ch. 36, p.585.
//
// The memory holds one word per row; addr_lo = addr[1:0] picks the byte lane:
//
//   addr_lo    :    3         2         1         0
//   wdata bits : [31:24]   [23:16]   [15:8]    [7:0]
//   be bit     :  be[3]     be[2]     be[1]     be[0]
//
// Misaligned SH (addr_lo 1 or 3) or SW (addr_lo != 0) is flagged and not
// written (be = 0). section 2.6 (p.34) lets the environment handle a misaligned access
// or raise an exception; this core does neither, so they are out of scope.
module store_unit (
  input  logic [2:0]  funct3,     // 000 SB, 001 SH, 010 SW
  input  logic [1:0]  addr_lo,    // byte offset inside the word = addr[1:0]
  input  logic [31:0] rs2,        // value to store; only the low 8/16/32 bits are used
  output logic [3:0]  be,         // byte enables: be[k] = 1 writes byte lane k
  output logic [31:0] wdata,      // rs2 moved into its lane(s), zero everywhere else
  output logic        misaligned  // 1 = address not a multiple of the access size
);

  // rs2's low byte / low halfword, zero-padded, then shifted left by
  // addr_lo * 8 bits so it sits in the addressed lane(s).
  logic [31:0] byte_in_lane;
  logic [31:0] half_in_lane;
  assign byte_in_lane = {24'b0, rs2[7:0]}  << {addr_lo, 3'b000};
  assign half_in_lane = {16'b0, rs2[15:0]} << {addr_lo, 3'b000};

  // Naturally aligned = address divisible by the access size (section 2.6).
  logic half_aligned;
  logic word_aligned;
  assign half_aligned = (addr_lo[0] == 1'b0);   // offset 0 or 2
  assign word_aligned = (addr_lo == 2'b00);     // offset 0 only

  always_comb begin
    // Defaults: write nothing. This also covers funct3 values that are not stores.
    be         = 4'b0000;
    wdata      = 32'h0000_0000;
    misaligned = 1'b0;

    case (funct3)
      3'b000: begin                          // SB: every byte address is aligned
        be    = 4'b0001 << addr_lo;
        wdata = byte_in_lane;
      end

      3'b001: begin                          // SH
        if (half_aligned) begin
          be    = 4'b0011 << addr_lo;
          wdata = half_in_lane;
        end else begin
          misaligned = 1'b1;
        end
      end

      3'b010: begin                          // SW
        if (word_aligned) begin
          be    = 4'b1111;
          wdata = rs2;
        end else begin
          misaligned = 1'b1;
        end
      end

      default: ;                             // 011, 1xx: not a store, write nothing
    endcase
  end

endmodule
