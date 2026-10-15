`timescale 1ns/1ps
// alu_adv_tb: adversarial check of rtl/alu.sv against an independent oracle.
//
// The expected values are not computed in SystemVerilog. tools/alu_adv_gen.py
// computes them with Python integers (two different ways that must agree) and
// writes them to a $readmemh file:
//   word 0            N = number of vectors
//   words 1+4k..4+4k  vector k: alu_ctrl, a, b, expected y
//   word 1+4N         end marker 32'hE0F0_E0F0
//
// Pass 1 applies every vector in file order (this includes the generator's
// directed corner blocks and its "only one input changes" blocks).
// Pass 2 replays N vectors picked at random with $urandom(seed), so the DUT
// also sees arbitrary jumps between unrelated inputs.
//
// Run:    tools/alu_adv_run.sh [seed]     (generates vectors, then runs)
//         plusargs: +seed=N  +vec=<file>
module alu_adv_tb;
  import rv_pkg::*;

  localparam int          MAX_VEC      = 400000;
  localparam int          MAX_WORDS    = 1 + 4 * MAX_VEC + 1;
  localparam logic [31:0] END_MARK     = 32'hE0F0_E0F0;
  localparam int          MIN_PER_CODE = 2000;   // the generator promises at least this

  // ---- DUT ----
  logic [31:0] a, b, y;
  logic [3:0]  alu_ctrl;

  alu dut (.a(a), .b(b), .alu_ctrl(alu_ctrl), .y(y));

  // ---- vectors and bookkeeping ----
  logic [31:0] vec [0:MAX_WORDS-1];
  string       vec_file = "build/alu_adv_vectors.hex";
  int          seed = 1;          // +seed=N
  int          seed0;
  int          n_vec = 0;
  int          errors = 0;
  int          file_checks = 0;   // pass 1
  int          rand_checks = 0;   // pass 2
  int          per_code [0:15];   // pass-1 checks per alu_ctrl code
  int          min_code;

  // Apply vector k, wait for the combinational ALU to settle, compare.
  task automatic run_vector(input int k, input bit is_random);
    logic [31:0] c, x, z, want;
    c    = vec[1 + 4*k];
    x    = vec[2 + 4*k];
    z    = vec[3 + 4*k];
    want = vec[4 + 4*k];
    // (Icarus 12 cannot "return" from a task, hence the if/else.)
    if ($isunknown({c, x, z, want}) || c > 32'd15) begin
      errors++;
      if (errors <= 20) $display("ERROR bad vector %0d in %s", k, vec_file);
    end else begin
      alu_ctrl = c[3:0];
      a        = x;
      b        = z;
      #1;
      if (y !== want) begin
        errors++;
        if (errors <= 20)
          $display("ERROR vec %0d (%s) ctrl=%0d a=%h b=%h : dut y=%h, oracle %h",
                   k, is_random ? "replay" : "file  ", c, x, z, y, want);
      end
      if (is_random) rand_checks++;
      else begin
        file_checks++;
        per_code[c[3:0]]++;
      end
    end
  endtask

  // Watchdog: the ALU has no clock, but a broken DUT or file must not hang the run.
  initial begin
    #50_000_000;   // 50 ms; a full run needs about 0.1 ms
    $display("FAIL alu_adv_tb: timeout after 50 ms of sim time, %0d errors so far", errors);
    $finish;
  end

  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("vec=%s", vec_file));
    seed0 = seed;
    for (int i = 0; i < 16; i++) per_code[i] = 0;

    // The memory is sized for MAX_VEC vectors, so Icarus warns "Not enough
    // words in the file"; that is expected. Unread words stay X.
    $readmemh(vec_file, vec);

    // ---- sanity of the vector file ----
    if ($isunknown(vec[0]) || vec[0] == 0 || vec[0] > MAX_VEC) begin
      $display("FAIL alu_adv_tb: cannot use vector file %s (header %h)", vec_file, vec[0]);
      $finish;
    end
    n_vec = vec[0];
    if (vec[1 + 4*n_vec] !== END_MARK) begin
      $display("FAIL alu_adv_tb: %s truncated: no end marker after %0d vectors", vec_file, n_vec);
      $finish;
    end

    // ---- pass 1: file order ----
    for (int k = 0; k < n_vec; k++)
      run_vector(k, 1'b0);

    // ---- pass 2: seeded random replay ----
    void'($urandom(seed));               // first draw is weak for small seeds
    for (int k = 0; k < n_vec; k++)
      run_vector(int'($urandom(seed) % n_vec), 1'b1);

    // every code must really have been exercised
    min_code = per_code[0];
    for (int i = 1; i < 16; i++)
      if (per_code[i] < min_code) min_code = per_code[i];
    if (min_code < MIN_PER_CODE) begin
      errors++;
      $display("ERROR only %0d vectors for some alu_ctrl code (need %0d)", min_code, MIN_PER_CODE);
    end

    if (errors == 0)
      $display("PASS alu_adv_tb: %0d checks (%0d file-order + %0d random-replay of %0d Python-oracle vectors, min %0d per alu_ctrl code), 0 errors, seed=%0d",
               file_checks + rand_checks, file_checks, rand_checks, n_vec, min_code, seed0);
    else
      $display("FAIL alu_adv_tb: %0d errors in %0d checks (%0d file-order, %0d random-replay), seed=%0d",
               errors, file_checks + rand_checks, file_checks, rand_checks, seed0);
    $finish;
  end

endmodule
