# FluxCore Project Scope

## Baseline (Initial Implementation Target)

The first implementation milestone is a working, verified, synthesizable five-stage RISC-V processor with the following fixed properties:

| Property              | Value                                     |
|-----------------------|-------------------------------------------|
| ISA                   | RV32I + RV32M + XFlux (CUSTOM_0)          |
| Pipeline              | Five-stage, in-order, single-issue        |
| Thread contexts       | 1 (single-threaded)                       |
| Memory (simulation)   | Ideal memory model                        |
| Memory (FPGA)         | BRAM-backed instruction and data memories |
| Implementation        | Handwritten SystemVerilog                 |
| Target board          | Digilent Zybo Z7 (Zynq-7000)             |

The baseline must produce correct retirement traces, verified against the Python
architectural reference model, before any additional feature work begins.

## Expanded Case-Study Scope

FluxCore started as a focused five-stage RV32I FPGA processor for sparse
computation. That baseline remains the reference implementation, but the project
is now also a living computer-architecture case study. Major processor topics
from classic organization and quantitative architecture texts should be explored
through real RTL, verification, FPGA reports, and benchmark measurements.

The baseline core should stay understandable and measurable. Larger features
such as superscalar issue, out-of-order execution, virtual memory, and coherence
should be added as explicit experimental variants rather than silently replacing
the known-good baseline.

## Planned Extensions

No claim about a feature is valid until backed by simulation traces, tests,
benchmark output, or synthesis/implementation reports.

| Feature                          | Milestone     | Notes                                         |
|----------------------------------|---------------|-----------------------------------------------|
| Performance counters             | M28 done      | `mcycle`, `minstret`, CPI and runtime basis    |
| Benchmark ROM/program flow       | M29           | Repeatable bare-metal benchmark loading        |
| RV32M (multiply/divide)          | M30 done      | MUL/MULH/MULHU/MULHSU single-cycle; DIV/DIVU/REM/REMU 33-cycle restoring divider |
| Instruction cache                | M31           | Direct-mapped and associative variants         |
| Data cache                       | M31           | Write-through/write-back policy experiments    |
| Branch prediction                | M32           | Static and simple dynamic predictors           |
| Cache/predictor counters         | M32           | Miss, hit, branch, and mispredict attribution  |
| Software-visible scratchpad      | M33           | Low-latency local storage                      |
| AXI master / DDR access          | M34           | Benchmark data from DDR via AXI                |
| DMA engine                       | M35           | Bulk transfers from DDR to scratchpad          |
| Gather/scatter engine            | M36           | Hardware support for indirect addressing       |
| XFlux sparse-computing ISA       | M37 partial   | XLIDX/XABS/XMIN/XMAX/XCLZ done; XMACC reserved pending 3rd read port |
| Four hardware thread contexts    | M38           | Fine-grained interleaved threading             |
| Nonblocking memory interface     | M39           | Multiple outstanding memory operations         |
| Scoreboard                       | M40           | Hazards for long-latency and threaded variants |
| Scoped FP32 subset               | M41           | Selected FP32 operations for scientific use    |
| Deeper pipeline variant          | M42           | Frequency/CPI tradeoff study                   |
| Superscalar variant              | M43+          | Experimental, measured separately              |
| Out-of-order variant             | M44+          | Experimental renaming/ROB study                |
| Virtual-memory/TLB experiment    | M45+          | Study variant, not needed for bare-metal base  |
| Multicore/coherence experiment   | M46+          | Later architecture study variant               |
| ARM PS host integration          | M34+          | PS loads programs and transfers sparse matrices|

## Baseline Boundaries

The default `fluxcore_soc` baseline remains:

- in-order unless an experimental variant is selected
- single-issue unless an experimental variant is selected
- bare-metal unless a virtual-memory/OS experiment is selected
- single-core unless a multicore/coherence experiment is selected
- programmable, not a fixed-function SpMV accelerator

Experimental variants may violate those boundaries when the purpose is to study
the architecture topic directly. Those variants must be named, tested, and
reported separately from the baseline.
