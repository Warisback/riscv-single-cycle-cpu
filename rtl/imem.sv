`timescale 1ns/1ps
// imem: instruction memory, 64 KiB = MEM_WORDS (16384) words of 32 bits.
//
// Read only, combinational: rdata is the word at addr[15:2].
//   addr[1:0]   are ignored (instructions are word aligned in RV32I).
//   addr[31:16] are ignored, so the 64 KiB image repeats ("aliases") every
//               64 KiB of address space. Programs stay below 0x10000.
//
// Contents come from a hex image named on the simulator command line:
//   vvp sim.vvp +hex=prog.hex
// The file holds one 32-bit word per line; line 0 is the word at address 0.
module imem (
  input  logic [31:0] addr,
  output logic [31:0] rdata
);
  import rv_pkg::*;

  logic [31:0] mem [0:MEM_WORDS-1];   // word i holds bytes 4i .. 4i+3
  string       hexfile;

  initial begin
    // Start from all zeros so words past the end of the image read 0, not X.
    for (int i = 0; i < MEM_WORDS; i++) mem[i] = 32'h0000_0000;

    if ($value$plusargs("hex=%s", hexfile)) begin
      $readmemh(hexfile, mem);
    end else begin
      $display("imem: no +hex=<file> plusarg, memory starts all zero");
    end
  end

  // Word address = byte address / 4, using only the 14 bits a 64 KiB memory needs.
  assign rdata = mem[addr[15:2]];

endmodule
