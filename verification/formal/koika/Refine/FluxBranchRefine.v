(* verification/formal/koika/Refine/FluxBranchRefine.v
 *
 * Path-A refinement for the FluxCore branch-resolution unit: each Kôika
 * comparison circuit (Impl/FluxBranchImpl.v) partial-evaluates to the 1-bit
 * `branch_taken` reference (Spec/FluxBranch.v).
 *
 *   peval (branch_<op>_expr a b) = inl (Ob~(branch_taken BR_<OP> a b))
 *
 * Simpler than the ALU comparisons: the result IS the predicate bit (no If mux),
 * so once the primitive is unfolded to `Ob~(pred a b)` the two sides coincide.
 *)

From Koika Require Import Prelude.
From Flux Require Import FluxCommon.
From Flux Require Import Spec.FluxBranch.
From Flux Require Import Impl.FluxBranchImpl.

#[local] Set Default Timeout 60.

Section branch_refine.
  Context {mod_t} `{M : Modules.t mod_t}.

  Theorem branch_eq_correct (a b : Word) :
    peval (branch_eq_expr a b) = inl (Ob~(branch_taken BR_EQ a b)).
  Proof.
    unfold branch_eq_expr; cbn [branch_taken peval Abbr.eq
      CircuitPrimSpecs.sigma2]. reflexivity.
  Qed.

  Theorem branch_ne_correct (a b : Word) :
    peval (branch_ne_expr a b) = inl (Ob~(branch_taken BR_NE a b)).
  Proof.
    unfold branch_ne_expr; cbn [branch_taken peval Abbr.neq
      CircuitPrimSpecs.sigma2]. reflexivity.
  Qed.

  Theorem branch_lt_correct (a b : Word) :
    peval (branch_lt_expr a b) = inl (Ob~(branch_taken BR_LT a b)).
  Proof.
    unfold branch_lt_expr; cbn [branch_taken peval Abbr.slt
      CircuitPrimSpecs.sigma2]. reflexivity.
  Qed.

  Theorem branch_ge_correct (a b : Word) :
    peval (branch_ge_expr a b) = inl (Ob~(branch_taken BR_GE a b)).
  Proof.
    unfold branch_ge_expr; cbn [branch_taken peval Abbr.sge
      CircuitPrimSpecs.sigma2]. reflexivity.
  Qed.

  Theorem branch_ltu_correct (a b : Word) :
    peval (branch_ltu_expr a b) = inl (Ob~(branch_taken BR_LTU a b)).
  Proof.
    unfold branch_ltu_expr; cbn [branch_taken peval Abbr.lt
      CircuitPrimSpecs.sigma2]. reflexivity.
  Qed.

  Theorem branch_geu_correct (a b : Word) :
    peval (branch_geu_expr a b) = inl (Ob~(branch_taken BR_GEU a b)).
  Proof.
    unfold branch_geu_expr; cbn [branch_taken peval Abbr.ge
      CircuitPrimSpecs.sigma2]. reflexivity.
  Qed.

End branch_refine.
