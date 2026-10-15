#!/usr/bin/env python3
"""loadstore_adv_gen.py: independent Python oracle for rtl/store_unit.sv + rtl/load_unit.sv.

usage: loadstore_adv_gen.py <out.hex> [seed] [n_random_per_combo] [riscv-tests rv64ui dir]

Vector sections: 0. every load/store case of the official riscv-tests
(lb lbu lh lhu lw sb sh sw), whose published expected values the Python model
must reproduce; 1. all 8x4x8x4 funct3/offset combinations on corner data;
2./3. walking ones/zeros; 4. seeded random data, shuffled.

The model is a 4-byte memory word held as a Python bytearray. Little-endian
order is done ONLY with int.to_bytes / int.from_bytes(..., 'little'), never
with shifts or masks, so it shares no lane arithmetic with the RTL.

Spec: RISC-V Unprivileged ISA v20260120, spec 2.6, p.33-34:
  "LW loads a 32-bit value ... LH loads a 16-bit value from memory, then
   sign-extends ... LHU ... zero extends ... LB and LBU are defined analogously"
  "SW, SH, and SB instructions store 32-bit, 16-bit, and 8-bit values from the
   low bits of register rs2 to memory."
  Little-endian: "multibyte stores write the least-significant register byte at
   the lowest memory byte address" (p.33).
  Naturally aligned = "the effective address is divisible by the size of the
   access in bytes" (p.34).
funct3 values: RV32I listing, spec ch. 36, p.585
  (LB 000, LH 001, LW 010, LBU 100, LHU 101, SB 000, SH 001, SW 010).
Misaligned behaviour is the design's choice (store_unit/load_unit headers):
  misaligned store -> be=0, wdata=0, misaligned=1 (memory unchanged);
  misaligned load  -> data=0, misaligned=1.
Non-store funct3 -> be=0, wdata=0, mis=0. Non-load funct3 -> data=0, mis=0.

Output: $readmemh text, one 192-bit vector per line (48 hex digits):
  [191:188] kind  0 = header (rs2 field = seed), 3 = vector, F = end sentinel
                  (rs2 field = number of kind-3 vectors before it)
  [187:184] store funct3 (nibble)   [183:180] store addr_lo (nibble)
  [179:148] rs2
  [147:144] load funct3 (nibble)    [143:140] load addr_lo (nibble)
  [139:108] old memory word (before the store)
  [107:104] expected be             [103:100] expected store misaligned
  [99:68]   expected wdata
  [67:36]   expected memory word after the store
  [35:32]   expected load misaligned
  [31:0]    expected load data (read from the word AFTER the store)
"""
import os
import random
import re
import sys

MASK = 0xFFFFFFFF

# store funct3 -> number of bytes
STORE_BYTES = {0b000: 1, 0b001: 2, 0b010: 4}
# load funct3 -> (number of bytes, signed?)
LOAD_KIND = {0b000: (1, True), 0b001: (2, True), 0b010: (4, False),
             0b100: (1, False), 0b101: (2, False)}


def py_store(mem, f3, a, rs2):
    """Apply a store to the 4-byte bytearray mem. Return (be, wdata, mis)."""
    if f3 not in STORE_BYTES:
        return 0, 0, 0
    n = STORE_BYTES[f3]
    if a % n != 0:
        return 0, 0, 1                       # misaligned: nothing written
    src = rs2.to_bytes(4, 'little')[:n]      # the low n bytes of rs2
    lanes = bytearray(4)                     # what goes on the 32-bit bus
    lanes[a:a + n] = src
    mem[a:a + n] = src
    be = sum(1 << k for k in range(a, a + n))
    return be, int.from_bytes(lanes, 'little'), 0


def py_load(mem, f3, a):
    """Load from the 4-byte bytearray mem. Return (data, mis)."""
    if f3 not in LOAD_KIND:
        return 0, 0
    n, signed = LOAD_KIND[f3]
    if a % n != 0:
        return 0, 1
    value = int.from_bytes(bytes(mem[a:a + n]), 'little', signed=signed)
    return value & MASK, 0                    # two's complement in 32 bits


