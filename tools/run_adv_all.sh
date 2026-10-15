#!/usr/bin/env bash
# run_adv_all.sh: run the checks that use an independent oracle, one after another.
#   usage: tools/run_adv_all.sh
#
#   immgen_adv_run.sh       immgen vs immediates chosen first, encoded by GNU as
#   alu_adv_run.sh          alu vs a Python model
#   branch_unit_adv_run.sh  branch_unit vs a Python model
#   decoder_adv_run.sh      maindec + aludec vs every RV32I instruction from GNU as
#   loadstore_adv_run.sh    store_unit + load_unit vs a Python byte model and riscv-tests cases
#   mem_adv_run.sh          imem and dmem vs raw image bytes (8 image cases)
#   run_iss_adv.sh          the reference model tools/iss.py vs hand-worked cases,
#                           a second Python model and GNU as
#
# Prints the last PASS or FAIL line of each, then one summary line, also kept in
# results/adv.log. Exit code 0 only if every check passed.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2
need_iverilog
need_binutils
need_riscv_tests
mkdir -p results
start=$SECONDS
{
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)  independent-oracle checks"
  n=0
  ok=0
  for s in immgen_adv_run.sh alu_adv_run.sh branch_unit_adv_run.sh decoder_adv_run.sh \
           loadstore_adv_run.sh mem_adv_run.sh run_iss_adv.sh; do
    n=$((n + 1))
    out="$(bash "tools/$s" 2>&1)"
    rc=$?
    line="$(printf '%s\n' "$out" | grep -E '^(PASS|FAIL)' | tail -n 1)"
    if [ $rc -eq 0 ] && [ -n "$line" ]; then
      ok=$((ok + 1))
      echo "$line"
    else
      echo "FAIL $s (exit $rc): ${line:-no PASS/FAIL line}"
      printf '%s\n' "$out" | tail -n 15 | sed 's/^/      /'
    fi
  done
  if [ $ok -eq $n ]; then
    echo "PASS adv: $ok/$n checks passed"
  else
    echo "FAIL adv: $ok/$n checks passed"
  fi
  echo "# elapsed $((SECONDS - start)) s"
} | tee results/adv.log
grep -q '^PASS adv' results/adv.log
