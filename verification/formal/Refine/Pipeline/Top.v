(** * PipelineCorrectness.v

    End-to-end correctness proof for the FluxCore pipeline.

    The central theorem: [pipeline_alu_correct] — after running any ALU-only
    program through the FluxCore pipeline starting from an initial state
    that matches the ISA reference, and draining the pipeline, the committed
    register file is bit-for-bit identical to what the ISA reference model
    computes.

    Proof strategy (layered):

    Layer 1 — [fwd_read_equals_pipeline_isa_rf]
      [fwd_read s rs] and [rf_read (pipeline_isa_rf s) rs] compute the same
      value for every [s] and [rs].  Proof: 3-way case split on which
      forwarding path (MEM / WB / RF) applies.

    Layer 2 — [pipeline_isa_rf_exec_step]
      [pipeline_isa_rf (pipe_exec s i)] equals (pointwise)
      [rf_write (pipeline_isa_rf s) (instr_rd i) (eval_in_ex s i)].
      Proof: definitional unfolding — the two let-bindings in
      [pipeline_isa_rf] and [pipe_exec] share the same sub-expression.

    Layer 3 — [rf_write_same_rhs]
      If two regfiles agree pointwise on every register, then applying the
      same write to both still gives agreement.  Proof: case split on rs = 0,
      rs = rd, rs ≠ rd.

    Layer 4 — [pipe_fwd_invariant_preserved]
      [pipe_fwd_invariant] is an invariant under [pipe_exec] / [isa_step].
      Proof: combines Layers 1–3 with the invariant hypothesis.

    Layer 5 — [pipe_drain_rf_eq_pipeline_isa_rf]
      After the 2-NOP drain, [(pipe_drain s).ps_rf] equals [pipeline_isa_rf s]
      pointwise.  Proof: unfold [pipe_drain] = two [pipe_exec Inop] steps and
      track the RF update.

    Layer 6 — [pipeline_alu_correct]
      By induction on [prog], [pipe_fwd_invariant] is preserved through
      [pipe_run], and Layer 5 + Layer 1 connect the drained pipeline RF to
      the ISA RF.
*)

Require Import FluxCore.Common.Types.
Require Import FluxCore.Spec.ISA.
Require Import FluxCore.Impl.Pipeline.
From Stdlib Require Import ZArith Bool List Lia.
Import ListNotations.
Open Scope Z_scope.
Open Scope bool_scope.

(* ========================================================================== *)
(** ** Pipeline ISA register file                                               *)
(* ========================================================================== *)

(** The register file that the ISA "currently sees" from the pipeline's
    perspective: committed RF, with in-flight WB and MEM writes applied. *)
Definition pipeline_isa_rf (s : pipe_state) : regfile :=
  let rf_wb :=
    if s.(ps_wb).(inf_valid) && s.(ps_wb).(inf_rd_wen)
    then rf_write s.(ps_rf) s.(ps_wb).(inf_rd) s.(ps_wb).(inf_result)
    else s.(ps_rf) in
  if s.(ps_mem).(inf_valid) && s.(ps_mem).(inf_rd_wen)
  then rf_write rf_wb s.(ps_mem).(inf_rd) s.(ps_mem).(inf_result)
  else rf_wb.

(* ========================================================================== *)
(** ** Layer 1: fwd_read = rf_read ∘ pipeline_isa_rf                          *)
(* ========================================================================== *)

(** Core forwarding theorem: [fwd_read s rs] equals the value that [rs] would
    have in [pipeline_isa_rf s]. *)
Theorem fwd_read_equals_pipeline_isa_rf : forall (s : pipe_state) (rs : Z),
    fwd_read s rs = rf_read (pipeline_isa_rf s) rs.
