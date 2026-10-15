`timescale 1ns/1ps
// maindec_tb: self-checking test of the main decoder.
//
// Reference model = a control table written row by row, one row per RV32I
// opcode. The opcode column is typed in as the bit pattern printed in the
// spec's RV32I listing (Unprivileged ISA v20260120, ch. 36, pp. 585-586), not
// taken from rv_pkg, so a typo in the package would be caught too. The
// control columns use the design's own encodings (docs/DESIGN.md item 5).
//
// Phase 1 (directed): all 128 opcode values. Opcodes in the table must match
//   their row exactly; every other value must give illegal=1 and all 0.
// Phase 2 (random):   seeded random 32-bit instruction words, half of them
//   forced to a legal opcode. Each is checked against the table and against
//   format rules that follow from the spec's instruction formats.
//
// Plusargs: +seed=N (default 1)   +nrand=N (default 2000)
module maindec_tb;
  import rv_pkg::*;

  // ---- DUT ----
  logic [6:0] opcode;
  logic       reg_write, mem_write, branch, jump, jalr, alu_src_b;
  logic       uses_rs1, uses_rs2, illegal;
  logic [1:0] result_src, alu_src_a, alu_op;
  logic [2:0] imm_src;

  maindec dut (
    .opcode(opcode), .reg_write(reg_write), .result_src(result_src),
    .mem_write(mem_write), .branch(branch), .jump(jump), .jalr(jalr),
    .alu_src_a(alu_src_a), .alu_src_b(alu_src_b), .imm_src(imm_src),
    .alu_op(alu_op), .uses_rs1(uses_rs1), .uses_rs2(uses_rs2),
    .illegal(illegal)
  );

  // All 13 outputs packed together so one !== compares everything.
  typedef struct packed {
    logic       reg_write;
    logic [1:0] result_src;
    logic       mem_write;
    logic       branch;
    logic       jump;
    logic       jalr;
    logic [1:0] alu_src_a;
    logic       alu_src_b;
    logic [2:0] imm_src;
    logic [1:0] alu_op;
    logic       uses_rs1;
    logic       uses_rs2;
    logic       illegal;
  } ctrl_t;

  ctrl_t got;
  assign got = {reg_write, result_src, mem_write, branch, jump, jalr,
                alu_src_a, alu_src_b, imm_src, alu_op, uses_rs1, uses_rs2,
                illegal};

  // ---- Reference table, indexed by opcode ----
  ctrl_t exp_tab  [0:127];
  bit    in_table [0:127];
  string name_tab [0:127];

  // An unknown opcode: illegal=1 and every other control 0.
  localparam ctrl_t ILLEGAL_CTRL = 18'b0_00_0_0_0_0_00_0_000_00_0_0_1;

  task automatic add_row(input string nm, input logic [6:0] opc,
                         input logic rw, input logic [1:0] res,
                         input logic mw, input logic br, input logic jp,
                         input logic jr, input logic [1:0] srca,
                         input logic srcb, input logic [2:0] imm,
                         input logic [1:0] aop, input logic r1,
                         input logic r2);
    ctrl_t c;
    c = {rw, res, mw, br, jp, jr, srca, srcb, imm, aop, r1, r2, 1'b0};
    exp_tab[opc]  = c;
    in_table[opc] = 1'b1;
    name_tab[opc] = nm;
  endtask

  task automatic build_table();
    for (int i = 0; i < 128; i++) begin
      exp_tab[i]  = ILLEGAL_CTRL;
      in_table[i] = 1'b0;
      name_tab[i] = "illegal";
    end
    // Fields an instruction does not use are 0 (design convention).
    //       name       opcode(spec)  rw res      mw br jp jr srcA       B imm    aluop        rs1 rs2
    add_row("LUI",     7'b0110111,   1, RES_ALU, 0, 0, 0, 0, SRCA_ZERO, 1, IMM_U, ALUOP_ADD,   0, 0);
    add_row("AUIPC",   7'b0010111,   1, RES_ALU, 0, 0, 0, 0, SRCA_PC,   1, IMM_U, ALUOP_ADD,   0, 0);
    add_row("JAL",     7'b1101111,   1, RES_PC4, 0, 0, 1, 0, SRCA_RS1,  0, IMM_J, ALUOP_ADD,   0, 0);
    add_row("JALR",    7'b1100111,   1, RES_PC4, 0, 0, 0, 1, SRCA_RS1,  0, IMM_I, ALUOP_ADD,   1, 0);
    add_row("BRANCH",  7'b1100011,   0, RES_ALU, 0, 1, 0, 0, SRCA_RS1,  0, IMM_B, ALUOP_ADD,   1, 1);
    add_row("LOAD",    7'b0000011,   1, RES_MEM, 0, 0, 0, 0, SRCA_RS1,  1, IMM_I, ALUOP_ADD,   1, 0);
    add_row("STORE",   7'b0100011,   0, RES_ALU, 1, 0, 0, 0, SRCA_RS1,  1, IMM_S, ALUOP_ADD,   1, 1);
    add_row("OP-IMM",  7'b0010011,   1, RES_ALU, 0, 0, 0, 0, SRCA_RS1,  1, IMM_I, ALUOP_FUNCT, 1, 0);
    add_row("OP",      7'b0110011,   1, RES_ALU, 0, 0, 0, 0, SRCA_RS1,  0, 3'b000, ALUOP_FUNCT, 1, 1);
    // FENCE: spec 2.7 says base implementations ignore its rs1/rd fields.
    add_row("FENCE",   7'b0001111,   0, RES_ALU, 0, 0, 0, 0, SRCA_RS1,  0, 3'b000, ALUOP_ADD, 0, 0);
    // SYSTEM: ECALL/EBREAK (rs1=rd=0 in their encoding), executed as NOP here.
    add_row("SYSTEM",  7'b1110011,   0, RES_ALU, 0, 0, 0, 0, SRCA_RS1,  0, 3'b000, ALUOP_ADD, 0, 0);
  endtask

  // ---- Checking ----
  int errors     = 0;
  int n_directed = 0;
  int n_random   = 0;

  // Print every field that differs (only the first 20 failures, to keep logs short).
  task automatic report(input string why, input logic [6:0] opc,
                        input ctrl_t exp, input ctrl_t act);
    errors++;
    if (errors <= 20) begin
      $display("ERROR %s opcode=%b (%s)", why, opc, name_tab[opc]);
      if (exp.reg_write  !== act.reg_write)  $display("   reg_write  exp %b got %b", exp.reg_write,  act.reg_write);
      if (exp.result_src !== act.result_src) $display("   result_src exp %b got %b", exp.result_src, act.result_src);
      if (exp.mem_write  !== act.mem_write)  $display("   mem_write  exp %b got %b", exp.mem_write,  act.mem_write);
      if (exp.branch     !== act.branch)     $display("   branch     exp %b got %b", exp.branch,     act.branch);
      if (exp.jump       !== act.jump)       $display("   jump       exp %b got %b", exp.jump,       act.jump);
      if (exp.jalr       !== act.jalr)       $display("   jalr       exp %b got %b", exp.jalr,       act.jalr);
      if (exp.alu_src_a  !== act.alu_src_a)  $display("   alu_src_a  exp %b got %b", exp.alu_src_a,  act.alu_src_a);
      if (exp.alu_src_b  !== act.alu_src_b)  $display("   alu_src_b  exp %b got %b", exp.alu_src_b,  act.alu_src_b);
      if (exp.imm_src    !== act.imm_src)    $display("   imm_src    exp %b got %b", exp.imm_src,    act.imm_src);
      if (exp.alu_op     !== act.alu_op)     $display("   alu_op     exp %b got %b", exp.alu_op,     act.alu_op);
      if (exp.uses_rs1   !== act.uses_rs1)   $display("   uses_rs1   exp %b got %b", exp.uses_rs1,   act.uses_rs1);
      if (exp.uses_rs2   !== act.uses_rs2)   $display("   uses_rs2   exp %b got %b", exp.uses_rs2,   act.uses_rs2);
      if (exp.illegal    !== act.illegal)    $display("   illegal    exp %b got %b", exp.illegal,    act.illegal);
    end
  endtask

  // Drive one opcode and compare all outputs with the table row.
  task automatic check_table(input logic [6:0] opc);
    opcode = opc;
    #1;
    if (got !== exp_tab[opc]) report("table", opc, exp_tab[opc], got);
  endtask

  // Rules that follow from the spec's formats (pp. 25-26, 585-586), checked
  // independently of the table. Uses whatever is on the outputs right now.
  task automatic check_rules(input logic [6:0] opc);
    bit ok;
    string rule;
    ok = 1; rule = "";
    // an illegal opcode must not change any state or redirect the pc
    if (illegal && (got !== ILLEGAL_CTRL))              begin ok = 0; rule = "illegal => all 0"; end
    // S-type and B-type have no rd field, so stores and branches never write rd
    if ((mem_write || branch) && reg_write)              begin ok = 0; rule = "store/branch write rd"; end
    // JAL and JALR write pc+4 to rd (2.5.1, p. 30)
    if ((jump || jalr) && !(reg_write && result_src == RES_PC4))
                                                         begin ok = 0; rule = "jump must link pc+4"; end
    // at most one kind of control transfer
    if ((branch + jump + jalr) > 1)                      begin ok = 0; rule = "two pc sources"; end
    // only loads take the result from memory
    if ((result_src == RES_MEM) !== (opc == 7'b0000011)) begin ok = 0; rule = "RES_MEM iff LOAD"; end
    // only R, S and B formats have an rs2 field
    if (uses_rs2 && !(opc == 7'b0110011 || opc == 7'b0100011 || opc == 7'b1100011))
                                                         begin ok = 0; rule = "uses_rs2 without rs2 field"; end
    // U and J formats have no rs1 field
    if (uses_rs1 && (opc == 7'b0110111 || opc == 7'b0010111 || opc == 7'b1101111))
                                                         begin ok = 0; rule = "uses_rs1 on U/J format"; end
    if (!ok) begin
      errors++;
      if (errors <= 20) $display("ERROR rule '%s' broken for opcode=%b (%s)", rule, opc, name_tab[opc]);
    end
  endtask

  // ---- Stimulus ----
  int          seed;        // RNG state: $urandom(seed) updates it every call
  int          start_seed;  // the +seed value, kept for the summary line
  int          nrand;
  logic [31:0] instr;
  int          k;
  int          hits [0:127];   // how often each opcode was seen in phase 2
  int          n_legal_hit;

  initial begin
    if (!$value$plusargs("seed=%d", seed))   seed  = 1;
    start_seed = seed;
    if (!$value$plusargs("nrand=%d", nrand)) nrand = 2000;
    build_table();

    // Phase 1: every one of the 128 opcode values.
    for (int i = 0; i < 128; i++) begin
      check_table(i[6:0]);
      check_rules(i[6:0]);
      n_directed++;
    end

    // Named corner cases (already inside the sweep above; repeated by name so
    // a failure message points straight at them):
    // opcode[1:0] != 2'b11 is not a 32-bit RV32I opcode (Table 72 is inst[1:0]=11).
    check_table(7'b0010000);  n_directed++;   // OP-IMM with low bits 00
    check_table(7'b0110010);  n_directed++;   // OP with low bits 10
    // neighbours of real opcodes that are reserved/other extensions
    check_table(7'b0111011);  n_directed++;   // OP-32 (RV64 only)
    check_table(7'b0011011);  n_directed++;   // OP-IMM-32 (RV64 only)
    check_table(7'b0101111);  n_directed++;   // AMO (A extension)
    check_table(7'b0000111);  n_directed++;   // LOAD-FP (F extension)
    check_table(7'b1010011);  n_directed++;   // OP-FP (F extension)

    // Phase 2: seeded random instruction words.
    for (int i = 0; i < 128; i++) hits[i] = 0;
    instr = $urandom(seed);  // first draw from a small seed is weak: discard
    for (int n = 0; n < nrand; n++) begin
      instr = $urandom(seed);
      if (instr[31]) begin                        // half the time: a legal opcode
        k = $urandom(seed) % 11;
        instr[6:0] = legal_opcode(k);
      end
      check_table(instr[6:0]);
      check_rules(instr[6:0]);
      hits[instr[6:0]]++;
      n_random++;
    end
    n_legal_hit = 0;
    for (int i = 0; i < 11; i++) if (hits[legal_opcode(i)] > 0) n_legal_hit++;
    $display("random coverage: %0d/11 legal opcodes hit, %0d distinct opcodes",
             n_legal_hit, count_distinct());
    if (n_legal_hit != 11) begin
      errors++;
      $display("ERROR random phase did not hit every legal opcode");
    end

    if (errors == 0)
      $display("PASS maindec_tb: %0d directed + %0d random checks, 0 errors (seed=%0d)",
               n_directed, n_random, start_seed);
    else
      $display("FAIL maindec_tb: %0d errors in %0d directed + %0d random checks (seed=%0d)",
               errors, n_directed, n_random, start_seed);
    $finish;
  end

  // The 11 RV32I opcodes (spec listing pp. 585-586), numbered 0..10.
  // (A function instead of an array: Icarus 12 cannot assign '{...} to a
  // whole unpacked array, and crashed on a packed 2-D constant indexed by
  // an expression.)
  function automatic logic [6:0] legal_opcode(input int idx);
    case (idx)
      0:       return 7'b0110111;  // LUI
      1:       return 7'b0010111;  // AUIPC
      2:       return 7'b1101111;  // JAL
      3:       return 7'b1100111;  // JALR
      4:       return 7'b1100011;  // BRANCH
      5:       return 7'b0000011;  // LOAD
      6:       return 7'b0100011;  // STORE
      7:       return 7'b0010011;  // OP-IMM
      8:       return 7'b0110011;  // OP
      9:       return 7'b0001111;  // FENCE (MISC-MEM)
      default: return 7'b1110011;  // SYSTEM
    endcase
  endfunction

  function automatic int count_distinct();
    int d;
    d = 0;
    for (int i = 0; i < 128; i++) if (hits[i] > 0) d++;
    return d;
  endfunction

endmodule
