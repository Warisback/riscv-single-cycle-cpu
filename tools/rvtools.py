"""rvtools.py: find the RISC-V GNU binutils, the same way tools/common.sh does.

Search order:
  1. $RISCV_PREFIX, if set: a prefix ending in '-', either a name on PATH or a
     path, for example /opt/riscv/bin/riscv64-unknown-elf-
  2. riscv64-unknown-elf-, riscv32-unknown-elf-, riscv64-elf- and
     riscv64-linux-gnu- on PATH, in that order
  3. a local, untracked copy under deps/rv (any layout with a bin/riscv*-as)

find_prefix() returns the prefix (so prefix + "as" is the assembler) or None.
link_resolved() links an object so that no relocation is left in it.
"""
import glob
import os
import shutil
import subprocess

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


def link_resolved(prefix, obj, elf, mabi="ilp32"):
    """Link obj on its own at 0x10000 and return the path of the linked file.

    Some binutils versions (2.42) leave branch and jump targets written as
    `.+N` for the linker even with -mno-relax. Linking resolves them; the
    offsets are PC-relative, so the load address does not change any word.
    """
    emulation = "elf64lriscv" if mabi.startswith("lp64") else "elf32lriscv"
    cmd = [prefix + "ld", "-m", emulation, "--no-relax", "-Ttext=0x10000", "-e", "0", "-o", elf, obj]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit(f"rvtools: {' '.join(cmd)} failed:\n{p.stderr}")
    return elf
