`timescale 1ns/1ps
// alu_tb: self-checking testbench for rtl/alu.sv.
//
// The reference model ref_alu() is written from the wording of spec section 2.4, not
// copied from the RTL:
//   - ADD, SUB, SLT, SLTU work on the numeric values of the operands, held in
//     64-bit longints (so nothing can overflow inside the model), and keep the
//     low 32 bits of the true result, as the spec says.
//   - AND, OR, XOR and the three shifts are built one result bit at a time.
//
// Three groups of tests:
//   1. known answers worked out by hand; these check both the DUT and the model
//   2. every pair from a list of corner values, for all 16 alu_ctrl codes
//   3. seeded random tests, n_random per alu_ctrl code (all 16 codes)
//
// Run:  tools/run_unit.sh alu_tb [+seed=N] [+n=N]
module alu_tb;
  import rv_pkg::*;

  // ---- DUT ----
  logic [31:0] a, b, y;
  logic [3:0]  alu_ctrl;

  alu dut (.a(a), .b(b), .alu_ctrl(alu_ctrl), .y(y));

  // ---- bookkeeping ----
  int seed = 1;            // +seed=N; $urandom(seed) advances it on every call
  int seed0;               // the seed we started from, for the summary line
  int n_random = 10000;    // +n=N random tests per alu_ctrl code
  int errors = 0;
  int directed_checks = 0;
  int random_checks = 0;
  int slt_sltu_differ = 0; // random cases where signed and unsigned order disagree
  int sra_srl_differ = 0;  // random cases where SRA and SRL give different results

  localparam longint TWO_POW_32 = 64'sd4294967296;

  // ================= reference model (spec section 2.4) =================

  // The number a 32-bit pattern stands for when read as UNSIGNED: 0 .. 2^32-1.
  function automatic longint unsigned_value(input logic [31:0] x);
    longint v;
    v = x;                 // x is unsigned, so the upper 32 bits fill with 0
    return v;
  endfunction

  // The number a 32-bit pattern stands for in two's complement: -2^31 .. 2^31-1.
  // Bit 31 has weight -2^31 instead of +2^31, i.e. subtract 2^32 when it is set.
  function automatic longint signed_value(input logic [31:0] x);
    if (x[31]) return unsigned_value(x) - TWO_POW_32;
    else       return unsigned_value(x);
  endfunction

  // Keep the low 32 bits of an exact result ("the low XLEN bits", spec section 2.4.2).
  function automatic logic [31:0] low32(input longint v);
    return v[31:0];
  endfunction

  function automatic logic [31:0] ref_alu(input logic [3:0] op,
                                          input logic [31:0] x,
                                          input logic [31:0] z);
    logic [31:0] r;
    int sh;
    sh = z[4:0];           // shift amount = lower 5 bits of rs2 / the immediate
    r  = 32'b0;
    case (op)
      ALU_ADD:  r = low32(unsigned_value(x) + unsigned_value(z));
      ALU_SUB:  r = low32(unsigned_value(x) - unsigned_value(z));
      ALU_SLT:  r = (signed_value(x)   < signed_value(z))   ? 32'd1 : 32'd0;
      ALU_SLTU: r = (unsigned_value(x) < unsigned_value(z)) ? 32'd1 : 32'd0;
      ALU_AND:  for (int i = 0; i < 32; i++) r[i] = (x[i] == 1'b1) && (z[i] == 1'b1);
      ALU_OR:   for (int i = 0; i < 32; i++) r[i] = (x[i] == 1'b1) || (z[i] == 1'b1);
      ALU_XOR:  for (int i = 0; i < 32; i++) r[i] = (x[i] != z[i]);
      // result bit i comes from source bit i-sh (left) or i+sh (right);
      // a bit position with no source gets 0, or the sign bit for SRA
      ALU_SLL:  for (int i = 0; i < 32; i++) r[i] = (i - sh >= 0)  ? x[i - sh] : 1'b0;
      ALU_SRL:  for (int i = 0; i < 32; i++) r[i] = (i + sh <= 31) ? x[i + sh] : 1'b0;
      ALU_SRA:  for (int i = 0; i < 32; i++) r[i] = (i + sh <= 31) ? x[i + sh] : x[31];
      default:  r = 32'b0; // codes 10..15 are unused: docs/DESIGN.md says output 0
    endcase
    return r;
  endfunction

  function automatic string op_name(input logic [3:0] op);
    case (op)
      ALU_ADD: return "ADD";   ALU_SUB:  return "SUB";
      ALU_AND: return "AND";   ALU_OR:   return "OR";
      ALU_XOR: return "XOR";   ALU_SLT:  return "SLT";
      ALU_SLTU: return "SLTU"; ALU_SLL:  return "SLL";
      ALU_SRL: return "SRL";   ALU_SRA:  return "SRA";
      default: return "UNUSED";
    endcase
  endfunction

  // ================= checking tasks =================

  // Drive the DUT, wait for it to settle, compare with the expected value.
  task automatic drive_and_compare(input logic [3:0] op, input logic [31:0] x,
                                   input logic [31:0] z, input logic [31:0] expected);
    alu_ctrl = op;
    a = x;
    b = z;
    #1;
    if (y !== expected) begin
      errors++;
      if (errors <= 20)
        $display("ERROR %-6s a=%h b=%h : dut y=%h, expected %h", op_name(op), x, z, y, expected);
    end
  endtask

  // Group 1: a hand-worked answer. Checks the model first, then the DUT.
  task automatic known(input logic [3:0] op, input logic [31:0] x,
                       input logic [31:0] z, input logic [31:0] answer);
    if (ref_alu(op, x, z) !== answer) begin
      errors++;
      $display("MODEL ERROR %-6s a=%h b=%h : model=%h, hand answer %h",
               op_name(op), x, z, ref_alu(op, x, z), answer);
    end
    drive_and_compare(op, x, z, answer);
    directed_checks++;
  endtask

  // Groups 2 and 3: the model gives the expected value.
  task automatic check(input logic [3:0] op, input logic [31:0] x, input logic [31:0] z,
                       input bit is_random);
    drive_and_compare(op, x, z, ref_alu(op, x, z));
    if (is_random) random_checks++;
    else           directed_checks++;
  endtask

  // ================= corner values =================
  // Used for both a and b. The first five are the classic integer edges; 31/32/33
  // and the last four test that shifts only look at b[4:0]: 0xFFFFFFE0 has low
  // bits 0, and 0x41F is what SRAI rd, rs1, 31 puts on b (imm bit 10 marks SRA).
  // (A function, because Icarus 12 cannot initialise an unpacked array with '{...}.)
  localparam int N_CORNERS = 12;
  function automatic logic [31:0] corner(input int i);
    case (i)
      0:       return 32'h0000_0000;
      1:       return 32'h0000_0001;
      2:       return 32'hFFFF_FFFF;   // -1
      3:       return 32'h7FFF_FFFF;   // largest positive
      4:       return 32'h8000_0000;   // most negative
      5:       return 32'd31;
      6:       return 32'd32;
      7:       return 32'd33;
      8:       return 32'hFFFF_FFE0;
      9:       return 32'h0000_041F;
      10:      return 32'hF000_0000;
      default: return 32'h1234_5678;
    endcase
  endfunction

  // ================= random operand generator =================
  // Mostly uniform random, but often a corner value, a small signed number or a
  // single set bit, because those are where carries, signs and shifts go wrong.
  function automatic logic [31:0] rand_operand();
    logic [31:0] r;
    case ($urandom(seed) % 8)
      0:       r = corner($urandom(seed) % N_CORNERS);
      1:       r = 32'($signed(5'($urandom(seed))));   // -16 .. 15
      2:       r = 32'h1 << ($urandom(seed) % 32);     // one bit set
      default: r = $urandom(seed);                     // any 32-bit value
    endcase
    return r;
  endfunction

  // ================= the test =================
  initial begin
    logic [31:0] ra, rb;
    logic [3:0]  op;

    // optional command-line overrides; the variable keeps its default if absent
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("n=%d", n_random));
    seed0 = seed;

    // ---------- group 1: hand-worked answers ----------
    // ADD / SUB: overflow ignored, low 32 bits kept (spec section 2.4.1, section 2.4.2)
    known(ALU_ADD, 32'h7FFF_FFFF, 32'h0000_0001, 32'h8000_0000); // signed overflow wraps
    known(ALU_ADD, 32'hFFFF_FFFF, 32'h0000_0001, 32'h0000_0000); // carry out dropped
    known(ALU_ADD, 32'h8000_0000, 32'h8000_0000, 32'h0000_0000);
    known(ALU_ADD, 32'h0000_0005, 32'hFFFF_FFFD, 32'h0000_0002); // 5 + (-3), like ADDI
    known(ALU_SUB, 32'h0000_0000, 32'h0000_0001, 32'hFFFF_FFFF); // 0 - 1 = -1
    known(ALU_SUB, 32'h8000_0000, 32'h0000_0001, 32'h7FFF_FFFF); // most negative - 1 wraps
    known(ALU_SUB, 32'h0000_0001, 32'hFFFF_FFFF, 32'h0000_0002); // 1 - (-1)
    known(ALU_SUB, 32'h7FFF_FFFF, 32'hFFFF_FFFF, 32'h8000_0000); // max - (-1) wraps
    // logic
    known(ALU_AND, 32'hF0F0_F0F0, 32'hFF00_FF00, 32'hF000_F000);
    known(ALU_OR,  32'hF0F0_F0F0, 32'hFF00_FF00, 32'hFFF0_FFF0);
    known(ALU_XOR, 32'hF0F0_F0F0, 32'hFF00_FF00, 32'h0FF0_0FF0);
    known(ALU_XOR, 32'h1234_5678, 32'hFFFF_FFFF, 32'hEDCB_A987); // XORI rd,rs1,-1 = NOT
    // SLT vs SLTU: same bits, different order
    known(ALU_SLT,  32'hFFFF_FFFF, 32'h0000_0001, 32'd1); // -1 < 1
    known(ALU_SLTU, 32'hFFFF_FFFF, 32'h0000_0001, 32'd0); // 4294967295 > 1
    known(ALU_SLT,  32'h0000_0001, 32'hFFFF_FFFF, 32'd0);
    known(ALU_SLTU, 32'h0000_0001, 32'hFFFF_FFFF, 32'd1);
    known(ALU_SLT,  32'h8000_0000, 32'h7FFF_FFFF, 32'd1); // most negative < most positive
    known(ALU_SLTU, 32'h8000_0000, 32'h7FFF_FFFF, 32'd0); // 2^31 > 2^31-1
    known(ALU_SLT,  32'h7FFF_FFFF, 32'h8000_0000, 32'd0);
    known(ALU_SLTU, 32'h7FFF_FFFF, 32'h8000_0000, 32'd1);
    known(ALU_SLT,  32'h8000_0000, 32'h0000_0000, 32'd1);
    known(ALU_SLTU, 32'h8000_0000, 32'h0000_0000, 32'd0);
    known(ALU_SLT,  32'hFFFF_FFFE, 32'hFFFF_FFFF, 32'd1); // -2 < -1: here they agree
    known(ALU_SLTU, 32'hFFFF_FFFE, 32'hFFFF_FFFF, 32'd1);
    known(ALU_SLT,  32'h0000_0005, 32'h0000_0005, 32'd0); // equal is not less
    known(ALU_SLTU, 32'h8000_0000, 32'h8000_0000, 32'd0);
    known(ALU_SLTU, 32'h0000_0000, 32'h0000_0007, 32'd1); // SNEZ: sltu rd, x0, rs2
    known(ALU_SLTU, 32'h0000_0000, 32'h0000_0000, 32'd0);
    known(ALU_SLTU, 32'h0000_0000, 32'h0000_0001, 32'd1); // SEQZ: sltiu rd, rs1, 1
    known(ALU_SLTU, 32'h0000_0009, 32'h0000_0001, 32'd0);
    // shifts: only b[4:0] counts
    known(ALU_SLL, 32'h0000_0001, 32'd0,  32'h0000_0001);
    known(ALU_SLL, 32'h0000_0001, 32'd31, 32'h8000_0000);
    known(ALU_SLL, 32'h0000_0001, 32'd32, 32'h0000_0001); // 32 -> shamt 0
    known(ALU_SLL, 32'h0000_0001, 32'd33, 32'h0000_0002); // 33 -> shamt 1
    known(ALU_SLL, 32'hFFFF_FFFF, 32'hFFFF_FFE0, 32'hFFFF_FFFF); // low 5 bits are 0
    known(ALU_SLL, 32'h8000_0001, 32'd1,  32'h0000_0002); // top bit falls off
    known(ALU_SRL, 32'h8000_0000, 32'd31, 32'h0000_0001);
    known(ALU_SRA, 32'h8000_0000, 32'd31, 32'hFFFF_FFFF);
    known(ALU_SRL, 32'hF000_0000, 32'd4,  32'h0F00_0000); // zeros come in
    known(ALU_SRA, 32'hF000_0000, 32'd4,  32'hFF00_0000); // copies of the sign come in
    known(ALU_SRA, 32'h7000_0000, 32'd4,  32'h0700_0000); // positive: same as SRL
    known(ALU_SRL, 32'h8000_0000, 32'd32, 32'h8000_0000); // 32 -> no shift
    known(ALU_SRA, 32'h8000_0000, 32'd32, 32'h8000_0000);
    known(ALU_SRL, 32'h8000_0000, 32'd33, 32'h4000_0000); // 33 -> shift by 1
    known(ALU_SRA, 32'h8000_0000, 32'd33, 32'hC000_0000);
    known(ALU_SRL, 32'hFFFF_FFFF, 32'd31, 32'h0000_0001);
    known(ALU_SRA, 32'hFFFF_FFFF, 32'd31, 32'hFFFF_FFFF);
    known(ALU_SRA, 32'h8000_0000, 32'h0000_041F, 32'hFFFF_FFFF); // SRAI imm: bit 10 set, shamt 31
    known(ALU_SRL, 32'h8000_0000, 32'h0000_041F, 32'h0000_0001);
    known(ALU_SRA, 32'hFFFF_FFF0, 32'd2,  32'hFFFF_FFFC); // -16 >> 2 = -4
    known(ALU_SRA, 32'hFFFF_FFF1, 32'd2,  32'hFFFF_FFFC); // -15 >> 2 = -4 (rounds down)
    // unused codes always give 0
    for (int c = 10; c < 16; c++)
      known(4'(c), 32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'h0000_0000);

    // ---------- group 2: every corner pair, every code ----------
    for (int c = 0; c < 16; c++)
      for (int i = 0; i < N_CORNERS; i++)
        for (int j = 0; j < N_CORNERS; j++)
          check(4'(c), corner(i), corner(j), 1'b0);

    // ---------- group 3: seeded random ----------
    // Throw away the first draw: in Icarus 12 it is weak for small seeds
    // (seed 5 gives 0x00054600, seed 6 gives 0x00065400).
    void'($urandom(seed));
    for (int c = 0; c < 16; c++) begin
      op = 4'(c);
      for (int k = 0; k < n_random; k++) begin
        ra = rand_operand();
        // 1 in 16: equal operands (the SLT/SLTU "not less" edge)
        rb = ($urandom(seed) % 16 == 0) ? ra : rand_operand();
        check(op, ra, rb, 1'b1);
        if (op == ALU_SLT && ref_alu(ALU_SLT, ra, rb) !== ref_alu(ALU_SLTU, ra, rb))
          slt_sltu_differ++;
        if (op == ALU_SRA && ref_alu(ALU_SRA, ra, rb) !== ref_alu(ALU_SRL, ra, rb))
          sra_srl_differ++;
      end
    end

    $display("INFO random: SLT and SLTU disagreed on %0d of %0d SLT cases; SRA and SRL differed on %0d of %0d SRA cases",
             slt_sltu_differ, n_random, sra_srl_differ, n_random);
    if (errors == 0)
      $display("PASS alu_tb: %0d checks (%0d directed, %0d random = %0d per alu_ctrl code), 0 errors, seed=%0d",
               directed_checks + random_checks, directed_checks, random_checks, n_random, seed0);
    else
      $display("FAIL alu_tb: %0d errors in %0d checks (%0d directed, %0d random), seed=%0d",
               errors, directed_checks + random_checks, directed_checks, random_checks, seed0);
    $finish;
  end

endmodule
