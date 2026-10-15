/* link.ld: where every program for the single-cycle RV32I core lives in memory.
 *
 * The core has 64 KiB (0x0000-0xFFFF). imem and dmem both load the same image
 * (word 0 = address 0), so code and data just have to sit at different places:
 *
 *   0x0000 .. 0x7FFF   code   (.text.init first: _start must be at 0x0, the reset pc)
 *   0x8000 .. 0xFFEF   data   (.data, .rodata, .bss)
 *   0xFFF0             TOHOST (a store here ends the test; nothing is linked here)
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
  . = 0x00000000;
  .text : {
    *(.text.init)               /* riscv_test.h puts _start here */
    *(.text .text.*)
  }
  ASSERT(. <= 0x8000, "code is larger than 32 KiB and runs into the data region")

  . = 0x00008000;
  .data   : { *(.data .data.*)  *(.sdata .sdata.*) }
  .rodata : { *(.rodata .rodata.*) *(.srodata .srodata.*) }
  .bss    : { *(.sbss .sbss.*) *(.bss .bss.*) *(COMMON) }
  ASSERT(. <= 0xFFF0, "data runs into TOHOST (0xFFF0)")
}
