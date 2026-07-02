# FluxCore Formal Verification

Machine-checked proofs about FluxCore models, built with Rocq/Coq
(`make -C verification/formal check` — compiles everything and enforces
the no-Admitted gate).

## Layout

The organization follows the ModularKoika GPU proof
(per-module **Spec / Impl / Refine** separation, end-to-end kernel proofs
on top, unfinished work quarantined):

| Directory | Contents |
|---|---|
| `Common/` | Shared foundations: 32-bit word arithmetic (`wrap32`), register-file algebra with the x0 hardwire (`Types.v`) |
| `Spec/` | Trusted specifications: sequential ISA semantics for the ALU-class subset (`ISA.v`) |
| `Impl/` | Models of the RTL implementation: the 3-slot forwarding pipeline (`Pipeline.v`), the CSR counter update algorithm (`CsrCounter.v`) |
| `Refine/<Module>/Top.v` | Proof that each Impl refines its Spec |
| `Kernels/` | End-to-end program proofs on the ISA machine (`SPMV.v`) |
| `wip/` | **Not built, not claimed.** Unfinished proofs (`Machine.v`, `Memory.v`) |

## What is actually proven (all Qed — no Admitted, gated in CI)

- **`Refine/Pipeline/Top.v`** — the forwarding pipeline model refines the
  sequential ISA: `fwd_read` equals the architectural register value
  (`fwd_read_equals_pipeline_isa_rf`), the invariant is preserved by every
  `pipe_exec` step, and after draining, the committed register file equals
  the ISA register file for any ALU program.
- **`Refine/CsrCounter/Top.v`** — the mcycle/minstret update algorithm
  (increment first, then overlay the written 32-bit half) satisfies:
  written half reads back exactly (S2), and the un-written half keeps the
  increment including the low→high carry (S3).  `buggy_loses_carry`
  exhibits the pre-2026-07-02 RTL bug as a concrete violation of S3.
- **`Kernels/SPMV.v`** — the 12-instruction SpMV CSR inner loop terminates
  from any well-formed initial state with `rf[x3]` equal to the exact
  dot product (`spmv_terminates`, via a strictly-decreasing per-PC step
  budget), never triggering undefined behavior; instantiated on the 8×8
  NNZ=21 benchmark matrix with checksum 416 (`spmv_concrete_terminates`,
  matching `make sim-spmv-csr`).

## What is NOT proven (honesty section)

- These are proofs about **hand-written models** of the RTL, not about the
  SystemVerilog itself.  There is no mechanical link RTL ↔ Coq (that is
  the role of the planned RVFI + riscv-formal track).
- The ISA spec covers the ALU-class subset (RV32I ALU ops + XFlux); loads/
  stores/branches/CSRs are modeled only where the SPMV kernel needs them.
- `wip/Machine.v` and `wip/Memory.v` are incomplete explorations and are
  excluded from the build and from every claim above.

## Gate

`verification/scripts/check_no_admitted.sh` fails the build if any
`Admitted`, `admit`, or new `Axiom` appears outside `wip/`.
