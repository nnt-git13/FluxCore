/* software/benchmarks/xflux_kernel.c
 *
 * XFlux custom-instruction benchmark: first program to execute XFlux ops
 * from compiled C (via the .insn intrinsics in runtime/xflux.h).
 *
 * Workload: the SpMV-flavored indexed-gather reduction
 *     acc += clamp(|x[idx[j]]|, lo, hi)
 * run twice over the same data:
 *   scalar : shifts/loads/branches only (baseline RV32IM)
 *   xflux  : XLIDX (fused indexed load) + XABS + XMIN + XMAX
 * and verifies both produce identical checksums.
 *
 * Result block:
 *   checksum = xflux-path checksum (must equal scalar; else 0 reported)
 *   extra0   = scalar-path cycles      extra1 = xflux-path cycles
 *   extra2   = xflux_clz(1) sanity (expected 31)
 */

#include "../runtime/fluxcore.h"
#include "../runtime/xflux.h"

#define N 64

static uint32_t x_arr[N];     /* BSS -> DMEM */
static uint32_t idx[N];

int main(void) {
    for (uint32_t j = 0; j < N; j++) {
        x_arr[j] = (j * 2654435761u) ^ (j << 3);   /* mixed-sign patterns */
        idx[j]   = (j * 7u) & (N - 1);
    }

    /* -------- scalar baseline -------- */
    uint32_t t0 = fluxcore_rdcycle();
    int32_t acc_s = 0;
    for (uint32_t j = 0; j < N; j++) {
        int32_t v = (int32_t)x_arr[idx[j]];
        if (v < 0) v = -v;
        if (v > 1000) v = 1000;
        if (v < 10)   v = 10;
        acc_s += v;
    }
    uint32_t scalar_cycles = fluxcore_rdcycle() - t0;

    /* -------- XFlux path -------- */
    t0 = fluxcore_rdcycle();
    int32_t acc_x = 0;
    for (uint32_t j = 0; j < N; j++) {
        int32_t v = (int32_t)xflux_lidx(x_arr, idx[j]);
        v = xflux_abs(v);
        v = xflux_min(v, 1000);
        v = xflux_max(v, 10);
        acc_x += v;
    }
    uint32_t xflux_cycles = fluxcore_rdcycle() - t0;

    uint32_t checksum = (acc_s == acc_x) ? (uint32_t)acc_x : 0u;

    fluxcore_report(fluxcore_rdcycle(), fluxcore_rdinstret(),
                    checksum, scalar_cycles, xflux_cycles, xflux_clz(1));
    return 0;
}
