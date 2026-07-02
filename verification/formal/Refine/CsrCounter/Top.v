(** * Refine/CsrCounter/Top.v

    Refinement of the CSR counter update logic (Impl/CsrCounter.v)
    against its architectural specification:

      S1. With no CSR write, the counter is the free-running increment.
      S2. A write to one half makes that half read back exactly the
          written (RMW) value.
      S3. A write to one half leaves the OTHER half equal to the
          corresponding half of the incremented value — in particular a
          carry out of the low half during a high-half write, or into the
          high half during an unrelated cycle, is never lost.

    [buggy_loses_carry] shows the pre-2026-07-02 RTL violates S3 on a
    concrete carry boundary, which is the formal statement of the bug
    fixed in rtl/core/csr_unit.sv (regressed by tb_csr_unit G17–G19).
*)

Require Import FluxCore.Common.Types.
Require Import FluxCore.Impl.CsrCounter.
From Stdlib Require Import ZArith Lia.
Open Scope Z_scope.

(* ========================================================================== *)
(** ** Half-overlay algebra                                                   *)
(* ========================================================================== *)

Lemma lo32_set_lo32 : forall c v,
    0 <= v < WORD_SIZE ->
    lo32 (set_lo32 c v) = v.
Proof.
  intros c v Hv.
  unfold lo32, set_lo32.
  rewrite Z.add_comm, Z_mod_plus_full.
  apply Z.mod_small. exact Hv.
Qed.

Lemma hi32_set_lo32 : forall c v,
    0 <= v < WORD_SIZE ->
    hi32 (set_lo32 c v) = hi32 c.
Proof.
  intros c v Hv.
  unfold hi32, set_lo32.
  rewrite Z.div_add_l by (unfold WORD_SIZE; lia).
  rewrite Z.div_small by exact Hv.
  now rewrite Z.add_0_r.
Qed.

Lemma hi32_set_hi32 : forall c v,
    0 <= v ->
    0 <= c ->
    hi32 (set_hi32 c v) = v.
Proof.
  intros c v Hv Hc.
  unfold hi32, set_hi32, lo32.
  rewrite Z.div_add_l by (unfold WORD_SIZE; lia).
  rewrite Z.div_small.
  - now rewrite Z.add_0_r.
  - apply Z.mod_pos_bound. unfold WORD_SIZE. lia.
Qed.

Lemma lo32_set_hi32 : forall c v,
    lo32 (set_hi32 c v) = lo32 c.
Proof.
  intros c v.
  unfold lo32, set_hi32.
  rewrite Z.add_comm, Z_mod_plus_full.
  unfold lo32.
  now rewrite Z.mod_mod by (unfold WORD_SIZE; lia).
Qed.

(* ========================================================================== *)
(** ** S1: free-running increment                                             *)
(* ========================================================================== *)

Theorem counter_no_write_increments : forall c tick,
    counter_next c tick None = wrap64 (c + tick).
Proof. reflexivity. Qed.

(* ========================================================================== *)
(** ** S2: the written half reads back as the written value                   *)
(* ========================================================================== *)

Theorem counter_write_lo_visible : forall c tick v,
    0 <= v < WORD_SIZE ->
    lo32 (counter_next c tick (Some (LO, v))) = v.
Proof.
  intros c tick v Hv. unfold counter_next.
  apply lo32_set_lo32. exact Hv.
Qed.

Theorem counter_write_hi_visible : forall c tick v,
    0 <= v ->
    lo32 (counter_next c tick (Some (HI, v))) = lo32 (wrap64 (c + tick)) ->
    hi32 (counter_next c tick (Some (HI, v))) = v.
Proof.
  intros c tick v Hv _. unfold counter_next.
  apply hi32_set_hi32.
  - exact Hv.
  - pose proof (wrap64_range (c + tick)). lia.
Qed.

(* ========================================================================== *)
(** ** S3: the un-written half carries the increment (carry never lost)       *)
(* ========================================================================== *)

(** High-half write: the LOW half still takes this cycle's increment,
    including the wrap 0xFFFF_FFFF → 0. *)
Theorem counter_write_hi_preserves_lo_tick : forall c tick v,
    lo32 (counter_next c tick (Some (HI, v))) = lo32 (wrap64 (c + tick)).
Proof.
  intros c tick v. unfold counter_next.
  apply lo32_set_hi32.
Qed.

(** Low-half write: the HIGH half still takes the increment's carry. *)
Theorem counter_write_lo_preserves_hi_carry : forall c tick v,
    0 <= v < WORD_SIZE ->
    hi32 (counter_next c tick (Some (LO, v))) = hi32 (wrap64 (c + tick)).
Proof.
  intros c tick v Hv. unfold counter_next.
  apply hi32_set_lo32. exact Hv.
Qed.

(* ========================================================================== *)
(** ** The pre-fix RTL violates S3 at the carry boundary                      *)
(* ========================================================================== *)

(** Concrete counterexample: counter = 0x0000_0000_FFFF_FFFF, tick = 1,
    software writes mcycleh := 5 in the same cycle.
      Fixed RTL:  low half = 0 (the increment carried out).
      Buggy RTL:  low half = 0xFFFF_FFFF (increment dropped) — and the
                  carry into the high half is silently destroyed by the
                  overlay, so the counter goes backwards by 2^32−1 ticks
                  relative to the architectural count. *)
Theorem buggy_loses_carry :
    lo32 (counter_next_buggy (WORD_SIZE - 1) 1 (Some (HI, 5))) =
      WORD_SIZE - 1
    /\ lo32 (counter_next (WORD_SIZE - 1) 1 (Some (HI, 5))) = 0.
Proof. split; vm_compute; reflexivity. Qed.
