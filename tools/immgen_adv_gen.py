#!/usr/bin/env python3
"""immgen_adv_gen.py: write an assembly file of real RV32I instructions whose
immediates we choose, plus the immediate immgen must produce for each one.

The oracle is GNU as: we pick a number, ask the assembler to encode it, and the
expected immgen output is that same number (as a 32-bit two's-complement value).
Nothing here slices instruction bits; the assembler does all the encoding.

  usage: immgen_adv_gen.py <out_dir> <seed> [n_random_per_format]
  writes <out_dir>/immgen_adv.s       (assembly, one instruction per line)
         <out_dir>/immgen_adv.expect  (one line per instruction, same order:
                                       kind imm_src expected opcode text)

Meaning of each immediate (RISC-V Unprivileged ISA v20260120):
  I  addi/slti/sltiu/xori/ori/andi, loads, jalr: sign-extended 12-bit imm
     (spec 2.4.1 p.28, 2.5.1 p.30, 2.6 p.33)
  I  slli/srli/srai: shamt in imm[4:0]; srai also has imm[10] = 1 (bit 30 of
     the instruction, spec 2.4.1 p.28: "0100000" in imm[11:5])
  S  sb/sh/sw: sign-extended 12-bit offset (spec 2.6 p.33)
  B  branches: signed offset, multiple of 2, -4096..4094 (spec 2.5.2 p.31)
  U  lui/auipc: 20-bit value placed in imm[31:12], low 12 bits 0 (spec 2.4.1 p.28)
  J  jal: signed offset, multiple of 2, -1048576..1048574 (spec 2.5.1 p.30)
"""
import random
import sys

# ImmSrc values from rv_pkg.sv (this design's own choice, docs/DESIGN.md "Encodings")
IMM_I, IMM_S, IMM_B, IMM_U, IMM_J = 0, 1, 2, 3, 4

# Major opcodes (spec opcode map; same values as rv_pkg.sv OP_*). Used only to
# check that the assembler emitted the instruction we asked for.
OP_IMM, OP_LOAD, OP_JALR = 0b0010011, 0b0000011, 0b1100111
OP_STORE, OP_BRANCH = 0b0100011, 0b1100011
OP_LUI, OP_AUIPC, OP_JAL = 0b0110111, 0b0010111, 0b1101111

I_ALU = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
I_LOAD = ["lb", "lh", "lw", "lbu", "lhu"]
STORES = ["sb", "sh", "sw"]
BRANCHES = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
SHIFTS = ["slli", "srli", "srai"]

MASK32 = 0xFFFFFFFF


def reg(rng):
    return "x%d" % rng.randrange(32)


class Gen:
    def __init__(self, rng):
        self.rng = rng
        self.lines = []   # assembly text
        self.expect = []  # (kind, imm_src, expected, opcode, text)

    def add(self, kind, src, value, opcode, text):
        self.lines.append(text)
        self.expect.append((kind, src, value & MASK32, opcode, text))

    # ---- one instruction per format, value chosen by the caller ----
    def i_type(self, kind, imm):
        assert -2048 <= imm <= 2047
        r = self.rng
        pick = r.randrange(3)
        if pick == 0:
            m = r.choice(I_ALU)
            self.add(kind, IMM_I, imm, OP_IMM, "%s %s, %s, %d" % (m, reg(r), reg(r), imm))
        elif pick == 1:
            m = r.choice(I_LOAD)
            self.add(kind, IMM_I, imm, OP_LOAD, "%s %s, %d(%s)" % (m, reg(r), imm, reg(r)))
        else:
            self.add(kind, IMM_I, imm, OP_JALR, "jalr %s, %d(%s)" % (reg(r), imm, reg(r)))

    def shift(self, kind, m, shamt):
        assert 0 <= shamt <= 31
        r = self.rng
        value = shamt + (0x400 if m == "srai" else 0)
        self.add(kind, IMM_I, value, OP_IMM, "%s %s, %s, %d" % (m, reg(r), reg(r), shamt))

    def s_type(self, kind, imm):
        assert -2048 <= imm <= 2047
        r = self.rng
        self.add(kind, IMM_S, imm, OP_STORE,
                 "%s %s, %d(%s)" % (r.choice(STORES), reg(r), imm, reg(r)))

    def b_type(self, kind, off):
        assert -4096 <= off <= 4094 and off % 2 == 0
        r = self.rng
        # ". + off": the target is this instruction's own address plus off, so
        # the assembler must encode exactly off (no labels, no linker).
        self.add(kind, IMM_B, off, OP_BRANCH,
                 "%s %s, %s, . %s %d" % (r.choice(BRANCHES), reg(r), reg(r),
                                         "+" if off >= 0 else "-", abs(off)))

    def u_type(self, kind, up):
        assert 0 <= up <= 0xFFFFF
        r = self.rng
        if r.randrange(2):
            self.add(kind, IMM_U, up << 12, OP_LUI, "lui %s, 0x%x" % (reg(r), up))
        else:
            self.add(kind, IMM_U, up << 12, OP_AUIPC, "auipc %s, 0x%x" % (reg(r), up))

    def j_type(self, kind, off):
        assert -1048576 <= off <= 1048574 and off % 2 == 0
        r = self.rng
        self.add(kind, IMM_J, off, OP_JAL,
                 "jal %s, . %s %d" % (reg(r), "+" if off >= 0 else "-", abs(off)))


