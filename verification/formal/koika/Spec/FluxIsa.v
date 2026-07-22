(* verification/formal/koika/Spec/FluxIsa.v
 *
 * Architectural (ISA-level) reference for the register-writing effect of one
 * ALU / XFlux instruction.  This is the sequential semantics the pipelined
 * Kôika core must refine at the top level (see Refine/Top.v): a single
 * instruction atomically reads its sources and writes rd.
 *
 * The full ISA step (all instruction classes, PC, memory, CSRs, the F
 * extension via Flocq) is the remaining work catalogued in Refine/Top.v; this
 * file pins the ALU/XFlux writeback, which composes with the proven datapath
 * refinement in Refine/FluxAluRefine.v.
 *)

From Koika Require Import Prelude.
From Flux Require Import FluxCommon.
From Flux Require Import Spec.FluxAlu.

#[local] Set Default Timeout 60.

(* Architectural integer register file: a map from 5-bit index to word. *)
Definition RegState := RegIdx -> Word.

Definition rf_read (rf : RegState) (i : RegIdx) : Word := rf i.

Definition rf_write (rf : RegState) (i : RegIdx) (v : Word) : RegState :=
  fun j => if eq_dec i j then v else rf j.

(* RISC-V register write: x0 is hardwired to zero, so a write to index 0 is
   discarded (RV32I §2.1).  This is the write the ISA machine (FluxProcSpec)
   uses. *)
Definition rf_write0 (rf : RegState) (i : RegIdx) (v : Word) : RegState :=
  if eq_dec i (Bits.zero : RegIdx) then rf else rf_write rf i v.

(* rf_write0 never disturbs x0: starting from an all-zero-x0 file, x0 stays 0
   forever — the ISA-level x0 invariant. *)
Theorem rf_write0_preserves_x0 : forall rf i v,
  rf_write0 rf i v (Bits.zero : RegIdx) = rf (Bits.zero : RegIdx).
Proof.
  intros. unfold rf_write0, rf_write.
  destruct (eq_dec i (Bits.zero : RegIdx)) as [-> | NE]; [reflexivity|].
  destruct (eq_dec i (Bits.zero : RegIdx)) as [E | _]; [contradiction|].
  reflexivity.
Qed.

(* The ISA effect of a register-register ALU/XFlux instruction:
   rd <- alu_spec op (rf[rs1]) (rf[rs2]).  x0 stays zero is handled by the
   register-file module refinement, not here. *)
Definition arch_step_alu (rf : RegState) (op : alu_op) (rd rs1 rs2 : RegIdx)
  : RegState :=
  rf_write rf rd (alu_spec op (rf_read rf rs1) (rf_read rf rs2)).

(* Reading back the just-written destination yields the ALU result. *)
Theorem arch_step_alu_writes_rd : forall rf op rd rs1 rs2,
  rf_read (arch_step_alu rf op rd rs1 rs2) rd
  = alu_spec op (rf_read rf rs1) (rf_read rf rs2).
Proof.
  intros. unfold arch_step_alu, rf_read, rf_write.
  destruct (eq_dec rd rd) as [ | Hne]; [reflexivity | now contradiction Hne].
Qed.
