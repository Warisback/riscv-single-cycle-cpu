#!/usr/bin/env python3
"""alu_adv_gen.py: independent Python oracle for rtl/alu.sv.

usage: alu_adv_gen.py <out.hex> [seed] [n_random_per_code]

Writes a $readmemh file for tb/alu_adv_tb.sv, made of 32-bit words:
    word 0            number of vectors N
    words 1+4k..4+4k  vector k: alu_ctrl, a, b, expected y
    word 1+4N         end marker E0F0E0F0 (so a truncated file is noticed)
Each vector sits on one text line ("ctrl a b y"); $readmemh treats spaces and
newlines the same, so the TB just sees consecutive words.

Semantics come from the RISC-V Unprivileged ISA v20260120, spec 2.4, p.27-29:
  ADD/ADDI: "Arithmetic overflow is ignored and the result is simply the low
            XLEN bits of the result" (2.4.1, p.28; 2.4.2, p.29)
  SUB:      "subtraction of rs2 from rs1" (2.4.2, p.29)
  SLT/SLTU: 1 if rs1 < rs2, signed / unsigned (2.4.2, p.29; SLTI/SLTIU 2.4.1, p.28)
  AND/OR/XOR: bitwise (2.4.1, p.28; 2.4.2, p.29)
  SLL/SRL/SRA: shift amount = "lower 5 bits of register rs2" (2.4.2, p.29);
            SRA copies "the original sign bit ... into the vacated upper bits"
            (2.4.1, p.28)
alu_ctrl numbering (ALU_ADD=0 .. ALU_SRA=9) and "unused ctrl -> 0" come from
docs/DESIGN.md; they are checked against rtl/rv_pkg.sv below.

Python integers have no width, so every result is masked to 32 bits and the
signed view of a pattern is computed explicitly (to_signed). Each operation is
computed TWO different ways (word arithmetic and a bit-by-bit/ripple version);
the generator stops if they ever disagree, so a slip in the oracle cannot
quietly become the "expected" value.
"""
import os
import random
import re
import sys

MASK = 0xFFFFFFFF
END_MARK = 0xE0F0E0F0

ADD, SUB, AND, OR, XOR, SLT, SLTU, SLL, SRL, SRA = range(10)
NAMES = ["ADD", "SUB", "AND", "OR", "XOR", "SLT", "SLTU", "SLL", "SRL", "SRA"]


def to_signed(x):
    """Two's-complement value of a 32-bit pattern: bit 31 weighs -2^31."""
    return x - (1 << 32) if x & 0x80000000 else x


def sext12(imm):
    """Sign-extend a 12-bit I-immediate, as the decoder hands it to the ALU."""
    imm &= 0xFFF
    return (imm - 0x1000 if imm & 0x800 else imm) & MASK


# ---------------- way 1: word arithmetic on Python integers ----------------
def alu_word(ctrl, a, b):
    sh = b & 0x1F                       # lower 5 bits of rs2 / the immediate
    if ctrl == ADD:
        return (a + b) & MASK
    if ctrl == SUB:
        return (a - b) & MASK
    if ctrl == AND:
        return a & b
    if ctrl == OR:
        return a | b
    if ctrl == XOR:
        return a ^ b
    if ctrl == SLT:
        return 1 if to_signed(a) < to_signed(b) else 0
    if ctrl == SLTU:
        return 1 if a < b else 0
    if ctrl == SLL:
        return (a << sh) & MASK
    if ctrl == SRL:
        return a >> sh
    if ctrl == SRA:
        return (to_signed(a) >> sh) & MASK   # Python >> on a negative int floors
    return 0                                 # codes 10..15 unused -> 0


# ---------------- way 2: bit-level / alternative arithmetic ----------------
def bit(x, i):
    return (x >> i) & 1


def ripple_add(a, b, cin):
    """32-bit ripple-carry adder; returns (sum, carry_out)."""
    s, c = 0, cin
    for i in range(32):
        t = bit(a, i) + bit(b, i) + c
        s |= (t & 1) << i
        c = t >> 1
    return s, c


def alu_bits(ctrl, a, b):
    sh = b % 32
    if ctrl == ADD:
        return ripple_add(a, b, 0)[0]
    if ctrl == SUB:                          # a + ~b + 1
        return ripple_add(a, (~b) & MASK, 1)[0]
    if ctrl in (AND, OR, XOR):
        r = 0
        for i in range(32):
            x, z = bit(a, i), bit(b, i)
            v = {AND: x & z, OR: x | z, XOR: x ^ z}[ctrl]
            r |= v << i
        return r
    if ctrl == SLTU:                         # no carry out of a + ~b + 1 <=> a < b
        return 1 - ripple_add(a, (~b) & MASK, 1)[1]
    if ctrl == SLT:                          # different signs: the negative one is less
        if bit(a, 31) != bit(b, 31):
            return bit(a, 31)
        return 1 - ripple_add(a, (~b) & MASK, 1)[1]
    if ctrl == SLL:
        return (a * 2 ** sh) % 2 ** 32
    if ctrl == SRL:
        return a // 2 ** sh
    if ctrl == SRA:
        q = to_signed(a) // 2 ** sh          # floor division = round toward -inf
        return q % 2 ** 32
    return 0