def signed_powers(lo, hi, step):
    """+/- every power of two (multiple of step) inside [lo, hi]."""
    out = []
    p = step
    while p <= max(-lo, hi):
        for v in (p, -p):
            if lo <= v <= hi:
                out.append(v)
        p *= 2
    return out


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    out_dir = sys.argv[1]
    seed = int(sys.argv[2])
    n_rand = int(sys.argv[3]) if len(sys.argv) > 3 else 3000
    rng = random.Random(seed)
    g = Gen(rng)

    # ---------------- directed: range edges, single bits, bit patterns -------
    i_vals = [-2048, -2047, -1366, -1025, -1024, -2, -1, 0, 1, 2, 682, 1023, 1024, 1365, 2046, 2047]
    i_vals += signed_powers(-2048, 2047, 1)
    for v in i_vals:
        g.i_type(0, v)
        g.s_type(0, v)
    for m in SHIFTS:
        for sh in range(32):
            g.shift(0, m, sh)

    b_vals = [-4096, -4094, -2732, -2050, -2048, -2046, -6, -4, -2, 0, 2, 4, 6,
              1364, 2046, 2048, 2050, 2730, 4092, 4094]
    b_vals += signed_powers(-4096, 4094, 2)
    for v in b_vals:
        g.b_type(0, v)

    j_vals = [-1048576, -1048574, -699052, -4096, -2050, -2048, -2046, -6, -2, 0, 2, 6,
              2046, 2048, 2050, 4094, 4096, 349524, 699050, 1048572, 1048574]
    j_vals += signed_powers(-1048576, 1048574, 2)
    for v in j_vals:
        g.j_type(0, v)

    u_vals = [0, 1, 0x7FFFF, 0x80000, 0x80001, 0xFFFFE, 0xFFFFF, 0x55555, 0xAAAAA, 0x12345]
    u_vals += [1 << k for k in range(20)]
    for v in u_vals:
        g.u_type(0, v)

    # ---------------- random: uniform over each legal range ------------------
    for _ in range(n_rand):
        g.i_type(1, rng.randint(-2048, 2047))
        g.s_type(1, rng.randint(-2048, 2047))
        g.b_type(1, 2 * rng.randint(-2048, 2047))
        g.u_type(1, rng.randint(0, 0xFFFFF))
        g.j_type(1, 2 * rng.randint(-524288, 524287))
        g.shift(1, rng.choice(SHIFTS), rng.randint(0, 31))

    with open(out_dir + "/immgen_adv.s", "w") as f:
        f.write("# generated by tools/immgen_adv_gen.py seed=%d; do not edit\n" % seed)
        f.write("        .option norelax\n        .text\n")
        for line in g.lines:
            f.write("        " + line + "\n")
    with open(out_dir + "/immgen_adv.expect", "w") as f:
        for kind, src, value, opcode, text in g.expect:
            f.write("%d %d %08x %02x %s\n" % (kind, src, value, opcode, text))
    print("immgen_adv_gen: seed=%d, %d instructions" % (seed, len(g.lines)))


if __name__ == "__main__":
    main()
