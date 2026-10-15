`timescale 1ns/1ps
// immgen_tb: self-checking testbench for immgen.
//
// Three kinds of test, all compared with !== so an X or Z is an error too:
//   1. golden : real instructions assembled by GNU as 2.45.50; the expected
//               immediate is what objdump decodes (a second, independent decoder)
//   2. directed: zero, all ones, max positive, most negative, sign cases,
//               walking ones/zeros, every imm_src including unused 101/110/111
//   3. random : (a) random instruction words vs a per-bit reference model
//               (b) random legal immediates, encoded like an assembler, decoded by the DUT
//
// Run:  tools/run_unit.sh immgen_tb [+seed=N]
module immgen_tb;
  import rv_pkg::*;

  // ---- DUT ----
  logic [31:0] instr;     // a whole instruction word; the DUT only sees bits 31..7
  logic [2:0]  imm_src;
  logic [31:0] imm_ext;

  immgen dut (.instr(instr[31:7]), .imm_src(imm_src), .imm_ext(imm_ext));

  // ---- bookkeeping ----
  int seed       = 1;     // change with +seed=N; $urandom(seed) updates it every call
  int seed0;              // the starting seed, for the summary line
  int errors     = 0;     // every failed comparison
  int checks     = 0;     // DUT comparisons
  int mchecks    = 0;     // reference-model self-checks (model vs a known answer)
  int n_golden   = 0;
  int n_directed = 0;
  int n_random   = 0;

  localparam int N_RANDOM = 2000;   // per format, per random test

  // ===========================================================================
  // Reference model, written from spec Figure 1 "Types of immediate produced by
  // RISC-V instructions" (section 2.3). For every bit k of the 32-bit immediate
  // the figure names the instruction bit that feeds it. src_bit() is that figure
  // as a table: it returns the instruction bit number, or -1 for a constant 0.
  // ===========================================================================
  function automatic int src_bit(input logic [2:0] fmt, input int k);
    case (fmt)
      IMM_I: begin                        // I-immediate
        if      (k >= 11) return 31;      //   [31:11] = inst[31]
        else if (k >= 5)  return k + 20;  //   [10:5]  = inst[30:25]
        else if (k >= 1)  return k + 20;  //   [4:1]   = inst[24:21]
        else              return 20;      //   [0]     = inst[20]
      end
      IMM_S: begin                        // S-immediate
        if      (k >= 11) return 31;      //   [31:11] = inst[31]
        else if (k >= 5)  return k + 20;  //   [10:5]  = inst[30:25]
        else if (k >= 1)  return k + 7;   //   [4:1]   = inst[11:8]
        else              return 7;       //   [0]     = inst[7]
      end
      IMM_B: begin                        // B-immediate
        if      (k >= 12) return 31;      //   [31:12] = inst[31]
        else if (k == 11) return 7;       //   [11]    = inst[7]
        else if (k >= 5)  return k + 20;  //   [10:5]  = inst[30:25]
        else if (k >= 1)  return k + 7;   //   [4:1]   = inst[11:8]
        else              return -1;      //   [0]     = 0
      end
      IMM_U: begin                        // U-immediate
        if      (k == 31) return 31;      //   [31]    = inst[31]
        else if (k >= 20) return k;       //   [30:20] = inst[30:20]
        else if (k >= 12) return k;       //   [19:12] = inst[19:12]
        else              return -1;      //   [11:0]  = 0
      end
      IMM_J: begin                        // J-immediate
        if      (k >= 20) return 31;      //   [31:20] = inst[31]
        else if (k >= 12) return k;       //   [19:12] = inst[19:12]
        else if (k == 11) return 20;      //   [11]    = inst[20]
        else if (k >= 5)  return k + 20;  //   [10:5]  = inst[30:25]
        else if (k >= 1)  return k + 20;  //   [4:1]   = inst[24:21]
        else              return -1;      //   [0]     = 0
      end
      default: return -1;                 // 101/110/111: no format, immediate is 0
    endcase
  endfunction

  // Build the expected immediate one bit at a time from the table above.
  function automatic logic [31:0] ref_imm(input logic [31:0] ins, input logic [2:0] fmt);
    logic [31:0] r;
    int b;
    for (int k = 0; k < 32; k++) begin
      b    = src_bit(fmt, k);
      r[k] = (b < 0) ? 1'b0 : ins[b];
    end
    return r;
  endfunction

  // ===========================================================================
  // Encoder: the assembler's direction. The format diagrams ("Base instruction
  // formats immediate variants", section 2.3) label each instruction field with
  // the immediate bits it holds; copy them in. 'other' supplies the fields that
  // are not immediate (opcode, rd, funct3, rs1, rs2) so we can prove the DUT
  // ignores them.
  // ===========================================================================
  function automatic logic [31:0] encode(input logic [2:0] fmt, input logic [31:0] imm,
                                         input logic [31:0] other);
    logic [31:0] w;
    w = other;
    case (fmt)
      IMM_I: w[31:20] = imm[11:0];                         // imm[11:0]
      IMM_S: begin
        w[31:25] = imm[11:5];                              // imm[11:5]
        w[11:7]  = imm[4:0];                               // imm[4:0]
      end
      IMM_B: begin
        w[31]    = imm[12];                                // [12]
        w[30:25] = imm[10:5];                              // imm[10:5]
        w[11:8]  = imm[4:1];                               // imm[4:1]
        w[7]     = imm[11];                                // [11]
      end
      IMM_U: w[31:12] = imm[31:12];                        // imm[31:12]
      IMM_J: begin
        w[31]    = imm[20];                                // [20]
        w[30:21] = imm[10:1];                              // imm[10:1]
        w[20]    = imm[11];                                // [11]
        w[19:12] = imm[19:12];                             // imm[19:12]
      end
      default: ;
    endcase
    return w;
  endfunction

  // ===========================================================================
  // Checking helpers
  // ===========================================================================
  // Drive one input, wait for the combinational logic to settle, compare.
  task automatic check(input logic [31:0] ins, input logic [2:0] fmt,
                       input logic [31:0] exp, input string what);
    instr   = ins;
    imm_src = fmt;
    #1;
    checks++;
    if (imm_ext !== exp) begin
      errors++;
      if (errors <= 20)
        $display("ERROR %s: instr=%h imm_src=%b got %h expected %h",
                 what, ins, fmt, imm_ext, exp);
    end
  endtask

  // Check the checker: the reference model must agree with an answer we got
  // some other way (objdump, or worked out by hand from the spec).
  task automatic model_check(input logic [31:0] ins, input logic [2:0] fmt,
                             input logic [31:0] exp, input string what);
    logic [31:0] m;
    m = ref_imm(ins, fmt);
    mchecks++;
    if (m !== exp) begin
      errors++;
      if (errors <= 20)
        $display("MODEL ERROR %s: instr=%h imm_src=%b model %h expected %h",
                 what, ins, fmt, m, exp);
    end
  endtask

  // A real assembled instruction; exp is the immediate objdump printed.
  task automatic golden(input logic [31:0] ins, input logic [2:0] fmt, input logic [31:0] exp);
    model_check(ins, fmt, exp, "golden");
    check(ins, fmt, exp, "golden");
    n_golden++;
  endtask

  // A hand-worked corner case.
  task automatic directed(input logic [31:0] ins, input logic [2:0] fmt, input logic [31:0] exp);
    model_check(ins, fmt, exp, "directed");
    check(ins, fmt, exp, "directed");
    n_directed++;
  endtask

  // Round trip: put imm into an instruction, the DUT must give it back.
  task automatic roundtrip(input logic [2:0] fmt, input logic [31:0] imm,
                           input logic [31:0] other, input string what);
    logic [31:0] w;
    w = encode(fmt, imm, other);
    model_check(w, fmt, imm, what);   // the two spec figures must agree with each other
    check(w, fmt, imm, what);
  endtask

  // A random immediate that fits the format (arithmetic, not bit slicing).
  function automatic logic [31:0] random_legal_imm(input logic [2:0] fmt, input logic [31:0] r);
    int u;
    case (fmt)
      IMM_I, IMM_S: begin u = r % 4096;    return u - 2048;          end // -2048 .. 2047
      IMM_B:        begin u = r % 4096;    return (u - 2048) * 2;    end // even, -4096 .. 4094
      IMM_U:                               return r & 32'hFFFF_F000;     // any multiple of 4096
      IMM_J:        begin u = r % 1048576; return (u - 524288) * 2;  end // even, -1048576 .. 1048574
      default:                             return 0;
    endcase
  endfunction

  // ===========================================================================
  // Tests
  // ===========================================================================
  logic [2:0]  fmts [5];          // the five real formats, for the random loop
  logic [31:0] w, v, other;

  initial begin
    if ($value$plusargs("seed=%d", seed)) ;
    seed0 = seed;
    $display("immgen_tb: seed=%0d", seed0);
    // (Icarus 12 cannot initialise a whole array with '{...}, so fill it here.)
    fmts[0] = IMM_I;  fmts[1] = IMM_S;  fmts[2] = IMM_B;  fmts[3] = IMM_U;  fmts[4] = IMM_J;

    // ---- 1. Golden vectors ------------------------------------------------
    // Assembled with riscv64-unknown-elf-as -march=rv32i -mabi=ilp32, linked
    // with fixed section addresses, decoded with objdump -d -M no-aliases,numeric.
    // Branch/jump offsets = (target objdump printed) - pc.
    golden(32'hfff00093, IMM_I, 32'hffffffff);  // addi x1,x0,-1
    golden(32'h7ff18113, IMM_I, 32'h000007ff);  // addi x2,x3,2047
    golden(32'h80028213, IMM_I, 32'hfffff800);  // addi x4,x5,-2048
    golden(32'h0003a303, IMM_I, 32'h00000000);  // lw x6,0(x7)
    golden(32'h0644a403, IMM_I, 32'h00000064);  // lw x8,100(x9)
    golden(32'h0016c603, IMM_I, 32'h00000001);  // lbu x12,1(x13)
    golden(32'haab5a513, IMM_I, 32'hfffffaab);  // slti x10,x11,-1365
    golden(32'hffc280e7, IMM_I, 32'hfffffffc);  // jalr x1,-4(x5)
    golden(32'h00008067, IMM_I, 32'h00000000);  // jalr x0,0(x1)
    golden(32'h00000013, IMM_I, 32'h00000000);  // addi x0,x0,0 (nop)
    golden(32'h80512023, IMM_S, 32'hfffff800);  // sw x5,-2048(x2)
    golden(32'h7ff0afa3, IMM_S, 32'h000007ff);  // sw x31,2047(x1)
    golden(32'hfe740fa3, IMM_S, 32'hffffffff);  // sb x7,-1(x8)
    golden(32'h00951623, IMM_S, 32'h0000000c);  // sh x9,12(x10)
    golden(32'h00002023, IMM_S, 32'h00000000);  // sw x0,0(x0)
    golden(32'h435b2023, IMM_S, 32'h00000420);  // sw x21,1056(x22)
    golden(32'hfffff0b7, IMM_U, 32'hfffff000);  // lui x1,0xfffff
    golden(32'h80000137, IMM_U, 32'h80000000);  // lui x2,0x80000
    golden(32'h7ffff1b7, IMM_U, 32'h7ffff000);  // lui x3,0x7ffff
    golden(32'h12345217, IMM_U, 32'h12345000);  // auipc x4,0x12345
    golden(32'h000002b7, IMM_U, 32'h00000000);  // lui x5,0x0
    golden(32'h00000063, IMM_B, 32'h00000000);  // beq x0,x0,50   (pc 50, offset 0)
    golden(32'h0062c463, IMM_B, 32'h00000008);  // blt x5,x6,5c   (pc 54, offset 8)
    golden(32'hfe83dae3, IMM_B, 32'hfffffff4);  // bge x7,x8,50   (pc 5c, offset -12)
    golden(32'hfaa4e0e3, IMM_B, 32'hffffffa0);  // bltu x9,x10,0  (pc 60, offset -96)
    golden(32'h80208063, IMM_B, 32'hfffff000);  // beq x1,x2,1000 (pc 2000, offset -4096)
    golden(32'h7e419ee3, IMM_B, 32'h00000ffc);  // bne x3,x4,3000 (pc 2004, offset 4092)
    golden(32'h0062c0e3, IMM_B, 32'h00000800);  // blt x5,x6,2808 (pc 2008, offset 2048)
    golden(32'h80a4f0e3, IMM_B, 32'hfffff800);  // bgeu x9,x10,180c (pc 200c, offset -2048)
    golden(32'hfedff06f, IMM_J, 32'hffffffec);  // jal x0,50      (pc 64, offset -20)
    golden(32'hff5ff0ef, IMM_J, 32'hfffffff4);  // jal x1,5c      (pc 68, offset -12)
    golden(32'h800000ef, IMM_J, 32'hfff00000);  // jal x1,0       (pc 100000, offset -1048576)
    golden(32'h7fdff06f, IMM_J, 32'h000ffffc);  // jal x0,200000  (pc 100004, offset 1048572)
    golden(32'h001002ef, IMM_J, 32'h00000800);  // jal x5,100808  (pc 100008, offset 2048)
    golden(32'h0000136f, IMM_J, 32'h00001000);  // jal x6,10100c  (pc 10000c, offset 4096)
    golden(32'h801ff46f, IMM_J, 32'hfffff800);  // jal x8,ff810   (pc 100010, offset -2048)

    // ---- 2. Directed corner cases (expected values worked out by hand) ----
    // Zero instruction: every imm_src gives 0.
    for (int s = 0; s < 8; s++) directed(32'h0000_0000, s[2:0], 32'h0000_0000);

    // All ones: sign bit set, every field bit set.
    directed(32'hFFFF_FFFF, IMM_I,  32'hFFFF_FFFF);  // -1
    directed(32'hFFFF_FFFF, IMM_S,  32'hFFFF_FFFF);  // -1
    directed(32'hFFFF_FFFF, IMM_B,  32'hFFFF_FFFE);  // -2 (bit 0 is always 0)
    directed(32'hFFFF_FFFF, IMM_U,  32'hFFFF_F000);  // low 12 bits always 0
    directed(32'hFFFF_FFFF, IMM_J,  32'hFFFF_FFFE);  // -2
    directed(32'hFFFF_FFFF, 3'b101, 32'h0000_0000);  // unused imm_src -> 0
    directed(32'hFFFF_FFFF, 3'b110, 32'h0000_0000);
    directed(32'hFFFF_FFFF, 3'b111, 32'h0000_0000);

    // Sign bit 0, everything else 1: the largest positive immediate of each format.
    directed(32'h7FFF_FFFF, IMM_I,  32'h0000_07FF);  // +2047
    directed(32'h7FFF_FFFF, IMM_S,  32'h0000_07FF);  // +2047
    directed(32'h7FFF_FFFF, IMM_B,  32'h0000_0FFE);  // +4094
    directed(32'h7FFF_FFFF, IMM_U,  32'h7FFF_F000);
    directed(32'h7FFF_FFFF, IMM_J,  32'h000F_FFFE);  // +1048574
    directed(32'h7FFF_FFFF, 3'b101, 32'h0000_0000);
    directed(32'h7FFF_FFFF, 3'b110, 32'h0000_0000);
    directed(32'h7FFF_FFFF, 3'b111, 32'h0000_0000);

    // Sign bit 1, everything else 0: the most negative immediate of each format.
    directed(32'h8000_0000, IMM_I,  32'hFFFF_F800);  // -2048
    directed(32'h8000_0000, IMM_S,  32'hFFFF_F800);  // -2048
    directed(32'h8000_0000, IMM_B,  32'hFFFF_F000);  // -4096
    directed(32'h8000_0000, IMM_U,  32'h8000_0000);
    directed(32'h8000_0000, IMM_J,  32'hFFF0_0000);  // -1048576
    directed(32'h8000_0000, 3'b101, 32'h0000_0000);
    directed(32'h8000_0000, 3'b110, 32'h0000_0000);
    directed(32'h8000_0000, 3'b111, 32'h0000_0000);

    // Only the scrambled bits: B imm[11] lives in instr[7], J imm[11] in instr[20].
    directed(32'h0000_0080, IMM_B,  32'h0000_0800);  // instr[7]  -> B imm[11]
    directed(32'h0000_0080, IMM_S,  32'h0000_0001);  // instr[7]  -> S imm[0]
    directed(32'h0010_0000, IMM_J,  32'h0000_0800);  // instr[20] -> J imm[11]
    directed(32'h0010_0000, IMM_I,  32'h0000_0001);  // instr[20] -> I imm[0]

    // Round trips at the edges of every format's range, with the non-immediate
    // fields all 0 and then all 1 (the DUT must ignore rs1/rs2/rd/funct3/opcode).
    for (int f = 0; f < 2; f++) begin
      other = (f == 0) ? 32'h0000_0000 : 32'hFFFF_FFFF;
      roundtrip(IMM_I, 0,     other, "edge I");  roundtrip(IMM_I, 1,      other, "edge I");
      roundtrip(IMM_I, -1,    other, "edge I");  roundtrip(IMM_I, 2047,   other, "edge I");
      roundtrip(IMM_I, -2048, other, "edge I");
      roundtrip(IMM_S, 0,     other, "edge S");  roundtrip(IMM_S, 1,      other, "edge S");
      roundtrip(IMM_S, -1,    other, "edge S");  roundtrip(IMM_S, 2047,   other, "edge S");
      roundtrip(IMM_S, -2048, other, "edge S");
      roundtrip(IMM_B, 0,     other, "edge B");  roundtrip(IMM_B, 2,      other, "edge B");
      roundtrip(IMM_B, -2,    other, "edge B");  roundtrip(IMM_B, 4094,   other, "edge B");
      roundtrip(IMM_B, -4096, other, "edge B");  roundtrip(IMM_B, 2048,   other, "edge B");
      roundtrip(IMM_U, 32'h0000_0000, other, "edge U");  roundtrip(IMM_U, 32'h0000_1000, other, "edge U");
      roundtrip(IMM_U, 32'hFFFF_F000, other, "edge U");  roundtrip(IMM_U, 32'h7FFF_F000, other, "edge U");
      roundtrip(IMM_U, 32'h8000_0000, other, "edge U");
      roundtrip(IMM_J, 0,     other, "edge J");  roundtrip(IMM_J, 2,       other, "edge J");
      roundtrip(IMM_J, -2,    other, "edge J");  roundtrip(IMM_J, 1048574, other, "edge J");
      roundtrip(IMM_J, -1048576, other, "edge J");
      roundtrip(IMM_J, 2048,  other, "edge J");  roundtrip(IMM_J, 4096,    other, "edge J");
      n_directed += 28;
    end

    // Walking one and walking zero through instr[31:7], for every imm_src:
    // catches any single mis-wired or stuck bit.
    for (int i = 7; i < 32; i++) begin
      for (int s = 0; s < 8; s++) begin
        w = 32'h1 << i;
        check(w,  s[2:0], ref_imm(w,  s[2:0]), "walking one");
        check(~w, s[2:0], ref_imm(~w, s[2:0]), "walking zero");
        n_directed += 2;
      end
    end

    // ---- 3a. Random instruction words vs the reference model ---------------
    // Every imm_src value, including the unused ones (model says 0).
    for (int s = 0; s < 8; s++) begin
      for (int n = 0; n < N_RANDOM; n++) begin
        w = $urandom(seed);
        check(w, s[2:0], ref_imm(w, s[2:0]), "random word");
        n_random++;
      end
    end

    // ---- 3b. Random legal immediates, encoded then decoded ------------------
    for (int f = 0; f < 5; f++) begin
      for (int n = 0; n < N_RANDOM; n++) begin
        v     = random_legal_imm(fmts[f], $urandom(seed));
        other = $urandom(seed);                 // random rd/rs1/rs2/funct3/opcode
        roundtrip(fmts[f], v, other, "random roundtrip");
        n_random++;
      end
    end

    // ---- summary ------------------------------------------------------------
    if (errors == 0)
      $display("PASS immgen_tb: %0d checks (golden %0d, directed %0d, random %0d), %0d model self-checks, 0 errors, seed=%0d",
               checks, n_golden, n_directed, n_random, mchecks, seed0);
    else
      $display("FAIL immgen_tb: %0d errors in %0d checks (golden %0d, directed %0d, random %0d), %0d model self-checks, seed=%0d",
               errors, checks, n_golden, n_directed, n_random, mchecks, seed0);
    $finish;
  end

endmodule
