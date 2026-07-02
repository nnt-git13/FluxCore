/* software/benchmarks/board_hello.c
 *
 * Zybo Z7-20 bring-up program — exercises UART, GPIO, CSRs, and the CLINT
 * timer interrupt on real silicon in one binary.
 *
 * Behaviour:
 *   1. Prints a banner + mcycle + mtime over the PMOD UART (115200 8N1).
 *   2. Arms a periodic CLINT timer interrupt (~2 Hz at 50 MHz).
 *   3. The handler advances a binary counter on LD0..LD3 and prints a tick.
 *
 * Expected on the board: banner once, then LEDs counting in binary with a
 * "tick <n>" line per step, forever.
 */

#include "../runtime/fluxcore.h"
#include "../runtime/console.h"

#define TICK_PERIOD 25000000u   /* 0.5 s at the 50 MHz core clock */

volatile uint32_t tick_count;

static void banner(void) {
    /* char-by-char: string literals are unreachable IMEM rodata (Harvard) */
    fc_putchar('F'); fc_putchar('l'); fc_putchar('u'); fc_putchar('x');
    fc_putchar('C'); fc_putchar('o'); fc_putchar('r'); fc_putchar('e');
    fc_putchar(' '); fc_putchar('u'); fc_putchar('p'); fc_putchar('\n');
}

__attribute__((interrupt("machine")))
void trap_handler(void) {
    tick_count++;
    GPIO_LEDS = tick_count & 0xFu;
    fc_putchar('t'); fc_putchar('i'); fc_putchar('c'); fc_putchar('k');
    fc_putchar(' ');
    fc_putdec(tick_count);
    fc_putchar('\n');
    CLINT_MTIMECMP = CLINT_MTIME + TICK_PERIOD;
}

int main(void) {
    tick_count = 0;
    GPIO_LEDS  = 0xFu;

    banner();
    fc_putchar('m'); fc_putchar('c'); fc_putchar('y'); fc_putchar('c');
    fc_putchar('='); fc_puthex(fluxcore_rdcycle()); fc_putchar('\n');

    __asm__ volatile ("csrw mtvec, %0" :: "r"((uint32_t)&trap_handler));
    CLINT_MTIMECMPH = 0;
    CLINT_MTIMECMP  = CLINT_MTIME + TICK_PERIOD;
    __asm__ volatile ("csrs mie, %0"     :: "r"(0x80u));
    __asm__ volatile ("csrs mstatus, %0" :: "r"(0x8u));

    for (;;) { }   /* everything else happens in the handler */
    return 0;
}
