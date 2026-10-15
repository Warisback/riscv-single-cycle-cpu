`timescale 1ns/1ps
// branch_unit_tb: self-checking testbench for branch_unit.
//
// What the spec says (spec section 2.5.2, p.31-32): BEQ/BNE test rs1 == rs2 / rs1 != rs2;
// BLT/BGE test rs1 < rs2 / rs1 >= rs2 as SIGNED numbers; BLTU/BGEU do the same
// as UNSIGNED numbers. funct3 encodings: RV32I listing (spec ch. 36, p.585).
//
// The reference model below does not reuse the RTL's method ($signed, <, ==).
// It works from first principles of two's complement instead:
//   * equal         <=> x - y is zero
//   * unsigned x<y  <=> the 33-bit subtraction {0,x} - {0,y} borrows (bit 32 = 1)
//   * signed   x<y  <=> if the sign bits differ, the negative one (sign bit 1) is
//                       smaller; if they match, the unsigned answer is also right
//
// Three parts:
//   1. hand-worked golden table (expected bits typed in from the spec text)
//   2. every pair from a corner-value list x every funct3, checked by the model
//   3. seeded random tests (+seed=N, +n=N), biased so equal values and
//      sign-bit differences come up often
// Ends with exactly one line starting PASS or FAIL.
module branch_unit_tb;

  // ---------------- DUT ----------------
  logic [31:0] a, b;
  logic [2:0]  funct3;
  logic        taken;

  branch_unit dut (.a(a), .b(b), .funct3(funct3), .taken(taken));

  // ---------------- bookkeeping ----------------
  int seed;              // changes as $urandom(seed) is called
  int seed0;             // the starting seed, printed in the summary
  int n_random;          // number of random checks (+n=N), default 20000
  int errors   = 0;
  int checks   = 0;
  int directed = 0;      // checks done before the random part
  int n_taken     [8];   // random part: per funct3, how often the answer was 1
  int n_not_taken [8];   //                          ... and how often it was 0

  // The six real branch encodings, in the order used by the golden table.
  logic [2:0]  BR_F3  [6];
  // Values where comparisons usually go wrong: zero, +-1, the signed min/max
  // and their neighbours, and pairs that differ only in the lowest bit.
  logic [31:0] CORNER [14];

  // Icarus 12 rejects '{...} initialisers on unpacked arrays ("sorry: not yet
  // supported"), so the two tables are filled one element at a time.
  task automatic fill_tables();
    BR_F3[0] = 3'b000;  BR_F3[1] = 3'b001;               // BEQ  BNE
    BR_F3[2] = 3'b100;  BR_F3[3] = 3'b101;               // BLT  BGE
    BR_F3[4] = 3'b110;  BR_F3[5] = 3'b111;               // BLTU BGEU

    CORNER[0]  = 32'h0000_0000;  CORNER[1]  = 32'h0000_0001;
    CORNER[2]  = 32'h0000_0002;  CORNER[3]  = 32'h0000_0005;
    CORNER[4]  = 32'h7FFF_FFFE;  CORNER[5]  = 32'h7FFF_FFFF;   // largest positive numbers
    CORNER[6]  = 32'h8000_0000;  CORNER[7]  = 32'h8000_0001;   // most negative numbers
    CORNER[8]  = 32'hFFFF_FFFE;  CORNER[9]  = 32'hFFFF_FFFF;   // -2, -1
    CORNER[10] = 32'h1234_5678;  CORNER[11] = 32'h1234_5679;
    CORNER[12] = 32'h0000_FFFF;  CORNER[13] = 32'hFFFF_0000;
  endtask

  // ---------------- reference model ----------------
  function automatic logic ref_taken(input logic [2:0] f3, input logic [31:0] x, input logic [31:0] y);
    logic [32:0] diff;
    logic is_eq, is_ltu, is_lt;
    diff   = {1'b0, x} - {1'b0, y};             // bit 32 is the borrow
    is_eq  = (diff[31:0] == 32'd0);
    is_ltu = diff[32];
    is_lt  = (x[31] != y[31]) ? x[31] : is_ltu;
    case (f3)
      3'b000:  return  is_eq;    // BEQ
      3'b001:  return !is_eq;    // BNE
      3'b100:  return  is_lt;    // BLT
      3'b101:  return !is_lt;    // BGE
      3'b110:  return  is_ltu;   // BLTU
      3'b111:  return !is_ltu;   // BGEU
      default: return 1'b0;      // 010, 011: not a branch
    endcase
  endfunction

  function automatic string f3_name(input logic [2:0] f3);
    case (f3)
      3'b000:  return "BEQ";
      3'b001:  return "BNE";
      3'b100:  return "BLT";
      3'b101:  return "BGE";
      3'b110:  return "BLTU";
      3'b111:  return "BGEU";
      default: return "f3=01x";
    endcase
  endfunction

  // Drive one input set, wait for the logic to settle, compare.
  // !== also catches X or Z on the output.
  task automatic check(input logic [2:0] f3, input logic [31:0] x, input logic [31:0] y,
                       input logic expected);
    funct3 = f3;
    a      = x;
    b      = y;
    #1;
    checks++;
    if (taken !== expected) begin
      errors++;
      if (errors <= 20)
        $display("ERROR %-6s a=%h b=%h : taken=%b expected=%b", f3_name(f3), x, y, taken, expected);
    end
  endtask

  // Golden row: exp = expected bits for {BEQ, BNE, BLT, BGE, BLTU, BGEU},
  // worked out by hand. Also checks that the reference model agrees, so a
  // broken model cannot hide a broken DUT. funct3 010/011 must give 0.
  task automatic known(input logic [31:0] x, input logic [31:0] y, input logic [5:0] exp);
    for (int i = 0; i < 6; i++) begin
      check(BR_F3[i], x, y, exp[5 - i]);
      if (ref_taken(BR_F3[i], x, y) !== exp[5 - i]) begin
        errors++;
        $display("ERROR reference model disagrees with golden table: %s a=%h b=%h", f3_name(BR_F3[i]), x, y);
      end
    end
    check(3'b010, x, y, 1'b0);
    check(3'b011, x, y, 1'b0);
  endtask

  // ---------------- test sequence ----------------
  initial begin
    logic [31:0] ra, rb;
    logic [2:0]  rf3;
    logic        exp;

    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("n=%d", n_random)) n_random = 20000;
    seed0 = seed;
    fill_tables();

    // ---- 1. golden table ----           BEQ BNE BLT BGE BLTU BGEU
    known(32'h0000_0000, 32'h0000_0000, 6'b1___0___0___1___0____1);    // equal (zero)
    known(32'h0000_0005, 32'h0000_0005, 6'b1___0___0___1___0____1);    // equal
    known(32'hFFFF_FFFF, 32'hFFFF_FFFF, 6'b1___0___0___1___0____1);    // equal (-1)
    known(32'h8000_0000, 32'h8000_0000, 6'b1___0___0___1___0____1);    // equal (min int)
    known(32'h0000_0003, 32'h0000_0007, 6'b0___1___1___0___1____0);    // 3 < 7 both ways
    known(32'h0000_0007, 32'h0000_0003, 6'b0___1___0___1___0____1);    // 7 > 3 both ways
    known(32'hFFFF_FFFF, 32'h0000_0001, 6'b0___1___1___0___0____1);    // -1 < 1 signed, but 0xFFFFFFFF > 1 unsigned
    known(32'h0000_0001, 32'hFFFF_FFFF, 6'b0___1___0___1___1____0);    // 1 > -1 signed, but 1 < 0xFFFFFFFF unsigned
    known(32'h8000_0000, 32'h7FFF_FFFF, 6'b0___1___1___0___0____1);    // min < max signed; unsigned the other way
    known(32'h7FFF_FFFF, 32'h8000_0000, 6'b0___1___0___1___1____0);    // max > min signed; unsigned the other way
    known(32'hFFFF_FFFE, 32'hFFFF_FFFF, 6'b0___1___1___0___1____0);    // -2 < -1 both ways
    known(32'h8000_0000, 32'h0000_0000, 6'b0___1___1___0___0____1);    // min < 0 signed, > 0 unsigned

    // ---- 2. every corner pair x every funct3 (all 8, including 010/011) ----
    foreach (CORNER[i])
      foreach (CORNER[j])
        for (int f = 0; f < 8; f++)
          check(f[2:0], CORNER[i], CORNER[j], ref_taken(f[2:0], CORNER[i], CORNER[j]));

    directed = checks;

    // ---- 3. random ----
    for (int i = 0; i < n_random; i++) begin
      ra = $urandom(seed);
      case ($urandom(seed) % 4)
        0: rb = $urandom(seed);                               // unrelated values (almost never equal)
        1: rb = ra;                                           // equal: needed to hit BEQ taken / BNE not taken
        2: rb = ra ^ (32'd1 << ($urandom(seed) % 32));        // differ in exactly one bit (bit 31 flips the sign)
        default: begin                                        // two corner values
          ra = CORNER[$urandom(seed) % 14];
          rb = CORNER[$urandom(seed) % 14];
        end
      endcase
      rf3 = $urandom(seed) % 8;                               // all 8 funct3 values, invalid ones too
      exp = ref_taken(rf3, ra, rb);
      check(rf3, ra, rb, exp);
      if (exp) n_taken[rf3]++;
      else     n_not_taken[rf3]++;
    end

    // ---- coverage: each real branch must have been seen both taken and not taken ----
    for (int i = 0; i < 6; i++) begin
      if (n_taken[BR_F3[i]] == 0 || n_not_taken[BR_F3[i]] == 0) begin
        errors++;
        $display("ERROR coverage: %s random taken=%0d not_taken=%0d", f3_name(BR_F3[i]),
                 n_taken[BR_F3[i]], n_not_taken[BR_F3[i]]);
      end
    end
    $display("random coverage (taken/not taken): BEQ %0d/%0d  BNE %0d/%0d  BLT %0d/%0d  BGE %0d/%0d  BLTU %0d/%0d  BGEU %0d/%0d  f3=010 %0d/%0d  f3=011 %0d/%0d",
             n_taken[0], n_not_taken[0], n_taken[1], n_not_taken[1], n_taken[4], n_not_taken[4],
             n_taken[5], n_not_taken[5], n_taken[6], n_not_taken[6], n_taken[7], n_not_taken[7],
             n_taken[2], n_not_taken[2], n_taken[3], n_not_taken[3]);

    if (errors == 0)
      $display("PASS branch_unit_tb: %0d checks (%0d directed, %0d random), 0 errors, seed=%0d",
               checks, directed, checks - directed, seed0);
    else
      $display("FAIL branch_unit_tb: %0d errors in %0d checks (%0d directed, %0d random), seed=%0d",
               errors, checks, directed, checks - directed, seed0);
    $finish;
  end

endmodule
