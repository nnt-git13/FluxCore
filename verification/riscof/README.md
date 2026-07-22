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
  (text @0x8000_0000 = spike's native RAM base, data+signature
  @0x8000_8000), makes one 64 KiB `$readmemh` image via
  `scripts/elf2hex.py --base 0x80000000`; `tb_riscof` aliases the
  0x8000_xxxx addresses through `addr[15:2]` and boots with
  `RESET_VECTOR=0x8000_0000`. Halt: store 0xD0E0D0E0 to 0x8000_FFFC
  (FluxCore mailbox) then 1 to `tohost` (terminates spike).
- `spike/` — reference plugin (`+signature=` native dumping).
- `tb_riscof.sv` — fluxcore_top + flat word memories (one unified
  image, two views), signature writer.

## Hard-won environment notes
- spike **execs `dtc` at runtime**; keep `build/dtc` on PATH.
- xsim snapshot reruns need `LD_LIBRARY_PATH=build/vivado-compat`
  (libtinfo.so.5 shim) — xsim_run.sh sets it, raw `xsim` calls don't.
- spike cannot map RAM at 0 (its boot ROM owns [0,0x1000)); hence the
  0x8000_0000 link base.
- gcc needs explicit `-mabi=ilp32` and a `_zicsr_zifencei` march
  suffix; the ctp-release tests additionally need no-op `RVMODEL_IO_*`
  macros.

## Run
```sh
cd verification/riscof
riscof run --config=config.ini \
  --suite=riscv-arch-test/riscv-test-suite/rv32i_m/I \
  --env=riscv-arch-test/riscv-test-suite/env --no-browser
```
Suites to cover as extensions land: I, M, A, F, Zifencei, privilege
(machine + U). C and Sv32 suites wait on P8.5 / P8.4.
