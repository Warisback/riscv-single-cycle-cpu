#!/usr/bin/env bash
# check.sh: the shorter regression that CI runs (make check).
#   usage: tools/check.sh [N]   (N random programs, default 20; 4 minutes in the logged run)
#
# Steps, in order: lint, the unit testbenches, the independent-oracle checks,
# then smoke, the rv32ui riscv-tests and random programs 1..N on the core
# against the ISS. The riscv-tests and their ISS traces are built first if they
# are missing. The planted bugs and the longer programs are left to
# tools/regress_all.sh (make all).
# Log: results/check.log, in the same form as results/regress_all.log. The tool
# versions go to results/tool_versions.log first.
# Exit code 0 only if every step passed.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2
nrand="${1:-20}"
case "$nrand" in '' | *[!0-9]*) echo "usage: tools/check.sh [N]   (N: a whole number)" >&2; exit 2 ;; esac
need_iverilog
need_binutils
need_riscv_tests
mkdir -p results
bash tools/tool_versions.sh > /dev/null
log=results/check.log
start=$SECONDS

{
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)  check, what CI runs (tool versions: results/tool_versions.log)"
  step lint_sc.sh
  step run_unit_all.sh
  step run_adv_all.sh
  step run_all_sc.sh smoke
  step run_all_sc.sh riscv
  step run_all_sc.sh rand "$nrand" 1 300
  step_verdict check
  echo "# Wall-clock seconds of each step."
  step_times
  echo "# elapsed $((SECONDS - start)) s"
} | tee "$log"
grep -q '^PASS check' "$log"
