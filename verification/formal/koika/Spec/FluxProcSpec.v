(* verification/formal/koika/Spec/FluxProcSpec.v
 *
 * ISASpec — the FluxCore ISA specification MACHINE, as a semantic object
 * (Sem.t FluxProc.ifc).  Architectural state is {pc, register file, memory};
 * one `step` retires one instruction atomically per `spec_next`:
 *
 *   ALU/ALUI : rd <- alu_spec op rf[rs1] (rf[rs2] | imm)      ; pc+4
 *   BR       : pc <- taken ? pc+imm : pc+4
 *   JAL      : rd <- pc+4                                     ; pc <- pc+imm
 *   JALR     : rd <- pc+4                    ; pc <- (rf[rs1]+imm) & ~1
 *   LUI      : rd <- imm                                      ; pc+4
 *   AUIPC    : rd <- pc+imm                                   ; pc+4
 *   LW       : rd <- mem[(rf[rs1]+imm) & ~3]                  ; pc+4
 *   SW       : mem[(rf[rs1]+imm) & ~3] <- rf[rs2]             ; pc+4
 *   MUL      : rd <- mul variant of rf[rs1], rf[rs2]          ; pc+4
 *
 * All rd writes go through rf_write0 (x0 hardwired to zero).  Undecodable
 * class/op words: spec_next = None and the method refuses — mirroring the
 * implementation's Rollback guard.
 *
 * This is the machine the Kôika implementation (Impl/FluxProcImpl.v) is
 * proven to refine: Refine/FluxProcRefine.v, `FluxCore_refines`.
 *)

From Koika Require Import Prelude.
From Flux Require Import FluxCommon.
From Flux Require Import Spec.FluxAlu.
From Flux Require Import Spec.FluxBranch.
From Flux Require Import Spec.FluxMul.
From Flux Require Import Spec.FluxIsa.
From Flux Require Import FluxMem.
From Flux Require Import FluxProc.

#[local] Set Default Timeout 120.

Record state_t := mkProcState {
  pc_s  : Word;
  rf_s  : RegState;
  mem_s : MemState;
}.

(* The RV32M multiply reference, by variant (Spec/FluxMul.v). *)
Definition mul_spec (m : mul_op) (a b : Word) : Word :=
  match m with
  | M_LO   => mul_lo a b
  | M_HI   => mul_hi a b
  | M_HISU => mul_hisu a b
  | M_HIU  => mul_hiu a b
  end.

