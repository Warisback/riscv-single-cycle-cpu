`timescale 1ns/1ps
// sc_core: a single-cycle RV32I processor.
// Every instruction is fetched, decoded, executed, given its memory access and
// written back in one clock cycle: all of that is combinational logic between
// the PC register and the register-file / data-memory writes on the next
// rising edge. CPI is exactly 1; the clock period must cover the slowest
// instruction (a load: fetch, decode, register read, address add, memory read,
// load extend, write-back mux).
//
// The ret_* outputs describe the instruction executed this cycle. sc_core_tb
// writes a trace from them, and tools/compare.py checks it line by line
// against the trace from the instruction-set simulator (tools/iss.py).
module sc_core (
  input  logic        clk,
  input  logic        rst,          // synchronous, active high
  // instruction memory
  output logic [31:0] imem_addr,
  input  logic [31:0] imem_rdata,
  // data memory
  output logic [31:0] dmem_addr,
  output logic        dmem_we,
  output logic [3:0]  dmem_be,
  output logic [31:0] dmem_wdata,
  input  logic [31:0] dmem_rdata,
  // retire interface: what the instruction executed this cycle did
  output logic        ret_valid,
  output logic [31:0] ret_pc,
  output logic [31:0] ret_instr,
  output logic        ret_rd_we,
  output logic [4:0]  ret_rd,
  output logic [31:0] ret_rd_wdata,
  output logic        ret_mem_we,
  output logic [31:0] ret_mem_addr,   // word-aligned
  output logic [3:0]  ret_mem_be,
  output logic [31:0] ret_mem_wdata
);
  import rv_pkg::*;

  // ------------------------------------------------------------------ fetch
  logic [31:0] pc, pc_plus4, pc_next, instr;

  always_ff @(posedge clk) begin
    if (rst) pc <= 32'd0;
    else     pc <= pc_next;
  end

  assign imem_addr = pc;
  assign instr     = imem_rdata;
  assign pc_plus4  = pc + 32'd4;

  // ------------------------------------------------------------------ decode
  // Field extraction uses continuous assigns: Icarus Verilog 12 does not support
  // constant part-selects inside always_* blocks.
  logic [6:0] opcode;
  logic [4:0] rs1, rs2, rd;
  logic [2:0] funct3;
  logic       funct7b5, opb5;

  assign opcode   = instr[6:0];
  assign rd       = instr[11:7];
  assign funct3   = instr[14:12];
  assign rs1      = instr[19:15];
  assign rs2      = instr[24:20];
  assign funct7b5 = instr[30];
  assign opb5     = instr[5];

  // control
  logic       reg_write, mem_write, branch, jump, jalr, alu_src_b;
  logic [1:0] result_src, alu_src_a, alu_op;
  logic [2:0] imm_src;
  logic [3:0] alu_ctrl;
  logic       uses_rs1, uses_rs2, illegal;   // uses_rs1/uses_rs2: not needed by this datapath;
                                             // illegal: probed by sc_core_tb (assertion A3)

  maindec u_maindec (
    .opcode(opcode), .reg_write(reg_write), .result_src(result_src), .mem_write(mem_write),
    .branch(branch), .jump(jump), .jalr(jalr), .alu_src_a(alu_src_a), .alu_src_b(alu_src_b),
    .imm_src(imm_src), .alu_op(alu_op), .uses_rs1(uses_rs1), .uses_rs2(uses_rs2), .illegal(illegal)
  );

  aludec u_aludec (
    .alu_op(alu_op), .funct3(funct3), .funct7b5(funct7b5), .opb5(opb5), .alu_ctrl(alu_ctrl)
  );

  // register file and immediate
  logic [31:0] rs1_val, rs2_val, imm, result;

  regfile u_regfile (
    .clk(clk), .rst(rst), .ra1(rs1), .ra2(rs2), .rd1(rs1_val), .rd2(rs2_val),
    .we(reg_write && !rst), .wa(rd), .wd(result)
  );

  immgen u_immgen (.instr(instr[31:7]), .imm_src(imm_src), .imm_ext(imm));

  // ------------------------------------------------------------------ execute
  logic [31:0] src_a, src_b, alu_y;

  always_comb begin
    case (alu_src_a)
      SRCA_PC:   src_a = pc;          // AUIPC: pc + imm
      SRCA_ZERO: src_a = 32'd0;       // LUI:   0 + imm
      default:   src_a = rs1_val;     // everything else
    endcase
  end

  assign src_b = alu_src_b ? imm : rs2_val;

  alu u_alu (.a(src_a), .b(src_b), .alu_ctrl(alu_ctrl), .y(alu_y));

  // branches and jumps
  logic        taken;
  logic [31:0] target_base, target_sum, pc_target;
  logic        pc_src;

  branch_unit u_branch (.a(rs1_val), .b(rs2_val), .funct3(funct3), .taken(taken));

  assign target_base = jalr ? rs1_val : pc;              // JALR: rs1 + imm, others: pc + imm
  assign target_sum  = target_base + imm;
  assign pc_target   = {target_sum[31:1], target_sum[0] & ~jalr};   // JALR clears bit 0 (spec section 2.5.1)
  assign pc_src      = (branch && taken) || jump || jalr;
  assign pc_next     = pc_src ? pc_target : pc_plus4;

  // ------------------------------------------------------------------ memory
  logic [3:0]  st_be;
  logic [31:0] st_wdata, load_data;
  logic        st_misaligned, ld_misaligned;

  store_unit u_store (
    .funct3(funct3), .addr_lo(alu_y[1:0]), .rs2(rs2_val),
    .be(st_be), .wdata(st_wdata), .misaligned(st_misaligned)
  );

  assign dmem_addr  = alu_y;                    // loads and stores: rs1 + imm
  assign dmem_we    = mem_write && !rst;
  assign dmem_be    = st_be;
  assign dmem_wdata = st_wdata;

  load_unit u_load (
    .funct3(funct3), .addr_lo(alu_y[1:0]), .rdata_word(dmem_rdata),
    .data(load_data), .misaligned(ld_misaligned)
  );

  // ------------------------------------------------------------------ write-back
  always_comb begin
    case (result_src)
      RES_MEM: result = load_data;    // loads
      RES_PC4: result = pc_plus4;     // JAL / JALR link value
      default: result = alu_y;        // ALU instructions, LUI, AUIPC
    endcase
  end

  // ------------------------------------------------------------------ retire interface
  assign ret_valid     = !rst;
  assign ret_pc        = pc;
  assign ret_instr     = instr;
  assign ret_rd_we     = !rst && reg_write && (rd != 5'd0);
  assign ret_rd        = rd;
  assign ret_rd_wdata  = result;
  assign ret_mem_we    = dmem_we;
  assign ret_mem_addr  = {alu_y[31:2], 2'b00};
  assign ret_mem_be    = st_be;
  assign ret_mem_wdata = st_wdata;

endmodule
