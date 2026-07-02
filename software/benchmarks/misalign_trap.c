/* software/benchmarks/misalign_trap.c
 *
 * Fetch-misalignment exception test: JALR to an address with bit1 set
 * (bit0 is masked per the spec) must raise EXC_INSTR_ADDR_MISALIGNED
 * on the jump itself, with mtval = the misaligned target and
 * mepc = the jump's PC.  The handler skips the jump and resumes.
 *
 * Result block: checksum = trap count (1), extra0 = mcause (0),
 *               extra1 = mtval (0x102).
 */

#include "../runtime/fluxcore.h"
#include "../runtime/console.h"

volatile uint32_t trap_count;
volatile uint32_t got_mcause;
volatile uint32_t got_mtval;

__attribute__((interrupt("machine")))
void trap_handler(void) {
    uint32_t c, v, e;
    __asm__ volatile ("csrr %0, mcause" : "=r"(c));
    __asm__ volatile ("csrr %0, mtval"  : "=r"(v));
    __asm__ volatile ("csrr %0, mepc"   : "=r"(e));
    got_mcause = c;
    got_mtval  = v;
    trap_count++;
    e += 4;                                   /* skip the faulting jump */
    __asm__ volatile ("csrw mepc, %0" :: "r"(e));
}

int main(void) {
    trap_count = 0;
    got_mcause = 0xFFFFFFFFu;
    got_mtval  = 0xFFFFFFFFu;

    __asm__ volatile ("csrw mtvec, %0" :: "r"((uint32_t)&trap_handler));

    /* JALR to 0x103: bit0 masked -> target 0x102, bit1 set -> misaligned */
    __asm__ volatile (
        "li   t0, 0x103\n\t"
        "jalr x0, t0, 0\n\t"
        ::: "t0");

    fluxcore_report(0, 0, trap_count, got_mcause, got_mtval, 0);
    return 0;
}
