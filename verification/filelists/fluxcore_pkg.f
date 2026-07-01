// verification/filelists/fluxcore_pkg.f
//
// Questa file list for the fluxcore_pkg unit test.
//
// Compiles the shared architectural package and its self-checking testbench.
// The package must be compiled before the testbench that imports it.
//
// Invoked by verification/scripts/run_questa_pkg.sh via:
//   vlog -sv -f verification/filelists/fluxcore_pkg.f
//
// Working directory must be the repository root when this list is used.

// Shared architectural package (no dependencies; must be first)
rtl/common/fluxcore_pkg.sv

// Package unit testbench (imports fluxcore_pkg)
verification/unit/common/tb_fluxcore_pkg.sv
