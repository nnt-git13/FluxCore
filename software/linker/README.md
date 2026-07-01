# software/linker — Linker Scripts

This directory will contain the linker scripts for bare-metal FluxCore programs.

## Future Contents

- `fluxcore.ld` — Linker script describing the memory map visible to software:
  - Instruction BRAM base address and size.
  - Data BRAM base address and size.
  - Stack placement.
  - Section layout (`.text`, `.rodata`, `.data`, `.bss`).

## Status: Not Yet Created

The linker script depends on:

- The confirmed Zybo Z7 model (available BRAM blocks and their AXI addresses).
- The memory map established in the FluxCore package file.
- Decisions about scratchpad and MMIO placement (future milestones).

No linker script will be written until the memory map is frozen.
See `docs/decisions/0002-board-model-unconfirmed.md`.
