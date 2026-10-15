#!/usr/bin/env bash
# mem_adv_run.sh: run the memory testbench tb/mem_adv_tb.sv on every image case.
#   usage: tools/mem_adv_run.sh
# Images: build/mem_adv/{full,part}.bin from tools/mem_adv_gen.py, turned into
# .hex by tools/bin2hex.py (the same step as the program flow), plus the mem_tb
# fixture (tb/mem_test.hex, rebuilt from tb/mem_test.S by tools/mem_test_gen.sh)
# and the no-image case. Each run's log is kept as results/mem_adv/<case>.log.
# Exit code 0 only if every run printed PASS.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2
D=build/mem_adv
python3 tools/mem_adv_gen.py "$D" || exit 2
python3 tools/bin2hex.py "$D/full.bin" "$D/full.hex" || exit 2
python3 tools/bin2hex.py "$D/part.bin" "$D/part.hex" || exit 2
echo "full.hex: $(wc -l < "$D/full.hex" | tr -d ' ') words, part.hex: $(wc -l < "$D/part.hex" | tr -d ' ') words"
bash tools/mem_test_gen.sh || exit 2
mkdir -p results/mem_adv

rc=0
n=0
ok=0
run() {   # run <case-name> <plusargs...>
  local name="$1" r
  shift
  n=$((n + 1))
  bash tools/run_unit.sh mem_adv_tb "$@" > /dev/null
  r=$?
  # run_unit.sh writes results/mem_adv_tb.log; keep it under the case name instead
  mv results/mem_adv_tb.log "results/mem_adv/$name.log"
  echo "$name: $(grep -E '^(PASS|FAIL)' "results/mem_adv/$name.log" || echo 'NO SUMMARY LINE')"
  if [ $r -eq 0 ]; then ok=$((ok + 1)); else rc=1; fi
}
for s in 1 2 3 42 777; do
  run "full_s$s" +hex="$D/full.hex" +bin="$D/full.bin" +seed="$s"
done
run part_s5 +hex="$D/part.hex" +bin="$D/part.bin" +seed=5
run fixture +hex=tb/mem_test.hex +bin=build/mem_test/mem_test.bin +seed=9
run nohex +seed=11
if [ $rc -eq 0 ]; then
  echo "PASS mem_adv: $ok/$n image cases passed (logs in results/mem_adv/)"
else
  echo "FAIL mem_adv: $ok/$n image cases passed (logs in results/mem_adv/)"
fi
exit $rc
