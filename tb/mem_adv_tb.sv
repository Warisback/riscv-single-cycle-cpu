`timescale 1ns/1ps
// mem_adv_tb: adversarial checks of imem and dmem, written independently of mem_tb.
//
// Run from the repository root (tools/mem_adv_run.sh runs every case below):
//   tools/run_unit.sh mem_adv_tb +hex=build/mem_adv/full.hex +bin=build/mem_adv/full.bin [+seed=N]
//   tools/run_unit.sh mem_adv_tb [+seed=N]          no image: both memories all zero
//
// Oracle
//   +bin names the RAW binary the +hex file was made from (objcopy -O binary
//   layout: file byte k is memory byte k). This TB reads it one byte at a time
//   with $fgetc into a byte array. It never uses $readmemh or tools/bin2hex.py,
//   so a wrong byte order anywhere in bin -> hex -> $readmemh -> lanes shows up.
//   Rules the oracle applies:
//     - little-endian: the least-significant byte is at the lowest address,
//       loads put lesser addresses in less-significant bytes   (spec 2.6, p.33)
//     - SB/SH/SW store the low 8/16/32 bits of rs2              (spec 2.6, p.34)
//     - docs/DESIGN.md: 64 KiB, so a byte address is (addr mod 65536); dmem be[k]
//       writes byte (word base + k); write only on the rising edge when we=1.
//
// What is checked
//   A  all 16384 words: imem == image, dmem == image, imem == dmem, with random
//      addr[1:0] and random alias bits; clock running with we=0 + junk be/wdata
//   B  all 16 be patterns (not only the 7 that SB/SH/SW make) x all addr[1:0]
//   C  SB/SH/SW built from the spec's byte rule at corner addresses
//   D  glitches: we=1 only while clk is high, or held across the falling edge,
//      or pulsed early in the low phase -> none of these may write
//   E  N_OPS random cycles over hot words and the whole 64 KiB, mixing be
//      writes, spec stores, we=0 junk cycles, we=1/be=0000 cycles and
//      interleaved reads of both memories
//   F  final sweep: every dmem word == byte model, every imem word == image
module mem_adv_tb;
  import rv_pkg::*;

  // ---------------- DUTs ----------------
  logic        clk = 1'b0;
  logic [31:0] iaddr, irdata;
  logic [31:0] daddr, drdata, dwdata;
  logic        dwe;
  logic [3:0]  dbe;

  imem u_imem (.addr(iaddr), .rdata(irdata));
  dmem u_dmem (.clk(clk), .addr(daddr), .rdata(drdata), .we(dwe), .be(dbe), .wdata(dwdata));

  always #5 clk = ~clk;   // rising edges at 5, 15, 25 ...; falling edges at 10, 20 ...

  localparam int N_OPS      = 20000;
  localparam int N_HOT      = 48;        // a few words used again and again
  localparam int TIMEOUT_NS = 5_000_000;

  // ---------------- bookkeeping ----------------
  int    seed = 1;
  int    rng;
  int    errors = 0;
  int    checks = 0;
  string hexfile, binfile;
  bit    have_hex, have_bin;
  int    nbytes = 0;                     // bytes read from +bin

  logic [7:0] img_b [0:65535];           // image as loaded; imem must always match it
  logic [7:0] ref_b [0:65535];           // current data memory; dmem must match it
  int         hot   [0:N_HOT-1];         // word indices of the hot set

  int be_cov [0:15];                     // writes (we=1) per be pattern
  int n_ops_done = 0, n_glitch = 0, n_we0 = 0, n_alias = 0, n_raw = 0, n_reads = 0;
  int last_write_word = -1;

  // ---------------- oracle helpers ----------------
  // Byte address inside the 64 KiB memory.
  function automatic int byte_of(input logic [31:0] a);
    return a % 65536;
  endfunction

  // Little-endian word that holds byte address a (lowest address -> bits 7:0).
  function automatic logic [31:0] ref_word(input logic [31:0] a);
    int base;
    base = byte_of(a) - (byte_of(a) % 4);
    return {ref_b[base + 3], ref_b[base + 2], ref_b[base + 1], ref_b[base]};
  endfunction

  function automatic logic [31:0] img_word(input logic [31:0] a);
    int base;
    base = byte_of(a) - (byte_of(a) % 4);
    return {img_b[base + 3], img_b[base + 2], img_b[base + 1], img_b[base]};
  endfunction

  // dmem byte-enable write: be[k] -> byte (word base + k) gets wdata bits 8k+7..8k.
  task automatic ref_be_write(input logic [31:0] a, input logic [3:0] be, input logic [31:0] wd);
    int base;
    base = byte_of(a) - (byte_of(a) % 4);
    for (int k = 0; k < 4; k++)
      if (be[k]) ref_b[base + k] = wd[8*k +: 8];
  endtask

  // SB/SH/SW: byte j of rs2 goes to byte address a+j (spec 2.6, p.33-34).
  task automatic ref_store(input int size, input logic [31:0] a, input logic [31:0] rs2);
    for (int j = 0; j < size; j++)
      ref_b[byte_of(a) + j] = rs2[8*j +: 8];
  endtask

  // What the core must hand dmem for an aligned SB/SH/SW: for each stored byte,
  // find the lane its byte address falls in, set that be bit and put the byte there.
  // Other lanes keep the junk value (dmem must ignore them).
  task automatic spec_lanes(input int size, input logic [31:0] a, input logic [31:0] rs2,
                            input logic [31:0] junk, output logic [3:0] be, output logic [31:0] wd);
    int lane;
    be = 4'b0000;
    wd = junk;
    for (int j = 0; j < size; j++) begin
      lane = (byte_of(a) + j) % 4;
      be[lane] = 1'b1;
      wd[8*lane +: 8] = rs2[8*j +: 8];
    end
  endtask

  // ---------------- random helpers ----------------
  // 6 in 10: a hot word (many overwrites), else any of the 16384 words.
  function automatic int pick_word();
    if ($urandom(rng) % 10 < 6) return hot[$urandom(rng) % N_HOT];
    return $urandom(rng) % MEM_WORDS;
  endfunction

  // Byte address of word w with low bits lo; half the time random upper 16 bits.
  function automatic logic [31:0] make_addr(input int w, input logic [1:0] lo);
    logic [31:0] hi;
    hi = ($urandom(rng) % 2) ? ($urandom(rng) & 32'hFFFF_0000) : 32'h0;
    if (hi != 0) n_alias++;
    return hi + 4 * w + lo;
  endfunction

  // ---------------- checking ----------------
  task automatic chk(input logic [31:0] got, input logic [31:0] exp, input string what);
    checks++;
    if (got !== exp) begin
      errors++;
      if (errors <= 25)
        $display("ERROR t=%0t %s: got %08h expected %08h", $time, what, got, exp);
    end
  endtask

  // Read both memories at random places while dmem has we=0 and junk be/wdata.
  task automatic interleaved_read();
    logic [31:0] a, ai;
    a  = make_addr(pick_word(), $urandom(rng) % 4);
    ai = make_addr($urandom(rng) % MEM_WORDS, $urandom(rng) % 4);
    dwe = 1'b0; dbe = $urandom(rng); dwdata = $urandom(rng);
    daddr = a; iaddr = ai;
    #1;
    chk(drdata, ref_word(a),  $sformatf("interleaved dmem read %08h", a));
    chk(irdata, img_word(ai), $sformatf("interleaved imem read %08h", ai));
    n_reads++;
  endtask

  // Early-low-phase pulse: we=1 with junk at some word, then taken away well
  // before the rising edge. An edge-triggered write never sees it.
  task automatic low_pulse();
    logic [31:0] a;
    a = make_addr(pick_word(), $urandom(rng) % 4);
    daddr = a; dwe = 1'b1; dbe = 4'b1111; dwdata = ~ref_word(a);
    #1 chk(drdata, ref_word(a), $sformatf("we=1 pulse in low phase wrote %08h", a));
    dwe = 1'b0;
    n_glitch++;
  endtask

  // Called right after a rising edge: we=1 with junk while clk is high, held
  // across the falling edge, dropped before the next rising edge.
  // Catches level-sensitive (latch) writes and falling-edge writes.
  task automatic high_glitch();
    logic [31:0] a;
    a = make_addr(pick_word(), $urandom(rng) % 4);
    daddr = a; dwe = 1'b1; dbe = 4'b1111; dwdata = ~ref_word(a);
    #1 chk(drdata, ref_word(a), $sformatf("we=1 while clk high wrote %08h", a));
    @(negedge clk);
    #1 chk(drdata, ref_word(a), $sformatf("we=1 across falling edge wrote %08h", a));
    dwe = 1'b0;
    @(posedge clk);
    #1 chk(drdata, ref_word(a), $sformatf("we dropped before rising edge, still wrote %08h", a));
    n_glitch++;
  endtask

  // One dmem cycle. kind 0: raw be write (ref uses be). kind 1/2/4: SB/SH/SW
  // (ref uses the spec byte rule on rs2). If we_i=0 nothing may change.
  task automatic op_cycle(input logic        we_i,
                          input logic [31:0] a,
                          input logic [3:0]  be_i,
                          input logic [31:0] wd_i,
                          input int          kind,
                          input logic [31:0] rs2,
                          input string       what);
    logic [31:0] old_w, new_w;
    int          w;
    @(negedge clk);
    repeat ($urandom(rng) % 3) interleaved_read();   // 0-2 reads first
    if ($urandom(rng) % 5 == 0) low_pulse();
    daddr = a; dwe = we_i; dbe = be_i; dwdata = wd_i;
    old_w = ref_word(a);
    if (we_i) begin
      if (kind == 0) ref_be_write(a, be_i, wd_i);
      else           ref_store(kind, a, rs2);
      be_cov[be_i]++;
    end else begin
      n_we0++;
    end
    new_w = ref_word(a);
    w = byte_of(a) / 4;
    if (w == last_write_word) n_raw++;
    last_write_word = (we_i && be_i != 4'b0000) ? w : -1;
    #1 chk(drdata, old_w, $sformatf("%s addr=%08h we=%0b be=%04b before edge", what, a, we_i, be_i));
    @(posedge clk);
    #1 chk(drdata, new_w, $sformatf("%s addr=%08h we=%0b be=%04b after edge", what, a, we_i, be_i));
    n_ops_done++;
  endtask

  // ---------------- timeout ----------------
  initial begin
    #(TIMEOUT_NS);
    $display("FAIL mem_adv_tb: timeout after %0d ns", TIMEOUT_NS);
    $finish;
  end

  // ---------------- main ----------------
  initial begin
    int          fd, c, size, w, lo;
    logic [31:0] a, rs2, junk;
    logic [3:0]  be_v;
    logic [31:0] wd_v;

    iaddr = 32'h0; daddr = 32'h0; dwe = 1'b0; dbe = 4'b0000; dwdata = 32'h0;
    for (int k = 0; k < 16; k++) be_cov[k] = 0;

    void'($value$plusargs("seed=%d", seed));
    rng = seed;
    have_hex = $value$plusargs("hex=%s", hexfile);
    have_bin = $value$plusargs("bin=%s", binfile);
    if (!have_hex) hexfile = "none";
    if (!have_bin) binfile = "none";
    if (have_hex != have_bin) begin
      $display("FAIL mem_adv_tb: give both +hex=<image> and +bin=<raw binary it came from>, or neither");
      $finish;
    end

    // Oracle: read the raw binary byte by byte (zero past its end).
    for (int b = 0; b < 65536; b++) img_b[b] = 8'h00;
    if (have_bin) begin
      fd = $fopen(binfile, "rb");
      if (fd == 0) begin
        $display("FAIL mem_adv_tb: cannot open %s", binfile);
        $finish;
      end
      c = $fgetc(fd);
      while (c != -1 && nbytes < 65536) begin
        img_b[nbytes] = c[7:0];
        nbytes++;
        c = $fgetc(fd);
      end
      $fclose(fd);
      if (nbytes == 0) begin
        $display("FAIL mem_adv_tb: %s is empty", binfile);
        $finish;
      end
    end
    for (int b = 0; b < 65536; b++) ref_b[b] = img_b[b];
    $display("mem_adv_tb: hex=%s bin=%s (%0d bytes), seed %0d", hexfile, binfile, nbytes, seed);

    // Hot set: corner words, the rest random.
    hot[0] = 0;                   // address 0x0000
    hot[1] = 1;
    hot[2] = 32'h8000 / 4;        // start of the data region
    hot[3] = TOHOST_ADDR / 4;     // 0xFFF0
    hot[4] = MEM_WORDS - 1;       // 0xFFFC, last word
    hot[5] = (nbytes / 4);        // the word where the image ends (padding / zero init)
    for (int i = 6; i < N_HOT; i++) hot[i] = $urandom(rng) % MEM_WORDS;

    @(negedge clk);   // the memories' initial blocks have run by now

    // ===== A: every word of both memories, combinational reads, clock running.
    // dmem sees we=0 (or we=1 with be=0000) with junk data on every edge.
    for (w = 0; w < MEM_WORDS; w++) begin
      a = make_addr(w, $urandom(rng) % 4);
      iaddr = a;
      daddr = make_addr(w, $urandom(rng) % 4);   // a different alias of the same word
      dwdata = $urandom(rng);
      if (w % 7 == 0) begin dwe = 1'b1; dbe = 4'b0000; end
      else            begin dwe = 1'b0; dbe = $urandom(rng); end
      #1;
      chk(irdata, img_word(a), $sformatf("A imem word %0d addr=%08h", w, a));
      chk(drdata, img_word(a), $sformatf("A dmem word %0d addr=%08h", w, daddr));
      chk(irdata, drdata,      $sformatf("A imem vs dmem word %0d", w));
    end
    dwe = 1'b0;

    // ===== B: all 16 be patterns x all addr[1:0], on hot words.
    for (int be_i = 0; be_i < 16; be_i++)
      for (lo = 0; lo < 4; lo++) begin
        a = make_addr(hot[(4 * be_i + lo) % N_HOT], lo);
        op_cycle(1'b1, a, be_i[3:0], $urandom(rng), 0, 32'h0, "B be write");
      end

    // ===== C: SB/SH/SW from the spec byte rule at corner addresses.
    // SB at all 4 offsets of 0x8000, SH at both halves, SW; then the top word via
    // a wrapped alias, word 0 via 0x00010000, and TOHOST.
    for (lo = 0; lo < 4; lo++) begin
      rs2 = $urandom(rng); junk = $urandom(rng);
      spec_lanes(1, 32'h8000 + lo, rs2, junk, be_v, wd_v);
      op_cycle(1'b1, 32'h8000 + lo, be_v, wd_v, 1, rs2, "C SB");
    end
    for (lo = 0; lo < 4; lo += 2) begin
      rs2 = $urandom(rng); junk = $urandom(rng);
      spec_lanes(2, 32'h8004 + lo, rs2, junk, be_v, wd_v);
      op_cycle(1'b1, 32'h8004 + lo, be_v, wd_v, 2, rs2, "C SH");
    end
    rs2 = $urandom(rng); spec_lanes(4, 32'hFFFF_FFFC, rs2, 32'h0, be_v, wd_v);
    op_cycle(1'b1, 32'hFFFF_FFFC, be_v, wd_v, 4, rs2, "C SW top via 0xFFFFFFFC");
    rs2 = $urandom(rng); spec_lanes(1, 32'hFFFF_FFFF, rs2, 32'hFFFF_FFFF, be_v, wd_v);
    op_cycle(1'b1, 32'hFFFF_FFFF, be_v, wd_v, 1, rs2, "C SB last byte via 0xFFFFFFFF");
    rs2 = $urandom(rng); spec_lanes(4, 32'h0001_0000, rs2, 32'h0, be_v, wd_v);
    op_cycle(1'b1, 32'h0001_0000, be_v, wd_v, 4, rs2, "C SW word 0 via 0x00010000");
    rs2 = $urandom(rng); spec_lanes(4, TOHOST_ADDR, rs2, 32'h0, be_v, wd_v);
    op_cycle(1'b1, TOHOST_ADDR, be_v, wd_v, 4, rs2, "C SW tohost");
    // imem must not have seen any of that
    iaddr = 32'h0; #1 chk(irdata, img_word(32'h0), "C imem word 0 after dmem store");
    iaddr = 32'hFFFC; #1 chk(irdata, img_word(32'hFFFC), "C imem top word after dmem store");

    // ===== D: directed glitches on hot words (also random in phase E).
    for (int i = 0; i < 8; i++) begin
      @(negedge clk); low_pulse();
      @(posedge clk); #1 high_glitch();
    end

    // ===== E: random cycles.
    for (int n = 0; n < N_OPS; n++) begin
      int pick;
      pick = $urandom(rng) % 10;
      // 1 in 4: the same word as the last op (write-then-write / write-then-read)
      if (n > 0 && $urandom(rng) % 4 == 0) w = byte_of(a) / 4;
      else                                 w = pick_word();
      lo   = $urandom(rng) % 4;
      junk = $urandom(rng);
      rs2  = $urandom(rng);
      case (pick)
        0, 1, 2: begin                                   // raw be write, any of 16 patterns
          a = make_addr(w, lo);
          op_cycle(1'b1, a, $urandom(rng), junk, 0, 32'h0, "E be write");
        end
        3, 4, 5: begin                                   // SB / SH / SW, aligned
          case ($urandom(rng) % 3)
            0:       size = 1;
            1:       size = 2;
            default: size = 4;
          endcase
          if (size == 2) lo = lo & 2;
          if (size == 4) lo = 0;
          a = make_addr(w, lo);
          spec_lanes(size, a, rs2, junk, be_v, wd_v);
          op_cycle(1'b1, a, be_v, wd_v, size, rs2, "E store");
        end
        6, 7: begin                                      // we=0, any be, junk data
          a = make_addr(w, lo);
          op_cycle(1'b0, a, $urandom(rng), junk, 0, 32'h0, "E we=0");
        end
        8: begin                                         // we=1, be=0000
          a = make_addr(w, lo);
          op_cycle(1'b1, a, 4'b0000, junk, 0, 32'h0, "E be=0000");
        end
        default: begin                                   // we=0, be=1111 (looks like SW)
          a = make_addr(w, 0);
          op_cycle(1'b0, a, 4'b1111, junk, 0, 32'h0, "E we=0 be=1111");
        end
      endcase
      if ($urandom(rng) % 6 == 0) high_glitch();
    end

    // ===== F: final sweep of both memories over all 64 KiB.
    @(negedge clk);
    dwe = 1'b0;
    for (w = 0; w < MEM_WORDS; w++) begin
      daddr = make_addr(w, $urandom(rng) % 4);
      iaddr = make_addr(w, $urandom(rng) % 4);
      dbe = $urandom(rng); dwdata = $urandom(rng);
      #1;
      chk(drdata, ref_word(daddr), $sformatf("F dmem word %0d", w));
      chk(irdata, img_word(iaddr), $sformatf("F imem word %0d", w));
    end

    // ---------------- summary ----------------
    $display("coverage: be writes 0000=%0d 0001=%0d 0010=%0d 0011=%0d 0100=%0d 0101=%0d 0110=%0d 0111=%0d",
             be_cov[0], be_cov[1], be_cov[2], be_cov[3], be_cov[4], be_cov[5], be_cov[6], be_cov[7]);
    $display("coverage: be writes 1000=%0d 1001=%0d 1010=%0d 1011=%0d 1100=%0d 1101=%0d 1110=%0d 1111=%0d",
             be_cov[8], be_cov[9], be_cov[10], be_cov[11], be_cov[12], be_cov[13], be_cov[14], be_cov[15]);
    $display("coverage: ops=%0d we0=%0d glitches=%0d interleaved_reads=%0d alias_addrs=%0d write_then_same_word=%0d",
             n_ops_done, n_we0, n_glitch, n_reads, n_alias, n_raw);
    if (errors == 0)
      $display("PASS mem_adv_tb: %0d checks, %0d ops, seed=%0d, hex=%s, bin=%s (%0d bytes)",
               checks, n_ops_done, seed, hexfile, binfile, nbytes);
    else
      $display("FAIL mem_adv_tb: %0d errors in %0d checks, seed=%0d, hex=%s", errors, checks, seed, hexfile);
    $finish;
  end

endmodule
