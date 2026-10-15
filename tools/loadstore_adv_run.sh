#!/usr/bin/env bash
# loadstore_adv_run.sh: check of store_unit + load_unit against a Python oracle.
#   usage: tools/loadstore_adv_run.sh [seed] [n_random_per_combo]
# 1. tools/loadstore_adv_gen.py writes build/loadstore_adv_vectors.hex (seeded),
#    including the load/store cases of the official riscv-tests (deps/riscv-tests)
# 2. tools/run_unit.sh runs tb/loadstore_adv_tb.sv with the same +seed
# Exit code 0 only if the testbench prints PASS (log: results/loadstore_adv_tb.log).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2
seed="${1:-1}"
nrand="${2:-16}"
need_riscv_tests
mkdir -p build
python3 -I tools/loadstore_adv_gen.py build/loadstore_adv_vectors.hex "$seed" "$nrand" || exit 4
bash tools/run_unit.sh loadstore_adv_tb +seed="$seed" +vec=build/loadstore_adv_vectors.hex