def expected(ctrl, a, b):
    w = alu_word(ctrl, a, b)
    v = alu_bits(ctrl, a, b)
    if w != v or not (0 <= w <= MASK):
        sys.exit(f"ORACLE DISAGREES ctrl={ctrl} a={a:08x} b={b:08x}: word={w:#x} bits={v:#x}")
    return w


def self_check():
    """Facts worked out by hand from the spec text; the oracle must agree."""
    assert to_signed(0x80000000) == -2 ** 31 and to_signed(0xFFFFFFFF) == -1
    assert sext12(0x800) == 0xFFFFF800 and sext12(0x7FF) == 0x7FF
    assert expected(ADD, 0x7FFFFFFF, 1) == 0x80000000        # overflow ignored
    assert expected(ADD, 0xFFFFFFFF, 1) == 0                 # low XLEN bits
    assert expected(ADD, 5, sext12(0xFFD)) == 2              # ADDI x, 5, -3
    assert expected(ADD, 0x1234, 0) == 0x1234                # MV = ADDI rd, rs1, 0
    assert expected(SUB, 0, 1) == 0xFFFFFFFF                 # rs1 - rs2
    assert expected(SUB, 3, 5) == 0xFFFFFFFE                 # not rs2 - rs1
    assert expected(XOR, 0x0F0F1234, sext12(0xFFF)) == 0xF0F0EDCB   # NOT = XORI -1
    assert expected(SLTU, 0, 1) == 1 and expected(SLTU, 7, 1) == 0  # SEQZ = SLTIU rd,rs,1
    assert expected(SLTU, 0, 9) == 1 and expected(SLTU, 0, 0) == 0  # SNEZ = SLTU rd,x0,rs
    assert expected(SLTU, 5, sext12(0xFFF)) == 1             # SLTIU: imm -1 is 0xFFFFFFFF
    assert expected(SLT, 0xFFFFFFFF, 1) == 1                 # -1 < 1
    assert expected(SLTU, 0xFFFFFFFF, 1) == 0                # 2^32-1 > 1
    assert expected(SLT, 0x80000000, 0x7FFFFFFF) == 1
    assert expected(SLT, 4, 4) == 0 and expected(SLTU, 4, 4) == 0
    assert expected(SLL, 1, 31) == 0x80000000
    assert expected(SLL, 1, 32) == 1                         # only b[4:0]
    assert expected(SRL, 0x80000000, 31) == 1
    assert expected(SRA, 0x80000000, 31) == 0xFFFFFFFF       # sign copied in
    assert expected(SRA, 0x80000000, 0x41F) == 0xFFFFFFFF    # SRAI x,31: imm[10]=1
    assert expected(SRA, 0xFFFFFFF1, 2) == 0xFFFFFFFC        # -15 >> 2 = -4
    assert expected(SRA, 0x70000000, 4) == 0x07000000        # positive: zeros
    for c in range(10, 16):
        assert expected(c, 0xFFFFFFFF, 0xFFFFFFFF) == 0


def check_pkg(pkg_path):
    """The ALU_* numbers in rv_pkg.sv must be the 0..9 assumed here."""
    text = open(pkg_path, encoding="utf-8").read()
    found = dict(re.findall(r"localparam\s+logic\s*\[3:0\]\s*ALU_(\w+)\s*=\s*4'd(\d+)", text))
    want = {n: str(i) for i, n in enumerate(NAMES)}
    if found != want:
        sys.exit(f"rv_pkg ALU_* encoding {found} != expected {want}")


# ---------------- operand sets ----------------
CORNERS = [
    0x00000000, 0x00000001, 0x00000002, 0x00000003,
    0x7FFFFFFE, 0x7FFFFFFF, 0x80000000, 0x80000001,
    0xFFFFFFFE, 0xFFFFFFFF, 0x0000001F, 0x00000020,
    0x00000021, 0x0000003F, 0xFFFFFFE0, 0xFFFFFFE1,
    0x0000041F, 0x00000400, 0x000007FF, 0xFFFFF800,   # SRAI imm, imm12 edges
    0xAAAAAAAA, 0x55555555, 0x0000FFFF, 0xFFFF0000,
    0x00008000, 0x00010000, 0xDEADBEEF, 0x40000000,
]

