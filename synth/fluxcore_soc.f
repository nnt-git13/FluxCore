# synth/fluxcore_soc.f
#
# Vivado synthesis filelist for fluxcore_soc (standalone BRAM-backed FluxCore).
#
# Usage:
#   make vivado-synth
#
# Or directly:
#   ./scripts/vivado_2023_1.sh -mode batch \
#       -source vivado/scripts/synth_fluxcore_soc.tcl \
#       -tclargs xc7z020clg400-1
#
# Files are ordered so that packages and leaf modules precede their consumers.
# The matching XDC constrains clk/rst for the Zybo Z7-20 and marks internal
# retire/exception nets for debug visibility.
rtl/common/fluxcore_pkg.sv
rtl/common/mem_if_pkg.sv
rtl/common/rv32_isa_pkg.sv
rtl/common/pipeline_pkg.sv
rtl/common/imm_gen.sv
rtl/common/regfile.sv
rtl/decode/decoder.sv
rtl/execution/alu.sv
rtl/execution/branch_unit.sv
rtl/execution/mul_div_unit.sv
rtl/pipeline/if_id_reg.sv
rtl/pipeline/id_ex_reg.sv
rtl/pipeline/ex_mem_reg.sv
rtl/pipeline/mem_wb_reg.sv
rtl/frontend/fetch_unit.sv
rtl/execution/execute_stage.sv
rtl/memory/mem_stage.sv
rtl/core/wb_stage.sv
rtl/core/forwarding_unit.sv
rtl/core/pipeline_ctrl.sv
rtl/core/csr_unit.sv
rtl/core/fluxcore_top.sv
rtl/cache/dcache.sv
rtl/memory/mem_if_bram.sv
rtl/peripherals/uart_tx.sv
rtl/peripherals/gpio.sv
rtl/peripherals/clint.sv
rtl/top/soc_bus.sv
rtl/top/bram_imem.sv
rtl/top/bram_dmem.sv
rtl/top/fluxcore_soc.sv
