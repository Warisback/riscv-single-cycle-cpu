`timescale 1ns/1ps
// store_unit_tb: self-checking testbench for store_unit.
//
// Reference model, written from the spec text (section 2.6, p.33-34), not from the RTL:
//   * SB/SH/SW store n = 1/2/4 bytes taken from the low bits of rs2.
//   * Little-endian: rs2 byte i goes to memory byte address (addr + i).
//   * An access is naturally aligned when addr is divisible by n.
// In this design a misaligned store is flagged and writes nothing, and wdata
// must be zero in every byte lane whose be bit is 0 (docs/DESIGN.md item 7).
//
// Tests:
//   1. Directed: hand-written expected values (they also check the model).
//   2. Directed patterns: every funct3 x addr_lo with corner data values.
//   3. Seeded random: every funct3 x addr_lo with N_PER_CELL random rs2 values.
// Run: tools/run_unit.sh store_unit_tb [+seed=N]
module store_unit_tb;

  localparam int N_PER_CELL = 1000;   // random rs2 values per (funct3, addr_lo)

  // DUT signals
  logic [2:0]  funct3;
  logic [1:0]  addr_lo;
  logic [31:0] rs2;
  logic [3:0]  be;
  logic [31:0] wdata;
  logic        misaligned;

  store_unit dut (
    .funct3(funct3), .addr_lo(addr_lo), .rs2(rs2),
    .be(be), .wdata(wdata), .misaligned(misaligned)
  );

  int seed   = 1;      // random state: $urandom(seed) updates it on every call
  int seed0;           // the starting seed, kept for the summary line
  int errors = 0;
  int checks = 0;

  // ---------------- reference model ----------------
  // Number of bytes a store writes; 0 means "this funct3 is not a store".
  function automatic int store_bytes(input logic [2:0] f3);
    case (f3)
      3'b000:  store_bytes = 1;   // SB
      3'b001:  store_bytes = 2;   // SH
      3'b010:  store_bytes = 4;   // SW
      default: store_bytes = 0;
    endcase
  endfunction

  task automatic ref_store(input  logic [2:0]  f3,
                           input  logic [1:0]  lo,
                           input  logic [31:0] value,
                           output logic [3:0]  e_be,
                           output logic [31:0] e_wdata,
                           output logic        e_mis);
    int n;
    int a;
    n       = store_bytes(f3);
    a       = lo;
    e_be    = 4'b0000;
    e_wdata = 32'h0;
    e_mis   = 1'b0;
    if (n != 0) begin
      if (a % n != 0) begin
        e_mis = 1'b1;                              // not naturally aligned: no write
      end else begin
        for (int i = 0; i < n; i++) begin
          e_be[a + i]               = 1'b1;          // memory byte a+i is written ...
          e_wdata[8*(a + i) +: 8]   = value[8*i +: 8]; // ... with rs2 byte i
        end
      end
    end
  endtask

  // ---------------- checking ----------------
  // Apply inputs, wait for the combinational logic, compare with the model.
  task automatic apply_and_check(input logic [2:0] f3, input logic [1:0] lo,
                                 input logic [31:0] value, input string tag);
    logic [3:0]  e_be;
    logic [31:0] e_wdata;
    logic        e_mis;
    funct3  = f3;
    addr_lo = lo;
    rs2     = value;
    #1;
    ref_store(f3, lo, value, e_be, e_wdata, e_mis);
    checks++;
    if (be !== e_be || wdata !== e_wdata || misaligned !== e_mis) begin
      errors++;
      if (errors <= 10)
        $display("ERROR [%s] funct3=%b addr_lo=%0d rs2=%h : got be=%b wdata=%h mis=%b, expected be=%b wdata=%h mis=%b",
                 tag, f3, lo, value, be, wdata, misaligned, e_be, e_wdata, e_mis);
    end
    // Contract rule stated on its own: every byte lane with be[k]=0 must be zero.
    checks++;
    for (int k = 0; k < 4; k++) begin
      if (be[k] !== 1'b1 && wdata[8*k +: 8] !== 8'h00) begin
        errors++;
        if (errors <= 10)
          $display("ERROR [%s] funct3=%b addr_lo=%0d: lane %0d has be=0 but wdata byte=%h",
                   tag, f3, lo, k, wdata[8*k +: 8]);
      end
    end
  endtask

  // Directed test with a hand-written expected answer. It checks both the DUT and
  // the reference model, so a mistake in the model cannot hide a DUT bug.
  task automatic directed(input logic [2:0] f3, input logic [1:0] lo, input logic [31:0] value,
                          input logic [3:0] x_be, input logic [31:0] x_wdata, input logic x_mis,
                          input string name);
    logic [3:0]  e_be;
    logic [31:0] e_wdata;
    logic        e_mis;
    ref_store(f3, lo, value, e_be, e_wdata, e_mis);
    checks++;
    if (e_be !== x_be || e_wdata !== x_wdata || e_mis !== x_mis) begin
      errors++;
      $display("ERROR [model] %s: model says be=%b wdata=%h mis=%b, hand value be=%b wdata=%h mis=%b",
               name, e_be, e_wdata, e_mis, x_be, x_wdata, x_mis);
    end
    apply_and_check(f3, lo, value, name);
  endtask

  // Corner data values: all zeros, all ones, lone sign bits, distinct bytes.
  localparam int N_PATTERNS = 9;
  function automatic logic [31:0] pattern(input int p);
    case (p)
      0:       pattern = 32'h0000_0000;
      1:       pattern = 32'hFFFF_FFFF;
      2:       pattern = 32'h8000_0000;
      3:       pattern = 32'h7FFF_FFFF;
      4:       pattern = 32'h1234_5678;
      5:       pattern = 32'hDEAD_BEEF;
      6:       pattern = 32'h0000_00FF;
      7:       pattern = 32'h0000_8080;
      default: pattern = 32'hA5A5_5A5A;
    endcase
  endfunction

  initial begin
    int f, lo, k, p;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    seed0 = seed;
    $display("store_unit_tb: seed=%0d", seed0);

    // ---- 1. directed, hand-computed (rs2 = 0x12345678 shows which byte went where) ----
    //            funct3  lo    rs2           be       wdata          mis
    directed(3'b000, 2'd0, 32'h1234_5678, 4'b0001, 32'h0000_0078, 1'b0, "SB @0");
    directed(3'b000, 2'd1, 32'h1234_5678, 4'b0010, 32'h0000_7800, 1'b0, "SB @1");
    directed(3'b000, 2'd2, 32'h1234_5678, 4'b0100, 32'h0078_0000, 1'b0, "SB @2");
    directed(3'b000, 2'd3, 32'h1234_5678, 4'b1000, 32'h7800_0000, 1'b0, "SB @3");
    directed(3'b001, 2'd0, 32'h1234_5678, 4'b0011, 32'h0000_5678, 1'b0, "SH @0");
    directed(3'b001, 2'd2, 32'h1234_5678, 4'b1100, 32'h5678_0000, 1'b0, "SH @2");
    directed(3'b001, 2'd1, 32'h1234_5678, 4'b0000, 32'h0000_0000, 1'b1, "SH @1 misaligned");
    directed(3'b001, 2'd3, 32'h1234_5678, 4'b0000, 32'h0000_0000, 1'b1, "SH @3 misaligned");
    directed(3'b010, 2'd0, 32'h1234_5678, 4'b1111, 32'h1234_5678, 1'b0, "SW @0");
    directed(3'b010, 2'd1, 32'h1234_5678, 4'b0000, 32'h0000_0000, 1'b1, "SW @1 misaligned");
    directed(3'b010, 2'd2, 32'h1234_5678, 4'b0000, 32'h0000_0000, 1'b1, "SW @2 misaligned");
    directed(3'b010, 2'd3, 32'h1234_5678, 4'b0000, 32'h0000_0000, 1'b1, "SW @3 misaligned");
    directed(3'b000, 2'd3, 32'hFFFF_FF80, 4'b1000, 32'h8000_0000, 1'b0, "SB high bits dropped");
    directed(3'b001, 2'd2, 32'hFFFF_8001, 4'b1100, 32'h8001_0000, 1'b0, "SH high bits dropped");
    directed(3'b011, 2'd0, 32'hFFFF_FFFF, 4'b0000, 32'h0000_0000, 1'b0, "funct3 011 not a store");
    directed(3'b100, 2'd0, 32'hFFFF_FFFF, 4'b0000, 32'h0000_0000, 1'b0, "funct3 100 not a store");

    // ---- 2. corner patterns over every funct3 x addr_lo ----
    for (f = 0; f < 8; f++)
      for (lo = 0; lo < 4; lo++)
        for (p = 0; p < N_PATTERNS; p++)
          apply_and_check(f[2:0], lo[1:0], pattern(p), "pattern");

    // ---- 3. seeded random rs2 over every funct3 x addr_lo ----
    for (f = 0; f < 8; f++)
      for (lo = 0; lo < 4; lo++)
        for (k = 0; k < N_PER_CELL; k++)
          apply_and_check(f[2:0], lo[1:0], $urandom(seed), "random");

    if (errors == 0)
      $display("PASS store_unit_tb: %0d checks, 0 errors (seed=%0d)", checks, seed0);
    else
      $display("FAIL store_unit_tb: %0d checks, %0d errors (seed=%0d)", checks, errors, seed0);
    $finish;
  end

endmodule
