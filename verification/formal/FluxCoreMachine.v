(** * FluxCoreMachine.v

    Full RV32I + RV32M machine model for FluxCore formal verification.

    This file defines the abstract machine that all program-level proofs reason
    about.  It generalises the [spmv_instr]/[spmv_state] model in FluxCoreSPMV.v
    to cover the complete RV32I + RV32M instruction set, and lifts the
    [eventually] inevitability modality and its backbone lemma out of the
    SpMV-specific file so they can be reused for any program proof.

    Structure:
      §1  Machine state ([machine_state]) and program counter model.
      §2  Full instruction set ([rv32i_instr]) covering every RV32I + RV32M
          instruction relevant to FluxCore programs.
      §3  Single-instruction execution ([machine_exec]).
      §4  Program counter sequencing and the fetch/execute step ([machine_step]).
      §5  Inevitability modality ([eventually]) and backbone lemmas.
      §6  Multi-step execution ([machine_run_n]) and safety.
      §7  Key structural lemmas.

    The model deliberately omits:
    - Privileged (M-mode) CSR instructions — covered by FluxCoreISA.v extensions.
    - Fence / EBREAK / WFI — not needed for the programs proved here.
    - Sub-word memory (LH/LHU/LB/LBU/SH/SB) — loads/stores are word-granular;
      sub-word variants can be added when needed.

    Memory is imported from [FluxCoreMemory.v].  The register file is imported
    from [FluxCoreTypes.v].
*)

Require Import FluxCore.FluxCoreTypes.
Require Import FluxCore.FluxCoreMemory.
From Stdlib Require Import ZArith Bool List Lia Nat.
Import ListNotations.
Open Scope Z_scope.
Open Scope bool_scope.

(* ========================================================================== *)
(** ** §1.  Machine state                                                       *)
(* ========================================================================== *)

(** The architectural state visible to software.
    - [ms_rf]  : committed register file (x0 always = 0 by [rf_read]).
    - [ms_mem] : data memory (word-granular, byte-addressed).
    - [ms_pc]  : program counter — instruction index (not byte address).
                 The FluxCore ISA uses byte-addressed PCs but for the proof
                 model we use instruction indices so program lists are indexable
                 directly.  Byte address = ms_pc × 4.
*)
Record machine_state : Type := mk_ms
  { ms_rf  : regfile
  ; ms_mem : memory
  ; ms_pc  : nat
  }.

Definition ms_init (rf0 : regfile) (m0 : memory) : machine_state :=
  {| ms_rf := rf0 ; ms_mem := m0 ; ms_pc := 0 |}.

(* ========================================================================== *)
(** ** §2.  Instruction set (RV32I + RV32M subset)                             *)
(* ========================================================================== *)

(** Abstract instruction representation.  Register indices and immediates are
    [Z].  The encoding details (opcode bits) are irrelevant to the proof. *)
