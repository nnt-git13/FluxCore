# config/tools.example.mk — Example user-local tool overrides
#
# Copy this file to config/tools.local.mk and fill in your local paths.
# config/tools.local.mk is git-ignored and must NOT be committed.
#
# Usage:
#   cp config/tools.example.mk config/tools.local.mk
#   # Edit config/tools.local.mk
#
# If a variable is not set here it falls back to the system PATH.
# The Makefile includes config/tools.local.mk with -include so this file
# is not required to exist.

# ---------------------------------------------------------------------------
# Questa (ModelSim/QuestaSim)
# ---------------------------------------------------------------------------
# VLOG  ?= /opt/questasim/bin/vlog
# VSIM  ?= /opt/questasim/bin/vsim

VLOG  ?= vlog
VSIM  ?= vsim

# ---------------------------------------------------------------------------
# Vivado
# ---------------------------------------------------------------------------
# VIVADO ?= /tools/Xilinx/Vivado/2024.1/bin/vivado

VIVADO ?= vivado

# ---------------------------------------------------------------------------
# Yosys (optional, for generic synthesis checks)
# ---------------------------------------------------------------------------
# YOSYS ?= /usr/local/bin/yosys

YOSYS ?= yosys

# ---------------------------------------------------------------------------
# RISC-V GNU toolchain
# ---------------------------------------------------------------------------
# Set the prefix for the cross-compiler. For a bare-metal RV32I target the
# typical prefix is riscv32-unknown-elf- or riscv64-unknown-elf-.
# Adjust to match your local toolchain installation.
#
# RISCV_PREFIX ?= riscv32-unknown-elf-
# RISCV_PREFIX ?= riscv64-unknown-elf-

RISCV_PREFIX ?= riscv32-unknown-elf-

# ---------------------------------------------------------------------------
# Python
# ---------------------------------------------------------------------------
# Override if your Python 3.11+ interpreter is not on PATH as 'python3'.
#
# PYTHON ?= python3.11

PYTHON ?= python3
