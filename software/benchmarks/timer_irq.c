/* software/benchmarks/timer_irq.c
 *
 * Machine-timer interrupt test: arms the CLINT timer, takes IRQ_TARGET
 * interrupts through a real M-mode trap handler, and reports.
 *
 * Checks the full interrupt path end-to-end:
 *   CLINT mtip → csr_unit mip/mie/mstatus.MIE → EX-stage injection →
 *   trap to mtvec → mepc/mcause → handler → mret → resume.
 *
 * Result block:
 *   checksum = number of interrupts taken (expected IRQ_TARGET)
 *   extra0   = last observed mcause (expected 0x80000007, machine timer)
 *   extra1   = mstatus.MIE restored after the run (expected 8)
 */

#include "../runtime/fluxcore.h"
#include "../runtime/console.h"

#define IRQ_TARGET 3u
#define PERIOD     200u   /* mtime ticks between interrupts */

volatile uint32_t irq_count;
volatile uint32_t last_mcause;

__attribute__((interrupt("machine")))
void trap_handler(void) {
    uint32_t cause;
    __asm__ volatile ("csrr %0, mcause" : "=r"(cause));
    last_mcause = cause;
    irq_count++;
    /* Re-arm (level-sensitive mtip clears once mtimecmp > mtime) */
    if (irq_count < IRQ_TARGET)
        CLINT_MTIMECMP = CLINT_MTIME + PERIOD;
    else
        CLINT_MTIMECMPH = 0xFFFFFFFFu;   /* park the timer */
}

int main(void) {
    uint32_t t0 = fluxcore_cycle_start();
    uint32_t i0 = fluxcore_rdinstret();

    irq_count   = 0;
    last_mcause = 0;

    /* Trap vector (direct mode) */
    __asm__ volatile ("csrw mtvec, %0" :: "r"((uint32_t)&trap_handler));

    /* Arm the timer: high word first (parks), then the low word target */
    CLINT_MTIMECMPH = 0;
    CLINT_MTIMECMP  = CLINT_MTIME + PERIOD;

    /* Enable machine timer interrupt + global enable */
    __asm__ volatile ("csrs mie, %0"     :: "r"(0x80u));   /* MTIE */
    __asm__ volatile ("csrs mstatus, %0" :: "r"(0x8u));    /* MIE  */

    while (irq_count < IRQ_TARGET) { }

    uint32_t mstatus_v;
    __asm__ volatile ("csrr %0, mstatus" : "=r"(mstatus_v));

    uint32_t cycles   = fluxcore_cycle_end(t0);
    uint32_t instrets = fluxcore_rdinstret() - i0;

    fluxcore_report(cycles, instrets, irq_count,
                    last_mcause, mstatus_v & 0x8u, 0);
    return 0;
}
