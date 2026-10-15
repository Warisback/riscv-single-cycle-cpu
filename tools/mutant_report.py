#!/usr/bin/env python3
"""mutant_report.py: show how each planted bug was caught, from the outputs that
tools/mutate_sc.sh leaves in build/mut/<name>/.

    usage: python3 tools/mutant_report.py [--out LOG] [--log MUTANTS_LOG] [NAME ...]
    e.g.   python3 tools/mutant_report.py
           python3 tools/mutant_report.py --out results/sc_mutants_part_detail.log x0_writable

Reads only. For every program run on a mutant it takes <prog>.out (the
testbench output) and <prog>.rtl.trace, and compares that trace with the ISS
trace of the same program: sw/riscv-tests/<prog>.trace for a riscv-test,
sw/gen/rand_<s>.iss.trace for a random program. It writes one row per mutant
to --out (default results/sc_mutants_detail.log) and prints the same table.

With no NAME, it reports every mutant listed in tools/mutate_sc.sh that has a
folder in build/mut/, in the order of that list. With --log (default
results/sc_mutants.log, or the log given), it also checks that its count of
failing programs agrees with the verdict rows of that log.
Exit code: 0, or 2 if there is nothing to report.
"""
import argparse
import datetime
import os
import re
import sys

sys.dont_write_bytecode = True   # leave no __pycache__ in tools/
from compare import read_trace  # noqa: E402  (tools/compare.py, same folder)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSERT_RE = re.compile(r"^ASSERTION FAILED at cycle \d+: (A[1-5])\b")
TOHOST_RE = re.compile(r"^TOHOST=([0-9a-fA-F]{8})")
VERDICT_RE = re.compile(r"^(\S+)\s+(KILLED|SURVIVED)\s+riscv-tests failing\s+(\d+)/\d+.*random failing\s+(\d+)/\d+")


def mutant_order():
    """Mutant names in the order of the MUTANTS list in tools/mutate_sc.sh."""
    with open(os.path.join(ROOT, "tools", "mutate_sc.sh")) as f:
        return re.findall(r'^"([A-Za-z0-9_]+)#', f.read(), re.M)


def program_key(name):
    """riscv-tests first (by name), then the random programs by seed."""
    m = re.fullmatch(r"rand_(\d+)", name)
    return (1, int(m.group(1)), "") if m else (0, 0, name)


def golden_trace(prog):
    if re.fullmatch(r"rand_\d+", prog):
        return os.path.join(ROOT, "sw", "gen", prog + ".iss.trace")
    return os.path.join(ROOT, "sw", "riscv-tests", prog + ".trace")


def report_mutant(mdir):
    progs = sorted((f[:-4] for f in os.listdir(mdir) if f.endswith(".out")), key=program_key)
    row = {"programs": len(progs), "failing": 0, "tohost": 0, "timeout": 0, "diff": 0,
           "assert_only": 0, "A1": 0, "A2": 0, "A3": 0, "A4": 0, "A5": 0}
    for prog in progs:
        with open(os.path.join(mdir, prog + ".out"), errors="replace") as f:
            lines = f.read().splitlines()
        passed = any(line.startswith("PASS") for line in lines)
        timeout = any(line.startswith("FAIL timeout") for line in lines)
        tohost = [m.group(1).lower() for m in map(TOHOST_RE.match, lines) if m]
        fired = {m.group(1) for m in map(ASSERT_RE.match, lines) if m}
        rtl = os.path.join(mdir, prog + ".rtl.trace")
        gold = golden_trace(prog)
        same = os.path.exists(rtl) and os.path.exists(gold) and read_trace(rtl) == read_trace(gold)
        wrong_tohost = bool(tohost) and tohost[-1] != "00000001"
        failing = not passed or not same
        row["failing"] += failing
        row["tohost"] += wrong_tohost
        row["timeout"] += timeout
        row["diff"] += not same
        row["assert_only"] += failing and same and not wrong_tohost and not timeout and bool(fired)
        for a in fired:
            row[a] += 1
    return row


