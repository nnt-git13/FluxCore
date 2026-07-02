(** * FluxCoreISA.v

    Functional ISA specification for FluxCore (RV32I + RV32M + XFlux subset).

    This file is the authoritative architectural reference model against which
    the RTL pipeline is verified.  It captures exactly what the RISC-V spec
    says each instruction does, without any pipeline implementation details.

    Scope in this file:
    - [alu_op]     : enumeration of ALU operations (RV32I base, RV32M multiply,
                     and XFlux custom operations covered here as ALU-class).
    - [alu_eval]   : purely functional evaluation of each ALU operation.
    - [instr]      : instruction representation (R-type and I-type for now;
                     branches and memory are future work).
    - [isa_state]  : architectural visible state (register file + PC).
    - [isa_step]   : one-instruction ISA evaluation step.
    - [isa_run]    : iterated ISA step over a program list.

    Excluded from this file (future work):
    - Load/store memory operations.
    - Branch/JAL/JALR control flow.
    - CSR instructions.
    - RV32M division (requires multi-cycle stall reasoning).
*)

Require Import FluxCore.Common.Types.
From Stdlib Require Import ZArith.
From Stdlib Require Import Bool.
From Stdlib Require Import List.
Import ListNotations.
From Stdlib Require Import Lia.
Open Scope Z_scope.
Open Scope bool_scope.

(* ========================================================================== *)
(** ** ALU operations                                                          *)
(* ========================================================================== *)

Inductive alu_op : Type :=
  (* RV32I R-type and I-type *)
  | ALU_ADD
  | ALU_SUB
  | ALU_AND
  | ALU_OR
  | ALU_XOR
  | ALU_SLL    (** logical shift left  *)
  | ALU_SRL    (** logical shift right *)
  | ALU_SRA    (** arithmetic shift right *)
  | ALU_SLT    (** signed less-than comparison *)
  | ALU_SLTU   (** unsigned less-than comparison *)
  | ALU_COPY_B (** used for LUI: output = b *)
  (* XFlux custom extensions (CUSTOM_0 opcode) *)
  | ALU_XABS   (** signed absolute value of a *)
  | ALU_XMIN   (** signed minimum of a and b *)
  | ALU_XMAX   (** signed maximum of a and b *)
  | ALU_XCLZ   (** count leading zeros of a (32-bit) *).

(** Evaluate [op] on 32-bit operands [a] and [b].

    All inputs and outputs are treated as elements of [[0, 2^32)].
    Signed operations interpret the inputs via [to_signed32] before
    comparison but still return a value in [[0, 2^32)]. *)
