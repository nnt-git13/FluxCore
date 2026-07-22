# FluxCore formal verification — Kôika Path-A refinement

FluxCore's formal verification is a **Kôika refinement proof**: the processor is
re-expressed in [Kôika](https://github.com/mit-plv/koika) — a rule-based HDL
with formal Rocq semantics *and* a compiler to synthesizable Verilog — and
proven to **refine a machine-checked ISA specification**. Because Kôika compiles
to the RTL, the object proven correct is the object synthesised. Everything is
under [`koika/`](koika/); see [`koika/README.md`](koika/README.md) for details,
the build, and the module-by-module roadmap.

## Why this replaced the previous proofs

An earlier iteration of this directory held hand-written Coq *models* of the
SystemVerilog (a forwarding-pipeline model, a CSR-counter model, an SpMV kernel
proof). Those were `Qed`-complete but had a fundamental limitation, stated
plainly in their own README at the time: **there was no mechanical link between
the RTL and the Coq model** — a human transcribed the algorithm, and if the SV
and the model drifted, the theorems said nothing about the hardware.

That entire model-level tree has been **removed** in favour of the Kôika
approach, which closes that gap by construction. The SystemVerilog RTL under
`rtl/` is unchanged and remains governed by the 54-target simulation regression;
this directory adds the theorem-prover layer on top of a design representation
that is itself compilable to hardware.

## Status

- ✅ **`FluxCore_refines : refines FluxCoreImpl ISASpec`** — the top-level
  machine refinement over the **full FluxCore integer ISA**, proven `Qed`,
  axiom-free, in the framework's simulation relation. `FluxCoreImpl` is a
  real stateful Kôika machine (PC + 32 register submodules + word memory +
  the proven datapath circuits); `ISASpec` is the sequential ISA machine
  {pc, regfile, memory}; the simulation quantifies over all instruction
  streams. **Covered:** ALU/ALU-imm (15 ops incl. XABS/XMIN/XMAX/XLIDX),
  BEQ/BNE/BLT/BGE/BLTU/BGEU, JAL/JALR, LUI/AUIPC, LW/SW/LB/LBU/LH/LHU/SB/SH,
  MUL/MULH/MULHSU/MULHU; x0 hardwired.
- ✅ **25 combinational datapath circuits** (ALU/XFlux, branch comparisons,
  the RV32M multiply family) — each proven against its reference and consumed
  by the machine theorem through the dispatch bridges.
- ⏳ DIV/REM (verified iterative divider) + XCLZ, decode from raw RV32
  instruction bits, CSRs/traps, the FPU (against **Flocq**), and the
  **pipelined** implementation proven against the same `ISASpec` via
  `refines_trans` — see `koika/README.md`.

This is a large, ongoing formal-methods effort: a complete machine-checked
refinement of a full **pipelined** RV32IMF+XFlux core is a multi-module
research undertaking (the ModularKoika GPU proof it is modeled on is a
substantial artifact). What is done: the single-cycle machine over the full
integer ISA is proven end to end. What remains: division, raw-bits decode,
CSRs/traps, the FPU vs Flocq, and the pipelined-vs-sequential refinement.

## Building

Requires **opam Rocq 9.1** and a built ModularKoika checkout:

```sh
eval $(opam env)
make -C verification/formal check MK=$HOME/Desktop/CSAIL_UROP/ModularKoika
```

Without those dependencies (e.g. minimal CI) the build step is skipped with a
message; the no-`Admitted` gate (`verification/scripts/check_no_admitted.sh`)
still runs over the sources.
