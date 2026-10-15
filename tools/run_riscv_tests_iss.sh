#!/usr/bin/env bash
# run_riscv_tests_iss.sh: build every official rv32ui test and run it on the ISS.
#
#   usage: tools/run_riscv_tests_iss.sh
#
# For each deps/riscv-tests/isa/rv32ui/<name>.S this makes
#   sw/riscv-tests/<name>.hex    memory image (plus .elf/.dump/... from asm2hex.sh)
#   sw/riscv-tests/<name>.trace  ISS trace: the golden trace for the RTL run
# and writes a summary to results/iss_riscv_tests.log.
# One line per test (indented), then exactly one summary line starting PASS or FAIL.
# Exit code 0 only if every test that is not skipped passes.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2
need_binutils
need_riscv_tests
mkdir -p sw/riscv-tests results
rm -f sw/riscv-tests/.built
log=results/iss_riscv_tests.log

# Tests that cannot apply to this core, and why.
skip_reason() {
  case "$1" in
    fence_i) echo "needs Zifencei and self-modifying code; imem and dmem are separate (Harvard) and imem is never written" ;;
    ma_data) echo "misaligned loads/stores; this core (and the ISS) only support naturally aligned accesses" ;;
    *)       echo "" ;;
  esac
}

commit="$(head -c 7 deps/riscv-tests/COMMIT 2> /dev/null)"
start=$SECONDS
{
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)  rv32ui riscv-tests on tools/iss.py"
  echo "# riscv-tests commit ${commit:-unknown}, binutils $("${RV}as" --version | head -n 1)"
  np=0; nf=0; ns=0; passed=""; failed=""; skipped=""
  for src in deps/riscv-tests/isa/rv32ui/*.S; do
    name="$(basename "$src" .S)"
    reason="$(skip_reason "$name")"
    if [ -n "$reason" ]; then
      printf '  %-8s skip  %s\n' "$name" "$reason"
      ns=$((ns + 1)); skipped="$skipped $name"
      continue
    fi
    hex="sw/riscv-tests/$name.hex"
    if ! build_out="$(bash tools/asm2hex.sh "$src" "$hex" 2>&1)"; then
      printf '  %-8s FAIL  build error\n' "$name"
      echo "$build_out" | sed 's/^/      /'
      nf=$((nf + 1)); failed="$failed $name"
      continue
    fi
    if iss_out="$(python3 tools/iss.py --hex "$hex" --trace "sw/riscv-tests/$name.trace" 2>&1)"; then
      printf '  %-8s pass  %s\n' "$name" "$(echo "$iss_out" | tr '\n' ' ' | sed 's/ *$//')"
      np=$((np + 1)); passed="$passed $name"
    else
      printf '  %-8s FAIL\n' "$name"
      echo "$iss_out" | sed 's/^/      /'
      nf=$((nf + 1)); failed="$failed $name"
    fi
  done
  echo "  passed  ($np):$passed"
  echo "  failed  ($nf):$failed"
  echo "  skipped ($ns):$skipped"
  if [ $nf -eq 0 ] && [ $np -gt 0 ]; then
    echo "PASS riscv-tests on ISS: $np passed, 0 failed, $ns skipped"
  else
    echo "FAIL riscv-tests on ISS: $np passed, $nf failed, $ns skipped"
  fi
  echo "# elapsed $((SECONDS - start)) s"
} 2>&1 | tee "$log"

if grep -q '^PASS riscv-tests' "$log"; then
  touch sw/riscv-tests/.built
  exit 0
fi
exit 1
