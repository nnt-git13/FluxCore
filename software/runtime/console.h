/* software/runtime/console.h
 *
 * Header-only console + MMIO map for the FluxCore SoC.
 *
 * Address map (rtl/top/soc_bus.sv):
 *   0x0200_0000  CLINT   msip +0x0, mtimecmp +0x4000/+0x4004, mtime +0xBFF8/+0xBFFC
 *   0x1000_0000  UART    TXDATA +0 (WO), STATUS +4 (RO, bit0 = busy)
 *   0x1000_1000  GPIO    LEDS +0 (RW, bits[3:0])
 *
 * The console is TX-only (fc_putchar polls STATUS.busy).  No printf: the
 * fc_put* helpers below cover strings, hex, and unsigned decimal, which is
 * everything the bring-up and benchmark programs need.
 */

#ifndef FLUXCORE_CONSOLE_H
#define FLUXCORE_CONSOLE_H

#include <stdint.h>

#define UART_TXDATA   (*(volatile uint32_t *)0x10000000u)
#define UART_STATUS   (*(volatile uint32_t *)0x10000004u)
#define GPIO_LEDS     (*(volatile uint32_t *)0x10001000u)

#define CLINT_MSIP      (*(volatile uint32_t *)0x02000000u)
#define CLINT_MTIMECMP  (*(volatile uint32_t *)0x02004000u)
#define CLINT_MTIMECMPH (*(volatile uint32_t *)0x02004004u)
#define CLINT_MTIME     (*(volatile uint32_t *)0x0200BFF8u)
#define CLINT_MTIMEH    (*(volatile uint32_t *)0x0200BFFCu)

static inline void fc_putchar(char c) {
    while (UART_STATUS & 1u) { }
    UART_TXDATA = (uint32_t)(uint8_t)c;
}

/* NOTE (Harvard memory): string literals are linked into IMEM (.rodata),
 * which data loads cannot reach — DMEM is a separate memory at the same
 * addresses.  fc_puts therefore only works for strings built at runtime
 * in stack/BSS memory.  For constant banners use fc_putchar sequences. */
static inline void fc_puts(const char *s) {
    while (*s) fc_putchar(*s++);
}

static inline void fc_puthex(uint32_t v) {
    fc_putchar('0'); fc_putchar('x');
    for (int i = 28; i >= 0; i -= 4) {
        uint32_t nib = (v >> i) & 0xFu;
        fc_putchar((char)(nib < 10 ? '0' + nib : 'a' + nib - 10));
    }
}

static inline void fc_putdec(uint32_t v) {
    char buf[10];
    int n = 0;
    if (v == 0) { fc_putchar('0'); return; }
    while (v) { buf[n++] = (char)('0' + v % 10u); v /= 10u; }
    while (n) fc_putchar(buf[--n]);
}

#endif /* FLUXCORE_CONSOLE_H */
