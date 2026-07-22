# FluxCore root Makefile
#
# All targets must be invoked from the repository root.
# Run 'make help' to see available targets.
#
# Local overrides (git-ignored):
#   config/tools.local.mk  — tool paths
#   config/board.local.mk  — board model and FPGA part
#
# Required: GNU Make >= 3.82

.PHONY: help setup check-tools python-test lint typecheck check synth-analysis regress \
        questa-smoke pkg-test isa-pkg-test alu-test imm-gen-test decoder-test regfile-test fp-regfile-test \
        fp-cvt-test fp-short-test fp-mul-test fp-addsub-test fp-fma-test fp-divsqrt-test fp-sweep-test \
        fp-arith-test fp-loadstore-test fp-muldiv-test fp-csr-test branch-unit-test \
        pipeline-pkg-test if-id-reg-test id-ex-reg-test ex-mem-reg-test mem-wb-reg-test fetch-unit-test \
        execute-stage-test mem-stage-test wb-stage-test pipeline-ctrl-test forwarding-unit-test \
        integration-test lw-sw-test branch-integ-test jal-jalr-test lui-auipc-test \
        byte-halfword-test branch-compare-test rv32m-test rv32i-alu-test dcache-e2e-test \
        csr-unit-test ecall-mret-test \
        bram-imem-test bram-dmem-test dcache-sim \
        sim-hello-cpi sim-spmv-csr sim-csr-probe sim-hello-uart sim-timer-irq \
        sim-misalign-trap sim-xflux sim-fp-kernel sim-hello-cpi-dcache sim-spmv-csr-dcache \
        verilator-lint program-board \
        formal-verify \
        vivado-check vivado-synth vivado-impl vivado-bitstream yosys-check clean distclean show-config \
        sw-hello_cpi sw-spmv sw-all sw-clean

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
include config/project.mk
-include config/tools.local.mk
-include config/board.local.mk

# Tool defaults (if not set by tools.local.mk)
VLOG         ?= vlog
VSIM         ?= vsim
VIVADO       ?= vivado
YOSYS        ?= yosys
# RISC-V cross-compiler: riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32
# Install: sudo apt install gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf
RISCV_PREFIX ?= riscv64-unknown-elf-

# Board defaults (if not set by board.local.mk)
BOARD_MODEL  ?= UNCONFIRMED
FPGA_PART    ?= UNCONFIRMED
BOARD_PART   ?= UNCONFIRMED

# Questa smoke-test paths
SMOKE_BUILD  := $(QUESTA_BUILD_DIR)/smoke
SMOKE_FLIST  := $(VERIF_DIR)/filelists/questa_smoke.f
SMOKE_DO     := $(SIM_DIR)/questa/run_smoke.do
SMOKE_SH     := $(VERIF_DIR)/scripts/run_questa_smoke.sh

# fluxcore_pkg unit-test paths
PKG_BUILD    := $(QUESTA_BUILD_DIR)/pkg
PKG_SH       := $(VERIF_DIR)/scripts/run_questa_pkg.sh

# Generic Questa runner (default); override SIM_RUN in tools.local.mk to
# use the xsim backend: SIM_RUN := verification/scripts/xsim_run.sh
QUESTA_RUN   := $(VERIF_DIR)/scripts/questa_run.sh
SIM_RUN      ?= $(QUESTA_RUN)
UNIT_DO      := $(SIM_DIR)/questa/run_unit.do

# rv32_isa_pkg unit-test paths
ISA_PKG_BUILD := $(QUESTA_BUILD_DIR)/isa_pkg
ISA_PKG_FLIST := $(VERIF_DIR)/filelists/rv32_isa_pkg.f

# ALU unit-test paths
ALU_BUILD    := $(QUESTA_BUILD_DIR)/alu
ALU_FLIST    := $(VERIF_DIR)/filelists/alu.f

# Immediate generator unit-test paths
IMMGEN_BUILD := $(QUESTA_BUILD_DIR)/imm_gen
IMMGEN_FLIST := $(VERIF_DIR)/filelists/imm_gen.f

# Decoder unit-test paths
DECODER_BUILD := $(QUESTA_BUILD_DIR)/decoder
DECODER_FLIST := $(VERIF_DIR)/filelists/decoder.f

# Register file unit-test paths
REGFILE_BUILD := $(QUESTA_BUILD_DIR)/regfile
REGFILE_FLIST := $(VERIF_DIR)/filelists/regfile.f

# Branch unit unit-test paths
BRANCH_BUILD  := $(QUESTA_BUILD_DIR)/branch_unit
BRANCH_FLIST  := $(VERIF_DIR)/filelists/branch_unit.f

# Pipeline package unit-test paths
PIPELINE_BUILD := $(QUESTA_BUILD_DIR)/pipeline_pkg
PIPELINE_FLIST := $(VERIF_DIR)/filelists/pipeline_pkg.f

# Execute stage unit-test paths
EXSTAGE_BUILD := $(QUESTA_BUILD_DIR)/execute_stage

# Memory stage unit-test paths
MEMSTAGE_BUILD := $(QUESTA_BUILD_DIR)/mem_stage

# Writeback stage unit-test paths
WBSTAGE_BUILD := $(QUESTA_BUILD_DIR)/wb_stage

# Pipeline control unit test paths
PCTRL_BUILD := $(QUESTA_BUILD_DIR)/pipeline_ctrl

# Forwarding unit test paths
FWDUNIT_BUILD := $(QUESTA_BUILD_DIR)/forwarding_unit

# LW/SW integration test paths
LWSW_BUILD := $(QUESTA_BUILD_DIR)/lw_sw

# Branch integration test paths
BRANCH_INTEG_BUILD := $(QUESTA_BUILD_DIR)/branch_integ

# JAL/JALR integration test paths
JALJALR_BUILD := $(QUESTA_BUILD_DIR)/jal_jalr

# LUI/AUIPC integration test paths
LUIAUIPC_BUILD := $(QUESTA_BUILD_DIR)/lui_auipc

# CSR unit test paths
CSRUNIT_BUILD := $(QUESTA_BUILD_DIR)/csr_unit

# ECALL/MRET integration test paths
ECALLMRET_BUILD := $(QUESTA_BUILD_DIR)/ecall_mret

# BRAM unit test paths
BRAM_IMEM_BUILD := $(QUESTA_BUILD_DIR)/bram_imem
BRAM_DMEM_BUILD := $(QUESTA_BUILD_DIR)/bram_dmem

# Integration test paths
INTEG_BUILD := $(QUESTA_BUILD_DIR)/integration

# Fetch unit unit-test paths
FETCH_BUILD   := $(QUESTA_BUILD_DIR)/fetch_unit

# Pipeline stage register unit-test paths
IFID_BUILD    := $(QUESTA_BUILD_DIR)/if_id_reg
IDEX_BUILD    := $(QUESTA_BUILD_DIR)/id_ex_reg
EXMEM_BUILD   := $(QUESTA_BUILD_DIR)/ex_mem_reg
MEMWB_BUILD   := $(QUESTA_BUILD_DIR)/mem_wb_reg

