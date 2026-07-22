(* verification/formal/koika/FluxCommon.v
 *
 * Shared types for the FluxCore ↔ Kôika formal port.
 *
 * This is the Kôika/Rocq re-expression of the FluxCore project (Path A: prove
 * the hardware refines the ISA specification).  It lives alongside — not in
 * place of — the SystemVerilog RTL under rtl/.  The RTL is unchanged; this
 * directory builds a Kôika model of the same design and states/proves that it
 * refines a machine-checked reference semantics.
 *
 * Word width and the register-index type match FluxCore's fluxcore_pkg.sv
 * (XLEN=32, 32 architectural registers).
 *)

From Koika Require Import Prelude.

(* 32-bit data word — fluxcore_pkg.sv word_t. *)
Notation Word := (bits 32).

(* Number of architectural registers (integer or FP file) — REG_COUNT. *)
Definition RegCount : nat := 32.

(* A 5-bit register index — reg_idx_t. *)
Notation RegIdx := (bits 5).
