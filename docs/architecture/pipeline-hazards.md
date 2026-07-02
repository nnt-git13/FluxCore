# FluxCore Pipeline Hazards — Bypassing and Stall Logic

Reference mapping: Patterson & Hennessy, *Computer Organization and Design*
(4th ed.) §4.7–4.8, and Hennessy & Patterson, *Computer Architecture: A
Quantitative Approach* (6th ed.) Appendix C.2–C.3.  This document is the
audit record that FluxCore implements the full textbook forwarding/stall
set for a five-stage in-order pipeline, plus the cases the textbooks leave
as exercises (CSR reads, long-latency units, cache stalls).

## Data hazards — forwarding paths (COD Fig. 4.54 / H&P Fig. C.27)

Implemented in `rtl/core/forwarding_unit.sv`; operands are muxed *before*
the EX stage consumes them (`id_ex_fwd_s` in `fluxcore_top.sv`).

| Producer stage | Consumer | Value forwarded | Notes |
|---|---|---|---|
| EX/MEM (1-cycle stale) | EX rs1/rs2 | mirror of mem_stage's wb_src mux: `alu_result` (ALU/LUI/AUIPC), `pc+4` (JAL/JALR), `csr_rdata` (CSR reads) | The CSR arm is the 2026-07-02 fix: forwarding `alu_result` for a csrr forwards the sign-extended CSR address. Regressed by `tb_forwarding_unit` (`t_em_csr`) and end-to-end by `sim-hello-cpi`. |
| MEM/WB (2-cycle stale) | EX rs1/rs2 | `mem_wb_rd_data_i` — the canonical WB value incl. live-BRAM load data | EX/MEM wins on double match (newer producer, textbook priority rule). |
| WB → ID (same cycle) | ID register read | write-first bypass inside `regfile.sv` | Closes the 3-instruction gap without a third forwarding mux. |

x0 never forwards (gated `rd != 0`); illegal instructions never forward
(gated `decoded.legal`).

## Data hazards — stalls

| Hazard | Detection | Action | Cost |
|---|---|---|---|
| Load-use (COD §4.7) | load in EX, dependent in ID | hold IF+ID, bubble into EX | 1 cycle, then MEM/WB path forwards |
| XLIDX-use | same as load-use (`is_load=1`) | same | 1 cycle |
| CSR-after-CSR-write (same CSR) | CSR write in EX or MEM, CSR read in ID | hold IF+ID, bubble | 1–2 cycles (write commits at end of MEM); reads-without-write (`CSR_NOP`) don't stall |
| DIV busy | `mul_div_unit.busy_o` | freeze all five stages | 33 cycles per DIV |
| D-cache miss (`USE_DCACHE=1`) | `dmem_stall` | freeze all five stages | 1 cycle per miss (write-through, no-allocate stores) |

MUL is single-cycle combinational — no stall, forwarded like an ALU result.

## Control hazards (COD §4.8)

Branches and jumps resolve in EX from the *combinational* stage output, so
`pipeline_ctrl` flushes exactly the two younger stages (IF/ID, ID/EX) and
redirects fetch in the same cycle: 2-cycle taken penalty, 0-cycle
not-taken.  Static predict-not-taken (no BTB) — the right depth/complexity
point for a single-issue in-order core.

Exceptions and interrupts commit at WB (all four stage registers flushed;
redirect to the effective mtvec, vectored for interrupts).  MRET redirects
from EX like a jump.  Interrupts are *injected* at EX, never WB, because
stores commit at the end of MEM — a WB-time interrupt would have to replay
a committed store (H&P C.4 "precise exceptions" discussion).

## Structural hazards

None by construction: separate IMEM/DMEM (Harvard BRAMs), 2R+1W register
file with write-first bypass, dedicated CSR read and write ports.

## Measured behaviour (xsim, `make regress`)

- `hello_cpi`: CPI 1.599 — per iteration: lw→add load-use stall (+1) and
  taken-branch flush (+2) over 5 instructions, exactly the textbook cost
  model's prediction.
- `spmv_csr`: CPI ≈ 1.36 direct-BRAM, 1.429 through the D-cache.
- Directed corner TBs: `tb_forwarding_unit` (all paths + priorities +
  csrr regression), `tb_csr_unit` G17–G19 (counter RMW), `tb_timer_irq`
  (interrupt in EX with mepc on the first un-executed instruction),
  `tb_misalign_trap` (taken branch to a misaligned target).
