# verification/filelists/soc_benchmark.f
#
# Filelist for full-SoC benchmark simulation (tb_hello_cpi, tb_spmv_csr).
#
# Compiles the complete fluxcore_soc hierarchy — CPU core, BRAMs, optional
# dcache — plus the benchmark testbench.
#
# Usage:
#   make sim-hello-cpi
#   make sim-spmv-csr

# Core packages
rtl/common/fluxcore_pkg.sv
rtl/common/mem_if_pkg.sv
rtl/common/rv32_isa_pkg.sv
rtl/common/pipeline_pkg.sv

# Core RTL
rtl/common/imm_gen.sv
rtl/common/regfile.sv
rtl/decode/decoder.sv
rtl/execution/alu.sv
rtl/execution/branch_unit.sv
rtl/pipeline/if_id_reg.sv
rtl/pipeline/id_ex_reg.sv
rtl/pipeline/ex_mem_reg.sv
rtl/pipeline/mem_wb_reg.sv
rtl/frontend/btb.sv
rtl/frontend/fetch_unit.sv
rtl/execution/mul_div_unit.sv
rtl/execution/execute_stage.sv
rtl/memory/mem_stage.sv
rtl/core/wb_stage.sv
rtl/core/forwarding_unit.sv
rtl/core/pipeline_ctrl.sv
rtl/core/csr_unit.sv
rtl/common/fp_pkg.sv
rtl/common/fp_regfile.sv
rtl/execution/fp/fp_pack.sv
rtl/execution/fp/fp_sgnj.sv
rtl/execution/fp/fp_minmax.sv
rtl/execution/fp/fp_cmp.sv
rtl/execution/fp/fp_classify.sv
rtl/execution/fp/fp_cvt.sv
rtl/execution/fp/fp_mul.sv
rtl/execution/fp/fp_addsub.sv
rtl/execution/fp/fp_short.sv
rtl/execution/fp/fp_fma.sv
rtl/execution/fp/fp_divsqrt.sv
rtl/execution/fp/fpu.sv
rtl/core/fluxcore_top.sv

# Memory and cache
rtl/top/bram_imem.sv
rtl/top/bram_dmem.sv
rtl/cache/dcache.sv
rtl/cache/icache.sv
rtl/memory/mem_if_bram.sv
rtl/peripherals/uart_tx.sv
rtl/peripherals/gpio.sv
rtl/peripherals/clint.sv
rtl/top/soc_bus.sv

# SOC top
rtl/top/fluxcore_soc.sv

# Benchmark testbenches
verification/integration/tb_soc_benchmarks.sv
verification/integration/tb_soc_uart.sv
