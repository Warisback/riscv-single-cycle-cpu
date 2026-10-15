`timescale 1ns/1ps
// rv32i_sc_top: the single-cycle core plus its two memories. Both memories
// load the same +hex= image (Harvard: instructions and data on separate ports).
module rv32i_sc_top (
  input  logic        clk,
  input  logic        rst,
  output logic        ret_valid,
  output logic [31:0] ret_pc,
  output logic [31:0] ret_instr,
  output logic        ret_rd_we,
  output logic [4:0]  ret_rd,
  output logic [31:0] ret_rd_wdata,
  output logic        ret_mem_we,
  output logic [31:0] ret_mem_addr,
  output logic [3:0]  ret_mem_be,
  output logic [31:0] ret_mem_wdata
);
  logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
  logic        dmem_we;
  logic [3:0]  dmem_be;

  sc_core u_core (.*);

  imem u_imem (.addr(imem_addr), .rdata(imem_rdata));

  dmem u_dmem (
    .clk(clk), .addr(dmem_addr), .rdata(dmem_rdata),
    .we(dmem_we), .be(dmem_be), .wdata(dmem_wdata)
  );
endmodule
