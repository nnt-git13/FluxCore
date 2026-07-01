# verification/filelists/dcache.f
#
# Filelist for dcache unit test (standalone — no pipeline packages needed).
#
# Usage:
#   make dcache-sim
#
# Or directly:
#   vsim -do "vsim -f verification/filelists/dcache.f -top tb_dcache; run -all"
rtl/common/fluxcore_pkg.sv
rtl/cache/dcache.sv
verification/unit/cache/tb_dcache.sv
