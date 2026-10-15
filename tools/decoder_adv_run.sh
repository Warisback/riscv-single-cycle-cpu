#!/usr/bin/env bash
# decoder_adv_run.sh: check of maindec + aludec with GNU as as the oracle.
#   usage: tools/decoder_adv_run.sh [seed] [extra vvp plusargs...]
#          (environment PER=N: random instances per mnemonic, default 20)
# 1. tools/decoder_adv_gen.py assembles every RV32I instruction (plus words from
#    other extensions) -> build/decoder_adv/vectors.hex
# 2. tools/run_unit.sh decoder_adv_tb replays them through maindec and aludec, and
#    through a one-instruction execute slice built from immgen, alu and branch_unit.
# The same seed drives the generator's random instructions and the testbench's
# operand values.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2
seed="${1:-1}"; shift || true
need_binutils
mkdir -p build/decoder_adv
python3 tools/decoder_adv_gen.py --seed "$seed" --per "${PER:-20}" --out build/decoder_adv \
  | tee build/decoder_adv/decoder_adv_gen.log
[ "${PIPESTATUS[0]}" -eq 0 ] || exit 4
bash tools/run_unit.sh decoder_adv_tb +seed="$seed" "$@"
