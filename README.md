<p align="center">
  <img src="figures/readme.png" alt="FluxCore processor mark" width="260" />
</p>

<h1 align="center">F L U X C O R E</h1>
<p align="center"><em>A case study in building a five-stage FPGA processor for sparse computation</em></p>

<p align="center">
  <img src="https://img.shields.io/badge/ISA-RV32IMXFlux-0f766e" alt="RV32IM + XFlux">
  <img src="https://img.shields.io/badge/Pipeline-5%20stage-334155" alt="5 stage pipeline">
  <img src="https://img.shields.io/badge/FPGA-Zybo%20Z7--20-0f766e" alt="Zybo Z7-20">
  <img src="https://img.shields.io/badge/Vivado-2023.1-334155" alt="Vivado 2023.1">
</p>

FluxCore is a handwritten SystemVerilog processor case study: a small, inspectable five-stage RISC-V core being shaped into a sparse-computation sidecar for FPGA systems and a living study vehicle for computer architecture. The current artifact is not a marketing model or simulator-only design. It includes synthesizable RTL, unit and integration benches, a BRAM-backed SoC top, Zybo Z7-20 constraints, Vivado synthesis/implementation scripts, and saved timing/utilization reports.

The long-term target has two tracks: keep the baseline core simple enough to reason about while adding the memory behavior, scratchpad/control surface, and custom sparse instructions that matter for CSR SpMV and PCG; then add measured architecture variants for the broader processor topics in computer organization and quantitative architecture.

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
| RV32M extension | MUL/MULH/MULHU/MULHSU (single-cycle), DIV/DIVU/REM/REMU (33-cycle restoring divider) |
| XFlux custom ISA | XLIDX/XABS/XMIN/XMAX/XCLZ in CUSTOM_0 opcode space (sparse/scientific helpers) |
| Pipeline | Five-stage IF/ID/EX/MEM/WB, in-order, single-issue |
| Hazards | EX/MEM and MEM/WB forwarding, load-use stall, branch/JAL/JALR redirects, mul/div full-freeze stall |
| Register file | 32 x 32-bit, async read, sync write, hardwired x0 |
| Memory | BRAM instruction memory, byte-enabled BRAM data memory |
| Counters | `mcycle` and `minstret` machine counters for CPI/runtime measurement |
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
| ISA | RV32I + RV32M + XFlux (CUSTOM_0) |
| Privileged subset | Machine-mode CSR/trap/return subset |
| Implementation | Handwritten SystemVerilog |
| Simulation | Questa-oriented testbenches |
| FPGA flow | Vivado non-project Tcl |
| Initial memory | BRAM instruction and data memories |
| Current FPGA clock target | 50 MHz constraint on Zybo Z7 system clock input |

### ISA Coverage

| Instruction group | Opcodes | Status | Notes |
|---|---|---|---|
| RV32I ALU | ADD/SUB/AND/OR/XOR/SLL/SRL/SRA/SLT/SLTU + I-type forms | Implemented | Full decode and execute |
| RV32I load/store | LW/LH/LB/LHU/LBU/SW/SH/SB | Implemented | Byte-enabled BRAM path |
| RV32I branch | BEQ/BNE/BLT/BGE/BLTU/BGEU | Implemented | Redirect in decode stage |
| RV32I jump | JAL/JALR | Implemented | Link register writeback |
| RV32I upper immediate | LUI/AUIPC | Implemented | |
| RV32I system | ECALL/MRET | Implemented | M-mode trap flow |
| RV32I CSR | CSRRW/CSRRS/CSRRC + I-type forms | Implemented | `mstatus`, `mepc`, `mcause`, `mcycle`, `minstret` |
| RV32M multiply | MUL/MULH/MULHU/MULHSU | Implemented | Single-cycle combinational, no stall |
| RV32M divide | DIV/DIVU/REM/REMU | Implemented | 33-cycle iterative restoring divider, full-freeze stall |
| XFlux XLIDX | `xlidx rd, rs1, rs2` — load word at rs1 + rs2×4 | Implemented | CUSTOM_0, treated as scaled-index load |
| XFlux XABS | `xabs rd, rs1` — signed absolute value | Implemented | CUSTOM_0 |
| XFlux XMIN | `xmin rd, rs1, rs2` — signed minimum | Implemented | CUSTOM_0 |
| XFlux XMAX | `xmax rd, rs1, rs2` — signed maximum | Implemented | CUSTOM_0 |
| XFlux XCLZ | `xclz rd, rs1` — count leading zeros | Implemented | CUSTOM_0 |
| XFlux XMACC | `xmacc rd, rs1, rs2` — fused multiply-accumulate | Reserved | Pending 3rd register read port; FUNCT3=101 reserved |

The default `fluxcore_soc` remains a small in-order, single-issue baseline. Broader topics such as branch prediction, multithreading, superscalar issue, out-of-order execution, virtual memory, and coherence belong in named experimental variants with separate tests and reports. The point is to preserve a known-good baseline while turning the repository into a measured architecture case study.

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
| Slice LUTs | 3,313 / 53,200 = 6.23% |
| Slice registers | 2,003 / 106,400 = 1.88% |
| Block RAM tiles | 2.5 / 140 = 1.79% |
| DSPs | 0 |
| Route status | 4,844 / 4,844 routable nets fully routed |
| Timing | WNS 3.780 ns, TNS 0.000 ns |
| Timing checks | all `check_timing` categories clean |
| Bitstream | generated at `build/vivado/fluxcore_soc.bit` |
| Bitstream DRC | 2 warnings, 0 errors |

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
- `reports/implementation/fluxcore_soc_drc_bitstream.rpt`
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
make rv32m-test
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

- use `mcycle` and `minstret` in benchmark programs to report cycles, retired instructions, and CPI
- load a real bare-metal program into IMEM before bitstream generation
- program the Zybo Z7-20 and inspect retire/exception probes with ILA
- add a real IMEM initialization path for bare-metal programs
- add integration tests for BLT/BGE/BLTU/BGEU
- add end-to-end byte/halfword load/store tests
- decide where the optional cache enters the future memory interface

Architecture-study direction:

- long-latency scoreboard experiments (div already full-freeze stalls; scoreboard is the next step)
- branch prediction with misprediction counters
- integrated I-cache/D-cache and scratchpad variants
- fine-grained multithreading and nonblocking memory
- superscalar and out-of-order variants as later, separately measured studies
- virtual-memory/TLB and multicore/coherence experiments after the baseline memory system matures

Sparse-compute direction:

- AXI-Lite control registers from PS to FluxCore
- program/data loading path from the ARM PS
- scratchpad and streaming memory experiments
- XFlux XMACC fused multiply-accumulate (pending 3rd register read port)
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
