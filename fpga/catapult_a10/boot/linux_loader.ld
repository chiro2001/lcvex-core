OUTPUT_ARCH(aarch64)
ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS(5); /* read + execute */
    data PT_LOAD FLAGS(6); /* read + write */
}

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
    } > BRAM :text

    .rodata : ALIGN(8)
    {
        *(.rodata*)
    } > BRAM :text

    .data : ALIGN(8)
    {
        *(.data*)
    } > BRAM :data

    .bss (NOLOAD) : ALIGN(8)
    {
        *(.bss*)
        *(COMMON)
    } > BRAM :data

    __loader_image_end = .;
    __stack_limit = ORIGIN(BRAM) + 0xF000;
    __stack_top = ORIGIN(BRAM) + LENGTH(BRAM);

    ASSERT(__loader_image_end <= __stack_limit,
           "Linux loader image overlaps its reserved BRAM stack [0xF000,0x10000)")
    ASSERT(__loader_image_end <= ORIGIN(BRAM) + LENGTH(BRAM),
           "Linux loader exceeds the 64 KiB BRAM")
    ASSERT(__stack_top == 0x00010000,
           "Linux loader stack top must remain at 0x00010000")
}
