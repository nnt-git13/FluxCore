/* software/benchmarks/hello_cpi.c
 *
 * Smoke-test benchmark: measure CPI for a simple arithmetic loop.
 *
 * This is the first program run on FluxCore.  It runs a 1000-iteration
 * ADD loop and measures the elapsed cycles and retired instructions,
 * producing a CPI reading that validates the performance counter CSRs
 * and the overall software flow.
 *
 * Expected results (no cache, no stalls for this all-register loop):
 *   ~4 instructions per iteration (ADDI + ADDI + BLT + overhead)
 *   CPI ≈ 1.0  (fully pipelined, no hazards after pipeline fill)
 *
 * Actual CPI confirms:
 *   - mcycle / minstret counters are working
 *   - Toolchain, linker, crt0, and BRAM init flow are correct
 *   - The pipeline is not stalling unexpectedly
 */

#include "../runtime/fluxcore.h"

#define ITERATIONS 1000

int main(void) {
    volatile uint32_t sum = 0;

    uint32_t t0 = fluxcore_cycle_start();
    uint32_t i0 = fluxcore_rdinstret();

    /* Simple loop — compiler should produce: ADDI sum, ADDI i, BLT */
    for (int i = 0; i < ITERATIONS; i++) {
        sum += (uint32_t)i;
    }

    uint32_t cycles   = fluxcore_cycle_end(t0);
    uint32_t instrets = fluxcore_rdinstret() - i0;

    /* checksum: expected sum = 0+1+...+999 = 499500 = 0x7A0EC */
    fluxcore_report(cycles, instrets, (uint32_t)sum, ITERATIONS, 0, 0);

    return 0;
}
