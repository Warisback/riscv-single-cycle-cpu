#!/usr/bin/env bash
# asm2hex.sh: assembly source -> memory image for the core and the ISS.
#
#   usage: tools/asm2hex.sh <src.S|src.s> <out.hex>
#   e.g.   tools/asm2hex.sh sw/smoke.S build/sc/smoke.hex
#
# Relative paths are taken from the repository root.
# Steps, and the files they leave next to <out.hex> (same base name):
#   1. .S only: C preprocessor (pcpp)      -> <out>.i     (#include/#define expanded)
#   2. assembler, RV32I only               -> <out>.o
#   3. linker with tools/link.ld           -> <out>.elf   (code at 0x0, data at 0x8000)
#   4. disassembly for reading             -> <out>.dump
#   5. objcopy raw bytes + bin2hex.py      -> <out>.bin, <out>.hex
# The RISC-V binutils are found as described in tools/common.sh (RISCV_PREFIX).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT"

if [ $# -ne 2 ]; then
  echo "usage: tools/asm2hex.sh <src.S|src.s> <out.hex>" >&2
  exit 2
fi
src="$1"
out="$2"
base="${out%.hex}"
need_binutils
mkdir -p "$(dirname "$out")"

# 1. Preprocess. pcpp is a C preprocessor written in Python.
#    -D__riscv_xlen=32 : riscv-tests use it (a RISC-V gcc would predefine it).
#    -I tools/env      : our riscv_test.h (end of test via TOHOST, no CSRs).
#    -I .../scalar     : test_macros.h from the official riscv-tests.
#    --line-directive with no value: do not emit #line markers.
case "$src" in
  *.S)
    need_pcpp
    "${PCPP[@]}" \
      -D__riscv_xlen=32 \
      -I "$ROOT/tools/env" \
      -I "$ROOT/deps/riscv-tests/isa/macros/scalar" \
      --line-directive -o "$base.i" "$src"
    asm_in="$base.i"
    ;;
  *.s)
    asm_in="$src"
    ;;
  *)
    echo "asm2hex: $src must end in .S (preprocessed) or .s (plain assembly)" >&2
    exit 2
    ;;
esac

# 2. Assemble for plain RV32I. -mno-relax (and --no-relax below) keeps every
#    instruction exactly as written, so the .dump matches the source.
"${RV}as" -march=rv32i -mabi=ilp32 -mno-relax -o "$base.o" "$asm_in"

# 3. Link at the addresses in tools/link.ld.
"${RV}ld" -m elf32lriscv --no-relax -T "$ROOT/tools/link.ld" -o "$base.elf" "$base.o"

# 4. Disassemble: numeric register names (x1, not ra) and no pseudo-instructions,
#    so lines read like the trace (x01=...) and like the spec's tables.
"${RV}objdump" -d -M numeric,no-aliases "$base.elf" > "$base.dump"

# 5. Raw memory image from address 0, then one hex word per line.
#    .bss is made "loadable" so its zeros are in the image too, and the hex is
#    padded to all 16384 words: no X in the RTL memories, same memory as the ISS.
"${RV}objcopy" -O binary --set-section-flags .bss=alloc,load,contents "$base.elf" "$base.bin"
python3 "$ROOT/tools/bin2hex.py" "$base.bin" "$out" --words 16384

echo "asm2hex: $src -> $out ($(wc -c < "$base.bin" | tr -d ' ') bytes of code+data, padded to 16384 words)"
