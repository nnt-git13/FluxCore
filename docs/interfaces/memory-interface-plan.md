# Memory Interface Plan

## Status

**Not yet defined.** The memory interface transaction structure has not been
frozen. This document records the planned abstraction hierarchy and the
signals that the eventual interface must support.

## Planned Abstraction Hierarchy

```
Processor request interface
        ↓
Ideal simulation memory
or configurable-latency simulation memory
or BRAM adapter
or future AXI/DDR adapter
```

The same processor-side interface connects to any of these backends without
changing the core RTL. This abstraction enables:

- Early simulation with an ideal zero-latency memory model.
- Latency stress testing with a configurable-latency model.
- FPGA deployment with BRAM primitives.
- Later DDR access through an AXI adapter.

## Required Signals

The eventual memory interface protocol must support the following fields.
Exact signal names, widths, and encoding are deferred until the baseline
pipeline interfaces are frozen.

### Request channel

| Signal            | Purpose                                           |
|-------------------|---------------------------------------------------|
| valid / ready     | Flow control (ready/valid handshake)              |
| request_id        | Links response to outstanding request             |
| thread_id         | Identifies the issuing hardware thread context    |
| operation         | Read or write                                     |
| address           | Byte address                                      |
| byte_enables      | Per-byte write mask                               |
| write_data        | Data for write operations                         |

### Response channel

| Signal            | Purpose                                           |
|-------------------|---------------------------------------------------|
| valid / ready     | Flow control                                      |
| response_id       | Matches the originating request_id                |
| thread_id         | Matches the originating thread_id                 |
| read_data         | Data returned for read operations                 |
| error             | Error status (bus error, alignment fault, etc.)   |

## Later Milestone Requirements

- Multiple outstanding operations (nonblocking interface) in Milestone 4+.
- Gather/scatter address generation in Milestone 6+.
- Scratchpad addressing alongside DDR addressing in Milestone 6+.

## Optional Cache Primitive

`rtl/cache/direct_mapped_cache.sv` provides a standalone cache block for the
future request/response memory interface. It is not wired into the current
BRAM-only SoC.

Policy:

- Direct-mapped, parameterized by set count and words per line.
- One-cycle registered response on hits.
- Read-allocate on load misses.
- Write-through, no-write-allocate stores.
- One-entry write buffer so store hits can update the cached word immediately
  and drain the external write afterward.
- One outstanding refill at a time; refill streams one 32-bit word per backend
  response.

This is intentionally a small FPGA-friendly baseline: no dirty bits, no
replacement policy state, and no coherency assumptions. It should be placed
between the future processor memory request interface and a BRAM/AXI/DDR
adapter once the request/response protocol is finalized.

## Deferred

The actual SystemVerilog `interface` or `struct` definition will be created
in `rtl/interfaces/` when the pipeline register interfaces are established.
See the next recommended task in the top-level README.
