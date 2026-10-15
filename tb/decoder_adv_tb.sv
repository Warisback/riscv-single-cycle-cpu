`timescale 1ns/1ps
// decoder_adv_tb: adversarial test of maindec + aludec, with GNU as as the oracle.
//
// tools/decoder_adv_gen.py had GNU as 2.45.50 (-march=rv32i) assemble every
// instruction of the RV32I listing (Unprivileged ISA v20260120, ch. 36,
// pp. 585-586): directed corner cases plus random instances. Each line of the
// vector file holds: the mnemonic, the immediate as typed in the source, and
// the 32-bit word GNU as produced. Run it with tools/decoder_adv_run.sh.
//
// The word goes through the decode logic exactly as sc_core.sv wires it:
//   maindec(opcode = instr[6:0]) --alu_op--> aludec(funct3 = instr[14:12],
//                                            funct7b5 = instr[30], opb5 = instr[5])
// and three separate checks are made on it:
//  A. table:   all 13 maindec outputs + alu_ctrl == the row for that mnemonic
//              (docs/DESIGN.md items 5 and 6; fields an instruction does not use = 0).
//  B. format:  uses_rs1 / uses_rs2 from the listing's format column:
//              R, S, B read rs1 and rs2; I reads rs1 only; U and J read neither.
//  C. execute: the controls drive a one-instruction execute slice made of the
//              real immgen, alu and branch_unit, wired as in sc_core.sv
//              (operand muxes, target adder, pc_src, write-back value). Its
//              effect (rd written and its value, load/store address, store
//              data, next pc) must equal a reference written from the spec
//              text (sections 2.4 to 2.6) that uses the typed immediate, not
//              one decoded from the word.
//              The reference also tells which of rs1/rs2 an instruction really
//              reads (flip the value, see if any effect changes). If it reads
//              one, uses_rs1/uses_rs2 must be 1.
// Words from other extensions (M, A, F, Zicsr, Zifencei, RV64I, custom-0, raw)
// get check A only. Those that share an RV32I opcode print a NOTE: maindec
// sees only the opcode, so it cannot flag them (docs/DESIGN.md item 5).
//
// Plusargs: +seed=N (default 1)   +ntrial=N random operand sets per word (default 24)
//           +vec=<file> +cnt=<file> (default build/decoder_adv/vectors.hex / vectors_count.txt)
//           +skip_table  turn check A off (mutation runs: do B and C catch it alone?)
module decoder_adv_tb;
  import rv_pkg::*;

  // ---------------- decode logic, wired as in sc_core.sv ----------------
  logic [31:0] instr;
  logic        reg_write, mem_write, branch, jump, jalr, alu_src_b;
  logic        uses_rs1, uses_rs2, illegal;
  logic [1:0]  result_src, alu_src_a, alu_op;
  logic [2:0]  imm_src;
  logic [3:0]  alu_ctrl;

  maindec u_maindec (
    .opcode(instr[6:0]), .reg_write(reg_write), .result_src(result_src),
    .mem_write(mem_write), .branch(branch), .jump(jump), .jalr(jalr),
    .alu_src_a(alu_src_a), .alu_src_b(alu_src_b), .imm_src(imm_src),
    .alu_op(alu_op), .uses_rs1(uses_rs1), .uses_rs2(uses_rs2), .illegal(illegal)
  );

  aludec u_aludec (
    .alu_op(alu_op), .funct3(instr[14:12]), .funct7b5(instr[30]),
    .opb5(instr[5]), .alu_ctrl(alu_ctrl)
  );

  // ---------------- one-instruction execute slice ----------------
  logic [31:0] rs1v, rs2v, pc;            // register values and pc for one trial
  logic [31:0] imm_ext, src_a, src_b, alu_y, pc_target, next_pc, ex_result;
  logic        taken, pc_src;

  immgen      u_immgen (.instr(instr[31:7]), .imm_src(imm_src), .imm_ext(imm_ext));
  alu         u_alu    (.a(src_a), .b(src_b), .alu_ctrl(alu_ctrl), .y(alu_y));
  branch_unit u_branch (.a(rs1v), .b(rs2v), .funct3(instr[14:12]), .taken(taken));

  always_comb begin
    case (alu_src_a)                      // an unused select gives X so a check fails
      SRCA_RS1:  src_a = rs1v;
      SRCA_PC:   src_a = pc;
      SRCA_ZERO: src_a = 32'b0;
      default:   src_a = 32'bx;
    endcase
  end
  assign src_b     = alu_src_b ? imm_ext : rs2v;
  assign pc_target = jalr ? ((rs1v + imm_ext) & ~32'd1) : (pc + imm_ext);
  assign pc_src    = (branch && taken) || jump || jalr;
  assign next_pc   = pc_src ? pc_target : pc + 32'd4;
  assign ex_result = (result_src == RES_PC4) ? pc + 32'd4 : alu_y;

  // ---------------- check A: the expected control row per mnemonic ----------------
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
    logic [3:0] alu_ctrl;
  } dec_t;

  dec_t got;
  assign got = {reg_write, result_src, mem_write, branch, jump, jalr, alu_src_a,
                alu_src_b, imm_src, alu_op, uses_rs1, uses_rs2, illegal, alu_ctrl};

  function automatic dec_t row(input logic rw, input logic [1:0] res, input logic mw,
                               input logic br, input logic jp, input logic jr,
                               input logic [1:0] srca, input logic srcb,
                               input logic [2:0] imm, input logic [1:0] aop,
                               input logic r1, input logic r2, input logic ill,
                               input logic [3:0] alu);
    return {rw, res, mw, br, jp, jr, srca, srcb, imm, aop, r1, r2, ill, alu};
  endfunction

  // Rows by instruction kind. "imm" for OP / NOP / illegal is 000 (unused, so 0 by the docs/DESIGN.md convention).
  //                                            rw res      mw br jp jr srcA       B imm     aluop        r1 r2 ill alu
  function automatic dec_t r_op_imm(input logic [3:0] a); return row(1, RES_ALU, 0, 0, 0, 0, SRCA_RS1,  1, IMM_I,  ALUOP_FUNCT, 1, 0, 0, a);       endfunction
  function automatic dec_t r_op    (input logic [3:0] a); return row(1, RES_ALU, 0, 0, 0, 0, SRCA_RS1,  0, 3'b000, ALUOP_FUNCT, 1, 1, 0, a);       endfunction
  function automatic dec_t r_load  ();                    return row(1, RES_MEM, 0, 0, 0, 0, SRCA_RS1,  1, IMM_I,  ALUOP_ADD,   1, 0, 0, ALU_ADD); endfunction
  function automatic dec_t r_store ();                    return row(0, RES_ALU, 1, 0, 0, 0, SRCA_RS1,  1, IMM_S,  ALUOP_ADD,   1, 1, 0, ALU_ADD); endfunction
  function automatic dec_t r_branch();                    return row(0, RES_ALU, 0, 1, 0, 0, SRCA_RS1,  0, IMM_B,  ALUOP_ADD,   1, 1, 0, ALU_ADD); endfunction
  function automatic dec_t r_nop   ();                    return row(0, RES_ALU, 0, 0, 0, 0, SRCA_RS1,  0, 3'b000, ALUOP_ADD,   0, 0, 0, ALU_ADD); endfunction
  function automatic dec_t r_illegal();                   return row(0, RES_ALU, 0, 0, 0, 0, SRCA_RS1,  0, 3'b000, ALUOP_ADD,   0, 0, 1, ALU_ADD); endfunction

  function automatic dec_t expect_row(input logic [127:0] mn);
    case (mn)
      "lui":    return row(1, RES_ALU, 0, 0, 0, 0, SRCA_ZERO, 1, IMM_U, ALUOP_ADD, 0, 0, 0, ALU_ADD);
      "auipc":  return row(1, RES_ALU, 0, 0, 0, 0, SRCA_PC,   1, IMM_U, ALUOP_ADD, 0, 0, 0, ALU_ADD);
      "jal":    return row(1, RES_PC4, 0, 0, 1, 0, SRCA_RS1,  0, IMM_J, ALUOP_ADD, 0, 0, 0, ALU_ADD);
      "jalr":   return row(1, RES_PC4, 0, 0, 0, 1, SRCA_RS1,  0, IMM_I, ALUOP_ADD, 1, 0, 0, ALU_ADD);
      "beq", "bne", "blt", "bge", "bltu", "bgeu":  return r_branch();
      "lb", "lh", "lw", "lbu", "lhu":              return r_load();
      "sb", "sh", "sw":                            return r_store();
      "addi":   return r_op_imm(ALU_ADD);
      "slti":   return r_op_imm(ALU_SLT);
      "sltiu":  return r_op_imm(ALU_SLTU);
      "xori":   return r_op_imm(ALU_XOR);
      "ori":    return r_op_imm(ALU_OR);
      "andi":   return r_op_imm(ALU_AND);
      "slli":   return r_op_imm(ALU_SLL);
      "srli":   return r_op_imm(ALU_SRL);
      "srai":   return r_op_imm(ALU_SRA);
      "add":    return r_op(ALU_ADD);
      "sub":    return r_op(ALU_SUB);
      "sll":    return r_op(ALU_SLL);
      "slt":    return r_op(ALU_SLT);
      "sltu":   return r_op(ALU_SLTU);
      "xor":    return r_op(ALU_XOR);
      "srl":    return r_op(ALU_SRL);
      "sra":    return r_op(ALU_SRA);
      "or":     return r_op(ALU_OR);
      "and":    return r_op(ALU_AND);
      "fence", "fence.tso", "pause", "ecall", "ebreak":  return r_nop();
      // ---- not RV32I, but the opcode is an RV32I opcode: decodes as that opcode ----
      "mul":    return r_op(ALU_ADD);    // OP, funct7 0000001, funct3 000
      "mulh":   return r_op(ALU_SLL);    //                     funct3 001
      "div":    return r_op(ALU_XOR);    //                     funct3 100
      "remu":   return r_op(ALU_AND);    //                     funct3 111
      "csrrw", "csrrs", "csrrwi", "fence.i":  return r_nop();
      "ld", "lwu":  return r_load();     // LOAD funct3 011 / 110
      "sd":         return r_store();    // STORE funct3 011
      // ---- opcodes that are not RV32I: must be flagged ----
      "lr.w", "amoadd.w", "flw", "fsw", "fadd.s", "fmadd.s",
      "addiw", "addw", "custom0", "word0", "wordF":  return r_illegal();
      default:  return 22'bx;            // unknown mnemonic: the caller reports it
    endcase
  endfunction

  // Foreign words that share an RV32I opcode (illegal cannot be raised for them).
  function automatic bit shares_opcode(input logic [127:0] mn);
    case (mn)
      "mul", "mulh", "div", "remu", "csrrw", "csrrs", "csrrwi",
      "fence.i", "ld", "lwu", "sd":  return 1;
      default:                       return 0;
    endcase
  endfunction

  // ---------------- check B: format column of the listing (pp. 585-586) ----------------
  function automatic byte fmt_of(input logic [127:0] mn);
    case (mn)
      "lui", "auipc":                              return "U";
      "jal":                                       return "J";
      "jalr", "lb", "lh", "lw", "lbu", "lhu",
      "addi", "slti", "sltiu", "xori", "ori", "andi",
      "slli", "srli", "srai":                      return "I";
      "beq", "bne", "blt", "bge", "bltu", "bgeu":  return "B";
      "sb", "sh", "sw":                            return "S";
      "add", "sub", "sll", "slt", "sltu", "xor",
      "srl", "sra", "or", "and":                   return "R";
      "fence", "fence.tso", "pause":               return "F";  // rs1 ignored (section 2.7, p. 35)
      "ecall", "ebreak":                           return "E";  // rs1 field is 0 (section 2.8, p. 36)
      default:                                     return "?";
    endcase
  endfunction

  // The 42 RV32I instructions of the listing, numbered for coverage.
  function automatic int rv32i_index(input logic [127:0] mn);
    case (mn)
      "lui": return 0;   "auipc": return 1;  "jal": return 2;    "jalr": return 3;
      "beq": return 4;   "bne": return 5;    "blt": return 6;    "bge": return 7;
      "bltu": return 8;  "bgeu": return 9;
      "lb": return 10;   "lh": return 11;    "lw": return 12;    "lbu": return 13;  "lhu": return 14;
      "sb": return 15;   "sh": return 16;    "sw": return 17;
      "addi": return 18; "slti": return 19;  "sltiu": return 20; "xori": return 21;
      "ori": return 22;  "andi": return 23;  "slli": return 24;  "srli": return 25; "srai": return 26;
      "add": return 27;  "sub": return 28;   "sll": return 29;   "slt": return 30;
      "sltu": return 31; "xor": return 32;   "srl": return 33;   "sra": return 34;
      "or": return 35;   "and": return 36;
      "fence": return 37; "fence.tso": return 38; "pause": return 39;
      "ecall": return 40; "ebreak": return 41;
      default: return -1;
    endcase
  endfunction

  // ---------------- check C: reference semantics from the spec text ----------------
  typedef struct packed {
    logic        wr;       // writes rd
    logic        ld;       // rd comes from memory (value not modelled)
    logic        st;       // writes memory
    logic [31:0] rd_val;   // value written to rd (0 if !wr or ld)
    logic [31:0] addr;     // load/store effective address (0 otherwise)
    logic [31:0] sdata;    // store data before lane placement (0 if !st)
    logic [31:0] npc;      // next pc
  } eff_t;

  // imm is the value typed in the assembly: I/S/shift value, U = the 20-bit
  // value (shifted here), B/J = the byte offset.
  function automatic eff_t ref_exec(input logic [127:0] mn, input logic [31:0] imm,
                                    input logic [31:0] a, input logic [31:0] b,
                                    input logic [31:0] p);
    eff_t r;
    logic [31:0] u;
    r     = '0;
    r.npc = p + 32'd4;
    u     = {imm[19:0], 12'b0};          // U-immediate: low 12 bits zero (section 2.4.1, p. 28)
    case (mn)
      // section 2.4.1, p. 28
      "lui":   begin r.wr = 1; r.rd_val = u;     end
      "auipc": begin r.wr = 1; r.rd_val = p + u; end
      // section 2.5.1, p. 30: link pc+4; JALR target = (rs1 + imm) with bit 0 cleared
      "jal":   begin r.wr = 1; r.rd_val = p + 32'd4; r.npc = p + imm;                 end
      "jalr":  begin r.wr = 1; r.rd_val = p + 32'd4; r.npc = (a + imm) & ~32'd1;      end
      // section 2.5.2, p. 31
      "beq":   if (a == b)                   r.npc = p + imm;
      "bne":   if (a != b)                   r.npc = p + imm;
      "blt":   if ($signed(a) <  $signed(b)) r.npc = p + imm;
      "bge":   if ($signed(a) >= $signed(b)) r.npc = p + imm;
      "bltu":  if (a <  b)                   r.npc = p + imm;
      "bgeu":  if (a >= b)                   r.npc = p + imm;
      // section 2.6, p. 33: address = rs1 + sign-extended offset; stores write rs2
      "lb", "lh", "lw", "lbu", "lhu":  begin r.wr = 1; r.ld = 1; r.addr = a + imm; end
      "sb", "sh", "sw":                begin r.st = 1; r.addr = a + imm; r.sdata = b; end
      // section 2.4.1, p. 28 (immediate already sign-extended to 32 bits)
      "addi":  begin r.wr = 1; r.rd_val = a + imm;                              end
      "slti":  begin r.wr = 1; r.rd_val = {31'b0, $signed(a) < $signed(imm)};   end
      "sltiu": begin r.wr = 1; r.rd_val = {31'b0, a < imm};                     end
      "xori":  begin r.wr = 1; r.rd_val = a ^ imm;                              end
      "ori":   begin r.wr = 1; r.rd_val = a | imm;                              end
      "andi":  begin r.wr = 1; r.rd_val = a & imm;                              end
      "slli":  begin r.wr = 1; r.rd_val = a << imm[4:0];                        end
      "srli":  begin r.wr = 1; r.rd_val = a >> imm[4:0];                        end
      "srai":  begin r.wr = 1; r.rd_val = $signed(a) >>> imm[4:0];              end
      // section 2.4.2, p. 29: shifts use the low 5 bits of rs2
      "add":   begin r.wr = 1; r.rd_val = a + b;                                end
      "sub":   begin r.wr = 1; r.rd_val = a - b;                                end
      "sll":   begin r.wr = 1; r.rd_val = a << b[4:0];                          end
      "slt":   begin r.wr = 1; r.rd_val = {31'b0, $signed(a) < $signed(b)};     end
      "sltu":  begin r.wr = 1; r.rd_val = {31'b0, a < b};                       end
      "xor":   begin r.wr = 1; r.rd_val = a ^ b;                                end
      "srl":   begin r.wr = 1; r.rd_val = a >> b[4:0];                          end
      "sra":   begin r.wr = 1; r.rd_val = $signed(a) >>> b[4:0];                end
      "or":    begin r.wr = 1; r.rd_val = a | b;                                end
      "and":   begin r.wr = 1; r.rd_val = a & b;                                end
      // FENCE (section 2.7), ECALL/EBREAK (section 2.8): executed as NOPs (docs/DESIGN.md item 5)
      default: ;
    endcase
    return r;
  endfunction

  // The same effect, read off the DUT's controls and the execute slice.
  function automatic eff_t dut_effect();
    eff_t d;
    d     = '0;
    d.wr  = reg_write;
    d.ld  = (result_src == RES_MEM);
    d.st  = mem_write;
    if (reg_write && !d.ld) d.rd_val = (result_src == 2'b11) ? 32'bx : ex_result;
    if (d.ld || d.st)       d.addr   = alu_y;
    if (d.st)               d.sdata  = rs2v;      // store data = rs2 (docs/DESIGN.md item 7)
    d.npc = next_pc;
    return d;
  endfunction

  function automatic string mn_str(input logic [127:0] m);
    string s;
    s = "";
    for (int i = 15; i >= 0; i--)
      if (m[8*i +: 8] != 8'h00) s = {s, $sformatf("%c", m[8*i +: 8])};
    return s;
  endfunction

  // ---------------- bookkeeping ----------------
  int errors = 0;
  int n_table = 0, n_format = 0, n_exec = 0, n_dep = 0;
  int n_rv32i = 0, n_foreign = 0, n_notes = 0;
  int hits    [0:41];
  int n_taken [0:41];
  int n_ntaken[0:41];
  int n_addi_b30 = 0;      // ADDI words with instr[30] = imm[10] = 1 (must still ADD)

  task automatic fail(input string msg);
    errors++;
    if (errors <= 25) $display("ERROR %s", msg);
  endtask

  // ---------------- stimulus ----------------
  logic [191:0] vec [0:4095];
  int           nvec, fd, ntrial, seed, start_seed;
  string        vfile, cfile;
  bit           skip_table;   // +skip_table: only checks B and C (to show they catch bugs alone)

  initial begin
    skip_table = $test$plusargs("skip_table");
    if (!$value$plusargs("seed=%d", seed))     seed   = 1;
    if (!$value$plusargs("ntrial=%d", ntrial)) ntrial = 24;
    if (!$value$plusargs("vec=%s", vfile))     vfile  = "build/decoder_adv/vectors.hex";
    if (!$value$plusargs("cnt=%s", cfile))     cfile  = "build/decoder_adv/vectors_count.txt";
    start_seed = seed;
    for (int i = 0; i < 42; i++) begin hits[i] = 0; n_taken[i] = 0; n_ntaken[i] = 0; end

    fd = $fopen(cfile, "r");
    if (fd == 0 || $fscanf(fd, "%d", nvec) != 1 || nvec < 1 || nvec > 4096) begin
      $display("FAIL decoder_adv_tb: cannot read vector count from %s (run tools/decoder_adv_run.sh)", cfile);
      $finish;
    end
    $fclose(fd);
    $readmemh(vfile, vec, 0, nvec - 1);
    fd = $urandom(seed);                 // first draw from a small seed is weak: discard

    for (int v = 0; v < nvec; v++) begin
      logic [127:0] mn;
      logic [31:0]  typed_imm;
      dec_t         exp;
      byte          f;
      int           idx;
      bit           dep1, dep2;
      string        tag;

      mn        = vec[v][191:64];
      typed_imm = vec[v][63:32];
      instr     = vec[v][31:0];
      rs1v = 0; rs2v = 0; pc = 0;
      #1;
      tag = $sformatf("#%0d %s (%h)", v, mn_str(mn), instr);

      // ---- A: control table ----
      exp = expect_row(mn);
      idx = rv32i_index(mn);
      if ((^exp) === 1'bx) begin
        fail({tag, ": mnemonic not in the expected table"});
        idx = -2;                          // skip the rest for this word
      end else begin
        n_table++;
        if (got !== exp && !skip_table)
          fail($sformatf("%s table: exp rw=%b res=%b mw=%b br=%b jp=%b jr=%b srcA=%b srcB=%b imm=%b aop=%b r1=%b r2=%b ill=%b alu=%0d | got rw=%b res=%b mw=%b br=%b jp=%b jr=%b srcA=%b srcB=%b imm=%b aop=%b r1=%b r2=%b ill=%b alu=%0d",
                 tag, exp.reg_write, exp.result_src, exp.mem_write, exp.branch, exp.jump, exp.jalr,
                 exp.alu_src_a, exp.alu_src_b, exp.imm_src, exp.alu_op, exp.uses_rs1, exp.uses_rs2,
                 exp.illegal, exp.alu_ctrl,
                 got.reg_write, got.result_src, got.mem_write, got.branch, got.jump, got.jalr,
                 got.alu_src_a, got.alu_src_b, got.imm_src, got.alu_op, got.uses_rs1, got.uses_rs2,
                 got.illegal, got.alu_ctrl));
      end

      if (idx == -1) begin                 // foreign word: table check only
        n_foreign++;
        if (shares_opcode(mn)) begin
          n_notes++;
          $display("NOTE %s is not RV32I but has an RV32I opcode: illegal=%b, runs as reg_write=%b mem_write=%b alu_ctrl=%0d",
                   tag, illegal, reg_write, mem_write, alu_ctrl);
        end
      end

      if (idx >= 0) begin                  // an RV32I instruction: checks B and C
        n_rv32i++;
        hits[idx]++;
        if (mn == "addi" && instr[30]) n_addi_b30++;

        // ---- B: uses_rs1 / uses_rs2 from the format ----
        f = fmt_of(mn);
        n_format++;
        if (uses_rs1 !== (f == "R" || f == "I" || f == "S" || f == "B"))
          fail($sformatf("%s format %c: uses_rs1=%b", tag, f, uses_rs1));
        if (uses_rs2 !== (f == "R" || f == "S" || f == "B"))
          fail($sformatf("%s format %c: uses_rs2=%b", tag, f, uses_rs2));
        if ((f == "U" || f == "J") && (uses_rs1 || uses_rs2))
          fail($sformatf("%s %c-type has no rs1/rs2 field but claims one", tag, f));

        // ---- C: execute with corner and random operands ----
        dep1 = 0; dep2 = 0;
        for (int t = 0; t < 8 + ntrial; t++) begin
          logic [31:0] a, b, p, da, db;
          eff_t        r, d;
          a = $urandom(seed); b = $urandom(seed); p = $urandom(seed) & ~32'd3;
          case (t)                              // corner operands first
            0: begin a = 0;            b = 0;            p = 0;            end
            1: begin                   b = a;                              end
            2: begin a = 32'h8000_0000; b = 32'h7fff_ffff; p = 32'hffff_fffc; end
            3: begin a = 32'h7fff_ffff; b = 32'h8000_0000;                 end
            4: begin a = 32'hffff_ffff; b = 32'd1;                         end
            5: begin a = 32'd1;         b = 32'hffff_ffff;                 end
            6: begin                   b = 32'hffff_ffe0 | b[4:0];         end  // shift amount with high bits set
            7: begin a = 32'hffff_ffff; b = 32'hffff_ffff;                 end
            default: if ($urandom(seed) % 4 == 0) b = a;                     // equal operands for BEQ/BGE
          endcase
          rs1v = a; rs2v = b; pc = p;
          #1;
          r = ref_exec(mn, typed_imm, a, b, p);
          d = dut_effect();
          n_exec++;
          if (d !== r)
            fail($sformatf("%s exec rs1=%h rs2=%h pc=%h: exp wr=%b ld=%b st=%b rd=%h addr=%h sdata=%h npc=%h | got wr=%b ld=%b st=%b rd=%h addr=%h sdata=%h npc=%h",
                           tag, a, b, p, r.wr, r.ld, r.st, r.rd_val, r.addr, r.sdata, r.npc,
                           d.wr, d.ld, d.st, d.rd_val, d.addr, d.sdata, d.npc));
          if (f == "B" && typed_imm != 32'd4) begin   // offset 4: both outcomes look alike
            if (r.npc == p + typed_imm) n_taken[idx]++;
            else                        n_ntaken[idx]++;
          end
          // does the instruction really read rs1 / rs2? flip bits and compare
          da = $urandom(seed); if (da == 0) da = 32'd1;
          db = $urandom(seed); if (db == 0) db = 32'd1;
          if (ref_exec(mn, typed_imm, a ^ da, b, p) !== r) dep1 = 1;
          if (ref_exec(mn, typed_imm, a, b ^ db, p) !== r) dep2 = 1;
        end
        n_dep++;
        if (dep1 && uses_rs1 !== 1'b1)
          fail($sformatf("%s reads rs1 (spec) but uses_rs1=%b", tag, uses_rs1));
        if (dep2 && uses_rs2 !== 1'b1)
          fail($sformatf("%s reads rs2 (spec) but uses_rs2=%b", tag, uses_rs2));
      end
    end

    // ---- coverage: every RV32I instruction, both branch outcomes, the ADDI trap ----
    for (int i = 0; i < 42; i++) begin
      if (hits[i] == 0) fail($sformatf("coverage: RV32I instruction #%0d never seen", i));
      if (i >= 4 && i <= 9 && (n_taken[i] == 0 || n_ntaken[i] == 0))
        fail($sformatf("coverage: branch #%0d taken %0d / not taken %0d times", i, n_taken[i], n_ntaken[i]));
    end
    if (n_addi_b30 == 0) fail("coverage: no ADDI with instr[30]=1");
    $display("vectors: %0d RV32I words (%0d with ADDI instr[30]=1), %0d foreign words (%0d NOTEs)",
             n_rv32i, n_addi_b30, n_foreign, n_notes);
    $display("checks: %0d table, %0d format, %0d execute, %0d rs-dependence", n_table, n_format, n_exec, n_dep);

    if (errors == 0)
      $display("PASS decoder_adv_tb: %0d GNU-as words, 42/42 RV32I instructions, %0d checks, 0 errors (seed=%0d)",
               nvec, n_table + n_format + n_exec + n_dep, start_seed);
    else
      $display("FAIL decoder_adv_tb: %0d errors in %0d GNU-as words, %0d checks (seed=%0d)",
               errors, nvec, n_table + n_format + n_exec + n_dep, start_seed);
    $finish;
  end

endmodule
