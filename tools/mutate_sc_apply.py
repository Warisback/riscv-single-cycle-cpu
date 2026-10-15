"""Literal text replacement for tools/mutate_sc.sh: apply.py FILE FROM TO. Exit 1 if FROM is not found exactly once."""
import sys
path, old, new = sys.argv[1:4]
s = open(path, encoding="utf-8").read()
if s.count(old) != 1:
    sys.exit(1)
open(path, "w", encoding="utf-8", newline="\n").write(s.replace(old, new))
