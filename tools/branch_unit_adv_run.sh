#!/usr/bin/env bash
# branch_unit_adv_run.sh: check of branch_unit against a Python oracle
# (tools/branch_unit_adv_gen.py).
#   usage: tools/branch_unit_adv_run.sh [seed] [extra vvp plusargs...]
# The same seed drives the Python random vectors and the testbench's replay order.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2
seed="${1:-1}"; shift || true
mkdir -p build
python3 tools/branch_unit_adv_gen.py build/branch_unit_adv_vectors.hex "$seed" || exit 4
bash tools/run_unit.sh branch_unit_adv_tb +seed="$seed" "$@"
