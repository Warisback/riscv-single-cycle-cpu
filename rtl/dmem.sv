`timescale 1ns/1ps
// dmem: data memory, 64 KiB = MEM_WORDS (16384) words of 32 bits.
//
// Read:  combinational. rdata is the whole word at addr[15:2]; load_unit
//        picks the byte/halfword out of it using addr[1:0].
// Write: on the rising clock edge when we=1. Only the byte lanes whose
//        be bit is 1 change; store_unit has already put the data in the
//        right lane(s) and chosen be from addr[1:0], so dmem itself
//        ignores addr[1:0].
//
// Byte lanes are little-endian (lane 0 = lowest byte address):
//   be[0] -> bits  7:0  -> byte address 4i+0
//   be[1] -> bits 15:8  -> byte address 4i+1
//   be[2] -> bits 23:16 -> byte address 4i+2
//   be[3] -> bits 31:24 -> byte address 4i+3
//
// addr[31:16] are ignored, so the 64 KiB memory repeats every 64 KiB.
//
// Harvard memories holding one unified image: dmem loads the same
// +hex=<file> as imem, so code and initialised data are both visible to
// loads. A store changes dmem only; imem keeps the original instructions.
module dmem (
  input  logic        clk,
  input  logic [31:0] addr,
  output logic [31:0] rdata,
  input  logic        we,
  input  logic [3:0]  be,
  input  logic [31:0] wdata
);
  import rv_pkg::*;

  logic [31:0] mem [0:MEM_WORDS-1];
  string       hexfile;

  initial begin
    for (int i = 0; i < MEM_WORDS; i++) mem[i] = 32'h0000_0000;

    if ($value$plusargs("hex=%s", hexfile)) begin
      $readmemh(hexfile, mem);
    end else begin
      $display("dmem: no +hex=<file> plusarg, memory starts all zero");
    end
  end

  // Combinational read of the addressed word.
  assign rdata = mem[addr[15:2]];

  // Byte-enable write: each enabled lane is copied, the others keep their value.
  // A plain always, not always_ff: the initial block above also writes mem, and
  // IEEE 1800 does not allow a variable written by always_ff to have another writer.
  always @(posedge clk) begin
    if (we) begin
      if (be[0]) mem[addr[15:2]][7:0]   <= wdata[7:0];
      if (be[1]) mem[addr[15:2]][15:8]  <= wdata[15:8];
      if (be[2]) mem[addr[15:2]][23:16] <= wdata[23:16];
      if (be[3]) mem[addr[15:2]][31:24] <= wdata[31:24];
    end
  end

endmodule
