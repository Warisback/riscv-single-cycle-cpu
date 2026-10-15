`timescale 1ns/1ps
// sc_core_tb: runs one program on the single-cycle core (rv32i_sc_top) and checks it.
//
//   vvp build/sc_core_tb.vvp +hex=prog.hex [+trace=prog.rtl.trace] [+maxcycles=N] [+vcd=wave.vcd]
//
//   +hex=        memory image (imem and dmem read it themselves)
//   +trace=      write one line per executed instruction, in the same format as
//                tools/iss.py, so tools/compare.py can check the two line by line
//   +maxcycles=  give up after this many cycles (default 200000)
//   +vcd=        dump waveforms for GTKWave (only when given: VCD files are big)
//
// The trace is built only from the core's ret_* outputs. Five groups of
// immediate assertions (A1 to A5) are checked every cycle; any failure makes
// the run FAIL.
// The run ends when the store to TOHOST (0xFFF0) executes: TOHOST=1 means the
// program passed. Exactly one output line starts with PASS or FAIL.
module sc_core_tb;
  import rv_pkg::*;

  // ---------------------------------------------------------------- clock, reset, DUT
  logic clk = 1'b0;
  logic rst = 1'b1;
  always #5 clk = ~clk;                 // 10 ns clock period

  logic        ret_valid, ret_rd_we, ret_mem_we;
  logic [31:0] ret_pc, ret_instr, ret_rd_wdata, ret_mem_addr, ret_mem_wdata;
  logic [4:0]  ret_rd;
  logic [3:0]  ret_mem_be;

  rv32i_sc_top dut (.*);

  // Probes: internal signals the assertions look at (never the trace).
  logic [31:0] rf_x0, rs1_val, rs2_val;
  logic [4:0]  rs1, rs2;
  logic        illegal, st_misaligned, ld_misaligned;
  logic [1:0]  result_src;
  assign rf_x0         = dut.u_core.u_regfile.regs[0];
  assign rs1           = dut.u_core.rs1;
  assign rs2           = dut.u_core.rs2;
  assign rs1_val       = dut.u_core.rs1_val;
  assign rs2_val       = dut.u_core.rs2_val;
  assign illegal       = dut.u_core.illegal;
  assign result_src    = dut.u_core.result_src;
  assign st_misaligned = dut.u_core.st_misaligned;
  assign ld_misaligned = dut.u_core.ld_misaligned;

  // ---------------------------------------------------------------- settings and counters
  string trace_file, vcd_file;
  int    trace_fd     = 0;
  int    maxcycles    = 200000;
  int    cycle        = 0;            // rising edges since reset was released
  int    executed     = 0;            // instructions executed
  int    assert_fails = 0;
  bit    finished     = 1'b0;

  initial begin
    if ($value$plusargs("trace=%s", trace_file)) begin
      trace_fd = $fopen(trace_file, "w");
      if (trace_fd == 0) $display("sc_core_tb: cannot open trace file %s", trace_file);
    end
    void'($value$plusargs("maxcycles=%d", maxcycles));
    if ($value$plusargs("vcd=%s", vcd_file)) begin
      $dumpfile(vcd_file);
      $dumpvars(0, sc_core_tb);
    end
    // Synchronous reset over one rising edge: PC <= 0, registers <= 0.
    rst = 1'b1;
    @(posedge clk);
    #1 rst = 1'b0;
  end

  always @(posedge clk) if (!rst) cycle <= cycle + 1;

  // Everything is checked at the falling edge: the PC changed at the rising
  // edge, and by mid-cycle every combinational value of this instruction has
  // settled. The register and memory writes happen at the next rising edge.
  always @(negedge clk) begin
    if (!rst && !finished) begin
      check_assertions();
      if (ret_valid) execute_line();
      if (!finished && cycle >= maxcycles) finish_run(1'b1);
    end
  end

  // ---------------------------------------------------------------- assertions
  task automatic bad(input string msg);
    assert_fails++;
    if (assert_fails <= 20) $display("ASSERTION FAILED at cycle %0d: %s", cycle, msg);
  endtask

  function automatic bit legal_be(input logic [3:0] be);
    case (be)
      4'b0001, 4'b0010, 4'b0100, 4'b1000,   // SB
      4'b0011, 4'b1100,                     // SH
      4'b1111:  return 1'b1;                // SW
      default:  return 1'b0;
    endcase
  endfunction

  function automatic logic [31:0] lane_mask(input logic [3:0] be);
    return {{8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}};
  endfunction

  logic [171:0] ret_bundle;            // 1+32+32+1+5+32+1+32+4+32 = 172 bits: every ret_* output
  assign ret_bundle = {ret_valid, ret_pc, ret_instr, ret_rd_we, ret_rd, ret_rd_wdata,
                       ret_mem_we, ret_mem_addr, ret_mem_be, ret_mem_wdata};

  task automatic check_assertions();
    // A1. x0 is always 0: its storage never changes and both read ports return 0 for it.
    assert (rf_x0 == 32'd0) else bad($sformatf("A1 x0: the register file holds x0=%08x", rf_x0));
    assert (rs1 != 5'd0 || rs1_val == 32'd0) else bad("A1 x0: read port 1 returned nonzero for x0");
    assert (rs2 != 5'd0 || rs2_val == 32'd0) else bad("A1 x0: read port 2 returned nonzero for x0");

    // A2. Nothing on the retire interface is X or Z once reset is over.
    assert (!$isunknown(ret_bundle)) else bad($sformatf("A2 X/Z: a ret_* output is X or Z at pc %08x", ret_pc));

    // A3. Every executed instruction is a legal RV32I opcode (the test programs only contain those).
    assert (!illegal) else bad($sformatf("A3 illegal: instruction %08x at pc %08x has no RV32I opcode", ret_instr, ret_pc));

    // A4. A store is well formed: legal byte lanes, word address, data only in its lanes;
    //     and no load or store is misaligned (this core supports aligned accesses only).
    if (ret_mem_we) begin
      assert (legal_be(ret_mem_be)) else bad($sformatf("A4 store: illegal byte enables %b at pc %08x", ret_mem_be, ret_pc));
      assert (ret_mem_addr[1:0] == 2'b00) else bad($sformatf("A4 store: address %08x not word aligned", ret_mem_addr));
      assert ((ret_mem_wdata & ~lane_mask(ret_mem_be)) == 32'd0)
        else bad($sformatf("A4 store: data %08x has bits outside lanes %b", ret_mem_wdata, ret_mem_be));
      assert (!st_misaligned) else bad($sformatf("A4 store: misaligned store at pc %08x", ret_pc));
    end
    if (result_src == RES_MEM)
      assert (!ld_misaligned) else bad($sformatf("A4 load: misaligned load at pc %08x", ret_pc));
  endtask

  // A5. The PC sequence follows the program. The testbench works out where the
  // next instruction must be from the encoding and a shadow copy of the
  // registers that it updates only from ret_* (spec section 2.5.1-2.5.2).
  logic [31:0] shadow [0:31];
  logic [31:0] expected_pc = 32'd0;
  logic [31:0] previous_pc = 32'd0;
  initial for (int i = 0; i < 32; i++) shadow[i] = 32'd0;

  function automatic logic [31:0] next_pc_of(input logic [31:0] pc, input logic [31:0] instr);
    logic [31:0] a, b, imm_i, imm_b, imm_j;
    logic        taken;
    a     = shadow[instr[19:15]];
    b     = shadow[instr[24:20]];
    imm_i = {{20{instr[31]}}, instr[31:20]};
    imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
    case (instr[6:0])
      OP_JAL:  return pc + imm_j;
      OP_JALR: return (a + imm_i) & 32'hFFFF_FFFE;
      OP_BRANCH: begin
        case (instr[14:12])
          3'b000:  taken = (a == b);                    // BEQ
          3'b001:  taken = (a != b);                    // BNE
          3'b100:  taken = ($signed(a) <  $signed(b));  // BLT
          3'b101:  taken = ($signed(a) >= $signed(b));  // BGE
          3'b110:  taken = (a <  b);                    // BLTU
          3'b111:  taken = (a >= b);                    // BGEU
          default: taken = 1'b0;
        endcase
        return taken ? pc + imm_b : pc + 32'd4;
      end
      default: return pc + 32'd4;
    endcase
  endfunction

  // ---------------------------------------------------------------- one executed instruction
  task automatic execute_line();
    assert (ret_pc == expected_pc)
      else bad($sformatf("A5 pc sequence: pc %08x, expected %08x (next pc of the instruction at %08x)",
                         ret_pc, expected_pc, previous_pc));
    expected_pc = next_pc_of(ret_pc, ret_instr);   // uses register values from before this write
    previous_pc = ret_pc;
    if (ret_rd_we) shadow[ret_rd] = ret_rd_wdata;
    executed++;

    // Trace line:  <pc> <instr>[ x<rd>=<value>][ m[<word addr>]&<be>=<lane data>]
    if (trace_fd != 0) begin
      $fwrite(trace_fd, "%08x %08x", ret_pc, ret_instr);
      if (ret_rd_we)  $fwrite(trace_fd, " x%02d=%08x", ret_rd, ret_rd_wdata);
      if (ret_mem_we) $fwrite(trace_fd, " m[%08x]&%1x=%08x", ret_mem_addr, ret_mem_be, ret_mem_wdata);
      $fwrite(trace_fd, "\n");
    end

    if (ret_mem_we && ret_mem_addr == TOHOST_ADDR) finish_run(1'b0);
  endtask

  // ---------------------------------------------------------------- end of the run
  task automatic finish_run(input bit timed_out);
    int    cycles;
    string stats;
    finished = 1'b1;
    if (trace_fd != 0) $fclose(trace_fd);
    cycles = cycle + 1;                 // cycles 0..cycle inclusive
    stats = $sformatf("%0d instructions, %0d cycles, CPI %0.3f, %0d assertion failures",
                      executed, cycles, (executed > 0) ? real'(cycles) / real'(executed) : 0.0, assert_fails);
    if (timed_out) begin
      $display("FAIL timeout: no store to TOHOST in %0d cycles (%s)", maxcycles, stats);
    end else begin
      $display("TOHOST=%08x", ret_mem_wdata);
      if (ret_mem_wdata == 32'd1 && assert_fails == 0)
        $display("PASS %s", stats);
      else if (ret_mem_wdata != 32'd1)
        $display("FAIL test %0d (TOHOST=%08x): %s", ret_mem_wdata >> 1, ret_mem_wdata, stats);
      else
        $display("FAIL assertions: the program passed but %0d assertion(s) failed: %s", assert_fails, stats);
    end
    $finish;
  endtask

endmodule
