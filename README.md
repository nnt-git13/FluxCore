<p align="center">
  <img src="figures/readme.png" alt="FluxCore processor mark" width="260" />
</p>

<h1 align="center">F L U X C O R E</h1>
<p align="center"><em>A compact RV32IMXFlux FPGA processor for sparse-kernel measurement</em></p>

<p align="center">
  <img src="https://img.shields.io/badge/ISA-RV32IMXFlux-0f766e" alt="RV32IM + XFlux">
  <img src="https://img.shields.io/badge/Pipeline-5%20stage-334155" alt="5 stage pipeline">
  <img src="https://img.shields.io/badge/FPGA-Zybo%20Z7--20-0f766e" alt="Zybo Z7-20">
  <img src="https://img.shields.io/badge/Vivado-2023.1-334155" alt="Vivado 2023.1">
</p>

FluxCore is a handwritten SystemVerilog RISC-V core with a small bare-metal software flow, directed RTL verification, Rocq/Coq proof artifacts, and a Vivado path to a standalone Zybo Z7-20 bitstream. The current design is a measurable FPGA processor: it can build and simulate benchmark programs, retire RV32I/RV32M/XFlux instructions, expose machine counters, and run through synthesis, implementation, and bitstream generation.

The default SoC is intentionally simple: `fluxcore_soc` wires the CPU to local BRAM instruction and data memories, exposes only `clk` and `rst`, and preserves retirement/exception signals for debug. A parameterized direct-mapped data-cache path is present, with the default configuration left as direct BRAM.

---

## Contents

