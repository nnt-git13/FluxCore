/* software/runtime/xflux.h
 *
 * C intrinsics for the XFlux custom instructions (CUSTOM_0 opcode 0x0B,
 * funct7 = 0).  Emitted with GCC's .insn directive, so no custom toolchain
 * ("FluxCC") is required — plain riscv64-unknown-elf-gcc works.
 *
 * Implemented ops (rtl/decode/decoder.sv, rtl/execution/alu.sv):
 *   funct3 000  XLIDX rd,rs1,rs2   rd = MEM[rs1 + (rs2 << 2)]  indexed load
 *   funct3 001  XABS  rd,rs1       rd = |rs1|                  (signed)
 *   funct3 010  XMIN  rd,rs1,rs2   rd = signed min
 *   funct3 011  XMAX  rd,rs1,rs2   rd = signed max
 *   funct3 100  XCLZ  rd,rs1       rd = count leading zeros
 *
 * XMACC (funct3 101) is intentionally unimplemented: it needs a third
 * register read port, which conflicts with the 2R1W register file.
 */

#ifndef FLUXCORE_XFLUX_H
#define FLUXCORE_XFLUX_H

#include <stdint.h>

/* rd = MEM[rs1 + (rs2 << 2)] — one-instruction indexed word load,
 * the CSR SpMV inner-loop fusion (x[col_idx[j]]). */
static inline uint32_t xflux_lidx(const uint32_t *base, uint32_t idx) {
    uint32_t rd;
    __asm__ volatile (".insn r 0x0b, 0x0, 0x00, %0, %1, %2"
                      : "=r"(rd) : "r"(base), "r"(idx) : "memory");
    return rd;
}

static inline int32_t xflux_abs(int32_t a) {
    int32_t rd;
    __asm__ (".insn r 0x0b, 0x1, 0x00, %0, %1, x0" : "=r"(rd) : "r"(a));
    return rd;
}

static inline int32_t xflux_min(int32_t a, int32_t b) {
    int32_t rd;
    __asm__ (".insn r 0x0b, 0x2, 0x00, %0, %1, %2" : "=r"(rd) : "r"(a), "r"(b));
    return rd;
}

static inline int32_t xflux_max(int32_t a, int32_t b) {
    int32_t rd;
    __asm__ (".insn r 0x0b, 0x3, 0x00, %0, %1, %2" : "=r"(rd) : "r"(a), "r"(b));
    return rd;
}

static inline uint32_t xflux_clz(uint32_t a) {
    uint32_t rd;
    __asm__ (".insn r 0x0b, 0x4, 0x00, %0, %1, x0" : "=r"(rd) : "r"(a));
    return rd;
}

#endif /* FLUXCORE_XFLUX_H */
