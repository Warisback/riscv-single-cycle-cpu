#!/usr/bin/env python3
"""iss.py: a small RV32I instruction-set simulator (the "golden model").

    usage: python3 tools/iss.py --hex prog.hex [--trace prog.trace] [--max-steps N]

It runs one instruction at a time, with no pipeline, exactly as the ISA manual
describes each instruction. For every instruction it writes one trace line in
the format of docs/DESIGN.md, the same format the RTL testbench prints, so the two
traces can be compared with `diff`:

    <pc> <instr>[ x<rd>=<value>][ m[<word addr>]&<be>=<lane data>]

Written from the RISC-V Unprivileged ISA manual (v20260120):
  chapter 2 (RV32I), sections 2.2-2.6, for what each instruction does, and
  chapter 36 ("RV32I Base Instruction Set" table) for the opcode/funct3/funct7 bits.

Machine (docs/DESIGN.md): 64 KiB little-endian memory loaded from the hex file
(word 0 = address 0, missing words are 0), pc starts at 0, x0 is always 0.
Like the RTL it has two memories holding the same image (Harvard): loads and
stores use the data memory, instructions are fetched from a read-only copy, so
a store never changes the instructions that run (as in rtl/imem.sv, rtl/dmem.sv).
FENCE, ECALL and EBREAK do nothing: the spec allows FENCE as a NOP (ch. 2 intro);
ECALL/EBREAK would normally trap, but this core has no traps. The run ends when
a store to TOHOST (0xFFF0) retires: 1 means PASS, anything else FAIL with test
number = value >> 1. Exit code is 0 only for PASS.

Things the core does not support stop the run with FAIL: a misaligned load or
store (out of scope here: section 2.6, p.34), and a jump or
taken branch to an address that is not a multiple of 4 (an
instruction-address-misaligned exception, sections 2.2 and 2.5).
Encodings that are not RV32I are executed as NOPs with a warning on stderr
(section 2.2: behavior on a reserved instruction is UNSPECIFIED).
"""
import argparse
import sys

MASK32 = 0xFFFF_FFFF
MEM_BYTES = 64 * 1024          # 0x0000-0xFFFF
TOHOST_ADDR = 0x0000_FFF0

# Major opcodes, instr[6:0] (spec ch. 36, RV32I table)
OP_LUI    = 0b0110111
OP_AUIPC  = 0b0010111
OP_JAL    = 0b1101111
OP_JALR   = 0b1100111
OP_BRANCH = 0b1100011
OP_LOAD   = 0b0000011
OP_STORE  = 0b0100011
OP_IMM    = 0b0010011
OP_OP     = 0b0110011
OP_FENCE  = 0b0001111
OP_SYSTEM = 0b1110011

ECALL  = 0x00000073   # spec ch. 36: imm=0, rs1=0, funct3=0, rd=0, SYSTEM
EBREAK = 0x00100073   # same with imm=1


class SimStop(Exception):
    """Raised when the program does something the core cannot do."""


# ---------------------------------------------------------------- helpers

def sext(value, bits):
    """Sign-extend the low `bits` bits of value (result is a Python int)."""
    value &= (1 << bits) - 1
    sign = 1 << (bits - 1)
    return (value ^ sign) - sign


def signed(value):
    """Read a 32-bit register value as a two's complement number."""
    return sext(value, 32)


def bits(instr, hi, lo):
    """instr[hi:lo] as an unsigned number."""
    return (instr >> lo) & ((1 << (hi - lo + 1)) - 1)


# Immediates, spec section 2.3 Figure 1. The sign bit is always instr[31].
def imm_i(instr):
    return sext(bits(instr, 31, 20), 12)


def imm_s(instr):
    return sext((bits(instr, 31, 25) << 5) | bits(instr, 11, 7), 12)


def imm_b(instr):
    value = (bits(instr, 31, 31) << 12) | (bits(instr, 7, 7) << 11) \
          | (bits(instr, 30, 25) << 5) | (bits(instr, 11, 8) << 1)
    return sext(value, 13)


