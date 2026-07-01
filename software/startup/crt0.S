/* software/startup/crt0.S
 *
 * FluxCore bare-metal reset vector.
 *
 * Runs from RESET_VECTOR (0x0000_0000) before any C code.
 * Assumptions:
 *   - IMEM holds .text starting at 0x0000_0000.
 *   - DMEM (separate Harvard bus) provides 8 KB of read/write data space.
 *   - Stack occupies the top of DMEM; grows downward from _stack_top.
 *   - BSS symbols (_bss_start, _bss_end) are exported by the linker script
 *     as byte addresses in the DMEM address space starting from 0x0.
 */

    .section .text.start
    .global  _start
    .type    _start, @function

_start:
    /* Disable all interrupts and clear mstatus */
    csrw    mstatus, zero

    /* Set stack pointer to top of DMEM (8 KB = 0x2000) */
    li      sp, 0x00002000

    /* Clear BSS in DMEM — byte addresses [_bss_start, _bss_end) */
    la      t0, _bss_start
    la      t1, _bss_end
.Lbss_loop:
    bge     t0, t1, .Lbss_done
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       .Lbss_loop
.Lbss_done:

    /* Zero all integer registers (except sp which is already set) */
    li      ra, 0
    li      gp, 0
    li      tp, 0
    li      t0, 0
    li      t1, 0
    li      t2, 0
    li      s0, 0
    li      s1, 0
    li      a0, 0
    li      a1, 0
    li      a2, 0
    li      a3, 0
    li      a4, 0
    li      a5, 0
    li      a6, 0
    li      a7, 0
    li      s2, 0
    li      s3, 0
    li      s4, 0
    li      s5, 0
    li      s6, 0
    li      s7, 0
    li      s8, 0
    li      s9, 0
    li      s10, 0
    li      s11, 0
    li      t3, 0
    li      t4, 0
    li      t5, 0
    li      t6, 0

    /* Jump to C entry point */
    call    main

    /* main returned — spin forever */
.Lhalt:
    j       .Lhalt

    .size _start, . - _start
