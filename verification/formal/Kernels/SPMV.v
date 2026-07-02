(** * Kernels/SPMV.v

    End-to-end correctness proof for the SpMV CSR inner-loop kernel on
    FluxCore.  Fully proven — no Admitted (gated by check_no_admitted.sh).

    Structure mirrors the ModularKoika GPU vecadd kernel proof:
      - [machine_step] : one ISA step with memory (load, MUL, branch, ALU)
      - [eventually]   : inevitability modality — all executions reach P in
                         finitely many steps without UB ([P None = False]
                         excludes UB).
      - [eventually_by_measure] : reusable backbone (proven)
      - [spmv_measure] : per-PC step budget, strictly decreasing on every
                         transition including the back-jump PC 11 -> PC 0
      - [spmv_pc]      : per-PC register/memory shape (one row per instruction)
      - [spmv_full_inv]: full loop invariant (pc in 0..11, per-PC shape, mem_wf)
      - [spmv_inv]     : [spmv_full_inv] or terminal ([spmv_post]) — the
                         terminal disjunct makes the exit transition provable
      - [spmv_STEP]    : main step lemma; 12-way case split on the PC
      - [spmv_terminates] : assembled from backbone + STEP

    The program is the SpMV CSR inner loop (12 instructions, PCs 0-11;
    done at 12):

      PC  0: BGEU  x1, x2, 12      if j >= j_end: exit (loop done)
      PC  1: LW    x7, x4,  0      x7  := val[j]
      PC  2: LW    x8, x5,  0      x8  := col_idx[j]
      PC  3: SLLI  x9, x8,  2      x9  := col_idx[j] * 4
      PC  4: ADD   x9, x6,  x9     x9  := x_base + x9
      PC  5: LW    x10, x9, 0      x10 := x[col_idx[j]]
      PC  6: MUL   x11, x7, x10    x11 := val[j] * x[col_idx[j]]
      PC  7: ADD   x3,  x3, x11    acc := acc + x11
      PC  8: ADDI  x4,  x4,  4     val_ptr  += 4
      PC  9: ADDI  x5,  x5,  4     col_ptr  += 4
      PC 10: ADDI  x1,  x1,  1     j        := j + 1
      PC 11: JUMP  0               back to PC 0 (loop header)

    Register convention (all values are unsigned 32-bit words):
      x1 = j (loop counter)         x6  = x_base
      x2 = j_end                    x7  = val[j] (temp)
      x3 = acc (running sum)        x8  = col_idx[j] (temp)
      x4 = &val[j] (byte ptr)       x9  = &x[col_idx[j]] (temp)
      x5 = &col_idx[j] (byte ptr)   x10 = x[col_idx[j]] (temp)
                                    x11 = product (temp)

    Pipeline note: each loop-body instruction executes correctly on FluxCore
    because ALU ops are fully forwarded (Refine/Pipeline/Top.v), load-use
    hazards are resolved by the 1-cycle stall, and BGEU resolves in EX with
    forwarded operands.  This file proves the ISA-level behaviour; the
    pipeline-refines-ISA connection is [pipe_fwd_invariant] in
    Refine/Pipeline/Top.v.

    Concrete instance: 8x8 sparse matrix, NNZ=21, x=[1..8]^T, checksum = 416
    ([spmv_concrete_checksum], closes by [vm_compute]).
*)

Require Import FluxCore.Common.Types.
From Stdlib Require Import ZArith Bool List Lia Nat.
Import ListNotations.
Open Scope Z_scope.
Open Scope bool_scope.

(* ========================================================================== *)
(** ** 1.  Machine state, instructions, step function                          *)
(* ========================================================================== *)

Definition memory : Type := Z -> option Z.

Record spmv_state : Type := mk_spmv_st
  { ss_rf  : regfile
  ; ss_mem : memory
  ; ss_pc  : nat
  }.

Inductive spmv_instr : Type :=
  | SI_lw    (rd rs1 : Z) (imm : Z)
  | SI_slli  (rd rs1 : Z) (sh : Z)
  | SI_add   (rd rs1 rs2 : Z)
  | SI_addi  (rd rs1 : Z) (imm : Z)
  | SI_mul   (rd rs1 rs2 : Z)
  | SI_bgeu  (rs1 rs2 : Z) (target : nat)
  | SI_jump  (target : nat)
  .

Definition spmv_exec (s : spmv_state) (i : spmv_instr) : option spmv_state :=
  match i with
  | SI_lw rd rs1 imm =>
      match s.(ss_mem) (rf_read s.(ss_rf) rs1 + imm) with
      | None   => None
      | Some v => Some {| ss_rf  := rf_write s.(ss_rf) rd v
                        ; ss_mem := s.(ss_mem)
                        ; ss_pc  := S s.(ss_pc) |}
      end
  | SI_slli rd rs1 sh =>
      Some {| ss_rf  := rf_write s.(ss_rf) rd
                          (wrap32 (Z.shiftl (rf_read s.(ss_rf) rs1) sh))
            ; ss_mem := s.(ss_mem) ; ss_pc := S s.(ss_pc) |}
  | SI_add rd rs1 rs2 =>
      Some {| ss_rf  := rf_write s.(ss_rf) rd
                          (wrap32 (rf_read s.(ss_rf) rs1 + rf_read s.(ss_rf) rs2))
            ; ss_mem := s.(ss_mem) ; ss_pc := S s.(ss_pc) |}
  | SI_addi rd rs1 imm =>
      Some {| ss_rf  := rf_write s.(ss_rf) rd
                          (wrap32 (rf_read s.(ss_rf) rs1 + imm))
            ; ss_mem := s.(ss_mem) ; ss_pc := S s.(ss_pc) |}
  | SI_mul rd rs1 rs2 =>
      Some {| ss_rf  := rf_write s.(ss_rf) rd
                          (wrap32 (rf_read s.(ss_rf) rs1 * rf_read s.(ss_rf) rs2))
            ; ss_mem := s.(ss_mem) ; ss_pc := S s.(ss_pc) |}
  | SI_bgeu rs1 rs2 target =>
      let v1 := rf_read s.(ss_rf) rs1 in
      let v2 := rf_read s.(ss_rf) rs2 in
      let next := if v2 <=? v1 then target else S s.(ss_pc) in
      Some {| ss_rf := s.(ss_rf) ; ss_mem := s.(ss_mem) ; ss_pc := next |}
  | SI_jump target =>
      Some {| ss_rf := s.(ss_rf) ; ss_mem := s.(ss_mem) ; ss_pc := target |}
  end.

