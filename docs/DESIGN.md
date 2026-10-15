# Design notes

Interfaces, encodings and conventions shared by the RTL, the testbenches and the tools. The
README has the [datapath overview](../README.md#how-it-works) and the
[limitations](../README.md#limitations), and [VERIFICATION.md](VERIFICATION.md) has the checks.

Testbench comments refer to the numbered items under [Module interfaces](#module-interfaces)
(for example "docs/DESIGN.md item 5"). Section and page numbers in comments refer to the PDF of
the RISC-V Unprivileged ISA, version 20260120.

## Conventions

- Every file starts with `` `timescale 1ns/1ps ``.
- Ports are plain `logic [N:0]` vectors (no structs or interfaces on ports).
- A control output that an instruction does not use is 0, never X.
- Every testbench prints exactly one line starting with `PASS` or `FAIL` (its summary), then
  calls `$finish`. Lines about single errors (`ERROR`, `MODEL ERROR`, `ORACLE MISMATCH`,
  `ASSERTION FAILED`, indented details) never start with `PASS` or `FAIL`. The run scripts
  decide pass or fail from that one line.

## Simulator notes (Icarus Verilog 12.0)

These explain why some of the code looks the way it does.

- Packages are imported inside each module body (`import rv_pkg::*;`), not in the module
  header.
- Only immediate assertions (`assert (...) else ...;`) are used. Icarus 12 does not support
  concurrent assertions (`assert property`).
- `$urandom(seed)` is always given an `int` variable, which Icarus needs. Icarus has no
  `randomize()`, constraints or covergroups, so the testbenches make their own random stimulus
  and count their own coverage.
- Instruction fields are sliced with continuous `assign`s, outside `always_*` blocks. Inside
  them Icarus prints "sorry: constant selects in always_* processes are not currently
  supported".
- The `dmem` write port is a plain `always @(posedge clk)`, because its initial block also
  writes the memory array (IEEE 1800 does not allow another writer for an `always_ff`
  variable).

## Encodings

All shared constants are in [`rtl/rv_pkg.sv`](../rtl/rv_pkg.sv). The opcodes come from the ISA
manual. The rest are this design's own choice.

- Opcodes: `OP_LUI`, `OP_AUIPC`, `OP_JAL`, `OP_JALR`, `OP_BRANCH`, `OP_LOAD`, `OP_STORE`,
  `OP_IMM`, `OP_OP`, `OP_FENCE`, `OP_SYSTEM`.
- Immediate format (`imm_src`): `IMM_I` 000, `IMM_S` 001, `IMM_B` 010, `IMM_U` 011, `IMM_J` 100.
- ALU control (`alu_ctrl`): `ALU_ADD` 0, `ALU_SUB` 1, `ALU_AND` 2, `ALU_OR` 3, `ALU_XOR` 4,
  `ALU_SLT` 5, `ALU_SLTU` 6, `ALU_SLL` 7, `ALU_SRL` 8, `ALU_SRA` 9.
- ALU operation class (`alu_op`): `ALUOP_ADD` 00, `ALUOP_FUNCT` 10.
- Operand A select (`alu_src_a`): `SRCA_RS1` 00, `SRCA_PC` 01, `SRCA_ZERO` 10.
- Result select (`result_src`): `RES_ALU` 00, `RES_MEM` 01, `RES_PC4` 10.
- Memory: `MEM_WORDS` 16384 (64 KiB), `TOHOST_ADDR` 0x0000FFF0.

## Module interfaces

All ports are `logic`. Combinational means no clock: the outputs follow the inputs.

### 1. `immgen` (combinational)

```systemverilog
input  [31:7] instr     // instruction bits 31..7 (the opcode holds no immediate bits)
input  [2:0]  imm_src   // IMM_I, IMM_S, IMM_B, IMM_U or IMM_J
output [31:0] imm_ext   // the immediate, sign-extended to 32 bits
```

An unused `imm_src` value gives 0.

### 2. `regfile`

```systemverilog
input         clk
input         rst       // synchronous, active high: clears every register to 0
input  [4:0]  ra1, ra2  // read addresses (rs1, rs2)
output [31:0] rd1, rd2  // read data, combinational
input         we        // write enable
input  [4:0]  wa        // write address (rd)
input  [31:0] wd        // write data
```

32 registers of 32 bits. The write happens at the rising edge of `clk` when `we && wa != 0`.
x0 always reads 0 and its storage stays 0. There is no write-to-read bypass (see
[below](#no-write-to-read-bypass-in-the-register-file)).

### 3. `alu` (combinational)

```systemverilog
input  [31:0] a, b      // operand A (rs1, pc or 0) and operand B (rs2 or the immediate)
input  [3:0]  alu_ctrl  // ALU_*
output [31:0] y
```

Shifts use `b[4:0]`. An unused `alu_ctrl` value gives 0.

### 4. `branch_unit` (combinational)

```systemverilog
input  [31:0] a, b      // rs1 and rs2 values
input  [2:0]  funct3    // instr[14:12]
output        taken
```

BEQ 000, BNE 001, BLT 100, BGE 101, BLTU 110, BGEU 111. funct3 010 and 011 give 0.

### 5. `maindec` (combinational)

```systemverilog
input  [6:0] opcode
output       reg_write    // write the result to rd
output [1:0] result_src   // RES_ALU, RES_MEM or RES_PC4
output       mem_write    // store
output       branch       // conditional branch
output       jump         // JAL only
output       jalr         // JALR only
output [1:0] alu_src_a    // SRCA_RS1, SRCA_PC or SRCA_ZERO
output       alu_src_b    // 0: rs2, 1: immediate
output [2:0] imm_src      // IMM_*
output [1:0] alu_op       // ALUOP_ADD or ALUOP_FUNCT
output       uses_rs1     // the instruction reads rs1
output       uses_rs2     // the instruction reads rs2
output       illegal      // the opcode is not an RV32I opcode
```

LUI uses `alu_src_a` = `SRCA_ZERO`, the U immediate and ADD. AUIPC uses `alu_src_a` =
`SRCA_PC`. FENCE and SYSTEM are legal and set every write and branch control to 0, so they run
as NOPs. An unknown opcode sets `illegal` = 1 and every control to 0. The single-cycle datapath
does not need `uses_rs1` and `uses_rs2`. They are kept as decoder outputs and checked by
`maindec_tb` and `decoder_adv_tb`.

Only the opcode is decoded, so an encoding from another extension that shares an RV32I opcode
runs as that opcode: MUL runs as ADD, CSRRW runs as a NOP and does not write rd, and LD and SD
(funct3 011) act as a load that returns 0 and a store that writes nothing. `decoder_adv_tb`
prints a NOTE line for each such encoding.

### 6. `aludec` (combinational)

```systemverilog
input  [1:0] alu_op
input  [2:0] funct3
input        funct7b5   // instr[30]
input        opb5       // instr[5]: 1 for OP (register-register), 0 for OP-IMM
output [3:0] alu_ctrl
```

SUB only when the instruction is register-register and `funct7b5` = 1. SRA (and SRAI) when
funct3 = 101 and `funct7b5` = 1, in both forms.

### 7. `store_unit` (combinational)

```systemverilog
input  [2:0]  funct3      // 000 SB, 001 SH, 010 SW
input  [1:0]  addr_lo     // addr[1:0], the byte offset inside the word
input  [31:0] rs2         // the value to store
output [3:0]  be          // byte enables: be[k] = 1 writes byte lane k
output [31:0] wdata       // rs2 moved into its lane(s), zero in every other lane
output        misaligned  // the address is not a multiple of the access size
```

A misaligned SH or SW gives `misaligned` = 1 and `be` = 0000, so nothing is written. A funct3
that is not a store gives `be` = 0000.

### 8. `load_unit` (combinational)

```systemverilog
input  [2:0]  funct3      // 000 LB, 001 LH, 010 LW, 100 LBU, 101 LHU
input  [1:0]  addr_lo     // addr[1:0]
input  [31:0] rdata_word  // the whole aligned word read from memory
output [31:0] data        // the value written to rd
output        misaligned  // the address is not a multiple of the access size
```

LB and LH sign-extend, LBU and LHU zero-extend, LW returns the whole word. A misaligned LH, LHU
or LW gives `misaligned` = 1 and `data` = 0 (rd is still written). A funct3 that is not a load
gives `data` = 0.

### 9. `imem` (combinational read)

```systemverilog
input  [31:0] addr
output [31:0] rdata     // the word at addr[15:2]
```

Loads `+hex=<file>` with `$readmemh` in an initial block. It ignores `addr[1:0]`.

### 10. `dmem`

```systemverilog
input         clk
input  [31:0] addr
output [31:0] rdata     // the word at addr[15:2], combinational
input         we
input  [3:0]  be
input  [31:0] wdata
```

Writes the enabled byte lanes at the rising edge. It loads the same `+hex=<file>` image as
`imem` (two Harvard memories holding one image).

### 11. `sc_core` and `rv32i_sc_top`

```systemverilog
// sc_core
input         clk
input         rst           // synchronous, active high
output [31:0] imem_addr
input  [31:0] imem_rdata
output [31:0] dmem_addr
output        dmem_we
output [3:0]  dmem_be
output [31:0] dmem_wdata
input  [31:0] dmem_rdata
// ... and the ret_* outputs listed under "Retire interface"
```

`rv32i_sc_top` has `clk`, `rst` and the `ret_*` outputs. It is `sc_core` plus `imem` and
`dmem`.

## The single-cycle core

One instruction per clock cycle. The PC register and the register-file and data-memory writes
are the only state that changes at the rising edge. Everything else is combinational in between.

```
pc_src    = (branch && taken) || jump || jalr
pc_target = (jalr ? rs1 : pc) + imm        bit 0 cleared for JALR
pc_next   = pc_src ? pc_target : pc + 4
result    = RES_MEM: load data,  RES_PC4: pc + 4,  otherwise: the ALU result
```

Reset is synchronous and active high, and sets the PC to 0. Register-file and memory writes are
gated off during reset.

### Retire interface

The testbench builds its trace only from these outputs.

| Output | Meaning |
|---|---|
| `ret_valid` | `!rst` |
| `ret_pc`, `ret_instr` | PC and instruction word of the instruction executed this cycle |
| `ret_rd_we` | `!rst && reg_write && rd != 0` |
| `ret_rd`, `ret_rd_wdata` | Register written and the value |
| `ret_mem_we` | `mem_write && !rst` |
| `ret_mem_addr` | Store address, word-aligned |
| `ret_mem_be`, `ret_mem_wdata` | Byte enables and lane-placed data (zero outside the enables) |

The assertions in `tb/sc_core_tb.sv` are listed in
[VERIFICATION.md](VERIFICATION.md#assertions-in-tbsc_core_tbsv).

## Trace format

Written by `tb/sc_core_tb.sv` and `tools/iss.py`, compared line by line by `tools/compare.py`.
One line per executed instruction, lower-case hex, single spaces:

```
<pc> <instr>                            always
 x<rd>=<value>                          then this, if it writes a register other than x0
 m[<word addr>]&<be>=<lane data>        then this, if it is a store
```

`<pc>`, `<instr>`, `<value>`, `<word addr>` and `<lane data>` are 8 hex digits, `<rd>` is 2
decimal digits and `<be>` is 1 hex digit. Three examples, from a 9-instruction program in
`tools/iss_adv_test.py` that checks these lines:

```
00000004 00500093 x01=00000005
0000000c 00112223 m[00008004]&f=00000005
00000010 00208463
```

## Test end and memory map

64 KiB, 0x0000 to 0xFFFF, and addresses use bits [15:2]. Code starts at 0x0000 and data at
0x8000 (`tools/link.ld`). A store to `TOHOST_ADDR` (0xFFF0) ends the run after that store
executes (it is printed in the trace). The value 1 means PASS. Any other value means FAIL, with
the test number in `value >> 1` (the riscv-tests convention). The testbench gives up after
`+maxcycles=` cycles (default 200000).

## Hex image format

`$readmemh` text: one 32-bit word per line, 8 hex digits, word 0 at address 0. Program images
made by `tools/asm2hex.sh` (linked ELF, `objcopy -O binary`, `tools/bin2hex.py --words 16384`)
are padded to all 16384 words. `tb/mem_test.hex` (the `mem_tb` image, made by
`tools/mem_test_gen.sh`) has 16 words. `imem` and `dmem` are cleared to zero before
`$readmemh`, so a short image works, and Icarus then prints a "Not enough words" warning.

## Design decisions

### No write-to-read bypass in the register file

Pipelined cores often let a read see the value being written in the same cycle. In a
single-cycle core that value is computed from the values being read, so with rd equal to rs1 a
bypass would close a combinational loop (rd1 to ALU to write data to rd1). The write lands at
the rising edge and the next instruction reads it, which is all this core needs.
`tools/regfile_mut.sh` plants a bypass to show that `regfile_tb` catches it.

### Two memories, one image

`imem` and `dmem` are separate (Harvard), so a fetch and a load or store can happen in the same
cycle. Both load the same `+hex=` image, so loads see the initialised data. A store changes
`dmem` only, so a program cannot modify its own code. The ISS models the same split.

### Store data is zero outside the byte enables

`store_unit` shifts the byte or halfword into its lane and zeroes the other lanes. `dmem` writes
only the enabled lanes, so the zeros change nothing in memory, but they give the store data on
the retire port one defined value that the trace can compare exactly. Assertion A4 checks it on
every store.

### ADDI is never decoded as SUB

In the register-immediate form, `instr[30]` is bit 10 of the immediate, so
`addi x1, x0, -1024` has `instr[30]` = 1. `aludec` picks SUB only when `instr[5]` is also 1 (the
register-register form). Right shifts differ: SRAI and SRA both use `instr[30]`. The random part
of `aludec_tb` hit 428 cases that had `instr[30]` = 1 and still expected ADD
([`aludec_tb.log`](../results/aludec_tb.log)).

### Unused controls are 0, never X

`maindec` starts every output at 0 and each opcode turns on only what it needs, so an unknown
opcode changes no state. Assertion A2 checks that nothing on the retire port is ever X or Z.
