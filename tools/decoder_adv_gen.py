#!/usr/bin/env python3
"""decoder_adv_gen.py: GNU as is the oracle for tb/decoder_adv_tb.sv.

    usage: python3 tools/decoder_adv_gen.py [--seed N] [--per N] [--out DIR]

What it does (from the repository root; tools/decoder_adv_run.sh runs it):
  1. Writes assembly: every RV32I instruction of the spec listing (Unprivileged
     ISA v20260120, ch. 36, pp. 585-586), directed corner cases first, then
     --per random instances of each (random registers and immediates).
     A second set holds words from other extensions (M, A, F, Zicsr, Zifencei,
     RV64I, custom-0, raw words) that maindec cannot tell apart from RV32I by
     the opcode alone, or that must be flagged illegal.
  2. Assembles with GNU as (found by tools/rvtools.py; -mno-relax), takes
     the words from `objcopy -O binary`, and checks:
       - one word per source line (nothing expanded or compressed),
       - no relocations (so every branch/jump offset is really encoded). Older
         binutils (2.42) leave `.+N` branch and jump targets as relocations, so
         the object is then linked once and the words come from the linked file,
       - `objdump -M no-aliases` gives back the same mnemonic and word.
  3. Writes <out>/vectors.hex, one line per instruction, 48 hex digits:
       mnemonic (16 ASCII bytes, right-justified, NUL padded)
       | immediate exactly as typed in the source (32 bits)
       | the instruction word from GNU as (32 bits)
     plus <out>/vectors_count.txt and a readable <out>/vectors.lst.
     The TB never sees the source text: it gets the word (to decode) and the
     typed immediate (to compute the expected result independently).
  4. Provenance check: re-assembles the instruction texts that tb/aludec_tb.sv
     claims came from GNU as and compares them with the hex in that file.
"""
import argparse
import os
import random
import re
import subprocess
import sys

G = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(G, "tools"))
import rvtools  # noqa: E402  (finds the RISC-V binutils, like tools/common.sh)

RV = rvtools.find_prefix()   # e.g. "riscv64-unknown-elf-", or None


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"decoder_adv_gen: {' '.join(cmd)} failed:\n{p.stderr}")
    return p.stdout


# ---------------------------------------------------------------- the source
# One entry = (mnemonic, typed immediate, assembly text, disassembly token).
# The typed immediate means: I/S/shift: the value written; U: the 20-bit
# value written (TB shifts it by 12); B/J: the byte offset written as .+N.

I_ALU = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SHIFT_I = ["slli", "srli", "srai"]
R_ALU = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
BRANCH = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
LOADS = ["lb", "lh", "lw", "lbu", "lhu"]
STORES = ["sb", "sh", "sw"]


def off(n):
    """Branch/jump target written relative to the instruction: .+8 / .-4096"""
    return f".{n:+d}"


def e(mn, imm, text, dis="same"):
    """dis: the mnemonic objdump must print ("same" = mn, None = do not check)."""
    return (mn, imm, text, mn if dis == "same" else dis)


def directed():
    v = []
    # U-type: LUI / AUIPC (spec 2.4.1, p. 28)
    for imm in (0x00000, 0xfffff, 0x80000, 0x12345, 0x00001):
        v.append(e("lui", imm, f"lui x1, {imm:#x}"))
        v.append(e("auipc", imm, f"auipc x5, {imm:#x}"))
    # JAL: +-1 MiB range (spec 2.5.1, p. 30)
    for n in (2048, -4, 1048574, -1048576, 4, 2):
        v.append(e("jal", n, f"jal x1, {off(n)}"))
    v.append(e("jal", 8, f"jal x0, {off(8)}"))           # plain J
    # JALR: I-imm, LSB cleared (p. 30)
    for rd, imm, rs1 in ((1, -1024, 2), (0, 0, 1), (5, 2047, 6), (1, -2048, 0), (1, 1, 3)):
        v.append(e("jalr", imm, f"jalr x{rd}, {imm}(x{rs1})"))
    # Branches: +-4 KiB (spec 2.5.2, p. 31)
    for b in BRANCH:
        for n in (8, -4096, 4094, -2048, 2, -2):
            v.append(e(b, n, f"{b} x1, x2, {off(n)}"))
    # Loads / stores (spec 2.6, p. 33): imm bit 10 set, both ends of the range
    for ld in LOADS:
        for imm in (0, -1, -1024, 2047, -2048, 1024):
            v.append(e(ld, imm, f"{ld} x3, {imm}(x4)"))
    for st in STORES:
        for imm in (0, -1, -1024, 2047, -2048, 1024):
            v.append(e(st, imm, f"{st} x5, {imm}(x6)"))
    # OP-IMM: instr[30] = imm[10] must never turn ADDI into SUB (p. 28)
    for op in I_ALU:
        for imm in (-1024, -1, 2047, -2048, 0, 1024, 1023):
            v.append(e(op, imm, f"{op} x1, x2, {imm}"))
    v.append(e("addi", 0, "addi x0, x0, 0"))              # canonical NOP (2.4.3)
    # shifts by a constant: bit 30 picks SRAI (p. 28)
    for op in SHIFT_I:
        for sh in (0, 1, 31, 16):
            v.append(e(op, sh, f"{op} x1, x2, {sh}"))
    v.append(e("slli", 0x1f, "slli x0, x0, 0x1f"))        # semihosting entry NOP (2.8)
    v.append(e("srai", 7, "srai x0, x0, 7"))              # semihosting exit NOP
    # OP (p. 29)
    for op in R_ALU:
        v.append(e(op, 0, f"{op} x3, x1, x2"))
        v.append(e(op, 0, f"{op} x0, x31, x30"))          # HINT form (rd = x0)
    # MISC-MEM / SYSTEM (2.7, 2.8)
    v.append(e("fence", 0, "fence", "fence"))
    v.append(e("fence", 0, "fence rw, rw", "fence"))
    v.append(e("fence", 0, "fence r, w", "fence"))
    v.append(e("fence.tso", 0, "fence.tso", "fence.tso"))
    v.append(e("ecall", 0, "ecall"))
    v.append(e("ebreak", 0, "ebreak"))
    return v


