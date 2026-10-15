#!/usr/bin/env bash
# run_all_sc.sh: check the single-cycle core against the ISS on test programs.
#
#   usage: tools/run_all_sc.sh smoke              sw/smoke.S
#          tools/run_all_sc.sh riscv              the 40 applicable rv32ui riscv-tests
#          tools/run_all_sc.sh rand [N] [START] [RAND_N]
#                                                 N random programs (default 20), seeds
#                                                 START..START+N-1 (default 1), each from
#                                                 tools/randgen.py --n RAND_N (default 300)
#          tools/run_all_sc.sh summary            results/sc_summary.log from the logs of
#                                                 the full run below
#          tools/run_all_sc.sh all                smoke, riscv, rand 200 1 300,
#                                                 rand 20 1001 2000, then summary
#
# Every program runs on both:
#   ISS  tools/iss.py      -> <name>.iss.trace (the golden trace)
#   RTL  tools/run_sc.sh   -> <name>.rtl.trace and <name>.rtl.out
# and passes only if the ISS says PASS, the RTL testbench says PASS (TOHOST=1,
# no assertion failed) and tools/compare.py finds the two traces identical.
# Logs: results/sc_smoke.log, results/sc_riscv.log,
#       results/sc_rand_n<RAND_N>_s<START>-<END>.log, results/sc_summary.log.
# Exit code: 0 only if every program in the group passed.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2
mkdir -p build/sc results sw/gen

# run_one <name> <hex> <dir>: one program through ISS + RTL + compare.
# Prints one table row: name, ISS, RTL, compare, instructions, cycles.
run_one() {
  local name="$1" hex="$2" dir="$3"
  local iss_rc rtl_rc cmp_rc instrs cycles
  python3 tools/iss.py --hex "$hex" --trace "$dir/$name.iss.trace" > "$dir/$name.iss.out" 2>&1
  iss_rc=$?
  bash tools/run_sc.sh "$hex" "$dir/$name.rtl.trace" > "$dir/$name.rtl.out" 2>&1
  rtl_rc=$?
  python3 tools/compare.py "$dir/$name.iss.trace" "$dir/$name.rtl.trace" > "$dir/$name.cmp" 2>&1
  cmp_rc=$?
  instrs=$(grep -oE '^PASS [0-9]+ instructions' "$dir/$name.rtl.out" | grep -oE '[0-9]+' || echo 0)
  cycles=$(grep -oE '[0-9]+ cycles' "$dir/$name.rtl.out" | head -n 1 | grep -oE '[0-9]+' || echo 0)
  printf '  %-14s ISS %-4s RTL %-4s trace %-4s %6s instr %6s cycles\n' "$name" \
    "$([ $iss_rc -eq 0 ] && echo PASS || echo FAIL)" "$([ $rtl_rc -eq 0 ] && echo PASS || echo FAIL)" \
    "$([ $cmp_rc -eq 0 ] && echo same || echo DIFF)" "${instrs:-0}" "${cycles:-0}"
  if [ $iss_rc -ne 0 ] || [ $rtl_rc -ne 0 ] || [ $cmp_rc -ne 0 ]; then
    sed 's/^/      /' "$dir/$name.rtl.out" | grep -E 'FAIL|ASSERTION' | head -n 5
    sed 's/^/      /' "$dir/$name.cmp" | head -n 8
    return 1
  fi
  return 0
}

# group <label> <log> <dir>, then "name hex" pairs on stdin
group() {
  local label="$1" log="$2" dir="$3" n=0 ok=0 ti=0 tc=0 start=$SECONDS i c
  {
    echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)  $label on the single-cycle core vs tools/iss.py"
    while read -r name hex; do
      n=$((n + 1))
      if run_one "$name" "$hex" "$dir"; then ok=$((ok + 1)); fi
      i=$(grep -oE '^PASS [0-9]+ instructions' "$dir/$name.rtl.out" | grep -oE '[0-9]+' || echo 0)
      c=$(grep -oE '[0-9]+ cycles' "$dir/$name.rtl.out" | head -n 1 | grep -oE '[0-9]+' || echo 0)
      ti=$((ti + ${i:-0}))
      tc=$((tc + ${c:-0}))
    done
    echo "TOTAL programs=$n passed=$ok instructions=$ti cycles=$tc"
    if [ "$n" -gt 0 ] && [ "$ok" -eq "$n" ]; then
      echo "PASS $label: $ok/$n programs passed"
    else
      echo "FAIL $label: $ok/$n programs passed"
    fi
    echo "# elapsed $((SECONDS - start)) s"
  } | tee "$log"
  grep -q '^PASS' "$log"
}

