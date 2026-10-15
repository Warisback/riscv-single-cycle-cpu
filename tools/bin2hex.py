#!/usr/bin/env python3
"""bin2hex.py: turn a raw binary image into a $readmemh file.

    usage: python3 tools/bin2hex.py <in.bin> <out.hex> [--words N]

<in.bin> comes from `objcopy -O binary`: byte 0 of the file is address 0.
<out.hex> has one 32-bit word per line, 8 lower-case hex digits, word 0 first.
RISC-V is little-endian here (spec section 2.6): the byte at the lowest address
is the least-significant byte of the word.

The image is padded with zero bytes to a whole number of words, and with
--words N to exactly N words. asm2hex.sh uses --words 16384 (all 64 KiB):
Icarus' $readmemh leaves words past the end of a short file as X (and warns),
while the ISS would see 0. A full-size image gives both the same memory.
"""
import argparse
import sys

MEM_BYTES = 64 * 1024   # the core's memory size (docs/DESIGN.md)


def main():
    ap = argparse.ArgumentParser(description="binary image -> $readmemh hex")
    ap.add_argument("bin_file")
    ap.add_argument("hex_file")
    ap.add_argument("--words", type=int, default=0,
                    help="pad with zero words up to this many words")
    args = ap.parse_args()

    with open(args.bin_file, "rb") as f:
        image = f.read()
    if len(image) > MEM_BYTES:
        sys.exit(f"bin2hex: {args.bin_file} is {len(image)} bytes, memory is only {MEM_BYTES}")

    # Pad to a multiple of 4 bytes so the last word is complete.
    if len(image) % 4 != 0:
        image += bytes(4 - len(image) % 4)
    # Optionally pad to a fixed size.
    if args.words:
        if len(image) > 4 * args.words:
            sys.exit(f"bin2hex: image has {len(image) // 4} words, more than --words {args.words}")
        image += bytes(4 * args.words - len(image))

    with open(args.hex_file, "w", newline="\n") as f:     # LF line ends on any OS
        for addr in range(0, len(image), 4):
            word = int.from_bytes(image[addr:addr + 4], "little")
            f.write(f"{word:08x}\n")


if __name__ == "__main__":
    main()
