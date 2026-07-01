# software/tests — Bare-Metal Test Programs

This directory will contain assembly and C test programs for functional
verification of the FluxCore processor.

## Planned Test Programs

| Program           | Purpose                                                  |
|-------------------|----------------------------------------------------------|
| `hello.c`         | Simplest possible program; verifies PC starts and exits  |
| `alu_test.S`      | Exhaustive RV32I ALU instruction coverage                |
| `branch_test.S`   | All branch conditions, forward and backward              |
| `load_store.S`    | All load/store widths and alignments                     |
| `hazard_test.S`   | Back-to-back RAW hazards, load-use stalls, branch flushes|
| `fibonacci.c`     | Simple loop with function calls                          |
| `riscv_tests/`    | Import from the RISC-V compliance test suite (future)    |

## Status: Not Yet Created

Test programs require:

1. A confirmed memory map (linker script).
2. Startup code (see `software/startup/`).
3. A working RISC-V GCC cross-compiler installation.
4. A Makefile target to compile and generate `.hex` or `.mem` files.

None of these dependencies are resolved yet.
