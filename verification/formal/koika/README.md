# FluxCore ↔ Kôika formal port (Path A)

This directory is the **Kôika re-expression of FluxCore with a machine-checked
refinement proof** — the "Path A" approach: prove that the hardware, written in
Kôika (a rule-based HDL with formal Rocq semantics *and* a compiler to
synthesizable Verilog), refines a reference ISA specification.

It sits **alongside** the SystemVerilog RTL under `rtl/`, which is unchanged.
The SV remains the shipping design and its 54-target regression still governs
correctness; this directory adds the theorem-prover-grade formal layer that the
hand-written model in `verification/formal/` (Impl/Spec/Refine `.v` files)
deliberately could not reach — that older layer states, in its own README, that
there is *no mechanical link RTL ↔ Coq*. The Kôika port closes exactly that gap:
the object proven here is the object a Kôika backend compiles to Verilog.

The methodology and infrastructure follow the ModularKoika project
(`~/Desktop/CSAIL_UROP/ModularKoika`): per-module `Impl / Spec / Refine`, with
`refines := mod_init ⊑ sim` (reflexive + transitive) composing module proofs
into a whole-core theorem.

## The top-level theorem (Qed, axiom-free)

```coq
Theorem FluxCore_refines : refines FluxCoreImpl ISASpec.
```

