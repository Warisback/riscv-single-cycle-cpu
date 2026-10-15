#!/usr/bin/env bash
# regress_all.sh: rerun every check in this project and write results/regress_all.log.
#   usage: tools/regress_all.sh   (22 minutes in the logged run; the log gives the time of each step)
#
# Steps, in order: the unit testbenches, the independent-oracle checks, the
# rv32ui riscv-tests on the ISS, every program group on the core against the ISS
# (smoke, riscv-tests, 200 random programs, 20 long random programs), planted
# bugs in the core and in the register file, the waveform figure, and lint.
# The log keeps the PASS/FAIL lines of each step, then one verdict line, the
# instruction and cycle totals of the program groups, and the wall-clock time
# of each step. The tool versions go to results/tool_versions.log first.
# Exit code 0 only if every step passed.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2
need_iverilog
need_binutils
need_riscv_tests
mkdir -p results
bash tools/tool_versions.sh > /dev/null
log=results/regress_all.log
start=$SECONDS

# step, step_verdict and step_times are in tools/common.sh
{
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)  full regression (tool versions: results/tool_versions.log)"
  step run_unit_all.sh
  step run_adv_all.sh
  step run_riscv_tests_iss.sh
  step run_all_sc.sh all
  step mutate_sc.sh
  step regfile_mut.sh
  step make_wave_fig.sh
  step lint_sc.sh
  step_verdict regression
  grep -h '^TOTAL all groups' results/sc_summary.log 2> /dev/null
  echo "# Wall-clock seconds of each step. Each program group inside run_all_sc.sh all"
  echo "# gives its own time on the last line of its log."
  step_times
  echo "# elapsed $((SECONDS - start)) s"
} | tee "$log"
grep -q '^PASS regression' "$log"