# Vivado check script
VIVADO_CHECK_TCL := $(VIVADO_DIR)/scripts/check_environment.tcl
VIVADO_SYNTH_TCL := $(VIVADO_DIR)/scripts/synth_fluxcore_soc.tcl
VIVADO_IMPL_TCL  := $(VIVADO_DIR)/scripts/impl_fluxcore_soc.tcl
VIVADO_BITSTREAM_TCL := $(VIVADO_DIR)/scripts/bitstream_fluxcore_soc.tcl

# ---------------------------------------------------------------------------
# Default target
# ---------------------------------------------------------------------------
.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------
help:
	@echo ""
	@echo "FluxCore — development infrastructure targets"
	@echo "=============================================="
	@echo ""
	@echo "  make setup           Create .venv and install Python dev dependencies"
	@echo "  make check-tools     Detect available tools and report missing ones"
	@echo "  make python-test     Run pytest"
	@echo "  make lint            Run ruff check"
	@echo "  make typecheck       Run mypy"
	@echo "  make check           Run python-test + lint + typecheck"
	@echo "  make questa-smoke    Compile and run RTL infrastructure smoke test"
	@echo "  make pkg-test        Compile and verify fluxcore_pkg in Questa"
	@echo "  make isa-pkg-test    Compile and verify rv32_isa_pkg in Questa"
	@echo "  make alu-test        Compile and verify ALU (directed + randomized) in Questa"
	@echo "  make imm-gen-test    Compile and verify immediate generator in Questa"
	@echo "  make decoder-test    Compile and verify RV32I decoder in Questa"
	@echo "  make regfile-test    Compile and verify register file in Questa"
	@echo "  make branch-unit-test Compile and verify branch comparator in Questa"
	@echo "  make pipeline-pkg-test Compile and verify pipeline payload types in Questa"
	@echo "  make if-id-reg-test  Compile and verify IF/ID stage register in Questa"
	@echo "  make id-ex-reg-test  Compile and verify ID/EX stage register in Questa"
	@echo "  make ex-mem-reg-test Compile and verify EX/MEM stage register in Questa"
	@echo "  make mem-wb-reg-test Compile and verify MEM/WB stage register in Questa"
	@echo "  make fetch-unit-test Compile and verify fetch unit (PC register) in Questa"
	@echo "  make execute-stage-test Compile and verify execute stage datapath in Questa"
	@echo "  make mem-stage-test  Compile and verify memory stage datapath in Questa"
	@echo "  make wb-stage-test   Compile and verify writeback stage in Questa"
	@echo "  make pipeline-ctrl-test Compile and verify pipeline control unit in Questa"
	@echo "  make forwarding-unit-test Compile and verify data forwarding/hazard unit in Questa"
	@echo "  make lw-sw-test      SW/LW round-trip + load-use stall integration test in Questa"
	@echo "  make byte-halfword-test SB/SH/LB/LBU/LH/LHU byte and halfword memory integration test in Questa"
	@echo "  make branch-compare-test BLT/BGE/BLTU/BGEU taken+not-taken integration test in Questa"
	@echo "  make rv32m-test      RV32M MUL/DIV/REM all variants + special-case integration test in Questa"
	@echo "  make rv32i-alu-test  RV32I ALU: all R-type and I-type ops + forwarding integration test in Questa"
	@echo "  make dcache-e2e-test dcache write-through + miss/hit/load-use end-to-end integration test in Questa"
	@echo "  make branch-integ-test Branch direction + forwarded-operand integration test in Questa"
	@echo "  make jal-jalr-test   JAL link-address + JALR forwarded-rs1 integration test in Questa"
	@echo "  make lui-auipc-test  LUI/AUIPC values + LUI+ADDI forwarding integration test in Questa"
	@echo "  make csr-unit-test   CSR register file unit test (mstatus/mtvec/mepc/mcause/mtval) in Questa"
	@echo "  make ecall-mret-test ECALL trap + M-mode CSR handler + MRET return integration test in Questa"
	@echo "  make bram-imem-test  BRAM instruction memory: 1-cycle latency + sequential reads in Questa"
	@echo "  make bram-dmem-test  BRAM data memory: word/byte-enable write+read in Questa"
	@echo "  make integration-test Full pipeline smoke test (all stages wired) in Questa"
	@echo "  make sim-hello-cpi   Run hello_cpi benchmark in full-SoC simulation"
	@echo "  make sim-spmv-csr    Run spmv_csr benchmark in full-SoC simulation"
	@echo "  make sw-hello_cpi    Build hello_cpi benchmark → build/sw/hello_cpi/imem.hex"
	@echo "  make sw-spmv_csr     Build spmv_csr benchmark  → build/sw/spmv_csr/imem.hex"
	@echo "  make sw-all          Build all software benchmarks"
	@echo "  make sw-clean        Remove build/sw/ directory"
	@echo "  make vivado-check    Validate Vivado startup (no project created)"
	@echo "  make vivado-synth    Run non-project Vivado synthesis for fluxcore_soc"
	@echo "  make vivado-impl     Run opt/place/route from the synthesized checkpoint"
	@echo "  make vivado-bitstream Generate bitstream from the routed checkpoint"
	@echo "  make yosys-check     Print Yosys version"
	@echo "  make regress         Run the full self-checking simulation regression"
	@echo "  make sim-hello-uart  Console banner over the UART TX line (full SoC)"
	@echo "  make sim-timer-irq   CLINT timer interrupts through a C trap handler"
	@echo "  make sim-xflux       XFlux custom instructions from C (.insn intrinsics)"
	@echo "  make verilator-lint  Lint all RTL with Verilator (CI engine)"
	@echo "  make program-board   Program the Zybo Z7-20 over JTAG (see program-board docs)"
	@echo "  make synth-analysis  Run CA-formula analysis on Vivado synthesis results"
	@echo "  make formal-verify   Compile Rocq/Coq formal verification proofs (requires coqc)"
	@echo "  make clean           Remove generated outputs inside build/"
	@echo "  make distclean       clean + remove .venv (explicit only)"
	@echo "  make show-config     Print resolved project, tool, and board values"
	@echo ""
	@echo "Local overrides:"
	@echo "  cp config/tools.example.mk config/tools.local.mk"
	@echo "  cp config/board.example.mk config/board.local.mk"
	@echo ""

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------
setup:
	@echo "--- Creating Python virtual environment at .venv ---"
	@if [ ! -d ".venv" ]; then \
		$(PYTHON) -m venv .venv; \
		echo "Virtual environment created."; \
	else \
		echo "Virtual environment already exists at .venv."; \
	fi
	@echo "--- Installing development requirements ---"
	@.venv/bin/pip install --quiet --upgrade pip
	@.venv/bin/pip install --quiet -r requirements-dev.txt
	@echo ""
	@echo "Setup complete. Activate the environment with:"
	@echo "  source .venv/bin/activate"
	@echo ""

# ---------------------------------------------------------------------------
# check-tools
# ---------------------------------------------------------------------------
check-tools:
	@$(PYTHON) $(SCRIPTS_DIR)/check_tools.py \
		--vlog "$(VLOG)" \
		--vsim "$(VSIM)" \
		--vivado "$(VIVADO)" \
		--yosys "$(YOSYS)" \
		--riscv-prefix "$(RISCV_PREFIX)" \
		--python "$(PYTHON)"

