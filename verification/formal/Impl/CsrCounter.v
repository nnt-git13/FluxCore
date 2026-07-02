(** * Impl/CsrCounter.v

    Model of csr_unit.sv's 64-bit performance-counter update logic
    (mcycle / minstret).

    The RTL algorithm (rtl/core/csr_unit.sv, counter next-value block):

      1. Compute the free-running increment first:
           next = counter + tick        (tick = 1 for mcycle,
                                         tick = retire_i for minstret)
      2. A CSR write overlays ONLY the addressed 32-bit half of [next];
         the un-written half keeps the incremented value, so a carry out
         of the low half is never lost.

    [counter_next_buggy] models the PRE-FIX RTL (shipped until 2026-07-02),
    which on a half-write held the other half at its OLD value and dropped
    that cycle's increment entirely — losing the low→high carry.

    The refinement theorems live in Refine/CsrCounter/Top.v.
*)

Require Import FluxCore.Common.Types.
From Stdlib Require Import ZArith Lia.
Open Scope Z_scope.

(* ========================================================================== *)
(** ** 64-bit counter arithmetic                                              *)
(* ========================================================================== *)

Definition WORD64 : Z := 18446744073709551616.  (** 2^64 *)

Definition wrap64 (n : Z) : Z := n mod WORD64.

Lemma wrap64_range : forall n, 0 <= wrap64 n < WORD64.
Proof. intro n. unfold wrap64, WORD64. apply Z.mod_pos_bound. lia. Qed.

(** Half extraction / overlay.  For [c] in [[0, 2^64)]:
    [lo32 c] and [hi32 c] are the two 32-bit halves;
    [set_lo32]/[set_hi32] replace one half, keeping the other. *)
Definition lo32 (c : Z) : Z := c mod WORD_SIZE.
Definition hi32 (c : Z) : Z := c / WORD_SIZE.

Definition set_lo32 (c v : Z) : Z := hi32 c * WORD_SIZE + v.
Definition set_hi32 (c v : Z) : Z := v * WORD_SIZE + lo32 c.

(* ========================================================================== *)
(** ** The counter update algorithms                                          *)
(* ========================================================================== *)

Inductive half : Type := LO | HI.

(** Post-fix RTL: increment first, then overlay the addressed half.
    [w = None] models wen_i = 0 (or a write to an unrelated CSR);
    [w = Some (h, v)] models a CSR write of RMW result [v] to half [h]. *)
Definition counter_next (c tick : Z) (w : option (half * Z)) : Z :=
  let inc := wrap64 (c + tick) in
  match w with
  | None          => inc
  | Some (LO, v)  => set_lo32 inc v
  | Some (HI, v)  => set_hi32 inc v
  end.

(** Pre-fix RTL (the bug): a half-write held the OTHER half at its old
    value and dropped the increment for that cycle. *)
Definition counter_next_buggy (c tick : Z) (w : option (half * Z)) : Z :=
  match w with
  | None          => wrap64 (c + tick)
  | Some (LO, v)  => set_lo32 c v
  | Some (HI, v)  => set_hi32 c v
  end.
