(* verification/formal/koika/Impl/FluxBranchImpl.v
 *
 * Kôika combinational circuits for the FluxCore branch-resolution unit — the
 * Impl half of the branch refinement.  Each circuit is a single comparison
 * primitive producing the 1-bit "taken" result; Refine/FluxBranchRefine.v proves
 * each partial-evaluates to `branch_taken` from Spec/FluxBranch.v.
 *)

From Koika Require Import Prelude.
From Flux Require Import FluxCommon.

#[local] Set Default Timeout 60.

Section branch_circuits.
  Context {mod_t} `{M : Modules.t mod_t} {V : nat -> Type}.

  (* Equality tests (BEQ / BNE) — the EqBits primitive. *)
  Definition branch_eq_expr  (a b : V 32) : PureExpr V 1 := Abbr.eq  ${a} ${b}.
  Definition branch_ne_expr  (a b : V 32) : PureExpr V 1 := Abbr.neq ${a} ${b}.

  (* Signed ordering (BLT / BGE) — Compare with the signed flag set. *)
  Definition branch_lt_expr  (a b : V 32) : PureExpr V 1 := Abbr.slt ${a} ${b}.
  Definition branch_ge_expr  (a b : V 32) : PureExpr V 1 := Abbr.sge ${a} ${b}.

  (* Unsigned ordering (BLTU / BGEU) — Compare with the signed flag clear. *)
  Definition branch_ltu_expr (a b : V 32) : PureExpr V 1 := Abbr.lt  ${a} ${b}.
  Definition branch_geu_expr (a b : V 32) : PureExpr V 1 := Abbr.ge  ${a} ${b}.
End branch_circuits.