# ---------------------------------------------------------------------------
# Python quality targets
# ---------------------------------------------------------------------------
python-test:
	@echo "--- Running pytest ---"
	@PYTHONPATH=models $(PYTEST) $(VERIF_DIR) models/tests

lint:
	@echo "--- Running ruff check ---"
	@$(RUFF) check models/ scripts/

typecheck:
	@echo "--- Running mypy ---"
	@$(MYPY) --config-file pyproject.toml models/fluxcore/ models/tests/

check: python-test lint typecheck
	@echo ""
	@echo "All Python checks passed."

# ---------------------------------------------------------------------------
# Questa smoke test
# ---------------------------------------------------------------------------
questa-smoke:
	@echo "--- Questa infrastructure smoke test ---"
	@if ! command -v $(VLOG) > /dev/null 2>&1; then \
		echo "ERROR: vlog not found (VLOG=$(VLOG))."; \
		echo "       Install Questa and add it to PATH, or set VLOG in config/tools.local.mk."; \
		exit 1; \
	fi
	@if ! command -v $(VSIM) > /dev/null 2>&1; then \
		echo "ERROR: vsim not found (VSIM=$(VSIM))."; \
		echo "       Install Questa and add it to PATH, or set VSIM in config/tools.local.mk."; \
		exit 1; \
	fi
	@mkdir -p "$(SMOKE_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 SMOKE_BUILD="$(SMOKE_BUILD)" \
	 SMOKE_FLIST="$(SMOKE_FLIST)" \
	 SMOKE_DO="$(SMOKE_DO)" \
	 bash "$(SMOKE_SH)"

# ---------------------------------------------------------------------------
# fluxcore_pkg unit test
# ---------------------------------------------------------------------------
pkg-test:
	@echo "--- fluxcore_pkg unit test ---"
	@if ! command -v $(VLOG) > /dev/null 2>&1; then \
		echo "ERROR: vlog not found (VLOG=$(VLOG))."; \
		echo "       Install Questa and add it to PATH, or set VLOG in config/tools.local.mk."; \
		exit 1; \
	fi
	@if ! command -v $(VSIM) > /dev/null 2>&1; then \
		echo "ERROR: vsim not found (VSIM=$(VSIM))."; \
		echo "       Install Questa and add it to PATH, or set VSIM in config/tools.local.mk."; \
		exit 1; \
	fi
	@mkdir -p "$(PKG_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" PKG_BUILD="$(PKG_BUILD)" \
	 bash "$(PKG_SH)"

# ---------------------------------------------------------------------------
# rv32_isa_pkg unit test
# ---------------------------------------------------------------------------
isa-pkg-test:
	@echo "--- rv32_isa_pkg unit test ---"
	@mkdir -p "$(ISA_PKG_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/isa_pkg" \
	     "verification/filelists/rv32_isa_pkg.f" \
	     "sim/questa/run_unit.do" \
	     "tb_rv32_isa_pkg"

# ---------------------------------------------------------------------------
# mem_if_pkg unit test — frozen memory interface contract
# ---------------------------------------------------------------------------
mem-if-pkg-test:
	@echo "--- mem_if_pkg unit test ---"
	@mkdir -p "build/questa/mem_if_pkg"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/mem_if_pkg" \
	     "verification/filelists/mem_if_pkg.f" \
	     "sim/questa/run_unit.do" \
	     "tb_mem_if_pkg"

# ---------------------------------------------------------------------------
# mem_model unit test — configurable-latency behavioral memory
# ---------------------------------------------------------------------------
mem-model-test:
	@echo "--- mem_model unit test ---"
	@mkdir -p "build/questa/mem_model"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/mem_model" \
	     "verification/filelists/mem_model.f" \
	     "sim/questa/run_unit.do" \
	     "tb_mem_model"

dram-model-test:
	@echo "--- DRAM timing model unit test ---"
	@mkdir -p "build/questa/dram_model"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/dram_model" \
	     "verification/filelists/dram_model.f" \
	     "sim/questa/run_unit.do" \
	     "tb_dram_model"

# ---------------------------------------------------------------------------
# ALU unit test
# ---------------------------------------------------------------------------
alu-test:
	@echo "--- ALU unit test ---"
	@mkdir -p "$(ALU_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/alu" \
	     "verification/filelists/alu.f" \
	     "sim/questa/run_unit.do" \
	     "tb_alu"

# ---------------------------------------------------------------------------
# Immediate generator unit test
# ---------------------------------------------------------------------------
imm-gen-test:
	@echo "--- Immediate generator unit test ---"
	@mkdir -p "$(IMMGEN_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/imm_gen" \
	     "verification/filelists/imm_gen.f" \
	     "sim/questa/run_unit.do" \
	     "tb_imm_gen"

# ---------------------------------------------------------------------------
# Decoder unit test
# ---------------------------------------------------------------------------
decoder-test:
	@echo "--- RV32I decoder unit test ---"
	@mkdir -p "$(DECODER_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/decoder" \
	     "verification/filelists/decoder.f" \
	     "sim/questa/run_unit.do" \
	     "tb_decoder"

# ---------------------------------------------------------------------------
# Register file unit test
# ---------------------------------------------------------------------------
regfile-test:
	@echo "--- Register file unit test ---"
	@mkdir -p "$(REGFILE_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/regfile" \
	     "verification/filelists/regfile.f" \
	     "sim/questa/run_unit.do" \
	     "tb_regfile"

# ---------------------------------------------------------------------------
# FP register file unit test (RV32F: 3 read ports, f0 writable)
# ---------------------------------------------------------------------------
FP_REGFILE_BUILD := $(QUESTA_BUILD_DIR)/fp_regfile

fp-regfile-test:
	@echo "--- FP register file unit test ---"
	@mkdir -p "$(FP_REGFILE_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/fp_regfile" \
	     "verification/filelists/fp_regfile.f" \
	     "sim/questa/run_unit.do" \
	     "tb_fp_regfile"

# ---------------------------------------------------------------------------
# RV32F FPU unit tests (combinational ops)
# ---------------------------------------------------------------------------
fp-cvt-test:
	@echo "--- FP convert unit test ---"
	@mkdir -p "$(QUESTA_BUILD_DIR)/fp_cvt"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/fp_cvt" \
	     "verification/filelists/fp_cvt.f" \
	     "sim/questa/run_unit.do" \
	     "tb_fp_cvt"

fp-csr-test:
	@echo "--- FP fcsr flag-accrual end-to-end integration test ---"
	@mkdir -p "$(QUESTA_BUILD_DIR)/fp_csr"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/fp_csr" \
	     "verification/filelists/fp_csr.f" \
	     "sim/questa/run_unit.do" \
	     "tb_fp_csr"

fp-muldiv-test:
	@echo "--- FP FMA + divide/sqrt end-to-end integration test ---"
	@mkdir -p "$(QUESTA_BUILD_DIR)/fp_muldiv"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/fp_muldiv" \
	     "verification/filelists/fp_muldiv.f" \
	     "sim/questa/run_unit.do" \
	     "tb_fp_muldiv"

fp-loadstore-test:
	@echo "--- FP load/store end-to-end integration test ---"
	@mkdir -p "$(QUESTA_BUILD_DIR)/fp_loadstore"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/fp_loadstore" \
	     "verification/filelists/fp_loadstore.f" \
	     "sim/questa/run_unit.do" \
	     "tb_fp_loadstore"

