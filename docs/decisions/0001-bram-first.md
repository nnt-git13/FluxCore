# ADR 0001 — BRAM-First Memory Strategy

**Date:** 2026-06-29
**Status:** Superseded by [ADR 0003](0003-memory-hierarchy.md) (2026-07-22)

---

## Context

FluxCore's eventual deployment uses AXI interconnect and DDR memory for
benchmark datasets. However, integrating AXI, a Zynq PS block, and DDR
access simultaneously with initial RTL development would conflate multiple
sources of bugs and make early verification difficult.

An alternative is to begin with BRAM-backed instruction and data memories
instantiated directly in the processor top-level, deferring AXI and DDR
integration until the core is stable.

## Decision

FluxCore will be developed against BRAM-backed instruction and data memories
as the first FPGA deployment target. The processor top-level will instantiate
Xilinx BRAM primitives directly (no AXI, no PS block, no DDR) for the initial
milestone.

## Benefits

- **Simplified simulation**: BRAM behavior is well-understood and easy to model.
- **Isolated verification**: Core correctness can be verified independently of
  AXI protocol issues, DDR timing, and PS software.
- **Fast synthesis feedback**: A standalone PL design synthesizes and implements
  faster than a full PS+PL block design.
- **Smaller scope**: Each integration layer (AXI-Lite, PS control, DDR) is added
  incrementally after the previous layer is stable.
- **Lower risk**: BRAM capacity is sufficient for all initial test programs;
  DDR is only required for full sparse matrix benchmarks.

## Costs

- Initial FPGA designs cannot load programs from the PS at runtime.
- Program changes require a new bitstream.
- BRAM capacity limits the size of programs that can be tested on FPGA before
  AXI/DDR integration.

## Revisit Conditions

Revisit when:
- The BRAM-backed core is verified and synthesized with timing closure.
- Test programs are large enough to require more memory than available BRAMs
  can provide.
- AXI-Lite control integration is the next planned milestone.
