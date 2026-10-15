`timescale 1ns/1ps
// load_unit_tb: self-checking testbench for load_unit (plus a store->load
// round trip through store_unit, the way sc_core connects them).
//
// Reference model, written from the spec text (section 2.6, p.33-34), not from the RTL:
//   * LB/LBU read 1 byte, LH/LHU 2 bytes, LW 4 bytes.
//   * Little-endian: result byte i comes from memory byte address (addr + i).
//   * LB/LH sign-extend (copy the top loaded bit into every higher bit),
//     LBU/LHU zero-extend, LW is the whole word.
//   * Naturally aligned = addr divisible by the access size. In this design a
//     misaligned load is flagged and returns 0 (docs/DESIGN.md item 8).
//
// Tests:
//   1. Directed: hand-written expected values (they also check the model).
//   2. Directed patterns: every funct3 x addr_lo with corner memory words.
//   3. Seeded random: every funct3 x addr_lo with N_PER_CELL random words.
//   4. Round trip: store_unit writes rs2 into a random old word, load_unit
//      reads it back; the result must be rs2's low bytes, extended.
// Run: tools/run_unit.sh load_unit_tb [+seed=N]
module load_unit_tb;

  localparam int N_PER_CELL = 1000;   // random words per (funct3, addr_lo)
  localparam int N_ROUND    = 2000;   // round trips per (store size, aligned addr_lo)

  // load_unit (DUT) signals
  logic [2:0]  funct3;
  logic [1:0]  addr_lo;
  logic [31:0] rdata_word;
  logic [31:0] data;
  logic        misaligned;

  load_unit dut (
    .funct3(funct3), .addr_lo(addr_lo), .rdata_word(rdata_word),
    .data(data), .misaligned(misaligned)
  );

  // store_unit, used only by the round-trip test
  logic [2:0]  st_funct3;
  logic [31:0] st_rs2;
  logic [3:0]  st_be;
  logic [31:0] st_wdata;
  logic        st_misaligned;

  store_unit st (
    .funct3(st_funct3), .addr_lo(addr_lo), .rs2(st_rs2),
    .be(st_be), .wdata(st_wdata), .misaligned(st_misaligned)
  );

  int seed   = 1;      // random state: $urandom(seed) updates it on every call
  int seed0;           // the starting seed, kept for the summary line
  int errors = 0;
  int checks = 0;

  // ---------------- reference model ----------------
  // Number of bytes a load reads; 0 means "this funct3 is not a load".
  function automatic int load_bytes(input logic [2:0] f3);
    case (f3)
      3'b000, 3'b100: load_bytes = 1;   // LB, LBU
      3'b001, 3'b101: load_bytes = 2;   // LH, LHU
      3'b010:         load_bytes = 4;   // LW
      default:        load_bytes = 0;
    endcase
  endfunction

  // LB and LH sign-extend; everything else zero-extends (or needs no extension).
  function automatic logic load_signed(input logic [2:0] f3);
    load_signed = (f3 == 3'b000) || (f3 == 3'b001);
  endfunction

  task automatic ref_load(input  logic [2:0]  f3,
                          input  logic [1:0]  lo,
                          input  logic [31:0] word,
                          output logic [31:0] e_data,
                          output logic        e_mis);
    int   n;
    int   a;
    logic top;
    n      = load_bytes(f3);
    a      = lo;
    e_data = 32'h0;
    e_mis  = 1'b0;
    if (n != 0) begin
      if (a % n != 0) begin
        e_mis = 1'b1;                                   // not naturally aligned: 0
      end else begin
        for (int i = 0; i < n; i++)
          e_data[8*i +: 8] = word[8*(a + i) +: 8];      // result byte i = memory byte a+i
        top = e_data[8*n - 1];                          // highest bit actually loaded
        for (int b = 8*n; b < 32; b++)
          e_data[b] = load_signed(f3) ? top : 1'b0;     // sign- or zero-extend
      end
    end
  endtask

  // ---------------- checking ----------------
  task automatic apply_and_check(input logic [2:0] f3, input logic [1:0] lo,
                                 input logic [31:0] word, input string tag);
    logic [31:0] e_data;
    logic        e_mis;
    funct3     = f3;
    addr_lo    = lo;
    rdata_word = word;
    #1;
    ref_load(f3, lo, word, e_data, e_mis);
    checks++;
    if (data !== e_data || misaligned !== e_mis) begin
      errors++;
      if (errors <= 10)
        $display("ERROR [%s] funct3=%b addr_lo=%0d word=%h : got data=%h mis=%b, expected data=%h mis=%b",
                 tag, f3, lo, word, data, misaligned, e_data, e_mis);
    end
  endtask

  // Directed test with a hand-written expected answer; checks the model too.
  task automatic directed(input logic [2:0] f3, input logic [1:0] lo, input logic [31:0] word,
                          input logic [31:0] x_data, input logic x_mis, input string name);
    logic [31:0] e_data;
    logic        e_mis;
    ref_load(f3, lo, word, e_data, e_mis);
    checks++;
    if (e_data !== x_data || e_mis !== x_mis) begin
      errors++;
      $display("ERROR [model] %s: model says data=%h mis=%b, hand value data=%h mis=%b",
               name, e_data, e_mis, x_data, x_mis);
    end
    apply_and_check(f3, lo, word, name);
  endtask

  // One store->load round trip. The memory word starts as old_word; store_unit
  // writes value with store funct3 sf3; load_unit reads it back with load lf3.
  task automatic round_trip(input logic [2:0] sf3, input logic [2:0] lf3, input logic [1:0] lo,
                            input logic [31:0] old_word, input logic [31:0] value);
    logic [31:0] lane_mask;
    logic [31:0] new_word;
    logic [31:0] e_data;
    logic        e_mis;
    int          n;
    // store: merge only the enabled byte lanes into the old word (what dmem does)
    st_funct3 = sf3;
    st_rs2    = value;
    addr_lo   = lo;
    #1;
    lane_mask = {{8{st_be[3]}}, {8{st_be[2]}}, {8{st_be[1]}}, {8{st_be[0]}}};
    new_word  = (old_word & ~lane_mask) | (st_wdata & lane_mask);
    // load it back
    funct3     = lf3;
    rdata_word = new_word;
    #1;
    // expected: value's low n bytes, extended the way lf3 says
    n      = load_bytes(lf3);
    e_data = value;
    for (int b = 8*n; b < 32; b++)
      e_data[b] = load_signed(lf3) ? value[8*n - 1] : 1'b0;
    e_mis = 1'b0;
    checks++;
    if (data !== e_data || misaligned !== e_mis || st_misaligned !== 1'b0) begin
      errors++;
      if (errors <= 10)
        $display("ERROR [round trip] store %b / load %b addr_lo=%0d old=%h rs2=%h : got data=%h, expected %h",
                 sf3, lf3, lo, old_word, value, data, e_data);
    end
    // bytes the store did not enable must still hold the old memory contents
    checks++;
    for (int k = 0; k < 4; k++) begin
      if ((k < lo || k >= lo + n) && new_word[8*k +: 8] !== old_word[8*k +: 8]) begin
        errors++;
        if (errors <= 10)
          $display("ERROR [round trip] store %b addr_lo=%0d clobbered byte %0d", sf3, lo, k);
      end
    end
  endtask

  // Corner memory words. 32'h80FF7F01 holds bytes 01, 7F, FF, 80 at offsets
  // 0..3, i.e. small positive, largest positive, -1, most negative.
  localparam int N_PATTERNS = 9;
  function automatic logic [31:0] pattern(input int p);
    case (p)
      0:       pattern = 32'h0000_0000;
      1:       pattern = 32'hFFFF_FFFF;
      2:       pattern = 32'h80FF_7F01;
      3:       pattern = 32'h017F_FF80;
      4:       pattern = 32'h1234_5678;
      5:       pattern = 32'hDEAD_BEEF;
      6:       pattern = 32'h8000_8000;
      7:       pattern = 32'h7FFF_7FFF;
      default: pattern = 32'h0080_0080;
    endcase
  endfunction

  initial begin
    int f, lo, k, p;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    seed0 = seed;
    $display("load_unit_tb: seed=%0d", seed0);
    st_funct3 = 3'b111;   // store_unit idle (not a store) until the round trip
    st_rs2    = 32'h0;

    // ---- 1. directed, hand-computed. Memory word 0x80FF7F01:
    //         byte@0 = 01, byte@1 = 7F, byte@2 = FF, byte@3 = 80
    //        funct3  lo    word           expected data  mis
    directed(3'b000, 2'd0, 32'h80FF_7F01, 32'h0000_0001, 1'b0, "LB  @0 +1");
    directed(3'b000, 2'd1, 32'h80FF_7F01, 32'h0000_007F, 1'b0, "LB  @1 +127");
    directed(3'b000, 2'd2, 32'h80FF_7F01, 32'hFFFF_FFFF, 1'b0, "LB  @2 -1");
    directed(3'b000, 2'd3, 32'h80FF_7F01, 32'hFFFF_FF80, 1'b0, "LB  @3 -128");
    directed(3'b100, 2'd2, 32'h80FF_7F01, 32'h0000_00FF, 1'b0, "LBU @2 255");
    directed(3'b100, 2'd3, 32'h80FF_7F01, 32'h0000_0080, 1'b0, "LBU @3 128");
    directed(3'b001, 2'd0, 32'h80FF_7F01, 32'h0000_7F01, 1'b0, "LH  @0 positive");
    directed(3'b001, 2'd2, 32'h80FF_7F01, 32'hFFFF_80FF, 1'b0, "LH  @2 negative");
    directed(3'b101, 2'd2, 32'h80FF_7F01, 32'h0000_80FF, 1'b0, "LHU @2");
    directed(3'b010, 2'd0, 32'h80FF_7F01, 32'h80FF_7F01, 1'b0, "LW  @0");
    directed(3'b001, 2'd1, 32'h80FF_7F01, 32'h0000_0000, 1'b1, "LH  @1 misaligned");
    directed(3'b001, 2'd3, 32'h80FF_7F01, 32'h0000_0000, 1'b1, "LH  @3 misaligned");
    directed(3'b101, 2'd1, 32'h80FF_7F01, 32'h0000_0000, 1'b1, "LHU @1 misaligned");
    directed(3'b101, 2'd3, 32'h80FF_7F01, 32'h0000_0000, 1'b1, "LHU @3 misaligned");
    directed(3'b010, 2'd1, 32'h80FF_7F01, 32'h0000_0000, 1'b1, "LW  @1 misaligned");
    directed(3'b010, 2'd2, 32'h80FF_7F01, 32'h0000_0000, 1'b1, "LW  @2 misaligned");
    directed(3'b010, 2'd3, 32'h80FF_7F01, 32'h0000_0000, 1'b1, "LW  @3 misaligned");
    directed(3'b011, 2'd0, 32'hFFFF_FFFF, 32'h0000_0000, 1'b0, "funct3 011 not a load");
    directed(3'b110, 2'd0, 32'hFFFF_FFFF, 32'h0000_0000, 1'b0, "funct3 110 not a load");
    directed(3'b111, 2'd0, 32'hFFFF_FFFF, 32'h0000_0000, 1'b0, "funct3 111 not a load");

    // ---- 2. corner patterns over every funct3 x addr_lo ----
    for (f = 0; f < 8; f++)
      for (lo = 0; lo < 4; lo++)
        for (p = 0; p < N_PATTERNS; p++)
          apply_and_check(f[2:0], lo[1:0], pattern(p), "pattern");

    // ---- 3. seeded random words over every funct3 x addr_lo ----
    for (f = 0; f < 8; f++)
      for (lo = 0; lo < 4; lo++)
        for (k = 0; k < N_PER_CELL; k++)
          apply_and_check(f[2:0], lo[1:0], $urandom(seed), "random");

    // ---- 4. store -> load round trips at every aligned address ----
    for (k = 0; k < N_ROUND; k++) begin
      for (lo = 0; lo < 4; lo++) begin
        round_trip(3'b000, 3'b000, lo[1:0], $urandom(seed), $urandom(seed));  // SB -> LB
        round_trip(3'b000, 3'b100, lo[1:0], $urandom(seed), $urandom(seed));  // SB -> LBU
      end
      for (lo = 0; lo < 4; lo += 2) begin
        round_trip(3'b001, 3'b001, lo[1:0], $urandom(seed), $urandom(seed));  // SH -> LH
        round_trip(3'b001, 3'b101, lo[1:0], $urandom(seed), $urandom(seed));  // SH -> LHU
      end
      round_trip(3'b010, 3'b010, 2'd0, $urandom(seed), $urandom(seed));       // SW -> LW
    end

    if (errors == 0)
      $display("PASS load_unit_tb: %0d checks, 0 errors (seed=%0d)", checks, seed0);
    else
      $display("FAIL load_unit_tb: %0d checks, %0d errors (seed=%0d)", checks, errors, seed0);
    $finish;
  end

endmodule
