/* software/runtime/fluxcore.h
 *
 * Bare-metal runtime for FluxCore benchmarks.
 *
 * CSR addresses implemented in csr_unit.sv:
 *   0xB00  mcycle     cycle counter (lo 32 bits)
 *   0xB80  mcycleh    cycle counter (hi 32 bits)
 *   0xB02  minstret   retired-instruction counter (lo 32 bits)
 *   0xB82  minstreth  retired-instruction counter (hi 32 bits)
 *
 * NOTE: FluxCore uses machine-mode CSR addresses (0xBxx), not the
 * user-mode shadow registers (0xCxx).  Use the macros below instead of
 * the rdcycle/rdinstret pseudo-instructions (which target 0xC00/0xC02).
 *
 * Result reporting:
 *   fluxcore_report() writes a structured result block to a sentinel
 *   address in DMEM.  In simulation, the testbench reads this block
 *   after execution completes to extract cycles, retirements, and a
 *   workload checksum for correctness verification.
 */

#ifndef FLUXCORE_H
#define FLUXCORE_H

#include <stdint.h>

/* -----------------------------------------------------------------------
 * CSR read helpers
 * ----------------------------------------------------------------------- */

static inline uint32_t fluxcore_rdcycle(void) {
    uint32_t v;
    __asm__ volatile ("csrr %0, 0xB00" : "=r"(v));
    return v;
}

static inline uint32_t fluxcore_rdcycleh(void) {
    uint32_t v;
    __asm__ volatile ("csrr %0, 0xB80" : "=r"(v));
    return v;
}

static inline uint32_t fluxcore_rdinstret(void) {
    uint32_t v;
    __asm__ volatile ("csrr %0, 0xB02" : "=r"(v));
    return v;
}

static inline uint32_t fluxcore_rdinstreth(void) {
    uint32_t v;
    __asm__ volatile ("csrr %0, 0xB82" : "=r"(v));
    return v;
}

/* -----------------------------------------------------------------------
 * Timing helpers
 * ----------------------------------------------------------------------- */

static inline uint32_t fluxcore_cycle_start(void) {
    return fluxcore_rdcycle();
}

static inline uint32_t fluxcore_cycle_end(uint32_t start) {
    return fluxcore_rdcycle() - start;
}

/* -----------------------------------------------------------------------
 * Result block — written to top of DMEM for testbench/ILA readback
 *
 * Layout at RESULT_BASE (8 words = 32 bytes):
 *   [0]  MAGIC     0xF10CCAFE
 *   [1]  cycles    elapsed cycle count
 *   [2]  instrets  elapsed retired-instruction count
 *   [3]  checksum  benchmark-specific correctness value
 *   [4]  extra0    benchmark-specific (e.g. hit count, miss count)
 *   [5]  extra1
 *   [6]  extra2
 *   [7]  DONE      0x600DD00E — written last; testbench polls this
 * ----------------------------------------------------------------------- */

#define RESULT_BASE  ((volatile uint32_t *)0x00001FE0)
#define RESULT_MAGIC  0xF10CCAFE
#define RESULT_DONE   0x600DD00E

static inline void fluxcore_report(uint32_t cycles,
                                   uint32_t instrets,
                                   uint32_t checksum,
                                   uint32_t extra0,
                                   uint32_t extra1,
                                   uint32_t extra2) {
    RESULT_BASE[0] = RESULT_MAGIC;
    RESULT_BASE[1] = cycles;
    RESULT_BASE[2] = instrets;
    RESULT_BASE[3] = checksum;
    RESULT_BASE[4] = extra0;
    RESULT_BASE[5] = extra1;
    RESULT_BASE[6] = extra2;
    RESULT_BASE[7] = RESULT_DONE;   /* sentinel last */
}

#endif /* FLUXCORE_H */
