#!/usr/bin/env python3
"""mem_adv_gen.py: raw binary images for the adversarial memory test (mem_adv_tb).

    usage: python3 tools/mem_adv_gen.py <outdir>

Writes two files laid out like `objcopy -O binary` output (file byte k is
memory byte k):
  full.bin  65533 seeded random bytes: fills all 64 KiB except the last 3
            bytes, so tools/bin2hex.py must pad the top word with zeros.
  part.bin  4099 seeded random bytes: an odd length (padding again) and
            most of memory is left to the RTL's zero initialisation.
The testbench reads these bytes itself with $fgetc as its oracle, so the
check does not depend on bin2hex.py or $readmemh being right.
"""
import os
import random
import sys


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: mem_adv_gen.py <outdir>")
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    rnd = random.Random(20260120)   # fixed seed: the same images every run
    for name, size in (("full.bin", 65533), ("part.bin", 4099)):
        data = bytes(rnd.getrandbits(8) for _ in range(size))
        with open(os.path.join(out, name), "wb") as f:
            f.write(data)
        print(f"mem_adv_gen: {name} {size} bytes")


if __name__ == "__main__":
    main()
