#!/usr/bin/env bash
# mem_test_gen.sh: assemble tb/mem_test.S, the source of the mem_tb fixture.
#   usage: tools/mem_test_gen.sh
# Writes build/mem_test/mem_test.{o,elf,dis,bin,hex} (as -march=rv32i,
# ld -Ttext=0, objcopy -O binary, then 4 little-endian bytes per line) and checks
# that the hex is identical to the tracked tb/mem_test.hex.
# mem_adv_tb reads build/mem_test/mem_test.bin as its raw-byte oracle.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2
need_binutils
D=build/mem_test
mkdir -p "$D"
"${RV}as" -march=rv32i -mabi=ilp32 -o "$D/mem_test.o" tb/mem_test.S || exit 4
"${RV}ld" -m elf32lriscv -Ttext=0 -e _start -o "$D/mem_test.elf" "$D/mem_test.o" || exit 4
"${RV}objdump" -d -M no-aliases,numeric "$D/mem_test.elf" > "$D/mem_test.dis" || exit 4
"${RV}objcopy" -O binary "$D/mem_test.elf" "$D/mem_test.bin" || exit 4
python3 tools/bin2hex.py "$D/mem_test.bin" "$D/mem_test.hex" || exit 4
if cmp -s "$D/mem_test.hex" tb/mem_test.hex; then
  echo "PASS mem_test: tb/mem_test.hex matches tb/mem_test.S ($(wc -l < "$D/mem_test.hex" | tr -d ' ') words)"
else
  echo "FAIL mem_test: $D/mem_test.hex differs from tb/mem_test.hex"
  exit 1
fi
