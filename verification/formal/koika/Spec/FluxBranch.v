(* verification/formal/koika/Spec/FluxBranch.v
 *
 * Reference semantics for the FluxCore branch-resolution unit — the combinational
 * block in the execute stage that decides whether a conditional branch
 * (BEQ/BNE/BLT/BGE/BLTU/BGEU) is taken.  `branch_taken op a b : bool` is the
 * "taken" flag; the Kôika circuits in Impl/FluxBranchImpl.v refine it
 * (Refine/FluxBranchRefine.v) to a 1-bit result.
 *
 * A handful of property theorems pin the ISA-level intent: reflexivity of BEQ,
 * BNE as the complement of BEQ, and the signed/unsigned GE conditions as the
 * exact complements of their LT counterparts (RISC-V §2.5).
 *)

From Koika Require Import Prelude.
From Flux Require Import FluxCommon.

#[local] Set Default Timeout 60.

(* The six RV32I conditional-branch tests. *)
Variant branch_op :=
  | BR_EQ | BR_NE | BR_LT | BR_GE | BR_LTU | BR_GEU.

Definition branch_taken (op : branch_op) (a b : Word) : bool :=
  match op with
  | BR_EQ  => beq_dec a b
  | BR_NE  => negb (beq_dec a b)
  | BR_LT  => Bits.signed_lt a b
  | BR_GE  => Bits.signed_ge a b
  | BR_LTU => Bits.unsigned_lt a b
  | BR_GEU => Bits.unsigned_ge a b
  end.

(* BEQ against equal operands is always taken. *)
Theorem branch_eq_refl (a : Word) : branch_taken BR_EQ a a = true.
Proof. apply beq_dec_refl. Qed.

(* BNE is exactly the negation of BEQ. *)
Theorem branch_ne_is_not_eq (a b : Word) :
  branch_taken BR_NE a b = negb (branch_taken BR_EQ a b).
Proof. reflexivity. Qed.

(* A total-order comparison is exactly one of Lt / Eq / Gt, so "greater-or-equal"
   is the complement of "less-than" — signed and unsigned alike. *)
Theorem branch_ge_is_not_lt (a b : Word) :
  branch_taken BR_GE a b = negb (branch_taken BR_LT a b).
Proof.
  cbn [branch_taken]. unfold Bits.signed_ge, Bits.signed_lt,
    Bits.lift_comparison, Bits.is_ge, Bits.is_lt.
  destruct (BinInt.Z.compare (Bits.to_2cZ a) (Bits.to_2cZ b)); reflexivity.
Qed.

Theorem branch_geu_is_not_ltu (a b : Word) :
  branch_taken BR_GEU a b = negb (branch_taken BR_LTU a b).
Proof.
  cbn [branch_taken]. unfold Bits.unsigned_ge, Bits.unsigned_lt,
    Bits.lift_comparison, Bits.is_ge, Bits.is_lt.
  destruct (N.compare (Bits.to_N a) (Bits.to_N b)); reflexivity.
Qed.
