#!/usr/bin/env bash
# regfile_mut.sh: plant two bugs in copies of rtl/regfile.sv and check that
# tb/regfile_tb.sv reports FAIL for each, after an unmodified control copy passes.
#   bypass      : a write-to-read bypass (wrong in a single-cycle core: see rtl/regfile.sv)
#   x0_writable : writes to x0 are not dropped
# Log: results/regfile_mut.log. Exit code 0 only if the control passes and
# both bugs are caught.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2
need_iverilog
mkdir -p results build/regfile_mut
log=results/regfile_mut.log

# run <name> <from> <to>: prints "<name>: <the testbench's PASS or FAIL line>"
run() {
  local name="$1" from="$2" to="$3" m="$ROOT/build/regfile_mut/$1" line
  rm -rf "$m"
  mkdir -p "$m"
  cp -r rtl tb tools "$m/"
  if ! python3 tools/mutate_sc_apply.py "$m/rtl/regfile.sv" "$from" "$to"; then
    echo "$name: NOT APPLIED"
    return
  fi
  line="$(cd "$m" && iverilog -g2012 -Wall -o build.vvp -y rtl -y tb -Y .sv -I rtl -I tb \
            rtl/rv_pkg.sv tb/regfile_tb.sv 2>&1 && vvp -n build.vvp 2>&1)"
  line="$(printf '%s\n' "$line" | grep -E '^(PASS|FAIL)' | head -n 1)"
  echo "$name: ${line:-no PASS/FAIL line}"
}

start=$SECONDS
{
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)  planted bugs in rtl/regfile.sv vs tb/regfile_tb.sv"
  run control "end else if (we && wa != 5'd0) begin" "end else if (we && wa != 5'd0) begin"
  run bypass "assign rd1 = (ra1 == 5'd0) ? 32'd0 : regs[ra1];" "assign rd1 = (ra1 == 5'd0) ? 32'd0 : (we && wa == ra1) ? wd : regs[ra1];"
  run x0_writable "end else if (we && wa != 5'd0) begin" "end else if (we) begin"
} | tee "$log"

caught=$(grep -cE '^(bypass|x0_writable): FAIL' "$log")
if grep -q '^control: PASS' "$log" && [ "$caught" -eq 2 ]; then
  echo "PASS regfile_mut: control passed, 2 of 2 planted bugs caught" | tee -a "$log"
  rc=0
else
  echo "FAIL regfile_mut: control must pass and both bugs must be caught ($caught of 2 caught)" | tee -a "$log"
  rc=1
fi
echo "# elapsed $((SECONDS - start)) s" | tee -a "$log"
exit $rc