def self_check():
    """Hand-worked facts, so a broken oracle cannot pass silently."""
    m = bytearray((0x80FF7F01).to_bytes(4, 'little'))
    assert list(m) == [0x01, 0x7F, 0xFF, 0x80]          # byte 0 is the LSB
    assert py_load(m, 0b000, 0) == (0x00000001, 0)       # LB +1
    assert py_load(m, 0b000, 1) == (0x0000007F, 0)       # LB +127
    assert py_load(m, 0b000, 2) == (0xFFFFFFFF, 0)       # LB -1
    assert py_load(m, 0b000, 3) == (0xFFFFFF80, 0)       # LB -128
    assert py_load(m, 0b100, 3) == (0x00000080, 0)       # LBU 128
    assert py_load(m, 0b001, 2) == (0xFFFF80FF, 0)       # LH negative
    assert py_load(m, 0b101, 2) == (0x000080FF, 0)       # LHU
    assert py_load(m, 0b001, 0) == (0x00007F01, 0)       # LH positive
    assert py_load(m, 0b010, 0) == (0x80FF7F01, 0)       # LW
    assert py_load(m, 0b010, 2) == (0, 1)                # LW misaligned
    assert py_load(m, 0b101, 3) == (0, 1)                # LHU misaligned
    assert py_load(m, 0b110, 0) == (0, 0)                # not a load
    m = bytearray(4)
    assert py_store(m, 0b010, 0, 0x12345678) == (0xF, 0x12345678, 0)
    assert list(m) == [0x78, 0x56, 0x34, 0x12]
    m = bytearray(4)
    assert py_store(m, 0b000, 3, 0xFFFFFF80) == (0x8, 0x80000000, 0)
    assert py_store(m, 0b001, 2, 0xABCD1234) == (0xC, 0x12340000, 0)
    assert py_store(m, 0b001, 1, 0xABCD1234) == (0, 0, 1)
    assert py_store(m, 0b011, 0, 0xFFFFFFFF) == (0, 0, 0)
    assert int.from_bytes(m, 'little') == 0x12340000


def vector(sf3, slo, rs2, lf3, llo, old):
    mem = bytearray(old.to_bytes(4, 'little'))
    be, wdata, smis = py_store(mem, sf3, slo, rs2)
    new = int.from_bytes(mem, 'little')
    data, lmis = py_load(mem, lf3, llo)
    return (3, sf3, slo, rs2, lf3, llo, old, be, smis, wdata, new, lmis, data)


def pack(v):
    kind, sf3, slo, rs2, lf3, llo, old, be, smis, wdata, new, lmis, data = v
    return (f"{kind:01x}{sf3:01x}{slo:01x}{rs2:08x}{lf3:01x}{llo:01x}{old:08x}"
            f"{be:01x}{smis:01x}{wdata:08x}{new:08x}{lmis:01x}{data:08x}")


# Corner (old memory word, rs2) pairs: every byte's top bit both 0 and 1,
# alternating patterns, distinct bytes so a wrong lane is visible.
CORNERS = [
    (0x00000000, 0xFFFFFFFF), (0xFFFFFFFF, 0x00000000),
    (0x80FF7F01, 0x7F0180FF), (0xA5A5A5A5, 0x5A5A5A5A),
    (0x01234567, 0x89ABCDEF), (0x80808080, 0x7F7F7F7F),
    (0x7FFF8000, 0x80007FFF), (0xDEADBEEF, 0xCAFEBABE),
]


INSN_F3 = {'lb': 0b000, 'lh': 0b001, 'lw': 0b010, 'lbu': 0b100, 'lhu': 0b101,
           'sb': 0b000, 'sh': 0b001, 'sw': 0b010}
DATA_SIZE = {'byte': 1, 'half': 2, 'word': 4, 'dword': 8}
MACRO = re.compile(r'^\s*(TEST_LD_OP|TEST_LD_DEST_BYPASS|TEST_LD_SRC1_BYPASS|'
                   r'TEST_ST_OP|TEST_ST_SRC12_BYPASS|TEST_ST_SRC21_BYPASS)\s*\((.*)\)\s*;?\s*$')
DATA = re.compile(r'^(tdat\d*):\s*(?:\.(byte|half|word|dword)\s+(\S+))?\s*$')


def riscv_tests_vectors(isa_dir):
    """Third oracle: the official riscv-tests (deps/riscv-tests/isa/rv64ui).

    Parses the TEST_LD_* / TEST_ST_* macro calls and the tdat data of
    lb/lbu/lh/lhu/lw/sb/sh/sw.S, replays them in file order on the test's own
    data bytes, and asserts that the Python model gives the value the test
    expects (truncated to 32 bits, as MASK_XLEN does on RV32). Returns vectors.
    tdat is 16-byte aligned (RVTEST_DATA_BEGIN: .align 4; TEST_DATA is empty).
    """
    vecs = []
    for name in ('lb', 'lbu', 'lh', 'lhu', 'lw', 'sb', 'sh', 'sw'):
        with open(os.path.join(isa_dir, name + '.S')) as fh:
            lines = fh.read().splitlines()
        region, label = bytearray(), {}
        for ln in lines:
            m = DATA.match(ln.strip())
            if m:
                label[m.group(1)] = len(region)
                if m.group(2):
                    size = DATA_SIZE[m.group(2)]
                    region += (int(m.group(3), 0) & ((1 << 8 * size) - 1)).to_bytes(size, 'little')
        region += bytearray(-len(region) % 4)               # pad to whole words
        n_cases = 0
        for ln in lines:
            m = MACRO.match(ln)
            if not m:
                continue
            args = [a.strip() for a in m.group(2).split(',')]
            if m.group(1).startswith('TEST_LD'):
                ld, st = args[-4], None
            else:
                ld, st = args[-5], args[-4]
            result = int(args[-3], 0) & MASK
            addr = label[args[-1]] + int(args[-2], 0)
            w, lo = addr // 4, addr % 4
            old = int.from_bytes(region[4 * w:4 * w + 4], 'little')
            sf3 = INSN_F3[st] if st else 0b011               # 011 = no store
            v = vector(sf3, lo, result, INSN_F3[ld], lo, old)
            assert v[12] == result and v[11] == 0, \
                f"Python model disagrees with riscv-tests {name}.S: {ln.strip()} -> {v[12]:08x}"
            region[4 * w:4 * w + 4] = v[10].to_bytes(4, 'little')   # memory after the store
            vecs.append(v)
            n_cases += 1
        assert n_cases > 0, f"no test macros parsed from {name}.S"
    return vecs


