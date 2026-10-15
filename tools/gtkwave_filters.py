#!/usr/bin/env python3
"""gtkwave_filters.py: write the GTKWave alias files that tools/gtkwave/smoke.gtkw uses.

    usage: python3 tools/gtkwave_filters.py <program.dump> <out_dir>
    e.g.   python3 tools/gtkwave_filters.py build/sc/smoke.dump build/sc/gtkwave
    (tools/gtkwave_shot.sh runs it like this.)

GTKWave can show a bus value as text through a "translate filter file": each
line holds a value, written exactly as GTKWave would print it, and the text to
show instead (GTKWave manual, "Alias Files and Attaching External
Disassemblers"). This script writes four of them into <out_dir>:

    instr.txt       instruction word (8 hex digits) -> assembly, from the objdump listing
    alu_ctrl.txt    alu_ctrl code (1 hex digit)     -> ALU operation (ALU_* in rtl/rv_pkg.sv)
    result_src.txt  result_src code (1 hex digit)   -> write-back source (RES_* in rtl/rv_pkg.sv)
    reg.txt         register number (2 hex digits)  -> x0 .. x31

The ALU and result names are read from rtl/rv_pkg.sv, so they follow the RTL.
Python 3 standard library only.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vcd2svg import DUMP_LINE, clean_asm  # noqa: E402  (objdump line pattern, short assembly)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, "rtl", "rv_pkg.sv")

# localparam logic [3:0] ALU_ADD  = 4'd0;
PARAM = re.compile(r"localparam\s+logic\s+\[\d+:0\]\s+([A-Z]+)_(\w+)\s*=\s*\d+'([bdh])([0-9a-fA-F_]+)\s*;")


def package_codes(prefix):
    """{code: name} for every localparam <prefix>_<name> in rtl/rv_pkg.sv."""
    codes = {}
    with open(PKG) as f:
        for m in PARAM.finditer(f.read()):
            if m.group(1) == prefix:
                base = {"b": 2, "d": 10, "h": 16}[m.group(3)]
                codes[int(m.group(4).replace("_", ""), base)] = m.group(2)
    if not codes:
        sys.exit(f"gtkwave_filters: no {prefix}_* constants found in rtl/rv_pkg.sv")
    return codes


def program_words(dump):
    """{instruction word: assembly} from an `objdump -d` listing.

    A branch or jump is pc-relative, so one word can sit at two addresses with
    two different targets (for example two `jal x0,.` spin loops). An alias
    cannot know the address, so such a word is shown with its offset instead:
    'jal x0,.' or 'beq x7,x3,.+8'.
    """
    seen = {}                                   # word -> {assembly: (address, raw objdump text)}
    with open(dump) as f:
        for line in f:
            m = DUMP_LINE.match(line)
            if m:
                addr, word, raw = int(m.group(1), 16), int(m.group(2), 16), m.group(3)
                seen.setdefault(word, {}).setdefault(clean_asm(raw), (addr, raw))
    words = {}
    for word, texts in seen.items():
        text, (addr, raw) = next(iter(texts.items()))
        if len(texts) > 1:
            raw = re.sub(r"\s#\s.*$", "", raw)
            raw = re.sub(r"\s*<[^>]*>$", "", raw).strip()
            mnemonic, operands = raw.split(None, 1)
            ops = operands.replace(" ", "").split(",")
            offset = int(ops[-1], 16) - addr
            ops[-1] = "." if offset == 0 else f".{offset:+d}"
            text = f"{mnemonic} {','.join(ops)}"
        words[word] = text
    return words


def write(path, header, rows):
    with open(path, "w", newline="\n") as f:
        f.write(f"# {header}\n# written by tools/gtkwave_filters.py\n")
        for value, text in rows:
            f.write(f"{value} {text}\n")
    print(f"gtkwave_filters: {os.path.relpath(path)}: {len(rows)} values")


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: python3 tools/gtkwave_filters.py <program.dump> <out_dir>")
    dump, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)

    words = program_words(dump)
    if not words:
        sys.exit(f"gtkwave_filters: no instructions found in {dump}")
    write(os.path.join(out, "instr.txt"), f"instruction word -> assembly, from {dump}",
          [(f"{word:08X}", text) for word, text in sorted(words.items())])
    write(os.path.join(out, "alu_ctrl.txt"), "alu_ctrl -> ALU operation (rtl/rv_pkg.sv)",
          [(f"{code:X}", name) for code, name in sorted(package_codes("ALU").items())])
    write(os.path.join(out, "result_src.txt"), "result_src -> write-back source (rtl/rv_pkg.sv)",
          [(f"{code:X}", name) for code, name in sorted(package_codes("RES").items())])
    write(os.path.join(out, "reg.txt"), "register number -> name",
          [(f"{n:02X}", f"x{n}") for n in range(32)])


if __name__ == "__main__":
    main()