Proof.
  intros s rs.
  unfold fwd_read, pipeline_isa_rf.
  (* --- Case 1: MEM stage forwards to rs --- *)
  destruct (s.(ps_mem).(inf_valid) && s.(ps_mem).(inf_rd_wen)
            && (s.(ps_mem).(inf_rd) =? rs) && negb (rs =? 0)) eqn:Hmem_fwd.
  {
    apply andb_true_iff in Hmem_fwd as [H3 Hne_z].
    apply andb_true_iff in H3 as [H2 Hrd_eq].
    apply andb_true_iff in H2 as [Hv Hwen].
    apply Z.eqb_eq in Hrd_eq.
    apply negb_true_iff in Hne_z. apply Z.eqb_neq in Hne_z.
    rewrite Hv, Hwen. simpl.
    (* pipeline_isa_rf = rf_write rf_wb (ps_mem.inf_rd) (ps_mem.inf_result) *)
    (* rf_read (rf_write rf_wb rs result) rs = result   [since rs ≠ 0] *)
    rewrite <- Hrd_eq.
    symmetry. apply rf_write_read_same. rewrite Hrd_eq. exact Hne_z.
  }
  (* --- Case 2 or 3: MEM does not forward --- *)
  destruct (s.(ps_wb).(inf_valid) && s.(ps_wb).(inf_rd_wen)
            && (s.(ps_wb).(inf_rd) =? rs) && negb (rs =? 0)) eqn:Hwb_fwd.
  {
    (* --- Case 2: WB forwards to rs --- *)
    apply andb_true_iff in Hwb_fwd as [H3 Hne_z].
    apply andb_true_iff in H3 as [H2 Hrd_eq].
    apply andb_true_iff in H2 as [Hv Hwen].
    apply Z.eqb_eq in Hrd_eq.
    apply negb_true_iff in Hne_z. apply Z.eqb_neq in Hne_z.
    (* rf_wb = rf_write (ps_rf s) rs (ps_wb.inf_result) *)
    rewrite Hv, Hwen. simpl.
    (* Subcase on whether MEM writes at all *)
    destruct (s.(ps_mem).(inf_valid) && s.(ps_mem).(inf_rd_wen)) eqn:Hmem_w.
    - (* MEM writes some mem_rd ≠ rs (since Hmem_fwd = false) *)
      assert (Hmem_ne : s.(ps_mem).(inf_rd) <> rs).
      {
        intro Heq.
        assert (Htrue : s.(ps_mem).(inf_valid) && s.(ps_mem).(inf_rd_wen)
                        && (s.(ps_mem).(inf_rd) =? rs) && negb (rs =? 0) = true).
        { rewrite Hmem_w. rewrite Heq, Z.eqb_refl. simpl.
          apply negb_true_iff, Z.eqb_neq. exact Hne_z. }
        congruence.
      }
      (* rf_read (rf_write rf_wb ps_mem.inf_rd v) rs = rf_read rf_wb rs [mem_rd ≠ rs] *)
      rewrite rf_write_read_other; [| exact Hmem_ne].
      (* rf_read rf_wb rs = rf_read (rf_write ps_rf rs v_wb) rs = v_wb [rs ≠ 0] *)
      rewrite <- Hrd_eq. symmetry. apply rf_write_read_same. rewrite Hrd_eq. exact Hne_z.
    - (* MEM doesn't write at all *)
      rewrite <- Hrd_eq. symmetry. apply rf_write_read_same. rewrite Hrd_eq. exact Hne_z.
  }
  {
    (* --- Case 3: neither MEM nor WB forwards --- *)
    (* LHS = rf_read (ps_rf s) rs *)
    (* Need rs = 0 subcase for rf_read_x0_zero *)
    destruct (rs =? 0) eqn:Hrs.
    - apply Z.eqb_eq in Hrs. subst rs.
      rewrite !rf_read_x0_zero. reflexivity.
    - apply Z.eqb_neq in Hrs.
      (* WB doesn't write rs (even if it writes something) *)
      destruct (s.(ps_wb).(inf_valid) && s.(ps_wb).(inf_rd_wen)) eqn:Hwb_w.
      + (* WB writes some wb_rd ≠ rs *)
        assert (Hwb_ne : s.(ps_wb).(inf_rd) <> rs).
        {
          intro Heq.
          rewrite Heq, Z.eqb_refl in Hwb_fwd.
          try rewrite Hwb_w in Hwb_fwd.
          simpl in Hwb_fwd.
          first [ discriminate Hwb_fwd
                | apply negb_false_iff in Hwb_fwd; apply Z.eqb_eq in Hwb_fwd;
                  exact (Hrs Hwb_fwd) ].
        }
        try rewrite Hwb_w. simpl.
        destruct (s.(ps_mem).(inf_valid) && s.(ps_mem).(inf_rd_wen)) eqn:Hmem_w.
        * assert (Hmem_ne : s.(ps_mem).(inf_rd) <> rs).
          {
            intro Heq.
            rewrite Heq, Z.eqb_refl in Hmem_fwd.
            try rewrite Hmem_w in Hmem_fwd.
            simpl in Hmem_fwd.
            first [ discriminate Hmem_fwd
                  | apply negb_false_iff in Hmem_fwd; apply Z.eqb_eq in Hmem_fwd;
                    exact (Hrs Hmem_fwd) ].
          }
          try rewrite Hmem_w. simpl.
          rewrite rf_write_read_other; [| exact Hmem_ne].
          rewrite rf_write_read_other; [| exact Hwb_ne].
          reflexivity.
        * try rewrite Hmem_w. simpl.
          rewrite rf_write_read_other; [| exact Hwb_ne].
          reflexivity.
      + (* WB doesn't write *)
        try rewrite Hwb_w. simpl.
        destruct (s.(ps_mem).(inf_valid) && s.(ps_mem).(inf_rd_wen)) eqn:Hmem_w.
        * assert (Hmem_ne : s.(ps_mem).(inf_rd) <> rs).
          {
            intro Heq.
            rewrite Heq, Z.eqb_refl in Hmem_fwd.
            try rewrite Hmem_w in Hmem_fwd.
            simpl in Hmem_fwd.
            first [ discriminate Hmem_fwd
                  | apply negb_false_iff in Hmem_fwd; apply Z.eqb_eq in Hmem_fwd;
                    exact (Hrs Hmem_fwd) ].
          }
          try rewrite Hmem_w. simpl.
          rewrite rf_write_read_other; [| exact Hmem_ne].
          reflexivity.
        * try rewrite Hmem_w. simpl. reflexivity.
  }
Qed.

(* ========================================================================== *)
(** ** Key forwarding lemmas (retained from prior version, fully proven)        *)
(* ========================================================================== *)

Lemma fwd_mem_wins : forall s rs,
    s.(ps_mem).(inf_valid)  = true ->
    s.(ps_mem).(inf_rd_wen) = true ->
    s.(ps_mem).(inf_rd)     = rs ->
    rs <> 0 ->
    fwd_read s rs = s.(ps_mem).(inf_result).
Proof.
  intros s rs Hv Hwen Hrd Hne.
  unfold fwd_read.
  rewrite Hv, Hwen, Hrd, Z.eqb_refl.
  apply Z.eqb_neq in Hne. rewrite Hne. simpl. reflexivity.
Qed.

Lemma fwd_wb_wins : forall s rs,
    (s.(ps_mem).(inf_valid) && s.(ps_mem).(inf_rd_wen)
     && (s.(ps_mem).(inf_rd) =? rs) && negb (rs =? 0)) = false ->
    s.(ps_wb).(inf_valid)  = true ->
    s.(ps_wb).(inf_rd_wen) = true ->
    s.(ps_wb).(inf_rd)     = rs ->
    rs <> 0 ->
    fwd_read s rs = s.(ps_wb).(inf_result).
Proof.
  intros s rs Hmem Hv Hwen Hrd Hne.
  unfold fwd_read. rewrite Hmem.
  rewrite Hv, Hwen, Hrd, Z.eqb_refl.
  apply Z.eqb_neq in Hne. rewrite Hne. simpl. reflexivity.
Qed.

Lemma fwd_rf_fallthrough : forall s rs,
    (s.(ps_mem).(inf_valid) && s.(ps_mem).(inf_rd_wen)
     && (s.(ps_mem).(inf_rd) =? rs) && negb (rs =? 0)) = false ->
    (s.(ps_wb).(inf_valid) && s.(ps_wb).(inf_rd_wen)
     && (s.(ps_wb).(inf_rd) =? rs) && negb (rs =? 0)) = false ->
    fwd_read s rs = rf_read s.(ps_rf) rs.
Proof.
  intros s rs Hmem Hwb.
  unfold fwd_read. rewrite Hmem, Hwb. reflexivity.
Qed.

(* ========================================================================== *)
(** ** Layer 2: pipeline_isa_rf commutes with pipe_exec                        *)
(* ========================================================================== *)

(** If two regfiles agree pointwise on [rs], then applying the same write
    [rd ← v] to both still gives agreement on [rs]. *)
Lemma rf_write_same_rhs : forall rf1 rf2 rd v rs,
    rf_read rf1 rs = rf_read rf2 rs ->
    rf_read (rf_write rf1 rd v) rs = rf_read (rf_write rf2 rd v) rs.
Proof.
  intros rf1 rf2 rd v rs Heq.
  destruct (rs =? 0) eqn:Hrs.
  - apply Z.eqb_eq in Hrs. subst. rewrite !rf_read_x0_zero. reflexivity.
  - apply Z.eqb_neq in Hrs.
    destruct (rs =? rd) eqn:Hrsrd.
    + apply Z.eqb_eq in Hrsrd. subst.
      destruct (rd =? 0) eqn:Hrd.
      * apply Z.eqb_eq in Hrd. subst. rewrite !rf_read_x0_zero. reflexivity.
      * apply Z.eqb_neq in Hrd.
        rewrite !rf_write_read_same; [reflexivity | exact Hrd | exact Hrd].
    + apply Z.eqb_neq in Hrsrd.
      assert (Hrdrs : rd <> rs) by (intro H; apply Hrsrd; symmetry; exact H).
      rewrite !rf_write_read_other; [exact Heq | exact Hrdrs | exact Hrdrs].
Qed.

(** KEY STRUCTURAL LEMMA: [pipeline_isa_rf] after one [pipe_exec] step equals
    applying the instruction's result to the previous [pipeline_isa_rf].

    The proof is definitional: both sides reduce to the same let-binding
    computation because [pipe_exec] shifts old-MEM → new-WB and commits
    old-WB → ps_rf, while [pipeline_isa_rf] applies WB then MEM. *)
Lemma pipeline_isa_rf_exec_step : forall s i rs,
    rf_read (pipeline_isa_rf (pipe_exec s i)) rs =
    rf_read (rf_write (pipeline_isa_rf s) (instr_rd i) (eval_in_ex s i)) rs.
Proof.
  intros s i rs.
  (* pipe_exec commits old-WB into ps_rf and shifts old-MEM into the WB slot,
     so the inner term of [pipeline_isa_rf (pipe_exec s i)] is definitionally
     [pipeline_isa_rf s]; only the fresh MEM slot (valid=true,
     rd_wen = instr_writes_rd i) sits on top. *)
  unfold pipeline_isa_rf, pipe_exec. simpl.
  destruct (instr_writes_rd i) eqn:Hwr; simpl.
  - (* fresh slot writes: both sides carry the same rf_write on top *)
    try rewrite Hwr. reflexivity.
  - (* no write: the rf_write on the RHS targets x0 and is a no-op *)
    destruct i as [op rd rs1 rs2 | op rd rs1 imm |]; simpl in Hwr |- *.
    + apply negb_false_iff in Hwr. apply Z.eqb_eq in Hwr. subst rd.
      symmetry. apply rf_write_x0_nop.
    + apply negb_false_iff in Hwr. apply Z.eqb_eq in Hwr. subst rd.
      symmetry. apply rf_write_x0_nop.
    + symmetry. apply rf_write_x0_nop.
Qed.

(* ========================================================================== *)
(** ** Pipeline correctness invariant                                           *)
(* ========================================================================== *)

(** The invariant: for every register [rs], the forwarded read (which accounts
    for in-flight writes from MEM and WB) equals the ISA's current register
    value. *)
Definition pipe_fwd_invariant (s : pipe_state) (isa_s : isa_state) : Prop :=
  forall rs, fwd_read s rs = rf_read isa_s.(isa_rf) rs.

Lemma pipe_init_invariant : pipe_fwd_invariant pipe_init isa_init.
Proof.
  unfold pipe_fwd_invariant, pipe_init, isa_init. intro rs.
  unfold fwd_read. simpl. reflexivity.
Qed.

(* ========================================================================== *)
(** ** Layer 3: invariant preservation under pipe_exec                         *)
(* ========================================================================== *)

(** After issuing one instruction [i] through [pipe_exec] and simultaneously
    advancing the ISA by [isa_step], [pipe_fwd_invariant] is maintained. *)
Lemma pipe_fwd_invariant_preserved : forall s isa_s i,
    pipe_fwd_invariant s isa_s ->
    pipe_fwd_invariant (pipe_exec s i) (isa_step isa_s i).
Proof.
  intros s isa_s i Hinv rs.
  (* Rewrite LHS using fwd_read_equals_pipeline_isa_rf *)
  rewrite fwd_read_equals_pipeline_isa_rf.
  (* Use Layer 2: pipeline_isa_rf (pipe_exec s i) = rf_write (pipeline_isa_rf s) rd result *)
  rewrite pipeline_isa_rf_exec_step.
  (* LHS now: rf_read (rf_write (pipeline_isa_rf s) (instr_rd i) (eval_in_ex s i)) rs *)
  (* RHS: rf_read (isa_step isa_s i).(isa_rf) rs *)
  (* The pipeline_isa_rf s and isa_s.isa_rf agree pointwise by Hinv + Layer 1 *)
  assert (Hpisa : forall r, rf_read (pipeline_isa_rf s) r = rf_read isa_s.(isa_rf) r).
  { intro r. rewrite <- fwd_read_equals_pipeline_isa_rf. exact (Hinv r). }
  (* The eval_in_ex and isa_step compute the same result (using Hinv) *)
  destruct i as [op rd rs1 rs2 | op rd rs1 imm |]; simpl.
  - (* Ialu_rr: eval_in_ex = alu_eval op (fwd_read s rs1) (fwd_read s rs2) *)
    rewrite Hinv, Hinv.
    (* Goal: rf_read (rf_write (pipeline_isa_rf s) rd (alu_eval op ... )) rs
             = rf_read (rf_write isa_s.isa_rf rd (alu_eval op ...)) rs *)
    apply rf_write_same_rhs. exact (Hpisa rs).
  - (* Ialu_ri *)
    rewrite Hinv.
    apply rf_write_same_rhs. exact (Hpisa rs).
  - (* Inop: instr_rd = 0, rf_write rf 0 v = rf *)
    simpl.
    rewrite !rf_write_x0_nop.
    exact (Hpisa rs).
Qed.

(** Generalise to [pipe_run] over a full program. *)
Lemma pipe_run_preserves_invariant : forall prog s isa_s,
    pipe_fwd_invariant s isa_s ->
    pipe_fwd_invariant (pipe_run s prog) (isa_run isa_s prog).
Proof.
  intro prog. induction prog as [| i t IH]; intros s isa_s Hinv.
  - simpl. exact Hinv.
  - simpl. apply IH. apply pipe_fwd_invariant_preserved. exact Hinv.
Qed.

(* ========================================================================== *)
(** ** Layer 4: pipe_exec_mem_result                                            *)
(* ========================================================================== *)

(** After issuing [i], the MEM slot's result is the ISA result for [i] applied
    to [isa_s] — OR [i] doesn't write to any register. *)
Lemma pipe_exec_mem_result : forall s isa_s i,
    pipe_fwd_invariant s isa_s ->
    (pipe_exec s i).(ps_mem).(inf_result) =
      rf_read (isa_step isa_s i).(isa_rf) (instr_rd i) \/
    instr_writes_rd i = false.
Proof.
  intros s isa_s i Hinv.
  destruct i as [op rd rs1 rs2 | op rd rs1 imm |]; simpl.
  - (* Ialu_rr: check rd ≠ 0 *)
    unfold instr_writes_rd, instr_rd. simpl.
    destruct (rd =? 0) eqn:Hrd.
    + right. simpl. try rewrite Hrd. reflexivity.
    + left.
      apply Z.eqb_neq in Hrd.
      (* MEM result = eval_in_ex s (Ialu_rr op rd rs1 rs2) = alu_eval op (fwd_read s rs1) (fwd_read s rs2) *)
      (* ISA result at rd = alu_eval op (rf_read isa_s.isa_rf rs1) (rf_read isa_s.isa_rf rs2) *)
      (* These agree by Hinv *)
      simpl. rewrite Hinv, Hinv.
      (* rf_read (rf_write isa_s.isa_rf rd result) rd = result [rd ≠ 0] *)
      symmetry. apply rf_write_read_same. exact Hrd.
  - (* Ialu_ri *)
    unfold instr_writes_rd, instr_rd. simpl.
    destruct (rd =? 0) eqn:Hrd.
    + right. simpl. try rewrite Hrd. reflexivity.
    + left.
      apply Z.eqb_neq in Hrd.
      simpl. rewrite Hinv.
      symmetry. apply rf_write_read_same. exact Hrd.
  - (* Inop *)
    right. simpl. reflexivity.
Qed.

(* ========================================================================== *)
(** ** Layer 5: pipe_drain commits all in-flight results                        *)
(* ========================================================================== *)

(** After the 2-NOP drain, the committed RF equals [pipeline_isa_rf s]. *)
Lemma pipe_drain_rf_eq_pipeline_isa_rf : forall s rs,
    rf_read (pipe_drain s).(ps_rf) rs = rf_read (pipeline_isa_rf s) rs.
Proof.
  intros s rs.
  unfold pipe_drain, pipeline_isa_rf, pipe_exec. simpl.
  (* After two NOP pipe_exec steps:
     - Step 1: ps_rf = commit s.ps_wb; ps_wb = s.ps_mem; ps_mem = NOP
     - Step 2: ps_rf = commit s.ps_mem (from step-1 ps_wb) from step-1 ps_rf; ps_wb = NOP
     The final ps_rf = apply(s.ps_mem, apply(s.ps_wb, s.ps_rf)) = pipeline_isa_rf s *)
  destruct (s.(ps_wb).(inf_valid) && s.(ps_wb).(inf_rd_wen)) eqn:Hwb;
  destruct (s.(ps_mem).(inf_valid) && s.(ps_mem).(inf_rd_wen)) eqn:Hmem;
  simpl; rewrite ?Hwb, ?Hmem; simpl; reflexivity.
Qed.

(** After the drain, neither the MEM nor WB slot write any register
    (both are Inop with inf_rd_wen = false), so fwd_read = RF read. *)
Lemma pipe_drain_fwd_read_eq_rf : forall s rs,
    fwd_read (pipe_drain s) rs = rf_read (pipe_drain s).(ps_rf) rs.
Proof.
  intros s rs.
  unfold fwd_read, pipe_drain, pipe_exec. simpl.
  (* Both NOP slots: inf_rd_wen = instr_writes_rd Inop = false *)
  (* So the MEM and WB forward guards are both false (inf_rd_wen = false) *)
  reflexivity.
Qed.

(* ========================================================================== *)
(** ** Layer 6: pipeline_alu_correct — the main theorem                         *)
(* ========================================================================== *)

(** For any program [prog] containing only ALU instructions (no branches,
    loads, or stores), after running the program through the pipeline and
    draining, the committed register file equals the ISA register file. *)
Theorem pipeline_alu_correct : forall (prog : list instr) (s0 : isa_state),
    let pipe_s0 := {| ps_rf  := s0.(isa_rf)
                    ; ps_mem := inflight_nop
                    ; ps_wb  := inflight_nop |} in
    forall rs,
    rf_read (pipe_exec_full pipe_s0 prog).(ps_rf) rs =
    rf_read (isa_run s0 prog).(isa_rf) rs.
Proof.
  intros prog s0 pipe_s0 rs.
  (* Unfold pipe_exec_full = pipe_drain ∘ pipe_run *)
  unfold pipe_exec_full.
  (* Step 1: the drain RF equals pipeline_isa_rf of the run state *)
  rewrite pipe_drain_rf_eq_pipeline_isa_rf.
  (* Step 2: by fwd_read_equals_pipeline_isa_rf, this equals the fwd_read *)
  rewrite <- fwd_read_equals_pipeline_isa_rf.
  (* Step 3: the run state satisfies pipe_fwd_invariant w.r.t. isa_run s0 prog *)
  apply pipe_run_preserves_invariant.
  (* Step 4: the initial state satisfies the invariant *)
  (* pipe_fwd_invariant pipe_s0 s0: need fwd_read pipe_s0 rs = rf_read s0.isa_rf rs *)
  unfold pipe_fwd_invariant, pipe_s0.
  intro r. unfold fwd_read. simpl. reflexivity.
Qed.

(* ========================================================================== *)
(** ** Concrete correctness examples                                            *)
(* ========================================================================== *)

Example add_correct : forall rf rd rs1 rs2,
    rd <> 0 ->
    let prog := [Ialu_rr ALU_ADD rd rs1 rs2] in
    let s0   := {| isa_rf := rf ; isa_pc := 0 |} in
    rf_read (isa_run s0 prog).(isa_rf) rd =
    alu_eval ALU_ADD (rf_read rf rs1) (rf_read rf rs2).
Proof.
  intros rf rd rs1 rs2 Hrd prog s0.
  unfold prog, s0, isa_run, isa_step. simpl.
  apply rf_write_read_same. exact Hrd.
Qed.

Example fwd_one_cycle_gap : forall rf (op1 : alu_op) (rd1 rs1a rs1b : Z)
                                        (op2 : alu_op) (rd2 rs2b : Z),
    rd1 <> 0 ->
    let v1     := alu_eval op1 (rf_read rf rs1a) (rf_read rf rs1b) in
    let s_mem  := {| inf_valid := true
                   ; inf_rd_wen := true
                   ; inf_rd := rd1
                   ; inf_result := v1 |} in
    let s_pipe := {| ps_rf := rf ; ps_mem := s_mem ; ps_wb := inflight_nop |} in
    fwd_read s_pipe rd1 = v1.
Proof.
  intros rf op1 rd1 rs1a rs1b op2 rd2 rs2b Hrd1 v1 s_mem s_pipe.
  apply fwd_mem_wins; simpl; try reflexivity; assumption.
Qed.

Example fwd_two_cycle_gap : forall rf op1 rd1 rs1a rs1b v_mem_other rd_mem_other,
    rd1 <> 0 ->
    rd_mem_other <> rd1 ->
    let v1    := alu_eval op1 (rf_read rf rs1a) (rf_read rf rs1b) in
    let s_mem := {| inf_valid  := true ; inf_rd_wen := true
                  ; inf_rd     := rd_mem_other ; inf_result := v_mem_other |} in
    let s_wb  := {| inf_valid  := true ; inf_rd_wen := true
                  ; inf_rd     := rd1 ; inf_result := v1 |} in
    let s_pipe := {| ps_rf := rf ; ps_mem := s_mem ; ps_wb := s_wb |} in
    fwd_read s_pipe rd1 = v1.
Proof.
  intros rf op1 rd1 rs1a rs1b v_mem_other rd_mem_other Hrd1 Hne v1 s_mem s_wb s_pipe.
  unfold fwd_read, s_pipe, s_mem, s_wb. simpl.
  assert (H_mem_no_fwd : (rd_mem_other =? rd1) = false).
  { apply Z.eqb_neq. exact Hne. }
  rewrite H_mem_no_fwd. simpl.
  rewrite Z.eqb_refl.
  apply Z.eqb_neq in Hrd1. rewrite Hrd1. simpl. reflexivity.
Qed.

(* ========================================================================== *)
(** ** Summary of verified properties

    Fully proven (no Admitted):
    - [fwd_read_equals_pipeline_isa_rf] : fwd_read matches pipeline_isa_rf.
    - [rf_write_same_rhs]               : equal reads survive same write.
    - [pipeline_isa_rf_exec_step]       : pipeline_isa_rf commutes with pipe_exec.
    - [pipe_fwd_invariant_preserved]    : invariant survives one pipe_exec / isa_step.
    - [pipe_run_preserves_invariant]    : invariant survives pipe_run over any program.
    - [pipe_exec_mem_result]            : MEM slot result = ISA result (or no write).
    - [pipe_drain_rf_eq_pipeline_isa_rf]: drain commits all in-flight results.
    - [pipe_drain_fwd_read_eq_rf]       : after drain, fwd_read = committed RF.
    - [pipeline_alu_correct]            : pipeline RF = ISA RF after program run.
    - [fwd_mem_wins] / [fwd_wb_wins] / [fwd_rf_fallthrough] : key fwd cases.
    - [pipe_init_invariant]             : empty pipeline satisfies invariant.
    - [add_correct] / [fwd_one_cycle_gap] / [fwd_two_cycle_gap] : concrete examples.
*)
