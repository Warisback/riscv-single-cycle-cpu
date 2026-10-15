#!/usr/bin/env bash
# run_iss_adv.sh: targeted checks of the reference model tools/iss.py.
#   usage: tools/run_iss_adv.sh [--seed N] [--n N]
# Runs tools/iss_adv_test.py with its GNU as cross-check required, and writes
# results/iss_adv.log. Exit code 0 only if every check passed.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2
need_binutils
mkdir -p results
start=$SECONDS
{
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)  tools/iss_adv_test.py"
  python3 tools/iss_adv_test.py --require-as "$@" 2>&1
  echo "# elapsed $((SECONDS - start)) s"
} | tee results/iss_adv.log
grep -q '^PASS' results/iss_adv.log
