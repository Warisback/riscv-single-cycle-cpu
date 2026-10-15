# smoke.S: the first program to run on the core.
#
# Only real RV32I instructions (no pseudo-instructions), so every source line
# is one trace line. It uses each kind of instruction once or more:
#   - ALU:         addi, add, sub, lui (add/sub use results of the lines before)
#   - loads:       lw of a data word, then bne on the loaded value
#   - store/load:  sw then lw of the same word, then beq on the value read back
#   - control:     a taken beq and a jal with a link, then the TOHOST store
# and checks that the data region of the hex image was loaded (lw of 'magic').
#
# Build: tools/asm2hex.sh sw/smoke.S build/smoke.hex
# Run:   python3 tools/iss.py --hex build/smoke.hex --trace build/smoke.trace
#
# Expected trace (worked out by hand from the encodings, then checked against
# the ISS and objdump; see results/sc_smoke.log):
#   | 00000000 00500093 x01=00000005
#   | 00000004 00700113 x02=00000007
#   | 00000008 002081b3 x03=0000000c
#   | 0000000c 40118233 x04=00000007
#   | 00000010 000082b7 x05=00008000
#   | 00000014 0002a303 x06=12345678
#   | 00000018 12345537 x10=12345000
#   | 0000001c 67850513 x10=12345678
#   | 00000020 02a31863
#   | 00000024 0032a223 m[00008004]&f=0000000c
#   | 00000028 0042a383 x07=0000000c
#   | 0000002c 00338463
#   | 00000034 008000ef x01=00000038
#   | 0000003c 00010437 x08=00010000
#   | 00000040 ff040413 x08=0000fff0
#   | 00000044 00100493 x09=00000001
#   | 00000048 00942023 m[0000fff0]&f=00000001

        .section .text.init, "ax", @progbits
        .globl _start
_start:
        addi x1, x0, 5          # 00  x1 = 5
        addi x2, x0, 7          # 04  x2 = 7
        add  x3, x1, x2         # 08  x3 = 12   (reads x1, x2 written by the two lines above)
        sub  x4, x3, x1         # 0c  x4 = 7    (reads x3 written one line above)
        lui  x5, 0x8            # 10  x5 = 0x00008000, start of .data (tools/link.ld)
        lw   x6, 0(x5)          # 14  x6 = magic = 0x12345678
        lui  x10, 0x12345       # 18  x10 = 0x12345000
        addi x10, x10, 0x678    # 1c  x10 = 0x12345678
        bne  x6, x10, fail      # 20  not taken when the image was loaded right
                                #     (compares the loaded word with the constant built above)
        sw   x3, 4(x5)          # 24  mem[0x8004] = 12
        lw   x7, 4(x5)          # 28  x7 = 12
        beq  x7, x3, ok         # 2c  taken (x7 comes from the lw just before)
        jal  x0, fail           # 30  skipped
ok:     jal  x1, done           # 34  x1 = 0x38 (return address), go to done
        jal  x0, fail           # 38  skipped
done:   lui  x8, 0x10           # 3c  x8 = 0x00010000
        addi x8, x8, -16        # 40  x8 = 0x0000fff0 = TOHOST
        addi x9, x0, 1          # 44  x9 = 1 means PASS
        sw   x9, 0(x8)          # 48  the run ends when this store retires
1:      jal  x0, 1b             # 4c  spin
fail:   lui  x8, 0x10           # 50
        addi x8, x8, -16        # 54  x8 = TOHOST
        addi x9, x0, 3          # 58  (1 << 1) | 1 means "test 1 failed"
        sw   x9, 0(x8)          # 5c
2:      jal  x0, 2b             # 60  spin

        .data
magic:  .word 0x12345678        # at 0x8000
slot:   .word 0                 # at 0x8004, written by the sw above
