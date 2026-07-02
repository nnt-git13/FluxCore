/* software/linker/fluxcore.ld
 *
 * FluxCore bare-metal linker script (Harvard architecture).
 *
 * Memory map:
 *   IMEM  0x0000_0000 .. 0x0000_3FFF  16 KB  instruction BRAM
 *   DMEM  0x0000_0000 .. 0x0000_1FFF   8 KB  data BRAM (separate bus)
 *   result block  0x0000_1FE0 .. 0x0000_1FFF  (fluxcore_report protocol)
 *   stack grows down from 0x0000_1FE0 (below the result block)
 *
 * Since IMEM and DMEM are separate physical memories on separate buses,
 * their VMAs overlap at 0x0.  The linker is told about IMEM only; the
 * stack pointer is initialised by crt0.S.  Writable global arrays must
 * either be BSS (zeroed by crt0) or be placed via a DMEM init hex file.
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 16K
}

/* Stack top — sits just below the 32-byte result block at 0x1FE0..0x1FFF
 * (see software/runtime/fluxcore.h) so fluxcore_report() and deep stacks
 * can never corrupt each other. crt0.S loads this into sp. */
_stack_top = 0x00001FE0;

SECTIONS {
    /* ------------------------------------------------------------------ */
    /* Code and read-only data — loaded into IMEM via $readmemh            */
    /* NOTE: rodata cannot be read via LW in this Harvard design.          */
    /*       Use only stack-local or BSS data in C benchmarks.             */
    /* ------------------------------------------------------------------ */
    .text : {
        KEEP(*(.text.start))   /* crt0 entry point first */
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
        _etext = .;
    } > IMEM

    /* ------------------------------------------------------------------ */
    /* BSS — zero-initialised globals cleared by crt0 in DMEM             */
    /* ------------------------------------------------------------------ */
    .bss (NOLOAD) : {
        _bss_start = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > IMEM   /* VMA used only for symbol export; cleared in DMEM by crt0 */

    /* Discard everything else */
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.debug*) }
}
