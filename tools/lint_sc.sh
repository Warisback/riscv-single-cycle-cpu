#!/usr/bin/env bash
# lint_sc.sh: compile every testbench (and so every RTL module) with
# iverilog -g2012 -Wall and report any warning or error.
#   usage: tools/lint_sc.sh
# Log: results/lint.log. Exit code 0 only if every compile succeeded with no
# output at all.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2
need_iverilog
mkdir -p results
log=results/lint.log
start=$SECONDS
{
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)  iverilog $(iverilog -V 2>&1 | head -n 1 | sed 's/Icarus Verilog version //') -g2012 -Wall"
  n=0; bad=0
  for f in tb/*_tb.sv; do
    n=$((n + 1))
    out="$(iverilog -g2012 -Wall -t null -y rtl -y tb -Y .sv -I rtl -I tb rtl/rv_pkg.sv "$f" 2>&1)"
    rc=$?
    if [ $rc -eq 0 ] && [ -z "$out" ]; then
      echo "  $f: clean"
    else
      bad=$((bad + 1))
      echo "  $f: iverilog exit $rc"
      printf '%s\n' "$out" | sed 's/^/      /'
    fi
  done
  if [ $bad -eq 0 ]; then
    echo "PASS lint: $n testbenches and the RTL they use compile with no warnings"
  else
    echo "FAIL lint: $bad of $n testbenches gave warnings or errors"
  fi
  echo "# elapsed $((SECONDS - start)) s"
} | tee "$log"
grep -q '^PASS' "$log"