def verdict_counts(path):
    """{mutant: riscv-tests failing + random failing} from a mutate_sc.sh log."""
    counts = {}
    if path and os.path.exists(path):
        with open(path) as f:
            for line in f:
                m = VERDICT_RE.match(line)
                if m:
                    counts[m.group(1)] = int(m.group(3)) + int(m.group(4))
    return counts


def main():
    ap = argparse.ArgumentParser(description="how each planted bug was caught")
    ap.add_argument("names", nargs="*", help="mutants to report (default: all in build/mut)")
    ap.add_argument("--out", default="results/sc_mutants_detail.log", help="log to write")
    ap.add_argument("--log", default="results/sc_mutants.log",
                    help="mutate_sc.sh log whose failing counts must agree")
    ap.add_argument("--mutdir", default="build/mut", help="where mutate_sc.sh left its runs")
    args = ap.parse_args()

    mutdir = os.path.join(ROOT, args.mutdir)
    names = args.names or [n for n in mutant_order() if os.path.isdir(os.path.join(mutdir, n))]
    names = [n for n in names if os.path.isdir(os.path.join(mutdir, n))]
    if not names:
        print(f"mutant_report: no mutant runs in {args.mutdir}/ (run tools/mutate_sc.sh first)",
              file=sys.stderr)
        return 2

    rows = {n: report_mutant(os.path.join(mutdir, n)) for n in names}
    expected = verdict_counts(os.path.join(ROOT, args.log))

    out = []
    out.append(f"# {datetime.datetime.now(datetime.timezone.utc):%Y-%m-%dT%H:%M:%SZ}  "
               f"how each planted bug was caught (tools/mutant_report.py)")
    out.append(f"# From the runs that tools/mutate_sc.sh left in {args.mutdir}/<name>/: each program's")
    out.append("# testbench output (<prog>.out) and RTL trace, compared with the ISS trace of the program.")
    out.append("#   programs     programs run on the mutant (riscv-tests and random programs)")
    out.append("#   failing      programs that failed in any way (the count in the mutate_sc.sh log)")
    out.append("#   TOHOST!=1    the program stored a value other than 1 to TOHOST: its own check failed")
    out.append("#   timeout      no store to TOHOST before the cycle limit (+maxcycles)")
    out.append("#   trace-diff   the RTL trace differs from the ISS trace")
    out.append("#   assert-only  failed only because an assertion fired (TOHOST = 1, traces identical)")
    out.append("#   A1 .. A5     programs in which that assertion fired at least once (the testbench")
    out.append("#                prints the first 20 assertion failures of a program)")
    out.append(f"{'mutant':<18} {'programs':>8} {'failing':>8} {'TOHOST!=1':>10} {'timeout':>8} "
               f"{'trace-diff':>11} {'assert-only':>12} {'A1':>4} {'A2':>4} {'A3':>4} {'A4':>4} {'A5':>4}")
    for n in names:
        r = rows[n]
        out.append(f"{n:<18} {r['programs']:>8} {r['failing']:>8} {r['tohost']:>10} {r['timeout']:>8} "
                   f"{r['diff']:>11} {r['assert_only']:>12} {r['A1']:>4} {r['A2']:>4} {r['A3']:>4} "
                   f"{r['A4']:>4} {r['A5']:>4}")
    checked = [n for n in names if n in expected]
    bad = [n for n in checked if expected[n] != rows[n]["failing"]]
    if bad:
        for n in bad:
            out.append(f"# MISMATCH {n}: {rows[n]['failing']} failing here, {expected[n]} in {args.log}")
    elif checked:
        out.append(f"# The failing counts agree with {args.log} for all {len(checked)} mutants.")
    else:
        out.append(f"# No verdict rows found in {args.log} to check the failing counts against.")

    text = "\n".join(out) + "\n"
    os.makedirs(os.path.dirname(os.path.join(ROOT, args.out)), exist_ok=True)
    with open(os.path.join(ROOT, args.out), "w", newline="\n") as f:
        f.write(text)
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
