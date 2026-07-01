# ADR 0002 — Board Model Confirmation

**Date:** 2026-06-29
**Status:** Resolved — Zybo Z7-20 FPGA and board part confirmed

---

## Context

The Digilent Zybo Z7 is available in two variants:

- **Zybo Z7-10**: Zynq XC7Z010, smaller device (~17,600 LUTs, 60 BRAMs, 80 DSPs)
- **Zybo Z7-20**: Zynq XC7Z020, larger device (~53,200 LUTs, 140 BRAMs, 220 DSPs)

Resource counts above are illustrative and must be verified from the confirmed
board support package — they are NOT design targets.

These two variants use different FPGA part numbers and different Vivado board
part strings. Using the wrong part number produces:

- Incorrect resource utilization estimates.
- Invalid timing constraints.
- A bitstream that will not load onto the physical board.

**Update 2026-06-29:** Board confirmed as **Zybo Z7-20** (`xc7z020clg400-1`).

**Update 2026-06-30:** Digilent board files were located and queried with Vivado
2023.1. `get_board_parts *zybo*z7*20*` returned
`digilentinc.com:zybo-z7-20:part0:1.2`.

## Decision

No part number, board part string, device string, pin assignment, constraint
file, resource budget, BRAM count assumption, DSP count assumption, or timing
target is committed until the user physically identifies their board and
confirms which model it is.

Initial configuration files used:

```make
BOARD_MODEL := UNCONFIRMED
FPGA_PART   := UNCONFIRMED
BOARD_PART  := UNCONFIRMED
```

The local confirmed configuration now uses:

```make
BOARD_MODEL := zybo-z7-20
FPGA_PART   := xc7z020clg400-1
BOARD_PART  := digilentinc.com:zybo-z7-20:part0:1.2
```

## Benefits

- Prevents generating incorrect or misleading synthesis results.
- Avoids committing pin constraints that could damage the board if applied
  to the wrong model.
- Keeps the repository honest about what is actually known.

## Costs

- Synthesis was blocked until the board model and board part were confirmed.
- Resource budgets were planning-only until the board model was confirmed.

## How to Resolve

1. Physically inspect the board. The model is printed on the silkscreen.
2. Cross-check the part number against the Digilent product page.
3. Install the Digilent board files into Vivado:
   https://github.com/Digilent/vivado-boards
4. Locate the confirmed part string and board part string from the BSP.
5. Create `config/board.local.mk` from `config/board.example.mk` and fill
   in the verified values.
6. Update this ADR status to "Resolved" and commit.
7. The constraint file `vivado/constraints/fluxcore_soc.xdc` can then be used
   with confirmed pin assignments.

## Resolution Progress

| Item              | Status                        | Value                    |
|-------------------|-------------------------------|--------------------------|
| Board model       | **Confirmed**                 | Zybo Z7-20               |
| FPGA_PART         | **Confirmed**                 | `xc7z020clg400-1`        |
| BOARD_PART        | **Confirmed**                 | `digilentinc.com:zybo-z7-20:part0:1.2` |
| Pin constraints   | **Created**                   | `vivado/constraints/fluxcore_soc.xdc` |

## Revisit Conditions

Reopen if the physical board changes or Vivado reports a different Digilent
board part after board-file updates.
