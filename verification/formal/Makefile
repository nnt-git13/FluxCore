# Formal verification Makefile — FluxCore Rocq/Coq proofs
#
# Layout (inspired by the ModularKoika GPU proof: per-module Spec / Impl /
# Refine separation, kernels proven end-to-end on top):
#
#   Common/   shared types (32-bit words, register-file algebra)
#   Spec/     trusted specifications (sequential ISA semantics)
#   Impl/     models of the RTL implementation (forwarding pipeline,
#             CSR counter update logic)
#   Refine/   proofs that each Impl refines its Spec (one dir per module,
#             composed theorem in Top.v)
#   Kernels/  end-to-end program proofs on the ISA machine (SpMV CSR loop)
#   wip/      unfinished proofs — NOT built, NOT claimed (see README.md)
#
# Usage:
#   make            — compile the shipping proof set (requires coqc)
#   make check      — build + verify the shipping set contains no Admitted
#   make clean      — remove compiled artifacts
#
# Run from the repo root:  make -C verification/formal

COQC     ?= coqc
COQFLAGS := -R . FluxCore

SRCS := \
    Common/Types.v \
    Spec/ISA.v \
    Impl/Pipeline.v \
    Impl/CsrCounter.v \
    Refine/Pipeline/Top.v \
    Refine/CsrCounter/Top.v \
    Kernels/SPMV.v

VO := $(SRCS:.v=.vo)

.PHONY: all check no-admitted clean

all: $(VO)

check: all no-admitted

no-admitted:
	@bash ../scripts/check_no_admitted.sh

%.vo: %.v
	$(COQC) $(COQFLAGS) $<

# Dependencies (explicit ordering)
Common/Types.vo:          Common/Types.v
Spec/ISA.vo:              Spec/ISA.v          Common/Types.vo
Impl/Pipeline.vo:         Impl/Pipeline.v     Spec/ISA.vo
Impl/CsrCounter.vo:       Impl/CsrCounter.v   Common/Types.vo
Refine/Pipeline/Top.vo:   Refine/Pipeline/Top.v   Impl/Pipeline.vo
Refine/CsrCounter/Top.vo: Refine/CsrCounter/Top.v Impl/CsrCounter.vo
Kernels/SPMV.vo:          Kernels/SPMV.v      Common/Types.vo

clean:
	find . \( -name '*.vo' -o -name '*.vok' -o -name '*.vos' \
	       -o -name '*.glob' -o -name '.*.aux' \) -delete