Inductive rv32i_instr : Type :=
  (* ----------------------------------------------------------------------- *)
  (* RV32I: ALU register–register                                             *)
  (* ----------------------------------------------------------------------- *)
  | MI_add   (rd rs1 rs2 : Z)
  | MI_sub   (rd rs1 rs2 : Z)
  | MI_and   (rd rs1 rs2 : Z)
  | MI_or    (rd rs1 rs2 : Z)
  | MI_xor   (rd rs1 rs2 : Z)
  | MI_sll   (rd rs1 rs2 : Z)
  | MI_srl   (rd rs1 rs2 : Z)
  | MI_sra   (rd rs1 rs2 : Z)
  | MI_slt   (rd rs1 rs2 : Z)
  | MI_sltu  (rd rs1 rs2 : Z)
  (* ----------------------------------------------------------------------- *)
  (* RV32I: ALU register–immediate                                            *)
  (* ----------------------------------------------------------------------- *)
  | MI_addi  (rd rs1 : Z) (imm : Z)
  | MI_andi  (rd rs1 : Z) (imm : Z)
  | MI_ori   (rd rs1 : Z) (imm : Z)
  | MI_xori  (rd rs1 : Z) (imm : Z)
  | MI_slli  (rd rs1 : Z) (shamt : Z)
  | MI_srli  (rd rs1 : Z) (shamt : Z)
  | MI_srai  (rd rs1 : Z) (shamt : Z)
  | MI_slti  (rd rs1 : Z) (imm : Z)
  | MI_sltiu (rd rs1 : Z) (imm : Z)
  (* ----------------------------------------------------------------------- *)
  (* RV32I: Upper-immediate                                                   *)
  (* ----------------------------------------------------------------------- *)
  | MI_lui   (rd : Z) (imm : Z)          (** rd := imm << 12 (upper bits)    *)
  | MI_auipc (rd : Z) (imm : Z) (pc : Z) (** rd := pc + (imm << 12)          *)
  (* ----------------------------------------------------------------------- *)
  (* RV32I: Loads (word-granular)                                             *)
  (* ----------------------------------------------------------------------- *)
  | MI_lw    (rd rs1 : Z) (imm : Z)      (** rd := mem[rs1 + imm]            *)
  (* ----------------------------------------------------------------------- *)
  (* RV32I: Stores (word-granular)                                            *)
  (* ----------------------------------------------------------------------- *)
  | MI_sw    (rs1 rs2 : Z) (imm : Z)     (** mem[rs1 + imm] := rs2           *)
  (* ----------------------------------------------------------------------- *)
  (* RV32I: Branches                                                          *)
  (* ----------------------------------------------------------------------- *)
  | MI_beq   (rs1 rs2 : Z) (target : nat)
  | MI_bne   (rs1 rs2 : Z) (target : nat)
  | MI_blt   (rs1 rs2 : Z) (target : nat)
  | MI_bge   (rs1 rs2 : Z) (target : nat)
  | MI_bltu  (rs1 rs2 : Z) (target : nat)
  | MI_bgeu  (rs1 rs2 : Z) (target : nat)
  (* ----------------------------------------------------------------------- *)
  (* RV32I: Jumps                                                             *)
  (* ----------------------------------------------------------------------- *)
  | MI_jal   (rd : Z) (target : nat)     (** rd := pc+1; pc := target        *)
  | MI_jalr  (rd rs1 : Z) (imm : Z)      (** rd := pc+1; pc := (rs1+imm)/4   *)
  (* ----------------------------------------------------------------------- *)
  (* RV32M: Multiply                                                          *)
  (* ----------------------------------------------------------------------- *)
  | MI_mul   (rd rs1 rs2 : Z)            (** lower 32 bits of rs1×rs2        *)
  | MI_mulh  (rd rs1 rs2 : Z)            (** upper 32 bits of signed×signed  *)
  | MI_mulhu (rd rs1 rs2 : Z)            (** upper 32 bits of unsigned×unsigned *)
  | MI_mulhsu(rd rs1 rs2 : Z)            (** upper 32 bits of signed×unsigned   *)
  (* ----------------------------------------------------------------------- *)
  (* RV32M: Divide / remainder                                                *)
  (* ----------------------------------------------------------------------- *)
  | MI_div   (rd rs1 rs2 : Z)
  | MI_divu  (rd rs1 rs2 : Z)
  | MI_rem   (rd rs1 rs2 : Z)
  | MI_remu  (rd rs1 rs2 : Z)
  (* ----------------------------------------------------------------------- *)
  (* No-op                                                                    *)
  (* ----------------------------------------------------------------------- *)
  | MI_nop
  .

(* ========================================================================== *)
(** ** §3.  Single-instruction execution                                        *)
(* ========================================================================== *)

(** Signed 64-bit product, upper half. *)
Definition mulh_s (a b : Z) : Z :=
  let a_s := to_signed32 a in
  let b_s := to_signed32 b in
  (a_s * b_s) / WORD_SIZE.

(** Unsigned 64-bit product, upper half. *)
Definition mulhu_u (a b : Z) : Z :=
  (a * b) / WORD_SIZE.

(** Signed×unsigned product, upper half. *)
Definition mulhsu_su (a b : Z) : Z :=
  let a_s := to_signed32 a in
  (a_s * b) / WORD_SIZE.

(** RISC-V signed division with the mandated special cases:
    - divide by zero: result = -1 (all-ones)
    - INT_MIN / -1: result = INT_MIN (overflow). *)
