(** * FluxCorePipeline.v

    Abstract model of the FluxCore 5-stage pipeline for formal reasoning.

    This file captures the pipeline structure at a level of abstraction suitable
    for proving correctness without modeling every RTL register and mux.  The
    model is designed to match the RTL precisely for the ALU-only case:
    - [inflight_instr]   : record of one instruction in the EX/MEM or MEM/WB
                           pipeline register, carrying its pre-computed result.
    - [pipe_state]       : snapshot of the three stages that matter for
                           forwarding: EX, MEM, and WB, plus the committed RF.
    - [fwd_read]         : forwarding unit logic — returns the most-recently-
                           written value of a register across EX, MEM, and WB.
    - [pipe_exec]        : one pipeline step: issue one instruction in EX using
                           forwarded operands, advance MEM→WB and WB→RF.

    The model omits:
    - IF and ID stages (not relevant to forwarding correctness).
    - Load/store stalls (addressed separately in dcache verification).
    - Branch mispredictions (no branches in this model).
    - MUL/DIV long-latency stalls (future work).
    - CSR logic.

    Priority of forwarding in FluxCore (highest to lowest):
      1. EX/MEM register (instruction just finished EX, now in MEM).
      2. MEM/WB register (instruction in WB, about to retire).
      3. Committed register file (all retired instructions).
    If more than one stage writes the same register, the highest-priority (most
    recent) value is used.  This matches the RTL [forwarding_unit.sv].
*)

Require Import FluxCore.FluxCoreTypes.
Require Import FluxCore.FluxCoreISA.
From Stdlib Require Import ZArith.
From Stdlib Require Import Bool.
From Stdlib Require Import List.
Import ListNotations.
From Stdlib Require Import Lia.
Open Scope Z_scope.
Open Scope bool_scope.

(* ========================================================================== *)
(** ** In-flight instruction record                                            *)
(* ========================================================================== *)

(** Represents one instruction occupying a pipeline register (EX/MEM or MEM/WB).
    The [result] field holds the fully evaluated ALU result — computed when the
    instruction was in the EX stage.  This pre-computation mirrors what the RTL
    does: the ALU result is registered at the end of EX and carried forward. *)
Record inflight_instr : Type := mk_inflight
  { inf_valid  : bool   (** slot is occupied by a real instruction *)
  ; inf_rd_wen : bool   (** instruction writes [inf_rd] *)
  ; inf_rd     : Z      (** destination register index *)
  ; inf_result : Z      (** ALU result (valid when inf_valid && inf_rd_wen) *)
  }.

Definition inflight_nop : inflight_instr :=
  {| inf_valid := false ; inf_rd_wen := false ; inf_rd := 0 ; inf_result := 0 |}.

(* ========================================================================== *)
(** ** Pipeline snapshot                                                       *)
(* ========================================================================== *)

(** Snapshot of the pipeline state at the start of a cycle, from the
    forwarding unit's point of view.

    Nomenclature:
    - [ps_mem] = the EX/MEM register: instruction that just completed EX.
                 In FluxCore RTL this is [ex_mem_q].
    - [ps_wb]  = the MEM/WB register: instruction completing MEM.
                 In FluxCore RTL this is [mem_wb_q].
    - [ps_rf]  = committed register file: state after all retired instructions.

    Note: we name the slot after the *stage the instruction is currently
    processing* (MEM or WB), which is the convention in the forwarding unit. *)
Record pipe_state : Type := mk_pipe_state
  { ps_rf  : regfile            (** committed register file *)
  ; ps_mem : inflight_instr     (** instruction in MEM stage (EX/MEM register) *)
  ; ps_wb  : inflight_instr     (** instruction in WB  stage (MEM/WB register) *)
  }.

Definition pipe_init : pipe_state :=
  {| ps_rf  := rf_init
   ; ps_mem := inflight_nop
   ; ps_wb  := inflight_nop
   |}.

(* ========================================================================== *)
(** ** Forwarding unit                                                         *)
(* ========================================================================== *)

(** Return the current architectural value of register [rs], taking into
    account in-flight writes from MEM and WB stages.

    Priority (matches [forwarding_unit.sv]):
      1. MEM stage (most recent) — forward from [ps_mem].
      2. WB  stage              — forward from [ps_wb].
      3. Committed register file.

    x0 always returns 0 (enforced by [rf_read]). *)