(** SpMV CSR inner-loop program (12 instructions; pc=12 = loop done). *)
Definition spmv_prog : list spmv_instr :=
  [ (* PC  0 *) SI_bgeu  1  2 12
  ; (* PC  1 *) SI_lw    7  4  0
  ; (* PC  2 *) SI_lw    8  5  0
  ; (* PC  3 *) SI_slli  9  8  2
  ; (* PC  4 *) SI_add   9  6  9
  ; (* PC  5 *) SI_lw   10  9  0
  ; (* PC  6 *) SI_mul  11  7 10
  ; (* PC  7 *) SI_add   3  3 11
  ; (* PC  8 *) SI_addi  4  4  4
  ; (* PC  9 *) SI_addi  5  5  4
  ; (* PC 10 *) SI_addi  1  1  1
  ; (* PC 11 *) SI_jump  0
  ].

Lemma spmv_prog_length : (length spmv_prog = 12)%nat.
Proof. reflexivity. Qed.

Definition machine_step (s : spmv_state) (o : option spmv_state) : Prop :=
  match nth_error spmv_prog s.(ss_pc) with
  | Some i => o = spmv_exec s i
  | None   => o = None
  end.

(* ========================================================================== *)
(** ** 2.  Inevitability modality and backbone                                 *)
(* ========================================================================== *)

Inductive eventually (P : option spmv_state -> Prop) : spmv_state -> Prop :=
  | Ev_here : forall s,
      P (Some s) ->
      eventually P s
  | Ev_step : forall s,
      (exists o, machine_step s o) ->
      (forall s', machine_step s (Some s') -> eventually P s') ->
      (machine_step s None -> P None) ->
      eventually P s.

Lemma eventually_by_measure (P : option spmv_state -> Prop)
    (inv : spmv_state -> Prop) (measure : spmv_state -> nat) :
    (forall s, inv s ->
       P (Some s) \/
       ((exists o, machine_step s o)
        /\ (forall s', machine_step s (Some s') ->
              inv s' /\ (measure s' < measure s)%nat)
        /\ (machine_step s None -> P None))) ->
    forall n s, (measure s < n)%nat -> inv s -> eventually P s.
Proof.
  intros HSTEP.
  induction n; intros s Hlt Hinv.
  - lia.
  - destruct (HSTEP s Hinv) as [HP | (Hprog & Hpres & Hnone)].
    + apply Ev_here. exact HP.
    + apply Ev_step; [exact Hprog | | exact Hnone].
      intros s' Hstep.
      destruct (Hpres s' Hstep) as [Hinv' Hlt'].
      apply IHn; [lia | exact Hinv'].
Qed.

Corollary eventually_by_measure' (P : option spmv_state -> Prop)
    (inv : spmv_state -> Prop) (measure : spmv_state -> nat) :
    (forall s, inv s ->
       P (Some s) \/
       ((exists o, machine_step s o)
        /\ (forall s', machine_step s (Some s') ->
              inv s' /\ (measure s' < measure s)%nat)
        /\ (machine_step s None -> P None))) ->
    forall s, inv s -> eventually P s.
Proof.
  intros HSTEP s Hinv.
  apply (eventually_by_measure P inv measure HSTEP (S (measure s))).
  - lia.
  - exact Hinv.
Qed.

(* ========================================================================== *)
(** ** 3.  SpMV partial-sum algebra                                            *)
(* ========================================================================== *)

Fixpoint spmv_sum (val col x : Z -> Z) (j0 : Z) (n : nat) : Z :=
  match n with
  | O    => 0
  | S n' => spmv_sum val col x j0 n' + val (j0 + Z.of_nat n') * x (col (j0 + Z.of_nat n'))
  end.

Lemma spmv_sum_0 : forall val col x j0, spmv_sum val col x j0 0 = 0.
Proof. reflexivity. Qed.

Lemma spmv_sum_S : forall val col x j0 n,
    spmv_sum val col x j0 (S n) =
    spmv_sum val col x j0 n + val (j0 + Z.of_nat n) * x (col (j0 + Z.of_nat n)).
Proof. intros. reflexivity. Qed.

Lemma spmv_sum_term : forall val col x j0 n,
    spmv_sum val col x j0 (S n) - spmv_sum val col x j0 n =
    val (j0 + Z.of_nat n) * x (col (j0 + Z.of_nat n)).
Proof. intros. simpl. ring. Qed.

(* ========================================================================== *)
(** ** 4.  Concrete matrix data and checksum                                   *)
(* ========================================================================== *)

Definition concrete_val (j : Z) : Z :=
  match j with
  | 0  => 2  | 1  => 7  | 2  => 5  | 3  => 3  | 4  => 1
  | 5  => 4  | 6  => 8  | 7  => 6  | 8  => 2  | 9  => 9
  | 10 => 1  | 11 => 5  | 12 => 3  | 13 => 4  | 14 => 7
  | 15 => 2  | 16 => 6  | 17 => 3  | 18 => 8  | 19 => 2
  | 20 => 4  | _  => 0
  end.

Definition concrete_col (j : Z) : Z :=
  match j with
  | 0  => 0  | 1  => 3  | 2  => 1  | 3  => 4  | 4  => 6
  | 5  => 0  | 6  => 2  | 7  => 3  | 8  => 5  | 9  => 7
  | 10 => 1  | 11 => 4  | 12 => 0  | 13 => 3  | 14 => 5
  | 15 => 2  | 16 => 6  | 17 => 7  | 18 => 1  | 19 => 4
  | 20 => 7  | _  => 0
  end.

Definition concrete_x (i : Z) : Z :=
  match i with
  | 0 => 1  | 1 => 2  | 2 => 3  | 3 => 4
  | 4 => 5  | 5 => 6  | 6 => 7  | 7 => 8  | _ => 0
  end.

(** Value bounds — proven by exhausting the finitely many match arms. *)
Lemma concrete_val_range : forall j, 0 <= concrete_val j <= 9.
Proof.
  intro j. unfold concrete_val.
  destruct j as [|p|p]; [lia| |lia].
  repeat (destruct p as [p|p|]; simpl; try lia).
Qed.

Lemma concrete_col_range : forall j, 0 <= concrete_col j <= 7.
Proof.
  intro j. unfold concrete_col.
  destruct j as [|p|p]; [lia| |lia].
  repeat (destruct p as [p|p|]; simpl; try lia).
Qed.

Lemma concrete_x_range : forall j, 0 <= concrete_x j <= 8.
Proof.
  intro j. unfold concrete_x.
  destruct j as [|p|p]; [lia| |lia].
  repeat (destruct p as [p|p|]; simpl; try lia).
Qed.

Theorem spmv_concrete_checksum :
    spmv_sum concrete_val concrete_col concrete_x 0 21 = 416.
Proof. vm_compute. reflexivity. Qed.

Theorem spmv_row0 :
    concrete_val 0 * concrete_x (concrete_col 0) +
    concrete_val 1 * concrete_x (concrete_col 1) = 30.
Proof. vm_compute. reflexivity. Qed.

Theorem spmv_row3 :
    concrete_val 7 * concrete_x (concrete_col 7) +
    concrete_val 8 * concrete_x (concrete_col 8) +
    concrete_val 9 * concrete_x (concrete_col 9) = 108.
Proof. vm_compute. reflexivity. Qed.

