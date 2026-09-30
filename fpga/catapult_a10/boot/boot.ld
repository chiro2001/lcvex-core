OUTPUT_ARCH(aarch64)
ENTRY(_start)

MEMORY
{
    BRAM (rwx) : ORIGIN = 0x00000000, LENGTH = 0x00010000
}

SECTIONS
{
    . = ORIGIN(BRAM);
    .text : ALIGN(4)
    {
        KEEP(*(.text.boot))
        *(.text*)
    } > BRAM

    .rodata : ALIGN(4)
    {
        *(.rodata*)
    } > BRAM

    .data : ALIGN(4)
    {
        *(.data*)
    } > BRAM

    .bss (NOLOAD) : ALIGN(4)
    {
        *(.bss*)
        *(COMMON)
    } > BRAM

    __image_end = .;
    __stack_limit = ORIGIN(BRAM) + 0xF000;
    __stack_top = ORIGIN(BRAM) + LENGTH(BRAM);

    ASSERT(__image_end <= __stack_limit,
           "B25 boot image overlaps reserved stack [0xF000,0x10000)")
    ASSERT(__stack_top == 0x10000,
           "B25 stack top must remain at 0x00010000")
}
