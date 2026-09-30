/* LCVEX 裸机链接脚本：代码/数据放 0x44000000（SRAM 基址）。 */

ENTRY(_start)
MEMORY
{
    ram (rwx) : ORIGIN = 0x44000000, LENGTH = 1M
}

SECTIONS
{
    .text : { *(.text.startup) *(.text*) } > ram
    .rodata : { *(.rodata*) } > ram
    .data : { *(.data*) } > ram
    .bss : { *(.bss*) } > ram
    . = ALIGN(16);
    _stack_top = 0x44080000;
}
