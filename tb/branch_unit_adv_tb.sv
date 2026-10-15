`timescale 1ns/1ps
// branch_unit_adv_tb: adversarial check of branch_unit against an oracle in a
// different language. tools/branch_unit_adv_gen.py (Python, explicit signed
// conversion) writes the vectors AND the expected answers; this TB only
// applies them and compares. It contains no model of its own.
//
// Vector file (+vec=<file>, default build/branch_unit_adv_vectors.hex), one
// 72-bit word per line: [71:68] funct3, [67:36] a, [35:4] b, [3:0] expected.
// Sentinel line: [71:68] = F, [67:36] = number of vectors before it.
// Count file <vec>_count.hex holds the same number; both must agree.
// Run with tools/branch_unit_adv_run.sh [seed] (generates, then runs).
//
// Pass 1 applies every vector in file order (corner grid x grid x all 8 funct3,
// x vs x+-1 neighbours, Python-seeded random).
// Pass 2 replays +n=N vectors (default 50000) picked with $urandom(seed),
// +seed=N, so the DUT sees the same answers after different previous inputs
// (a latch or any hidden state would show up here).
module branch_unit_adv_tb;

  localparam int MAXV = 262144;

  logic [71:0] vec [MAXV];
  logic [31:0] a, b;
  logic [2:0]  funct3;
  logic        taken;

  branch_unit dut (.a(a), .b(b), .funct3(funct3), .taken(taken));

  string vecfile, cntfile;
  logic [31:0] cnt [1];     // vector count written by the generator
  int    seed, seed0, n_replay;
  int    nvec      = 0;
  int    errors    = 0;
  int    checks    = 0;
  int    in_order  = 0;
  logic  bad       = 1'b0;  // set when the vector file has a broken line
  int    n_taken     [8];   // from the oracle's expected bit, pass 1
  int    n_not_taken [8];

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

  // Apply vector i and compare. !== also fails on X/Z.
  task automatic apply(input int i);
    logic [2:0] f3;
    logic       exp;
    f3     = vec[i][70:68];
    exp    = vec[i][0];
    funct3 = f3;
    a      = vec[i][67:36];
    b      = vec[i][35:4];
    #1;
    checks++;
    if (taken !== exp) begin
      errors++;
      if (errors <= 20)
        $display("ERROR vec %0d %-6s a=%h b=%h : taken=%b expected=%b",
                 i, f3_name(f3), a, b, taken, exp);
    end
  endtask

  initial begin
    if (!$value$plusargs("vec=%s", vecfile)) vecfile = "build/branch_unit_adv_vectors.hex";
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("n=%d", n_replay)) n_replay = 50000;
    seed0 = seed;

    // The generator also writes <vecfile minus .hex>_count.hex: one word, the
    // number of vectors. Reading exactly [0:count] (vectors + sentinel) keeps
    // $readmemh from warning about a short file.
    cntfile = {vecfile.substr(0, vecfile.len() - 5), "_count.hex"};
    $readmemh(cntfile, cnt);
    if ($isunknown(cnt[0]) || cnt[0] == 0 || cnt[0] >= MAXV) begin
      errors++;
      $display("ERROR count file %s unreadable or out of range: %h", cntfile, cnt[0]);
    end else
      $readmemh(vecfile, vec, 0, cnt[0]);

    // ---- find the sentinel, reject unreadable lines (Icarus 12 has no 'break') ----
    while (!bad && nvec < MAXV && vec[nvec][71:68] !== 4'hF) begin
      if ($isunknown(vec[nvec]) || vec[nvec][71] !== 1'b0 || vec[nvec][3:1] !== 3'b000) begin
        errors++;
        bad = 1'b1;
        $display("ERROR vector file line %0d is missing or malformed: %h", nvec, vec[nvec]);
      end else
        nvec++;
    end
    if (nvec == MAXV || vec[nvec][71:68] !== 4'hF || vec[nvec][67:36] !== nvec || cnt[0] !== nvec) begin
      errors++;
      $display("ERROR vector file: sentinel missing or count wrong (read %0d vectors)", nvec);
    end
    if (nvec == 0) begin
      errors++;
      $display("ERROR vector file %s gave no vectors", vecfile);
    end

    // ---- pass 1: every vector, file order ----
    for (int i = 0; i < nvec; i++) begin
      apply(i);
      if (vec[i][0]) n_taken[vec[i][70:68]]++;
      else           n_not_taken[vec[i][70:68]]++;
    end
    in_order = checks;

    // ---- pass 2: random-order replay ----
    if (nvec > 0)
      for (int k = 0; k < n_replay; k++)
        apply($urandom(seed) % nvec);

    // ---- the vectors themselves must exercise every case ----
    for (int f = 0; f < 8; f++) begin
      if (f == 2 || f == 3) begin
        if (n_not_taken[f] == 0 || n_taken[f] != 0) begin
          errors++;
          $display("ERROR vector coverage: funct3=%0d taken=%0d not_taken=%0d", f, n_taken[f], n_not_taken[f]);
        end
      end else if (n_taken[f] == 0 || n_not_taken[f] == 0) begin
        errors++;
        $display("ERROR vector coverage: %s taken=%0d not_taken=%0d", f3_name(f[2:0]), n_taken[f], n_not_taken[f]);
      end
    end
    $display("vector coverage (taken/not taken): BEQ %0d/%0d  BNE %0d/%0d  BLT %0d/%0d  BGE %0d/%0d  BLTU %0d/%0d  BGEU %0d/%0d  f3=010 %0d/%0d  f3=011 %0d/%0d",
             n_taken[0], n_not_taken[0], n_taken[1], n_not_taken[1], n_taken[4], n_not_taken[4],
             n_taken[5], n_not_taken[5], n_taken[6], n_not_taken[6], n_taken[7], n_not_taken[7],
             n_taken[2], n_not_taken[2], n_taken[3], n_not_taken[3]);

    if (errors == 0)
      $display("PASS branch_unit_adv_tb: %0d checks (%0d file vectors in order, %0d random-order replays), 0 errors, seed=%0d, vec=%s",
               checks, in_order, checks - in_order, seed0, vecfile);
    else
      $display("FAIL branch_unit_adv_tb: %0d errors in %0d checks (%0d in order, %0d replays), seed=%0d, vec=%s",
               errors, checks, in_order, checks - in_order, seed0, vecfile);
    $finish;
  end

endmodule
