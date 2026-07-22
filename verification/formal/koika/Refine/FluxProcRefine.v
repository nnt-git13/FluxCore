(* verification/formal/koika/Refine/FluxProcRefine.v
 *
 * THE top-level FluxCore refinement: the Kôika machine (Impl/FluxProcImpl.v)
 * refines the ISA specification machine (Spec/FluxProcSpec.v) in the
 * framework's simulation relation:
 *
 *     Theorem FluxCore_refines : refines FluxCoreImpl ISASpec.
 *
 * v2: the FluxCore integer ISA — ALU/ALU-imm (15 proven ops incl. XFlux),
 * the 6 branches, JAL/JALR, LUI/AUIPC, LW/SW, and the RV32M multiply family.
 *
 * Structure mirrors ModularKoika's CsrFileRefine: a functional coupling
 * invariant (state_sim: PC + all 32 registers + all memory words agree),
 * one simulation lemma per interface method, and the sim_witness assembly.
 * The step lemma consumes the proven combinational datapath theorems
 * (FluxAluRefine / FluxBranchRefine / FluxMulRefine) through peval — the
 * circuit refinements literally plug into the machine refinement here via
 * the three dispatch bridges below.
 *)

From Koika Require Import Prelude.
From Gpu Require Import Reg.
From Flux Require Import FluxCommon.
From Flux Require Import Spec.FluxAlu.
From Flux Require Import Spec.FluxBranch.
From Flux Require Import Spec.FluxMul.
From Flux Require Import Spec.FluxIsa.
From Flux Require Import FluxMem.
From Flux Require Import FluxProc.
From Flux Require Import Spec.FluxProcSpec.
From Flux Require Import Impl.FluxAluImpl.
From Flux Require Import Impl.FluxBranchImpl.
From Flux Require Import Impl.FluxMulImpl.
From Flux Require Import Impl.FluxProcImpl.
From Flux Require Import Refine.FluxAluRefine.
From Flux Require Import Refine.FluxBranchRefine.
From Flux Require Import Refine.FluxMulRefine.

#[local] Set Default Timeout 300.

Section coupling.

  Notation Σ := FluxProcImpl.Σ.

  (* The coupling: the spec's architectural state is exactly the impl's
     storage — the PC register, pointwise the 32 register submodules, and
     pointwise the memory. *)
  Variant state_sim (st_i : ∀ m, Sem.state_t (Σ m)) (s : state_t) : Prop :=
  | state_sim_intro
      (PC  : pc_s s = st_i pc)
      (RF  : ∀ i : RegIdx, rf_s s i = st_i (reg i))
      (MEM : ∀ a : Word, mem_s s a = st_i mem a)
  .

End coupling.

Section bridges.
  (* Dispatch bridges: for every decodable sub-opcode, the dispatched Kôika
     circuit partial-evaluates to its reference function.  These are the
     proven combinational theorems, keyed by the decoders. *)

  Lemma alu_expr_of_correct (cb : bits 4) (o : alu_op) (a b : Word)
        (DEC : decode_op cb = Some o) :
    peval (alu_expr_of (V := Bits.bits) o a b) = inl (alu_spec o a b).
  Proof.
    revert DEC. unfold decode_op.
    destruct (Bits.to_nat cb) as
      [|[|[|[|[|[|[|[|[|[|[|[|[|[|[|n]]]]]]]]]]]]]]];
      intro DEC; inversion DEC; subst; cbn [alu_expr_of].
    - apply alu_and_correct.
    - apply alu_or_correct.
    - apply alu_xor_correct.
    - apply alu_add_correct.
    - apply alu_sub_correct.
    - apply alu_copyb_correct.
    - apply alu_sll_correct.
    - apply alu_srl_correct.
    - apply alu_sra_correct.
    - apply alu_slt_correct.
    - apply alu_sltu_correct.
    - apply alu_xmin_correct.
    - apply alu_xmax_correct.
    - apply alu_xlidx_correct.
    - apply alu_xabs_correct.
  Qed.

  Lemma br_nextpc_correct (cb : bits 4) (bo : branch_op) (a b p i : Word)
        (DEC : decode_br cb = Some bo) :
    peval (br_nextpc_expr (V := Bits.bits) bo a b p i)
    = inl (if branch_taken bo a b
           then Bits.plus p i
           else Bits.plus p (Bits.of_nat 32 4)).
  Proof.
    revert DEC. unfold decode_br.
    destruct (Bits.to_nat cb) as [|[|[|[|[|[|n]]]]]];
      intro DEC; inversion DEC; subst;
      unfold br_nextpc_expr;
      cbn [br_expr_of branch_eq_expr branch_ne_expr branch_lt_expr
           branch_ge_expr branch_ltu_expr branch_geu_expr
           peval branch_taken Abbr.eq Abbr.neq Abbr.slt Abbr.sge
           Abbr.lt Abbr.ge Abbr.plus CircuitPrimSpecs.sigma2];
      unfold BitFuns.bitfun_of_predicate, BitFuns._eq, BitFuns._neq;
      rewrite unfold_single; apply if_inl.
  Qed.

  Lemma mul_expr_of_correct (cb : bits 4) (m : mul_op) (a b : Word)
        (DEC : decode_mop cb = Some m) :
    peval (mul_expr_of (V := Bits.bits) m a b) = inl (mul_spec m a b).
  Proof.
    revert DEC. unfold decode_mop.
    destruct (Bits.to_nat cb) as [|[|[|[|n]]]];
      intro DEC; inversion DEC; subst; cbn [mul_expr_of mul_spec].
    - apply mul_lo_correct.
    - apply mul_hi_correct.
    - apply mul_hisu_correct.
    - apply mul_hiu_correct.
  Qed.
