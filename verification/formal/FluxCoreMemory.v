(** * FluxCoreMemory.v

    Byte-addressed partial memory model for FluxCore formal verification.

    Memory is modelled as a partial map [Z -> option Z]:
    - [None]   = uninitialized / inaccessible: any read is undefined behaviour (UB).
    - [Some v] = initialized word at that byte address.

    The model is byte-addressed but word-granular for loads/stores (each entry
    holds a full 32-bit word).  This matches the RTL's BRAM data memory which
    presents 32-bit words at word-aligned addresses.

    Key definitions:
    - [memory]      : the type (Z -> option Z).
    - [mem_read]    : safe read — returns [None] if uninitialized.
    - [mem_write]   : write a word to an address.
    - [mem_wf]      : parameterised well-formedness predicate: "all addresses
                      in a given set are initialized and hold the expected value".

    This file was extracted and generalized from [FluxCoreSPMV.v] where the
    same type appeared as [memory] inside the SpMV section.
*)

Require Import FluxCore.FluxCoreTypes.
From Stdlib Require Import ZArith Bool List Lia.
Import ListNotations.
Open Scope Z_scope.

(* ========================================================================== *)
(** ** Memory type                                                              *)
(* ========================================================================== *)

(** Partial word-granular memory: byte-address → optional 32-bit word.
    [None] means the location is uninitialized; reading it is UB. *)
Definition memory : Type := Z -> option Z.

Definition mem_empty : memory := fun _ => None.

(** Read one word from [addr].  Returns [None] if uninitialized. *)
Definition mem_read (m : memory) (addr : Z) : option Z := m addr.

(** Write word [v] to [addr], returning the updated memory. *)
Definition mem_write (m : memory) (addr : Z) (v : Z) : memory :=
  fun a => if a =? addr then Some v else m a.

(* ========================================================================== *)
(** ** Basic lemmas                                                             *)
(* ========================================================================== *)

Lemma mem_write_read_same : forall m addr v,
    mem_read (mem_write m addr v) addr = Some v.
Proof.
  intros m addr v.
  unfold mem_read, mem_write.
  rewrite Z.eqb_refl. reflexivity.
Qed.

Lemma mem_write_read_other : forall m addr1 addr2 v,
    addr1 <> addr2 ->
    mem_read (mem_write m addr1 v) addr2 = mem_read m addr2.
Proof.
  intros m addr1 addr2 v Hne.
  unfold mem_read, mem_write.
  apply Z.eqb_neq in Hne.
  (* addr2 =? addr1 = false since addr1 ≠ addr2 *)
  assert (H : (addr2 =? addr1) = false).
  { apply Z.eqb_neq. intro H. apply Hne. symmetry. exact H. }
  rewrite H. reflexivity.
Qed.

Lemma mem_write_write_same : forall m addr v1 v2,
    mem_write (mem_write m addr v1) addr v2 = mem_write m addr v2.
Proof.
  intros m addr v1 v2.
  unfold mem_write. extensionality a.
  destruct (a =? addr); reflexivity.
Qed.

(* ========================================================================== *)
(** ** Array wellformedness                                                     *)
(* ========================================================================== *)

(** [mem_array_wf m base stride arr n] asserts that [n] consecutive array
    elements starting at byte address [base] are initialized and hold the
    values given by the function [arr].
    The [stride] is the byte step between elements (4 for 32-bit words). *)
Definition mem_array_wf (m : memory) (base stride : Z) (arr : Z -> Z) (n : nat) : Prop :=
  forall k, (k < n)%nat ->
    mem_read m (base + stride * Z.of_nat k) = Some (arr (Z.of_nat k)).

(** Shifting the index: [mem_array_wf] with base offset [j0 * stride]. *)
Definition mem_array_wf_offset (m : memory) (base stride : Z) (arr : Z -> Z)
           (j0 : Z) (n : nat) : Prop :=
  forall k, (k < n)%nat ->
    mem_read m (base + stride * Z.of_nat k) = Some (arr (j0 + Z.of_nat k)).

(** If a memory satisfies [mem_array_wf_offset] for all elements, any particular
    element within range is readable. *)
Lemma mem_array_wf_read : forall m base stride arr j0 n k,
    mem_array_wf_offset m base stride arr j0 n ->
    (k < n)%nat ->
    mem_read m (base + stride * Z.of_nat k) = Some (arr (j0 + Z.of_nat k)).
Proof.
  intros m base stride arr j0 n k Hwf Hk.
  exact (Hwf k Hk).
Qed.

(** Wellformedness is preserved by writes to disjoint addresses. *)
Lemma mem_array_wf_write_disjoint : forall m base stride arr j0 n waddr wval,
    mem_array_wf_offset m base stride arr j0 n ->
    (forall k, (k < n)%nat -> waddr <> base + stride * Z.of_nat k) ->
    mem_array_wf_offset (mem_write m waddr wval) base stride arr j0 n.
Proof.
  intros m base stride arr j0 n waddr wval Hwf Hdisj k Hk.
  rewrite mem_write_read_other; [apply Hwf; exact Hk |].
  exact (Hdisj k Hk).
Qed.

(* ========================================================================== *)
(** ** Disjointness helpers                                                    *)
(* ========================================================================== *)

(** Two arrays do not overlap if their address ranges are disjoint. *)
Definition arrays_disjoint (base1 stride1 n1 base2 stride2 n2 : Z) : Prop :=
  forall k1 k2,
    0 <= k1 < n1 -> 0 <= k2 < n2 ->
    base1 + stride1 * k1 <> base2 + stride2 * k2.

(** Pointer-bump within a word-aligned array: advancing by [stride] keeps
    the address within the array range. *)
Lemma array_addr_in_range : forall base stride k n,
    0 <= k -> Z.of_nat n > k ->
    base + stride * k < base + stride * Z.of_nat n \/ stride <= 0.
Proof.
  intros base stride k n Hk Hn.
  destruct (Z.le_or_lt stride 0) as [Hle | Hgt].
  - right. exact Hle.
  - left. apply Z.add_lt_mono_l.
    apply Z.mul_lt_mono_pos_l; [exact Hgt | exact Hn].
Qed.

(* ========================================================================== *)
(** ** Summary

    Fully proven (no Admitted):
    - [mem_write_read_same]         : write-then-read at same address = Some v.
    - [mem_write_read_other]        : write does not affect disjoint address.
    - [mem_write_write_same]        : double write to same address = last write.
    - [mem_array_wf_read]           : read any element of a wf array.
    - [mem_array_wf_write_disjoint] : disjoint write preserves array wf.
*)
