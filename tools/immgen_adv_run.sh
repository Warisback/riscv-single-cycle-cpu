#!/usr/bin/env bash
# immgen_adv_run.sh: check of immgen with GNU as as the oracle.
#   usage: tools/immgen_adv_run.sh [seed] [n_random_per_format] [extra vvp plusargs...]
#   e.g.   tools/immgen_adv_run.sh 7
# 1. immgen_adv_gen.py writes assembly with immediates we chose, plus the expected values
# 2. GNU as (RV32I, no relaxation) encodes them; there must be no relocations
# 3. objcopy pulls out the raw .text bytes; immgen_adv_merge.py pairs words with answers
# 4. run_unit.sh runs tb/immgen_adv_tb.sv on the vectors (the same seed drives its own
#    random choices)
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2
seed="${1:-1}"; shift || true
nrand="${1:-3000}"; shift || true
need_binutils
D=build/immgen_adv
mkdir -p "$D"
rm -f "$D/immgen_adv.s" "$D/immgen_adv.expect" "$D/immgen_adv.o" "$D/immgen_adv.bin" "$D/immgen_adv_vectors.hex"

python3 tools/immgen_adv_gen.py "$D" "$seed" "$nrand" || exit 4
"${RV}as" -march=rv32i -mabi=ilp32 -mno-relax -o "$D/immgen_adv.o" "$D/immgen_adv.s" || exit 5
# A relocation would mean the assembler left a field for the linker to fill in.
if "${RV}readelf" -r "$D/immgen_adv.o" | grep -q 'Relocation section'; then
  echo "immgen_adv_run: object has relocations, offsets were not resolved by as"
  exit 6
fi
"${RV}objcopy" -O binary -j .text "$D/immgen_adv.o" "$D/immgen_adv.bin" || exit 7
python3 tools/immgen_adv_merge.py "$D/immgen_adv.bin" "$D/immgen_adv.expect" "$D/immgen_adv_vectors.hex" || exit 8
nvec=$(wc -l < "$D/immgen_adv.expect" | tr -d ' ')
bash tools/run_unit.sh immgen_adv_tb +seed="$seed" +vec="$D/immgen_adv_vectors.hex" +nvec="$nvec" "$@"
