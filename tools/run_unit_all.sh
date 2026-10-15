#!/usr/bin/env bash
# run_unit_all.sh: run the nine unit testbenches one after another.
#   usage: tools/run_unit_all.sh
# Each testbench writes results/<tb>.log (see tools/run_unit.sh). This prints the
# PASS or FAIL line of each, then one summary line, also kept in results/unit.log.
# Exit code 0 only if every testbench passed.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2
need_iverilog
mkdir -p results
start=$SECONDS
{
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)  unit testbenches"
  n=0
  ok=0
  for t in alu_tb aludec_tb maindec_tb branch_unit_tb immgen_tb load_unit_tb store_unit_tb regfile_tb mem_tb; do
    n=$((n + 1))
    if [ "$t" = mem_tb ]; then
      bash tools/run_unit.sh "$t" +hex=tb/mem_test.hex > /dev/null && ok=$((ok + 1))
    else
      bash tools/run_unit.sh "$t" > /dev/null && ok=$((ok + 1))
    fi
    line="$(grep -E '^(PASS|FAIL|COMPILE FAILED)' "results/$t.log" | tail -n 1)"
    echo "${line:-FAIL $t: no PASS/FAIL line in results/$t.log}"
  done
  if [ $ok -eq $n ]; then
    echo "PASS unit: $ok/$n testbenches passed"
  else
    echo "FAIL unit: $ok/$n testbenches passed"
  fi
  echo "# elapsed $((SECONDS - start)) s"
} | tee results/unit.log
grep -q '^PASS unit' results/unit.log
