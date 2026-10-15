#!/usr/bin/env bash
# run_unit.sh: compile and run one testbench with Icarus Verilog.
#
#   usage: tools/run_unit.sh <tb_name> [extra vvp plusargs...]
#   e.g.   tools/run_unit.sh alu_tb +seed=7
#
# iverilog -g2012 -Wall, with rtl/ and tb/ searched for modules (-y, -Y .sv)
# and the package compiled first. The output also goes to results/<tb_name>.log.
# Exit code: 0 only if the compile succeeded and a line starts with "PASS".
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2
if [ $# -lt 1 ]; then
  echo "usage: tools/run_unit.sh <tb_name> [extra vvp plusargs...]" >&2
  exit 2
fi
tb="$1"
shift
if [ ! -f "tb/$tb.sv" ]; then
  echo "run_unit: no such testbench: tb/$tb.sv" >&2
  exit 2
fi
need_iverilog
mkdir -p build results
log="results/$tb.log"
start=$SECONDS
{
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)  iverilog $(iverilog -V 2>&1 | head -n 1 | sed 's/Icarus Verilog version //')"
  iverilog -g2012 -Wall -o "build/$tb.vvp" -y rtl -y tb -Y .sv -I rtl -I tb rtl/rv_pkg.sv "tb/$tb.sv" 2>&1
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "COMPILE FAILED ($rc)"
    exit 3
  fi
  vvp -n "build/$tb.vvp" "$@" 2>&1
  echo "# elapsed $((SECONDS - start)) s"
} | tee "$log"
grep -q '^PASS' "$log"
