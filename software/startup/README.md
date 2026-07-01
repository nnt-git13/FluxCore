# software/startup — Reset Vector and Startup Code

This directory will contain the bare-metal startup assembly for FluxCore test programs.

## Future Contents

- `crt0.S` — Reset vector, stack pointer initialization, BSS clear, and jump to `main`.
- Any other early-boot assembly required before C code can execute.

## Status: Not Yet Created

The startup code depends on the memory map, which is not yet frozen. The memory
map depends on:

- The confirmed Zybo Z7 model (BRAM count and address range).
- The baseline ISA contract (`rtl/common/fluxcore_pkg.sv`).
- The linker script (see `software/linker/`).

No startup code will be written until these dependencies are resolved.
See `docs/decisions/0002-board-model-unconfirmed.md`.
