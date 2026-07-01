# config/project.mk — Repository-relative project defaults
#
# This file is committed and defines stable project-wide defaults.
# Do NOT add machine-specific paths here.
# Override values in config/tools.local.mk or config/board.local.mk (not committed).

# ---------------------------------------------------------------------------
# Project identity
# ---------------------------------------------------------------------------
PROJECT_NAME     := fluxcore

# ---------------------------------------------------------------------------
# Directory layout (repository-relative)
# ---------------------------------------------------------------------------
BUILD_DIR        := build
REPORT_DIR       := reports
RTL_DIR          := rtl
VERIF_DIR        := verification
MODEL_DIR        := models
SOFTWARE_DIR     := software
SIM_DIR          := sim
VIVADO_DIR       := vivado
SYNTH_DIR        := synth
SCRIPTS_DIR      := scripts

# Questa-specific build outputs
QUESTA_BUILD_DIR := $(BUILD_DIR)/questa

# ---------------------------------------------------------------------------
# Python
# ---------------------------------------------------------------------------
PYTHON           ?= python3

# Prefer the project virtual environment when present
ifneq (,$(wildcard .venv/bin/python))
PYTHON           := .venv/bin/python
endif

PYTEST           := $(PYTHON) -m pytest
RUFF             := $(PYTHON) -m ruff
MYPY             := $(PYTHON) -m mypy

# ---------------------------------------------------------------------------
# Baseline architectural parameters (informational; not synthesized here)
# ---------------------------------------------------------------------------
XLEN             := 32
BASELINE_THREADS := 1