def imm_u(instr):
    return bits(instr, 31, 12) << 12          # low 12 bits are zero


def imm_j(instr):
    value = (bits(instr, 31, 31) << 20) | (bits(instr, 19, 12) << 12) \
          | (bits(instr, 20, 20) << 11) | (bits(instr, 30, 21) << 1)
    return sext(value, 21)


# ---------------------------------------------------------------- the machine

class RV32I:
    def __init__(self, words):
        self.mem = bytearray(MEM_BYTES)          # data memory: loads and stores
        for i, word in enumerate(words):
            self.mem[4 * i:4 * i + 4] = word.to_bytes(4, "little")
        self.imem = bytes(self.mem)              # instruction memory: same image, never written
        self.x = [0] * 32          # registers, kept as unsigned 32-bit numbers
        self.pc = 0
        self.warnings = 0

    def warn(self, pc, instr, msg):
        self.warnings += 1
        if self.warnings <= 20:
            print(f"iss: warning: pc={pc:08x} instr={instr:08x}: {msg}", file=sys.stderr)
        if self.warnings == 20:
            print("iss: (further warnings suppressed)", file=sys.stderr)

    # Memory: byte-addressed, little-endian (spec section 2.6). Only address
    # bits [15:0] select a byte, like the RTL memories (they use addr[15:2]).
    def fetch(self, pc):
        base = pc & 0xFFFC
        return int.from_bytes(self.imem[base:base + 4], "little")

    def read_word(self, addr):
        base = addr & 0xFFFC
        return int.from_bytes(self.mem[base:base + 4], "little")

    def write_word_lanes(self, addr, be, lane_data):
        """Write the bytes of lane_data whose byte-enable bit is set."""
        base = addr & 0xFFFC
        for lane in range(4):
            if be & (1 << lane):
                self.mem[base + lane] = (lane_data >> (8 * lane)) & 0xFF

    # ------------------------------------------------------------ one instruction
    def step(self):
        """Execute the instruction at pc. Returns (trace_line, store) where
        store is (word_addr, be, lane_data) for a store, else None."""
        pc = self.pc
        instr = self.fetch(pc)              # from imem: stores never change it

        opcode = bits(instr, 6, 0)          # field positions: spec section 2.2
        rd     = bits(instr, 11, 7)
        funct3 = bits(instr, 14, 12)
        rs1    = bits(instr, 19, 15)
        rs2    = bits(instr, 24, 20)
        funct7 = bits(instr, 31, 25)
        a = self.x[rs1]
        b = self.x[rs2]

        next_pc = pc + 4
        result = None      # value written to rd (None: no register write)
        store = None       # (word address, byte enable, lane data)
        jumped = False     # jump or taken branch: target must be 4-byte aligned

        if opcode == OP_LUI:                       # 2.4.1
            result = imm_u(instr)

        elif opcode == OP_AUIPC:                   # 2.4.1: pc of the AUIPC itself
            result = pc + imm_u(instr)

        elif opcode == OP_JAL:                     # 2.5.1
            result = pc + 4
            next_pc = pc + imm_j(instr)
            jumped = True

        elif opcode == OP_JALR:                    # 2.5.1: clear bit 0 of the sum
            if funct3 != 0:
                self.warn(pc, instr, "JALR with funct3 != 0 (reserved), executed as NOP")
            else:
                result = pc + 4
                next_pc = (a + imm_i(instr)) & ~1
                jumped = True

        elif opcode == OP_BRANCH:                  # 2.5.2
            taken = self.branch_taken(pc, instr, funct3, a, b)
            if taken:
                next_pc = pc + imm_b(instr)
                jumped = True

        elif opcode == OP_LOAD:                    # 2.6
            addr = (a + imm_i(instr)) & MASK32
            result = self.load(pc, instr, funct3, addr)

        elif opcode == OP_STORE:                   # 2.6
            addr = (a + imm_s(instr)) & MASK32
            store = self.store(pc, instr, funct3, addr, b)

        elif opcode == OP_IMM:                     # 2.4.1
            result = self.alu_imm(pc, instr, funct3, funct7, a)

        elif opcode == OP_OP:                      # 2.4.2
            result = self.alu_reg(pc, instr, funct3, funct7, a, b)

        elif opcode == OP_FENCE:                   # no caches or reordering: NOP
            if funct3 != 0:
                self.warn(pc, instr, "FENCE-opcode instruction other than FENCE, executed as NOP")

        elif opcode == OP_SYSTEM:                  # no traps or CSRs: NOP
            if instr not in (ECALL, EBREAK):
                self.warn(pc, instr, "SYSTEM instruction other than ECALL/EBREAK, executed as NOP")

        else:
            self.warn(pc, instr, f"unknown opcode {opcode:07b}, executed as NOP")

        next_pc &= MASK32
        if jumped and next_pc % 4 != 0:
            raise SimStop(f"pc={pc:08x} instr={instr:08x}: jump/branch target "
                          f"{next_pc:08x} is not 4-byte aligned")

        # Retire: write rd (never x0), build the trace line, move the pc.
        line = f"{pc:08x} {instr:08x}"
        if result is not None and rd != 0:
            self.x[rd] = result & MASK32
            line += f" x{rd:02d}={self.x[rd]:08x}"
        if store is not None:
            word_addr, be, lane_data = store
            line += f" m[{word_addr:08x}]&{be:x}={lane_data:08x}"
        self.pc = next_pc
        return line, store

    # ------------------------------------------------------------ instruction groups
    def branch_taken(self, pc, instr, funct3, a, b):
        if funct3 == 0b000:                        # BEQ
            return a == b
        if funct3 == 0b001:                        # BNE
            return a != b
        if funct3 == 0b100:                        # BLT  (signed)
            return signed(a) < signed(b)
        if funct3 == 0b101:                        # BGE  (signed)
            return signed(a) >= signed(b)
        if funct3 == 0b110:                        # BLTU (unsigned)
            return a < b
        if funct3 == 0b111:                        # BGEU (unsigned)
            return a >= b
        self.warn(pc, instr, f"branch funct3={funct3:03b} is reserved, not taken")
        return False

    def load(self, pc, instr, funct3, addr):
        # size in bytes and whether to sign-extend, per funct3 (ch. 36 table)
        kinds = {0b000: (1, True),    # LB
                 0b001: (2, True),    # LH
                 0b010: (4, False),   # LW
                 0b100: (1, False),   # LBU
                 0b101: (2, False)}   # LHU
        if funct3 not in kinds:
            self.warn(pc, instr, f"load funct3={funct3:03b} is reserved, executed as NOP")
            return None
        size, is_signed = kinds[funct3]
        if addr % size != 0:
            raise SimStop(f"pc={pc:08x} instr={instr:08x}: misaligned load from {addr:08x}")
        lane = addr & 3
        value = (self.read_word(addr) >> (8 * lane)) & ((1 << (8 * size)) - 1)
        if is_signed:
            value = sext(value, 8 * size)
        return value & MASK32

    def store(self, pc, instr, funct3, addr, value):
        sizes = {0b000: 1, 0b001: 2, 0b010: 4}     # SB, SH, SW
        if funct3 not in sizes:
            self.warn(pc, instr, f"store funct3={funct3:03b} is reserved, executed as NOP")
            return None
        size = sizes[funct3]
        if addr % size != 0:
            raise SimStop(f"pc={pc:08x} instr={instr:08x}: misaligned store to {addr:08x}")
        # The low `size` bytes of rs2 go to byte lanes lane .. lane+size-1 of the word.
        lane = addr & 3
        be = ((1 << size) - 1) << lane
        lane_data = (value & ((1 << (8 * size)) - 1)) << (8 * lane)
        self.write_word_lanes(addr, be, lane_data)
        return (addr & ~3) & MASK32, be, lane_data

    def alu_imm(self, pc, instr, funct3, funct7, a):
        imm = imm_i(instr)
        shamt = bits(instr, 24, 20)               # shifts: imm[4:0] (2.4.1)
        if funct3 == 0b000:                        # ADDI
            return a + imm
        if funct3 == 0b010:                        # SLTI
            return 1 if signed(a) < imm else 0
        if funct3 == 0b011:                        # SLTIU: sign-extend, then compare unsigned
            return 1 if a < (imm & MASK32) else 0
        if funct3 == 0b100:                        # XORI
            return a ^ (imm & MASK32)
        if funct3 == 0b110:                        # ORI
            return a | (imm & MASK32)
        if funct3 == 0b111:                        # ANDI
            return a & (imm & MASK32)
        if funct3 == 0b001 and funct7 == 0b0000000:    # SLLI
            return a << shamt
        if funct3 == 0b101 and funct7 == 0b0000000:    # SRLI
            return a >> shamt
        if funct3 == 0b101 and funct7 == 0b0100000:    # SRAI
            return signed(a) >> shamt
        self.warn(pc, instr, "OP-IMM shift with reserved imm[11:5], executed as NOP")
        return None

    def alu_reg(self, pc, instr, funct3, funct7, a, b):
        shamt = b & 0x1F                           # shifts use rs2[4:0] (2.4.2)
        if funct7 == 0b0000000:
            if funct3 == 0b000:                    # ADD
                return a + b
            if funct3 == 0b001:                    # SLL
                return a << shamt
            if funct3 == 0b010:                    # SLT
                return 1 if signed(a) < signed(b) else 0
            if funct3 == 0b011:                    # SLTU
                return 1 if a < b else 0
            if funct3 == 0b100:                    # XOR
                return a ^ b
            if funct3 == 0b101:                    # SRL
                return a >> shamt
            if funct3 == 0b110:                    # OR
                return a | b
            if funct3 == 0b111:                    # AND
                return a & b
        if funct7 == 0b0100000:
            if funct3 == 0b000:                    # SUB
                return a - b
            if funct3 == 0b101:                    # SRA
                return signed(a) >> shamt
        self.warn(pc, instr, f"OP with funct7={funct7:07b} funct3={funct3:03b} "
                             "is not RV32I, executed as NOP")
        return None