fp-arith-test:
	@echo "--- FP arithmetic end-to-end integration test ---"
	@mkdir -p "$(QUESTA_BUILD_DIR)/fp_arith"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/fp_arith" \
	     "verification/filelists/fp_arith.f" \
	     "sim/questa/run_unit.do" \
	     "tb_fp_arith"

fp-sweep-test:
	@echo "--- FP compliance sweep (golden RNE vectors) ---"
	@mkdir -p "$(QUESTA_BUILD_DIR)/fp_sweep"
	@python3 verification/scripts/fp_vectors.py 256 verification/unit/execution/fp_sweep_vectors.svh
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/fp_sweep" \
	     "verification/filelists/fp_sweep.f" \
	     "sim/questa/run_unit.do" \
	     "tb_fp_sweep"

fp-divsqrt-test:
	@echo "--- FP divide/sqrt unit test ---"
	@mkdir -p "$(QUESTA_BUILD_DIR)/fp_divsqrt"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/fp_divsqrt" \
	     "verification/filelists/fp_divsqrt.f" \
	     "sim/questa/run_unit.do" \
	     "tb_fp_divsqrt"

fp-fma-test:
	@echo "--- FP fused multiply-add unit test ---"
	@mkdir -p "$(QUESTA_BUILD_DIR)/fp_fma"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/fp_fma" \
	     "verification/filelists/fp_fma.f" \
	     "sim/questa/run_unit.do" \
	     "tb_fp_fma"

fp-addsub-test:
	@echo "--- FP add/sub unit test ---"
	@mkdir -p "$(QUESTA_BUILD_DIR)/fp_addsub"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/fp_addsub" \
	     "verification/filelists/fp_addsub.f" \
	     "sim/questa/run_unit.do" \
	     "tb_fp_addsub"

fp-mul-test:
	@echo "--- FP multiply unit test ---"
	@mkdir -p "$(QUESTA_BUILD_DIR)/fp_mul"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/fp_mul" \
	     "verification/filelists/fp_mul.f" \
	     "sim/questa/run_unit.do" \
	     "tb_fp_mul"

fp-short-test:
	@echo "--- FP short-op (sgnj/minmax/cmp/class/fmv) unit test ---"
	@mkdir -p "$(QUESTA_BUILD_DIR)/fp_short"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/fp_short" \
	     "verification/filelists/fp_short.f" \
	     "sim/questa/run_unit.do" \
	     "tb_fp_short"

# ---------------------------------------------------------------------------
# Branch unit test
# ---------------------------------------------------------------------------
branch-unit-test:
	@echo "--- Branch unit test ---"
	@mkdir -p "$(BRANCH_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/branch_unit" \
	     "verification/filelists/branch_unit.f" \
	     "sim/questa/run_unit.do" \
	     "tb_branch_unit"

# ---------------------------------------------------------------------------
# Pipeline package test
# ---------------------------------------------------------------------------
pipeline-pkg-test:
	@echo "--- Pipeline payload types test ---"
	@mkdir -p "$(PIPELINE_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/pipeline_pkg" \
	     "verification/filelists/pipeline_pkg.f" \
	     "sim/questa/run_unit.do" \
	     "tb_pipeline_pkg"

# ---------------------------------------------------------------------------
# Execute stage test
# ---------------------------------------------------------------------------
execute-stage-test:
	@echo "--- Execute stage test ---"
	@mkdir -p "$(EXSTAGE_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/execute_stage" \
	     "verification/filelists/execute_stage.f" \
	     "sim/questa/run_unit.do" \
	     "tb_execute_stage"

# ---------------------------------------------------------------------------
# Memory stage test
# ---------------------------------------------------------------------------
mem-stage-test:
	@echo "--- Memory stage test ---"
	@mkdir -p "$(MEMSTAGE_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/mem_stage" \
	     "verification/filelists/mem_stage.f" \
	     "sim/questa/run_unit.do" \
	     "tb_mem_stage"

# ---------------------------------------------------------------------------
# Integration test — full pipeline
# ---------------------------------------------------------------------------
integration-test:
	@echo "--- Full pipeline integration test ---"
	@mkdir -p "$(INTEG_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/integration" \
	     "verification/filelists/fluxcore_top.f" \
	     "sim/questa/run_unit.do" \
	     "tb_fluxcore_top"

# ---------------------------------------------------------------------------
# Pipeline control unit test
# ---------------------------------------------------------------------------
pipeline-ctrl-test:
	@echo "--- Pipeline control unit test ---"
	@mkdir -p "$(PCTRL_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/pipeline_ctrl" \
	     "verification/filelists/pipeline_ctrl.f" \
	     "sim/questa/run_unit.do" \
	     "tb_pipeline_ctrl"

# ---------------------------------------------------------------------------
# Byte/halfword integration test (SB/SH/LB/LBU/LH/LHU)
# ---------------------------------------------------------------------------
BYTEHALF_BUILD := $(QUESTA_BUILD_DIR)/byte_halfword

byte-halfword-test:
	@echo "--- Byte/halfword memory: SB/SH/LB/LBU/LH/LHU integration test ---"
	@mkdir -p "$(BYTEHALF_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/byte_halfword" \
	     "verification/filelists/byte_halfword.f" \
	     "sim/questa/run_unit.do" \
	     "tb_byte_halfword"

# ---------------------------------------------------------------------------
# Branch compare integration test (BLT/BGE/BLTU/BGEU taken + not-taken)
# ---------------------------------------------------------------------------
BRANCHCMP_BUILD := $(QUESTA_BUILD_DIR)/branch_compare

branch-compare-test:
	@echo "--- Branch comparators: BLT/BGE/BLTU/BGEU integration test ---"
	@mkdir -p "$(BRANCHCMP_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/branch_compare" \
	     "verification/filelists/branch_compare.f" \
	     "sim/questa/run_unit.do" \
	     "tb_branch_compare"

# ---------------------------------------------------------------------------
# RV32M integration test (MUL/MULH/MULHU/MULHSU/DIV/DIVU/REM/REMU + special cases)
# ---------------------------------------------------------------------------
RV32M_BUILD := $(QUESTA_BUILD_DIR)/rv32m

rv32m-test:
	@echo "--- RV32M: MUL/DIV/REM end-to-end integration test ---"
	@mkdir -p "$(RV32M_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/rv32m" \
	     "verification/filelists/rv32m.f" \
	     "sim/questa/run_unit.do" \
	     "tb_rv32m"

# ---------------------------------------------------------------------------
# dcache end-to-end integration test (write-through + miss/hit + stall)
# ---------------------------------------------------------------------------
DCACHE_E2E_BUILD := $(QUESTA_BUILD_DIR)/dcache_e2e

dcache-e2e-test:
	@echo "--- dcache: write-through, miss/hit stall, load-use end-to-end integration test ---"
	@mkdir -p "$(DCACHE_E2E_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/dcache_e2e" \
	     "verification/filelists/dcache_e2e.f" \
	     "sim/questa/run_unit.do" \
	     "tb_dcache_e2e"