Definition fwd_read (s : pipe_state) (rs : Z) : Z :=
  (* Priority 1: forward from MEM stage (EX/MEM register) *)
  if s.(ps_mem).(inf_valid)
       && s.(ps_mem).(inf_rd_wen)
       && (s.(ps_mem).(inf_rd) =? rs)
       && negb (rs =? 0)
  then s.(ps_mem).(inf_result)
  (* Priority 2: forward from WB stage (MEM/WB register) *)
  else if s.(ps_wb).(inf_valid)
            && s.(ps_wb).(inf_rd_wen)
            && (s.(ps_wb).(inf_rd) =? rs)
            && negb (rs =? 0)
  then s.(ps_wb).(inf_result)
  (* Priority 3: read from committed register file *)
  else rf_read s.(ps_rf) rs.

(* ========================================================================== *)
(** ** Pipeline step                                                           *)
(* ========================================================================== *)

(** Determine whether an instruction writes its destination register. *)
Definition instr_writes_rd (i : instr) : bool :=
  match i with
  | Ialu_rr _ rd _ _ => negb (rd =? 0)
  | Ialu_ri _ rd _ _ => negb (rd =? 0)
  | Inop              => false
  end.

(** Extract the destination register of an instruction (0 for Inop). *)
Definition instr_rd (i : instr) : Z :=
  match i with
  | Ialu_rr _ rd _ _ => rd
  | Ialu_ri _ rd _ _ => rd
  | Inop              => 0
  end.

(** Evaluate an instruction in EX using forwarded operand values.

    This mirrors the RTL execute_stage: the ALU runs combinationally in EX
    with operands supplied by the forwarding unit. *)
Definition eval_in_ex (s : pipe_state) (i : instr) : Z :=
  match i with
  | Ialu_rr op _ rs1 rs2 =>
      alu_eval op (fwd_read s rs1) (fwd_read s rs2)
  | Ialu_ri op _ rs1 imm =>
      alu_eval op (fwd_read s rs1) imm
  | Inop =>
      0
  end.

(** Advance the pipeline by one instruction.

    [pipe_exec s i] issues instruction [i] in EX, using [fwd_read] for operands.
    Simultaneously:
    - The instruction previously in MEM moves to WB.
    - The instruction previously in WB retires (its result is written to the RF).
    - The new instruction enters MEM (carrying its EX result).
*)
Definition pipe_exec (s : pipe_state) (i : instr) : pipe_state :=
  let new_mem_slot :=
    {| inf_valid  := true
     ; inf_rd_wen := instr_writes_rd i
     ; inf_rd     := instr_rd i
     ; inf_result := eval_in_ex s i
     |} in
  (* Retire the WB stage instruction into the register file *)
  let rf_after_wb :=
    if s.(ps_wb).(inf_valid) && s.(ps_wb).(inf_rd_wen)
    then rf_write s.(ps_rf) s.(ps_wb).(inf_rd) s.(ps_wb).(inf_result)
    else s.(ps_rf) in
  {| ps_rf  := rf_after_wb
   ; ps_mem := new_mem_slot
   ; ps_wb  := s.(ps_mem)      (* MEM → WB *)
   |}.

(** Run a program through the pipeline for [n] steps starting from [s].
    After all instructions have issued, the pipeline must drain; here we
    drain by issuing [Inop] instructions, matching the testbench NOP drain. *)
Fixpoint pipe_run (s : pipe_state) (prog : list instr) : pipe_state :=
  match prog with
  | nil    => s
  | i :: t => pipe_run (pipe_exec s i) t
  end.

(** Drain: advance the pipeline two more cycles (to flush the MEM and WB
    stages) after all real instructions have issued. *)
Definition pipe_drain (s : pipe_state) : pipe_state :=
  pipe_exec (pipe_exec s Inop) Inop.

(** Full pipeline execution: issue all instructions then drain. *)
Definition pipe_exec_full (s : pipe_state) (prog : list instr) : pipe_state :=
  pipe_drain (pipe_run s prog).

(* ========================================================================== *)
(** ** Basic pipeline lemmas                                                   *)
(* ========================================================================== *)

(** [pipe_run] distributes over append. *)
Lemma pipe_run_app : forall s p1 p2,
    pipe_run s (p1 ++ p2) = pipe_run (pipe_run s p1) p2.
Proof.
  intros s p1. revert s.
  induction p1 as [| h t IH]; intros s p2; simpl.
  - reflexivity.
  - apply IH.
Qed.

(** When no stage has a valid writeback-pending instruction, the RF is
    unchanged by [pipe_exec]. *)
Lemma pipe_exec_rf_stable : forall s i,
    s.(ps_wb).(inf_valid) = false ->
    (pipe_exec s i).(ps_rf) = s.(ps_rf).
Proof.
  intros s i Hwb.
  unfold pipe_exec. simpl.
  rewrite Hwb. simpl. reflexivity.
Qed.