- [Current Abilities](#current-abilities)
- [Architecture](#architecture)
- [Verification](#verification)
- [Software Flow](#software-flow)
- [FPGA Snapshot](#fpga-snapshot)
- [Runbook](#runbook)
- [Repository Map](#repository-map)
- [Boundaries](#boundaries)

---

## Current Abilities

| Area | Current state |
|---|---|
| Core | Five-stage, in-order, single-issue RV32 pipeline |
| ISA | RV32I + RV32M + XFlux custom helpers |
| Privilege | Machine-mode CSR/trap subset with ECALL and MRET |
| Counters | `mcycle`/`mcycleh` and `minstret`/`minstreth` |
| Hazards | EX/MEM and MEM/WB forwarding, load-use stall, control redirects, divider/cache stall input |
| Memory | BRAM instruction memory and byte-enabled BRAM data memory |
| Cache | Optional direct-mapped write-through D-cache path via `USE_DCACHE`; default is cacheless BRAM |
| Software | Bare-metal startup, linker script, runtime counter/report helpers, benchmark build targets |
| Benchmarks | `hello_cpi` and 8x8 CSR SpMV simulation workloads |
| Simulation | Questa-oriented unit, integration, cache, and SoC benchmark benches |
| Formal | Rocq/Coq proof target for core ISA/pipeline/SPMV proof files |
| FPGA | Non-project Vivado synth, implementation, and bitstream targets for Zybo Z7-20 |

---

## Architecture

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
| RTL | Handwritten SystemVerilog |
| Pipeline | IF, ID, EX, MEM, WB |
| Register file | 32 x 32-bit, async read, sync write, hardwired `x0` |
| Reset vector | `0x00000000` by default |
| Trap vector | `0x00000100` by default |
| IMEM | 4096 x 32-bit BRAM by default, `$readmemh` init capable |
| DMEM | 2048 x 32-bit BRAM by default, byte write strobes |
| FPGA clock constraint | 20 ns analysis period, 50 MHz target |
| Top-level ports | `clk`, `rst` |

### ISA Surface

| Group | Instructions | Status |
|---|---|---|
| RV32I ALU | ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU and I-type forms | Implemented |
| RV32I memory | LW, LH, LB, LHU, LBU, SW, SH, SB | Implemented |
| RV32I branch | BEQ, BNE, BLT, BGE, BLTU, BGEU | Implemented |
| RV32I jump | JAL, JALR | Implemented |
| RV32I immediate | LUI, AUIPC | Implemented |
| RV32I system | ECALL, MRET, CSR read/write/set/clear forms | Implemented |
| RV32M multiply | MUL, MULH, MULHU, MULHSU | Implemented, combinational |
| RV32M divide | DIV, DIVU, REM, REMU | Implemented, 33-cycle iterative divider |
| XFlux | XLIDX, XABS, XMIN, XMAX, XCLZ | Implemented in `CUSTOM_0` space |

### Memory And Cache

The default path is BRAM-first and cacheless. Instruction fetch uses next-PC addressing so the BRAM output is aligned with the visible fetch PC. Data loads are consumed live in writeback, matching the BRAM read timing used by `bram_dmem`.

The optional D-cache path is selected with `USE_DCACHE=1` in `fluxcore_soc`:

| Cache property | Current value |
|---|---|
| Organization | Direct-mapped |
| Line size | One 32-bit word |
| Default lines | 64 |
| Write policy | Write-through, no-write-allocate |
| Load miss behavior | One-cycle stall and refill from BRAM |
| Counters | 32-bit hit and miss counters exposed by the cache module |

---

## Verification

The Makefile exposes focused tests for leaf modules, pipeline behavior, memory behavior, cache behavior, software-loaded SoC simulations, and formal proof compilation.

| Layer | Examples |
|---|---|
| Unit RTL | `alu-test`, `decoder-test`, `regfile-test`, `csr-unit-test`, `dcache-sim` |
| Pipeline registers/control | `if-id-reg-test`, `id-ex-reg-test`, `pipeline-ctrl-test`, `forwarding-unit-test` |
| Integration | `rv32i-alu-test`, `rv32m-test`, `lw-sw-test`, `byte-halfword-test`, `branch-compare-test` |
| Control flow | `branch-integ-test`, `jal-jalr-test`, `lui-auipc-test`, `ecall-mret-test` |
| Memories | `bram-imem-test`, `bram-dmem-test`, `dcache-e2e-test` |
| Full SoC programs | `sim-hello-cpi`, `sim-spmv-csr` |
| Formal | `formal-verify` |

The formal target compiles the proof set listed by `verification/formal/Makefile`: `FluxCoreTypes.v`, `FluxCoreISA.v`, `FluxCorePipeline.v`, `PipelineCorrectness.v`, and `FluxCoreSPMV.v`.

---

## Software Flow

FluxCore includes a minimal bare-metal flow for benchmark simulation:

| Component | Path |
|---|---|
| Startup | `software/startup/crt0.S` |
| Linker script | `software/linker/fluxcore.ld` |
| Runtime helpers | `software/runtime/fluxcore.h` |
| Benchmarks | `software/benchmarks/hello_cpi.c`, `software/benchmarks/spmv_csr.c` |
| ELF to IMEM hex | `scripts/elf2hex.py` |

Benchmark programs read machine counters and write a result block in DMEM. The SoC benchmark testbench watches that block, reports cycles, retired instructions, CPI, and checksums, then finishes the simulation.

---

## FPGA Snapshot

Saved Vivado 2023.1 reports for the default `fluxcore_soc` configuration on `xc7z020clg400-1`:

| Metric | Routed result |
|---|---:|
| Slice LUTs | 3,313 / 53,200 = 6.23% |
| Slice registers | 2,003 / 106,400 = 1.88% |
| Block RAM tiles | 2.5 / 140 = 1.79% |
| DSPs | 0 / 220 = 0.00% |
| Route status | 4,844 / 4,844 routable nets fully routed |
| Timing | WNS 3.780 ns, TNS 0.000 ns |
| Bitstream | `build/vivado/fluxcore_soc.bit` |

Standalone direct-mapped cache synthesis snapshot:

| Metric | Cache synth result |
|---|---:|
| Slice LUTs | 699 |
| LUT as distributed RAM | 338 |
| Slice registers | 200 |
| BRAM tiles | 0 |
| DSPs | 0 |
| Timing | WNS 13.946 ns at 50 MHz |

Primary reports are kept under `reports/synthesis/` and `reports/implementation/`.

---

## Runbook

Set up Python checks:

```bash
make setup
source .venv/bin/activate
make check
```

Configure local tools and board values:

```bash
cp config/tools.example.mk config/tools.local.mk
cp config/board.example.mk config/board.local.mk
make show-config
```

Build benchmark IMEM images:

```bash
make sw-all
```

Run common RTL and SoC simulations:

```bash
make integration-test
make rv32i-alu-test
make rv32m-test
make byte-halfword-test
make branch-compare-test
make dcache-e2e-test
make sim-hello-cpi
make sim-spmv-csr
```

Run formal proof compilation:

```bash
make formal-verify
```

Run the FPGA flow:

```bash
make vivado-check
make vivado-synth
make vivado-impl
make vivado-bitstream
make vivado-cache-synth
```

---

## Repository Map

```text
FluxCore/
|-- rtl/
|   |-- common/        architectural packages and shared leaf units
|   |-- core/          pipeline top, CSR unit, control, forwarding, writeback
|   |-- decode/        instruction decoder
|   |-- execution/     ALU, branch unit, RV32M unit, execute stage
|   |-- frontend/      fetch unit
|   |-- memory/        memory-stage datapath
|   |-- pipeline/      stage registers
|   |-- cache/         direct-mapped data cache blocks
|   `-- top/           BRAM memories and `fluxcore_soc`
|-- verification/      SystemVerilog tests, filelists, and Rocq/Coq proofs
|-- software/          bare-metal startup, linker, runtime, and benchmarks
|-- vivado/            constraints and non-project Tcl scripts
|-- synth/             synthesis filelists and report analysis scripts
|-- reports/           saved synthesis and implementation reports
|-- docs/              design notes and project records
|-- models/            Python support model and tests
|-- scripts/           utility scripts
|-- config/            example and local tool/board configuration
`-- build/             generated outputs
```

---

## Boundaries

FluxCore does not currently include an AXI/DDR memory path, PS host-control interface, UART, operating system support, virtual memory, multicore coherence, superscalar issue, out-of-order execution, or a PCG benchmark. XFlux `XMACC` is reserved in the ISA notes but is not implemented in the current RTL.

Performance, timing, utilization, and correctness claims should be backed by source artifacts, Makefile targets, or saved reports in this repository.