SHIFT_A = [0x80000000, 0xFFFFFFFF, 0x00000001, 0x12345678,
           0x87654321, 0x7FFFFFFF, 0xAAAAAAAA, 0x80000001]


def rand_operand(rng):
    k = rng.randrange(8)
    if k == 0:
        return rng.choice(CORNERS)
    if k == 1:
        return rng.randint(-16, 15) & MASK                 # small signed
    if k == 2:
        return 1 << rng.randrange(32)                      # one-hot
    if k == 3:
        return (~(1 << rng.randrange(32))) & MASK          # one-cold
    if k == 4:
        return sext12(rng.randrange(4096))                 # any I-immediate
    return rng.getrandbits(32)


def vectors_for(ctrl, rng, n_random):
    """All (a, b) pairs for one alu_ctrl code."""
    out = []
    # 1. every pair of corner values
    for x in CORNERS:
        for z in CORNERS:
            out.append((x, z))
    # 2. shift-amount sweep: b = 0..63, then random upper bits over each shamt
    for x in SHIFT_A:
        for s in range(64):
            out.append((x, s))
        for s in range(32):
            out.append((x, (rng.getrandbits(27) << 5) | s))
    # 3. SRAI/SRLI/SLLI immediates (imm[10] set for SRAI) and I-immediate edges
    for s in range(32):
        out.append((rng.getrandbits(32) | 0x80000000, 0x400 | s))
        out.append((rng.getrandbits(32), sext12(s)))
    for imm in (0x000, 0x001, 0x7FF, 0x800, 0xFFF, 0x7FE, 0x801):
        for _ in range(8):
            out.append((rng.getrandbits(32), sext12(imm)))
    for _ in range(128):
        out.append((rng.getrandbits(32), sext12(rng.randrange(4096))))
    # 4. neighbours for the compares: (x,x), (x,x+1), (x+1,x), (x,x-1)
    xs = [0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0, 0x7FFFFFFE, 0x80000001]
    xs += [rng.getrandbits(32) for _ in range(44)]
    for x in xs:
        out += [(x, x), (x, (x + 1) & MASK), ((x + 1) & MASK, x), (x, (x - 1) & MASK)]
    # 5. carry / borrow chains of every length
    for k in range(33):
        out.append((((1 << k) - 1) & MASK, 1))
        out.append(((1 << k) & MASK, 0xFFFFFFFF))
        out.append(((1 << k) & MASK, 1))
    # 6. seeded random
    for _ in range(n_random):
        x = rand_operand(rng)
        z = x if rng.randrange(16) == 0 else rand_operand(rng)
        out.append((x, z))
    return out


def transitions(rng):
    """Blocks where only ONE input changes from one vector to the next, to
    check that y follows every input (a combinational block that misses an
    input in its sensitivity would keep a stale y)."""
    out = []
    for _ in range(64):                      # only alu_ctrl changes
        x, z = rng.getrandbits(32), rng.getrandbits(32)
        for c in range(16):
            out.append((c, x, z))
    for c in range(16):                      # only b changes
        x = rng.getrandbits(32) | 0x80000000
        for _ in range(24):
            out.append((c, x, rng.getrandbits(32)))
    for c in range(16):                      # only a changes
        z = rng.getrandbits(32)
        for _ in range(24):
            out.append((c, rng.getrandbits(32), z))
    for c in (SLL, SRL, SRA):                # only b[4:0] changes, upper b fixed
        x, hi = 0x80000000 | rng.getrandbits(31), rng.getrandbits(27) << 5
        for s in range(32):
            out.append((c, x, hi | s))
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    out_path = sys.argv[1]
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    n_random = int(sys.argv[3]) if len(sys.argv) > 3 else 1200
    here = os.path.dirname(os.path.abspath(__file__))
    check_pkg(os.path.join(here, "..", "rtl", "rv_pkg.sv"))
    self_check()

    rng = random.Random(seed)
    vecs = []
    for c in range(16):
        for (x, z) in vectors_for(c, rng, n_random):
            vecs.append((c, x, z))
    vecs += transitions(rng)

    per = [0] * 16
    lines = [f"{len(vecs):08x}"]
    for (c, x, z) in vecs:
        per[c] += 1
        lines.append(f"{c:08x} {x:08x} {z:08x} {expected(c, x, z):08x}")
    lines.append(f"{END_MARK:08x}")
    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"alu_adv_gen: {len(vecs)} vectors, seed={seed}, per code min={min(per)} max={max(per)} -> {out_path}")
    if min(per) < 2000:
        sys.exit("fewer than 2000 vectors for some alu_ctrl code")


if __name__ == "__main__":
    main()