# ---------------------------------------------------------------- files and main

def load_hex(path):
    """Read a $readmemh file: one 32-bit word per line, word 0 = address 0."""
    words = []
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            text = line.split("//")[0].strip()
            if not text:
                continue
            if len(text) > 8 or any(c not in "0123456789abcdefABCDEF" for c in text):
                sys.exit(f"iss: {path}:{lineno}: expected one hex word, got {text!r}")
            words.append(int(text, 16))
    if len(words) > MEM_BYTES // 4:
        sys.exit(f"iss: {path} has {len(words)} words, memory holds {MEM_BYTES // 4}")
    return words


def main():
    ap = argparse.ArgumentParser(description="RV32I instruction-set simulator")
    ap.add_argument("--hex", required=True, help="memory image ($readmemh format)")
    ap.add_argument("--trace", help="write the instruction trace to this file")
    ap.add_argument("--max-steps", type=int, default=1_000_000,
                    help="give up (FAIL) after this many instructions")
    args = ap.parse_args()

    cpu = RV32I(load_hex(args.hex))
    # newline="\n": the same bytes on Windows and Linux, so `diff` with the RTL trace works
    trace = open(args.trace, "w", newline="\n") if args.trace else None
    steps = 0
    tohost = None
    error = None

    while steps < args.max_steps:
        try:
            line, store = cpu.step()
        except SimStop as stop:
            error = str(stop)
            break
        steps += 1
        if trace:
            trace.write(line + "\n")
        if store is not None and store[0] == TOHOST_ADDR:
            tohost = store[2]      # lane data of the store (SW in practice)
            break

    if trace:
        trace.close()

    if tohost is None:
        reason = error or f"no store to TOHOST in {args.max_steps} instructions"
        print(f"FAIL {reason}")
        return 1
    print(f"TOHOST={tohost:08x}")
    if tohost == 1:
        print(f"PASS ({steps} instructions)")
        return 0
    print(f"FAIL test {tohost >> 1} ({steps} instructions)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