def randoms(rng, per):
    v = []
    r = lambda: rng.randrange(32)
    imm12 = lambda: rng.randrange(-2048, 2048)
    for _ in range(per):
        u = rng.randrange(1 << 20)
        v.append(e("lui", u, f"lui x{r()}, {u:#x}"))
        u = rng.randrange(1 << 20)
        v.append(e("auipc", u, f"auipc x{r()}, {u:#x}"))
        n = 2 * rng.randrange(-(1 << 19), 1 << 19)
        v.append(e("jal", n, f"jal x{r()}, {off(n)}"))
        i = imm12()
        v.append(e("jalr", i, f"jalr x{r()}, {i}(x{r()})"))
        for b in BRANCH:
            n = 2 * rng.randrange(-2048, 2048)
            v.append(e(b, n, f"{b} x{r()}, x{r()}, {off(n)}"))
        for ld in LOADS:
            i = imm12()
            v.append(e(ld, i, f"{ld} x{r()}, {i}(x{r()})"))
        for st in STORES:
            i = imm12()
            v.append(e(st, i, f"{st} x{r()}, {i}(x{r()})"))
        for op in I_ALU:
            i = imm12()
            v.append(e(op, i, f"{op} x{r()}, x{r()}, {i}"))
        for op in SHIFT_I:
            s = rng.randrange(32)
            v.append(e(op, s, f"{op} x{r()}, x{r()}, {s}"))
        for op in R_ALU:
            v.append(e(op, 0, f"{op} x{r()}, x{r()}, x{r()}"))
        sets = ["i", "o", "r", "w", "rw", "iorw", "io", "ow"]
        txt = f"fence {rng.choice(sets)}, {rng.choice(sets)}"
        v.append(e("fence", 0, txt, "fence"))
    return v


# Words from outside RV32I. maindec only sees the opcode, so the ones that
# share an RV32I opcode decode as that opcode (contract gap, see TB NOTEs);
# the others must give illegal = 1.
def foreign():
    return [
        ("rv32i_zihintpause", "ilp32", [e("pause", 0, "pause", "pause")]),
        ("rv32im", "ilp32", [
            e("mul", 0, "mul x3, x1, x2"), e("mulh", 0, "mulh x3, x1, x2"),
            e("div", 0, "div x3, x1, x2"), e("remu", 0, "remu x3, x1, x2")]),
        ("rv32i_zicsr", "ilp32", [
            e("csrrw", 0, "csrrw x1, mscratch, x2"), e("csrrs", 0, "csrrs x1, mstatus, x0"),
            e("csrrwi", 0, "csrrwi x1, mscratch, 5")]),
        ("rv32i_zifencei", "ilp32", [e("fence.i", 0, "fence.i")]),
        ("rv32ia", "ilp32", [
            e("lr.w", 0, "lr.w x1, (x2)"), e("amoadd.w", 0, "amoadd.w x1, x2, (x3)")]),
        ("rv32if", "ilp32", [
            e("flw", 0, "flw f1, 0(x2)"), e("fsw", 0, "fsw f1, 0(x2)"),
            e("fadd.s", 0, "fadd.s f1, f2, f3"), e("fmadd.s", 0, "fmadd.s f1, f2, f3, f4")]),
        ("rv64i", "lp64", [
            e("addiw", 0, "addiw x1, x2, 1"), e("addw", 0, "addw x1, x2, x3"),
            e("ld", 0, "ld x1, 0(x2)"), e("sd", 0, "sd x1, 0(x2)"),
            e("lwu", 0, "lwu x1, 0(x2)")]),
        ("rv32i", "ilp32", [
            e("custom0", 0, ".insn r CUSTOM_0, 0, 0, x1, x2, x3", None),
            e("word0", 0, ".word 0x00000000", None),
            e("wordF", 0, ".word 0xffffffff", None)]),
    ]


