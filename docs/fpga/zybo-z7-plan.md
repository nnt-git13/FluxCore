# Zybo Z7 FPGA Integration Plan

## Target Platform

**Board:** Digilent Zybo Z7 (Zynq-7000 SoC)

> **Board confirmed: Zybo Z7-20 — `xc7z020clg400-1`**
>
> `BOARD_PART` (Vivado board part string) is confirmed as
> `digilentinc.com:zybo-z7-20:part0:1.2`.
> Stage 2 pin/timing constraints live in `vivado/constraints/fluxcore_soc.xdc`.
> See `docs/decisions/0002-board-model-unconfirmed.md`.

The Zynq-7000 combines an ARM Cortex-A9 Processing System (PS) with
Programmable Logic (PL) fabric on a single die. FluxCore occupies the PL.

## Integration Progression

```
Stage 1: RTL simulation
    ↓
Stage 2: BRAM-backed processor in PL (standalone synthesis)
    ↓
Stage 3: AXI-Lite control interface (PS → FluxCore registers)
    ↓
Stage 4: ARM PS host control (PS loads programs, reads counters)
    ↓
Stage 5: AXI access to DDR (PS transfers sparse matrices for benchmarks)
```

### Stage 1: RTL Simulation

FluxCore simulates against an ideal memory model in Questa. No board is
required. This stage validates functional correctness before any FPGA work.

### Stage 2: BRAM-Backed Standalone Synthesis

FluxCore's top-level module instantiates Xilinx BRAM primitives directly
for instruction and data memories. The design is synthesized and implemented
in Vivado as a standalone PL design without a PS block. This validates:

- Vivado synthesis and implementation completeness.
- Resource utilization against the chosen Zybo Z7 model's device limits.
- Timing closure at the target clock frequency.

Stage 2 uses `vivado/constraints/fluxcore_soc.xdc`: `clk` is constrained to
the Zybo Z7 system clock pin K17 with a 20 ns period for the 50 MHz
implementation target, `rst` is constrained to push-button 0 on K18 as a
synchronous active-high reset input, and internal retirement/exception nets are
marked for debug visibility so they can be connected to an ILA during
implementation debug setup.

### Stage 3: AXI-Lite Control Interface

An AXI-Lite slave interface is added to FluxCore's top level, allowing the
PS to write control registers (reset, start, stop) and read status registers
(run state, program counter, performance counters). A Zynq PS block is added
to the Vivado design at this stage.

### Stage 4: ARM PS Host Control

The PS boots Linux or bare-metal firmware and exercises FluxCore:

- Loads a compiled test program into FluxCore's BRAM via AXI.
- Releases FluxCore reset and starts execution.
- Polls the retirement counter or waits for an interrupt.
- Reads back result registers or scratchpad contents.
- Validates correctness.

### Stage 5: AXI Access to DDR for Benchmarks

The PS transfers CSR-format sparse matrix data from DDR into FluxCore's
scratchpad or BRAM. FluxCore executes the SpMV or PCG kernel. The PS reads
back the result and validates it against a reference. Performance counters
are read and logged.

## Architecture Constraints

- **FluxCore is a soft processor in the PL.** It is not the ARM PS.
- The PS does not execute FluxCore programs — it is the host controller.
- No PS block design will be created until the standalone BRAM-backed core
  is stable and verified in RTL simulation (Stage 2).
- The BRAM-first approach ensures that FPGA integration issues (timing,
  synthesis, resource limits) are separated from functional bugs.

## Confirmed Device: Zybo Z7-20

**FPGA part:** `xc7z020clg400-1` (Zynq-7020, CLG400 package, speed grade -1)

| Resource       | Zybo Z7-20 (from DS190 / Xilinx product brief) |
|----------------|------------------------------------------------|
| LUTs           | 53,200                                         |
| Flip-flops     | 106,400                                        |
| BRAMs (36 Kb)  | 140 (= 4,900 Kb total)                         |
| DSP48E1        | 220                                            |
| User I/O       | 125 (CLG400 package)                           |

These figures are from Xilinx documentation and should be treated as planning
references. Actual post-implementation utilization reports are the authoritative
source for any design claim. See `reports/README.md`.

**Confirmed board configuration:** Vivado 2023.1 with Digilent board files
returns `digilentinc.com:zybo-z7-20:part0:1.2` for
`get_board_parts *zybo*z7*20*`; this value is set in
`config/board.local.mk`.