Definition alu_eval (op : alu_op) (a b : Z) : Z :=
  match op with
  | ALU_ADD    => wrap32 (a + b)
  | ALU_SUB    => wrap32 (a - b)
  | ALU_AND    => Z.land a b
  | ALU_OR     => Z.lor  a b
  | ALU_XOR    => Z.lxor a b
  | ALU_SLL    => wrap32 (Z.shiftl a (shamt b))
  | ALU_SRL    => Z.shiftr a (shamt b)
  | ALU_SRA    => wrap32 (Z.shiftr (to_signed32 a) (shamt b))
  | ALU_SLT    => if to_signed32 a <? to_signed32 b then 1 else 0
  | ALU_SLTU   => if a <? b then 1 else 0
  | ALU_COPY_B => b
  | ALU_XABS   => if a <? 0 then wrap32 (Z.opp a) else a
  | ALU_XMIN   => if to_signed32 a <? to_signed32 b then a else b
  | ALU_XMAX   => if to_signed32 a >? to_signed32 b then a else b
  | ALU_XCLZ   =>
      (* Count leading zeros: scan from bit 31 down to bit 0.
         clz(0) = 32; clz(x) = position of highest set bit subtracted from 31. *)
      let fix clz_inner (k : nat) (v : Z) : Z :=
        match k with
        | O    => if Z.testbit v 0 then 0 else 1
        | S k' => if Z.testbit v (Z.of_nat (S k'))
                  then (31 - Z.of_nat (S k'))
                  else clz_inner k' v
        end
      in clz_inner 31%nat a
  end.

(* ========================================================================== *)
(** ** Instruction representation                                              *)
(* ========================================================================== *)

(** Abstract instruction set.  Register indices and immediates are [Z] values
    that have already been decoded from the 32-bit encoding. *)
Inductive instr : Type :=
  (** R-type: rd := op(rs1, rs2) *)
  | Ialu_rr  (op : alu_op) (rd rs1 rs2 : Z)
  (** I-type: rd := op(rs1, imm) — covers OP_IMM group and LUI (via COPY_B) *)
  | Ialu_ri  (op : alu_op) (rd rs1 : Z) (imm : Z)
  (** No-operation: rd = x0 write, no effect *)
  | Inop.

(* ========================================================================== *)
(** ** ISA state and step function                                             *)
(* ========================================================================== *)

Record isa_state : Type := mk_isa_state
  { isa_rf : regfile
  ; isa_pc : Z
  }.

Definition isa_init : isa_state :=
  {| isa_rf := rf_init ; isa_pc := 0 |}.

(** Execute one instruction, returning the new architectural state. *)
Definition isa_step (s : isa_state) (i : instr) : isa_state :=
  match i with
  | Ialu_rr op rd rs1 rs2 =>
      let a      := rf_read s.(isa_rf) rs1 in
      let b      := rf_read s.(isa_rf) rs2 in
      let result := alu_eval op a b in
      {| isa_rf := rf_write s.(isa_rf) rd result
       ; isa_pc := s.(isa_pc) + 4 |}
  | Ialu_ri op rd rs1 imm =>
      let a      := rf_read s.(isa_rf) rs1 in
      let result := alu_eval op a imm in
      {| isa_rf := rf_write s.(isa_rf) rd result
       ; isa_pc := s.(isa_pc) + 4 |}
  | Inop =>
      {| isa_rf := s.(isa_rf)
       ; isa_pc := s.(isa_pc) + 4 |}
  end.

(** Run a list of instructions in program order, starting from [s]. *)
Fixpoint isa_run (s : isa_state) (prog : list instr) : isa_state :=
  match prog with
  | nil    => s
  | i :: t => isa_run (isa_step s i) t
  end.

(* ========================================================================== *)
(** ** Basic ISA lemmas                                                        *)
(* ========================================================================== *)

(** [isa_run] distributes over list append. *)
Lemma isa_run_app : forall s p1 p2,
    isa_run s (p1 ++ p2) = isa_run (isa_run s p1) p2.
Proof.
  intros s p1. revert s.
  induction p1 as [| h t IH]; intros s p2; simpl.
  - reflexivity.
  - apply IH.
Qed.

(** Single-step unfolding: [isa_run s [i] = isa_step s i]. *)
Lemma isa_run_singleton : forall s i,
    isa_run s [i] = isa_step s i.
Proof. intros. simpl. reflexivity. Qed.

(** Nop does not change the register file. *)
Lemma isa_nop_rf_unchanged : forall s,
    (isa_step s Inop).(isa_rf) = s.(isa_rf).
Proof. intro s. simpl. reflexivity. Qed.

(** An R-type instruction that writes x0 does not change the register file. *)
Lemma isa_rr_x0_rd_unchanged : forall s op rs1 rs2,
    (isa_step s (Ialu_rr op 0 rs1 rs2)).(isa_rf) = s.(isa_rf).
Proof.
  intros s op rs1 rs2. simpl.
  unfold rf_write. reflexivity.
Qed.

(** An I-type instruction that writes x0 does not change the register file. *)
Lemma isa_ri_x0_rd_unchanged : forall s op rs1 imm,
    (isa_step s (Ialu_ri op 0 rs1 imm)).(isa_rf) = s.(isa_rf).
Proof.
  intros s op rs1 imm. simpl.
  unfold rf_write. reflexivity.
Qed.

(** The result of an R-type instruction is [alu_eval op (rs1-value) (rs2-value)]. *)
Lemma isa_rr_result : forall s op rd rs1 rs2,
    rd <> 0 ->
    rf_read (isa_step s (Ialu_rr op rd rs1 rs2)).(isa_rf) rd =
    alu_eval op (rf_read s.(isa_rf) rs1) (rf_read s.(isa_rf) rs2).
Proof.
  intros s op rd rs1 rs2 Hrd. simpl.
  apply rf_write_read_same. exact Hrd.
Qed.

(** If two consecutive R-type instructions write to different registers,
    each write is visible independently. *)
Lemma isa_rr_independent : forall s (op1 : alu_op) (rd1 rs1a rs1b : Z)
                                     (op2 : alu_op) (rd2 rs2a rs2b : Z),
    rd1 <> 0 -> rd2 <> 0 -> rd1 <> rd2 ->
    let s1 := isa_step s (Ialu_rr op1 rd1 rs1a rs1b) in
    rf_read s1.(isa_rf) rd1 =
    alu_eval op1 (rf_read s.(isa_rf) rs1a) (rf_read s.(isa_rf) rs1b).
Proof.
  intros s op1 rd1 rs1a rs1b op2 rd2 rs2a rs2b Hrd1 Hrd2 Hne s1.
  apply isa_rr_result. exact Hrd1.
Qed.
