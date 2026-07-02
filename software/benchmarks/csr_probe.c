/* software/benchmarks/csr_probe.c
 *
 * Counter-CSR diagnostic probe.
 *
 * Reports RAW mcycle read values (not just deltas) so the testbench log
 * shows exactly what each csrr returned:
 *
 *   cycles   = t1 - t0   (delta across a 100-iteration loop)
 *   instrets = b  - a    (delta across two back-to-back csrr reads)
 *   checksum = loop sum  (0+1+...+99 = 4950)
 *   extra0   = raw t0    (first read, before loop)
 *   extra1   = raw t1    (read after loop)
 *   extra2   = raw b     (second of the back-to-back pair)
 *
 * A healthy core shows extra0 < extra2 < extra1, all in the low thousands.
 */

#include "../runtime/fluxcore.h"

#define ITERATIONS 1000

int main(void) {
    volatile uint32_t sum = 0;

    /* Exactly mirrors hello_cpi's measurement structure. */
    uint32_t t0 = fluxcore_cycle_start();
    uint32_t i0 = fluxcore_rdinstret();

    for (int i = 0; i < ITERATIONS; i++) {
        sum += (uint32_t)i;
    }

    uint32_t c_end = fluxcore_rdcycle();
    uint32_t i_end = fluxcore_rdinstret();

    /* Raw values in cycles/instrets/extras; deltas recomputable offline. */
    fluxcore_report(t0, i0, (uint32_t)sum, c_end, i_end, c_end - t0);

    return 0;
}