(* ========================================================================== *)
(** ** 5.  Section: loop invariant and main theorem                            *)
(* ========================================================================== *)

Section spmv_loop.

Context
  (val col x_arr : Z -> Z)
  (j0      : Z)
  (n_iters : nat)
  .

Let j_end : Z := j0 + Z.of_nat n_iters.

Context
  (val_base : Z)
  (col_base : Z)
  (x_base   : Z)
  .

Context
  (Hj0_range   : 0 <= j0 < WORD_SIZE)
  (Hjend_range : 0 <= j_end < WORD_SIZE)
  (Hvbase_ok : forall k, (k <= n_iters)%nat -> 0 <= val_base + 4 * Z.of_nat k < WORD_SIZE)
  (Hcbase_ok : forall k, (k <= n_iters)%nat -> 0 <= col_base + 4 * Z.of_nat k < WORD_SIZE)
  (Hcol_nn   : forall k, (k < n_iters)%nat -> 0 <= col (j0 + Z.of_nat k))
  (Hcolsz    : forall k, (k < n_iters)%nat -> 4 * col (j0 + Z.of_nat k) < WORD_SIZE)
  (Hxaddr_ok : forall k, (k < n_iters)%nat -> 0 <= x_base + 4 * col (j0 + Z.of_nat k) < WORD_SIZE)
  (Hprod_ok  : forall k, (k < n_iters)%nat ->
                 0 <= val (j0 + Z.of_nat k) * x_arr (col (j0 + Z.of_nat k)) < WORD_SIZE)
  (Hsum_ok   : forall k, (k <= n_iters)%nat -> 0 <= spmv_sum val col x_arr j0 k < WORD_SIZE)
  .

Definition mem_wf (m : memory) : Prop :=
  (forall k, (k < n_iters)%nat ->
     m (val_base + 4 * Z.of_nat k) = Some (val (j0 + Z.of_nat k)))
  /\ (forall k, (k < n_iters)%nat ->
     m (col_base + 4 * Z.of_nat k) = Some (col (j0 + Z.of_nat k)))
  /\ (forall k, (k < n_iters)%nat ->
     m (x_base + 4 * col (j0 + Z.of_nat k)) = Some (x_arr (col (j0 + Z.of_nat k)))).

Lemma wrap32_acc : forall k, (k <= n_iters)%nat ->
    wrap32 (spmv_sum val col x_arr j0 k) = spmv_sum val col x_arr j0 k.
Proof.
  intros k Hkk. unfold wrap32, WORD_SIZE.
  apply Z.mod_small. apply Hsum_ok. exact Hkk.
Qed.

Lemma wrap32_vbase : forall k, (k <= n_iters)%nat ->
    wrap32 (val_base + 4 * Z.of_nat k) = val_base + 4 * Z.of_nat k.
Proof.
  intros k Hkk. unfold wrap32, WORD_SIZE. apply Z.mod_small. apply Hvbase_ok. exact Hkk.
Qed.

Lemma wrap32_cbase : forall k, (k <= n_iters)%nat ->
    wrap32 (col_base + 4 * Z.of_nat k) = col_base + 4 * Z.of_nat k.
Proof.
  intros k Hkk. unfold wrap32, WORD_SIZE. apply Z.mod_small. apply Hcbase_ok. exact Hkk.
Qed.

(* ======================================================================== *)
(** ** 5a.  Per-PC invariant                                                 *)
(* ======================================================================== *)

