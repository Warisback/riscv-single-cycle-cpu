#!/usr/bin/env python3
"""compare.py: compare two instruction traces line by line.

    usage: python3 tools/compare.py A B [--context N]
    e.g.   python3 tools/compare.py sw/gen/rand_7.trace build/rand_7.rtl.trace

A and B are traces in the docs/DESIGN.md format, one line per retired instruction:
    <pc> <instr>[ x<rd>=<value>][ m[<word addr>]&<be>=<lane data>]
Usually A is the golden trace from the ISS and B the RTL trace.

Prints exactly one summary line starting with PASS or FAIL. On a mismatch it
shows the lines just before it (the same in both), both versions of the first
differing line, and which fields differ. Exit code 0 only for PASS.
"""
import argparse
import sys


def read_trace(path):
    with open(path) as f:
        # rstrip: ignore trailing spaces and CR (a trace written on Windows)
        return [line.rstrip() for line in f if line.strip()]


def fields(line):
    """Split a trace line into named parts, so a mismatch can say what differs."""
    parts = line.split()
    out = {"pc": parts[0] if parts else "", "instr": parts[1] if len(parts) > 1 else "",
           "reg write": "-", "store": "-"}
    for p in parts[2:]:
        if p.startswith("x"):
            out["reg write"] = p
        elif p.startswith("m["):
            out["store"] = p
        else:
            out.setdefault("other", p)
    return out


def main():
    ap = argparse.ArgumentParser(description="compare two instruction traces")
    ap.add_argument("a", help="expected trace (usually the ISS)")
    ap.add_argument("b", help="trace to check (usually the RTL)")
    ap.add_argument("--context", type=int, default=3, help="matching lines to show before a mismatch")
    args = ap.parse_args()

    a = read_trace(args.a)
    b = read_trace(args.b)

    for i in range(min(len(a), len(b))):
        if a[i] != b[i]:
            print(f"first mismatch at line {i + 1} (instruction {i + 1} to retire):")
            for k in range(max(0, i - args.context), i):
                print(f"   {k + 1:6d}   {a[k]}")
            print(f"A  {i + 1:6d}   {a[i]}")
            print(f"B  {i + 1:6d}   {b[i]}")
            fa, fb = fields(a[i]), fields(b[i])
            for key in fa:
                if fa.get(key) != fb.get(key):
                    print(f"   {key:<10} A: {fa.get(key)}   B: {fb.get(key)}")
            for k in range(i + 1, min(i + 1 + args.context, len(a), len(b))):
                print(f"   next     A: {a[k]}")
                print(f"            B: {b[k]}")
            print(f"FAIL traces differ at line {i + 1}: A={args.a} B={args.b}")
            return 1

    if len(a) != len(b):
        n = min(len(a), len(b))
        longer, name = (a, "A") if len(a) > len(b) else (b, "B")
        print(f"the first {n} lines match, then only {name} goes on:")
        for k in range(max(0, n - args.context), n):
            print(f"   {k + 1:6d}   {a[k]}")
        for k in range(n, min(n + args.context, len(longer))):
            print(f"{name}  {k + 1:6d}   {longer[k]}")
        print(f"FAIL trace lengths differ: A has {len(a)} lines, B has {len(b)} lines")
        return 1

    print(f"PASS traces match: {len(a)} lines")
    return 0


if __name__ == "__main__":
    sys.exit(main())
