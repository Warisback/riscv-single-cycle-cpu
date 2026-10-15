`timescale 1ns/1ps
// immgen_adv_tb: adversarial check of immgen, with GNU as as the oracle.
//
// Run through tools/immgen_adv_run.sh, which builds the vector file:
//   we choose an immediate -> GNU as encodes a real instruction with it ->
//   the expected immgen output is the number we chose (never decoded from bits).
// Vector line (72 bits): instr[71:40] kind[39:36] imm_src[35:32] expected[31:0]
//   kind 0 = directed (range edges, single bits, patterns), 1 = random, f = end.
//
// For every vector this TB checks three things, all with !==:
//   1. the assembled word with its own imm_src gives the chosen immediate;
//   2. the same word with the non-immediate fields (rd, rs1, rs2, funct3) set to
//      random values ($urandom, +seed=N) still gives it: those fields hold no
//      immediate bits (spec 2.3 format figure, p.26);
//   3. the unused imm_src values 101/110/111 give 0 (docs/DESIGN.md item 1).
module immgen_adv_tb;
  import rv_pkg::*;

  // ---- DUT ----
  logic [31:0] instr;
  logic [2:0]  imm_src;
  logic [31:0] imm_ext;

  immgen dut (.instr(instr[31:7]), .imm_src(imm_src), .imm_ext(imm_ext));

  // ---- vectors ----
  localparam int MAXV = 65536;
  logic [71:0] vec [0:MAXV-1];
  string vecfile = "build/immgen_adv/immgen_adv_vectors.hex";

  // ---- bookkeeping ----
  int seed      = 1;      // +seed=N; drives the field scramble
  int seed0;
  int nvec_want = -1;     // +nvec=N from the run script: how many vectors it wrote
  int nvec      = 0;
  int errors    = 0;
  int checks    = 0;
  int n_dir = 0, n_rand = 0, n_scr = 0, n_unused = 0;
  logic found_end = 1'b0;
  logic stop      = 1'b0;

  // Bits of instr[31:7] that are not immediate bits in each format (register
  // numbers and funct3), read off the format figure in spec 2.3 (p.26).
  function automatic logic [31:0] non_imm_fields(input logic [2:0] fmt);
    case (fmt)
      IMM_I:        return 32'h000F_FF80;   // rs1 [19:15], funct3 [14:12], rd [11:7]
      IMM_S, IMM_B: return 32'h01FF_F000;   // rs2 [24:20], rs1 [19:15], funct3 [14:12]
      IMM_U, IMM_J: return 32'h0000_0F80;   // rd [11:7]
      default:      return 32'h0000_0000;
    endcase
  endfunction

  task automatic check(input logic [31:0] ins, input logic [2:0] fmt,
                       input logic [31:0] exp, input string what, input int idx);
    instr   = ins;
    imm_src = fmt;
    #1;
    checks++;
    if (imm_ext !== exp) begin
      errors++;
      if (errors <= 20)
        $display("ERROR %s (vector %0d): instr=%h imm_src=%b got %h expected %h",
                 what, idx, ins, fmt, imm_ext, exp);
    end
  endtask

  logic [31:0] ins, exp, scr, m;
  logic [3:0]  kind, src;

  initial begin
    if ($value$plusargs("seed=%d", seed)) ;
    if ($value$plusargs("vec=%s", vecfile)) ;
    if ($value$plusargs("nvec=%d", nvec_want)) ;
    seed0 = seed;
    $display("immgen_adv_tb: seed=%0d vectors=%s", seed0, vecfile);

    // With +nvec we know the file holds nvec vectors plus the end marker, so
    // read exactly that range; a shorter file then leaves X and fails below.
    if (nvec_want >= 1 && nvec_want < MAXV) $readmemh(vecfile, vec, 0, nvec_want);
    else                                    $readmemh(vecfile, vec);

    // (Icarus 12 has no break/continue, so the loop stops on a flag.)
    for (int i = 0; i < MAXV && !stop; i++) begin
      {ins, kind, src, exp} = vec[i];
      if ($isunknown(vec[i])) begin           // missing line or bad hex: never a silent pass
        errors++;
        $display("ERROR vector file: line %0d is missing or not hex (no end marker before it)", i);
        stop = 1'b1;
      end else if (kind == 4'hF) begin        // end marker
        found_end = 1'b1;
        stop      = 1'b1;
      end else if (src > 4'd4 || kind > 4'd1) begin
        errors++;
        $display("ERROR vector file: line %0d has kind=%h imm_src=%h", i, kind, src);
      end else begin
        nvec++;

        // 1. the real instruction, exactly as the assembler produced it
        if (kind == 4'd0) begin check(ins, src[2:0], exp, "asm directed", i); n_dir++;  end
        else              begin check(ins, src[2:0], exp, "asm random",   i); n_rand++; end

        // 2. same immediate, random rd/rs1/rs2/funct3: the answer must not move
        m   = non_imm_fields(src[2:0]);
        scr = $urandom(seed);
        check((ins & ~m) | (scr & m), src[2:0], exp, "field scramble", i);
        n_scr++;

        // 3. unused imm_src values give 0
        for (int u = 5; u < 8; u++) begin
          check(ins, u[2:0], 32'h0000_0000, "unused imm_src", i);
          n_unused++;
        end
      end
    end

    if (!found_end) begin
      errors++;
      $display("ERROR vector file: no end marker found");
    end
    if (nvec == 0) begin
      errors++;
      $display("ERROR vector file: no vectors");
    end
    if (nvec_want >= 0 && nvec != nvec_want) begin
      errors++;
      $display("ERROR vector file: read %0d vectors, run script wrote %0d", nvec, nvec_want);
    end

    if (errors == 0)
      $display("PASS immgen_adv_tb: %0d checks (asm directed %0d, asm random %0d, field scramble %0d, unused imm_src %0d), %0d vectors, 0 errors, seed=%0d",
               checks, n_dir, n_rand, n_scr, n_unused, nvec, seed0);
    else
      $display("FAIL immgen_adv_tb: %0d errors in %0d checks (asm directed %0d, asm random %0d, field scramble %0d, unused imm_src %0d), %0d vectors, seed=%0d",
               errors, checks, n_dir, n_rand, n_scr, n_unused, nvec, seed0);
    $finish;
  end

endmodule