# ---------------------------------------------------------------------------
# RV32I ALU integration test (all R-type + I-type + forwarding)
# ---------------------------------------------------------------------------
RV32I_ALU_BUILD := $(QUESTA_BUILD_DIR)/rv32i_alu

rv32i-alu-test:
	@echo "--- RV32I ALU: all R-type and I-type ops + forwarding integration test ---"
	@mkdir -p "$(RV32I_ALU_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/rv32i_alu" \
	     "verification/filelists/rv32i_alu.f" \
	     "sim/questa/run_unit.do" \
	     "tb_rv32i_alu"

# ---------------------------------------------------------------------------
# Branch integration test (not-taken + taken with forwarded operands)
# ---------------------------------------------------------------------------
branch-integ-test:
	@echo "--- Branch direction + forwarded-operand integration test ---"
	@mkdir -p "$(BRANCH_INTEG_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/branch_integ" \
	     "verification/filelists/branch.f" \
	     "sim/questa/run_unit.do" \
	     "tb_branch"

# ---------------------------------------------------------------------------
# CSR unit test (machine-mode CSR register file)
# ---------------------------------------------------------------------------
csr-unit-test:
	@echo "--- CSR register file unit test ---"
	@mkdir -p "$(CSRUNIT_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/csr_unit" \
	     "verification/filelists/csr_unit.f" \
	     "sim/questa/run_unit.do" \
	     "tb_csr_unit"

# ---------------------------------------------------------------------------
# ECALL/MRET integration test (trap + CSR handler + MRET return)
# ---------------------------------------------------------------------------
ecall-mret-test:
	@echo "--- ECALL trap + M-mode CSR handler + MRET return integration test ---"
	@mkdir -p "$(ECALLMRET_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/ecall_mret" \
	     "verification/filelists/ecall_mret.f" \
	     "sim/questa/run_unit.do" \
	     "tb_ecall_mret"

# ---------------------------------------------------------------------------
# dcache unit test (direct-mapped write-through cache)
# ---------------------------------------------------------------------------
DCACHE_BUILD := $(QUESTA_BUILD_DIR)/dcache

dcache-sim:
	@echo "--- dcache unit test ---"
	@mkdir -p "$(DCACHE_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/dcache" \
	     "verification/filelists/dcache.f" \
	     "sim/questa/run_unit.do" \
	     "tb_dcache"

dcache-multiword-test:
	@echo "--- dcache multiword unit test ---"
	@mkdir -p "build/questa/dcache_multiword"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/dcache_multiword" \
	     "verification/filelists/dcache_multiword.f" \
	     "sim/questa/run_unit.do" \
	     "tb_dcache_multiword"

dcache-assoc-test:
	@echo "--- dcache associativity/LRU unit test ---"
	@mkdir -p "build/questa/dcache_assoc"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/dcache_assoc" \
	     "verification/filelists/dcache_assoc.f" \
	     "sim/questa/run_unit.do" \
	     "tb_dcache_assoc"

dcache-wb-test:
	@echo "--- dcache write-policy unit test ---"
	@mkdir -p "build/questa/dcache_wb"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/dcache_wb" \
	     "verification/filelists/dcache_wb.f" \
	     "sim/questa/run_unit.do" \
	     "tb_dcache_wb"

dcache-mshr-test:
	@echo "--- dcache MSHR/hit-under-miss unit test ---"
	@mkdir -p "build/questa/dcache_mshr"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/dcache_mshr" \
	     "verification/filelists/dcache_mshr.f" \
	     "sim/questa/run_unit.do" \
	     "tb_dcache_mshr"

dcache-flush-test:
	@echo "--- dcache maintenance-flush unit test ---"
	@mkdir -p "build/questa/dcache_flush"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/dcache_flush" \
	     "verification/filelists/dcache_flush.f" \
	     "sim/questa/run_unit.do" \
	     "tb_dcache_flush"

dcache-latency-test:
	@echo "--- dcache latency A/B (blocking vs non-blocking) ---"
	@mkdir -p "build/questa/dcache_latency"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/dcache_latency" \
	     "verification/filelists/dcache_latency.f" \
	     "sim/questa/run_unit.do" \
	     "tb_dcache_latency"

dcache-axi-test:
	@echo "--- dcache over AXI4 adapter + behavioral slave ---"
	@mkdir -p "build/questa/dcache_axi"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/dcache_axi" \
	     "verification/filelists/dcache_axi.f" \
	     "sim/questa/run_unit.do" \
	     "tb_dcache_axi"

l2-cache-test:
	@echo "--- L2 cache unit test ---"
	@mkdir -p "build/questa/l2_cache"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/l2_cache" \
	     "verification/filelists/l2_cache.f" \
	     "sim/questa/run_unit.do" \
	     "tb_l2_cache"

l2-chain-test:
	@echo "--- D\$$ -> arbiter -> L2 -> memory chain test ---"
	@mkdir -p "build/questa/l2_chain"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/l2_chain" \
	     "verification/filelists/l2_chain.f" \
	     "sim/questa/run_unit.do" \
	     "tb_l2_chain"

icache-test:
	@echo "--- I-cache unit test ---"
	@mkdir -p "build/questa/icache"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/icache" \
	     "verification/filelists/icache.f" \
	     "sim/questa/run_unit.do" \
	     "tb_icache"

fencei-test:
	@echo "--- FENCE.I integration test ---"
	@mkdir -p "build/questa/fencei"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/fencei" \
	     "verification/filelists/fencei.f" \
	     "sim/questa/run_unit.do" \
	     "tb_fencei"

amo-test:
	@echo "--- RV32A integration test ---"
	@mkdir -p "build/questa/amo"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/amo" \
	     "verification/filelists/amo.f" \
	     "sim/questa/run_unit.do" \
	     "tb_amo"

btb-predict-test:
	@echo "--- branch prediction integration test ---"
	@mkdir -p "build/questa/btb_predict"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/btb_predict" \
	     "verification/filelists/btb_predict.f" \
	     "sim/questa/run_unit.do" \
	     "tb_btb_predict"

# ---------------------------------------------------------------------------
# Full-SoC benchmark simulations (loads real imem.hex, checks result block)
# ---------------------------------------------------------------------------
SOC_BENCH_FLIST := verification/filelists/soc_benchmark.f
SOC_BENCH_BUILD := $(QUESTA_BUILD_DIR)/soc_benchmark

sim-hello-cpi: $(BUILD_DIR)/sw/hello_cpi/imem.hex
	@echo "--- SoC benchmark simulation: hello_cpi ---"
	@mkdir -p "$(SOC_BENCH_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "$(SOC_BENCH_BUILD)" \
	     "$(SOC_BENCH_FLIST)" \
	     "sim/questa/run_unit.do" \
	     "tb_hello_cpi"

sim-spmv-csr: $(BUILD_DIR)/sw/spmv_csr/imem.hex
	@echo "--- SoC benchmark simulation: spmv_csr ---"
	@mkdir -p "$(SOC_BENCH_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "$(SOC_BENCH_BUILD)" \
	     "$(SOC_BENCH_FLIST)" \
	     "sim/questa/run_unit.do" \
	     "tb_spmv_csr"