(* One architectural step: Some next-state, or None (instruction refused). *)
Definition spec_next (c : bits CtrlSz) (st : state_t) : option state_t :=
  let rd  := ctrl_rd c in
  let a   := rf_s st (ctrl_rs1 c) in
  let b   := rf_s st (ctrl_rs2 c) in
  let imm := ctrl_imm c in
  match decode_class (ctrl_class c) with
  | Some CL_ALU =>
    match decode_op (ctrl_op c) with
    | Some o => Some {| pc_s := plus4 (pc_s st);
                        rf_s := rf_write0 (rf_s st) rd (alu_spec o a b);
                        mem_s := mem_s st |}
    | None => None
    end
  | Some CL_ALUI =>
    match decode_op (ctrl_op c) with
    | Some o => Some {| pc_s := plus4 (pc_s st);
                        rf_s := rf_write0 (rf_s st) rd (alu_spec o a imm);
                        mem_s := mem_s st |}
    | None => None
    end
  | Some CL_BR =>
    match decode_br (ctrl_op c) with
    | Some bo => Some {| pc_s := if branch_taken bo a b
                                 then Bits.plus (pc_s st) imm
                                 else plus4 (pc_s st);
                         rf_s := rf_s st;
                         mem_s := mem_s st |}
    | None => None
    end
  | Some CL_JAL =>
    Some {| pc_s := Bits.plus (pc_s st) imm;
            rf_s := rf_write0 (rf_s st) rd (plus4 (pc_s st));
            mem_s := mem_s st |}
  | Some CL_JALR =>
    Some {| pc_s := Bits.and (Bits.plus a imm) maskJalr;
            rf_s := rf_write0 (rf_s st) rd (plus4 (pc_s st));
            mem_s := mem_s st |}
  | Some CL_LUI =>
    Some {| pc_s := plus4 (pc_s st);
            rf_s := rf_write0 (rf_s st) rd imm;
            mem_s := mem_s st |}
  | Some CL_AUIPC =>
    Some {| pc_s := plus4 (pc_s st);
            rf_s := rf_write0 (rf_s st) rd (Bits.plus (pc_s st) imm);
            mem_s := mem_s st |}
  | Some CL_LW =>
    Some {| pc_s := plus4 (pc_s st);
            rf_s := rf_write0 (rf_s st) rd (mem_s st (align4 (Bits.plus a imm)));
            mem_s := mem_s st |}
  | Some CL_SW =>
    Some {| pc_s := plus4 (pc_s st);
            rf_s := rf_s st;
            mem_s := mem_upd (mem_s st) (align4 (Bits.plus a imm)) b |}
  | Some CL_MUL =>
    match decode_mop (ctrl_op c) with
    | Some m => Some {| pc_s := plus4 (pc_s st);
                        rf_s := rf_write0 (rf_s st) rd (mul_spec m a b);
                        mem_s := mem_s st |}
    | None => None
    end
  | Some CL_LB =>
    let ea := Bits.plus a imm in
    Some {| pc_s := plus4 (pc_s st);
            rf_s := rf_write0 (rf_s st) rd
                      (sext8 (load_byte (mem_s st (align4 ea))
                                        (Bits.slice 0 2 ea)));
            mem_s := mem_s st |}
  | Some CL_LBU =>
    let ea := Bits.plus a imm in
    Some {| pc_s := plus4 (pc_s st);
            rf_s := rf_write0 (rf_s st) rd
                      (zext8 (load_byte (mem_s st (align4 ea))
                                        (Bits.slice 0 2 ea)));
            mem_s := mem_s st |}
  | Some CL_LH =>
    let ea := Bits.plus a imm in
    Some {| pc_s := plus4 (pc_s st);
            rf_s := rf_write0 (rf_s st) rd
                      (sext16 (load_half (mem_s st (align4 ea))
                                         (Bits.slice 1 1 ea)));
            mem_s := mem_s st |}
  | Some CL_LHU =>
    let ea := Bits.plus a imm in
    Some {| pc_s := plus4 (pc_s st);
            rf_s := rf_write0 (rf_s st) rd
                      (zext16 (load_half (mem_s st (align4 ea))
                                         (Bits.slice 1 1 ea)));
            mem_s := mem_s st |}
  | Some CL_SB =>
    let ea := Bits.plus a imm in
    Some {| pc_s := plus4 (pc_s st);
            rf_s := rf_s st;
            mem_s := mem_upd (mem_s st) (align4 ea)
                       (store_byte (mem_s st (align4 ea))
                                   (Bits.slice 0 2 ea)
                                   (Bits.slice 0 8 b)) |}
  | Some CL_SH =>
    let ea := Bits.plus a imm in
    Some {| pc_s := plus4 (pc_s st);
            rf_s := rf_s st;
            mem_s := mem_upd (mem_s st) (align4 ea)
                       (store_half (mem_s st (align4 ea))
                                   (Bits.slice 1 1 ea)
                                   (Bits.slice 0 16 b)) |}
  | None => None
  end.

(* ---- the interface methods ---- *)

Definition getPc_spec : Sem.v getPc_sig state_t :=
  fun _args st ret => ret = pc_s st
.

Definition getReg_spec : Sem.v getReg_sig state_t :=
  fun args st ret => ret = rf_s st (chd args)
.

Definition getMem_spec : Sem.v getMem_sig state_t :=
  fun args st ret => ret = mem_s st (chd args)
.

Definition step_spec : Sem.a step_sig state_t :=
  fun args st _ret st' => spec_next (chd args) st = Some st'
.

Definition ISASpec : Sem.t FluxProc.ifc.
Proof.
  refine {|
    Sem.state_t := state_t;
    Sem.init    := {| pc_s := Bits.zero;
                      rf_s := fun _ => Bits.zero;
                      mem_s := fun _ => Bits.zero |};
    Sem.rules   := Rules.empty;
  |}.
  - destruct vmet.
    + exact getPc_spec.
    + exact getReg_spec.
    + exact getMem_spec.
  - destruct amet.
    + exact step_spec.
  - destruct 1.
Defined.

(* ISA-level x0 invariant: no step ever changes x0. *)
Theorem spec_next_preserves_x0 c st st' :
  spec_next c st = Some st' ->
  rf_s st' (Bits.zero : RegIdx) = rf_s st (Bits.zero : RegIdx).
Proof.
  unfold spec_next; cbn zeta.
  destruct (decode_class _) as [[]|]; try discriminate.
  all: try (destruct (decode_op _); [|discriminate]).
  all: try (destruct (decode_br _); [|discriminate]).
  all: try (destruct (decode_mop _); [|discriminate]).
  all: injection 1 as <-; cbn [rf_s]; auto using rf_write0_preserves_x0.
Qed.
