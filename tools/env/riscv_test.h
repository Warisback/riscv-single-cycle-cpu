/* riscv_test.h: a minimal test environment for running the official rv32ui
 * riscv-tests on this bare RV32I core.
 *
 * Upstream, riscv-tests take this file from the riscv-test-env repo (env/p/),
 * which sets up machine mode, CSRs and trap handlers and ends a test with ECALL.
 * Our core has no CSRs and no traps, so this replacement keeps the same macro
 * names (the test sources and test_macros.h are used unmodified) but ends a
 * test with a plain store to a magic address instead:
 *
 *   PASS: store 1                     to TOHOST (0xFFF0)
 *   FAIL: store (TESTNUM << 1) | 1    to TOHOST, so failing test number = value >> 1
 *
 * After the store the program spins on a jump-to-self; the testbench and the
 * ISS stop as soon as the store to TOHOST retires.
 *
 * Macro names and the TESTNUM << 1 | 1 fail code follow riscv-test-env
 * (BSD-3-Clause); no upstream code is copied.
 */
#ifndef SC_RISCV_TEST_H
#define SC_RISCV_TEST_H

#define TOHOST_ADDR 0xFFF0

/* gp (x3) holds the number of the test case that is running. */
#define TESTNUM gp

/* Upstream these pick RV32/RV64 user-mode setup. There is nothing to set up here. */
#define RVTEST_RV32U
#define RVTEST_RV64U

/* _start goes in .text.init, which tools/link.ld places at address 0x0. */
#define RVTEST_CODE_BEGIN                       \
        .section .text.init, "ax", @progbits;   \
        .globl _start;                          \
_start:

#define RVTEST_CODE_END

#define RVTEST_PASS                             \
        fence;                                  \
        li   TESTNUM, 1;                        \
        li   t0, TOHOST_ADDR;                   \
        sw   TESTNUM, 0(t0);                    \
1:      j    1b;

/* TESTNUM == 0 would encode as 1 (= PASS), so like upstream we spin instead
 * and let the timeout report the failure. No rv32ui test can get here with 0. */
#define RVTEST_FAIL                             \
        fence;                                  \
1:      beqz TESTNUM, 1b;                       \
        slli TESTNUM, TESTNUM, 1;               \
        ori  TESTNUM, TESTNUM, 1;               \
        li   t0, TOHOST_ADDR;                   \
        sw   TESTNUM, 0(t0);                    \
2:      j    2b;

#define RVTEST_DATA_BEGIN                       \
        .align 4;                               \
        .globl begin_signature;                 \
begin_signature:

#define RVTEST_DATA_END                         \
        .align 4;                               \
        .globl end_signature;                   \
end_signature:

#endif
