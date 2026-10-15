#!/usr/bin/env python3
"""iss_adv_test.py: adversarial tests for tools/iss.py, the golden model.

    usage: python3 tools/iss_adv_test.py [--seed N | +seed=N] [--n N]
                                         [--iss PATH] [--log FILE] [--require-as]

tools/iss.py decides what the "right" trace is for every RTL run, so a bug in
it would hide the same bug in the CPU. This file attacks it four ways:

  1. ENCODINGS. Instruction words are built by the enc_* helpers below, written
     from the field pictures in spec section 2.2-2.3 (pp.25-27) and the RV32I listing
     (ch.36, pp.585-586). The GNU assembler is a second, independent
     encoder: every instruction used here is also assembled, and the words
     must agree. If no RISC-V binutils are found (tools/rvtools.py) the
     summary says this check was skipped; with --require-as (as
     tools/run_iss_adv.sh runs it) that is an error instead.
  2. DIRECTED cases with hand-computed expected values. The expected trace
     text is written out literally (" x03=ffffffff"), worked out from the spec
     text, not from iss.py. They target what the official rv32ui tests miss or
     barely touch: shift amounts with rs2[5] set, SRA/SRAI of negative values,
     SLTIU with a sign-extended immediate, JAL imm bit 11, JALR clearing bit 0
     with rd == rs1, LB/LH sign extension, AUIPC with a negative immediate,
     negative branch offsets, every store width at every legal offset, x0.
  3. RANDOM cases (seeded): one random instruction on a random machine,
     checked against ref_step() below. ref_step never decodes instruction
     bits: it gets the mnemonic and operands the generator chose, and uses
     different arithmetic tricks from iss.py (bias for signed compares, a fill
     mask for arithmetic shifts, byte lists for memory).
  4. COMMAND LINE: whole programs through `python3 iss.py`, checking stdout,
     the exit code and the trace file byte for byte (docs/DESIGN.md "Trace format").

Every check also makes sure nothing else changed: all 32 registers and all
64 KiB of data memory are compared, and a legal instruction must not warn.

Prints exactly one summary line starting PASS or FAIL. Exit code 0 only on PASS.
"""
import argparse
import contextlib
import importlib.util
import io
import os
import random
import re
import shutil
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCRATCH = os.path.join(ROOT, "build", "iss_adv")
sys.path.insert(0, HERE)
import rvtools  # noqa: E402  (finds the RISC-V binutils, like tools/common.sh)

RV = rvtools.find_prefix()   # e.g. "riscv64-unknown-elf-", or None
M32 = 0xFFFFFFFF

# ---------------------------------------------------------------- encoder
# Field positions: spec section 2.2 p.25 (R/I/S/U) and section 2.3 p.26 (B/J).
# Opcode / funct3 / funct7 values: spec ch.36 RV32I listing, pp.585-586.
OPC = {"lui": 0b0110111, "auipc": 0b0010111, "jal": 0b1101111, "jalr": 0b1100111,
       "branch": 0b1100011, "load": 0b0000011, "store": 0b0100011,
       "opimm": 0b0010011, "op": 0b0110011, "fence": 0b0001111, "system": 0b1110011}
F3 = {"add": 0, "sub": 0, "sll": 1, "slt": 2, "sltu": 3, "xor": 4, "srl": 5, "sra": 5,
      "or": 6, "and": 7,
      "addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7,
      "slli": 1, "srli": 5, "srai": 5,
      "lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5, "sb": 0, "sh": 1, "sw": 2,
      "beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7, "jalr": 0}
F7_SUB_SRA = 0b0100000            # funct7 of SUB, SRA, SRAI; every other one is 0

R_OPS = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
I_OPS = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SH_OPS = ["slli", "srli", "srai"]
LOADS = {"lb": (1, True), "lh": (2, True), "lw": (4, False), "lbu": (1, False), "lhu": (2, False)}
STORES = {"sb": 1, "sh": 2, "sw": 4}
BRANCHES = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]


class Ins:
    """One instruction: its 32-bit word, assembler text, and the operands
    (kept so ref_step can run it without decoding the word)."""
    def __init__(self, word, asm, name, rd=0, rs1=0, rs2=0, imm=0):
        self.word, self.asm, self.name = word, asm, name
        self.rd, self.rs1, self.rs2, self.imm = rd, rs1, rs2, imm