`Refine/FluxProcRefine.v`, verified with `Print Assumptions` → *Closed under
the global context*. This is a **machine-level refinement in the framework's
own simulation relation** (`refines := mod_init ⊑ sim`, the same statement
shape as ModularKoika's `CsrFile_refines`):

- **`FluxCoreImpl`** (`Impl/FluxProcImpl.v`) is a real stateful Kôika module —
  a PC register, 32 architectural register submodules, a word-memory
  submodule (`FluxMem.v`, a Reg/BRAM-style primitive leaf), `mux_expr`
  read/write muxes over the runtime register indices, byte/halfword lane
  muxes, and the **proven datapath circuits** (ALU/XFlux, branch comparisons,
  RV32M multiplies) dispatched by `alu_expr_of` / `br_expr_of` /
  `mul_expr_of`. x0 writes are dropped in hardware (lane 0 of the demux).
- **`ISASpec`** (`Spec/FluxProcSpec.v`) is the sequential ISA machine: state
  `{pc, regfile, memory}`; one `step` retires one instruction per the
  `spec_next` function.
- The coupling is `state_sim` (PC, all 32 registers, and all memory words
  agree pointwise); the simulation covers every method trace — i.e. **all
  instruction streams** — not any fixed program.
- The 25 combinational datapath theorems plug in through the three dispatch
  bridges + `interp_pure_peval`: the circuit proofs literally become the
  execute step of the machine proof.

**Scope of the v2 machine — the FluxCore integer ISA:**

| Class | Instructions |
|---|---|
| ALU / ALU-imm | AND OR XOR ADD SUB SLL SRL SRA SLT SLTU + LUI-copy + **XABS XMIN XMAX XLIDX** (15 proven ops) |
| Branches | BEQ BNE BLT BGE BLTU BGEU (pc-relative) |
| Jumps | JAL, JALR (link = pc+4; JALR target bit 0 cleared) |
| Upper imm | LUI, AUIPC |
| Memory | LW SW **LB LBU LH LHU SB SH** (word-granular magic memory, aligned base, read-modify-write byte/half lanes) |
| RV32M | MUL MULH MULHSU MULHU |

Honest boundaries: single-cycle transactional core (the environment feeds one
pre-decoded 55-bit control word per `step`); DIV/REM (needs a verified
iterative divider — no Kôika division primitive), XCLZ (priority encoder),
CSRs/traps, and the F extension (the Flocq project) are **not** in the
theorem; misaligned-access trapping is not modeled. Each grows `step` on both
sides of the *same* theorem statement.

## Supporting proven layers (Qed, axiom-free)

| File | Content |
|---|---|
| `Spec/FluxAlu.v` | Reference semantics for the integer ALU **and the custom XFlux ops** (`XABS/XMIN/XMAX/XCLZ/XLIDX`), plus 11 property theorems (XFlux selection/idempotence, `clz(0)=32`, SLT = signed order, XLIDX address). |
| `Spec/FluxIsa.v` | Architectural register file (`rf_read`/`rf_write`/x0-aware `rf_write0` + x0 invariant), `arch_step_alu` + its correctness. |
| `FluxProc.v` | The processor module interface shared by both machines (`getPc`/`getReg`/`getMem`/`step`), control-word fields, the four decoders, and the shared sub-word access helpers. |
| `Impl/FluxAluImpl.v` | **Real Kôika combinational circuits** for the ALU datapath — the compile-to-Verilog object. |
| `Refine/FluxAluRefine.v` | `peval (alu_<op>_expr a b) = inl (alu_spec ALU_<OP> a b)` for 15 of the 16 datapath ops (XCLZ pending), in the style of ModularKoika's `compare_ripple_correct`. |
| `Spec/FluxBranch.v` + `Impl/FluxBranchImpl.v` + `Refine/FluxBranchRefine.v` | Branch-resolution unit: `branch_taken` spec (+ 4 property theorems) and the six proven comparison circuits (BEQ/BNE/BLT/BGE/BLTU/BGEU). |
| `Spec/FluxMul.v` + `Impl/FluxMulImpl.v` + `Refine/FluxMulRefine.v` | The full RV32M multiply family: MUL / MULH / MULHSU / MULHU (sign-/zero-extended 64-bit products, sliced), each refined. |
| `FluxMem.v` | The word-memory primitive leaf (`mkWordMem`) + `mem_upd`, shared by leaf semantics and spec. |
| `Refine/FluxProcRefine.v` | **`FluxCore_refines`** + the coupling, per-method simulation lemmas, the three dispatch bridges, and the `interp_pure_peval` bridge. |
| `Refine/Top.v` | The combinational bundles + the roadmap; `Check FluxCore_refines`. |

## Roadmap (growing the same theorem)

1. **`FluxCore_refines` over the full integer ISA (v2 machine) — ✅ done**
   (ALU/ALU-imm, branches, jumps, upper immediates, word+byte+halfword
   loads/stores, RV32M multiplies)
2. DIV/DIVU/REM/REMU (needs a verified iterative divider circuit) and XCLZ
   (priority encoder) — *todo*
3. Decode from raw RV32 instruction bits (template: `Gpu.Basic.Decode`),
   replacing the pre-decoded control word — *todo*
4. CSRs / traps / interrupts (template: `Gpu.CsrFile`) — *todo*
5. FPU ⊑ **Flocq** (`Bplus/Bmult/Bfma/Bdiv/Bsqrt`) for F — *todo* (turns the
   numpy golden sweep into an unbounded theorem)
6. The **pipelined** `FluxCoreImpl` — five-stage, forwarding/hazards — proven
   against the *same* `ISASpec` via `refines_trans`
   (pipelined ⊑ single-cycle ⊑ ISA) — *todo, the research-grade step*
7. Kôika backend compile of `FluxProcImpl` to Verilog — *todo*

## Building

Requires the **opam Rocq 9.1** toolchain (the one that built ModularKoika — the
system Coq 8.18 will *not* load its `.vo` files) and a built ModularKoika
checkout.

```sh
eval $(opam env)                 # put Rocq 9.1 'coqc' on PATH
cd verification/formal/koika
make MK=$HOME/Desktop/CSAIL_UROP/ModularKoika
```

The three external libraries (`Koika`, the Kôika `Gpu.Basic` primitives, and
`riscv-coq`) are referenced in place via `-R`/`-Q` (see `_CoqProject` / the
`Makefile`), not vendored, so this stays a thin overlay on the ModularKoika
checkout.