# ------------------------------------------------------------- assembling
def assemble(entries, march, mabi, tag, outdir):
    src = os.path.join(outdir, f"{tag}.s")
    obj = os.path.join(outdir, f"{tag}.o")
    binf = os.path.join(outdir, f"{tag}.bin")
    with open(src, "w") as f:
        f.write("\t.text\n")
        for _, _, text, _ in entries:
            f.write(f"\t{text}\n")
    run([RV + "as", f"-march={march}", f"-mabi={mabi}", "-mno-relax", "-o", obj, src])
    if "R_RISCV" in run([RV + "objdump", "-r", obj]):
        # binutils 2.42 leaves `.+N` targets for the linker; 2.45 resolves them in as.
        # Linking resolves every PC-relative offset; the load address does not matter.
        obj = rvtools.link_resolved(RV, obj, os.path.join(outdir, f"{tag}.elf"), mabi)
    run([RV + "objcopy", "-O", "binary", "-j", ".text", obj, binf])
    data = open(binf, "rb").read()
    words = [int.from_bytes(data[i:i + 4], "little") for i in range(0, len(data), 4)]
    if len(data) % 4 or len(words) != len(entries):
        sys.exit(f"{tag}: {len(entries)} source lines but {len(data)} bytes of code")
    relocs = run([RV + "objdump", "-r", obj])
    if "R_RISCV" in relocs:
        sys.exit(f"{tag}: relocations left in the object, offsets not encoded:\n{relocs}")
    # disassemble and compare word + mnemonic line by line
    dis = []
    for line in run([RV + "objdump", "-d", "-M", "numeric,no-aliases", obj]).splitlines():
        m = re.match(r"^\s*[0-9a-f]+:\s+([0-9a-f]{8})\s+(\S+)", line)
        if m:
            dis.append((int(m.group(1), 16), m.group(2)))
    if len(dis) != len(words):
        sys.exit(f"{tag}: objdump shows {len(dis)} instructions, expected {len(words)}")
    for (mn, _, text, tok), w, (dw, dmn) in zip(entries, words, dis):
        if dw != w:
            sys.exit(f"{tag}: objdump word {dw:08x} != objcopy word {w:08x} for '{text}'")
        if tok is not None and dmn != tok:
            sys.exit(f"{tag}: '{text}' disassembles as '{dmn}', expected '{tok}'")
    return words


def provenance():
    """Re-assemble the words tb/aludec_tb.sv says came from GNU as."""
    path = os.path.join(G, "tb/aludec_tb.sv")
    pairs = re.findall(r'check_instr\(32\'h([0-9a-fA-F]{8}),\s*"([^"]+)"\)', open(path).read())
    pairs = [(int(h, 16), t) for h, t in pairs if t != "random"]
    outdir = os.path.join(G, "build/decoder_adv")
    ents = [e("x", 0, t.replace("  ", " "), None) for _, t in pairs]
    words = assemble(ents, "rv32i", "ilp32", "provenance", outdir)
    bad = [(t, h, w) for (h, t), w in zip(pairs, words) if h != w]
    for t, h, w in bad:
        print(f"PROVENANCE MISMATCH aludec_tb '{t}': file {h:08x}, GNU as {w:08x}")
    print(f"provenance: {len(pairs) - len(bad)}/{len(pairs)} hard-coded aludec_tb words match GNU as")
    return not bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--per", type=int, default=20)
    ap.add_argument("--out", default="build/decoder_adv")
    a = ap.parse_args()
    if RV is None:
        sys.exit("decoder_adv_gen: " + rvtools.INSTALL_HINT)
    os.chdir(G)
    os.makedirs(a.out, exist_ok=True)
    rng = random.Random(a.seed)

    groups = [("rv32i", "ilp32", "rv32i_directed", directed()),
              ("rv32i", "ilp32", "rv32i_random", randoms(rng, a.per))]
    for k, (march, mabi, ents) in enumerate(foreign()):
        groups.append((march, mabi, f"foreign{k}_{march}", ents))

    rows = []
    for march, mabi, tag, ents in groups:
        words = assemble(ents, march, mabi, tag, a.out)
        for (mn, imm, text, _), w in zip(ents, words):
            rows.append((mn, imm, w, text, march))

    with open(os.path.join(a.out, "vectors.hex"), "w") as fh, \
         open(os.path.join(a.out, "vectors.lst"), "w") as fl:
        for i, (mn, imm, w, text, march) in enumerate(rows):
            fh.write(mn.encode().rjust(16, b"\0").hex() + f"{imm & 0xffffffff:08x}{w:08x}\n")
            fl.write(f"{i:5d}  {w:08x}  {mn:10s} imm={imm:<9d} {march:18s} {text}\n")
    with open(os.path.join(a.out, "vectors_count.txt"), "w") as f:
        f.write(f"{len(rows)}\n")
    mnems = sorted({r[0] for r in rows})
    print(f"decoder_adv_gen: seed={a.seed} per={a.per}: {len(rows)} words from GNU as, "
          f"{len(mnems)} mnemonics, all checked against objdump")
    ok = provenance()
    sys.exit(0 if ok else 5)


if __name__ == "__main__":
    main()