Definition spmv_pc (s : spmv_state) (k : nat) (pcidx : nat) : Prop :=
  match pcidx with
  | 0%nat  =>
      rf_read s.(ss_rf) 1 = j0 + Z.of_nat k
      /\ rf_read s.(ss_rf) 2 = j_end
      /\ rf_read s.(ss_rf) 3 = spmv_sum val col x_arr j0 k
      /\ rf_read s.(ss_rf) 4 = val_base + 4 * Z.of_nat k
      /\ rf_read s.(ss_rf) 5 = col_base + 4 * Z.of_nat k
      /\ rf_read s.(ss_rf) 6 = x_base
  | 1%nat  =>
      rf_read s.(ss_rf) 1 = j0 + Z.of_nat k
      /\ rf_read s.(ss_rf) 2 = j_end
      /\ rf_read s.(ss_rf) 3 = spmv_sum val col x_arr j0 k
      /\ rf_read s.(ss_rf) 4 = val_base + 4 * Z.of_nat k
      /\ rf_read s.(ss_rf) 5 = col_base + 4 * Z.of_nat k
      /\ rf_read s.(ss_rf) 6 = x_base
      /\ (k < n_iters)%nat
  | 2%nat  =>
      rf_read s.(ss_rf) 1 = j0 + Z.of_nat k
      /\ rf_read s.(ss_rf) 2 = j_end
      /\ rf_read s.(ss_rf) 3 = spmv_sum val col x_arr j0 k
      /\ rf_read s.(ss_rf) 4 = val_base + 4 * Z.of_nat k
      /\ rf_read s.(ss_rf) 5 = col_base + 4 * Z.of_nat k
      /\ rf_read s.(ss_rf) 6 = x_base
      /\ rf_read s.(ss_rf) 7 = val (j0 + Z.of_nat k)
      /\ (k < n_iters)%nat
  | 3%nat  =>
      rf_read s.(ss_rf) 1 = j0 + Z.of_nat k
      /\ rf_read s.(ss_rf) 2 = j_end
      /\ rf_read s.(ss_rf) 3 = spmv_sum val col x_arr j0 k
      /\ rf_read s.(ss_rf) 4 = val_base + 4 * Z.of_nat k
      /\ rf_read s.(ss_rf) 5 = col_base + 4 * Z.of_nat k
      /\ rf_read s.(ss_rf) 6 = x_base
      /\ rf_read s.(ss_rf) 7 = val (j0 + Z.of_nat k)
      /\ rf_read s.(ss_rf) 8 = col (j0 + Z.of_nat k)
      /\ (k < n_iters)%nat
  | 4%nat  =>
      rf_read s.(ss_rf) 1 = j0 + Z.of_nat k
      /\ rf_read s.(ss_rf) 2 = j_end
      /\ rf_read s.(ss_rf) 3 = spmv_sum val col x_arr j0 k
      /\ rf_read s.(ss_rf) 4 = val_base + 4 * Z.of_nat k
      /\ rf_read s.(ss_rf) 5 = col_base + 4 * Z.of_nat k
      /\ rf_read s.(ss_rf) 6 = x_base
      /\ rf_read s.(ss_rf) 7 = val (j0 + Z.of_nat k)
      /\ rf_read s.(ss_rf) 8 = col (j0 + Z.of_nat k)
      /\ rf_read s.(ss_rf) 9 = col (j0 + Z.of_nat k) * 4
      /\ (k < n_iters)%nat
  | 5%nat  =>
      rf_read s.(ss_rf) 1 = j0 + Z.of_nat k
      /\ rf_read s.(ss_rf) 2 = j_end
      /\ rf_read s.(ss_rf) 3 = spmv_sum val col x_arr j0 k
      /\ rf_read s.(ss_rf) 4 = val_base + 4 * Z.of_nat k
      /\ rf_read s.(ss_rf) 5 = col_base + 4 * Z.of_nat k
      /\ rf_read s.(ss_rf) 6 = x_base
      /\ rf_read s.(ss_rf) 7 = val (j0 + Z.of_nat k)
      /\ rf_read s.(ss_rf) 9 = x_base + col (j0 + Z.of_nat k) * 4
      /\ (k < n_iters)%nat
  | 6%nat  =>
      rf_read s.(ss_rf) 1 = j0 + Z.of_nat k
      /\ rf_read s.(ss_rf) 2 = j_end
      /\ rf_read s.(ss_rf) 3 = spmv_sum val col x_arr j0 k
      /\ rf_read s.(ss_rf) 4 = val_base + 4 * Z.of_nat k
      /\ rf_read s.(ss_rf) 5 = col_base + 4 * Z.of_nat k
      /\ rf_read s.(ss_rf) 6 = x_base
      /\ rf_read s.(ss_rf) 7 = val (j0 + Z.of_nat k)
      /\ rf_read s.(ss_rf) 10 = x_arr (col (j0 + Z.of_nat k))
      /\ (k < n_iters)%nat
  | 7%nat  =>
      rf_read s.(ss_rf) 1 = j0 + Z.of_nat k
      /\ rf_read s.(ss_rf) 2 = j_end
      /\ rf_read s.(ss_rf) 3 = spmv_sum val col x_arr j0 k
      /\ rf_read s.(ss_rf) 4 = val_base + 4 * Z.of_nat k
      /\ rf_read s.(ss_rf) 5 = col_base + 4 * Z.of_nat k
      /\ rf_read s.(ss_rf) 6 = x_base
      /\ rf_read s.(ss_rf) 11 = val (j0 + Z.of_nat k) * x_arr (col (j0 + Z.of_nat k))
      /\ (k < n_iters)%nat
  | 8%nat  =>
      rf_read s.(ss_rf) 1 = j0 + Z.of_nat k
      /\ rf_read s.(ss_rf) 2 = j_end
      /\ rf_read s.(ss_rf) 3 = spmv_sum val col x_arr j0 (S k)
      /\ rf_read s.(ss_rf) 4 = val_base + 4 * Z.of_nat k
      /\ rf_read s.(ss_rf) 5 = col_base + 4 * Z.of_nat k
      /\ rf_read s.(ss_rf) 6 = x_base
      /\ (k < n_iters)%nat
  | 9%nat  =>
      rf_read s.(ss_rf) 1 = j0 + Z.of_nat k
      /\ rf_read s.(ss_rf) 2 = j_end
      /\ rf_read s.(ss_rf) 3 = spmv_sum val col x_arr j0 (S k)
      /\ rf_read s.(ss_rf) 4 = val_base + 4 * Z.of_nat (S k)
      /\ rf_read s.(ss_rf) 5 = col_base + 4 * Z.of_nat k
      /\ rf_read s.(ss_rf) 6 = x_base
      /\ (k < n_iters)%nat
  | 10%nat =>
      rf_read s.(ss_rf) 1 = j0 + Z.of_nat k
      /\ rf_read s.(ss_rf) 2 = j_end
      /\ rf_read s.(ss_rf) 3 = spmv_sum val col x_arr j0 (S k)
      /\ rf_read s.(ss_rf) 4 = val_base + 4 * Z.of_nat (S k)
      /\ rf_read s.(ss_rf) 5 = col_base + 4 * Z.of_nat (S k)
      /\ rf_read s.(ss_rf) 6 = x_base
      /\ (k < n_iters)%nat
  | 11%nat =>
      rf_read s.(ss_rf) 1 = j0 + Z.of_nat (S k)
      /\ rf_read s.(ss_rf) 2 = j_end
      /\ rf_read s.(ss_rf) 3 = spmv_sum val col x_arr j0 (S k)
      /\ rf_read s.(ss_rf) 4 = val_base + 4 * Z.of_nat (S k)
      /\ rf_read s.(ss_rf) 5 = col_base + 4 * Z.of_nat (S k)
      /\ rf_read s.(ss_rf) 6 = x_base
      /\ (k < n_iters)%nat
  | _  => False
  end.

Definition spmv_full_inv (s : spmv_state) : Prop :=
  exists k, (k <= n_iters)%nat /\ (s.(ss_pc) < 12)%nat
            /\ mem_wf s.(ss_mem) /\ spmv_pc s k s.(ss_pc).

Definition spmv_post (o : option spmv_state) : Prop :=
  match o with
  | Some s => s.(ss_pc) = 12%nat
              /\ rf_read s.(ss_rf) 3 = spmv_sum val col x_arr j0 n_iters
  | None   => False
  end.

(** Step-lemma invariant: mid-loop or already terminal.  The terminal
    disjunct is what makes the exit transition (PC 0 -> PC 12) provable. *)
Definition spmv_inv (s : spmv_state) : Prop :=
  spmv_full_inv s \/ spmv_post (Some s).

(* ======================================================================== *)
(** ** 5b.  Termination measure                                              *)
(*
   Exact remaining-step budget.  k is estimated from rf[x1]; rows 0-10 have
   rf[x1] = j0+k while row 11 has rf[x1] = j0+(k+1), which is why PC 11 gets
   budget 2 rather than following the 1..10 formula.  Every transition
   decreases the measure (exit: 1 -> 0).
*)
(* ======================================================================== *)

Definition spmv_measure (s : spmv_state) : nat :=
  let k  := Z.to_nat (rf_read s.(ss_rf) 1 - j0) in
  let pc := s.(ss_pc) in
  if Nat.eqb pc 0 then ((n_iters - k) * 12 + 1)%nat
  else if Nat.eqb pc 11 then ((n_iters - k) * 12 + 2)%nat
  else if Nat.ltb pc 12 then ((n_iters - k) * 12 + 1 - pc)%nat
  else 0%nat.

Lemma kest_simpl : forall k', Z.to_nat (j0 + Z.of_nat k' - j0) = k'.
Proof.
  intro k'.
  replace (j0 + Z.of_nat k' - j0) with (Z.of_nat k') by ring.
  apply Nat2Z.id.
Qed.

(* ======================================================================== *)
(** ** 5c.  Initial invariant                                                *)
(* ======================================================================== *)

Lemma spmv_init_inv :
    forall rf0 m,
    rf_read rf0 1 = j0 ->
    rf_read rf0 2 = j_end ->
    rf_read rf0 3 = 0 ->
    rf_read rf0 4 = val_base ->
    rf_read rf0 5 = col_base ->
    rf_read rf0 6 = x_base ->
    mem_wf m ->
    spmv_full_inv {| ss_rf := rf0; ss_mem := m; ss_pc := 0%nat |}.
