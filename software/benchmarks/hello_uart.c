/* software/benchmarks/hello_uart.c
 *
 * First console program: prints a banner on the memory-mapped UART and
 * lights the LEDs, then reports through the usual result block.
 *
 * In simulation, tb_soc_uart decodes the serial line (with a shortened baud
 * divisor) and checks the exact banner string.  On the Zybo Z7-20 the same
 * binary drives the PMOD UART pin at 115200 8N1.
 */

#include "../runtime/fluxcore.h"
#include "../runtime/console.h"

int main(void) {
    uint32_t t0 = fluxcore_cycle_start();

    GPIO_LEDS = 0xAu;

    /* Banner emitted char-by-char: string literals live in IMEM (.rodata)
     * and cannot be loaded through the data port on this Harvard SoC. */
    fc_putchar('h'); fc_putchar('e'); fc_putchar('l'); fc_putchar('l');
    fc_putchar('o'); fc_putchar(' '); fc_putchar('f'); fc_putchar('r');
    fc_putchar('o'); fc_putchar('m'); fc_putchar(' '); fc_putchar('f');
    fc_putchar('l'); fc_putchar('u'); fc_putchar('x'); fc_putchar('c');
    fc_putchar('o'); fc_putchar('r'); fc_putchar('e'); fc_putchar('\n');

    GPIO_LEDS = 0x5u;

    uint32_t cycles = fluxcore_cycle_end(t0);

    /* checksum 0xC0 marks "console OK" for the result-block snoop */
    fluxcore_report(cycles, 0, 0xC0u, 0, 0, 0);
    return 0;
}
