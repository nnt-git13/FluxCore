// questa_smoke.f — Questa file list for the infrastructure smoke test
//
// Contains only the toolchain validation modules.
// This list is not part of the FluxCore processor compilation.
//
// Path references are repository-relative. The Questa compile script
// must set the working directory to the repository root before invoking
// vlog with this file list.
//
// Options passed to vlog:
//   -sv              Enable SystemVerilog
//   -timescale       Simulation timescale

+incdir+verification/unit/infrastructure

verification/unit/infrastructure/smoke_dut.sv
verification/unit/infrastructure/tb_smoke_dut.sv
