(** * FluxCoreTypes.v

    Basic types and arithmetic for FluxCore formal verification.

    - [word]     : 32-bit unsigned integer, represented as [Z].  All values are
                   guaranteed to lie in [[0, 2^32)].
    - [wrap32]   : reduce any integer to [[0, 2^32)].
    - [to_signed32] : interpret a word as a signed 32-bit integer in [[-2^31, 2^31)].
    - [regfile]  : register file, modeled as a function [Z -> Z].
                   x0 always reads as 0 regardless of what is written.
    - [rf_read]  / [rf_write] : register file access with x0 hardwire.

    Key lemmas:
    - [rf_x0_always_zero]    : writing x0 has no observable effect.
    - [rf_write_read_same]   : write then read at same non-x0 index returns the
                               written value.
    - [rf_write_read_other]  : write to one index does not affect a different index.
*)

From Stdlib Require Import ZArith.
From Stdlib Require Import Lia.
Open Scope Z_scope.

(* ========================================================================== *)
(** ** 32-bit word arithmetic                                                  *)
(* ========================================================================== *)

Definition WORD_SIZE   : Z := 4294967296.   (** 2^32 *)
Definition HALF_WORD   : Z := 2147483648.   (** 2^31 *)

(** Reduce [n] to the range [[0, 2^32)]. *)
Definition wrap32 (n : Z) : Z := n mod WORD_SIZE.

Lemma wrap32_range : forall n, 0 <= wrap32 n < WORD_SIZE.
Proof.
  intro n. unfold wrap32, WORD_SIZE.
  apply Z.mod_pos_bound. lia.
Qed.

(** Reinterpret an unsigned 32-bit value as a signed integer in [[-2^31, 2^31)]. *)
Definition to_signed32 (w : Z) : Z :=
  if w <? HALF_WORD then w else w - WORD_SIZE.

(** Bit shift helpers — RV32I shifts use only the low 5 bits of the shift amount. *)
Definition shamt (n : Z) : Z := n mod 32.

Lemma shamt_range : forall n, 0 <= shamt n < 32.
Proof. intro n. unfold shamt. apply Z.mod_pos_bound. lia. Qed.

(* ========================================================================== *)
(** ** Register file                                                           *)
(* ========================================================================== *)

(** A register file maps register indices to word values.  We model it as a
    [Z -> Z] function so that pointwise update is a clean functional update
    without worrying about list lengths. *)
Definition regfile : Type := Z -> Z.

Definition rf_init : regfile := fun _ => 0.

(** Read register [idx].  x0 (index 0) always returns 0. *)
Definition rf_read (rf : regfile) (idx : Z) : Z :=
  if idx =? 0 then 0 else rf idx.

(** Write [v] to register [idx].  If [idx = 0] the register file is unchanged
    (hardware hardwire of x0). *)
Definition rf_write (rf : regfile) (idx : Z) (v : Z) : regfile :=
  if idx =? 0 then rf
  else fun j => if j =? idx then v else rf j.

(* -------------------------------------------------------------------------- *)
(** *** Lemmas                                                                 *)
(* -------------------------------------------------------------------------- *)

(** x0 always reads as 0. *)
Lemma rf_x0_always_zero : forall rf, rf_read rf 0 = 0.
Proof. intro rf. unfold rf_read. reflexivity. Qed.

(** Writing x0 is a no-op; reading anything still gives the original value. *)
Lemma rf_write_x0_nop : forall rf v idx, rf_read (rf_write rf 0 v) idx = rf_read rf idx.
Proof.
  intros rf v idx.
  unfold rf_read, rf_write.
  reflexivity.
Qed.

(** Write then read at the same non-x0 register returns the written value. *)
Lemma rf_write_read_same : forall rf idx v,
    idx <> 0 ->
    rf_read (rf_write rf idx v) idx = v.
Proof.
  intros rf idx v Hne.
  unfold rf_read, rf_write.
  destruct (idx =? 0) eqn:H0.
  - (* idx = 0: contradicts Hne *)
    apply Z.eqb_eq in H0. contradiction.
  - (* idx ≠ 0: after destruct, both [if false] branches were already reduced.
       Goal: (fun j => if j =? idx then v else rf j) idx = v *)
    simpl. rewrite Z.eqb_refl. reflexivity.
Qed.

(** Write to [idx] does not affect reads at a different index [idy]. *)
Lemma rf_write_read_other : forall rf idx idy v,
    idx <> idy ->
    rf_read (rf_write rf idx v) idy = rf_read rf idy.
Proof.
  intros rf idx idy v Hne.
  unfold rf_read, rf_write.
  destruct (idx =? 0) eqn:H0.
  - (* idx = 0: rf_write is a no-op *)
    reflexivity.
  - (* idx ≠ 0: after destruct, goal has (fun j => if j =? idx then v else rf j) *)
    assert (Hneq : (idy =? idx) = false).
    { apply (proj2 (Z.eqb_neq idy idx)).
      intro H. apply Hne. symmetry. exact H. }
    destruct (idy =? 0) eqn:H1.
    + (* idy = 0: both sides return 0 *)
      reflexivity.
    + (* idy ≠ 0: beta-reduce then rewrite inequality *)
      simpl. rewrite Hneq. reflexivity.
Qed.

(** Reading x0 always returns 0, regardless of the register file. *)
Lemma rf_read_x0_zero : forall rf, rf_read rf 0 = 0.
Proof. intro rf. unfold rf_read. reflexivity. Qed.
