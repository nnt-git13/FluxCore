# Formal verification Makefile — FluxCore Rocq/Coq proofs
#
# Usage:
#   make           — compile all .v files (requires coqc in PATH)
#   make check     — same as default target (alias)
#   make clean     — remove compiled .vo, .glob, .aux files
#
# Run from the repo root:
#   make -C verification/formal

COQC   ?= coqc
COQFLAGS := -R . FluxCore

SRCS := FluxCoreTypes.v FluxCoreISA.v FluxCorePipeline.v PipelineCorrectness.v FluxCoreSPMV.v

VO := $(SRCS:.v=.vo)

.PHONY: all check clean

all: $(VO)

check: all

%.vo: %.v
	$(COQC) $(COQFLAGS) $<

# Dependencies (explicit ordering required)
FluxCoreTypes.vo:       FluxCoreTypes.v
FluxCoreISA.vo:         FluxCoreISA.v  FluxCoreTypes.vo
FluxCorePipeline.vo:    FluxCorePipeline.v  FluxCoreISA.vo
PipelineCorrectness.vo: PipelineCorrectness.v  FluxCorePipeline.vo
FluxCoreSPMV.vo:        FluxCoreSPMV.v         PipelineCorrectness.vo

clean:
	rm -f *.vo *.glob *.aux .*.aux
