#!/usr/bin/env bash
# run_sc.sh: run one program on the single-cycle core (tb/sc_core_tb.sv).
#
#   usage: tools/run_sc.sh <hex> <trace_out> [extra plusargs...]
#   e.g.   tools/run_sc.sh build/sc/smoke.hex build/sc/smoke.rtl.trace
#          tools/run_sc.sh build/sc/smoke.hex build/sc/smoke.rtl.trace +vcd=build/sc/smoke.vcd
#
# <hex> and <trace_out> are taken relative to the current directory. Extra
# plusargs are passed to vvp as they are and run from the repository root, so a
# relative +vcd=<file> is relative to the root.
#
# Compiles once: build/sc_core_tb.vvp is reused until a .sv file in rtl/ or tb/
# is newer than it (same iverilog flags as tools/run_unit.sh). When flock is
# available the compile step is locked, so parallel runs share one build.
# Prints the testbench output (TOHOST=..., then one PASS or FAIL line).
# Exit code: 0 only if that line is PASS; 3 if the compile failed.
set -u
if [ $# -lt 2 ]; then
  echo "usage: tools/run_sc.sh <hex> <trace_out> [extra plusargs...]" >&2
  exit 2
fi

abspath() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
hex="$(abspath "$1")"
trace="$(abspath "$2")"
shift 2

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2
need_iverilog
mkdir -p build
vvp_file=build/sc_core_tb.vvp

compile() {
  if [ ! -f "$vvp_file" ] || [ -n "$(find rtl tb -name '*.sv' -newer "$vvp_file" | head -n 1)" ]; then
    iverilog -g2012 -Wall -o "$vvp_file.tmp.$$" -y rtl -y tb -Y .sv -I rtl -I tb \
      rtl/rv_pkg.sv tb/sc_core_tb.sv || return 3
    mv "$vvp_file.tmp.$$" "$vvp_file"
  fi
}

if command -v flock > /dev/null 2>&1; then
  ( flock 9 && compile ) 9> build/sc_core_tb.lock
else
  compile
fi
rc=$?
if [ $rc -ne 0 ]; then
  echo "FAIL compile of tb/sc_core_tb.sv (iverilog exit $rc)"
  exit 3
fi

out="$(vvp -n "$vvp_file" +hex="$hex" +trace="$trace" "$@" 2>&1)"
echo "$out"
echo "$out" | grep -q '^PASS'
