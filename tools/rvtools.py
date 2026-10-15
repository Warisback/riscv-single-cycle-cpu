"""rvtools.py: find the RISC-V GNU binutils, the same way tools/common.sh does.

Search order:
  1. $RISCV_PREFIX, if set: a prefix ending in '-', either a name on PATH or a
     path, for example /opt/riscv/bin/riscv64-unknown-elf-
  2. riscv64-unknown-elf-, riscv32-unknown-elf-, riscv64-elf- and
     riscv64-linux-gnu- on PATH, in that order
  3. a local, untracked copy under deps/rv (any layout with a bin/riscv*-as)

find_prefix() returns the prefix (so prefix + "as" is the assembler) or None.
"""
import glob
import os
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CANDIDATES = ("riscv64-unknown-elf-", "riscv32-unknown-elf-", "riscv64-elf-", "riscv64-linux-gnu-")
INSTALL_HINT = ("RISC-V GNU binutils not found (tried $RISCV_PREFIX, then riscv64-unknown-elf-as, "
                "riscv32-unknown-elf-as, riscv64-elf-as and riscv64-linux-gnu-as on PATH, then deps/rv).\n"
                "  Ubuntu/Debian: sudo apt install binutils-riscv64-unknown-elf\n"
                "  macOS:         brew install riscv64-elf-binutils\n"
                "  Elsewhere:     set RISCV_PREFIX, e.g. RISCV_PREFIX=/opt/riscv/bin/riscv64-unknown-elf-")


def _exists(prefix):
    tool = prefix + "as"
    return os.path.isfile(tool) or shutil.which(tool) is not None


def find_prefix():
    env = os.environ.get("RISCV_PREFIX")
    if env:
        return env if _exists(env) else None
    for prefix in CANDIDATES:
        if shutil.which(prefix + "as"):
            return prefix
    hits = sorted(glob.glob(os.path.join(ROOT, "deps", "rv", "**", "bin", "riscv*-as"), recursive=True))
    return hits[0][:-2] if hits else None
