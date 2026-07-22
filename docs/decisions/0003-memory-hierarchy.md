# ADR 0003 — Memory Hierarchy Build-Out (supersedes ADR 0001)

**Date:** 2026-07-22
**Status:** Accepted
**Supersedes:** [ADR 0001 — BRAM-First Memory Strategy](0001-bram-first.md)

---

## Context

ADR 0001 deferred AXI/DDR integration until three revisit conditions were met:

1. *The BRAM-backed core is verified and synthesized with timing closure.*
   Met — 54-target regression green, routed at 50 MHz with 7 % LUT
   utilization (`reports/implementation/`).
2. *Test programs outgrow BRAM capacity.* Met in principle — the benchmark
   roadmap (full sparse-matrix datasets) exceeds the ~630 KB of PL BRAM, and
   the RV32F additions grow the program footprint further.
3. *AXI-Lite control integration is the next planned milestone.* Met — the
   memory-hierarchy plan (phases P0–P9, tracked in the working session) makes
   the AXI/DDR path the current line of work.

All three conditions hold, so ADR 0001's strategy is retired and replaced by
the phased hierarchy below.

## Decision

Build the memory system in layers, each verified against the previous one
before the next is added, with simulation-only backends at every step so the
design never becomes FPGA-only:

| Phase | Layer | Status |
|-------|-------|--------|
| P0 | Frozen request/response contract (`rtl/common/mem_if_pkg.sv`) + configurable-latency sim memory (`sim/memory/mem_model.sv`) | done |
| P1 | L1 D-cache: multi-word lines, N-way true-LRU, write-allocate, write-back (SoC default: 2 KiB, 2-way, 16 B lines, WB+WA) | done |
| P2 | Non-blocking L1: 1-entry MSHR, hit-under-miss, deferred-load scoreboard in the core | done |
| P3 | soc_bus → ready/valid with backpressure + write buffer; AXI4 master adapter; behavioral AXI4 slave for xsim | current |
| P4 | Unified L2 (set-associative, write-back) + L1↔L2 arbiter | planned |
| P5 | I-cache + fetch handshake + FENCE.I | planned |
| P6 | DRAM timing model, memory controller, Zynq PS DDR3 via AXI HP, runtime program load | planned |
| P7 | Cache maintenance ops, PS/PL coherence policy, hierarchy performance counters | planned |

Key sub-decisions, fixed here:

- **Protocol:** the `mem_if_pkg` contract is minimal and single-threaded
  (valid/ready, 4-bit id, AXI-encoded burst len and resp codes). No
  thread_id, no gather/scatter. Re-freezing requires touching every
  memory-path module and is expected never to happen.
- **Miss handling:** one MSHR, hit-under-miss, in-order issue with
  out-of-order load completion via a one-entry scoreboard. This stays within
  FluxCore's architectural identity (single-issue, in-order, five-stage).
- **Error policy:** a memory error on a *deferred* access is imprecise by
  construction (the load already retired) and is treated as a fatal machine
  error; precise load/store faults exist only on blocking accesses.
- **Formal scope:** the Kôika theorem (`FluxCore_refines`) covers the
  transactional ISA machine and is untouched by hierarchy work; the
  pipelined-Impl refinement is a standing, separately-tracked obligation
  (see `verification/formal/koika/README.md`).

## Costs

- Every layer adds latency configurability that must be regression-tested;
  the regress suite grows accordingly (60 targets at P2).
- Write-back caching makes PS/PL data sharing non-trivial; P7 must resolve
  ACP-vs-HP before runtime program load (P6.4) can be trusted.

## Revisit conditions

- P6 hardware bring-up contradicts the DRAM timing model badly enough that
  sim CPI is misleading (> ~20 % divergence on the benchmark suite).
- A second bus master (DMA, debug) appears — the single-master bus decision
  and the coherence policy both need re-examination then.