do_smoke() {
  need_binutils
  bash tools/asm2hex.sh sw/smoke.S build/sc/smoke.hex > /dev/null || { echo "FAIL build of sw/smoke.S"; return 1; }
  echo "smoke build/sc/smoke.hex" | group "smoke" results/sc_smoke.log build/sc
}

do_riscv() {
  need_binutils
  need_riscv_tests
  # build the official tests (and their ISS traces) if they are missing or stale
  ensure_riscv_tests || return 1
  for f in sw/riscv-tests/*.hex; do echo "$(basename "$f" .hex) $f"; done \
    | group "riscv-tests (rv32ui)" results/sc_riscv.log sw/riscv-tests
}

rand_log() {   # rand_log N START RAND_N
  echo "results/sc_rand_n$3_s$2-$(($2 + $1 - 1)).log"
}

do_rand() {
  local n="$1" start="$2" rn="$3" s
  need_binutils
  case "$n$start$rn" in *[!0-9]*) echo "rand: N, START and RAND_N must be whole numbers" >&2; return 2 ;; esac
  if [ "$n" -lt 1 ]; then echo "rand: N must be at least 1" >&2; return 2; fi
  for ((s = start; s < start + n; s++)); do
    python3 tools/randgen.py --seed "$s" --n "$rn" --out "sw/gen/rand_$s.S" > /dev/null
    bash tools/asm2hex.sh "sw/gen/rand_$s.S" "sw/gen/rand_$s.hex" > /dev/null || echo "build error seed $s" >&2
    echo "rand_$s sw/gen/rand_$s.hex"
  done | group "random, seeds $start..$((start + n - 1)), RAND_N=$rn" "$(rand_log "$n" "$start" "$rn")" sw/gen
}

do_summary() {
  local f t np=0 nok=0 ni=0 nc=0
  num() {   # num <key> <TOTAL line>: the number after key=, or 0
    local v
    v="$(echo "$2" | grep -oE "$1=[0-9]+" | head -n 1 | cut -d= -f2)"
    echo "${v:-0}"
  }
  {
    echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)  single-cycle core: summary"
    for f in results/sc_smoke.log results/sc_riscv.log "$(rand_log 200 1 300)" "$(rand_log 20 1001 2000)"; do
      if [ -f "$f" ]; then
        t="$(grep -E '^TOTAL' "$f")"
        echo "$f: $t"
        grep -E '^(PASS|FAIL)' "$f"
        np=$((np + $(num programs "$t")))
        nok=$((nok + $(num passed "$t")))
        ni=$((ni + $(num instructions "$t")))
        nc=$((nc + $(num cycles "$t")))
      else
        echo "FAIL $f is missing (run: tools/run_all_sc.sh all)"
      fi
    done
    # the four groups together; the testbench counts instructions and cycles separately
    echo "TOTAL all groups: programs=$np passed=$nok instructions=$ni cycles=$nc"
  } > results/sc_summary.log
  cat results/sc_summary.log
  ! grep -q '^FAIL' results/sc_summary.log
}

case "${1:-}" in
  smoke)   do_smoke ;;
  riscv)   do_riscv ;;
  rand)    do_rand "${2:-20}" "${3:-1}" "${4:-300}" ;;
  summary) do_summary ;;
  all)
    rc=0
    do_smoke || rc=1
    do_riscv || rc=1
    do_rand 200 1 300 || rc=1
    do_rand 20 1001 2000 || rc=1
    do_summary || rc=1
    exit $rc
    ;;
  *)
    echo "usage: tools/run_all_sc.sh smoke | riscv | rand [N] [START] [RAND_N] | summary | all" >&2
    exit 2
    ;;
esac
