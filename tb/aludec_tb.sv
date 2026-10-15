`timescale 1ns/1ps
// aludec_tb: self-checking test of the ALU decoder.
//
// Reference model: decode the whole 32-bit instruction the way the spec's
// RV32I listing does (Unprivileged ISA v20260120, ch. 36, pp. 585-586):
// opcode + funct3 + all 7 funct7 bits -> mnemonic ("SRAI", "SUB", ...), then
// mnemonic -> ALU operation. aludec only sees 7 bits (alu_op, funct3,
// instr[30], instr[5]); the test shows those 7 bits are enough to agree with
// the full decode on every legal RV32I instruction.
//
// Phase 1 (directed, exhaustive): all 4*8*2*2 = 128 input combinations.
// Phase 2 (directed): real encodings from GNU as 2.45.50 (-march=rv32i), incl.
//   "addi x1,x0,-1024" whose instr[30]=1 must still ADD.
// Phase 3 (random): seeded random instruction words.
//
// Plusargs: +seed=N (default 1)   +nrand=N (default 5000)
module aludec_tb;
  import rv_pkg::*;

  // ---- DUT ----
  logic [1:0] alu_op;
  logic [2:0] funct3;
  logic       funct7b5;
  logic       opb5;
  logic [3:0] alu_ctrl;

  aludec dut (.alu_op(alu_op), .funct3(funct3), .funct7b5(funct7b5),
              .opb5(opb5), .alu_ctrl(alu_ctrl));

  // ---- Reference model ----
  // Opcodes typed from the spec listing, not from rv_pkg.
  localparam logic [6:0] R_OP     = 7'b0110011;
  localparam logic [6:0] R_OPIMM  = 7'b0010011;

  // Spec listing -> mnemonic. "RESERVED" = not an RV32I instruction.
  // "ADDR" = an instruction whose ALU use is just an add (address, LUI,
  // AUIPC) or that does not use the ALU result (branches, JAL, JALR).
  function automatic string ref_mnemonic(input logic [31:0] ins);
    logic [6:0] opc, f7;
    logic [2:0] f3;
    opc = ins[6:0];
    f3  = ins[14:12];
    f7  = ins[31:25];
    if (opc == R_OP) begin                      // R-type: funct7 + funct3
      if (f7 == 7'b0000000) begin
        case (f3)
          3'b000: return "ADD";
          3'b001: return "SLL";
          3'b010: return "SLT";
          3'b011: return "SLTU";
          3'b100: return "XOR";
          3'b101: return "SRL";
          3'b110: return "OR";
          default: return "AND";                // 3'b111
        endcase
      end
      if (f7 == 7'b0100000 && f3 == 3'b000) return "SUB";
      if (f7 == 7'b0100000 && f3 == 3'b101) return "SRA";
      return "RESERVED";
    end
    if (opc == R_OPIMM) begin                   // I-type: funct3 (+ funct7 for shifts)
      case (f3)
        3'b000: return "ADDI";                  // ins[31:20] is all immediate
        3'b010: return "SLTI";
        3'b011: return "SLTIU";
        3'b100: return "XORI";
        3'b110: return "ORI";
        3'b111: return "ANDI";
        3'b001: return (f7 == 7'b0000000) ? "SLLI" : "RESERVED";
        default: begin                          // 3'b101
          if (f7 == 7'b0000000) return "SRLI";
          if (f7 == 7'b0100000) return "SRAI";
          return "RESERVED";
        end
      endcase
    end
    if (opc == 7'b0110111 || opc == 7'b0010111 || opc == 7'b1101111 ||
        opc == 7'b1100111 || opc == 7'b1100011 || opc == 7'b0000011 ||
        opc == 7'b0100011)
      return "ADDR";                            // LUI AUIPC JAL JALR BRANCH LOAD STORE
    return "NOT_ALU";                           // FENCE, SYSTEM, illegal: no ALU op
  endfunction

  // Mnemonic -> the ALU operation it needs (spec 2.4.1, 2.4.2, pp. 28-29).
  function automatic logic [3:0] ref_alu(input string mn);
    if (mn == "ADD"  || mn == "ADDI" || mn == "ADDR") return ALU_ADD;
    if (mn == "SUB")                                   return ALU_SUB;
    if (mn == "AND"  || mn == "ANDI")                  return ALU_AND;
    if (mn == "OR"   || mn == "ORI")                   return ALU_OR;
    if (mn == "XOR"  || mn == "XORI")                  return ALU_XOR;
    if (mn == "SLT"  || mn == "SLTI")                  return ALU_SLT;
    if (mn == "SLTU" || mn == "SLTIU")                 return ALU_SLTU;
    if (mn == "SLL"  || mn == "SLLI")                  return ALU_SLL;
    if (mn == "SRL"  || mn == "SRLI")                  return ALU_SRL;
    if (mn == "SRA"  || mn == "SRAI")                  return ALU_SRA;
    return 4'bxxxx;                                    // caller must not ask
  endfunction

  // The 7 RV32I opcodes whose ALU use is a plain add (or no ALU use at all).
  function automatic logic [6:0] add_only_opcode(input logic [2:0] k);
    case (k)
      3'd0:    return 7'b0110111;  // LUI
      3'd1:    return 7'b0010111;  // AUIPC
      3'd2:    return 7'b1101111;  // JAL
      3'd3:    return 7'b1100111;  // JALR
      3'd4:    return 7'b1100011;  // BRANCH
      3'd5:    return 7'b0000011;  // LOAD
      default: return 7'b0100011;  // STORE
    endcase
  endfunction

  // What maindec sends for each opcode (docs/DESIGN.md item 5).
  function automatic logic [1:0] ref_alu_op(input logic [6:0] opc);
    return (opc == R_OP || opc == R_OPIMM) ? ALUOP_FUNCT : ALUOP_ADD;
  endfunction

  // ---- Checking ----
  int errors     = 0;
  int n_directed = 0;
  int n_random   = 0;
  int n_reserved = 0;   // random words that were reserved encodings (not checked)
  int cov [0:15];       // phase 3: how often each expected alu_ctrl value was checked
  int n_add_b30  = 0;   // phase 3: checks that must ADD although instr[30]=1

  // Drive aludec from an instruction word exactly as the core will wire it.
  task automatic check_instr(input logic [31:0] ins, input string asm_text);
    string       mn;
    logic [3:0]  exp;
    mn       = ref_mnemonic(ins);
    exp      = ref_alu(mn);
    alu_op   = ref_alu_op(ins[6:0]);
    funct3   = ins[14:12];
    funct7b5 = ins[30];
    opb5     = ins[5];
    #1;
    if (alu_ctrl !== exp) begin
      errors++;
      if (errors <= 20)
        $display("ERROR %-22s instr=%h (%s) alu_op=%b f3=%b f7b5=%b opb5=%b: exp alu_ctrl %0d got %0d",
                 asm_text, ins, mn, alu_op, funct3, funct7b5, opb5, exp, alu_ctrl);
    end
  endtask

  // Phase 1 helper: one raw input combination.
  task automatic check_inputs(input logic [1:0] aop, input logic [2:0] f3,
                              input logic f7b5, input logic ob5);
    logic [31:0] ins;
    string       mn;
    logic [3:0]  exp;
    if (aop == ALUOP_FUNCT) begin
      // Build the OP / OP-IMM instruction these bits come from.
      ins = 32'b0;
      ins[6:0]   = ob5 ? R_OP : R_OPIMM;
      ins[14:12] = f3;
      ins[30]    = f7b5;
      mn = ref_mnemonic(ins);
      if (mn == "RESERVED") begin
        // Not RV32I (e.g. funct7=0100000 with SLL). Spec 2.2: decoding a
        // reserved instruction is UNSPECIFIED. This design ignores instr[30]
        // there, so it must act like the funct7=0000000 instruction.
        ins[30] = 1'b0;
        mn = ref_mnemonic(ins);
      end
      exp = ref_alu(mn);
    end else begin
      // ALUOP_ADD: always add. Codes 01 and 11 are never produced by maindec;
      // this design also adds for them.
      mn  = "ADDR";
      exp = ALU_ADD;
    end
    alu_op = aop; funct3 = f3; funct7b5 = f7b5; opb5 = ob5;
    #1;
    if (alu_ctrl !== exp) begin
      errors++;
      if (errors <= 20)
        $display("ERROR inputs alu_op=%b f3=%b f7b5=%b opb5=%b (%s): exp alu_ctrl %0d got %0d",
                 aop, f3, f7b5, ob5, mn, exp, alu_ctrl);
    end
  endtask

  // ---- Stimulus ----
  int          seed;        // RNG state: $urandom(seed) updates it every call
  int          start_seed;  // the +seed value, kept for the summary line
  int          nrand;
  logic [31:0] ins;
  int          pick;
  int          opk;
  string       mn;

  initial begin
    if (!$value$plusargs("seed=%d", seed))   seed  = 1;
    if (!$value$plusargs("nrand=%d", nrand)) nrand = 5000;
    start_seed = seed;
    for (int c = 0; c < 16; c++) cov[c] = 0;

    // Phase 1: every (alu_op, funct3, funct7b5, opb5) combination.
    for (int a = 0; a < 4; a++)
      for (int f = 0; f < 8; f++)
        for (int b7 = 0; b7 < 2; b7++)
          for (int b5 = 0; b5 < 2; b5++) begin
            check_inputs(a[1:0], f[2:0], b7[0], b5[0]);
            n_directed++;
          end

    // Phase 2: real encodings, assembled by GNU as 2.45.50 -march=rv32i.
    check_instr(32'h002081b3, "add  x3,x1,x2");        n_directed++;
    check_instr(32'h402081b3, "sub  x3,x1,x2");        n_directed++;
    check_instr(32'h002091b3, "sll  x3,x1,x2");        n_directed++;
    check_instr(32'h0020a1b3, "slt  x3,x1,x2");        n_directed++;
    check_instr(32'h0020b1b3, "sltu x3,x1,x2");        n_directed++;
    check_instr(32'h0020c1b3, "xor  x3,x1,x2");        n_directed++;
    check_instr(32'h0020d1b3, "srl  x3,x1,x2");        n_directed++;
    check_instr(32'h4020d1b3, "sra  x3,x1,x2");        n_directed++;
    check_instr(32'h0020e1b3, "or   x3,x1,x2");        n_directed++;
    check_instr(32'h0020f1b3, "and  x3,x1,x2");        n_directed++;
    // instr[30] = imm[10] = 1 in the next four: must stay ADD, never SUB
    check_instr(32'hc0000093, "addi x1,x0,-1024");     n_directed++;
    check_instr(32'hfff10093, "addi x1,x2,-1");        n_directed++;
    check_instr(32'h40010093, "addi x1,x2,1024");      n_directed++;
    check_instr(32'h3ff10093, "addi x1,x2,1023");      n_directed++;
    check_instr(32'hc0012093, "slti x1,x2,-1024");     n_directed++;
    check_instr(32'hfff13093, "sltiu x1,x2,-1");       n_directed++;
    check_instr(32'hfff14093, "xori x1,x2,-1");        n_directed++;
    check_instr(32'h40016093, "ori  x1,x2,1024");      n_directed++;
    check_instr(32'hc0017093, "andi x1,x2,-1024");     n_directed++;
    // shifts by a constant: instr[30] picks SRAI vs SRLI
    check_instr(32'h01f11093, "slli x1,x2,31");        n_directed++;
    check_instr(32'h01f15093, "srli x1,x2,31");        n_directed++;
    check_instr(32'h41f15093, "srai x1,x2,31");        n_directed++;
    check_instr(32'h40015093, "srai x1,x2,0");         n_directed++;
    // ALUOP_ADD users: funct3 / instr[30] / instr[5] are not ALU selects here
    check_instr(32'hc0012083, "lw   x1,-1024(x2)");    n_directed++;  // f3=010 like SLT
    check_instr(32'h40014083, "lbu  x1,1024(x2)");     n_directed++;  // f3=100 like XOR
    check_instr(32'hfff11083, "lh   x1,-1(x2)");       n_directed++;
    check_instr(32'hc020a023, "sw   x2,-1024(x1)");    n_directed++;  // opb5=1 like OP
    check_instr(32'hfe208fa3, "sb   x2,-1(x1)");       n_directed++;
    check_instr(32'hfffff0b7, "lui  x1,0xfffff");      n_directed++;  // opb5=1, f7b5=1, f3=111
    check_instr(32'h7ffff097, "auipc x1,0x7ffff");     n_directed++;
    check_instr(32'hc00100e7, "jalr x1,-1024(x2)");    n_directed++;
    check_instr(32'h001000ef, "jal  x1,.+2048");       n_directed++;
    check_instr(32'h8020f0e3, "bgeu x1,x2,.-2048");    n_directed++;
    check_instr(32'h4020c063, "blt  x1,x2,.+1024");    n_directed++;

    // Phase 3: random instruction words.
    //   pick 0-1: OP,     funct7 forced legal     pick 2: OP, funct7 fully random
    //   pick 3-4: OP-IMM, shift funct7 forced legal  pick 5: OP-IMM fully random
    //   pick 6:   an opcode that always adds (LUI, AUIPC, JAL, JALR, BRANCH,
    //             LOAD, STORE)                    pick 7: fully random word
    // Legal funct7 depends on funct3 (listing pp. 585-586): 0100000 exists
    // only for SUB/SRA (OP, funct3 000/101) and SRAI (OP-IMM, funct3 101).
    // Reserved encodings and non-ALU opcodes are counted but not checked.
    ins = $urandom(seed);  // first draw from a small seed is weak: discard
    for (int n = 0; n < nrand; n++) begin
      ins  = $urandom(seed);
      pick = $urandom(seed) % 8;
      case (pick)
        0, 1, 2: ins[6:0] = R_OP;
        3, 4, 5: ins[6:0] = R_OPIMM;
        6: begin                         // fresh draw, so instr[30] stays independent
             opk      = $urandom(seed) % 7;
             ins[6:0] = add_only_opcode(opk[2:0]);
           end
        default: ;                       // keep the random opcode
      endcase
      if (pick == 0 || pick == 1)        // OP: 0100000 only with funct3 000 or 101
        ins[31:25] = (ins[25] && (ins[14:12] == 3'b000 || ins[14:12] == 3'b101))
                     ? 7'b0100000 : 7'b0000000;
      if ((pick == 3 || pick == 4) && (ins[14:12] == 3'b001 || ins[14:12] == 3'b101))
        ins[31:25] = (ins[25] && ins[14:12] == 3'b101)  // shifts: 0100000 only for SRAI
                     ? 7'b0100000 : 7'b0000000;
      mn = ref_mnemonic(ins);
      if (mn == "RESERVED" || mn == "NOT_ALU") begin
        n_reserved++;                    // spec: behaviour UNSPECIFIED / no ALU op
      end else begin
        check_instr(ins, "random");
        cov[ref_alu(mn)]++;
        if (ref_alu(mn) == ALU_ADD && ins[30]) n_add_b30++;  // the ADDI/SUB trap
        n_random++;
      end
    end
    $display("random: %0d checked, %0d skipped (reserved encoding or no ALU op)",
             n_random, n_reserved);
    $display("random coverage (checks per alu_ctrl 0..9): %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
             cov[0], cov[1], cov[2], cov[3], cov[4], cov[5], cov[6], cov[7], cov[8], cov[9]);
    $display("random: %0d checks expected ADD while instr[30]=1", n_add_b30);
    for (int c = 0; c < 10; c++)
      if (cov[c] == 0) begin
        errors++;
        $display("ERROR random phase never checked alu_ctrl %0d", c);
      end
    if (n_add_b30 == 0) begin
      errors++;
      $display("ERROR random phase never checked ADD with instr[30]=1");
    end

    if (errors == 0)
      $display("PASS aludec_tb: %0d directed + %0d random checks, 0 errors (seed=%0d)",
               n_directed, n_random, start_seed);
    else
      $display("FAIL aludec_tb: %0d errors in %0d directed + %0d random checks (seed=%0d)",
               errors, n_directed, n_random, start_seed);
    $finish;
  end

endmodule
