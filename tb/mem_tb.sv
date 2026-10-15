`timescale 1ns/1ps
// mem_tb: self-checking testbench for imem and dmem.
//
// Run from the repository root:
//   tools/run_unit.sh mem_tb +hex=tb/mem_test.hex [+seed=N]   image loaded
//   tools/run_unit.sh mem_tb [+seed=N]                        no image: all zero
//
// tb/mem_test.hex is 16 words assembled from tb/mem_test.S by
// tools/mem_test_gen.sh (as -march=rv32i, ld -Ttext=0, objcopy -O binary,
// then 4 little-endian bytes per line). image_word() below lists them.
//
// Reference model: ref_mem is a byte-addressed copy of the 64 KiB memory.
// Stores update it the way the ISA describes them, not the way dmem is built:
//   - SB/SH/SW store the low 8/16/32 bits of rs2           (spec 2.6, p.34)
//   - little-endian: the least-significant byte goes to the
//     lowest address, the others in ascending order        (spec 2.6, p.33)
// A word read is then {byte a+3, a+2, a+1, a}. dmem instead keeps 32-bit
// words and byte enables, so the two only agree if the lanes are right.
// Only address bits [15:0] exist (64 KiB, docs/DESIGN.md), so both models alias
// every 64 KiB; the tests below check that on purpose.
module mem_tb;
  import rv_pkg::*;

  // ---------------- DUTs ----------------
  logic        clk = 1'b0;
  logic [31:0] iaddr, irdata;
  logic [31:0] daddr, drdata, dwdata;
  logic        dwe;
  logic [3:0]  dbe;

  imem u_imem (.addr(iaddr), .rdata(irdata));
  dmem u_dmem (.clk(clk), .addr(daddr), .rdata(drdata), .we(dwe), .be(dbe), .wdata(dwdata));

  always #5 clk = ~clk;   // 10 ns period: posedge at 5, 15, 25, ...

  localparam int N_RANDOM   = 4000;        // random dmem/imem operations
  localparam int TIMEOUT_NS = 2_000_000;

  // ---------------- bookkeeping ----------------
  int    seed = 1;                         // +seed=N, printed in the summary
  int    rng;                              // RNG state: $urandom(rng) updates it
  int    errors = 0;
  int    directed_checks = 0;
  int    random_checks = 0;
  bit    in_random = 1'b0;
  bit    have_hex;
  string hexfile;
  int    be_hits [0:15];                   // random-phase coverage per be pattern
  int    alias_hits = 0;                   // random ops with addr[31:16] != 0
  int    raw_hits = 0;                     // op on the word written the cycle before

  logic [7:0] ref_mem [0:65535];           // reference model, one entry per byte

  // The 16 words of tb/mem_test.hex (from the objdump listing).
  // Without +hex the memories start all zero, so every word is expected 0.
  function automatic logic [31:0] image_word(input int i);
    if (!have_hex) return 32'h0000_0000;
    case (i)
      0:  return 32'h00500093;   // 0x00 addi x1,x0,5
      1:  return 32'h00700113;   // 0x04 addi x2,x0,7
      2:  return 32'h002081b3;   // 0x08 add  x3,x1,x2
      3:  return 32'h00008237;   // 0x0c lui  x4,0x8
      4:  return 32'h00322023;   // 0x10 sw   x3,0(x4)
      5:  return 32'h00022283;   // 0x14 lw   x5,0(x4)
      6:  return 32'h001200a3;   // 0x18 sb   x1,1(x4)
      7:  return 32'h00221123;   // 0x1c sh   x2,2(x4)
      8:  return 32'h00124303;   // 0x20 lbu  x6,1(x4)
      9:  return 32'h0000006f;   // 0x24 jal  x0,0x24 (jump to itself)
      10: return 32'h44332211;   // 0x28 .word, byte 0x11 at address 0x28
      11: return 32'hdeadbeef;   // 0x2c
      12: return 32'h80000000;   // 0x30
      13: return 32'hffffffff;   // 0x34
      14: return 32'h00000000;   // 0x38
      15: return 32'h0000ff00;   // 0x3c
      default: return 32'h0000_0000;   // past the end of the image
    endcase
  endfunction

  // ---------------- reference model ----------------
  // Word containing byte address a: little-endian, lowest address = bits 7:0.
  function automatic logic [31:0] ref_word(input logic [15:0] a);
    logic [15:0] base;
    base = {a[15:2], 2'b00};
    return {ref_mem[base + 3], ref_mem[base + 2], ref_mem[base + 1], ref_mem[base]};
  endfunction

  // SB (size 1), SH (size 2), SW (size 4): byte j of rs2 goes to address a+j.
  task automatic ref_store(input int size, input logic [31:0] a, input logic [31:0] rs2);
    for (int j = 0; j < size; j++)
      ref_mem[a[15:0] + j] = rs2[8*j +: 8];
  endtask

  // ---------------- checking helpers ----------------
  task automatic check(input logic [31:0] got, input logic [31:0] exp, input string what);
    if (in_random) random_checks++; else directed_checks++;
    if (got !== exp) begin
      errors++;
      if (errors <= 20)
        $display("ERROR t=%0t %s: got %08h expected %08h", $time, what, got, exp);
    end
  endtask

  // imem is combinational: set the address, let it settle, compare.
  task automatic imem_check(input logic [31:0] a, input logic [31:0] exp, input string what);
    iaddr = a;
    #1 check(irdata, exp, $sformatf("imem %s addr=%08h", what, a));
  endtask

  // One dmem clock cycle. Drive on the falling edge, then:
  //   before the rising edge rdata must still show the old word,
  //   after  the rising edge rdata must show the new word (read-after-write).
  task automatic dmem_cycle(input logic        we_i,
                            input logic [31:0] a,
                            input logic [3:0]  be_i,
                            input logic [31:0] wdata_i,
                            input logic [31:0] old_word,
                            input logic [31:0] new_word,
                            input string       what);
    @(negedge clk);
    daddr = a; dwe = we_i; dbe = be_i; dwdata = wdata_i;
    #1 check(drdata, old_word, $sformatf("dmem %s addr=%08h before edge", what, a));
    @(posedge clk);
    #1 check(drdata, new_word, $sformatf("dmem %s addr=%08h after edge", what, a));
  endtask

  // A read-only cycle: we=0 while be/wdata carry junk, so nothing may change.
  task automatic dmem_read(input logic [31:0] a, input logic [31:0] exp, input string what);
    dmem_cycle(1'b0, a, 4'b1111, 32'hBAD0_BAD0, exp, exp, what);
  endtask

  // An SB/SH/SW as the core will present it to dmem: be marks the lane(s)
  // chosen by a[1:0], wdata holds rs2 shifted into those lanes, and the
  // lanes outside be carry junk to prove dmem ignores them.
  task automatic store(input int size, input logic [31:0] a, input logic [31:0] rs2,
                       input logic [31:0] junk, input string what);
    logic [3:0]  be_v;
    logic [31:0] lanes, wdata_v, old_w, new_w;
    case (size)
      1:       be_v = 4'b0001 << a[1:0];   // SB: any byte
      2:       be_v = 4'b0011 << a[1:0];   // SH: a[1:0] is 0 or 2
      default: be_v = 4'b1111;             // SW: a[1:0] is 0
    endcase
    lanes   = {{8{be_v[3]}}, {8{be_v[2]}}, {8{be_v[1]}}, {8{be_v[0]}}};
    wdata_v = ((rs2 << (8 * a[1:0])) & lanes) | (junk & ~lanes);
    old_w = ref_word(a[15:0]);
    ref_store(size, a, rs2);
    new_w = ref_word(a[15:0]);
    if (in_random) be_hits[be_v]++;
    dmem_cycle(1'b1, a, be_v, wdata_v, old_w, new_w, what);
  endtask

  // ---------------- timeout ----------------
  initial begin
    #(TIMEOUT_NS);
    $display("FAIL mem_tb: timeout after %0d ns", TIMEOUT_NS);
    $finish;
  end

  // ---------------- main test ----------------
  initial begin
    logic [31:0] w;
    int          op, region, word_idx, last_word, lo;
    logic [31:0] a, hi;
    bit          last_was_write;

    // quiet inputs before the first clock edge
    iaddr = 32'h0; daddr = 32'h0; dwe = 1'b0; dbe = 4'b0000; dwdata = 32'h0;
    for (int k = 0; k < 16; k++) be_hits[k] = 0;

    void'($value$plusargs("seed=%d", seed));
    rng = seed;                          // keep seed unchanged for the summary line
    have_hex = $value$plusargs("hex=%s", hexfile);
    if (!have_hex) hexfile = "none";   // (Icarus 12 rejects a string/literal ?: mix)
    if (have_hex) $display("mem_tb: image %s, seed %0d", hexfile, seed);
    else          $display("mem_tb: no +hex, expecting all-zero memories, seed %0d", seed);

    // Reference model starts as the same image, bytes in little-endian order.
    for (int b = 0; b < 65536; b++) ref_mem[b] = 8'h00;
    for (int i = 0; i < 16; i++) begin
      w = image_word(i);
      ref_mem[4*i + 0] = w[7:0];
      ref_mem[4*i + 1] = w[15:8];
      ref_mem[4*i + 2] = w[23:16];
      ref_mem[4*i + 3] = w[31:24];
    end

    @(negedge clk);   // memories have run their initial blocks by now

    // ===== D1: imem returns each image word; addr[1:0] and addr[31:16] ignored
    for (int i = 0; i < 16; i++) begin
      for (int low = 0; low < 4; low++)
        imem_check(4*i + low, image_word(i), "image word");
      imem_check(32'h0001_0000 + 4*i, image_word(i), "alias +64KiB");
      imem_check(32'hFFFF_0000 + 4*i, image_word(i), "alias top");
    end

    // ===== D2: imem past the image is zero, up to the last word 0xFFFC
    imem_check(32'h0000_0040, 32'h0, "first word after image");
    imem_check(32'h0000_0400, 32'h0, "past image");
    imem_check(32'h0000_8000, 32'h0, "data region");
    imem_check(32'h0000_FFFC, 32'h0, "last word");

    // ===== D3: dmem holds the same image (one unified image, Harvard ports)
    for (int i = 0; i < 16; i++)
      dmem_read(4*i, image_word(i), "image word");
    dmem_read(32'h0000_0040, 32'h0, "first word after image");
    dmem_read(32'h0000_8000, 32'h0, "data region");
    dmem_read(TOHOST_ADDR,   32'h0, "tohost");

    // ===== D4: every be pattern used by SB/SH/SW, on a known background word.
    // Background 0x11223344 = bytes 44 33 22 11 at 0x8000..0x8003.
    store(4, 32'h8000, 32'h11223344, 32'hFFFF_FFFF, "SW background");
    check(drdata, 32'h11223344, "SW background value");
    store(1, 32'h8000, 32'h123456AA, 32'hFFFF_FFFF, "SB lane0 be=0001");
    check(drdata, 32'h112233AA, "SB lane0 value");

    store(4, 32'h8000, 32'h11223344, 32'hFFFF_FFFF, "SW background");
    store(1, 32'h8001, 32'h123456BB, 32'hFFFF_FFFF, "SB lane1 be=0010");
    check(drdata, 32'h1122BB44, "SB lane1 value");

    store(4, 32'h8000, 32'h11223344, 32'hFFFF_FFFF, "SW background");
    store(1, 32'h8002, 32'h123456CC, 32'hFFFF_FFFF, "SB lane2 be=0100");
    check(drdata, 32'h11CC3344, "SB lane2 value");

    store(4, 32'h8000, 32'h11223344, 32'hFFFF_FFFF, "SW background");
    store(1, 32'h8003, 32'h123456DD, 32'hFFFF_FFFF, "SB lane3 be=1000");
    check(drdata, 32'hDD223344, "SB lane3 value");

    store(4, 32'h8000, 32'h11223344, 32'hFFFF_FFFF, "SW background");
    store(2, 32'h8000, 32'h9999BEEF, 32'hFFFF_FFFF, "SH low be=0011");
    check(drdata, 32'h1122BEEF, "SH low value");

    store(4, 32'h8000, 32'h11223344, 32'hFFFF_FFFF, "SW background");
    store(2, 32'h8002, 32'h9999CAFE, 32'hFFFF_FFFF, "SH high be=1100");
    check(drdata, 32'hCAFE3344, "SH high value");

    store(4, 32'h8000, 32'hA5A55A5A, 32'hFFFF_FFFF, "SW be=1111");
    check(drdata, 32'hA5A55A5A, "SW value");

    // ===== D5: four SBs on back-to-back cycles build one word.
    // Little-endian: 0x11 at the lowest address ends up in bits 7:0,
    // giving the same word as image word 10 (.word 0x44332211).
    store(1, 32'h8010, 32'h11, 32'h0, "SB 0x8010");
    store(1, 32'h8011, 32'h22, 32'h0, "SB 0x8011");
    store(1, 32'h8012, 32'h33, 32'h0, "SB 0x8012");
    store(1, 32'h8013, 32'h44, 32'h0, "SB 0x8013");
    check(drdata, 32'h44332211, "4x SB little-endian word");

    // Two SHs: low half at 0x8020, high half at 0x8022.
    store(2, 32'h8020, 32'hBEEF, 32'h0, "SH 0x8020");
    store(2, 32'h8022, 32'hDEAD, 32'h0, "SH 0x8022");
    check(drdata, 32'hDEADBEEF, "2x SH little-endian word");

    // ===== D6: no write without we, and no write with be=0000
    dmem_cycle(1'b0, 32'h8000, 4'b1111, 32'h0BAD0BAD, 32'hA5A55A5A, 32'hA5A55A5A, "we=0 be=1111");
    dmem_cycle(1'b1, 32'h8000, 4'b0000, 32'h0BAD0BAD, 32'hA5A55A5A, 32'hA5A55A5A, "we=1 be=0000");

    // ===== D7: dmem ignores addr[1:0]; be alone picks the lane.
    // addr 0x8033 with be=0001 writes byte 0x8030 (lane 0), not 0x8033.
    dmem_cycle(1'b1, 32'h8033, 4'b0001, 32'h000000C3, 32'h0, 32'h000000C3, "raw be=0001 addr[1:0]=11");
    ref_store(1, 32'h8030, 32'hC3);   // keep the reference in step
    dmem_read(32'h8030, 32'h000000C3, "word 0x8030");

    // ===== D8: only addr[15:2] selects the word, so addresses alias every 64 KiB
    store(4, 32'h0001_8040, 32'h600DF00D, 32'h0, "SW via alias 0x00018040");
    dmem_read(32'h0000_8040, 32'h600DF00D, "read 0x00008040");
    dmem_read(32'hFFFF_8043, 32'h600DF00D, "read 0xFFFF8043");
    store(4, 32'hABCD_FFFC, 32'h7E57CA5E, 32'h0, "SW via alias 0xABCDFFFC");
    dmem_read(32'h0000_FFFC, 32'h7E57CA5E, "read last word 0xFFFC");

    // ===== D9: Harvard: a store to dmem does not change imem
    store(4, 32'h0000_0000, 32'hFFFF_FFFF, 32'h0, "SW over code word 0");
    imem_check(32'h0000_0000, image_word(0), "word 0 after dmem store");
    dmem_read(32'h0000_0000, 32'hFFFF_FFFF, "word 0 after store");

    // ===== D10: tohost is ordinary memory to dmem (the top level watches it)
    store(4, TOHOST_ADDR, 32'h0000_0001, 32'h0, "SW tohost");
    dmem_read(TOHOST_ADDR, 32'h0000_0001, "tohost readback");

    // ===== Random phase: SB/SH/SW/reads on three small windows with random
    // aliasing bits, so read-after-write and overwrites happen often.
    in_random = 1'b1;
    last_word = 32'h2000;
    last_was_write = 1'b0;
    for (int n = 0; n < N_RANDOM; n++) begin
      op = $urandom(rng) % 10;

      // pick a word: 1 in 4 reuse the previous one, else one of 3 windows
      if ($urandom(rng) % 4 == 0) begin
        word_idx = last_word;
      end else begin
        region = $urandom(rng) % 3;
        case (region)
          0:       word_idx = 32'h0000 + $urandom(rng) % 16;   // code (0x0000-0x003F)
          1:       word_idx = 32'h2000 + $urandom(rng) % 16;   // data (0x8000-0x803F)
          default: word_idx = 32'h3FF0 + $urandom(rng) % 16;   // top  (0xFFC0-0xFFFF)
        endcase
      end
      if (last_was_write && word_idx == last_word) raw_hits++;

      // upper 16 bits random half the time (aliasing), else zero
      hi = ($urandom(rng) % 2) ? ($urandom(rng) << 16) : 32'h0;
      if (hi != 0) alias_hits++;

      case (op)
        0, 1, 2: begin                           // SB, any byte
          lo = $urandom(rng) % 4;
          a  = hi | (word_idx << 2) | lo;
          store(1, a, $urandom(rng), $urandom(rng), "rand SB");
        end
        3, 4: begin                              // SH, aligned halves
          lo = 2 * ($urandom(rng) % 2);
          a  = hi | (word_idx << 2) | lo;
          store(2, a, $urandom(rng), $urandom(rng), "rand SH");
        end
        5, 6: begin                              // SW
          a = hi | (word_idx << 2);
          store(4, a, $urandom(rng), $urandom(rng), "rand SW");
        end
        7, 8: begin                              // read, we=0 with junk be/wdata
          a = hi | (word_idx << 2) | ($urandom(rng) % 4);
          dmem_read(a, ref_word(a[15:0]), "rand read");
        end
        default: begin                           // imem read anywhere
          word_idx = ($urandom(rng) % 2) ? ($urandom(rng) % 32) : ($urandom(rng) % MEM_WORDS);
          a = hi | (word_idx << 2) | ($urandom(rng) % 4);
          imem_check(a, image_word(word_idx), "rand read");
        end
      endcase
      last_was_write = (op <= 6);
      last_word      = word_idx;
    end

    // Final sweep: every word in the three windows matches the reference,
    // and imem still holds the original image (dmem stores never reach it).
    for (int i = 0; i < 16; i++) begin
      dmem_read(32'h0000 + 4*i, ref_word(16'h0000 + 4*i), "sweep code");
      dmem_read(32'h8000 + 4*i, ref_word(16'h8000 + 4*i), "sweep data");
      dmem_read(32'hFFC0 + 4*i, ref_word(16'hFFC0 + 4*i), "sweep top");
      imem_check(4*i, image_word(i), "sweep image");
    end

    // ---------------- summary ----------------
    $display("coverage: be 0001=%0d 0010=%0d 0100=%0d 1000=%0d 0011=%0d 1100=%0d 1111=%0d, alias=%0d, write-then-same-word=%0d",
             be_hits[1], be_hits[2], be_hits[4], be_hits[8], be_hits[3], be_hits[12], be_hits[15],
             alias_hits, raw_hits);
    if (errors == 0)
      $display("PASS mem_tb: %0d directed + %0d random checks, seed=%0d, hex=%s",
               directed_checks, random_checks, seed, hexfile);
    else
      $display("FAIL mem_tb: %0d errors in %0d directed + %0d random checks, seed=%0d",
               errors, directed_checks, random_checks, seed);
    $finish;
  end

endmodule