sim-csr-probe: $(BUILD_DIR)/sw/csr_probe/imem.hex
	@echo "--- SoC benchmark simulation: csr_probe (counter diagnostic) ---"
	@mkdir -p "$(SOC_BENCH_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "$(SOC_BENCH_BUILD)" \
	     "$(SOC_BENCH_FLIST)" \
	     "sim/questa/run_unit.do" \
	     "tb_csr_probe"

sim-hello-uart: $(BUILD_DIR)/sw/hello_uart/imem.hex
	@echo "--- SoC console simulation: hello_uart (banner over TX line) ---"
	@mkdir -p "$(SOC_BENCH_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "$(SOC_BENCH_BUILD)" \
	     "$(SOC_BENCH_FLIST)" \
	     "sim/questa/run_unit.do" \
	     "tb_soc_uart"

sim-timer-irq: $(BUILD_DIR)/sw/timer_irq/imem.hex
	@echo "--- SoC interrupt simulation: timer_irq (CLINT + trap handler) ---"
	@mkdir -p "$(SOC_BENCH_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "$(SOC_BENCH_BUILD)" \
	     "$(SOC_BENCH_FLIST)" \
	     "sim/questa/run_unit.do" \
	     "tb_timer_irq"

sim-misalign-trap: $(BUILD_DIR)/sw/misalign_trap/imem.hex
	@echo "--- SoC exception simulation: misalign_trap (fetch misalignment) ---"
	@mkdir -p "$(SOC_BENCH_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "$(SOC_BENCH_BUILD)" \
	     "$(SOC_BENCH_FLIST)" \
	     "sim/questa/run_unit.do" \
	     "tb_misalign_trap"

sim-xflux: $(BUILD_DIR)/sw/xflux_kernel/imem.hex
	@echo "--- SoC benchmark simulation: xflux_kernel (custom ISA from C) ---"
	@mkdir -p "$(SOC_BENCH_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "$(SOC_BENCH_BUILD)" \
	     "$(SOC_BENCH_FLIST)" \
	     "sim/questa/run_unit.do" \
	     "tb_xflux_kernel"

sim-fp-kernel: $(BUILD_DIR)/sw/fp_kernel/imem.hex
	@echo "--- SoC benchmark simulation: fp_kernel (RV32F hard-float from C) ---"
	@mkdir -p "$(SOC_BENCH_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "$(SOC_BENCH_BUILD)" \
	     "$(SOC_BENCH_FLIST)" \
	     "sim/questa/run_unit.do" \
	     "tb_fp_kernel"

sim-hello-cpi-dcache: $(BUILD_DIR)/sw/hello_cpi/imem.hex
	@echo "--- SoC benchmark simulation: hello_cpi with USE_DCACHE=1 ---"
	@mkdir -p "$(SOC_BENCH_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "$(SOC_BENCH_BUILD)" \
	     "$(SOC_BENCH_FLIST)" \
	     "sim/questa/run_unit.do" \
	     "tb_hello_cpi_dcache"

sim-spmv-csr-dcache: $(BUILD_DIR)/sw/spmv_csr/imem.hex
	@echo "--- SoC benchmark simulation: spmv_csr with USE_DCACHE=1 ---"
	@mkdir -p "$(SOC_BENCH_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "$(SOC_BENCH_BUILD)" \
	     "$(SOC_BENCH_FLIST)" \
	     "sim/questa/run_unit.do" \
	     "tb_spmv_csr_dcache"

sim-hello-cpi-caches: $(BUILD_DIR)/sw/hello_cpi/imem.hex
	@echo "--- SoC benchmark simulation: hello_cpi with I\$$ + D\$$ ---"
	@mkdir -p "$(SOC_BENCH_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "$(SOC_BENCH_BUILD)" \
	     "$(SOC_BENCH_FLIST)" \
	     "sim/questa/run_unit.do" \
	     "tb_hello_cpi_caches"

sim-spmv-csr-caches: $(BUILD_DIR)/sw/spmv_csr/imem.hex
	@echo "--- SoC benchmark simulation: spmv_csr with I\$$ + D\$$ ---"
	@mkdir -p "$(SOC_BENCH_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "$(SOC_BENCH_BUILD)" \
	     "$(SOC_BENCH_FLIST)" \
	     "sim/questa/run_unit.do" \
	     "tb_spmv_csr_caches"

# ---------------------------------------------------------------------------
# BRAM instruction memory unit test (1-cycle latency, sequential reads)
# ---------------------------------------------------------------------------
bram-imem-test:
	@echo "--- BRAM instruction memory unit test ---"
	@mkdir -p "$(BRAM_IMEM_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/bram_imem" \
	     "verification/filelists/bram_imem.f" \
	     "sim/questa/run_unit.do" \
	     "tb_bram_imem"

# ---------------------------------------------------------------------------
# BRAM data memory unit test (word and byte-enable write/read)
# ---------------------------------------------------------------------------
bram-dmem-test:
	@echo "--- BRAM data memory unit test ---"
	@mkdir -p "$(BRAM_DMEM_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/bram_dmem" \
	     "verification/filelists/bram_dmem.f" \
	     "sim/questa/run_unit.do" \
	     "tb_bram_dmem"

# ---------------------------------------------------------------------------
# JAL/JALR integration test (link address + forwarded rs1 for JALR)
# ---------------------------------------------------------------------------
jal-jalr-test:
	@echo "--- JAL/JALR link-address and forwarded-target integration test ---"
	@mkdir -p "$(JALJALR_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/jal_jalr" \
	     "verification/filelists/jal_jalr.f" \
	     "sim/questa/run_unit.do" \
	     "tb_jal_jalr"

# ---------------------------------------------------------------------------
# LUI/AUIPC integration test (upper-immediate values + LUI+ADDI forwarding)
# ---------------------------------------------------------------------------
lui-auipc-test:
	@echo "--- LUI/AUIPC values and LUI+ADDI forwarding integration test ---"
	@mkdir -p "$(LUIAUIPC_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/lui_auipc" \
	     "verification/filelists/lui_auipc.f" \
	     "sim/questa/run_unit.do" \
	     "tb_lui_auipc"

# ---------------------------------------------------------------------------
# LW/SW integration test (SW/LW round-trip + load-use stall)
# ---------------------------------------------------------------------------
lw-sw-test:
	@echo "--- LW/SW round-trip + load-use stall integration test ---"
	@mkdir -p "$(LWSW_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/lw_sw" \
	     "verification/filelists/lw_sw.f" \
	     "sim/questa/run_unit.do" \
	     "tb_lw_sw"

# ---------------------------------------------------------------------------
# Forwarding unit test
# ---------------------------------------------------------------------------
forwarding-unit-test:
	@echo "--- Forwarding unit test ---"
	@mkdir -p "$(FWDUNIT_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/forwarding_unit" \
	     "verification/filelists/forwarding_unit.f" \
	     "sim/questa/run_unit.do" \
	     "tb_forwarding_unit"

# ---------------------------------------------------------------------------
# Writeback stage test
# ---------------------------------------------------------------------------
wb-stage-test:
	@echo "--- Writeback stage test ---"
	@mkdir -p "$(WBSTAGE_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/wb_stage" \
	     "verification/filelists/wb_stage.f" \
	     "sim/questa/run_unit.do" \
	     "tb_wb_stage"

