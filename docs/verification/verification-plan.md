# FluxCore Verification Plan

## Overview

FluxCore verification is layered from unit tests to system-level integration,
always anchored by the Python architectural reference model as ground truth.

## Currently Available (Scaffold)

| Check                      | Tool      | Location                                      | Status   |
|----------------------------|-----------|-----------------------------------------------|----------|
| Python architectural config| pytest    | `models/tests/test_config.py`                 | Active   |
| SV toolchain smoke test    | Questa    | `verification/unit/infrastructure/`           | Active   |
| Vivado startup check       | Vivado    | `vivado/scripts/check_environment.tcl`        | Active   |
| Python lint                | ruff      | `models/`, `scripts/`                         | Active   |
| Python type checking       | mypy      | `models/fluxcore/`                            | Active   |

## Planned Verification Layers

### Unit Tests (Questa)

One testbench per RTL module, located in `verification/unit/<stage>/`.
Each testbench is self-checking, uses `$fatal` on mismatch, and prints
a single PASS message on success.

Planned unit testbenches (not yet created):

- Pipeline register files (IF/ID, ID/EX, EX/MEM, MEM/WB)
- ALU
- Decoder
- Register file (including hazard paths)
- Branch comparator
- Memory interface adapter (ideal model)
- BRAM adapter

### Python Architectural Reference Model

A Python instruction-level simulator in `models/fluxcore/` will execute
the same program as the RTL and produce a retirement trace. The trace
includes: PC, instruction word, register writeback address and value,
memory operation address and data.

### Retirement Trace Differential Testing

After every non-trivial RTL change, the RTL simulation writes a retirement
trace to `build/`. A Python comparison script checks it against the reference
model's expected trace. Any discrepancy fails the check.

### Directed Instruction Tests

Carefully crafted assembly programs exercising:

- All RV32I instruction encodings.
- All pipeline hazard scenarios (RAW, WAW, structural, control).
- Branch and jump edge cases.
- Memory alignment edge cases.
- CSR instructions (when implemented).

Located in `verification/programs/` and `software/tests/`.

### Randomized Instruction Streams

Random instruction generators (in Python) produce legal RV32I programs.
Both the RTL and the Python model execute the program and their retirement
traces are compared. This catches microarchitectural bugs that directed
tests miss.

### Pipeline Hazard Tests

Targeted tests for:

- Back-to-back RAW dependences (stall insertion).
- Load-use hazard (one-cycle stall).
- Control flow (branch, JAL, JALR) flush correctness.
- Forwarding paths (EX-to-EX, MEM-to-EX).

### Later Milestone Tests

| Milestone | Tests                                              |
|-----------|----------------------------------------------------|
| M2        | RV32M multiply/divide (corner cases, overflow)     |
| M3        | Cache hit/miss patterns, eviction, fill            |
| M4        | Multithreading context switch, scoreboard          |
| M4        | Nonblocking memory out-of-order responses          |
| M5        | FP32 operations, NaN, infinity, denormal           |
| M6        | Gather/scatter address patterns                    |
| M7        | XFlux instruction encoding and execution           |

### Assertions and Formal Verification

SystemVerilog Assertions (SVA) will be written for:

- Pipeline control signal invariants.
- Hazard detection coverage.
- Memory interface protocol compliance.

Selected properties will be checked with a formal tool (e.g., SymbiYosys)
in `verification/formal/`.

## Separation of Scaffold Checks from Future Verification

The checks under "Currently Available" can be run today with `make check`
and `make questa-smoke`. All other items in this plan require RTL and
test programs that do not yet exist. Do not conflate running infrastructure
checks with verified processor behavior.