Proof.
  intros rf0 m H1 H2 H3 H4 H5 H6 Hmem.
  exists 0%nat.
  split; [lia|]. split; [cbn; lia|]. split; [exact Hmem|].
  cbn [spmv_pc ss_rf ss_pc].
  rewrite H1, H2, H3, H4, H5, H6.
  cbn [spmv_sum Z.of_nat].
  repeat split; first [ reflexivity | ring ].
Qed.

(* ======================================================================== *)
(** ** 5d.  Main step lemma                                                  *)
(* ======================================================================== *)

(** Register-file read simplification through writes with literal indices. *)
Ltac rf_rw :=
  repeat (first [ rewrite rf_write_read_same by lia
                | rewrite rf_write_read_other by lia ]).

Lemma spmv_STEP :
    forall s, spmv_inv s ->
    spmv_post (Some s) \/
    ((exists o, machine_step s o)
     /\ (forall s', machine_step s (Some s') ->
           spmv_inv s' /\ (spmv_measure s' < spmv_measure s)%nat)
     /\ (machine_step s None -> spmv_post None)).
Proof.
  intros s Hinv.
  destruct Hinv as [Hinv | Hpost]; [| left; exact Hpost].
  destruct Hinv as (k & Hk & Hpc & Hmem & Hshape).
  pose proof Hmem as Hmem_parts.
  destruct Hmem_parts as (HvalM & HcolM & HxM).
  destruct s as [rf m pc].
  cbn [ss_pc ss_rf ss_mem] in Hpc, Hshape.

  (* ---------------------------------------------------------------- PC 0 *)
  destruct pc as [|pc].
  { cbn [spmv_pc ss_rf] in Hshape.
    destruct Hshape as (H1 & H2 & H3 & H4 & H5 & H6).
    right.
    destruct (Nat.eq_dec k n_iters) as [Hkeq | Hkne].
    - (* k = n_iters: BGEU taken, loop exits to PC 12 *)
      subst k.
      assert (Htaken : (rf_read rf 2 <=? rf_read rf 1) = true).
      { rewrite H1, H2.
        replace j_end with (j0 + Z.of_nat n_iters) by reflexivity.
        apply Z.leb_le. lia. }
      split; [| split].
      + eexists. unfold machine_step. cbn [ss_pc nth_error spmv_prog].
        reflexivity.
      + intros s' Hstep.
        unfold machine_step in Hstep.
        cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in Hstep.
        rewrite Htaken in Hstep.
        injection Hstep as Hst. subst s'.
        split.
        * unfold spmv_inv. right. cbn [ss_pc ss_rf].
          split; [reflexivity | exact H3].
        * unfold spmv_measure. cbn [ss_pc ss_rf Nat.eqb Nat.ltb Nat.leb].
          lia.
      + intros HN. unfold machine_step in HN.
        cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in HN.
        discriminate HN.
    - (* k < n_iters: BGEU not taken, enter loop body *)
      assert (Hklt : (k < n_iters)%nat) by lia.
      assert (Hnt : (rf_read rf 2 <=? rf_read rf 1) = false).
      { rewrite H1, H2.
        replace j_end with (j0 + Z.of_nat n_iters) by reflexivity.
        apply Z.leb_gt. lia. }
      split; [| split].
      + eexists. unfold machine_step. cbn [ss_pc nth_error spmv_prog].
        reflexivity.
      + intros s' Hstep.
        unfold machine_step in Hstep.
        cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in Hstep.
        rewrite Hnt in Hstep.
        injection Hstep as Hst. subst s'.
        split.
        * unfold spmv_inv. left. exists k.
          split; [lia|]. split; [cbn [ss_pc]; lia|]. split; [exact Hmem|].
          cbn [spmv_pc ss_rf ss_pc].
          repeat split; assumption.
        * unfold spmv_measure. cbn [ss_pc ss_rf Nat.eqb Nat.ltb Nat.leb].
          rewrite H1, !kest_simpl. lia.
      + intros HN. unfold machine_step in HN.
        cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in HN.
        discriminate HN.
  }

  (* ---------------------------------------------------------------- PC 1 *)
  destruct pc as [|pc].
  { cbn [spmv_pc ss_rf] in Hshape.
    destruct Hshape as (H1 & H2 & H3 & H4 & H5 & H6 & Hklt).
    assert (Haddr : m (rf_read rf 4 + 0) = Some (val (j0 + Z.of_nat k))).
    { rewrite H4, Z.add_0_r. apply HvalM. exact Hklt. }
    right. split; [| split].
    + eexists. unfold machine_step. cbn [ss_pc nth_error spmv_prog].
      reflexivity.
    + intros s' Hstep.
      unfold machine_step in Hstep.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in Hstep.
      rewrite Haddr in Hstep.
      injection Hstep as Hst. subst s'.
      split.
      * unfold spmv_inv. left. exists k.
        split; [lia|]. split; [cbn [ss_pc]; lia|]. split; [exact Hmem|].
        cbn [spmv_pc ss_rf ss_pc].
        rf_rw.
        repeat split; first [assumption | reflexivity].
      * unfold spmv_measure. cbn [ss_pc ss_rf Nat.eqb Nat.ltb Nat.leb].
        rf_rw. rewrite H1, !kest_simpl. lia.
    + intros HN. unfold machine_step in HN.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in HN.
      rewrite Haddr in HN. discriminate HN.
  }

  (* ---------------------------------------------------------------- PC 2 *)
  destruct pc as [|pc].
  { cbn [spmv_pc ss_rf] in Hshape.
    destruct Hshape as (H1 & H2 & H3 & H4 & H5 & H6 & H7 & Hklt).
    assert (Haddr : m (rf_read rf 5 + 0) = Some (col (j0 + Z.of_nat k))).
    { rewrite H5, Z.add_0_r. apply HcolM. exact Hklt. }
    right. split; [| split].
    + eexists. unfold machine_step. cbn [ss_pc nth_error spmv_prog].
      reflexivity.
    + intros s' Hstep.
      unfold machine_step in Hstep.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in Hstep.
      rewrite Haddr in Hstep.
      injection Hstep as Hst. subst s'.
      split.
      * unfold spmv_inv. left. exists k.
        split; [lia|]. split; [cbn [ss_pc]; lia|]. split; [exact Hmem|].
        cbn [spmv_pc ss_rf ss_pc].
        rf_rw.
        repeat split; first [assumption | reflexivity].
      * unfold spmv_measure. cbn [ss_pc ss_rf Nat.eqb Nat.ltb Nat.leb].
        rf_rw. rewrite H1, !kest_simpl. lia.
    + intros HN. unfold machine_step in HN.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in HN.
      rewrite Haddr in HN. discriminate HN.
  }

  (* ---------------------------------------------------------------- PC 3 *)
  destruct pc as [|pc].
  { cbn [spmv_pc ss_rf] in Hshape.
    destruct Hshape as (H1 & H2 & H3 & H4 & H5 & H6 & H7 & H8 & Hklt).
    assert (Hv : wrap32 (Z.shiftl (rf_read rf 8) 2) = col (j0 + Z.of_nat k) * 4).
    { rewrite H8. rewrite Z.shiftl_mul_pow2 by lia.
      replace (2 ^ 2) with 4 by reflexivity.
      unfold wrap32. apply Z.mod_small.
      pose proof (Hcol_nn k Hklt). pose proof (Hcolsz k Hklt). lia. }
    right. split; [| split].
    + eexists. unfold machine_step. cbn [ss_pc nth_error spmv_prog].
      reflexivity.
    + intros s' Hstep.
      unfold machine_step in Hstep.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in Hstep.
      injection Hstep as Hst. subst s'.
      split.
      * unfold spmv_inv. left. exists k.
        split; [lia|]. split; [cbn [ss_pc]; lia|]. split; [exact Hmem|].
        cbn [spmv_pc ss_rf ss_pc].
        rf_rw.
        repeat split; first [assumption | reflexivity | exact Hv].
      * unfold spmv_measure. cbn [ss_pc ss_rf Nat.eqb Nat.ltb Nat.leb].
        rf_rw. rewrite H1, !kest_simpl. lia.
    + intros HN. unfold machine_step in HN.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in HN.
      discriminate HN.
  }

  (* ---------------------------------------------------------------- PC 4 *)
  destruct pc as [|pc].
  { cbn [spmv_pc ss_rf] in Hshape.
    destruct Hshape as (H1 & H2 & H3 & H4 & H5 & H6 & H7 & H8 & H9 & Hklt).
    assert (Hv : wrap32 (rf_read rf 6 + rf_read rf 9)
                 = x_base + col (j0 + Z.of_nat k) * 4).
    { rewrite H6, H9. unfold wrap32. apply Z.mod_small.
      pose proof (Hxaddr_ok k Hklt). lia. }
    right. split; [| split].
    + eexists. unfold machine_step. cbn [ss_pc nth_error spmv_prog].
      reflexivity.
    + intros s' Hstep.
      unfold machine_step in Hstep.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in Hstep.
      injection Hstep as Hst. subst s'.
      split.
      * unfold spmv_inv. left. exists k.
        split; [lia|]. split; [cbn [ss_pc]; lia|]. split; [exact Hmem|].
        cbn [spmv_pc ss_rf ss_pc].
        rf_rw.
        repeat split; first [assumption | reflexivity | exact Hv].
      * unfold spmv_measure. cbn [ss_pc ss_rf Nat.eqb Nat.ltb Nat.leb].
        rf_rw. rewrite H1, !kest_simpl. lia.
    + intros HN. unfold machine_step in HN.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in HN.
      discriminate HN.
  }

  (* ---------------------------------------------------------------- PC 5 *)
  destruct pc as [|pc].
  { cbn [spmv_pc ss_rf] in Hshape.
    destruct Hshape as (H1 & H2 & H3 & H4 & H5 & H6 & H7 & H9 & Hklt).
    assert (Haddr : m (rf_read rf 9 + 0)
                    = Some (x_arr (col (j0 + Z.of_nat k)))).
    { rewrite H9.
      replace (x_base + col (j0 + Z.of_nat k) * 4 + 0)
        with (x_base + 4 * col (j0 + Z.of_nat k)) by ring.
      apply HxM. exact Hklt. }
    right. split; [| split].
    + eexists. unfold machine_step. cbn [ss_pc nth_error spmv_prog].
      reflexivity.
    + intros s' Hstep.
      unfold machine_step in Hstep.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in Hstep.
      rewrite Haddr in Hstep.
      injection Hstep as Hst. subst s'.
      split.
      * unfold spmv_inv. left. exists k.
        split; [lia|]. split; [cbn [ss_pc]; lia|]. split; [exact Hmem|].
        cbn [spmv_pc ss_rf ss_pc].
        rf_rw.
        repeat split; first [assumption | reflexivity].
      * unfold spmv_measure. cbn [ss_pc ss_rf Nat.eqb Nat.ltb Nat.leb].
        rf_rw. rewrite H1, !kest_simpl. lia.
    + intros HN. unfold machine_step in HN.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in HN.
      rewrite Haddr in HN. discriminate HN.
  }

  (* ---------------------------------------------------------------- PC 6 *)
  destruct pc as [|pc].
  { cbn [spmv_pc ss_rf] in Hshape.
    destruct Hshape as (H1 & H2 & H3 & H4 & H5 & H6 & H7 & H10 & Hklt).
    assert (Hv : wrap32 (rf_read rf 7 * rf_read rf 10)
                 = val (j0 + Z.of_nat k) * x_arr (col (j0 + Z.of_nat k))).
    { rewrite H7, H10. unfold wrap32. apply Z.mod_small.
      apply Hprod_ok. exact Hklt. }
    right. split; [| split].
    + eexists. unfold machine_step. cbn [ss_pc nth_error spmv_prog].
      reflexivity.
    + intros s' Hstep.
      unfold machine_step in Hstep.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in Hstep.
      injection Hstep as Hst. subst s'.
      split.
      * unfold spmv_inv. left. exists k.
        split; [lia|]. split; [cbn [ss_pc]; lia|]. split; [exact Hmem|].
        cbn [spmv_pc ss_rf ss_pc].
        rf_rw.
        repeat split; first [assumption | reflexivity | exact Hv].
      * unfold spmv_measure. cbn [ss_pc ss_rf Nat.eqb Nat.ltb Nat.leb].
        rf_rw. rewrite H1, !kest_simpl. lia.
    + intros HN. unfold machine_step in HN.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in HN.
      discriminate HN.
  }

  (* ---------------------------------------------------------------- PC 7 *)
  destruct pc as [|pc].
  { cbn [spmv_pc ss_rf] in Hshape.
    destruct Hshape as (H1 & H2 & H3 & H4 & H5 & H6 & H11 & Hklt).
    assert (Hv : wrap32 (rf_read rf 3 + rf_read rf 11)
                 = spmv_sum val col x_arr j0 (S k)).
    { rewrite H3, H11. rewrite <- spmv_sum_S.
      apply wrap32_acc. lia. }
    right. split; [| split].
    + eexists. unfold machine_step. cbn [ss_pc nth_error spmv_prog].
      reflexivity.
    + intros s' Hstep.
      unfold machine_step in Hstep.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in Hstep.
      injection Hstep as Hst. subst s'.
      split.
      * unfold spmv_inv. left. exists k.
        split; [lia|]. split; [cbn [ss_pc]; lia|]. split; [exact Hmem|].
        cbn [spmv_pc ss_rf ss_pc].
        rf_rw.
        repeat split; first [assumption | reflexivity | exact Hv].
      * unfold spmv_measure. cbn [ss_pc ss_rf Nat.eqb Nat.ltb Nat.leb].
        rf_rw. rewrite H1, !kest_simpl. lia.
    + intros HN. unfold machine_step in HN.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in HN.
      discriminate HN.
  }

  (* ---------------------------------------------------------------- PC 8 *)
  destruct pc as [|pc].
  { cbn [spmv_pc ss_rf] in Hshape.
    destruct Hshape as (H1 & H2 & H3 & H4 & H5 & H6 & Hklt).
    assert (Hv : wrap32 (rf_read rf 4 + 4) = val_base + 4 * Z.of_nat (S k)).
    { rewrite H4.
      replace (val_base + 4 * Z.of_nat k + 4)
        with (val_base + 4 * Z.of_nat (S k))
        by (rewrite Nat2Z.inj_succ; ring).
      apply wrap32_vbase. lia. }
    right. split; [| split].
    + eexists. unfold machine_step. cbn [ss_pc nth_error spmv_prog].
      reflexivity.
    + intros s' Hstep.
      unfold machine_step in Hstep.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in Hstep.
      injection Hstep as Hst. subst s'.
      split.
      * unfold spmv_inv. left. exists k.
        split; [lia|]. split; [cbn [ss_pc]; lia|]. split; [exact Hmem|].
        cbn [spmv_pc ss_rf ss_pc].
        rf_rw.
        repeat split; first [assumption | reflexivity | exact Hv].
      * unfold spmv_measure. cbn [ss_pc ss_rf Nat.eqb Nat.ltb Nat.leb].
        rf_rw. rewrite H1, !kest_simpl. lia.
    + intros HN. unfold machine_step in HN.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in HN.
      discriminate HN.
  }

  (* ---------------------------------------------------------------- PC 9 *)
  destruct pc as [|pc].
  { cbn [spmv_pc ss_rf] in Hshape.
    destruct Hshape as (H1 & H2 & H3 & H4 & H5 & H6 & Hklt).
    assert (Hv : wrap32 (rf_read rf 5 + 4) = col_base + 4 * Z.of_nat (S k)).
    { rewrite H5.
      replace (col_base + 4 * Z.of_nat k + 4)
        with (col_base + 4 * Z.of_nat (S k))
        by (rewrite Nat2Z.inj_succ; ring).
      apply wrap32_cbase. lia. }
    right. split; [| split].
    + eexists. unfold machine_step. cbn [ss_pc nth_error spmv_prog].
      reflexivity.
    + intros s' Hstep.
      unfold machine_step in Hstep.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in Hstep.
      injection Hstep as Hst. subst s'.
      split.
      * unfold spmv_inv. left. exists k.
        split; [lia|]. split; [cbn [ss_pc]; lia|]. split; [exact Hmem|].
        cbn [spmv_pc ss_rf ss_pc].
        rf_rw.
        repeat split; first [assumption | reflexivity | exact Hv].
      * unfold spmv_measure. cbn [ss_pc ss_rf Nat.eqb Nat.ltb Nat.leb].
        rf_rw. rewrite H1, !kest_simpl. lia.
    + intros HN. unfold machine_step in HN.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in HN.
      discriminate HN.
  }

  (* --------------------------------------------------------------- PC 10 *)
  destruct pc as [|pc].
  { cbn [spmv_pc ss_rf] in Hshape.
    destruct Hshape as (H1 & H2 & H3 & H4 & H5 & H6 & Hklt).
    assert (Hv : wrap32 (rf_read rf 1 + 1) = j0 + Z.of_nat (S k)).
    { rewrite H1.
      replace (j0 + Z.of_nat k + 1) with (j0 + Z.of_nat (S k))
        by (rewrite Nat2Z.inj_succ; ring).
      unfold wrap32. apply Z.mod_small.
      pose proof Hj0_range as Hjr. pose proof Hjend_range as Hje.
      replace j_end with (j0 + Z.of_nat n_iters) in Hje by reflexivity.
      lia. }
    right. split; [| split].
    + eexists. unfold machine_step. cbn [ss_pc nth_error spmv_prog].
      reflexivity.
    + intros s' Hstep.
      unfold machine_step in Hstep.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in Hstep.
      injection Hstep as Hst. subst s'.
      split.
      * unfold spmv_inv. left. exists k.
        split; [lia|]. split; [cbn [ss_pc]; lia|]. split; [exact Hmem|].
        cbn [spmv_pc ss_rf ss_pc].
        rf_rw.
        repeat split; first [assumption | reflexivity | exact Hv].
      * unfold spmv_measure. cbn [ss_pc ss_rf Nat.eqb Nat.ltb Nat.leb].
        rf_rw. rewrite Hv, H1, !kest_simpl. lia.
    + intros HN. unfold machine_step in HN.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in HN.
      discriminate HN.
  }

  (* --------------------------------------------------------------- PC 11 *)
  destruct pc as [|pc].
  { cbn [spmv_pc ss_rf] in Hshape.
    destruct Hshape as (H1 & H2 & H3 & H4 & H5 & H6 & Hklt).
    right. split; [| split].
    + eexists. unfold machine_step. cbn [ss_pc nth_error spmv_prog].
      reflexivity.
    + intros s' Hstep.
      unfold machine_step in Hstep.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in Hstep.
      injection Hstep as Hst. subst s'.
      split.
      * unfold spmv_inv. left. exists (S k).
        split; [lia|]. split; [cbn [ss_pc]; lia|]. split; [exact Hmem|].
        cbn [spmv_pc ss_rf ss_pc].
        repeat split; assumption.
      * unfold spmv_measure. cbn [ss_pc ss_rf Nat.eqb Nat.ltb Nat.leb].
        rewrite H1, !kest_simpl. lia.
    + intros HN. unfold machine_step in HN.
      cbn [ss_pc ss_rf ss_mem nth_error spmv_prog spmv_exec] in HN.
      discriminate HN.
  }

  (* pc >= 12 contradicts the invariant *)
  exfalso. lia.