# ---------------------------------------------------------------------------
# Fetch unit test
# ---------------------------------------------------------------------------
fetch-unit-test:
	@echo "--- Fetch unit test ---"
	@mkdir -p "$(FETCH_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/fetch_unit" \
	     "verification/filelists/fetch_unit.f" \
	     "sim/questa/run_unit.do" \
	     "tb_fetch_unit"

# ---------------------------------------------------------------------------
# Pipeline stage register tests
# ---------------------------------------------------------------------------
if-id-reg-test:
	@echo "--- IF/ID stage register test ---"
	@mkdir -p "$(IFID_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/if_id_reg" \
	     "verification/filelists/if_id_reg.f" \
	     "sim/questa/run_unit.do" \
	     "tb_if_id_reg"

id-ex-reg-test:
	@echo "--- ID/EX stage register test ---"
	@mkdir -p "$(IDEX_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/id_ex_reg" \
	     "verification/filelists/id_ex_reg.f" \
	     "sim/questa/run_unit.do" \
	     "tb_id_ex_reg"

ex-mem-reg-test:
	@echo "--- EX/MEM stage register test ---"
	@mkdir -p "$(EXMEM_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/ex_mem_reg" \
	     "verification/filelists/ex_mem_reg.f" \
	     "sim/questa/run_unit.do" \
	     "tb_ex_mem_reg"

mem-wb-reg-test:
	@echo "--- MEM/WB stage register test ---"
	@mkdir -p "$(MEMWB_BUILD)"
	@VLOG="$(VLOG)" VSIM="$(VSIM)" \
	 bash "$(SIM_RUN)" \
	     "build/questa/mem_wb_reg" \
	     "verification/filelists/mem_wb_reg.f" \
	     "sim/questa/run_unit.do" \
	     "tb_mem_wb_reg"

# ---------------------------------------------------------------------------
# Vivado check
# ---------------------------------------------------------------------------
vivado-check:
	@echo "--- Vivado environment check ---"
	@if ! command -v $(VIVADO) > /dev/null 2>&1; then \
		echo "ERROR: vivado not found (VIVADO=$(VIVADO))."; \
		echo "       Install Vivado and add it to PATH, or set VIVADO in config/tools.local.mk."; \
		exit 1; \
	fi
	@$(VIVADO) -mode batch -source "$(VIVADO_CHECK_TCL)" \
		-tclargs "$(BOARD_MODEL)" \
		-nolog -nojournal

vivado-synth:
	@echo "--- Vivado synthesis: fluxcore_soc ---"
	@if ! command -v $(VIVADO) > /dev/null 2>&1; then \
		echo "ERROR: vivado not found (VIVADO=$(VIVADO))."; \
		echo "       Install Vivado and add it to PATH, or set VIVADO in config/tools.local.mk."; \
		exit 1; \
	fi
	@if [ "$(FPGA_PART)" = "UNCONFIRMED" ]; then \
		echo "ERROR: FPGA_PART is UNCONFIRMED. Update config/board.local.mk first."; \
		exit 1; \
	fi
	@$(VIVADO) -mode batch -source "$(VIVADO_SYNTH_TCL)" \
		-tclargs "$(FPGA_PART)" $(if $(SW_PROG),"build/sw/$(SW_PROG)/imem.hex") \
		-nolog -nojournal

vivado-impl:
	@echo "--- Vivado implementation: fluxcore_soc ---"
	@if ! command -v $(VIVADO) > /dev/null 2>&1; then \
		echo "ERROR: vivado not found (VIVADO=$(VIVADO))."; \
		echo "       Install Vivado and add it to PATH, or set VIVADO in config/tools.local.mk."; \
		exit 1; \
	fi
	@if [ ! -f "$(BUILD_DIR)/vivado/fluxcore_soc_synth.dcp" ]; then \
		echo "INFO: synthesized checkpoint missing; running vivado-synth first."; \
		$(MAKE) vivado-synth; \
	fi
	@$(VIVADO) -mode batch -source "$(VIVADO_IMPL_TCL)" \
		-nolog -nojournal

vivado-bitstream:
	@echo "--- Vivado bitstream: fluxcore_soc ---"
	@if ! command -v $(VIVADO) > /dev/null 2>&1; then \
		echo "ERROR: vivado not found (VIVADO=$(VIVADO))."; \
		echo "       Install Vivado and add it to PATH, or set VIVADO in config/tools.local.mk."; \
		exit 1; \
	fi
	@if [ ! -f "$(BUILD_DIR)/vivado/fluxcore_soc_route.dcp" ]; then \
		echo "INFO: routed checkpoint missing; running vivado-impl first."; \
		$(MAKE) vivado-impl; \
	fi
	@$(VIVADO) -mode batch -source "$(VIVADO_BITSTREAM_TCL)" \
		-nolog -nojournal

# ---------------------------------------------------------------------------
# Program the Zybo Z7-20 over JTAG with the generated bitstream.
# Full flow: make sw-board_hello
#            make vivado-synth SW_PROG=board_hello
#            make vivado-impl && make vivado-bitstream && make program-board
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Verilator lint over the full RTL (CI engine; xsim remains signoff)
# ---------------------------------------------------------------------------
verilator-lint:
	@if ! command -v verilator > /dev/null 2>&1; then \
		echo "ERROR: verilator not found. Install: sudo apt install verilator"; \
		exit 1; \
	fi
	@echo "--- Verilator lint (rtl_all.f) ---"
	@verilator --lint-only -sv -Wall -Wno-fatal \
		-Wno-VARHIDDEN -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
		--top-module fluxcore_soc \
		-f verification/filelists/rtl_all.f
	@echo "verilator-lint complete."

program-board:
	@echo "--- Programming Zybo Z7-20 ---"
	@if ! command -v $(VIVADO) > /dev/null 2>&1; then \
		echo "ERROR: vivado not found (VIVADO=$(VIVADO))."; \
		exit 1; \
	fi
	@$(VIVADO) -mode batch -source vivado/scripts/program_fluxcore_soc.tcl \
		-nolog -nojournal

# ---------------------------------------------------------------------------
# Umbrella regression — every self-checking sim target, one dated report
# ---------------------------------------------------------------------------
regress:
	@SIM_RUN="$(SIM_RUN)" bash verification/scripts/regress.sh

# ---------------------------------------------------------------------------
# Formal verification (Rocq/Coq)
# ---------------------------------------------------------------------------
synth-analysis:
	@echo "--- FluxCore synthesis analysis (CA formulas) ---"
	@python3 synth/analysis/ca_metrics.py

formal-verify:
	@echo "--- Rocq/Coq formal verification (build + no-Admitted gate) ---"
	@if command -v opam > /dev/null 2>&1 && opam exec -- which coqc > /dev/null 2>&1; then \
		opam exec -- $(MAKE) -C verification/formal check; \
	elif command -v coqc > /dev/null 2>&1; then \
		$(MAKE) -C verification/formal check; \
	else \
		echo "ERROR: coqc not found. Install Rocq via opam (opam install rocq-prover) and add to PATH."; \
		exit 1; \
	fi

