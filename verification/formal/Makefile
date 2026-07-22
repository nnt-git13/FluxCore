# verification/formal/Makefile
#
# FluxCore formal verification — the Kôika Path-A refinement proof.
#
# The former model-level Coq proofs (hand-written models of the RTL, with no
# mechanical RTL↔Coq link) have been retired in favour of a single, sound
# approach: the design is re-expressed in Kôika — which has formal Rocq
# semantics AND compiles to Verilog — and proven to refine the ISA spec, so the
# object proven is the object synthesised.  All of that lives under koika/.
#
# Build requires opam Rocq 9.1 and a ModularKoika checkout (MK below).  When
# those are absent (e.g. minimal CI), `check` skips the build with a message
# rather than failing; the no-Admitted gate still runs over the sources.
#
#   make check MK=/path/to/ModularKoika
#   make clean

MK ?= $(HOME)/Desktop/CSAIL_UROP/ModularKoika

.PHONY: all check clean

all check:
	@if [ ! -d "$(MK)/coq" ]; then \
	  echo "formal: ModularKoika not found at MK=$(MK); skipping Koika proof build."; \
	  echo "        Full build needs opam Rocq 9.1 + a ModularKoika checkout — see koika/README.md."; \
	else \
	  echo "--- building Koika Path-A proof (koika/) ---"; \
	  $(MAKE) -C koika MK="$(MK)"; \
	fi
	@bash ../scripts/check_no_admitted.sh

clean:
	@$(MAKE) -C koika clean MK="$(MK)" 2>/dev/null || true
