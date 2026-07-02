# Zybo Z7-20 Board Bring-up — Findings

**Status: ready to run — fill in the observed results below after programming
the board.**

## Procedure

```sh
make sw-board_hello
make vivado-synth SW_PROG=board_hello   # bakes build/sw/board_hello/imem.hex into IMEM
make vivado-impl
make vivado-bitstream
make program-board                      # JTAG over the Zybo USB port
```

Serial console: 3.3V USB-UART adapter, RX ← PMOD **JE pin 1 (V12)**,
GND ← JE pin 5.  115200 baud, 8N1 (`minicom -D /dev/ttyUSB0 -b 115200`).
Press **BTN0** (K18) to reset the core after programming.

## Expected behaviour

1. On reset release: `FluxCore up` banner, then `mcyc=0x────────` on the
   serial console.
2. LEDs LD0–LD3 count in binary at 2 Hz (timer interrupt every 0.5 s at
   50 MHz), with a `tick <n>` line per step.

## Observed (fill in)

| Check | Expected | Observed | Pass |
|---|---|---|---|
| Banner over UART | `FluxCore up` | | ☐ |
| mcycle print | nonzero hex | | ☐ |
| LED binary count | 2 Hz | | ☐ |
| `tick N` lines | monotonically increasing | | ☐ |

- Bitstream: `build/vivado/fluxcore_soc.bit` built from commit `________`
- Vivado timing: WNS ________ ns (see `reports/implementation/`)
- minicom capture: paste below.

```text
(serial log here)
```