def enc_r(name, rd, rs1, rs2):
    f7 = F7_SUB_SRA if name in ("sub", "sra") else 0
    w = (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (F3[name] << 12) | (rd << 7) | OPC["op"]
    return Ins(w, f"{name} x{rd}, x{rs1}, x{rs2}", name, rd, rs1, rs2)


def enc_i(name, rd, rs1, imm):                    # ADDI .. ANDI, imm in -2048..2047
    w = ((imm & 0xFFF) << 20) | (rs1 << 15) | (F3[name] << 12) | (rd << 7) | OPC["opimm"]
    return Ins(w, f"{name} x{rd}, x{rs1}, {imm}", name, rd, rs1, 0, imm)


def enc_sh(name, rd, rs1, shamt):                 # SLLI/SRLI/SRAI: imm[11:5] = funct7
    f7 = F7_SUB_SRA if name == "srai" else 0
    w = (f7 << 25) | (shamt << 20) | (rs1 << 15) | (F3[name] << 12) | (rd << 7) | OPC["opimm"]
    return Ins(w, f"{name} x{rd}, x{rs1}, {shamt}", name, rd, rs1, 0, shamt)


def enc_load(name, rd, rs1, imm):
    w = ((imm & 0xFFF) << 20) | (rs1 << 15) | (F3[name] << 12) | (rd << 7) | OPC["load"]
    return Ins(w, f"{name} x{rd}, {imm}(x{rs1})", name, rd, rs1, 0, imm)


def enc_store(name, rs2, rs1, imm):               # S-type: imm[11:5] at 31:25, imm[4:0] at 11:7
    u = imm & 0xFFF
    w = ((u >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (F3[name] << 12) \
        | ((u & 0x1F) << 7) | OPC["store"]
    return Ins(w, f"{name} x{rs2}, {imm}(x{rs1})", name, 0, rs1, rs2, imm)


def enc_branch(name, rs1, rs2, off):              # B-type: [12|10:5] at 31:25, [4:1|11] at 11:7
    u = off & 0x1FFF
    w = (((u >> 12) & 1) << 31) | (((u >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) \
        | (F3[name] << 12) | (((u >> 1) & 0xF) << 8) | (((u >> 11) & 1) << 7) | OPC["branch"]
    sign = "+" if off >= 0 else "-"
    return Ins(w, f"{name} x{rs1}, x{rs2}, . {sign} {abs(off)}", name, 0, rs1, rs2, off)


def enc_u(name, rd, imm20):                       # LUI / AUIPC: imm[31:12] at 31:12
    w = ((imm20 & 0xFFFFF) << 12) | (rd << 7) | OPC[name]
    return Ins(w, f"{name} x{rd}, {imm20:#x}", name, rd, 0, 0, imm20)


def enc_jal(rd, off):                             # J-type: [20|10:1|11|19:12] at 31:12
    u = off & 0x1FFFFF
    w = (((u >> 20) & 1) << 31) | (((u >> 1) & 0x3FF) << 21) | (((u >> 11) & 1) << 20) \
        | (((u >> 12) & 0xFF) << 12) | (rd << 7) | OPC["jal"]
    sign = "+" if off >= 0 else "-"
    return Ins(w, f"jal x{rd}, . {sign} {abs(off)}", "jal", rd, 0, 0, off)


def enc_jalr(rd, rs1, imm):
    w = ((imm & 0xFFF) << 20) | (rs1 << 15) | (F3["jalr"] << 12) | (rd << 7) | OPC["jalr"]
    return Ins(w, f"jalr x{rd}, {imm}(x{rs1})", "jalr", rd, rs1, 0, imm)


def enc_fence(pred, succ):                        # FENCE: fm=0, rs1=0, rd=0 (ch.36)
    letters = lambda b: "".join(c for c, bit in zip("iorw", (8, 4, 2, 1)) if b & bit)
    w = (pred << 24) | (succ << 20) | OPC["fence"]
    return Ins(w, f"fence {letters(pred)}, {letters(succ)}", "fence")


ECALL = Ins(0x00000073, "ecall", "ecall")         # ch.36: imm=0, SYSTEM
EBREAK = Ins(0x00100073, "ebreak", "ebreak")      # ch.36: imm=1, SYSTEM


# ---------------------------------------------------------------- reference model
# Written from spec section 2.4-2.6 for this test. It never looks at instruction bits.

def u32(v):
    return v % (1 << 32)            # Python's % is never negative: wraps like 32-bit hardware


def lt_signed(a, b):
    # Flip the sign bits: then an unsigned compare orders two's-complement numbers.
    return (a ^ 0x80000000) < (b ^ 0x80000000)


def sra_ref(a, s):
    fill = M32 ^ (M32 >> s)         # the s top bits that an arithmetic shift fills
    return (a >> s) | fill if a & 0x80000000 else a >> s


def ref_step(ins, pc, x, mem):
    """Run ins at pc on registers x (list of 32) and data memory mem (bytearray,
    64 KiB). Returns ("stop", None) for a misaligned access or jump target,
    else ("ok", (trace line, next pc)). x and mem are updated in place."""
    n, rd = ins.name, ins.rd
    a, b, imm = x[ins.rs1], x[ins.rs2], ins.imm
    wr = None                       # value for rd
    st = ""                         # store part of the trace line
    nxt = u32(pc + 4)

    if n in R_OPS:
        s = b & 31                  # section 2.4.2: low 5 bits of rs2
        wr = {"add": a + b, "sub": a - b, "sll": a << s, "slt": int(lt_signed(a, b)),
              "sltu": int(a < b), "xor": a ^ b, "srl": a >> s, "sra": sra_ref(a, s),
              "or": a | b, "and": a & b}[n]
    elif n in I_OPS:
        iv = u32(imm)               # section 2.4.1: sign-extended to 32 bits
        wr = {"addi": a + iv, "slti": int(lt_signed(a, iv)), "sltiu": int(a < iv),
              "xori": a ^ iv, "ori": a | iv, "andi": a & iv}[n]
    elif n in SH_OPS:
        wr = {"slli": a << imm, "srli": a >> imm, "srai": sra_ref(a, imm)}[n]
    elif n == "lui":
        wr = imm << 12
    elif n == "auipc":
        wr = pc + (imm << 12)
    elif n == "jal":
        nxt = u32(pc + imm)
        if nxt % 4:
            return "stop", None
        wr = pc + 4
    elif n == "jalr":
        nxt = u32(a + imm) & ~1 & M32
        if nxt % 4:
            return "stop", None
        wr = pc + 4
    elif n in BRANCHES:
        sa, sb = a ^ 0x80000000, b ^ 0x80000000
        taken = {"beq": a == b, "bne": a != b, "blt": sa < sb, "bge": sa >= sb,
                 "bltu": a < b, "bgeu": a >= b}[n]
        if taken:
            nxt = u32(pc + imm)
            if nxt % 4:
                return "stop", None
    elif n in LOADS:
        size, sgn = LOADS[n]
        addr = u32(a + imm)
        if addr % size:
            return "stop", None
        at = addr & 0xFFFF          # 64 KiB memory: address bits [15:0]
        v = 0
        for i in range(size):       # little-endian: lowest address = least significant
            v |= mem[at + i] << (8 * i)
        if sgn and v >> (8 * size - 1):
            v -= 1 << (8 * size)
        wr = v
    elif n in STORES:
        size = STORES[n]
        addr = u32(a + imm)
        if addr % size:
            return "stop", None
        at = addr & 0xFFFF
        lane = addr % 4
        be, lane_data = 0, 0
        for i in range(size):
            byte = (b >> (8 * i)) & 0xFF
            mem[at + i] = byte
            be |= 1 << (lane + i)
            lane_data |= byte << (8 * (lane + i))
        st = f" m[{addr - lane:08x}]&{be:x}={lane_data:08x}"
    # fence / ecall / ebreak: nothing

    line = f"{pc:08x} {ins.word:08x}"
    if wr is not None and rd != 0:
        x[rd] = u32(wr)
        line += f" x{rd:02d}={x[rd]:08x}"
    return "ok", (line + st, nxt)


# ---------------------------------------------------------------- harness

class Checker:
    def __init__(self, iss, log):
        self.iss, self.log = iss, log
        self.checks = self.errors = 0
        self.counts = {}
        self.asm = []               # every Ins used, for the GNU as cross-check

    def say(self, text):
        print(text)
        if self.log:
            self.log.write(text + "\n")

    def eq(self, group, what, got, exp):
        self.checks += 1
        self.counts[group] = self.counts.get(group, 0) + 1
        if got != exp:
            self.errors += 1
            if self.errors <= 40:
                self.say(f"  MISMATCH [{group}] {what}\n      got      {got!r}\n      expected {exp!r}")
            return False
        return True


def image(pc, ins_word, mem_words):
    """Word list for RV32I(): mem_words {byte addr: word} plus the instruction at pc."""
    put = dict(((a & 0xFFFF) >> 2, w) for a, w in mem_words.items())
    put[(pc & 0xFFFF) >> 2] = ins_word
    words = [0] * (max(put) + 1)
    for i, w in put.items():
        words[i] = w
    return words


def mem_bytes(words):
    b = bytearray(64 * 1024)
    b[:4 * len(words)] = struct.pack(f"<{len(words)}I", *words)
    return b


def first_diff(a, b):
    for i in range(len(a)):
        if a[i] != b[i]:
            return f"byte {i:04x}: {a[i]:02x} (expected {b[i]:02x})"
    return "none"


def run_one(chk, group, label, ins, pc=0x100, regs=None, mem=None, exp=None,
            next_pc=None, mem_after=None, stop=None, warn=None, words=None):
    """Run one instruction on a fresh ISS and compare everything with what is expected.

    regs      {reg: value} before (all others 0)
    mem       {byte addr: word} before (all other memory 0)
    exp       trace text after "<pc> <instr>", e.g. " x03=ffffffff" (literal)
    next_pc   pc after the instruction
    mem_after {byte addr: word} words that must have changed
    stop      text the SimStop message must contain (then nothing may change)
    warn      text the stderr warning must contain (None: no warning allowed)
    """
    regs, mem, mem_after = regs or {}, mem or {}, mem_after or {}
    words = words if words is not None else image(pc, ins.word, mem)
    cpu = chk.iss.RV32I(words)
    for r, v in regs.items():
        cpu.x[r] = v
    cpu.pc = pc
    x_exp = [0] * 32
    for r, v in regs.items():
        x_exp[r] = v
    mem_exp = mem_bytes(words)
    chk.asm.append(ins)

    err = io.StringIO()
    line, stopped = None, None
    with contextlib.redirect_stderr(err):
        try:
            line, _ = cpu.step()
        except chk.iss.SimStop as e:
            stopped = str(e)
    tag = f"{label}: {ins.asm} @ {pc:08x}"

    if stop is not None:
        chk.eq(group, tag + " stops", stopped is not None and stop in stopped, True)
        chk.eq(group, tag + " pc unchanged after stop", cpu.pc, pc)
    else:
        chk.eq(group, tag + " no stop", stopped, None)
        chk.eq(group, tag + " trace line", line, f"{pc:08x} {ins.word:08x}{exp}")
        chk.eq(group, tag + " next pc", cpu.pc, next_pc)
        # register changes come from the literal expected text itself
        for m in re.finditer(r"x(\d\d)=([0-9a-f]{8})", exp):
            x_exp[int(m.group(1))] = int(m.group(2), 16)
        for a, w in mem_after.items():
            mem_exp[a & 0xFFFF:(a & 0xFFFF) + 4] = w.to_bytes(4, "little")
    chk.eq(group, tag + " registers", list(cpu.x), x_exp)
    chk.eq(group, tag + " data memory", first_diff(cpu.mem, mem_exp), "none")
    w = err.getvalue()
    if warn is None:
        chk.eq(group, tag + " no warning", w, "")
    else:
        chk.eq(group, tag + " warning", warn in w, True)


# ---------------------------------------------------------------- directed cases

def directed(chk):
    D = "directed"
    one = lambda *a, **k: run_one(chk, D, *a, **k)

    # --- shifts, spec section 2.4.1 p.28 (shamt = imm[4:0], type in bit 30) and
    #     section 2.4.2 p.29 (register shifts use the low 5 bits of rs2)
    one("SRAI by 31 of 0x80000000", enc_sh("srai", 3, 1, 31), regs={1: 0x80000000}, exp=" x03=ffffffff", next_pc=0x104)
    one("SRAI by 31 of 0x80000001", enc_sh("srai", 3, 1, 31), regs={1: 0x80000001}, exp=" x03=ffffffff", next_pc=0x104)
    one("SRAI by 31 of 0x7fffffff", enc_sh("srai", 3, 1, 31), regs={1: 0x7FFFFFFF}, exp=" x03=00000000", next_pc=0x104)
    one("SRAI by 0", enc_sh("srai", 3, 1, 0), regs={1: 0x80000000}, exp=" x03=80000000", next_pc=0x104)
    one("SRAI by 4", enc_sh("srai", 3, 1, 4), regs={1: 0xF0000000}, exp=" x03=ff000000", next_pc=0x104)
    one("SRAI by 1", enc_sh("srai", 3, 1, 1), regs={1: 0x80000000}, exp=" x03=c0000000", next_pc=0x104)
    one("SRA by 31", enc_r("sra", 3, 1, 2), regs={1: 0x80000000, 2: 31}, exp=" x03=ffffffff", next_pc=0x104)
    one("SRA rs2=ffffffff -> 31", enc_r("sra", 3, 1, 2), regs={1: 0x80000000, 2: 0xFFFFFFFF}, exp=" x03=ffffffff", next_pc=0x104)
    one("SRA rs2=0x20 -> 0", enc_r("sra", 3, 1, 2), regs={1: 0x80000000, 2: 0x20}, exp=" x03=80000000", next_pc=0x104)
    one("SRA rs2=0x21 -> 1", enc_r("sra", 3, 1, 2), regs={1: 0x80000000, 2: 0x21}, exp=" x03=c0000000", next_pc=0x104)
    # rd==rs1==rs2: shamt = 0xe4 & 31 = 4, so ffffffe4 >> 4 (arithmetic) = fffffffe
    one("SRA rd==rs1==rs2", enc_r("sra", 4, 4, 4), regs={4: 0xFFFFFFE4}, exp=" x04=fffffffe", next_pc=0x104)
    one("SRL by 31", enc_r("srl", 3, 1, 2), regs={1: 0x80000000, 2: 31}, exp=" x03=00000001", next_pc=0x104)
    one("SRL rs2=ffffffe4 -> 4", enc_r("srl", 3, 1, 2), regs={1: 0x12345678, 2: 0xFFFFFFE4}, exp=" x03=01234567", next_pc=0x104)
    one("SRLI by 31", enc_sh("srli", 3, 1, 31), regs={1: 0xFFFFFFFF}, exp=" x03=00000001", next_pc=0x104)
    one("SLL rs2=0x3f -> 31", enc_r("sll", 3, 1, 2), regs={1: 3, 2: 0x3F}, exp=" x03=80000000", next_pc=0x104)
    one("SLL rs2=0x20 -> 0", enc_r("sll", 3, 1, 2), regs={1: 0x12345678, 2: 0x20}, exp=" x03=12345678", next_pc=0x104)
    one("SLLI by 31", enc_sh("slli", 3, 1, 31), regs={1: 3}, exp=" x03=80000000", next_pc=0x104)

    # --- compares, section 2.4.1 p.28 (SLTIU: sign-extend, then compare unsigned) and section 2.4.2 p.29
    one("SLTIU -1, rs1=0", enc_i("sltiu", 3, 1, -1), regs={1: 0}, exp=" x03=00000001", next_pc=0x104)
    one("SLTIU -1, rs1=fffffffe", enc_i("sltiu", 3, 1, -1), regs={1: 0xFFFFFFFE}, exp=" x03=00000001", next_pc=0x104)
    one("SLTIU -1, rs1=ffffffff", enc_i("sltiu", 3, 1, -1), regs={1: 0xFFFFFFFF}, exp=" x03=00000000", next_pc=0x104)
    one("SLTIU 1 (SEQZ), rs1=0", enc_i("sltiu", 3, 1, 1), regs={1: 0}, exp=" x03=00000001", next_pc=0x104)
    one("SLTIU 1 (SEQZ), rs1=1", enc_i("sltiu", 3, 1, 1), regs={1: 1}, exp=" x03=00000000", next_pc=0x104)
    one("SLTIU -2048, rs1=fffff7ff", enc_i("sltiu", 3, 1, -2048), regs={1: 0xFFFFF7FF}, exp=" x03=00000001", next_pc=0x104)
    one("SLTIU -2048, rs1=fffff800", enc_i("sltiu", 3, 1, -2048), regs={1: 0xFFFFF800}, exp=" x03=00000000", next_pc=0x104)
    one("SLTI 0, rs1=-1", enc_i("slti", 3, 1, 0), regs={1: 0xFFFFFFFF}, exp=" x03=00000001", next_pc=0x104)
    one("SLTI -1, rs1=7fffffff", enc_i("slti", 3, 1, -1), regs={1: 0x7FFFFFFF}, exp=" x03=00000000", next_pc=0x104)
    one("SLTI -2048, rs1=80000000", enc_i("slti", 3, 1, -2048), regs={1: 0x80000000}, exp=" x03=00000001", next_pc=0x104)
    one("SLT 80000000 < 1", enc_r("slt", 3, 1, 2), regs={1: 0x80000000, 2: 1}, exp=" x03=00000001", next_pc=0x104)
    one("SLTU 80000000 < 1", enc_r("sltu", 3, 1, 2), regs={1: 0x80000000, 2: 1}, exp=" x03=00000000", next_pc=0x104)
    one("SLTU x0 < 5 (SNEZ)", enc_r("sltu", 3, 0, 2), regs={2: 5}, exp=" x03=00000001", next_pc=0x104)

    # --- logic and add with sign-extended immediates, wrap-around (section 2.4.1, section 2.4.2)
    one("XORI -1 (NOT)", enc_i("xori", 3, 1, -1), regs={1: 0x0F0F0F0F}, exp=" x03=f0f0f0f0", next_pc=0x104)
    one("ANDI -2048", enc_i("andi", 3, 1, -2048), regs={1: 0x12345FFF}, exp=" x03=12345800", next_pc=0x104)
    one("ORI -2048", enc_i("ori", 3, 1, -2048), regs={1: 0}, exp=" x03=fffff800", next_pc=0x104)
    one("ANDI 2047", enc_i("andi", 3, 1, 2047), regs={1: 0xFFFFFFFF}, exp=" x03=000007ff", next_pc=0x104)
    one("ADD overflow", enc_r("add", 3, 1, 2), regs={1: 0x7FFFFFFF, 2: 1}, exp=" x03=80000000", next_pc=0x104)
    one("SUB 0-1", enc_r("sub", 3, 1, 2), regs={2: 1}, exp=" x03=ffffffff", next_pc=0x104)
    one("SUB 80000000-1", enc_r("sub", 3, 1, 2), regs={1: 0x80000000, 2: 1}, exp=" x03=7fffffff", next_pc=0x104)
    one("ADDI -1 from 0", enc_i("addi", 3, 1, -1), regs={1: 0}, exp=" x03=ffffffff", next_pc=0x104)
    one("ADDI +1 wraps", enc_i("addi", 3, 1, 1), regs={1: 0xFFFFFFFF}, exp=" x03=00000000", next_pc=0x104)
    one("ADDI -2048", enc_i("addi", 3, 1, -2048), regs={1: 0x800}, exp=" x03=00000000", next_pc=0x104)

    # --- LUI / AUIPC, section 2.4.1 p.28: low 12 bits zero; AUIPC adds to its own pc
    one("LUI fffff", enc_u("lui", 3, 0xFFFFF), exp=" x03=fffff000", next_pc=0x104)
    one("LUI 12345", enc_u("lui", 3, 0x12345), exp=" x03=12345000", next_pc=0x104)
    one("LUI 00001", enc_u("lui", 3, 0x00001), exp=" x03=00001000", next_pc=0x104)
    one("LUI does not keep rd's old low bits", enc_u("lui", 3, 0x00001), regs={3: 0xFFFFFFFF}, exp=" x03=00001000", next_pc=0x104)
    one("AUIPC negative imm", enc_u("auipc", 3, 0xFFFFF), exp=" x03=fffff100", next_pc=0x104)
    one("AUIPC 80000", enc_u("auipc", 3, 0x80000), exp=" x03=80000100", next_pc=0x104)
    one("AUIPC 0 = own pc", enc_u("auipc", 3, 0), exp=" x03=00000100", next_pc=0x104)
    one("AUIPC x31 at 7ffc", enc_u("auipc", 31, 0x00001), pc=0x7FFC, exp=" x31=00008ffc", next_pc=0x8000)
    one("AUIPC -1 page from 0", enc_u("auipc", 9, 0xFFFFF), pc=0, exp=" x09=fffff000", next_pc=4)

    # --- JAL, section 2.5.1 p.30: target = pc + offset, rd = pc+4
    one("JAL +2048 (imm bit 11)", enc_jal(1, 2048), exp=" x01=00000104", next_pc=0x900)
    one("JAL -2048 (imm bit 11)", enc_jal(1, -2048), pc=0x1000, exp=" x01=00001004", next_pc=0x800)
    one("JAL -4", enc_jal(1, -4), exp=" x01=00000104", next_pc=0xFC)
    one("JAL x0 +8", enc_jal(0, 8), exp="", next_pc=0x108)
    one("JAL +0x7fc", enc_jal(5, 0x7FC), exp=" x05=00000104", next_pc=0x8FC)
    one("JAL +0xff000 (imm[19:12])", enc_jal(1, 0xFF000), exp=" x01=00000104", next_pc=0x000FF100)
    one("JAL -1 MiB", enc_jal(1, -0x100000), exp=" x01=00000104", next_pc=0xFFF00100)
    one("JAL rd==x31", enc_jal(31, 4), exp=" x31=00000104", next_pc=0x104)
    for k in range(2, 20):          # each J-immediate bit alone
        one(f"JAL +2^{k}", enc_jal(1, 1 << k), exp=" x01=00000104", next_pc=0x100 + (1 << k))
    # section 2.5.1 p.31: JAL/JALR target not 4-byte aligned -> misaligned exception (ISS: stop)
    one("JAL +2 misaligned", enc_jal(1, 2), stop="not 4-byte aligned")
    one("JAL +0xffffe misaligned", enc_jal(1, 0xFFFFE), stop="not 4-byte aligned")

    # --- JALR, section 2.5.1 p.30: target = (rs1 + imm) with bit 0 cleared; rd = pc+4
    one("JALR odd sum, rd==rs1", enc_jalr(5, 5, 13), regs={5: 0x200}, exp=" x05=00000104", next_pc=0x20C)
    one("JALR rs1 odd, imm -1", enc_jalr(1, 2, -1), regs={2: 0x301}, exp=" x01=00000104", next_pc=0x300)
    one("JALR rs1 0x2ff, imm 1", enc_jalr(1, 2, 1), regs={2: 0x2FF}, exp=" x01=00000104", next_pc=0x300)
    one("JALR x0 to odd 0x301", enc_jalr(0, 1, 0), regs={1: 0x301}, exp="", next_pc=0x300)
    one("JALR rd==rs1 x1, odd", enc_jalr(1, 1, 1), regs={1: 0x400}, exp=" x01=00000104", next_pc=0x400)
    one("JALR negative imm to 0", enc_jalr(1, 2, -16), regs={2: 0x10}, exp=" x01=00000104", next_pc=0)
    one("JALR imm 2047, rs1 1", enc_jalr(1, 2, 2047), regs={2: 1}, exp=" x01=00000104", next_pc=0x800)
    one("JALR 0(x0)", enc_jalr(1, 0, 0), exp=" x01=00000104", next_pc=0)
    one("JALR bit 1 set -> stop", enc_jalr(1, 2, 0), regs={2: 0x203}, stop="not 4-byte aligned")
    one("JALR -1(x0) -> fffffffe stop", enc_jalr(1, 0, -1), stop="not 4-byte aligned")

    # --- branches, section 2.5.2 pp.31-33; misaligned target only matters if taken (p.33)
    one("BEQ -4 taken", enc_branch("beq", 1, 2, -4), regs={1: 7, 2: 7}, exp="", next_pc=0xFC)
    one("BNE -4096 taken", enc_branch("bne", 1, 2, -4096), pc=0x2000, regs={1: 1, 2: 2}, exp="", next_pc=0x1000)
    one("BLT +4092 taken (-1 < 0)", enc_branch("blt", 1, 2, 4092), regs={1: 0xFFFFFFFF}, exp="", next_pc=0x10FC)
    one("BLTU +4092 not taken", enc_branch("bltu", 1, 2, 4092), regs={1: 0xFFFFFFFF}, exp="", next_pc=0x104)
    one("BGE -8 taken (0 >= -1)", enc_branch("bge", 1, 2, -8), regs={2: 0xFFFFFFFF}, exp="", next_pc=0xF8)
    one("BGEU -8 not taken", enc_branch("bgeu", 1, 2, -8), regs={2: 0xFFFFFFFF}, exp="", next_pc=0x104)
    one("BGE +2048 (imm bit 11)", enc_branch("bge", 1, 2, 2048), regs={1: 5, 2: 5}, exp="", next_pc=0x900)
    one("BLT -2048 (imm bit 11)", enc_branch("blt", 1, 2, -2048), pc=0x1000, regs={1: 0x80000000, 2: 0x7FFFFFFF}, exp="", next_pc=0x800)
    one("BLTU 7fffffff < 80000000", enc_branch("bltu", 1, 2, 8), regs={1: 0x7FFFFFFF, 2: 0x80000000}, exp="", next_pc=0x108)
    one("BGEU 80000000 >= 7fffffff", enc_branch("bgeu", 1, 2, 8), regs={1: 0x80000000, 2: 0x7FFFFFFF}, exp="", next_pc=0x108)
    one("BNE x1,x1 never taken", enc_branch("bne", 1, 1, 8), regs={1: 3}, exp="", next_pc=0x104)
    one("BEQ +2 not taken: no stop", enc_branch("beq", 1, 2, 2), regs={1: 1}, exp="", next_pc=0x104)
    one("BEQ +2 taken -> stop", enc_branch("beq", 1, 2, 2), regs={1: 1, 2: 1}, stop="not 4-byte aligned")

    # --- loads, section 2.6 pp.33-34: LB/LH sign-extend, LBU/LHU zero-extend, little-endian.
    # Memory: 0x8000 = 7f80ff01 (bytes 01 ff 80 7f), 0x8004 = 80007fff (bytes ff 7f 00 80)
    dm = {0x8000: 0x7F80FF01, 0x8004: 0x80007FFF}
    r1 = {1: 0x8000}
    one("LB +0", enc_load("lb", 3, 1, 0), regs=r1, mem=dm, exp=" x03=00000001", next_pc=0x104)
    one("LB +1 (ff)", enc_load("lb", 3, 1, 1), regs=r1, mem=dm, exp=" x03=ffffffff", next_pc=0x104)
    one("LB +2 (80)", enc_load("lb", 3, 1, 2), regs=r1, mem=dm, exp=" x03=ffffff80", next_pc=0x104)
    one("LB +3 (7f)", enc_load("lb", 3, 1, 3), regs=r1, mem=dm, exp=" x03=0000007f", next_pc=0x104)
    one("LBU +1 (ff)", enc_load("lbu", 3, 1, 1), regs=r1, mem=dm, exp=" x03=000000ff", next_pc=0x104)
    one("LBU +2 (80)", enc_load("lbu", 3, 1, 2), regs=r1, mem=dm, exp=" x03=00000080", next_pc=0x104)
    one("LH +4 (7fff)", enc_load("lh", 3, 1, 4), regs=r1, mem=dm, exp=" x03=00007fff", next_pc=0x104)
    one("LH +6 (8000)", enc_load("lh", 3, 1, 6), regs=r1, mem=dm, exp=" x03=ffff8000", next_pc=0x104)
    one("LHU +6 (8000)", enc_load("lhu", 3, 1, 6), regs=r1, mem=dm, exp=" x03=00008000", next_pc=0x104)
    one("LHU +0 (ff01)", enc_load("lhu", 3, 1, 0), regs=r1, mem=dm, exp=" x03=0000ff01", next_pc=0x104)
    one("LH +0 (ff01)", enc_load("lh", 3, 1, 0), regs=r1, mem=dm, exp=" x03=ffffff01", next_pc=0x104)
    one("LH +2 (7f80)", enc_load("lh", 3, 1, 2), regs=r1, mem=dm, exp=" x03=00007f80", next_pc=0x104)
    one("LW +4", enc_load("lw", 3, 1, 4), regs=r1, mem=dm, exp=" x03=80007fff", next_pc=0x104)
    one("LB negative offset", enc_load("lb", 3, 2, -16), regs={2: 0x8012}, mem=dm, exp=" x03=ffffff80", next_pc=0x104)
    one("LW rd==rs1", enc_load("lw", 1, 1, 4), regs=r1, mem=dm, exp=" x01=80007fff", next_pc=0x104)
    one("LW rd=x0: no write", enc_load("lw", 0, 1, 4), regs=r1, mem=dm, exp="", next_pc=0x104)
    one("LB rd=x0: no write", enc_load("lb", 0, 1, 1), regs=r1, mem=dm, exp="", next_pc=0x104)
    one("LW 0x10008004 aliases 0x8004", enc_load("lw", 3, 1, 0), regs={1: 0x10008004}, mem=dm, exp=" x03=80007fff", next_pc=0x104)
    one("LH +1 misaligned -> stop", enc_load("lh", 3, 1, 1), regs=r1, mem=dm, stop="misaligned load")
    one("LW +2 misaligned -> stop", enc_load("lw", 3, 1, 2), regs=r1, mem=dm, stop="misaligned load")
    one("LHU +3 misaligned -> stop", enc_load("lhu", 3, 1, 3), regs=r1, mem=dm, stop="misaligned load")
    one("LW x0 misaligned still stops", enc_load("lw", 0, 1, 1), regs=r1, mem=dm, stop="misaligned load")

    # --- stores, section 2.6: low bits of rs2, little-endian lanes.
    # docs/DESIGN.md trace: m[<word addr>]&<be>=<lane data>, data zero outside be.
    sm = {0x8000: 0x11223344}
    r12 = {1: 0x8000, 2: 0xA1B2C3D4}
    one("SB +0", enc_store("sb", 2, 1, 0), regs=r12, mem=sm, exp=" m[00008000]&1=000000d4", next_pc=0x104, mem_after={0x8000: 0x112233D4})
    one("SB +1", enc_store("sb", 2, 1, 1), regs=r12, mem=sm, exp=" m[00008000]&2=0000d400", next_pc=0x104, mem_after={0x8000: 0x1122D444})
    one("SB +2", enc_store("sb", 2, 1, 2), regs=r12, mem=sm, exp=" m[00008000]&4=00d40000", next_pc=0x104, mem_after={0x8000: 0x11D43344})
    one("SB +3", enc_store("sb", 2, 1, 3), regs=r12, mem=sm, exp=" m[00008000]&8=d4000000", next_pc=0x104, mem_after={0x8000: 0xD4223344})
    one("SH +0", enc_store("sh", 2, 1, 0), regs=r12, mem=sm, exp=" m[00008000]&3=0000c3d4", next_pc=0x104, mem_after={0x8000: 0x1122C3D4})
    one("SH +2", enc_store("sh", 2, 1, 2), regs=r12, mem=sm, exp=" m[00008000]&c=c3d40000", next_pc=0x104, mem_after={0x8000: 0xC3D43344})
    one("SW +0", enc_store("sw", 2, 1, 0), regs=r12, mem=sm, exp=" m[00008000]&f=a1b2c3d4", next_pc=0x104, mem_after={0x8000: 0xA1B2C3D4})
    one("SB x0 +1 (zero data)", enc_store("sb", 0, 1, 1), regs=r12, mem=sm, exp=" m[00008000]&2=00000000", next_pc=0x104, mem_after={0x8000: 0x11220044})
    one("SW negative offset", enc_store("sw", 2, 3, -4), regs={2: 0xA1B2C3D4, 3: 0x8004}, mem=sm, exp=" m[00008000]&f=a1b2c3d4", next_pc=0x104, mem_after={0x8000: 0xA1B2C3D4})
    one("SB rs2==rs1", enc_store("sb", 1, 1, 3), regs={1: 0x8000}, mem=sm, exp=" m[00008000]&8=00000000", next_pc=0x104, mem_after={0x8000: 0x00223344})
    one("SH rs2==rs1 +2", enc_store("sh", 1, 1, 2), regs={1: 0x80FE}, exp=" m[00008100]&3=000080fe", next_pc=0x104, mem_after={0x8100: 0x000080FE})
    one("SW high address aliases", enc_store("sw", 2, 1, 0), regs={1: 0xABCD8000, 2: 0xA1B2C3D4}, mem=sm, exp=" m[abcd8000]&f=a1b2c3d4", next_pc=0x104, mem_after={0x8000: 0xA1B2C3D4})
    one("SH -2 from 0x8002", enc_store("sh", 2, 1, -2), regs={1: 0x8002, 2: 0xA1B2C3D4}, mem=sm, exp=" m[00008000]&3=0000c3d4", next_pc=0x104, mem_after={0x8000: 0x1122C3D4})
    for off in (1, 3):
        one(f"SH +{off} misaligned -> stop", enc_store("sh", 2, 1, off), regs=r12, mem=sm, stop="misaligned store")
    for off in (1, 2, 3):
        one(f"SW +{off} misaligned -> stop", enc_store("sw", 2, 1, off), regs=r12, mem=sm, stop="misaligned store")

    # --- x0 is hardwired to 0 (section 2.1 p.23): writes are dropped, no x00 in the trace
    one("ADDI x0", enc_i("addi", 0, 0, 5), exp="", next_pc=0x104)
    one("LUI x0", enc_u("lui", 0, 0x12345), exp="", next_pc=0x104)
    one("AUIPC x0", enc_u("auipc", 0, 1), exp="", next_pc=0x104)
    one("ADD x0", enc_r("add", 0, 1, 2), regs={1: 1, 2: 2}, exp="", next_pc=0x104)
    one("SUB x3 = x0 - x0", enc_r("sub", 3, 0, 0), regs={3: 0x55}, exp=" x03=00000000", next_pc=0x104)

    # --- register-number formatting: two decimal digits
    one("rd x9 -> x09", enc_i("addi", 9, 0, 1), exp=" x09=00000001", next_pc=0x104)
    one("rd x10 -> x10", enc_i("addi", 10, 0, 2), exp=" x10=00000002", next_pc=0x104)
    one("rd x31 -> x31", enc_i("addi", 31, 0, -1), exp=" x31=ffffffff", next_pc=0x104)

    # --- FENCE, ECALL, EBREAK: NOPs in this design (FENCE as NOP: ch.2 intro p.23)
    one("FENCE", enc_fence(0xF, 0xF), exp="", next_pc=0x104)
    one("FENCE rw,rw", enc_fence(0x3, 0x3), exp="", next_pc=0x104)
    one("ECALL", ECALL, exp="", next_pc=0x104)
    one("EBREAK", EBREAK, exp="", next_pc=0x104)
    one("canonical NOP", enc_i("addi", 0, 0, 0), exp="", next_pc=0x104)

    # --- pc wrap at the top of the 32-bit space (fetch uses address bits [15:2])
    one("ADDI at pc fffffffc", enc_i("addi", 3, 0, 1), pc=0xFFFFFFFC, exp=" x03=00000001", next_pc=0)

    # --- documented ISS behaviour for encodings that are not RV32I (spec section 2.2 p.25:
    #     UNSPECIFIED; the ISS runs them as NOPs with a warning). Not in random tests.
    raw = lambda w, s: Ins(w, s, "raw")
    one("MUL (M ext) = NOP + warning", raw(0x022081B3, ".word 0x022081b3"), regs={1: 3, 2: 4}, exp="", next_pc=0x104, warn="OP with funct7")
    one("CSRRS = NOP + warning", raw(0xC0002573, ".word 0xc0002573"), exp="", next_pc=0x104, warn="SYSTEM")
    one("unknown opcode = NOP + warning", raw(0x0000007F, ".word 0x0000007f"), exp="", next_pc=0x104, warn="unknown opcode")


# ---------------------------------------------------------------- random cases

SPECIAL = [0x00000000, 0x00000001, 0x00000002, 0x0000001F, 0x00000020, 0x00000021,
           0x0000003F, 0x0000007F, 0x00000080, 0x000000FF, 0x00007FFF, 0x00008000,
           0x0000FFFF, 0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFF8000, 0xFFFFFF80,
           0xFFFFFFFE, 0xFFFFFFFF]
IMM_EDGES = [-2048, -2047, -1024, -2, -1, 0, 1, 2, 31, 32, 1023, 2046, 2047]
ALL_NAMES = R_OPS + I_OPS + SH_OPS + list(LOADS) + list(STORES) + BRANCHES \
    + ["lui", "auipc", "jal", "jalr", "fence", "ecall", "ebreak"]      # 37 + 3


def rand_value(r):
    return r.choice(SPECIAL) if r.random() < 0.4 else r.getrandbits(32)


def rand_imm12(r):
    return r.choice(IMM_EDGES) if r.random() < 0.3 else r.randint(-2048, 2047)


def rand_pc(r):
    p = r.random()
    if p < 0.7:
        return r.randrange(0, 0x8000, 4)
    if p < 0.85:
        return r.getrandbits(32) & ~3
    return r.choice([0, 0x7FFC, 0xFFFC, 0x10000, 0xFFFFFFFC, 0x80000000])


def rand_case(r, base_words):
    """Pick an instruction, a pc and a machine state. Returns (ins, pc, regs, words)."""
    name = r.choice(ALL_NAMES)
    rd, rs1, rs2 = r.randrange(32), r.randrange(32), r.randrange(32)
    regs = {i: rand_value(r) for i in range(1, 32)}
    pc = rand_pc(r)
    words = list(base_words)

    def addr_for(size):
        """A random effective address: mostly aligned, sometimes not, anywhere in 32 bits."""
        if r.random() < 0.7:
            a = 0x8000 + r.randrange(0, 0x8000, size)
        else:
            a = r.getrandbits(32) & ~(size - 1)
        if size > 1 and r.random() < 0.15:
            a = u32(a + r.randrange(1, size))
        return a

    if name in R_OPS:
        ins = enc_r(name, rd, rs1, rs2)
    elif name in I_OPS:
        ins = enc_i(name, rd, rs1, rand_imm12(r))
    elif name in SH_OPS:
        ins = enc_sh(name, rd, rs1, r.choice([0, 1, 30, 31, r.randrange(32)]))
    elif name in ("lui", "auipc"):
        ins = enc_u(name, rd, r.choice([0, 1, 0x7FFFF, 0x80000, 0xFFFFF, r.getrandbits(20)]))
    elif name == "jal":
        off = r.choice([r.randrange(-(1 << 20), 1 << 20, 4), r.randrange(-(1 << 20), 1 << 20, 4),
                        r.randrange(-(1 << 20), 1 << 20, 2), r.choice([-4, 4, 2048, -2048, 0])])
        ins = enc_jal(rd, off)
    elif name == "jalr":
        imm = rand_imm12(r)
        ins = enc_jalr(rd, rs1, imm)
        if rs1 and r.random() < 0.75:        # mostly an aligned target, often with bit 0 set
            regs[rs1] = u32((r.getrandbits(32) & ~3) - imm + r.choice([0, 1]))
    elif name in BRANCHES:
        off = r.randrange(-4096, 4096, 4) if r.random() < 0.85 else r.randrange(-4096, 4096, 2)
        ins = enc_branch(name, rs1, rs2, off)
        if rs1 and rs2 and r.random() < 0.3:  # equal operands sometimes
            regs[rs2] = regs[rs1]
    elif name in LOADS or name in STORES:
        size = LOADS[name][0] if name in LOADS else STORES[name]
        imm = rand_imm12(r)
        addr = addr_for(size)
        if rs1:
            regs[rs1] = u32(addr - imm)
        else:
            addr = u32(imm)                  # base x0: the address is the immediate
        if r.random() < 0.3:                 # sign-bit patterns in the data word
            words[(addr & 0xFFFF) >> 2] = r.choice([0x80808080, 0x7F7F7F7F, 0x80007FFF,
                                                    0x7FFF8000, 0xFFFFFFFF, 0])
        if name in LOADS:
            ins = enc_load(name, rd, rs1, imm)
        else:
            ins = enc_store(name, rs2, rs1, imm)
    elif name == "fence":
        ins = enc_fence(r.randrange(1, 16), r.randrange(1, 16))
    else:
        ins = ECALL if name == "ecall" else EBREAK
    words[(pc & 0xFFFF) >> 2] = ins.word
    return ins, pc, regs, words


def random_tests(chk, seed, n):
    G = "random"
    r = random.Random(seed)
    base = [r.getrandbits(32) for _ in range(16384)]   # random 64 KiB image
    stops = 0
    seen = set()
    for i in range(n):
        ins, pc, regs, words = rand_case(r, base)
        seen.add(ins.name)
        chk.asm.append(ins)
        # the reference, on its own copies
        x_ref = [0] + [regs[k] for k in range(1, 32)]
        mem_ref = mem_bytes(words)
        kind, res = ref_step(ins, pc, x_ref, mem_ref)
        # the ISS
        cpu = chk.iss.RV32I(words)
        for k, v in regs.items():
            cpu.x[k] = v
        cpu.pc = pc
        err = io.StringIO()
        line, stopped = None, False
        with contextlib.redirect_stderr(err):
            try:
                line, _ = cpu.step()
            except chk.iss.SimStop:
                stopped = True
        tag = f"seed {seed} #{i}: {ins.asm} @ {pc:08x}"
        if kind == "stop":
            stops += 1
            chk.eq(G, tag + " stops", stopped, True)
            chk.eq(G, tag + " registers", list(cpu.x), [0] + [regs[k] for k in range(1, 32)])
        else:
            exp_line, exp_pc = res
            if not chk.eq(G, tag + " no stop", stopped, False):
                continue
            chk.eq(G, tag + " trace line", line, exp_line)
            chk.eq(G, tag + " next pc", cpu.pc, exp_pc)
            chk.eq(G, tag + " registers", list(cpu.x), x_ref)
        chk.eq(G, tag + " data memory", first_diff(cpu.mem, mem_ref), "none")
        chk.eq(G, tag + " no warning", err.getvalue(), "")
    missing = [m for m in ALL_NAMES if m not in seen]
    chk.eq(G, "every mnemonic drawn at least once", missing, [])
    return stops


# ---------------------------------------------------------------- command line

def hexfile(path, words):
    with open(path, "w", newline="\n") as f:
        for w in words:
            f.write(f"{w:08x}\n")


def run_cli(chk, iss_path, label, words, exp_stdout, exp_rc, exp_trace, max_steps=None):
    """Run iss.py as a program; compare stdout, exit code and the trace file bytes."""
    G = "cli"
    hx = os.path.join(SCRATCH, f"cli_{label}.hex")
    tr = os.path.join(SCRATCH, f"cli_{label}.trace")
    hexfile(hx, words)
    if os.path.exists(tr):
        os.remove(tr)
    cmd = [sys.executable, iss_path, "--hex", hx, "--trace", tr]
    if max_steps is not None:
        cmd += ["--max-steps", str(max_steps)]
    p = subprocess.run(cmd, capture_output=True, text=True)
    chk.eq(G, f"{label}: stdout", p.stdout, exp_stdout)
    chk.eq(G, f"{label}: exit code", p.returncode, exp_rc)
    with open(tr, "rb") as f:
        got = f.read()
    chk.eq(G, f"{label}: trace file bytes", got, exp_trace.encode("ascii"))


def cli_tests(chk, iss_path):
    os.makedirs(SCRATCH, exist_ok=True)
    W = lambda *ins: [i.word for i in ins]
    # The three example lines of docs/DESIGN.md "Trace format", in a program that ends with PASS.
    prog = [enc_u("lui", 2, 0x8),            # 0x00 x2 = 0x8000
            enc_i("addi", 1, 0, 5),          # 0x04 DESIGN example 1
            enc_i("addi", 0, 0, 0),          # 0x08 nop
            enc_store("sw", 1, 2, 4),        # 0x0c DESIGN example 2
            enc_branch("beq", 1, 2, 8),      # 0x10 DESIGN example 3 (not taken)
            enc_u("lui", 3, 0x10),           # 0x14 x3 = 0x10000
            enc_i("addi", 3, 3, -16),        # 0x18 x3 = 0xfff0 = TOHOST
            enc_i("addi", 4, 0, 1),          # 0x1c
            enc_store("sw", 4, 3, 0)]        # 0x20 TOHOST = 1
    chk.asm.extend(prog)
    # hand-written: words from the spec field layouts, lines from docs/DESIGN.md
    chk.eq("cli", "docs/DESIGN.md example words", W(*prog),
           [0x00008137, 0x00500093, 0x00000013, 0x00112223, 0x00208463,
            0x000101B7, 0xFF018193, 0x00100213, 0x0041A023])
    trace = ("00000000 00008137 x02=00008000\n"
             "00000004 00500093 x01=00000005\n"
             "00000008 00000013\n"
             "0000000c 00112223 m[00008004]&f=00000005\n"
             "00000010 00208463\n"
             "00000014 000101b7 x03=00010000\n"
             "00000018 ff018193 x03=0000fff0\n"
             "0000001c 00100213 x04=00000001\n"
             "00000020 0041a023 m[0000fff0]&f=00000001\n")
    run_cli(chk, iss_path, "design_examples", W(*prog), "TOHOST=00000001\nPASS (9 instructions)\n", 0, trace)

    # Same program, TOHOST = 7: FAIL with test number 7 >> 1 = 3 (riscv-tests convention).
    fail = list(prog)
    fail[7] = enc_i("addi", 4, 0, 7)
    trace7 = trace.replace("0000001c 00100213 x04=00000001", "0000001c 00700213 x04=00000007") \
                  .replace("m[0000fff0]&f=00000001", "m[0000fff0]&f=00000007")
    run_cli(chk, iss_path, "fail_test3", W(*fail), "TOHOST=00000007\nFAIL test 3 (9 instructions)\n", 1, trace7)

    # SB of 1 to TOHOST: lane data 00000001 -> PASS
    sbp = [enc_i("addi", 1, 0, 1), enc_u("lui", 2, 0x10), enc_i("addi", 2, 2, -16), enc_store("sb", 1, 2, 0)]
    chk.asm.extend(sbp)
    run_cli(chk, iss_path, "sb_tohost", W(*sbp), "TOHOST=00000001\nPASS (4 instructions)\n", 0,
            "00000000 00100093 x01=00000001\n"
            "00000004 00010137 x02=00010000\n"
            "00000008 ff010113 x02=0000fff0\n"
            "0000000c 00110023 m[0000fff0]&1=00000001\n")

    # A misaligned load stops the run; the failing instruction is not in the trace.
    mis = [enc_u("lui", 2, 0x8), enc_load("lw", 1, 2, 2)]
    chk.asm.extend(mis)
    run_cli(chk, iss_path, "misaligned_load", W(*mis),
            "FAIL pc=00000004 instr=00212083: misaligned load from 00008002\n", 1,
            "00000000 00008137 x02=00008000\n")

    # A program that never writes TOHOST: FAIL after --max-steps instructions.
    loop = [enc_jal(0, 0)]
    chk.asm.extend(loop)
    run_cli(chk, iss_path, "timeout", W(*loop), "FAIL no store to TOHOST in 50 instructions\n", 1,
            "00000000 0000006f\n" * 50, max_steps=50)

    # Harvard memories (docs/DESIGN.md: imem and dmem load the same image; dmem.sv:
    # "A store changes dmem only; imem keeps the original instructions").
    # The sw overwrites the word at 0x0c in DATA memory; the fetch at 0x0c must
    # still see the original addi x3,x0,5, while a load of 0x0c sees the new word.
    harv = [enc_u("lui", 1, 0x00700),        # 0x00 x1 = 00700000
            enc_i("addi", 1, 1, 0x193),      # 0x04 x1 = 00700193 = addi x3,x0,7
            enc_store("sw", 1, 0, 12),       # 0x08 m[0000000c] = 00700193
            enc_i("addi", 3, 0, 5),          # 0x0c the original instruction
            enc_load("lw", 6, 0, 12),        # 0x10 data side sees the store
            enc_u("lui", 4, 0x10),           # 0x14
            enc_i("addi", 4, 4, -16),        # 0x18
            enc_i("addi", 5, 0, 1),          # 0x1c
            enc_store("sw", 5, 4, 0)]        # 0x20 TOHOST = 1
    chk.asm.extend(harv)
    chk.eq("cli", "harvard: stored word is addi x3,x0,7", enc_i("addi", 3, 0, 7).word, 0x00700193)
    run_cli(chk, iss_path, "harvard", W(*harv), "TOHOST=00000001\nPASS (9 instructions)\n", 0,
            "00000000 007000b7 x01=00700000\n"
            "00000004 19308093 x01=00700193\n"
            "00000008 00102623 m[0000000c]&f=00700193\n"
            "0000000c 00500193 x03=00000005\n"
            "00000010 00c02303 x06=00700193\n"
            "00000014 00010237 x04=00010000\n"
            "00000018 ff020213 x04=0000fff0\n"
            "0000001c 00100293 x05=00000001\n"
            "00000020 00522023 m[0000fff0]&f=00000001\n")


# ---------------------------------------------------------------- GNU as cross-check

def as_check(chk, require):
    """Assemble every instruction used above with GNU as; the words must match enc_*."""
    if RV is None:
        chk.say("  note: GNU as cross-check skipped: " + rvtools.INSTALL_HINT.splitlines()[0])
        if require:
            chk.eq("as", "RISC-V binutils found (--require-as)", False, True)
        return False
    asm_bin = RV + "as"
    todo = [i for i in chk.asm if not i.asm.startswith(".word")]
    src = os.path.join(SCRATCH, "as_check.s")
    obj = os.path.join(SCRATCH, "as_check.o")
    binf = os.path.join(SCRATCH, "as_check.bin")
    with open(src, "w", newline="\n") as f:
        f.write("\t.text\n")
        for i in todo:
            f.write(f"\t{i.asm}\n")
    try:
        subprocess.run([asm_bin, "-march=rv32i", "-mabi=ilp32", "-mno-relax", "-o", obj, src], check=True)
        subprocess.run([RV + "objcopy", "-O", "binary", "-j", ".text", obj, binf], check=True)
    except OSError as e:
        chk.say(f"  note: GNU as cross-check skipped: {asm_bin} does not run here ({e.strerror})")
        if require:
            chk.eq("as", "RISC-V binutils run (--require-as)", False, True)
        return False
    with open(binf, "rb") as f:
        data = f.read()
    got = list(struct.unpack(f"<{len(data) // 4}I", data))
    chk.eq("as", "number of words", len(got), len(todo))
    bad = [(i.asm, f"{g:08x}", f"{i.word:08x}") for i, g in zip(todo, got) if g != i.word]
    chk.eq("as", f"{len(todo)} encodings agree with GNU as (as, ours)", bad[:10], [])
    return True


# ---------------------------------------------------------------- main

def load_iss(path):
    spec = importlib.util.spec_from_file_location("iss_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    argv = [f"--seed={a[6:]}" if a.startswith("+seed=") else a for a in sys.argv[1:]]
    ap = argparse.ArgumentParser(description="adversarial tests for tools/iss.py")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--n", type=int, default=3000, help="random cases")
    ap.add_argument("--iss", default=os.path.join(HERE, "iss.py"), help="ISS file under test")
    ap.add_argument("--log", help="also write the output to this file")
    ap.add_argument("--require-as", action="store_true",
                    help="fail (rather than skip) if the GNU as cross-check cannot run")
    args = ap.parse_args(argv)

    log = open(args.log, "w", newline="\n") if args.log else None
    chk = Checker(load_iss(args.iss), log)
    chk.say(f"# iss_adv_test: iss={os.path.relpath(args.iss, ROOT)} seed={args.seed} "
            f"random={args.n} python={sys.version.split()[0]}")
    directed(chk)
    stops = random_tests(chk, args.seed, args.n)
    cli_tests(chk, args.iss)
    did_as = as_check(chk, args.require_as)
    c = chk.counts
    chk.say(f"# checks: directed {c.get('directed', 0)}, random {c.get('random', 0)} "
            f"({args.n} instructions, {stops} expected stops), cli {c.get('cli', 0)}, "
            f"as {c.get('as', 0)} ({len(chk.asm)} encodings{'' if did_as else ', SKIPPED'})")
    word = "PASS" if chk.errors == 0 else "FAIL"
    chk.say(f"{word} iss_adv_test: {chk.checks} checks, {chk.errors} errors (seed {args.seed})")
    if log:
        log.close()
    return 0 if chk.errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
