/* software/benchmarks/fp_kernel.c
 *
 * RV32F demonstration kernel: exercises the floating-point unit end-to-end on
 * the full SoC (compiled with -march=rv32imf), proving that hard-float C runs
 * on FluxCore from a real toolchain, not just directed RTL testbenches.
 *
 * FluxCore is a Harvard machine: data loads (FLW) hit DMEM, but the compiler
 * places float *literals* in .rodata inside the .text/IMEM image, which the
 * data bus cannot read. So this kernel deliberately builds every FP value at
 * runtime with integer→float conversions (fcvt.s.w) seeded from `volatile`
 * ints — no float literal ever reaches .rodata, and no FLW-from-IMEM occurs.
 *
 * All intermediates are small integers exactly representable in float32, so the
 * result is exact and the checksum is unambiguous:
 *
 *   x  = 1+2+...+10        = 55.0     (fcvt.s.w + fadd.s, in a loop)
 *   xx = x * x             = 3025.0   (fmul.s)
 *   sq = sqrt(xx)          = 55.0     (fsqrt.s, iterative)
 *   dv = xx / x            = 55.0     (fdiv.s, iterative)
 *   fm = fma(x,x,x) / x    = 3080/55 = 56.0   (fmadd.s then fdiv.s)
 *   result = sq + dv + fm  = 166.0    -> float bits 0x43260000
 *
 * The checksum reported is the raw float32 bit pattern of the result;
 * extra0 is its integer truncation (166).
 */

#include "../runtime/fluxcore.h"

static inline float fsqrt_s(float x) {
    float r; __asm__("fsqrt.s %0, %1" : "=f"(r) : "f"(x)); return r;
}
static inline float fmadd_s(float a, float b, float c) {
    float r; __asm__("fmadd.s %0, %1, %2, %3" : "=f"(r) : "f"(a), "f"(b), "f"(c)); return r;
}
static inline uint32_t fbits(float x) {
    uint32_t b; __asm__("fmv.x.w %0, %1" : "=r"(b) : "f"(x)); return b;
}

int main(void) {
    /* Enable the FP unit: mstatus.FS = Initial (bit 13). The NOPs guarantee the
     * write has retired before the first FP instruction (fs_off is sampled
     * combinationally in decode). */
    __asm__ volatile("csrs mstatus, %0\n\t nop\n\t nop\n\t nop\n\t nop"
                     :: "r"(0x2000));

    uint32_t c0 = fluxcore_cycle_start();

    volatile int vn = 10;    /* volatile keeps everything off .rodata */
    volatile int vz = 0;

    float x = (float)vz;                 /* 0.0 via fcvt.s.w */
    for (int i = 1; i <= vn; i++)
        x += (float)i;                   /* 55.0  */
    float xx = x * x;                    /* 3025.0 (fmul.s) */
    float sq = fsqrt_s(xx);              /* 55.0   (fsqrt.s) */
    float dv = xx / x;                   /* 55.0   (fdiv.s)  */
    float fm = fmadd_s(x, x, x) / x;     /* 56.0   (fmadd.s + fdiv.s) */

    float result = sq + dv + fm;         /* 166.0 -> 0x43260000 */

    uint32_t cycles = fluxcore_cycle_end(c0);
    uint32_t instrets = fluxcore_rdinstret();

    fluxcore_report(cycles, instrets, fbits(result), (uint32_t)result, 0, 0);
    return 0;
}
