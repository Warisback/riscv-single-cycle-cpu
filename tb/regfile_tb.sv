`timescale 1ns/1ps
// regfile_tb: self-checking testbench for the single-cycle register file.
//   Reference model: a plain array `model` updated with the same rule the spec
//   gives (x0 reads 0, writes to x0 ignored) and nothing else from the RTL.
//   Inputs change on the falling edge; reads are checked just before each
//   rising edge (old value must still be there) and just after it (new value).
// Run:  tools/run_unit.sh regfile_tb [+seed=N] [+n=CYCLES]
module regfile_tb;

  logic        clk = 0, rst;
  logic [4:0]  ra1, ra2, wa;
  logic [31:0] rd1, rd2, wd;
  logic        we;

  regfile dut (.*);

  always #5 clk = ~clk;

  logic [31:0] model [0:31];
  int errors = 0, checks = 0, n = 20000, seed = 1, seed0;

  function automatic logic [31:0] ref_read(input logic [4:0] a);
    return (a == 5'd0) ? 32'd0 : model[a];
  endfunction

  task automatic check_reads(input string when);
    // White-box check: the storage behind x0 must stay 0. The read ports always
    // return 0 for x0, so a write that slipped into regs[0] is invisible at the
    // ports; only looking inside catches it (tools/regfile_mut.sh plants that bug).
    checks++;
    if (dut.regs[0] !== 32'd0) begin
      errors++;
      if (errors <= 10) $display("ERROR %s: regs[0] holds %h, x0 storage must stay 0", when, dut.regs[0]);
    end
    checks += 2;
    if (rd1 !== ref_read(ra1)) begin
      errors++;
      if (errors <= 10) $display("ERROR %s: ra1=x%0d rd1=%h expected %h", when, ra1, rd1, ref_read(ra1));
    end
    if (rd2 !== ref_read(ra2)) begin
      errors++;
      if (errors <= 10) $display("ERROR %s: ra2=x%0d rd2=%h expected %h", when, ra2, rd2, ref_read(ra2));
    end
  endtask

  // One clock cycle: set inputs on the falling edge, check the read before the
  // rising edge, update the model at the edge, check again after it.
  task automatic cycle(input logic w, input logic [4:0] a_w, input logic [31:0] d,
                       input logic [4:0] a1, input logic [4:0] a2);
    @(negedge clk);
    we = w; wa = a_w; wd = d; ra1 = a1; ra2 = a2;
    #4 check_reads("before edge");           // same-cycle read sees the old value (no bypass)
    @(posedge clk);
    if (w && a_w != 5'd0) model[a_w] = d;
    #1 check_reads("after edge");
  endtask

  initial begin
    if ($value$plusargs("seed=%d", seed)) ;
    if ($value$plusargs("n=%d", n)) ;
    seed0 = seed;
    for (int i = 0; i < 32; i++) model[i] = 32'd0;

    // reset: every register reads 0 afterwards
    rst = 1; we = 0; wa = 0; wd = 0; ra1 = 0; ra2 = 0;
    @(posedge clk); #1 rst = 0;
    for (int r = 0; r < 32; r++) cycle(0, 0, 0, r[4:0], r[4:0]);

    // directed: write every register with a distinct value, read it back on both ports
    for (int r = 1; r < 32; r++) cycle(1, r[4:0], 32'hA5A5_0000 | r, 0, 0);
    for (int r = 0; r < 32; r++) cycle(0, 0, 0, r[4:0], 5'd31 - r[4:0]);

    // directed: x0 ignores writes
    cycle(1, 0, 32'hDEAD_BEEF, 0, 0);
    cycle(0, 0, 0, 0, 0);

    // directed: write and read the same register in one cycle (rd == rs1 == rs2)
    cycle(1, 5'd7, 32'h1234_5678, 5'd7, 5'd7);
    cycle(1, 5'd7, 32'h0BAD_F00D, 5'd7, 5'd7);

    // directed: we=0 must not write
    cycle(0, 5'd9, 32'hFFFF_FFFF, 5'd9, 5'd9);

    // random traffic over all registers, including x0 and same-cycle collisions
    for (int i = 0; i < n; i++)
      cycle($urandom(seed) % 4 != 0, $urandom(seed) % 32, $urandom(seed),
            $urandom(seed) % 32, $urandom(seed) % 32);

    // reset in the middle of traffic clears everything again
    @(negedge clk) rst = 1; we = 0;
    @(posedge clk); for (int i = 0; i < 32; i++) model[i] = 32'd0;
    #1 rst = 0;
    for (int r = 0; r < 32; r++) cycle(0, 0, 0, r[4:0], r[4:0]);

    if (errors == 0) $display("PASS regfile_tb: %0d checks, 0 errors, seed=%0d", checks, seed0);
    else             $display("FAIL regfile_tb: %0d checks, %0d errors, seed=%0d", checks, errors, seed0);
    $finish;
  end

  initial begin
    #10_000_000;
    $display("FAIL regfile_tb: timeout");
    $finish;
  end

endmodule
