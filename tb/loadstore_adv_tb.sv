`timescale 1ns/1ps
// loadstore_adv_tb: adversarial end-to-end check of store_unit + load_unit.
//
// Oracle 1 (primary): Python vectors from tools/loadstore_adv_gen.py. The Python
// model is a 4-byte bytearray using int.to_bytes / int.from_bytes(..., 'little');
// it shares no code or lane arithmetic with the RTL or with store_unit_tb / load_unit_tb.
// Oracle 2: a small byte-array model below (ref_store / ref_load), written from
// spec 2.6 (p.33-34). It is compared with Python on every vector (so each oracle
// checks the other) and then drives a seeded random sequence.
//
// Each vector models one memory word in the TB (mem[0..3], one byte per address):
//   1. mem = old word
//   2. store_unit gets (store funct3, store addr_lo, rs2); its be/wdata/misaligned
//      are checked, then written into mem byte by byte where be is 1 (as dmem does)
//   3. mem is checked against the Python word-after-store
//   4. load_unit reads mem with (load funct3, load addr_lo); data/misaligned checked
// Vectors cover every store funct3 x offset x load funct3 x offset (all 8x4x8x4).
//
// Run: tools/loadstore_adv_run.sh [seed]   (generates vectors, then runs this TB)
module loadstore_adv_tb;

  localparam int N_SEQ = 20000;        // TB-side seeded random sequence steps

  // ---- store_unit ----
  logic [2:0]  s_funct3;
  logic [1:0]  s_addr_lo;
  logic [31:0] s_rs2;
  logic [3:0]  s_be;
  logic [31:0] s_wdata;
  logic        s_mis;
  store_unit su (.funct3(s_funct3), .addr_lo(s_addr_lo), .rs2(s_rs2),
                 .be(s_be), .wdata(s_wdata), .misaligned(s_mis));

  // ---- load_unit ----
  logic [2:0]  l_funct3;
  logic [1:0]  l_addr_lo;
  logic [31:0] l_word;
  logic [31:0] l_data;
  logic        l_mis;
  load_unit lu (.funct3(l_funct3), .addr_lo(l_addr_lo), .rdata_word(l_word),
                .data(l_data), .misaligned(l_mis));

  logic [7:0] mem     [0:3];   // memory word written through the DUT
  logic [7:0] ref_mem [0:3];   // memory word written by oracle 2

  int    seed = 1;
  int    seed0;
  int    errors = 0;           // DUT disagreed with an oracle
  int    oracle_errors = 0;    // the two oracles disagreed (bad test, not bad DUT)
  int    checks = 0;
  int    n_vec = 0;
  string vecfile;

  function automatic logic [31:0] mem_word();
    return {mem[3], mem[2], mem[1], mem[0]};
  endfunction

  // ---------------- oracle 2 (SV, byte array) ----------------
  function automatic int st_size(input logic [2:0] f3);   // 0 = not a store
    case (f3)
      3'b000:  return 1;
      3'b001:  return 2;
      3'b010:  return 4;
      default: return 0;
    endcase
  endfunction

  function automatic int ld_size(input logic [2:0] f3);   // 0 = not a load
    case (f3)
      3'b000, 3'b100: return 1;
      3'b001, 3'b101: return 2;
      3'b010:         return 4;
      default:        return 0;
    endcase
  endfunction

  task automatic ref_store(input logic [2:0] f3, input logic [1:0] lo, input logic [31:0] v,
                           output logic [3:0] be, output logic [31:0] wd, output logic mis);
    int n;
    int a;
    n = st_size(f3);
    a = lo;
    be = 4'b0000; wd = 32'h0; mis = 1'b0;
    if (n > 0 && (a % n) != 0) mis = 1'b1;
    else
      for (int i = 0; i < n; i++) begin       // register byte i -> address a+i
        ref_mem[a + i] = v[8*i +: 8];
        be[a + i]      = 1'b1;
        wd[8*(a + i) +: 8] = v[8*i +: 8];
      end
  endtask

  task automatic ref_load(input logic [2:0] f3, input logic [1:0] lo,
                          output logic [31:0] d, output logic mis);
    int n;
    int a;
    logic fill;
    n = ld_size(f3);
    a = lo;
    d = 32'h0; mis = 1'b0;
    if (n > 0 && (a % n) != 0) mis = 1'b1;
    else if (n > 0) begin
      for (int i = 0; i < n; i++) d[8*i +: 8] = ref_mem[a + i];   // address a+i -> byte i
      fill = (f3 == 3'b000 || f3 == 3'b001) ? d[8*n - 1] : 1'b0;  // LB/LH sign-extend
      for (int b = 8*n; b < 32; b++) d[b] = fill;
    end
  endtask

  // ---------------- one end-to-end step ----------------
  // Drives the DUTs, checks against the expected values x_*, and also checks
  // oracle 2 against them when check_oracle = 1.
  task automatic step(input logic [2:0] sf3, input logic [1:0] slo, input logic [31:0] rs2,
                      input logic [2:0] lf3, input logic [1:0] llo,
                      input logic [3:0] x_be, input logic x_smis, input logic [31:0] x_wdata,
                      input logic [31:0] x_new, input logic x_lmis, input logic [31:0] x_data,
                      input string tag);
    // store: inputs that did not change cause no event (single-input changes test sensitivity)
    s_funct3 = sf3; s_addr_lo = slo; s_rs2 = rs2;
    #1;
    checks++;
    if (s_be !== x_be || s_wdata !== x_wdata || s_mis !== x_smis) begin
      errors++;
      if (errors <= 12)
        $display("ERROR [%s store] f3=%b lo=%0d rs2=%h: got be=%b wdata=%h mis=%b, want be=%b wdata=%h mis=%b",
                 tag, sf3, slo, rs2, s_be, s_wdata, s_mis, x_be, x_wdata, x_smis);
    end
    // the memory word: write enabled bytes only
    for (int k = 0; k < 4; k++)
      if (s_be[k] === 1'b1) mem[k] = s_wdata[8*k +: 8];
    checks++;
    if (mem_word() !== x_new) begin
      errors++;
      if (errors <= 12)
        $display("ERROR [%s memory] after store f3=%b lo=%0d rs2=%h: word=%h, want %h",
                 tag, sf3, slo, rs2, mem_word(), x_new);
    end
    // load back from the word the TB now holds
    l_funct3 = lf3; l_addr_lo = llo; l_word = mem_word();
    #1;
    checks++;
    if (l_data !== x_data || l_mis !== x_lmis) begin
      errors++;
      if (errors <= 12)
        $display("ERROR [%s load] f3=%b lo=%0d word=%h: got data=%h mis=%b, want data=%h mis=%b",
                 tag, lf3, llo, l_word, l_data, l_mis, x_data, x_lmis);
    end
  endtask

  // Oracle 2 on the same inputs; returns its expectations (uses/updates ref_mem).
  task automatic oracle2(input logic [2:0] sf3, input logic [1:0] slo, input logic [31:0] rs2,
                         input logic [2:0] lf3, input logic [1:0] llo,
                         output logic [3:0] be, output logic smis, output logic [31:0] wd,
                         output logic [31:0] nw, output logic lmis, output logic [31:0] d);
    ref_store(sf3, slo, rs2, be, wd, smis);
    nw = {ref_mem[3], ref_mem[2], ref_mem[1], ref_mem[0]};
    ref_load(lf3, llo, d, lmis);
  endtask

  // Watchdog (the TB is combinational; this only guards against a hang).
  initial begin
    #50ms;
    $display("FAIL loadstore_adv_tb: timeout after %0d checks, %0d errors (seed=%0d)", checks, errors, seed0);
    $finish;
  end

  initial begin
    int fd, r, header_seed, sentinel_count;
    logic [191:0] v;
    logic [2:0]  sf3, lf3;
    logic [1:0]  slo, llo;
    logic [31:0] rs2, old;
    logic [3:0]  e_be, o_be;
    logic        e_smis, e_lmis, o_smis, o_lmis;
    logic [31:0] e_wdata, e_new, e_data, o_wdata, o_new, o_data;
    bit          done;

    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    seed0 = seed;
    if (!$value$plusargs("vec=%s", vecfile)) vecfile = "build/loadstore_adv_vectors.hex";
    $display("loadstore_adv_tb: seed=%0d vectors=%s", seed0, vecfile);

    // ---------------- part 1: Python vectors ----------------
    sentinel_count = -1;
    header_seed    = -1;
    fd = $fopen(vecfile, "r");
    if (fd == 0) begin
      errors++;
      $display("ERROR cannot open %s (run tools/loadstore_adv_run.sh)", vecfile);
    end else begin
      done = 0;
      while (!done) begin
        r = $fscanf(fd, "%h\n", v);
        if (r != 1) done = 1;
        else case (v[191:188])
          4'h0: header_seed = v[179:148];
          4'hF: begin sentinel_count = v[179:148]; done = 1; end
          4'h3: begin
            // field nibbles must hold small values only (catches a corrupt file)
            if (v[187] || v[183:182] || v[147] || v[143:142] || v[103:101] || v[35:33]) begin
              errors++;
              $display("ERROR malformed vector %0d: %h", n_vec, v);
            end
            sf3 = v[186:184]; slo = v[181:180]; rs2 = v[179:148];
            lf3 = v[146:144]; llo = v[141:140]; old = v[139:108];
            e_be = v[107:104]; e_smis = v[100]; e_wdata = v[99:68];
            e_new = v[67:36];  e_lmis = v[32];  e_data = v[31:0];
            for (int k = 0; k < 4; k++) begin
              mem[k]     = old[8*k +: 8];
              ref_mem[k] = old[8*k +: 8];
            end
            step(sf3, slo, rs2, lf3, llo, e_be, e_smis, e_wdata, e_new, e_lmis, e_data, "py");
            // the two oracles must agree, field by field
            oracle2(sf3, slo, rs2, lf3, llo, o_be, o_smis, o_wdata, o_new, o_lmis, o_data);
            if (o_be !== e_be || o_smis !== e_smis || o_wdata !== e_wdata ||
                o_new !== e_new || o_lmis !== e_lmis || o_data !== e_data) begin
              oracle_errors++;
              if (oracle_errors <= 5)
                $display("ORACLE MISMATCH vector %0d: python %h", n_vec, v);
            end
            n_vec++;
          end
          default: begin
            errors++;
            $display("ERROR unknown vector kind %h", v[191:188]);
          end
        endcase
      end
      $fclose(fd);
      if (sentinel_count != n_vec) begin
        errors++;
        $display("ERROR vector file: read %0d vectors, sentinel says %0d (truncated?)", n_vec, sentinel_count);
      end
      if (header_seed != seed0) begin
        errors++;
        $display("ERROR vector file was made with seed %0d but +seed=%0d", header_seed, seed0);
      end
    end

    // ---------------- part 2: seeded random sequence ($urandom) ----------------
    // One memory word persists across N_SEQ random store+load steps, so later
    // loads see bytes left by earlier stores of other sizes and offsets.
    old = $urandom(seed);
    for (int k = 0; k < 4; k++) begin
      mem[k]     = old[8*k +: 8];
      ref_mem[k] = old[8*k +: 8];
    end
    for (int i = 0; i < N_SEQ; i++) begin
      r   = $urandom(seed);
      sf3 = r[2:0]; slo = r[4:3]; lf3 = r[7:5]; llo = r[9:8];
      rs2 = $urandom(seed);
      oracle2(sf3, slo, rs2, lf3, llo, o_be, o_smis, o_wdata, o_new, o_lmis, o_data);
      step(sf3, slo, rs2, lf3, llo, o_be, o_smis, o_wdata, o_new, o_lmis, o_data, "seq");
      for (int k = 0; k < 4; k++) mem[k] = ref_mem[k];   // one DUT error must not cascade
    end

    if (errors == 0 && oracle_errors == 0)
      $display("PASS loadstore_adv_tb: %0d checks (%0d python vectors, %0d random steps), 0 errors (seed=%0d)",
               checks, n_vec, N_SEQ, seed0);
    else
      $display("FAIL loadstore_adv_tb: %0d checks (%0d python vectors, %0d random steps), %0d errors, %0d oracle mismatches (seed=%0d)",
               checks, n_vec, N_SEQ, errors, oracle_errors, seed0);
    $finish;
  end

endmodule
