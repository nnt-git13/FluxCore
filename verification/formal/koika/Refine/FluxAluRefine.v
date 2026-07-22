(* verification/formal/koika/Refine/FluxAluRefine.v
 *
 * Path-A refinement for the FluxCore ALU datapath: each Kôika combinational
 * circuit (Impl/FluxAluImpl.v) partial-evaluates to the reference function
 * (Spec/FluxAlu.v).  This is the combinational analogue of ModularKoika's
 * `compare_ripple_correct` — the Kôika hardware provably computes the spec.
 *
 *   peval (alu_<op>_expr a b) = inl (alu_spec ALU_<OP> a b)
 *)

From Koika Require Import Prelude.
From Flux Require Import FluxCommon.
From Flux Require Import Spec.FluxAlu.
From Flux Require Import Impl.FluxAluImpl.

#[local] Set Default Timeout 60.

(* peval leaves `if c then inl x else inl y`; the spec has `inl (if c then x
   else y)`.  Collapse the two (as DecodeImpl's if_inl_collect does). *)
Lemma if_inl {A B} (c : bool) (x y : A) :
  (if c then inl x else inl y : A + B) = inl (if c then x else y).
Proof. destruct c; reflexivity. Qed.

Section alu_refine.
  Context {mod_t} `{M : Modules.t mod_t}.

  (* Bitwise ops: the DSL BOp denotes directly to the Bits operation. *)
  Theorem alu_and_correct (a b : Word) :
    peval (alu_and_expr a b) = inl (alu_spec ALU_AND a b).
  Proof.
    unfold alu_and_expr; cbn [alu_spec peval Abbr.and
      CircuitPrimSpecs.sigma1 CircuitPrimSpecs.sigma2].
    reflexivity.
  Qed.

  Theorem alu_or_correct (a b : Word) :
    peval (alu_or_expr a b) = inl (alu_spec ALU_OR a b).
  Proof.
    unfold alu_or_expr; cbn [alu_spec peval Abbr.or
      CircuitPrimSpecs.sigma1 CircuitPrimSpecs.sigma2].
    reflexivity.
  Qed.

  Theorem alu_xor_correct (a b : Word) :
    peval (alu_xor_expr a b) = inl (alu_spec ALU_XOR a b).
  Proof.
    unfold alu_xor_expr; cbn [alu_spec peval Abbr.xor
      CircuitPrimSpecs.sigma1 CircuitPrimSpecs.sigma2].
    reflexivity.
  Qed.

  (* Arithmetic ops: Plus / Minus denote to Bits.plus / Bits.minus. *)
  Theorem alu_add_correct (a b : Word) :
    peval (alu_add_expr a b) = inl (alu_spec ALU_ADD a b).
  Proof.
    unfold alu_add_expr; cbn [alu_spec peval Abbr.plus
      CircuitPrimSpecs.sigma1 CircuitPrimSpecs.sigma2].
    reflexivity.
  Qed.

  Theorem alu_sub_correct (a b : Word) :
    peval (alu_sub_expr a b) = inl (alu_spec ALU_SUB a b).
  Proof.
    unfold alu_sub_expr; cbn [alu_spec peval Abbr.minus
      CircuitPrimSpecs.sigma1 CircuitPrimSpecs.sigma2].
    reflexivity.
  Qed.

  (* Pass-through. *)
  Theorem alu_copyb_correct (a b : Word) :
    peval (alu_copyb_expr a b) = inl (alu_spec ALU_COPY_B a b).
  Proof. reflexivity. Qed.

  (* Shifts: the shift-amount slice + Lsl/Lsr/Asr primitive match shamt. *)
  Theorem alu_sll_correct (a b : Word) :
    peval (alu_sll_expr a b) = inl (alu_spec ALU_SLL a b).
  Proof.
    unfold alu_sll_expr, shamt; cbn [alu_spec peval Abbr.lsl Abbr.slice
      CircuitPrimSpecs.sigma1 CircuitPrimSpecs.sigma2]. reflexivity.
  Qed.

  Theorem alu_srl_correct (a b : Word) :
    peval (alu_srl_expr a b) = inl (alu_spec ALU_SRL a b).
  Proof.
    unfold alu_srl_expr, shamt; cbn [alu_spec peval Abbr.lsr Abbr.slice
      CircuitPrimSpecs.sigma1 CircuitPrimSpecs.sigma2]. reflexivity.
  Qed.

  Theorem alu_sra_correct (a b : Word) :
    peval (alu_sra_expr a b) = inl (alu_spec ALU_SRA a b).
  Proof.
    unfold alu_sra_expr, shamt; cbn [alu_spec peval Abbr.asr Abbr.slice
      CircuitPrimSpecs.sigma1 CircuitPrimSpecs.sigma2]. reflexivity.
  Qed.

  (* Comparisons drive an If mux.  The Compare primitive denotes to
     bitfun_of_predicate P a b = Ob~(P a b), whose single is P a b; then the
     inl distributes over the two branches. *)
  Theorem alu_slt_correct (a b : Word) :
    peval (alu_slt_expr a b) = inl (alu_spec ALU_SLT a b).
  Proof.
    unfold alu_slt_expr; cbn [alu_spec peval Abbr.slt
      CircuitPrimSpecs.sigma1 CircuitPrimSpecs.sigma2].
    unfold BitFuns.bitfun_of_predicate; rewrite unfold_single; apply if_inl.
  Qed.

  Theorem alu_sltu_correct (a b : Word) :
    peval (alu_sltu_expr a b) = inl (alu_spec ALU_SLTU a b).
  Proof.
    unfold alu_sltu_expr; cbn [alu_spec peval Abbr.lt
      CircuitPrimSpecs.sigma1 CircuitPrimSpecs.sigma2].
    unfold BitFuns.bitfun_of_predicate; rewrite unfold_single; apply if_inl.
  Qed.

  (* XFlux signed min / max. *)
  Theorem alu_xmin_correct (a b : Word) :
    peval (alu_xmin_expr a b) = inl (alu_spec ALU_XMIN a b).
  Proof.
    unfold alu_xmin_expr; cbn [alu_spec peval Abbr.slt
      CircuitPrimSpecs.sigma1 CircuitPrimSpecs.sigma2].
    unfold BitFuns.bitfun_of_predicate; rewrite unfold_single; apply if_inl.
  Qed.

  Theorem alu_xmax_correct (a b : Word) :
    peval (alu_xmax_expr a b) = inl (alu_spec ALU_XMAX a b).
  Proof.
    unfold alu_xmax_expr; cbn [alu_spec peval Abbr.slt
      CircuitPrimSpecs.sigma1 CircuitPrimSpecs.sigma2].
    unfold BitFuns.bitfun_of_predicate; rewrite unfold_single; apply if_inl.
  Qed.

  (* XABS: the circuit tests signed-less-than-zero; the spec tests the sign
     bit.  They coincide: to_2cZ is negative exactly when msb is set. *)
  Lemma signed_lt_zero_msb (a : Word) :
    Bits.signed_lt a (Bits.zero : Word) = Bits.msb a.
  Proof.
    unfold Bits.signed_lt, Bits.lift_comparison, Bits.is_lt.
    change (Bits.to_2cZ (Bits.zero : Word)) with Z0.
    unfold Bits.to_2cZ.
    destruct (Bits.msb a) eqn:MSB.
    - destruct (Bits.to_N (Bits.neg a)); reflexivity.
    - destruct (Bits.to_N a); reflexivity.
  Qed.

  Theorem alu_xabs_correct (a b : Word) :
    peval (alu_xabs_expr a b) = inl (alu_spec ALU_XABS a b).
  Proof.
    unfold alu_xabs_expr; cbn [alu_spec peval Abbr.slt Abbr.minus
      CircuitPrimSpecs.sigma1 CircuitPrimSpecs.sigma2].
    unfold BitFuns.bitfun_of_predicate; rewrite unfold_single.
    rewrite signed_lt_zero_msb. apply if_inl.
  Qed.

  (* XFlux XLIDX effective address. *)
  Theorem alu_xlidx_correct (a b : Word) :
    peval (alu_xlidx_expr a b) = inl (alu_spec ALU_XLIDX a b).
  Proof.
    unfold alu_xlidx_expr; cbn [alu_spec peval Abbr.plus Abbr.lsl
      CircuitPrimSpecs.sigma1 CircuitPrimSpecs.sigma2]. reflexivity.
  Qed.

End alu_refine.