Qed.

(* ======================================================================== *)
(** ** 5e.  Termination theorem                                              *)
(* ======================================================================== *)

Theorem spmv_terminates :
    forall s, spmv_full_inv s -> eventually spmv_post s.
Proof.
  intros s Hinv.
  apply (eventually_by_measure' spmv_post spmv_inv spmv_measure).
  - exact spmv_STEP.
  - unfold spmv_inv. left. exact Hinv.
Qed.

Corollary spmv_correct_from_init :
    forall rf0 m,
    rf_read rf0 1 = j0 ->
    rf_read rf0 2 = j_end ->
    rf_read rf0 3 = 0 ->
    rf_read rf0 4 = val_base ->
    rf_read rf0 5 = col_base ->
    rf_read rf0 6 = x_base ->
    mem_wf m ->
    eventually spmv_post {| ss_rf := rf0; ss_mem := m; ss_pc := 0%nat |}.
Proof.
  intros rf0 m H1 H2 H3 H4 H5 H6 Hmem.
  apply spmv_terminates.
  apply spmv_init_inv; assumption.
Qed.

End spmv_loop.

(* ========================================================================== *)
(** ** 6.  Concrete 8x8 instance                                                *)
(* ========================================================================== *)

Section spmv_concrete.

Lemma concrete_sum_nonneg : forall k,
    0 <= spmv_sum concrete_val concrete_col concrete_x 0 k.
Proof.
  intro k. induction k as [|k IH].
  - cbn. lia.
  - rewrite spmv_sum_S.
    pose proof (concrete_val_range (0 + Z.of_nat k)).
    pose proof (concrete_x_range (concrete_col (0 + Z.of_nat k))).
    assert (0 <= concrete_val (0 + Z.of_nat k)
                 * concrete_x (concrete_col (0 + Z.of_nat k)))
      by (apply Z.mul_nonneg_nonneg; lia).
    lia.
Qed.

Lemma concrete_sum_le : forall a b, (a <= b)%nat ->
    spmv_sum concrete_val concrete_col concrete_x 0 a
    <= spmv_sum concrete_val concrete_col concrete_x 0 b.
Proof.
  intros a b Hab. induction Hab as [|m Hm IH].
  - lia.
  - rewrite spmv_sum_S.
    pose proof (concrete_val_range (0 + Z.of_nat m)).
    pose proof (concrete_x_range (concrete_col (0 + Z.of_nat m))).
    assert (0 <= concrete_val (0 + Z.of_nat m)
                 * concrete_x (concrete_col (0 + Z.of_nat m)))
      by (apply Z.mul_nonneg_nonneg; lia).
    lia.
Qed.

Lemma concrete_sum_ok : forall k, (k <= 21)%nat ->
    0 <= spmv_sum concrete_val concrete_col concrete_x 0 k < WORD_SIZE.
Proof.
  intros k Hk.
  pose proof (concrete_sum_nonneg k).
  pose proof (concrete_sum_le k 21 Hk).
  pose proof spmv_concrete_checksum.
  unfold WORD_SIZE. split; lia.
Qed.

Theorem spmv_concrete_terminates :
    forall val_base col_base x_base rf0 m,
    rf_read rf0 1 = 0 ->
    rf_read rf0 2 = 21 ->
    rf_read rf0 3 = 0 ->
    rf_read rf0 4 = val_base ->
    rf_read rf0 5 = col_base ->
    rf_read rf0 6 = x_base ->
    (forall k, (k < 21)%nat ->
       m (val_base + 4 * Z.of_nat k) = Some (concrete_val (Z.of_nat k))) ->
    (forall k, (k < 21)%nat ->
       m (col_base + 4 * Z.of_nat k) = Some (concrete_col (Z.of_nat k))) ->
    (forall k, (k < 21)%nat ->
       m (x_base + 4 * concrete_col (Z.of_nat k))
       = Some (concrete_x (concrete_col (Z.of_nat k)))) ->
    0 <= val_base -> val_base + 4 * 21 < WORD_SIZE ->
    0 <= col_base -> col_base + 4 * 21 < WORD_SIZE ->
    0 <= x_base ->
    (forall k, (k < 21)%nat ->
       0 <= x_base + 4 * concrete_col (Z.of_nat k) < WORD_SIZE) ->
    eventually
      (spmv_post concrete_val concrete_col concrete_x 0 21)
      {| ss_rf := rf0; ss_mem := m; ss_pc := 0%nat |}.
Proof.
  intros val_base col_base x_base rf0 m
    H1 H2 H3 H4 H5 H6
    Hval Hcol Hx
    Hvbase_nn Hvbase_hi Hcbase_nn Hcbase_hi Hxbase_nn Hxaddr.
  eapply (spmv_correct_from_init
            concrete_val concrete_col concrete_x 0 21
            val_base col_base x_base).
  - (* Hj0_range *) unfold WORD_SIZE. lia.
  - (* Hjend_range *) cbn. unfold WORD_SIZE. lia.
  - (* Hvbase_ok *) intros k Hk. split; lia.
  - (* Hcbase_ok *) intros k Hk. split; lia.
  - (* Hcol_nn *)
    intros k Hk. pose proof (concrete_col_range (0 + Z.of_nat k)). lia.
  - (* Hcolsz *)
    intros k Hk. pose proof (concrete_col_range (0 + Z.of_nat k)).
    unfold WORD_SIZE. lia.
  - (* Hxaddr_ok *)
    intros k Hk.
    replace (0 + Z.of_nat k) with (Z.of_nat k) by ring.
    apply Hxaddr. exact Hk.
  - (* Hprod_ok *)
    intros k Hk.
    pose proof (concrete_val_range (0 + Z.of_nat k)) as Hv.
    pose proof (concrete_x_range (concrete_col (0 + Z.of_nat k))) as Hx2.
    split.
    + apply Z.mul_nonneg_nonneg; lia.
    + apply Z.le_lt_trans with (9 * 8).
      * apply Z.mul_le_mono_nonneg; lia.
      * unfold WORD_SIZE. lia.
  - (* Hsum_ok *) intros k Hk. apply concrete_sum_ok. exact Hk.
  - (* rf x1 *) exact H1.
  - (* rf x2 *) rewrite H2. cbn. reflexivity.
  - (* rf x3 *) exact H3.
  - (* rf x4 *) exact H4.
  - (* rf x5 *) exact H5.
  - (* rf x6 *) exact H6.
  - (* mem_wf *)
    unfold mem_wf.
    split; [| split].
    + intros k Hk.
      replace (0 + Z.of_nat k) with (Z.of_nat k) by ring.
      apply Hval. exact Hk.
    + intros k Hk.
      replace (0 + Z.of_nat k) with (Z.of_nat k) by ring.
      apply Hcol. exact Hk.
    + intros k Hk.
      replace (0 + Z.of_nat k) with (Z.of_nat k) by ring.
      apply Hx. exact Hk.
Qed.

End spmv_concrete.

(* ========================================================================== *)
(** ** 7.  Summary of verified properties (all Qed — no Admitted)               *)
(*
   - [eventually_by_measure] / [']  : reusable inevitability backbone
   - [spmv_sum_0] / [_S] / [_term]  : partial-sum algebra
   - [spmv_concrete_checksum]       : sum val[j]*x[col[j]] = 416
   - [spmv_row0] / [spmv_row3]      : per-row spot checks
   - [concrete_{val,col,x}_range]   : data bounds
   - [wrap32_acc/vbase/cbase]       : wrap32 identity on loop values
   - [spmv_init_inv]                : initial state satisfies the invariant
   - [spmv_STEP]                    : 12-way PC case split — every reachable
                                      state steps, preserves the invariant
                                      (or terminates), decreases the measure,
                                      and never triggers UB
   - [spmv_terminates]              : inevitability of [spmv_post]
   - [spmv_correct_from_init]       : end-to-end from a clean initial state
   - [spmv_concrete_terminates]     : the 8x8/NNZ=21 instance, checksum 416
*)
(* ========================================================================== *)