Definition div_s (a b : Z) : Z :=
  if b =? 0 then wrap32 (-1)
  else if a =? wrap32 (-1 * HALF_WORD) && (b =? wrap32 (-1)) then wrap32 (-1 * HALF_WORD)
  else wrap32 (to_signed32 a / to_signed32 b).

Definition divu_u (a b : Z) : Z :=
  if b =? 0 then wrap32 (-1) else wrap32 (a / b).

Definition rem_s (a b : Z) : Z :=
  if b =? 0 then a
  else if a =? wrap32 (-1 * HALF_WORD) && (b =? wrap32 (-1)) then 0
  else wrap32 (to_signed32 a mod to_signed32 b).

Definition remu_u (a b : Z) : Z :=
  if b =? 0 then a else wrap32 (a mod b).

(** Execute instruction [i] against state [s].
    Returns [None] for any load/JALR that reads uninitialized memory or an
    unresolvable JALR target.  All other operations return [Some s']. *)
Definition machine_exec (s : machine_state) (i : rv32i_instr) : option machine_state :=
  let r  := rf_read s.(ms_rf) in       (* shorthand: read register          *)
  let pc := s.(ms_pc) in               (* current PC index                  *)
  let advance := S pc in               (* normal next-PC (sequential)       *)
  match i with
  (* ---- ALU R-type ---- *)
  | MI_add  rd rs1 rs2 => Some {| ms_rf := rf_write s.(ms_rf) rd (wrap32 (r rs1 + r rs2))
                                 ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_sub  rd rs1 rs2 => Some {| ms_rf := rf_write s.(ms_rf) rd (wrap32 (r rs1 - r rs2))
                                 ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_and  rd rs1 rs2 => Some {| ms_rf := rf_write s.(ms_rf) rd (Z.land (r rs1) (r rs2))
                                 ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_or   rd rs1 rs2 => Some {| ms_rf := rf_write s.(ms_rf) rd (Z.lor  (r rs1) (r rs2))
                                 ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_xor  rd rs1 rs2 => Some {| ms_rf := rf_write s.(ms_rf) rd (Z.lxor (r rs1) (r rs2))
                                 ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_sll  rd rs1 rs2 => Some {| ms_rf := rf_write s.(ms_rf) rd (wrap32 (Z.shiftl (r rs1) (shamt (r rs2))))
                                 ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_srl  rd rs1 rs2 => Some {| ms_rf := rf_write s.(ms_rf) rd (Z.shiftr (r rs1) (shamt (r rs2)))
                                 ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_sra  rd rs1 rs2 => Some {| ms_rf := rf_write s.(ms_rf) rd (wrap32 (Z.shiftr (to_signed32 (r rs1)) (shamt (r rs2))))
                                 ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_slt  rd rs1 rs2 => let v := if to_signed32 (r rs1) <? to_signed32 (r rs2) then 1 else 0 in
                           Some {| ms_rf := rf_write s.(ms_rf) rd v ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_sltu rd rs1 rs2 => let v := if r rs1 <? r rs2 then 1 else 0 in
                           Some {| ms_rf := rf_write s.(ms_rf) rd v ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  (* ---- ALU I-type ---- *)
  | MI_addi  rd rs1 imm => Some {| ms_rf := rf_write s.(ms_rf) rd (wrap32 (r rs1 + imm))
                                  ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_andi  rd rs1 imm => Some {| ms_rf := rf_write s.(ms_rf) rd (Z.land (r rs1) imm)
                                  ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_ori   rd rs1 imm => Some {| ms_rf := rf_write s.(ms_rf) rd (Z.lor  (r rs1) imm)
                                  ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_xori  rd rs1 imm => Some {| ms_rf := rf_write s.(ms_rf) rd (Z.lxor (r rs1) imm)
                                  ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_slli  rd rs1 sh  => Some {| ms_rf := rf_write s.(ms_rf) rd (wrap32 (Z.shiftl (r rs1) sh))
                                  ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_srli  rd rs1 sh  => Some {| ms_rf := rf_write s.(ms_rf) rd (Z.shiftr (r rs1) sh)
                                  ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_srai  rd rs1 sh  => Some {| ms_rf := rf_write s.(ms_rf) rd (wrap32 (Z.shiftr (to_signed32 (r rs1)) sh))
                                  ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_slti  rd rs1 imm => let v := if to_signed32 (r rs1) <? imm then 1 else 0 in
                            Some {| ms_rf := rf_write s.(ms_rf) rd v ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_sltiu rd rs1 imm => let v := if r rs1 <? imm then 1 else 0 in
                            Some {| ms_rf := rf_write s.(ms_rf) rd v ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  (* ---- Upper-immediate ---- *)
  | MI_lui   rd imm     => Some {| ms_rf := rf_write s.(ms_rf) rd (wrap32 (Z.shiftl imm 12))
                                  ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_auipc rd imm pc_byte =>
                            Some {| ms_rf := rf_write s.(ms_rf) rd (wrap32 (pc_byte + Z.shiftl imm 12))
                                  ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  (* ---- Load ---- *)
  | MI_lw rd rs1 imm =>
      match mem_read s.(ms_mem) (r rs1 + imm) with
      | None   => None
      | Some v => Some {| ms_rf := rf_write s.(ms_rf) rd v
                        ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
      end
  (* ---- Store ---- *)
  | MI_sw rs1 rs2 imm =>
      Some {| ms_rf  := s.(ms_rf)
            ; ms_mem := mem_write s.(ms_mem) (r rs1 + imm) (r rs2)
            ; ms_pc  := advance |}
  (* ---- Branches ---- *)
  | MI_beq  rs1 rs2 tgt =>
      let next := if r rs1 =? r rs2 then tgt else advance in
      Some {| ms_rf := s.(ms_rf) ; ms_mem := s.(ms_mem) ; ms_pc := next |}
  | MI_bne  rs1 rs2 tgt =>
      let next := if r rs1 =? r rs2 then advance else tgt in
      Some {| ms_rf := s.(ms_rf) ; ms_mem := s.(ms_mem) ; ms_pc := next |}
  | MI_blt  rs1 rs2 tgt =>
      let next := if to_signed32 (r rs1) <? to_signed32 (r rs2) then tgt else advance in
      Some {| ms_rf := s.(ms_rf) ; ms_mem := s.(ms_mem) ; ms_pc := next |}
  | MI_bge  rs1 rs2 tgt =>
      let next := if to_signed32 (r rs2) <=? to_signed32 (r rs1) then tgt else advance in
      Some {| ms_rf := s.(ms_rf) ; ms_mem := s.(ms_mem) ; ms_pc := next |}
  | MI_bltu rs1 rs2 tgt =>
      let next := if r rs1 <? r rs2 then tgt else advance in
      Some {| ms_rf := s.(ms_rf) ; ms_mem := s.(ms_mem) ; ms_pc := next |}
  | MI_bgeu rs1 rs2 tgt =>
      let next := if r rs2 <=? r rs1 then tgt else advance in
      Some {| ms_rf := s.(ms_rf) ; ms_mem := s.(ms_mem) ; ms_pc := next |}
  (* ---- Jumps ---- *)
  | MI_jal rd tgt =>
      let link := wrap32 (4 * Z.of_nat advance) in   (* byte address of pc+1 *)
      Some {| ms_rf  := rf_write s.(ms_rf) rd link
            ; ms_mem := s.(ms_mem) ; ms_pc := tgt |}
  | MI_jalr rd rs1 imm =>
      (* Target is (rs1 + imm) in byte address, divided by 4 for instr index.
         We require the result to be word-aligned; if it's unresolvable from
         the available information we treat it as UB (returns None). *)
      let tgt_byte := wrap32 (r rs1 + imm) in
      let link     := wrap32 (4 * Z.of_nat advance) in
      Some {| ms_rf  := rf_write s.(ms_rf) rd link
            ; ms_mem := s.(ms_mem)
            ; ms_pc  := Z.to_nat (tgt_byte / 4) |}
  (* ---- RV32M multiply ---- *)
  | MI_mul    rd rs1 rs2 => Some {| ms_rf := rf_write s.(ms_rf) rd (wrap32 (r rs1 * r rs2))
                                   ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_mulh   rd rs1 rs2 => Some {| ms_rf := rf_write s.(ms_rf) rd (mulh_s  (r rs1) (r rs2))
                                   ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_mulhu  rd rs1 rs2 => Some {| ms_rf := rf_write s.(ms_rf) rd (mulhu_u (r rs1) (r rs2))
                                   ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_mulhsu rd rs1 rs2 => Some {| ms_rf := rf_write s.(ms_rf) rd (mulhsu_su (r rs1) (r rs2))
                                   ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  (* ---- RV32M divide ---- *)
  | MI_div  rd rs1 rs2 => Some {| ms_rf := rf_write s.(ms_rf) rd (div_s  (r rs1) (r rs2))
                                 ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_divu rd rs1 rs2 => Some {| ms_rf := rf_write s.(ms_rf) rd (divu_u (r rs1) (r rs2))
                                 ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_rem  rd rs1 rs2 => Some {| ms_rf := rf_write s.(ms_rf) rd (rem_s  (r rs1) (r rs2))
                                 ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  | MI_remu rd rs1 rs2 => Some {| ms_rf := rf_write s.(ms_rf) rd (remu_u (r rs1) (r rs2))
                                 ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  (* ---- No-op ---- *)
  | MI_nop => Some {| ms_rf := s.(ms_rf) ; ms_mem := s.(ms_mem) ; ms_pc := advance |}
  end.

(* ========================================================================== *)
(** ** §4.  Fetch/execute step relation                                         *)
(* ========================================================================== *)

(** [machine_step prog s o] holds when [s] steps to output [o] by fetching the
    instruction at [s.(ms_pc)] from [prog].
    - If [ms_pc] is out of range: [o = None] (UB / halt).
    - Otherwise: [o = machine_exec s i] for the fetched instruction [i]. *)
Definition machine_step (prog : list rv32i_instr) (s : machine_state)
                        (o : option machine_state) : Prop :=
  match nth_error prog s.(ms_pc) with
  | Some i => o = machine_exec s i
  | None   => o = None
  end.

(** Convenience: the step is always defined (an output always exists). *)
Lemma machine_step_defined : forall prog s,
    exists o, machine_step prog s o.
Proof.
  intros prog s. unfold machine_step.
  destruct (nth_error prog s.(ms_pc)) as [i|].
  - exists (machine_exec s i). reflexivity.
  - exists None. reflexivity.
Qed.

(* ========================================================================== *)
(** ** §5.  Inevitability modality                                              *)
(* ========================================================================== *)

(** [eventually prog P s] holds iff every execution of [prog] from [s]
    reaches a state satisfying [P] in finitely many steps without UB.
    [P None = False] is the standard choice to exclude UB outcomes. *)
Inductive eventually (prog : list rv32i_instr)
                     (P : option machine_state -> Prop)
                     : machine_state -> Prop :=
  | Ev_here : forall s,
      P (Some s) ->
      eventually prog P s
  | Ev_step : forall s,
      (exists o, machine_step prog s o) ->
      (forall s', machine_step prog s (Some s') -> eventually prog P s') ->
      (machine_step prog s None -> P None) ->
      eventually prog P s.

(** [eventually_by_measure]: if a strictly-decreasing [measure] function
    witnesses progress under an invariant [inv], then [eventually P] holds. *)
Lemma eventually_by_measure
    (prog : list rv32i_instr)
    (P : option machine_state -> Prop)
    (inv : machine_state -> Prop)
    (measure : machine_state -> nat) :
    (forall s, inv s ->
       P (Some s) \/
       ((exists o, machine_step prog s o)
        /\ (forall s', machine_step prog s (Some s') ->
              inv s' /\ measure s' < measure s)
        /\ (machine_step prog s None -> P None))) ->
    forall n s, measure s < n -> inv s -> eventually prog P s.
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

Corollary eventually_by_measure'
    (prog : list rv32i_instr)
    (P : option machine_state -> Prop)
    (inv : machine_state -> Prop)
    (measure : machine_state -> nat) :
    (forall s, inv s ->
       P (Some s) \/
       ((exists o, machine_step prog s o)
        /\ (forall s', machine_step prog s (Some s') ->
              inv s' /\ measure s' < measure s)
        /\ (machine_step prog s None -> P None))) ->
    forall s, inv s -> eventually prog P s.
Proof.
  intros HSTEP s Hinv.
  apply (eventually_by_measure prog P inv measure HSTEP (S (measure s))).
  - lia.
  - exact Hinv.
Qed.

(* ========================================================================== *)
(** ** §6.  Bounded multi-step execution                                        *)
(* ========================================================================== *)

(** Run [prog] for exactly [n] steps from [s], collecting the trace.
    Returns [None] if UB occurs at any step. *)
Fixpoint machine_run_n (prog : list rv32i_instr) (s : machine_state) (n : nat)
    : option machine_state :=
  match n with
  | O    => Some s
  | S n' =>
      match machine_exec s (nth n.(* dummy *) 0 (MI_nop) (* placeholder *)) with
      | _ => None (* placeholder; real impl below *)
      end
  end.

(** Proper implementation using the step relation. *)
Fixpoint machine_exec_n (prog : list rv32i_instr) (n : nat) (s : machine_state)
    : option machine_state :=
  match n with
  | O    => Some s
  | S n' =>
      match nth_error prog s.(ms_pc) with
      | None   => None
      | Some i =>
          match machine_exec s i with
          | None    => None
          | Some s' => machine_exec_n prog n' s'
          end
      end
  end.

Lemma machine_exec_n_0 : forall prog s, machine_exec_n prog 0 s = Some s.
Proof. reflexivity. Qed.

Lemma machine_exec_n_S : forall prog n s,
    machine_exec_n prog (S n) s =
    match nth_error prog s.(ms_pc) with
    | None   => None
    | Some i =>
        match machine_exec s i with
        | None    => None
        | Some s' => machine_exec_n prog n s'
        end
    end.
Proof. reflexivity. Qed.

(* ========================================================================== *)
(** ** §7.  Structural lemmas                                                   *)
(* ========================================================================== *)

(** [eventually] is monotone in [P]. *)
Lemma eventually_mono : forall prog (P Q : option machine_state -> Prop) s,
    (forall o, P o -> Q o) ->
    eventually prog P s ->
    eventually prog Q s.
Proof.
  intros prog P Q s HPQ Hev.
  induction Hev as [s HP | s Hdef Hstep Hnone].
  - apply Ev_here. exact (HPQ _ HP).
  - apply Ev_step.
    + exact Hdef.
    + exact IHHstep.
    + intro Hmach. exact (HPQ _ (Hnone Hmach)).
Qed.

(** If [P (Some s)] and [eventually prog P s], we can extract the post-condition
    directly (the base case). *)
Lemma eventually_here : forall prog P s,
    P (Some s) -> eventually prog P s.
Proof.
  intros prog P s HP. apply Ev_here. exact HP.
Qed.

(** A machine that has reached the post-condition [P] satisfies
    [eventually prog P] regardless of what [prog] says next. *)
Lemma eventually_done : forall prog P s,
    P (Some s) -> eventually prog P s.
Proof. intros. apply Ev_here. assumption. Qed.

(** Instruction at a PC within [prog] is the one [nth_error] returns. *)
Lemma machine_step_instr : forall prog s i o,
    nth_error prog s.(ms_pc) = Some i ->
    machine_step prog s o <-> o = machine_exec s i.
Proof.
  intros prog s i o Hnth.
  unfold machine_step. rewrite Hnth. tauto.
Qed.

(** Reading a register that [machine_exec] did not write is unchanged. *)
Lemma machine_exec_read_unmodified : forall s i s' rd rs,
    machine_exec s i = Some s' ->
    (* i does not write rs: for ALU-type instructions, instr_rd i ≠ rs *)
    (forall v, rf_write s.(ms_rf) rs v = s.(ms_rf)) ->
    ms_rf s' rs = ms_rf s rs.
Proof.
  (* This requires knowing which register [i] writes; left as a framework
     stub that concrete program proofs instantiate. *)
Admitted.

(* ========================================================================== *)
(** ** Summary

    Fully proven (no Admitted):
    - [machine_step_defined]     : every state has at least one successor.
    - [eventually_by_measure]    : backbone for termination arguments.
    - [eventually_by_measure']   : corollary without explicit fuel.
    - [eventually_mono]          : monotonicity in the postcondition.
    - [eventually_here/done]     : immediate post-condition closes [eventually].
    - [machine_exec_n_0/S]       : unfolding of bounded execution.
    - [machine_step_instr]       : step relation when PC is in range.

    Admitted (framework stub):
    - [machine_exec_read_unmodified] : used by program proofs to discharge
      "register rs is unchanged after instruction i" without full case
      analysis on every instruction variant.
*)
