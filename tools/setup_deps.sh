#!/usr/bin/env bash
# setup_deps.sh: fetch the third-party inputs that this repository does not keep,
# then report whether the system tools are installed.
#
#   usage: tools/setup_deps.sh
#
#   deps/riscv-tests  the official riscv-tests, pinned to one commit. Only isa/
#                     (rv32ui sources, the rv64ui files they include, the test
#                     macros) and LICENSE are kept. Needs git and network access.
#   pcpp              the C preprocessor (Python) used by tools/asm2hex.sh for .S
#                     files. If python3 cannot import it and there is no pcpp
#                     command, pcpp 1.30 is installed into deps/pylib with
#                     python3 -m pip install --target (tools/common.sh adds
#                     deps/pylib to PYTHONPATH).
#
# Icarus Verilog and the RISC-V binutils come from the system package manager:
#   Ubuntu/Debian: sudo apt install iverilog binutils-riscv64-unknown-elf
#   macOS:         brew install icarus-verilog riscv64-elf-binutils
# Safe to run again: what is already in place is left alone.
# Environment: RISCV_TESTS_URL and RISCV_TESTS_COMMIT override the source.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2

RISCV_TESTS_URL="${RISCV_TESTS_URL:-https://github.com/riscv-software-src/riscv-tests.git}"
RISCV_TESTS_COMMIT="${RISCV_TESTS_COMMIT:-7b68f7b91f827f8d94cc1c57ff123752c5c8f704}"
PCPP_VERSION=1.30
dest=deps/riscv-tests
rc=0

# ---- riscv-tests
if [ -f "$dest/COMMIT" ] && [ "$(head -n 1 "$dest/COMMIT")" = "$RISCV_TESTS_COMMIT" ] \
   && [ -f "$dest/isa/rv32ui/add.S" ] && [ -f "$dest/isa/macros/scalar/test_macros.h" ]; then
  echo "riscv-tests: $dest is already at commit ${RISCV_TESTS_COMMIT:0:7}"
else
  command -v git > /dev/null 2>&1 || die "error: git is needed to fetch riscv-tests"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/riscv-tests.XXXXXX")" || die "error: mktemp failed"
  trap 'rm -rf "$tmp"' EXIT
  echo "riscv-tests: fetching commit ${RISCV_TESTS_COMMIT:0:7} from $RISCV_TESTS_URL"
  git -C "$tmp" init -q &&
    git -C "$tmp" remote add origin "$RISCV_TESTS_URL" &&
    git -C "$tmp" fetch -q --depth 1 origin "$RISCV_TESTS_COMMIT" &&
    git -C "$tmp" -c advice.detachedHead=false checkout -q FETCH_HEAD ||
    die "error: could not fetch riscv-tests commit $RISCV_TESTS_COMMIT"
  got="$(git -C "$tmp" rev-parse HEAD)"
  [ "$got" = "$RISCV_TESTS_COMMIT" ] || die "error: fetched commit $got, expected $RISCV_TESTS_COMMIT"
  [ -f "$tmp/isa/rv32ui/add.S" ] || die "error: the fetched tree has no isa/rv32ui/add.S"
  rm -rf "$dest"
  mkdir -p "$dest"
  cp -R "$tmp/isa" "$tmp/LICENSE" "$dest/"
  printf '%s\n# %s at this commit; only isa/ and LICENSE kept (tools/setup_deps.sh)\n' \
    "$RISCV_TESTS_COMMIT" "$RISCV_TESTS_URL" > "$dest/COMMIT"
  echo "riscv-tests: $(ls "$dest/isa/rv32ui"/*.S | wc -l | tr -d ' ') rv32ui sources in $dest"
fi

# ---- pcpp
pcpp_importable() {
  PYTHONPATH="$ROOT/deps/pylib${PYTHONPATH:+:$PYTHONPATH}" python3 -c 'import pcpp' > /dev/null 2>&1
}
if pcpp_importable; then
  echo "pcpp: $(PYTHONPATH="$ROOT/deps/pylib${PYTHONPATH:+:$PYTHONPATH}" python3 -c 'import pcpp; print("version", pcpp.version)')"
elif command -v pcpp > /dev/null 2>&1; then
  echo "pcpp: using the pcpp command on PATH"
elif python3 -m pip --version > /dev/null 2>&1; then
  echo "pcpp: installing pcpp $PCPP_VERSION into deps/pylib"
  python3 -m pip install --quiet --target deps/pylib "pcpp==$PCPP_VERSION" || die "error: pip could not install pcpp"
  pcpp_importable || die "error: pcpp was installed into deps/pylib but cannot be imported"
else
  echo "pcpp: MISSING, and python3 has no pip. Install it yourself, for example:"
  echo "        python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt"
  rc=1
fi

# ---- system tools (reported, not installed)
if command -v iverilog > /dev/null 2>&1 && command -v vvp > /dev/null 2>&1; then
  echo "iverilog: $(iverilog -V 2>&1 | head -n 1)"
else
  echo "iverilog: MISSING (Ubuntu/Debian: sudo apt install iverilog; macOS: brew install icarus-verilog)"
  rc=1
fi
if find_binutils 2> /dev/null; then
  case "$RV" in
    "$ROOT"/*) asm="${RV#"$ROOT/"}as" ;;
    /*)        asm="$(basename "$RV")as (outside the repository)" ;;
    *)         asm="${RV}as" ;;
  esac
  echo "binutils: $asm, $("${RV}as" --version | head -n 1)"
else
  echo "binutils: MISSING (Ubuntu/Debian: sudo apt install binutils-riscv64-unknown-elf;"
  echo "          macOS: brew install riscv64-elf-binutils; or set RISCV_PREFIX)"
  rc=1
fi
exit $rc
