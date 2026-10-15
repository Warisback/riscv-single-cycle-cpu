#!/usr/bin/env bash
# tool_versions.sh: record the version of every tool the checks use.
#   usage: tools/tool_versions.sh
# Log: results/tool_versions.log. A tool that is missing is listed as "not found"
# (this script only reports, it does not stop). The assembler line names the
# binutils that tools/common.sh picks: a repository-relative path if it is a
# local copy under deps/, and only the file name if it is elsewhere on disk.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2
mkdir -p results

row() { printf '%-24s %s\n' "$1" "$2"; }
# ver <command> [args...]: first line of the command's output, or "not found"
ver() {
  if command -v "$1" > /dev/null 2>&1; then
    "$@" 2>&1 | head -n 1
  else
    echo "not found"
  fi
}

if [ -f /etc/os-release ]; then
  os="$(. /etc/os-release && echo "${PRETTY_NAME:-Linux}")"
elif command -v sw_vers > /dev/null 2>&1; then
  os="macOS $(sw_vers -productVersion)"
else
  os="$(uname -s)"
fi

if python3 -c 'import pcpp' > /dev/null 2>&1; then
  pcpp_ver="$(python3 -c 'import pcpp; print("pcpp", pcpp.__version__)' 2>&1)"
else
  pcpp_ver="$(ver pcpp --version)"
fi

{
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)  tool versions"
  row "os:" "$os, kernel $(uname -r)"
  row "bash:" "$(ver bash --version)"
  row "iverilog -V:" "$(ver iverilog -V)"
  row "vvp -V:" "$(ver vvp -V)"
  if find_binutils; then
    # never write an absolute path outside the repository into the log
    case "$RV" in
      "$ROOT"/*) asm="${RV#"$ROOT/"}as" ;;
      /*)        asm="$(basename "$RV")as (outside the repository)" ;;
      *)         asm="${RV}as" ;;
    esac
    row "assembler:" "$asm"
    row "as --version:" "$(ver "${RV}as" --version)"
    row "ld --version:" "$(ver "${RV}ld" --version)"
    row "objcopy --version:" "$(ver "${RV}objcopy" --version)"
    row "objdump --version:" "$(ver "${RV}objdump" --version)"
  else
    row "RISC-V binutils:" "not found"
  fi
  row "python3 --version:" "$(ver python3 --version)"
  row "pcpp:" "$pcpp_ver"
  row "riscv-tests commit:" "$(head -n 1 deps/riscv-tests/COMMIT 2> /dev/null || echo 'not fetched (run tools/setup_deps.sh)')"
  if command -v gtkwave > /dev/null 2>&1; then
    row "gtkwave --version:" "$(ver gtkwave --version) (viewer only)"
  fi
} | tee results/tool_versions.log
