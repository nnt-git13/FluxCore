<p align="center">
  <img src="figures/readme.png" alt="FluxCore processor mark" width="260" />
</p>

<h1 align="center">F L U X C O R E</h1>
<p align="center"><em>A case study in building a five-stage FPGA processor for sparse computation</em></p>

<p align="center">
  <img src="https://img.shields.io/badge/ISA-RV32I-0f766e" alt="RV32I">
  <img src="https://img.shields.io/badge/Pipeline-5%20stage-334155" alt="5 stage pipeline">
  <img src="https://img.shields.io/badge/FPGA-Zybo%20Z7--20-0f766e" alt="Zybo Z7-20">
  <img src="https://img.shields.io/badge/Vivado-2023.1-334155" alt="Vivado 2023.1">
</p>

FluxCore is a handwritten SystemVerilog processor case study: a small, inspectable five-stage RISC-V core being shaped into a sparse-computation sidecar for FPGA systems. The current artifact is not a marketing model or simulator-only design. It includes synthesizable RTL, unit and integration benches, a BRAM-backed SoC top, Zybo Z7-20 constraints, Vivado synthesis/implementation scripts, and saved timing/utilization reports.

The long-term target is a highly specialized processor for irregular sparse kernels such as CSR SpMV and PCG: keep the simple in-order pipeline, then add the memory behavior, scratchpad/control surface, and custom sparse instructions that matter for those workloads.

---

## Contents

