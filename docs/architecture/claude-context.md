# FluxCore Claude Context

## Current Direction

FluxCore is no longer only a small five-stage sparse-computation sidecar. The
baseline core remains the anchor, but the project scope has expanded into a
living computer-architecture case study that incrementally implements and
measures the major processor topics from:

- *Computer Organization and Design: The Hardware/Software Interface*
- *Computer Architecture: A Quantitative Approach*

The project should grow through real RTL, verification, FPGA synthesis,
implementation reports, and benchmark evidence. Do not treat textbook topics as
pure documentation. When practical, implement them as optional architectural
variants or measurable extensions inside the repo.

## Baseline Already Built

The current implementation is a synthesizable SystemVerilog RV32IM + XFlux processor for
the Zybo Z7-20:

- five-stage IF/ID/EX/MEM/WB pipeline
- single-issue, in-order baseline
- RV32I decode and execute path
- ALU, register file, immediate generation, branch unit
- forwarding from EX/MEM and MEM/WB
- load-use stall handling
- branch, JAL, and JALR redirects
- byte-enabled data memory path
- BRAM instruction and data memories
- M-mode CSR subset with ECALL/MRET trap flow
- standalone `fluxcore_soc` top
- Vivado synthesis, implementation, route, and bitstream flow
- successful programming onto Zybo Z7-20 PL fabric
- `mcycle` and `minstret` machine counters for benchmark timing and CPI
- optional direct-mapped write-through cache primitive, not yet integrated
- **RV32M**: MUL/MULH/MULHU/MULHSU (single-cycle combinational), DIV/DIVU/REM/REMU
  (33-cycle iterative restoring divider, full-freeze pipeline stall via `muldiv_busy_s`)
- **XFlux** CUSTOM_0 instructions: XLIDX (scaled-index load), XABS, XMIN, XMAX, XCLZ;
  XMACC (fused MAC) reserved at FUNCT3=101 pending a 3rd register read port

Current FPGA evidence exists in `reports/implementation/` and
`reports/synthesis/`.

## Important Scope Change

Older docs said FluxCore would never include out-of-order execution,
superscalar issue, virtual memory, cache coherence, complete floating point, or
vector/GPU-style processing. That is no longer the intended long-term framing.

The corrected framing is:

- The baseline FluxCore core remains small, in-order, and sparse-oriented.
- Broader architecture topics should be implemented as studied variants,
  optional modules, or controlled experiments.
- Sparse-computation specialization remains the main research through-line.
- Claims require tests, traces, benchmark results, and/or Vivado reports.

Do not casually rewrite the baseline into a large speculative CPU. Add features
in stages, keep measurement hooks, and preserve a known-good baseline.

## Expanded Architecture Roadmap

Near-term architecture study features:

- `mcycle` and `minstret` counters
- benchmark ROM/program loading flow
- CPI and execution-time reporting
- full branch variant integration tests
- byte/halfword load-store integration tests
- RV32M multiply/divide
- integrated instruction/data cache experiments
- branch prediction and misprediction accounting
- cache miss/hit counters

Memory-system topics:

- split I-cache and D-cache
- direct-mapped vs set-associative cache variants
- write-through vs write-back policies
- scratchpad memory
- DMA movement between DDR and scratchpad
- AXI/DDR memory access
- nonblocking request/response memory interface
- multiple outstanding misses
- gather/scatter support for sparse kernels

Pipeline and ILP topics:

- scoreboarded long-latency units
- simple branch prediction
- deeper pipeline variant
- fine-grained multithreading
- superscalar issue as an experimental variant
- out-of-order execution as a later experimental variant
- register renaming and reorder-buffer study if/when OoO begins

System topics:

- interrupts and fuller privileged-machine behavior
- virtual-memory/TLB experiment as a study variant
- multicore and cache coherence as later variants, not baseline assumptions
- power/area/performance comparison across variants

Sparse-computation specialization:

- XFlux custom ISA extensions
- sparse index/value traversal instructions
- CSR SpMV microbenchmarks
- PCG microbenchmarks
- memory-walker and prefetch experiments
- scratchpad-backed sparse kernels

## Development Policy

Work one measured feature at a time:

1. Define the architecture question.
2. Implement the smallest RTL change that exposes it.
3. Add unit/integration tests.
4. Add benchmark or measurement hooks where relevant.
5. Run `make check` and targeted RTL tests.
6. Run Vivado synthesis/implementation for stable hardware milestones.
7. Update reports and docs with only measured numbers.

The first implementation after this context update added performance counters:
`mcycle` and `minstret`. Those counters are the foundation for CPU execution
time, CPI, and quantitative comparisons across later architecture variants. The
next recommended implementation is a benchmark ROM/program loading flow that
reads those counters around small bare-metal kernels.
