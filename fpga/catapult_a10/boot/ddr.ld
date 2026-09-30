OUTPUT_ARCH(aarch64)
ENTRY(ddr_entry)

SECTIONS
{
    . = 0x40000000;
    .text : {
        KEEP(*(.text.ddr))
        *(.text*)
        *(.rodata*)
    }
    .data : { *(.data*) }
    .bss  : { *(.bss*) }
}
