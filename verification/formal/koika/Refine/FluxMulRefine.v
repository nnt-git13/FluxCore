(* verification/formal/koika/Refine/FluxMulRefine.v
 *
 * Path-A refinement for the directly-expressible RV32M multiply ops: each Kôika
 * circuit (Impl/FluxMulImpl.v) partial-evaluates to the reference (Spec/FluxMul.v).
 *
 *   peval (mul_lo_expr  a b) = inl (mul_lo  a b)
 *   peval (mul_hiu_expr a b) = inl (mul_hiu a b)
 *
 * The `Abbr.slice` UOp denotes to `Bits.slice` and `Abbr.mul` to `Bits.mul`, so
 * the circuit and the sliced-product spec coincide definitionally.
 *)

From Koika Require Import Prelude.
From Flux Require Import FluxCommon.
From Flux Require Import Spec.FluxMul.
From Flux Require Import Impl.FluxMulImpl.

#[local] Set Default Timeout 60.

Section mul_refine.
  Context {mod_t} `{M : Modules.t mod_t}.

  Theorem mul_lo_correct (a b : Word) :
    peval (mul_lo_expr a b) = inl (mul_lo a b).
  Proof.
    unfold mul_lo_expr, mul_lo, mul_full; cbn [peval Abbr.slice Abbr.mul
      CircuitPrimSpecs.sigma1 CircuitPrimSpecs.sigma2]. reflexivity.
  Qed.

  Theorem mul_hiu_correct (a b : Word) :
    peval (mul_hiu_expr a b) = inl (mul_hiu a b).
  Proof.
    unfold mul_hiu_expr, mul_hiu, mul_full; cbn [peval Abbr.slice Abbr.mul
      CircuitPrimSpecs.sigma1 CircuitPrimSpecs.sigma2]. reflexivity.
  Qed.

  Theorem mul_hi_correct (a b : Word) :
    peval (mul_hi_expr a b) = inl (mul_hi a b).
  Proof.
    unfold mul_hi_expr, mul_hi, sext64; cbn [peval Abbr.slice Abbr.mul
      Abbr.sext CircuitPrimSpecs.sigma1 CircuitPrimSpecs.sigma2].
    reflexivity.
  Qed.

  Theorem mul_hisu_correct (a b : Word) :
    peval (mul_hisu_expr a b) = inl (mul_hisu a b).
  Proof.
    unfold mul_hisu_expr, mul_hisu, sext64, zext64; cbn [peval Abbr.slice
      Abbr.mul Abbr.sext Abbr.zextL
      CircuitPrimSpecs.sigma1 CircuitPrimSpecs.sigma2].
    reflexivity.
  Qed.

End mul_refine.
