`timescale 1ns/1ps
// regfile: the 32 integer registers x0..x31 of RV32I, each 32 bits wide.
//   Spec section 2.1, p.23: register x0 is hardwired with all bits equal to 0.
//   Two read ports (rs1, rs2) and one write port (rd), as an R-type
//   instruction needs (spec section 2.2, p.25).
// Reads are combinational. The write happens on the rising clock edge.
// No write-to-read bypass: in a single-cycle core the value being written is
// computed from the values being read, so a bypass would close a
// combinational loop (rd1 -> ALU -> wd -> rd1) whenever rd == rs1.
module regfile (
  input  logic        clk,
  input  logic        rst,   // synchronous, active high: clears every register
  input  logic [4:0]  ra1,   // read address 1 (rs1)
  input  logic [4:0]  ra2,   // read address 2 (rs2)
  output logic [31:0] rd1,   // read data 1
  output logic [31:0] rd2,   // read data 2
  input  logic        we,    // write enable
  input  logic [4:0]  wa,    // write address (rd)
  input  logic [31:0] wd     // write data
);

  logic [31:0] regs [0:31];

  // Write port: one register per rising edge. Writes to x0 are dropped.
  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < 32; i++) regs[i] <= 32'd0;
    end else if (we && wa != 5'd0) begin
      regs[wa] <= wd;
    end
  end

  // Read ports: x0 always reads 0, every other register reads its stored value.
  assign rd1 = (ra1 == 5'd0) ? 32'd0 : regs[ra1];
  assign rd2 = (ra2 == 5'd0) ? 32'd0 : regs[ra2];

endmodule