def main():
    out = sys.argv[1]
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    n_rand = int(sys.argv[3]) if len(sys.argv) > 3 else 16
    isa_dir = sys.argv[4] if len(sys.argv) > 4 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), '..', 'deps', 'riscv-tests', 'isa', 'rv64ui')
    self_check()
    rng = random.Random(seed)

    # 0. The official riscv-tests load/store cases (third oracle, real source).
    vecs = riscv_tests_vectors(isa_dir)
    n_official = len(vecs)

    # 1. Every store funct3 x store offset x load funct3 x load offset, with
    #    corner data. Load offset is the inner loop, so consecutive vectors often
    #    change one input only (checks combinational sensitivity too).
    for old, rs2 in CORNERS:
        for sf3 in range(8):
            for slo in range(4):
                for lf3 in range(8):
                    for llo in range(4):
                        vecs.append(vector(sf3, slo, rs2, lf3, llo, old))

    # 2. Walking ones / zeros through rs2 (only rs2 changes between vectors),
    #    read back as a whole word with LW: every rs2 bit's route to memory.
    for sf3, n in STORE_BYTES.items():
        for slo in range(0, 4, n):
            for old in (0x00000000, 0xFFFFFFFF):
                for b in range(32):
                    for rs2 in (1 << b, MASK ^ (1 << b)):
                        vecs.append(vector(sf3, slo, rs2, 0b010, 0, old))

    # 3. Walking ones / zeros through the memory word, no store (funct3 011),
    #    every load at every aligned offset: every memory bit's route to rd.
    for lf3, (n, _) in LOAD_KIND.items():
        for llo in range(0, 4, n):
            for b in range(32):
                for old in (1 << b, MASK ^ (1 << b)):
                    vecs.append(vector(0b011, 0, 0, lf3, llo, old))

    # 4. Seeded random data on every combination, in shuffled order so that
    #    consecutive vectors differ in every input.
    rnd = []
    for sf3 in range(8):
        for slo in range(4):
            for lf3 in range(8):
                for llo in range(4):
                    for _ in range(n_rand):
                        rnd.append(vector(sf3, slo, rng.getrandbits(32), lf3, llo,
                                          rng.getrandbits(32)))
    rng.shuffle(rnd)
    vecs += rnd

    # Coverage the oracle must have produced: every aligned load sees its sign
    # bit both 0 and 1; every misaligned case appears.
    seen = set()
    for v in vecs:
        _, sf3, slo, rs2, lf3, llo, old, be, smis, wdata, new, lmis, data = v
        if lf3 in LOAD_KIND and not lmis:
            n, _ = LOAD_KIND[lf3]
            top = int.from_bytes(new.to_bytes(4, 'little')[llo:llo + n], 'little') >> (8 * n - 1)
            seen.add(('sign', lf3, llo, top))
        if lmis:
            seen.add(('lmis', lf3, llo))
        if smis:
            seen.add(('smis', sf3, slo))
    for lf3, (n, _) in LOAD_KIND.items():
        for llo in range(4):
            if llo % n == 0:
                assert ('sign', lf3, llo, 0) in seen and ('sign', lf3, llo, 1) in seen
            else:
                assert ('lmis', lf3, llo) in seen
    for sf3, n in STORE_BYTES.items():
        for slo in range(4):
            if slo % n:
                assert ('smis', sf3, slo) in seen

    with open(out, 'w') as fh:
        fh.write(f"0{0:01x}{0:01x}{seed & MASK:08x}" + "0" * 37 + "\n")   # header
        for v in vecs:
            fh.write(pack(v) + "\n")
        fh.write(f"f00{len(vecs):08x}" + "0" * 37 + "\n")                  # sentinel
    print(f"loadstore_adv_gen: seed={seed} vectors={len(vecs)} "
          f"(riscv-tests cases={n_official}, all agree with the Python model) -> {out}")


if __name__ == '__main__':
    main()
