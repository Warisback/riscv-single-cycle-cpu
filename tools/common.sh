# common.sh: shared set-up for the bash scripts in tools/. Source it, do not run it.
#
#   ROOT            absolute path of the repository root
#   need_iverilog   stop with an install hint unless iverilog and vvp are on PATH
#   need_binutils   find the RISC-V GNU binutils and set RV to their prefix, so
#                   "${RV}as" is the assembler (also exported as RISCV_PREFIX for
#                   the Python tools). Search order:
#                     1. $RISCV_PREFIX, if set: a prefix ending in '-', either a
#                        name on PATH or a path, e.g. /opt/riscv/bin/riscv64-unknown-elf-
#                     2. riscv64-unknown-elf-, riscv32-unknown-elf-, riscv64-elf-
#                        and riscv64-linux-gnu- on PATH, in that order
#                     3. a local, untracked copy under deps/rv (any folder layout
#                        with a bin/riscv*-as in it)
#   need_pcpp       check that the pcpp C preprocessor runs; sets the array PCPP
#   need_riscv_tests  stop with a hint unless deps/riscv-tests is there
#   ensure_riscv_tests  rebuild sw/riscv-tests/ (images and ISS traces) if it is
#                   missing or older than anything it is built from
#   step, step_verdict, step_times  the steps of tools/regress_all.sh and
#                   tools/check.sh (see the end of this file)
#
# If deps/pylib exists (tools/setup_deps.sh can install pcpp there), it goes on
# the front of PYTHONPATH.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -d "$ROOT/deps/pylib" ]; then
  PYTHONPATH="$ROOT/deps/pylib${PYTHONPATH:+:$PYTHONPATH}"
  export PYTHONPATH
fi

die() {
  echo "$*" >&2
  exit 5
}

need_iverilog() {
  if ! command -v iverilog > /dev/null 2>&1 || ! command -v vvp > /dev/null 2>&1; then
    die "error: Icarus Verilog (iverilog, vvp) not found on PATH.
  Ubuntu/Debian: sudo apt install iverilog      macOS: brew install icarus-verilog"
  fi
}

find_binutils() {
  local p f
  if [ -n "${RISCV_PREFIX:-}" ]; then
    if [ -f "${RISCV_PREFIX}as" ] || command -v "${RISCV_PREFIX}as" > /dev/null 2>&1; then
      RV="$RISCV_PREFIX"
      return 0
    fi
    echo "RISCV_PREFIX is set to '$RISCV_PREFIX', but '${RISCV_PREFIX}as' was not found." >&2
    return 1
  fi
  for p in riscv64-unknown-elf- riscv32-unknown-elf- riscv64-elf- riscv64-linux-gnu-; do
    if command -v "${p}as" > /dev/null 2>&1; then
      RV="$p"
      return 0
    fi
  done
  if [ -d "$ROOT/deps/rv" ]; then
    f="$(find "$ROOT/deps/rv" -path '*/bin/riscv*-as' \( -type f -o -type l \) 2> /dev/null | sort | head -n 1)"
    if [ -n "$f" ]; then
      RV="${f%as}"
      return 0
    fi
  fi
  return 1
}

need_binutils() {
  if find_binutils; then
    RISCV_PREFIX="$RV"
    export RISCV_PREFIX
    return 0
  fi
  die "error: RISC-V GNU binutils not found (tried \$RISCV_PREFIX, then riscv64-unknown-elf-as,
  riscv32-unknown-elf-as, riscv64-elf-as and riscv64-linux-gnu-as on PATH, then deps/rv).
  Ubuntu/Debian: sudo apt install binutils-riscv64-unknown-elf
  macOS:         brew install riscv64-elf-binutils
  Elsewhere:     set RISCV_PREFIX, e.g. RISCV_PREFIX=/opt/riscv/bin/riscv64-unknown-elf-"
}

need_pcpp() {
  if python3 -c 'import pcpp' > /dev/null 2>&1; then
    PCPP=(python3 -c 'import pcpp; pcpp.main()')
  elif command -v pcpp > /dev/null 2>&1; then
    PCPP=(pcpp)
  else
    die "error: the pcpp C preprocessor (Python) was not found.
  Install it with: python3 -m pip install -r requirements.txt   (or run tools/setup_deps.sh)"
  fi
}

need_riscv_tests() {
  if [ ! -d "$ROOT/deps/riscv-tests/isa/rv32ui" ]; then
    die "error: deps/riscv-tests is missing. Run tools/setup_deps.sh first."
  fi
}

# True (0) if sw/riscv-tests/ must be rebuilt. The stamp file is written by
# tools/run_riscv_tests_iss.sh after a run in which every test passed.
riscv_tests_stale() {
  local stamp="$ROOT/sw/riscv-tests/.built"
  [ -f "$stamp" ] || return 0
  [ -n "$(cd "$ROOT" && find tools/asm2hex.sh tools/bin2hex.py tools/link.ld tools/env tools/iss.py \
          deps/riscv-tests/isa/rv32ui deps/riscv-tests/isa/rv64ui deps/riscv-tests/isa/macros \
          -newer "$stamp" 2> /dev/null | head -n 1)" ]
}

ensure_riscv_tests() {
  if riscv_tests_stale; then
    echo "building the rv32ui riscv-tests and their ISS traces (tools/run_riscv_tests_iss.sh)"
    bash "$ROOT/tools/run_riscv_tests_iss.sh" > /dev/null || {
      echo "FAIL building the riscv-tests: see results/iss_riscv_tests.log"
      return 1
    }
  fi
  return 0
}

# Steps of tools/regress_all.sh and tools/check.sh.
#   step SCRIPT [ARGS...]  run tools/SCRIPT and print its PASS/FAIL lines, each
#                   once. The step passes if the script exits 0 and printed at
#                   least one such line. Its wall-clock time is kept.
#   step_verdict NAME  "PASS NAME: k/n steps passed", or FAIL if any step failed
#   step_times      the wall-clock seconds of each step, one comment line each
STEPS_RUN=0
STEPS_OK=0
STEP_TIMES=()
step() {
  local script="$1" out rc lines t0=$SECONDS
  shift
  STEPS_RUN=$((STEPS_RUN + 1))
  out="$(bash "$ROOT/tools/$script" "$@" 2>&1)"
  rc=$?
  STEP_TIMES+=("$(printf '#  %5d  tools/%s %s' $((SECONDS - t0)) "$script" "$*" | sed 's/ *$//')")
  lines="$(printf '%s\n' "$out" | grep -E '^(PASS|FAIL)' | awk '!seen[$0]++')"
  if [ $rc -eq 0 ] && [ -n "$lines" ]; then
    STEPS_OK=$((STEPS_OK + 1))
    printf '%s\n' "$lines"
  else
    printf '%s\n' "${lines:-no PASS/FAIL line}"
    echo "FAIL step tools/$script $* (exit $rc)"
  fi
}
step_verdict() {
  if [ "$STEPS_RUN" -gt 0 ] && [ "$STEPS_OK" -eq "$STEPS_RUN" ]; then
    echo "PASS $1: $STEPS_OK/$STEPS_RUN steps passed"
  else
    echo "FAIL $1: $STEPS_OK/$STEPS_RUN steps passed"
  fi
}
step_times() {
  printf '%s\n' "${STEP_TIMES[@]}"
}
