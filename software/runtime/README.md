# software/runtime — Bare-Metal Runtime Support

This directory will contain minimal bare-metal runtime support for FluxCore programs.

## Future Contents

- `fluxcore_io.c` / `fluxcore_io.h` — UART or memory-mapped I/O helpers for
  printing output from test programs.
- `fluxcore_counters.c` / `fluxcore_counters.h` — Wrappers to read FluxCore's
  performance counters (retirement count, cycle count, etc.).
- Any other thin support library needed before full libc is available.

## Status: Not Yet Created

Runtime support is not started because:

- The I/O peripheral memory map has not been defined.
- The performance counter CSR assignments have not been specified.
- No CSR instructions are implemented yet.

These dependencies will be resolved during the baseline five-stage pipeline
implementation milestone.
