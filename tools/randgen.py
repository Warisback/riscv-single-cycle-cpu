#!/usr/bin/env python3
"""randgen.py: constrained-random RV32I test programs for the core.

    usage: python3 tools/randgen.py --seed N --n INSTRS --out file.S

The program is not self-checking. It is run on the ISS (tools/iss.py) to get
the golden trace, and the RTL trace must match it line for line
(tools/compare.py). So the generator only has to make programs that are
legal, always end, and stress the design:

  * all 37 RV32I mnemonics: RV32I has 40 instructions (spec ch. 2 intro, p.23);
    FENCE, ECALL and EBREAK are left out (the core runs them as NOPs)
  * a pool of 8 registers, and sources biased to the last 1-3 destinations,
    so most instructions depend on a recent one;
    extra load-use pairs and stores of just-loaded values
  * loads and stores through a base register that is set once and never
    written again, at naturally aligned addresses in 0x8000-0x8FFF (inside
    the data region of tools/link.ld, 0x8000-0xFFEF); sometimes the address
    is first computed into a pool register, so it depends on a recent result too
  * branches and jumps only go forward, so every program ends; the end is
    the riscv-tests style PASS store (1 to TOHOST = 0xFFF0)

The program is a list of small "blocks": one instruction, or a short pattern
such as load + use. Jump and branch targets are always block starts, so a jump
never lands between the two halves of a pattern. A taken branch always skips
at least one block, so "taken" can be read from a trace as next pc != pc + 4.

Same seed and n => the same file, byte for byte (random.Random(seed), and no
set or dict iteration order is involved).
"""
import argparse
import random

TOHOST_ADDR = 0xFFF0
DATA_START = 0x8000          # tools/link.ld puts .data here
DATA_WORDS = 1024            # 0x8000-0x8FFF, filled with random words
BASE_ADDR = 0x8800           # base +/- 2 KiB (the 12-bit offset) covers all the data
POOL_SIZE = 8

# The 37 mnemonics by class (spec section 2.4 computational, section 2.5 control transfer, section 2.6 load/store)
OP_R = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
OP_I = ["addi", "slti", "sltiu", "xori", "ori", "andi", "slli", "srli", "srai"]
SHIFT_I = ["slli", "srli", "srai"]
LOADS = {"lb": 1, "lh": 2, "lw": 4, "lbu": 1, "lhu": 2}       # name -> size in bytes
STORES = {"sb": 1, "sh": 2, "sw": 4}
BRANCHES = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]

# How often each kind of block is picked (relative weights).
BLOCK_WEIGHTS = [
    ("op", 22), ("opimm", 22), ("lui", 3), ("auipc", 2),
    ("load", 10), ("store", 8), ("loaduse", 7), ("addrcalc", 4),
    ("branch", 12), ("jal", 4), ("jalr", 4),
]

# Values that tend to find bugs: 0, +-1, sign bits, byte and halfword edges.
SPECIAL_VALUES = [0x00000000, 0x00000001, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF,
                  0x0000007F, 0x00000080, 0x000000FF, 0x00007FFF, 0x00008000,
                  0x0000FFFF, 0xFFFF8000, 0xFFFFFF80, 0x55555555, 0xAAAAAAAA]


def reg(n):
    return f"x{n}"


def hi_lo(value):
    """Split a 32-bit value for lui + addi (addi sign-extends its 12 bits)."""
    lo = value & 0xFFF
    if lo >= 0x800:
        lo -= 0x1000
    hi = ((value - lo) >> 12) & 0xFFFFF
    return hi, lo


