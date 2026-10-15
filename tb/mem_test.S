# mem_test.S: source of tb/mem_test.hex (fixture for mem_tb).
# 10 real RV32I instructions followed by 6 data words, 16 words = 64 bytes.
    .text
    .globl _start
_start:
    addi  x1, x0, 5          # word 0
    addi  x2, x0, 7          # word 1
    add   x3, x1, x2         # word 2
    lui   x4, 0x8            # word 3: x4 = 0x00008000 (data region)
    sw    x3, 0(x4)          # word 4
    lw    x5, 0(x4)          # word 5
    sb    x1, 1(x4)          # word 6
    sh    x2, 2(x4)          # word 7
    lbu   x6, 1(x4)          # word 8
spin:
    jal   x0, spin           # word 9: jump to itself (offset 0)
    .word 0x44332211         # word 10: byte 0x11 lives at the lowest address
    .word 0xdeadbeef         # word 11
    .word 0x80000000         # word 12
    .word 0xffffffff         # word 13
    .word 0x00000000         # word 14
    .word 0x0000ff00         # word 15
