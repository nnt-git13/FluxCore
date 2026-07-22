# verification/formal/koika/Makefile
#
# Builds the FluxCore ↔ Kôika Path-A formal development.
#
# Requirements (see README.md):
#   - opam Rocq 9.1 (the `rocq`/`coqc` that built ModularKoika; NOT system 8.18)
#   - a built ModularKoika checkout, path given by MK below (override on the CLI)
#
# Usage:
#   make MK=/path/to/ModularKoika        # build everything
#   make clean

MK ?= $(HOME)/Desktop/CSAIL_UROP/ModularKoika
# Prefer the opam Rocq 9.1 coqc that built ModularKoika; the system coqc
# (Coq 8.18 on this host) cannot read its .vo files.
OPAM_COQC := $(HOME)/.opam/default/bin/coqc
COQC ?= $(if $(wildcard $(OPAM_COQC)),$(OPAM_COQC),coqc)

FLAGS := -R $(MK)/coq Koika \
         -Q $(MK)/examples/gpu/src Gpu \
         -Q $(MK)/examples/gpu/coqutil/src/coqutil coqutil \
         -Q $(MK)/examples/gpu/riscv-coq/src/riscv riscv \
         -Q . Flux

# Dependency order (packages first, then spec, impl, refine, top).
VFILES := FluxCommon.v \
          Spec/FluxAlu.v \
          Spec/FluxBranch.v \
          Spec/FluxMul.v \
          Spec/FluxIsa.v \
          FluxMem.v \
          FluxProc.v \
          Spec/FluxProcSpec.v \
          Impl/FluxAluImpl.v \
          Impl/FluxBranchImpl.v \
          Impl/FluxMulImpl.v \
          Impl/FluxProcImpl.v \
          Refine/FluxAluRefine.v \
          Refine/FluxBranchRefine.v \
          Refine/FluxMulRefine.v \
          Refine/FluxProcRefine.v \
          Refine/Top.v

all: $(VFILES:.v=.vo)

%.vo: %.v
	$(COQC) $(FLAGS) $<

# Explicit deps so a spec change rebuilds its dependents.
Spec/FluxAlu.vo:      FluxCommon.vo
Spec/FluxBranch.vo:   FluxCommon.vo
Spec/FluxMul.vo:      FluxCommon.vo
Spec/FluxIsa.vo:      FluxCommon.vo Spec/FluxAlu.vo
FluxMem.vo:           FluxCommon.vo
FluxProc.vo:          FluxCommon.vo Spec/FluxAlu.vo Spec/FluxBranch.vo
Spec/FluxProcSpec.vo: FluxCommon.vo Spec/FluxAlu.vo Spec/FluxBranch.vo Spec/FluxMul.vo \
                      Spec/FluxIsa.vo FluxMem.vo FluxProc.vo
Impl/FluxAluImpl.vo:    FluxCommon.vo
Impl/FluxBranchImpl.vo: FluxCommon.vo
Impl/FluxMulImpl.vo:    FluxCommon.vo
Impl/FluxProcImpl.vo:   FluxCommon.vo Spec/FluxAlu.vo Spec/FluxBranch.vo Impl/FluxAluImpl.vo \
                        Impl/FluxBranchImpl.vo Impl/FluxMulImpl.vo FluxMem.vo FluxProc.vo
Refine/FluxAluRefine.vo:    FluxCommon.vo Spec/FluxAlu.vo Impl/FluxAluImpl.vo
Refine/FluxBranchRefine.vo: FluxCommon.vo Spec/FluxBranch.vo Impl/FluxBranchImpl.vo
Refine/FluxMulRefine.vo:    FluxCommon.vo Spec/FluxMul.vo Impl/FluxMulImpl.vo
Refine/FluxProcRefine.vo:   FluxCommon.vo Spec/FluxAlu.vo Spec/FluxBranch.vo Spec/FluxMul.vo \
                            Spec/FluxIsa.vo FluxMem.vo FluxProc.vo Spec/FluxProcSpec.vo \
                            Impl/FluxProcImpl.vo Refine/FluxAluRefine.vo \
                            Refine/FluxBranchRefine.vo Refine/FluxMulRefine.vo
Refine/Top.vo:        Spec/FluxAlu.vo Spec/FluxIsa.vo Impl/FluxAluImpl.vo Refine/FluxAluRefine.vo \
                      Refine/FluxBranchRefine.vo Refine/FluxMulRefine.vo \
                      FluxProc.vo Spec/FluxProcSpec.vo Impl/FluxProcImpl.vo Refine/FluxProcRefine.vo

clean:
	rm -f $(VFILES:.v=.vo) $(VFILES:.v=.vok) $(VFILES:.v=.vos) $(VFILES:.v=.glob)
	rm -f $(addsuffix .aux,$(dir $(VFILES)).*)
	find . -name '.*.aux' -delete

.PHONY: all clean