# ---------------------------------------------------------------------------
# Yosys check
# ---------------------------------------------------------------------------
yosys-check:
	@echo "--- Yosys version check ---"
	@if command -v $(YOSYS) > /dev/null 2>&1; then \
		$(YOSYS) --version; \
	else \
		echo "INFO: yosys not found (YOSYS=$(YOSYS)). Yosys is optional."; \
		echo "      Install Yosys or set YOSYS in config/tools.local.mk."; \
	fi

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Software build — bare-metal benchmarks for FluxCore
# ---------------------------------------------------------------------------
SW_DIR       := software
SW_BUILD     := $(BUILD_DIR)/sw
SW_LINKER    := $(SW_DIR)/linker/fluxcore.ld
SW_STARTUP   := $(SW_DIR)/startup/crt0.S
ELF2HEX      := scripts/elf2hex.py

RISCV_CC     := $(RISCV_PREFIX)gcc
RISCV_OBJCPY := $(RISCV_PREFIX)objcopy
RISCV_SIZE   := $(RISCV_PREFIX)size

# Target ISA: RV32I only (no compressed, no mul/div yet)
SW_ARCH      := rv32i_zicsr
SW_ABI       := ilp32
SW_CFLAGS    := -march=$(SW_ARCH) -mabi=$(SW_ABI) \
                -Os -g \
                -ffreestanding -fno-builtin -nostdlib -nostartfiles \
                -Wall -Wextra \
                -I$(SW_DIR)/runtime
SW_LDFLAGS   := -T$(SW_LINKER) -Wl,--gc-sections

# Convenience: build one benchmark
# $(1) = benchmark name (no extension), $(2) = source c file
define sw_bench
$(SW_BUILD)/$(1)/$(1).elf: $(SW_DIR)/benchmarks/$(2) $(SW_STARTUP) $(SW_LINKER) | $(SW_BUILD)/$(1)
	$(RISCV_CC) $(SW_CFLAGS) $(SW_LDFLAGS) \
	    $(SW_STARTUP) $$< -o $$@ -lgcc
	$(RISCV_SIZE) $$@

$(SW_BUILD)/$(1)/imem.hex: $(SW_BUILD)/$(1)/$(1).elf $(ELF2HEX) | $(SW_BUILD)/$(1)
	python3 $(ELF2HEX) $$< $$@ --base 0x00000000 --depth 4096

$(SW_BUILD)/$(1):
	@mkdir -p $$@

sw-$(1): $(SW_BUILD)/$(1)/imem.hex
	@echo "--- sw-$(1): IMEM hex ready at $(SW_BUILD)/$(1)/imem.hex ---"
endef

$(eval $(call sw_bench,hello_cpi,hello_cpi.c))
$(eval $(call sw_bench,spmv_csr,spmv_csr.c))
$(eval $(call sw_bench,csr_probe,csr_probe.c))
$(eval $(call sw_bench,hello_uart,hello_uart.c))
$(eval $(call sw_bench,timer_irq,timer_irq.c))
$(eval $(call sw_bench,misalign_trap,misalign_trap.c))
$(eval $(call sw_bench,board_hello,board_hello.c))
$(eval $(call sw_bench,xflux_kernel,xflux_kernel.c))

# RV32F variant: same recipe with the F extension enabled so the compiler
# emits hard-float instructions for the FP demonstration kernel.
SW_CFLAGS_FP := -march=rv32imf_zicsr -mabi=$(SW_ABI) \
                -Os -g \
                -ffreestanding -fno-builtin -nostdlib -nostartfiles \
                -Wall -Wextra \
                -I$(SW_DIR)/runtime

define sw_bench_fp
$(SW_BUILD)/$(1)/$(1).elf: $(SW_DIR)/benchmarks/$(2) $(SW_STARTUP) $(SW_LINKER) | $(SW_BUILD)/$(1)
	$(RISCV_CC) $(SW_CFLAGS_FP) $(SW_LDFLAGS) \
	    $(SW_STARTUP) $$< -o $$@ -lgcc
	$(RISCV_SIZE) $$@

$(SW_BUILD)/$(1)/imem.hex: $(SW_BUILD)/$(1)/$(1).elf $(ELF2HEX) | $(SW_BUILD)/$(1)
	python3 $(ELF2HEX) $$< $$@ --base 0x00000000 --depth 4096

$(SW_BUILD)/$(1):
	@mkdir -p $$@

sw-$(1): $(SW_BUILD)/$(1)/imem.hex
	@echo "--- sw-$(1): IMEM hex ready at $(SW_BUILD)/$(1)/imem.hex ---"
endef

$(eval $(call sw_bench_fp,fp_kernel,fp_kernel.c))

sw-spmv: sw-spmv_csr

sw-all: sw-hello_cpi sw-spmv_csr

sw-clean:
	@rm -rf $(SW_BUILD)
	@echo "sw-clean complete."

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------
clean:
	@echo "--- Removing generated build outputs ---"
	@rm -rf "$(BUILD_DIR)"/questa "$(BUILD_DIR)"/sw
	@rm -rf .Xil
	@find . -name "*.jou" -not -path "./.venv/*" -delete 2>/dev/null || true
	@find . -name "*.pb"  -not -path "./.venv/*" -delete 2>/dev/null || true
	@find . -type d -name "xsim.dir" -not -path "./.venv/*" -exec rm -rf {} + 2>/dev/null || true
	@find . -type d -name "__pycache__" -not -path "./.venv/*" -exec rm -rf {} + 2>/dev/null || true
	@find . -type d -name ".pytest_cache" -not -path "./.venv/*" -exec rm -rf {} + 2>/dev/null || true
	@find . -type d -name ".mypy_cache"   -not -path "./.venv/*" -exec rm -rf {} + 2>/dev/null || true
	@find . -type d -name ".ruff_cache"   -not -path "./.venv/*" -exec rm -rf {} + 2>/dev/null || true
	@echo "Clean complete."

distclean: clean
	@echo "--- Removing virtual environment ---"
	@rm -rf .venv
	@echo "distclean complete."

# ---------------------------------------------------------------------------
# show-config
# ---------------------------------------------------------------------------
show-config:
	@echo ""
	@echo "FluxCore resolved configuration"
	@echo "================================"
	@echo ""
	@echo "Project"
	@echo "  PROJECT_NAME   : $(PROJECT_NAME)"
	@echo "  BUILD_DIR      : $(BUILD_DIR)"
	@echo "  REPORT_DIR     : $(REPORT_DIR)"
	@echo "  RTL_DIR        : $(RTL_DIR)"
	@echo "  XLEN           : $(XLEN)"
	@echo "  THREADS        : $(BASELINE_THREADS)"
	@echo ""
	@echo "Tools"
	@echo "  PYTHON         : $(PYTHON)"
	@echo "  VLOG           : $(VLOG)"
	@echo "  VSIM           : $(VSIM)"
	@echo "  VIVADO         : $(VIVADO)"
	@echo "  YOSYS          : $(YOSYS)"
	@echo "  RISCV_PREFIX   : $(RISCV_PREFIX)"
	@echo ""
	@echo "Board (must be confirmed before synthesis)"
	@echo "  BOARD_MODEL    : $(BOARD_MODEL)"
	@echo "  FPGA_PART      : $(FPGA_PART)"
	@echo "  BOARD_PART     : $(BOARD_PART)"
	@echo ""