class Gen:
    def __init__(self, seed, n):
        self.rng = random.Random(seed)
        self.seed = seed
        self.n = n
        regs = list(range(1, 32))
        self.rng.shuffle(regs)
        self.base = regs[0]                          # memory base, never a destination
        self.pool = sorted(regs[1:1 + POOL_SIZE])    # everything else uses these
        self.recent = []                             # last 3 destinations, newest last
        self.hot = [BASE_ADDR + 4 * k for k in range(-4, 4)]   # 8 words used often
        # Each block: {"comment", "lines", "skip"}; lines may hold {target} / {off}
        # placeholders that are filled in once every block exists (resolve()).
        self.blocks = []

    # ------------------------------------------------------------ random pieces
    def chance(self, p):
        return self.rng.random() < p

    def src(self):
        """A source register, biased to the destinations 1, 2, 3 instructions back."""
        r = self.rng
        if self.recent and self.chance(0.6):
            d = r.choices([1, 2, 3], weights=[3, 2, 1])[0]
            if d <= len(self.recent):
                return self.recent[-d]
        if self.chance(0.05):
            return 0
        return r.choice(self.pool)

    def dst(self, avoid=()):
        """A destination register from the pool, sometimes x0 (result thrown away)."""
        if self.chance(0.03):
            return 0
        return self.rng.choice([x for x in self.pool if x not in avoid])

    def wrote(self, rd):
        if rd != 0:
            self.recent = (self.recent + [rd])[-3:]

    def imm12(self):
        r = self.rng
        k = r.random()
        if k < 0.2:
            return r.choice([0, 1, -1, 2047, -2048])
        if k < 0.5:
            return r.randint(-16, 16)
        return r.randint(-2048, 2047)

    def imm20(self):
        if self.chance(0.2):
            return self.rng.choice([0, 1, 0x80000, 0xFFFFF, 0x7FFFF])
        return self.rng.randint(0, 0xFFFFF)

    def shamt(self):
        if self.chance(0.3):
            return self.rng.choice([0, 1, 31])
        return self.rng.randint(0, 31)

    def mem_addr(self, size):
        """A naturally aligned address in 0x8000-0x8FFF for an access of `size` bytes.
        60% go to 8 'hot' words, so stores and later loads often meet."""
        r = self.rng
        if self.chance(0.6):
            return r.choice(self.hot) + r.randrange(0, 4, size)
        return DATA_START + r.randrange(0, DATA_WORDS * 4, size)

    # ------------------------------------------------------------ single instructions
    def ins_op(self):
        name = self.rng.choice(OP_R)
        rs1, rs2 = self.src(), self.src()
        rd = self.dst()
        self.wrote(rd)
        return f"{name:<6}{reg(rd)}, {reg(rs1)}, {reg(rs2)}"

    def ins_opimm(self, avoid=()):
        name = self.rng.choice(OP_I)
        rs1 = self.src()
        rd = self.dst(avoid)
        self.wrote(rd)
        imm = self.shamt() if name in SHIFT_I else self.imm12()
        return f"{name:<6}{reg(rd)}, {reg(rs1)}, {imm}"

    def ins_load(self, rd):
        name = self.rng.choice(list(LOADS))
        addr = self.mem_addr(LOADS[name])
        self.wrote(rd)
        return f"{name:<6}{reg(rd)}, {addr - BASE_ADDR}({reg(self.base)})"

    def ins_store(self, rs2):
        name = self.rng.choice(list(STORES))
        addr = self.mem_addr(STORES[name])
        return f"{name:<6}{reg(rs2)}, {addr - BASE_ADDR}({reg(self.base)})"

    # ------------------------------------------------------------ blocks
    def add(self, lines, comment="", skip=None):
        self.blocks.append({"comment": comment, "lines": lines, "skip": skip})

    def block(self, kind):
        r = self.rng
        if kind == "op":
            self.add([self.ins_op()])
        elif kind == "opimm":
            self.add([self.ins_opimm()])
        elif kind in ("lui", "auipc"):
            rd = self.dst()
            self.wrote(rd)
            self.add([f"{kind:<6}{reg(rd)}, {self.imm20():#x}"])
        elif kind == "load":
            self.add([self.ins_load(self.dst())])
        elif kind == "store":
            self.add([self.ins_store(self.src())])
        elif kind == "loaduse":
            self.block_loaduse()
        elif kind == "addrcalc":
            self.block_addrcalc()
        elif kind == "branch":
            name = r.choice(BRANCHES)
            rs1 = self.src()
            rs2 = rs1 if self.chance(0.3) else self.src()   # equal operands: both outcomes
            self.add([f"{name:<6}{reg(rs1)}, {reg(rs2)}, {{target}}"],
                     "forward branch to {target}", skip=r.randint(1, 4))
        elif kind == "jal":
            rd = self.dst() if self.chance(0.8) else 0
            self.wrote(rd)
            self.add([f"jal   {reg(rd)}, {{target}}"], "forward jal to {target}", skip=r.randint(1, 4))
        elif kind == "jalr":
            self.block_jalr()

    def block_loaduse(self):
        """A load and, right after it, an instruction that needs the loaded value."""
        r = self.rng
        way = r.choice(["rs1", "rs2", "store", "x0"])
        if way == "x0":
            # load to x0: the value is thrown away, and reading x0 must still give 0
            load = self.ins_load(0)
            rs2 = self.src()
            rd = self.dst()
            self.wrote(rd)
            self.add([load, f"{r.choice(OP_R):<6}{reg(rd)}, x0, {reg(rs2)}"], "load to x0, then read x0")
            return
        t = r.choice(self.pool)
        load = self.ins_load(t)
        if way == "store":
            self.add([load, self.ins_store(t)], "load, then store the loaded value")
            return
        other = self.src()
        rd = self.dst()
        self.wrote(rd)
        name = r.choice(OP_R)
        if way == "rs1":
            use = f"{name:<6}{reg(rd)}, {reg(t)}, {reg(other)}"
        else:
            use = f"{name:<6}{reg(rd)}, {reg(other)}, {reg(t)}"
        self.add([load, use], f"load-use on {way}")

    def block_addrcalc(self):
        """addi t, base, k ; 0-2 other instructions ; load/store at off(t).
        t is a pool register, so the address depends on a recent result."""
        r = self.rng
        t = r.choice(self.pool)
        is_load = self.chance(0.5)
        table = LOADS if is_load else STORES
        name = r.choice(list(table))
        while True:
            k = r.randrange(-1024, 1024)
            addr = self.mem_addr(table[name])
            off = addr - BASE_ADDR - k
            if -2048 <= off <= 2047:
                break
        lines = [f"addi  {reg(t)}, {reg(self.base)}, {k}"]
        self.wrote(t)
        for _ in range(r.choice([0, 0, 1, 2])):
            lines.append(self.ins_opimm(avoid=[t]))
        if is_load:
            rd = self.dst()
            self.wrote(rd)
            lines.append(f"{name:<6}{reg(rd)}, {off}({reg(t)})")
        else:
            lines.append(f"{name:<6}{reg(self.src())}, {off}({reg(t)})")
        self.add(lines, f"address made {len(lines) - 1} instruction(s) before the {name}")

    def block_jalr(self):
        """A forward JALR. The base t is made right before it (0-2 fillers between):
        either auipc t, 0 (t = own pc, jalr offset = distance to the target) or
        lui/addi of the target address. Sometimes the target is odd (+1): JALR
        clears bit 0 (spec section 2.5.1, p.30). Sometimes rd = t (read before write)."""
        r = self.rng
        t = r.choice(self.pool)
        rd = self.dst() if self.chance(0.8) else 0
        if self.chance(0.15):
            rd = t
        odd = self.chance(0.25)
        plus = "+1" if odd else ""
        if self.chance(0.6):
            lines = [f"auipc {reg(t)}, 0"]
            how = "auipc base"
        else:
            lines = [f"lui   {reg(t)}, %hi({{target}}{plus})",
                     f"addi  {reg(t)}, {reg(t)}, %lo({{target}}{plus})"]
            how = "absolute address"
        self.wrote(t)
        for _ in range(r.choice([0, 0, 1, 2])):
            lines.append(self.ins_opimm(avoid=[t]))
        if how == "auipc base":
            lines.append(f"jalr  {reg(rd)}, {{off}}({reg(t)})")
        else:
            lines.append(f"jalr  {reg(rd)}, 0({reg(t)})")
        self.wrote(rd)
        note = f"jalr to {{target}} ({how}{', target +1: bit 0 gets cleared' if odd else ''})"
        self.add(lines, note, skip=r.randint(1, 4))
        self.blocks[-1]["odd"] = odd

    # ------------------------------------------------------------ whole program
    def generate(self):
        kinds = [k for k, _ in BLOCK_WEIGHTS]
        weights = [w for _, w in BLOCK_WEIGHTS]
        count = 0
        while count < self.n:
            self.block(self.rng.choices(kinds, weights=weights)[0])
            count += len(self.blocks[-1]["lines"])
        self.resolve()

    def resolve(self):
        """Fill in jump targets: block i jumps to block i + 1 + skip (or to the end)."""
        nblocks = len(self.blocks)
        start = []                      # byte offset of each block from the first one
        pos = 0
        for b in self.blocks:
            start.append(pos)
            pos += 4 * len(b["lines"])
        start.append(pos)               # the end label
        self.targets = [False] * (nblocks + 1)
        for i, b in enumerate(self.blocks):
            if b["skip"] is None:
                continue
            j = min(i + 1 + b["skip"], nblocks)
            self.targets[j] = True
            label = f"L{j}" if j < nblocks else "Lend"
            # auipc is the block's first instruction, so the jalr offset is
            # (target - auipc address), +1 for an odd target
            off = start[j] - start[i] + (1 if b.get("odd") else 0)
            assert off <= 2047
            b["lines"] = [line.format(target=label, off=off) for line in b["lines"]]
            b["comment"] = b["comment"].format(target=label)

    # ------------------------------------------------------------ output
    def init_lines(self):
        r = self.rng
        hi, lo = hi_lo(BASE_ADDR)
        out = [(f"data base {reg(self.base)} = {BASE_ADDR:#x}, never written again",
                [f"lui   {reg(self.base)}, {hi:#x}",
                 f"addi  {reg(self.base)}, {reg(self.base)}, {lo}"])]
        values = []
        for x in self.pool:
            k = r.random()
            if k < 0.3:
                v = r.choice(SPECIAL_VALUES)
            elif k < 0.45 and values:
                v = r.choice(values)            # equal values make beq/bge/bgeu taken
            else:
                v = r.getrandbits(32)
            values.append(v)
            hi, lo = hi_lo(v)
            out.append((f"{reg(x)} = {v:#010x}",
                         [f"lui   {reg(x)}, {hi:#x}", f"addi  {reg(x)}, {reg(x)}, {lo}"]))
        return out

    def data_words(self):
        r = self.rng
        return [r.choice(SPECIAL_VALUES) if self.chance(0.15) else r.getrandbits(32)
                for _ in range(DATA_WORDS)]

    def text(self):
        init = self.init_lines()
        data = self.data_words()
        out = [f"# Generated by tools/randgen.py --seed {self.seed} --n {self.n}. Do not edit.",
               "# Not self-checking: its trace is compared with the ISS trace (tools/compare.py).",
               f"# Data base {reg(self.base)} = {BASE_ADDR:#x}; loads and stores reach "
               f"{DATA_START:#x}-{DATA_START + 4 * DATA_WORDS - 1:#x}.",
               f"# Register pool: {', '.join(reg(x) for x in self.pool)}",
               "",
               '        .section .text.init, "ax", @progbits',
               "        .globl _start",
               "_start:"]
        for comment, lines in init:
            out.append(f"        # {comment}")
            out += [f"        {line}" for line in lines]
        out.append("        # ---- random body")
        for k, b in enumerate(self.blocks):
            if b["comment"]:
                out.append(f"        # b{k}: {b['comment']}")
            for m, line in enumerate(b["lines"]):
                label = f"L{k}:" if (m == 0 and self.targets[k]) else ""
                out.append(f"{label:<8}{line}")
        hi, lo = hi_lo(TOHOST_ADDR)
        a, v = self.pool[0], self.pool[1]
        out += ["Lend:   # ---- end: store 1 to TOHOST (PASS)",
                f"        lui   {reg(a)}, {hi:#x}",
                f"        addi  {reg(a)}, {reg(a)}, {lo}",
                f"        addi  {reg(v)}, x0, 1",
                f"        sw    {reg(v)}, 0({reg(a)})",
                "Lspin:  jal   x0, Lspin",
                "",
                "        .data",
                f"rdata:  # {DATA_START:#x}, {DATA_WORDS} random words"]
        for k in range(0, len(data), 8):
            out.append("        .word " + ", ".join(f"{w:#010x}" for w in data[k:k + 8]))
        return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description="constrained-random RV32I program generator")
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--n", type=int, default=300, help="about how many body instructions")
    ap.add_argument("--out", required=True, help="output assembly file (.S)")
    args = ap.parse_args()
    g = Gen(args.seed, args.n)
    g.generate()
    with open(args.out, "w", newline="\n") as f:
        f.write(g.text())


if __name__ == "__main__":
    main()