- [**Introduction**](#introduction) - research question and processor thesis
- [**Current scope**](#current-scope) - what is implemented now
- [**Architecture**](#architecture) - pipeline, memory, CSR/trap, and cache blocks
- [**FPGA results**](#fpga-results-current-snapshot) - latest Zybo Z7-20 synthesis/route numbers
- [**Methodology**](#methodology) - BRAM-first, report-backed, test-gated development
- [**Runbook**](#runbook) - setup, tests, Vivado commands
- [**Repository map**](#repository-map) - directory-level guide
- [**Roadmap**](#roadmap) - what still needs work

---

## Introduction

Sparse linear algebra stresses memory systems more than arithmetic units. Kernels such as sparse matrix-vector multiply, triangular solve, and preconditioned conjugate gradient spend much of their time following irregular index streams. A conventional out-of-order CPU spends silicon on speculation and broad dynamic scheduling; a fixed-function accelerator can be efficient but rigid.

FluxCore explores a middle path:

- keep a simple five-stage, single-issue in-order core
- use RISC-V as the baseline control ISA
- make memory behavior explicit and FPGA-friendly
- add custom sparse-compute mechanisms only after the baseline core is measurable
- preserve enough programmability to run real sparse kernels, not only one canned datapath

This repository is the engineering record for that processor: each milestone is intended to leave behind RTL, tests, scripts, and tool reports.

---

## Current Scope

The current design has moved beyond infrastructure. Implemented and tested components include:

| Area | Current status |
|---|---|
| ISA baseline | RV32I decode/execute coverage, M-mode CSR subset, ECALL/MRET path |
| Pipeline | Five-stage IF/ID/EX/MEM/WB, in-order, single-issue |
| Hazards | EX/MEM and MEM/WB forwarding, load-use stall, branch/JAL/JALR redirects |
| Register file | 32 x 32-bit, async read, sync write, hardwired x0 |
| Memory | BRAM instruction memory, byte-enabled BRAM data memory |
| FPGA top | `fluxcore_soc` standalone `clk` + `rst` synthesis top |
| Reset | External button synchronized into the core clock domain |
| Debug visibility | Retire and exception signals preserved for later ILA hookup |
| Optional cache | Standalone direct-mapped write-through cache primitive, not yet integrated |
| Target board | Digilent Zybo Z7-20, `xc7z020clg400-1` |

The optional cache exists as an efficient reusable block, but the shipped SoC path is still BRAM-backed and cacheless. That is intentional: the current milestone proves the core and memory timing before adding a wider request/response memory fabric.

---

## Architecture

FluxCore is deliberately constrained:

```text
Instruction Fetch
      |
Instruction Decode / Register Read
      |
Execute
      |
Memory
      |
Writeback
```

| Property | Value |
|---|---|
| Pipeline | Five-stage, in-order, single-issue |
| Baseline ISA | RV32I |
| Privileged subset | Machine-mode CSR/trap/return subset |
| Implementation | Handwritten SystemVerilog |
| Simulation | Questa-oriented testbenches |
| FPGA flow | Vivado non-project Tcl |
| Initial memory | BRAM instruction and data memories |
| Current FPGA clock target | 50 MHz constraint on Zybo Z7 system clock input |

FluxCore is not intended to become out-of-order, superscalar, GPU-like, or a fixed-function sparse matrix engine. The point of the case study is to keep the processor small enough to reason about while specializing the memory and instruction interface around sparse workloads.

### Memory and Cache Work

The BRAM-first SoC hides instruction BRAM latency with next-PC addressing and handles data BRAM load latency by consuming live data memory output in writeback. A standalone cache block also exists for the later memory-front-end milestone:

- direct-mapped
- 64 sets by default
- 4 x 32-bit words per line
- one-cycle registered hit response
- read-allocate load misses
- write-through stores
- no-write-allocate store misses
- one-entry write buffer
- inferred LUTRAM data/tag arrays on Zybo Z7-20

---

## FPGA Results: Current Snapshot

Latest routed `fluxcore_soc` result on Zybo Z7-20 (`xc7z020clg400-1`) with Vivado 2023.1:

| Metric | Routed result |
|---|---:|
| Slice LUTs | 2,625 / 53,200 = 4.93% |
| Slice registers | 1,871 / 106,400 = 1.76% |
| Block RAM tiles | 2.5 / 140 = 1.79% |
| DSPs | 0 |
| Route status | 4,008 / 4,008 routable nets fully routed |
| Timing | WNS 4.143 ns, TNS 0.000 ns |
| Timing checks | all `check_timing` categories clean |

Standalone optional cache synthesis:

| Metric | Cache OOC synth result |
|---|---:|
| Slice LUTs | 699 |
| LUT as distributed RAM | 338 |
| Slice registers | 200 |
| BRAM/DSP | 0 / 0 |
| Timing | WNS 13.946 ns at 50 MHz |

Primary reports:

- `reports/synthesis/fluxcore_soc_utilization_synth.rpt`
- `reports/synthesis/fluxcore_soc_timing_summary_synth.rpt`
- `reports/implementation/fluxcore_soc_utilization_route.rpt`
- `reports/implementation/fluxcore_soc_timing_summary_route.rpt`
- `reports/implementation/fluxcore_soc_check_timing_route.rpt`
- `reports/synthesis/direct_mapped_cache_utilization_synth.rpt`
- `reports/synthesis/direct_mapped_cache_timing_summary_synth.rpt`

---

## Methodology

FluxCore is being built as a measurement-backed hardware case study.

### BRAM-first vertical slice

The first FPGA milestone avoids AXI/DDR complexity. Instruction and data memories are local BRAM blocks inside `fluxcore_soc`, which makes the processor standalone, synthesizable, routeable, and easy to inspect with ILA probes.

### Report-backed claims

No timing, utilization, or performance number should be treated as valid unless it is backed by a saved report under `reports/` and a reproducible command in the Makefile or Vivado scripts.

### Test-gated development

The repository keeps small unit tests for leaf modules and integration tests for pipeline behavior: forwarding, load/store, branches, jumps, LUI/AUIPC, CSR, ECALL/MRET, and BRAM memories. Python checks cover the support scripts and models.

---

## Runbook

Set up Python tooling:

```bash
make setup
source .venv/bin/activate
make check
```

Configure local tool and board paths:

```bash
cp config/tools.example.mk config/tools.local.mk
cp config/board.example.mk config/board.local.mk
```

Current local Vivado wrapper used during development:

```bash
./scripts/vivado_2023_1.sh -mode batch -source vivado/scripts/check_environment.tcl
```

Common FPGA commands:

```bash
make vivado-check
make vivado-synth
make vivado-impl
make vivado-bitstream
make vivado-cache-synth
```

Common RTL regression commands:

```bash
make integration-test
make lw-sw-test
make branch-integ-test
make jal-jalr-test
make lui-auipc-test
make ecall-mret-test
make bram-imem-test
make bram-dmem-test
```

---

## Repository Map

```text
FluxCore/
├── rtl/
│   ├── common/        shared architectural types and leaf units
│   ├── core/          top pipeline wiring, CSR, forwarding, control, writeback
│   ├── decode/        RV32I decoder
│   ├── execution/     ALU and branch execution
│   ├── frontend/      fetch unit
│   ├── memory/        memory-stage datapath
│   ├── pipeline/      stage payloads and pipeline registers
│   ├── cache/         optional direct-mapped cache primitive
│   └── top/           BRAM memories and `fluxcore_soc`
├── verification/      SystemVerilog benches and filelists
├── vivado/            constraints and non-project Tcl scripts
├── synth/             synthesis filelists
├── reports/           curated synthesis, implementation, and test reports
├── docs/              architecture, interface, and design-decision notes
├── models/            Python support models/tests
├── software/          bare-metal program area
├── scripts/           repo/tool utility scripts
├── config/            local and example tool/board configuration
└── build/             generated outputs, ignored by git
```

---

## Roadmap

Near-term work:

- load a real bare-metal program into IMEM before bitstream generation
- program the Zybo Z7-20 and inspect retire/exception probes with ILA
- add a real IMEM initialization path for bare-metal programs
- add integration tests for BLT/BGE/BLTU/BGEU
- add end-to-end byte/halfword load/store tests
- decide where the optional cache enters the future memory interface

Sparse-compute direction:

- AXI-Lite control registers from PS to FluxCore
- program/data loading path from the ARM PS
- scratchpad and streaming memory experiments
- XFlux sparse instructions for index/value traversal
- performance counters for sparse-kernel attribution
- CSR SpMV and PCG microbenchmarks

Known limitations:

- the optional cache is not wired into `fluxcore_soc`
- back-to-back CSR RAW hazards need forwarding or stalling
- `CSRRS rs1=x0` write-enable behavior is architecturally harmless but not spec-clean
- no DDR/AXI master path exists yet

---

## Performance Claims Policy

FluxCore is a case study, so the evidence trail matters. Do not cite a performance, timing, utilization, or correctness claim unless the repository contains the report, test log, or source artifact needed to reproduce it.
