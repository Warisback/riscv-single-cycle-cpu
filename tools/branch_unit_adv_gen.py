#!/usr/bin/env python3
"""branch_unit_adv_gen.py: independent Python oracle for rtl/branch_unit.sv.

usage: branch_unit_adv_gen.py <out.hex> [seed] [n_random]

Writes a $readmemh file for tb/branch_unit_adv_tb.sv. One vector per line,
18 hex digits = 72 bits:
    [71:68]  funct3 in a nibble (0-7)
    [67:36]  a  (rs1 value)
    [35:4]   b  (rs2 value)
    [3:0]    expected taken (0 or 1)
The last line is a sentinel: nibble F, a = number of vectors before it,
b = 0x5EA1ED00, expected = 0. The TB checks that it saw exactly that many.
It also writes <out>_count.hex (one 8-digit word = number of vectors).

Branch semantics: RISC-V Unprivileged ISA v20260120, spec 2.5.2, p.31-32
("BLT and BLTU take the branch if rs1 is less than rs2, using signed and
unsigned comparison respectively", BGE/BGEU = greater than or equal).
funct3 values: RV32I listing, spec ch. 36, p.585.
funct3 010/011 are not branches; docs/DESIGN.md item 4 says taken = 0 for them.

The oracle uses Python integers, which have no width: a 32-bit pattern is
turned into a signed number explicitly (to_signed), and the unsigned compare
is just the pattern read as a non-negative integer. No bit tricks.
"""
import random
import sys

MASK = 0xFFFFFFFF


def to_signed(x):
    """Read a 32-bit pattern as a two's-complement number."""
    return x - (1 << 32) if x & 0x80000000 else x


def expected(f3, a, b):
    sa, sb = to_signed(a), to_signed(b)
    if f3 == 0b000:
        return a == b          # BEQ
    if f3 == 0b001:
        return a != b          # BNE
    if f3 == 0b100:
        return sa < sb         # BLT  (signed)
    if f3 == 0b101:
        return sa >= sb        # BGE  (signed)
    if f3 == 0b110:
        return a < b           # BLTU (unsigned)
    if f3 == 0b111:
        return a >= b          # BGEU (unsigned)
    return False               # 010, 011: not a branch


def self_check():
    """A few facts worked out by hand, so a broken oracle cannot pass silently."""
    assert to_signed(0x80000000) == -2**31
    assert to_signed(0x7FFFFFFF) == 2**31 - 1
    assert to_signed(0xFFFFFFFF) == -1
    assert expected(0b100, 0xFFFFFFFF, 0x00000001) is True    # -1 < 1 signed
    assert expected(0b110, 0xFFFFFFFF, 0x00000001) is False   # 2^32-1 > 1 unsigned
    assert expected(0b101, 0x80000000, 0x7FFFFFFF) is False   # INT_MIN >= INT_MAX? no
    assert expected(0b111, 0x80000000, 0x7FFFFFFF) is True    # 2^31 >= 2^31-1 unsigned
    assert expected(0b101, 5, 5) is True and expected(0b111, 5, 5) is True
    assert expected(0b100, 5, 5) is False and expected(0b110, 5, 5) is False
    assert expected(0b000, 0, 0x80000000) is False and expected(0b001, 0, 0x80000000) is True
    assert expected(0b010, 1, 1) is False and expected(0b011, 0, 1) is False
    # Branch with overflowing difference: INT_MIN - 1 overflows to INT_MAX.
    assert expected(0b100, 0x80000000, 0x00000001) is True


def corner_grid():
    vals = {0, 1, 2, 3, 5, 7,
            0x7FFFFFFE, 0x7FFFFFFF, 0x80000000, 0x80000001,
            0xFFFFFFFE, 0xFFFFFFFF, 0x55555555, 0xAAAAAAAA,
            0x0000FFFF, 0xFFFF0000, 0x00008000, 0xFFFF8000,
            0x12345678, 0xDEADBEEF, 0x40000000, 0xC0000000}
    for k in range(32):
        vals.add(1 << k)                    # single bit set
        vals.add(((1 << k) - 1) & MASK)     # all bits below k set
        vals.add(~(1 << k) & MASK)          # single bit clear
        vals.add(-(1 << k) & MASK)          # -(2^k)
    # every combination of the two top and two bottom bits
    for hi in range(4):
        for lo in range(4):
            vals.add((hi << 30) | lo)
    return sorted(vals)


def main():
    out = sys.argv[1]
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    n_random = int(sys.argv[3]) if len(sys.argv) > 3 else 40000
    self_check()
    rng = random.Random(seed)
    vecs = []

    # 1. grid of corner values crossed with each other, every funct3 (0..7)
    grid = corner_grid()
    for a in grid:
        for b in grid:
            for f3 in range(8):
                vecs.append((f3, a, b))
    n_grid = len(vecs)

    # 2. neighbours: x vs x+1 and x vs x-1 (both orders), the >= vs > boundary
    for x in grid:
        for d in (1, -1):
            y = (x + d) & MASK
            for f3 in range(8):
                vecs.append((f3, x, y))
                vecs.append((f3, y, x))

    # 3. seeded random, several shapes so every branch is seen both ways
    for _ in range(n_random):
        mode = rng.randrange(6)
        a = rng.getrandbits(32)
        if mode == 0:
            b = rng.getrandbits(32)                        # unrelated
        elif mode == 1:
            b = a                                          # equal
        elif mode == 2:
            b = a ^ (1 << rng.randrange(32))               # one bit differs
        elif mode == 3:
            k = rng.randrange(1, 33)                       # same top bits, random low k bits
            b = (a & ~((1 << k) - 1) & MASK) | rng.getrandbits(k)
        elif mode == 4:
            b = (a + rng.choice((1, -1, 2, -2))) & MASK    # neighbours
        else:
            a = rng.choice(grid)
            b = rng.choice(grid)
        vecs.append((rng.randrange(8), a, b))

    with open(out, "w") as f:
        for f3, a, b in vecs:
            word = (f3 << 68) | (a << 36) | (b << 4) | int(expected(f3, a, b))
            f.write(f"{word:018x}\n")
        f.write(f"{(0xF << 68) | (len(vecs) << 36) | (0x5EA1ED00 << 4):018x}\n")
    # One-word file with the vector count, so the TB can $readmemh exactly
    # [0:count] (vectors + sentinel) without a "not enough words" warning.
    with open(out.replace(".hex", "") + "_count.hex", "w") as f:
        f.write(f"{len(vecs):08x}\n")

    print(f"branch_unit_adv_gen: {len(vecs)} vectors ({len(grid)} grid values, "
          f"{n_grid} grid vectors), seed={seed}, file={out}")


if __name__ == "__main__":
    main()