End bridges.

(* peval → interp_pure: a Pure expression whose partial evaluation is a value
   satisfies any postcondition holding of that value.  This is the bridge that
   plugs the combinational datapath theorems into the machine proof. *)
Lemma interp_pure_peval {mod_t} {M : Modules.t mod_t}
      {Σ : ∀ m, Sem.t (Modules.get_sig m)}
      (St : State Σ) (U : Update Σ) {ty}
      (e : t Bits.bits Pure ty) (v : bits ty) (P : bits ty -> Prop)
      (PEV : peval e = inl v) (K : P v) :
  interp_pure St U e P.
Proof.
  apply eval_interp_equiv_pure. unfold eval_pure.
  apply eval_peval_equiv. rewrite PEV. auto.
Qed.

Section methods.

  Notation impl       := FluxProcImpl.FluxCoreImpl.
  Notation spec       := FluxProcSpec.ISASpec.
  Notation Σ          := FluxProcImpl.Σ.
  Notation impl_state := (Sem.state_t impl).

  Lemma getPc_refine
        st_i st_s
        (args : context Bits.bits [])
        (LOW : state_sim st_i st_s) :
    interp_pure st_i •
      (@FluxProcImpl.getPc_syn Bits.bits)
      (fun (ret : bits 32) =>
         Sem.vmet_sem spec FluxProc.getPc args st_s ret).
  Proof.
    unfold FluxProcImpl.getPc_syn.
    steps; open_sem; rew_upd_hyp; subst.
    destruct LOW as [PC RF MEM].
    cbn [Sem.vmet_sem ISASpec].
    unfold getPc_spec.
    congruence.
  Qed.

  Lemma getReg_refine
        st_i st_s
        (args : context Bits.bits [5])
        (LOW : state_sim st_i st_s) :
    interp_pure st_i •
      (@FluxProcImpl.getReg_syn Bits.bits args)
      (fun (ret : bits 32) =>
         Sem.vmet_sem spec FluxProc.getReg args st_s ret).
  Proof.
    unfold FluxProcImpl.getReg_syn, FluxProcImpl.read_reg.
    steps; open_sem; rew_upd_hyp; subst.
    destruct LOW as [PC RF MEM].
    cbn [Sem.vmet_sem ISASpec].
    unfold getReg_spec.
    congruence.
  Qed.

  Lemma getMem_refine
        st_i st_s
        (args : context Bits.bits [32])
        (LOW : state_sim st_i st_s) :
    interp_pure st_i •
      (@FluxProcImpl.getMem_syn Bits.bits args)
      (fun (ret : bits 32) =>
         Sem.vmet_sem spec FluxProc.getMem args st_s ret).
  Proof.
    unfold FluxProcImpl.getMem_syn.
    steps; open_sem; rew_upd_hyp; subst.
    destruct LOW as [PC RF MEM].
    cbn [Sem.vmet_sem ISASpec].
    unfold getMem_spec.
    congruence.
  Qed.

  Lemma step_refine
        st_i st_s
        (args : context Bits.bits [CtrlSz])
        (LOW : state_sim (rd_init st_i) st_s) :
    interp (submodules_init _) (@FluxProcImpl.step_syn Bits.bits args) st_i
      (fun (ret : bits 0) (U' : Update Σ) =>
         ∃ st_s',
           Sem.amet_sem spec FluxProc.step args st_s ret st_s'
           ∧ state_sim (rd_init U') st_s').
  Proof.
    unfold FluxProcImpl.step_syn, FluxProcImpl.read_reg,
           FluxProcImpl.write_reg, FluxProcImpl.wr_pc4,
           FluxProcImpl.byte_mux, FluxProcImpl.half_mux,
           FluxProcImpl.byte_subst_mux, FluxProcImpl.half_subst_mux,
           FluxProcImpl.sext8_expr, FluxProcImpl.zext8_expr,
           FluxProcImpl.sext16_expr, FluxProcImpl.zext16_expr.
    steps.
    (* undecodable class/op leaves: the impl Rollbacks, nothing to prove *)
    all: try exact I.
    (* dispatch leaves: the proven datapath circuits compute their specs *)
    all: try (eapply interp_pure_peval;
              [ solve [ eapply alu_expr_of_correct; eassumption
                      | eapply br_nextpc_correct; eassumption
                      | eapply mul_expr_of_correct; eassumption ] |];
              steps).
    all: try exact I.
    (* final leaves: expose the read/write facts, pick the spec step *)
    all: open_sem; subst.
    all: destruct LOW as [PC RF MEM].
    all: eexists (mkProcState _ _ _); split;
      [ cbn [Sem.amet_sem ISASpec]; unfold step_spec, spec_next; cbn zeta;
        unfold ctrl_class, ctrl_op, ctrl_rd, ctrl_rs1, ctrl_rs2, ctrl_imm;
        repeat match goal with
               | H : decode_class _ = _ |- _ => rewrite H
               | H : decode_op _ = _ |- _ => rewrite H
               | H : decode_br _ = _ |- _ => rewrite H
               | H : decode_mop _ = _ |- _ => rewrite H
               end;
        reflexivity
      |].
    all: apply state_sim_intro; cbn [pc_s rf_s mem_s].
    (* PC / RF / MEM coupling conjuncts, closed uniformly per arm shape *)
    all: first
      [ (* PC: the pc register carries the spec's next-PC expression *)
        solve [ rew_upd; unfold plus4, align4;
                rewrite ?PC; repeat rewrite RF; repeat rewrite MEM;
                reflexivity ]
      | (* RF: no write / x0-dropped write / real write *)
        solve [ intro i;
                unfold rf_write0, rf_write, sext8, zext8, sext16, zext16,
                       load_byte, load_half;
                repeat match goal with
                       | H : eq_dec _ (Bits.zero) = _ |- _ => rewrite H
                       end;
                first
                  [ solve [ rew_upd; apply RF ]
                  | destruct (eq_dec (Bits.slice 8 5 (chd args)) i)
                      as [E | NEi];
                    [ subst i; rew_upd; unfold plus4, align4;
                      rewrite ?PC; repeat rewrite RF; repeat rewrite MEM;
                      repeat match goal with
                             | H : Bits.to_nat _ = _ |- _ => rewrite H
                             end;
                      reflexivity
                    | rew_upd; apply RF ] ] ]
      | (* MEM: no write / the SW/SB/SH read-modify-write *)
        solve [ intro ad;
                unfold mem_upd, align4, store_byte, store_half;
                rew_upd;
                repeat rewrite RF; repeat rewrite MEM;
                repeat match goal with
                       | H : Bits.to_nat _ = _ |- _ => rewrite H
                       end;
                reflexivity ]
      ].
  Qed.

End methods.

Section top.

  Notation impl       := FluxProcImpl.FluxCoreImpl.
  Notation spec       := FluxProcSpec.ISASpec.
  Notation Σ          := FluxProcImpl.Σ.
  Notation impl_state := (Sem.state_t impl).

  (* At reset both machines agree: PC = 0, every register = 0, memory = 0. *)
  Lemma proc_init_state_sim :
    state_sim (rd_init (Sem.init impl)) (Sem.init spec).
  Proof.
    apply state_sim_intro.
    - reflexivity.
    - intro i; reflexivity.
    - intro a; reflexivity.
  Qed.

  (* ============================================================
     THE TOP-LEVEL THEOREM: the FluxCore Kôika machine refines the
     ISA specification machine, in the framework's simulation
     relation (refines := mod_init ⊑ sim).
     ============================================================ *)
  Theorem FluxCore_refines : refines FluxCoreImpl ISASpec.
  Proof.
    start_witness (fun st : impl_state * Sem.state_t spec =>
                     state_sim (rd_init (fst st)) (snd st)).
    { (* initial states are coupled *)
      intros; inversion LOW; subst. apply proc_init_state_sim. }
    all: try (unfold FluxProcImpl.syn; cbn [vmet_syn amet_syn rule_syn]).
    (* vmets: getPc, getReg, getMem *)
    1: apply getPc_refine; assumption.
    1: apply getReg_refine; assumption.
    1: apply getMem_refine; assumption.
    (* amet: step *)
    1: apply step_refine; assumption.
  Qed.

End top.
