# RISCOF conformance flow (P9.2)

Runs the official riscv-arch-test suite on FluxCore RTL (xsim) against
Spike as the reference model.

## Environment (all local, no sudo)
- `riscof` installed in the project venv (`pip install riscof`).
- Spike built from source at `build/spike-install/bin/spike`
  (dtc also built from source at `build/dtc` — keep it on PATH for
  reconfigures; the spike *binary* has no runtime dtc dependency).
- Test suite cloned at `verification/riscof/riscv-arch-test`.

## Pieces
- `config.ini` — DUT = fluxcore, REF = spike.
- `fluxcore/` — DUT plugin: compiles each test with `env/link.ld`
  (Harvard split: text @0x0, data+signature @0x8000), makes one 64 KiB
  `$readmemh` image via `scripts/elf2hex.py`, runs the pre-built
  `tb_riscof` xsim snapshot with plusargs, TB dumps the signature.
  Halt protocol: store 0xD0E0D0E0 to 0xFFFC (`env/model_test.h`).
- `spike/` — reference plugin (`+signature=` native dumping).
- `tb_riscof.sv` — fluxcore_top + flat word memories (one unified
  image, two views), signature writer.

## Run
```sh
cd verification/riscof
riscof run --config=config.ini \
  --suite=riscv-arch-test/riscv-test-suite/rv32i_m/I \
  --env=riscv-arch-test/riscv-test-suite/env --no-browser
```
Suites to cover as extensions land: I, M, A, F, Zifencei, privilege
(machine + U). C and Sv32 suites wait on P8.5 / P8.4.
