#!/usr/bin/env bash
# alu_adv_run.sh: check of alu against a Python oracle (tools/alu_adv_gen.py).
#   usage: tools/alu_adv_run.sh [seed] [n_random_per_code] [extra vvp plusargs...]
# The same seed drives the Python random vectors and the testbench's random replay.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2
seed="${1:-1}"; shift || true
nrand="${1:-1200}"; shift || true
mkdir -p build
vecs="build/alu_adv_vectors_s$seed.hex"
python3 tools/alu_adv_gen.py "$vecs" "$seed" "$nrand" || exit 4
bash tools/run_unit.sh alu_adv_tb +seed="$seed" +vec="$vecs" "$@"
