(* verification/formal/koika/FluxProc.v
 *
 * The FluxCore processor-module INTERFACE — shared by the ISA specification
 * machine (Spec/FluxProcSpec.v) and the Kôika implementation machine
 * (Impl/FluxProcImpl.v), so that `refines FluxCoreImpl ISASpec` is a statement
 * between two Sem.t of this one interface.
 *
 * The machine is transactional: the environment supplies each instruction
 * (as a decoded control word) through the `step` action method, and observes
 * the architectural state through the `getPc` / `getReg` / `getMem` value
 * methods.  The refinement therefore quantifies over ALL instruction streams.
 *
 * Instruction classes (v2 — the FluxCore integer ISA):
 *   ALU / ALU-imm  : the 15 proven ALU/XFlux ops (XCLZ has no verified
 *                    circuit yet; its opcode is not decodable)
 *   BR             : BEQ/BNE/BLT/BGE/BLTU/BGEU, pc-relative
 *   JAL / JALR     : jumps with link (JALR target has bit 0 cleared, §2.5)
 *   LUI / AUIPC    : upper immediates
 *   LW / SW        : word loads/stores (address aligned to 4)
 *   MUL            : MUL / MULH / MULHSU / MULHU (RV32M multiply family)
 *
 * Not modeled (documented scope): DIV/REM (needs a verified iterative divider
 * — no Kôika division primitive), the F extension (Flocq project), CSRs/traps.
 *
 * Control word (55 bits, LSB first):
 *   [0..4)   class — 4-bit instruction class, see decode_class
 *   [4..8)   op    — 4-bit sub-opcode (ALU op / branch cond / mul variant)
 *   [8..13)  rd    — destination register
 *   [13..18) rs1   — source register 1
 *   [18..23) rs2   — source register 2
 *   [23..55) imm   — 32-bit immediate (already assembled/shifted by decode)
 *)

From Koika Require Import Prelude.
From Flux Require Import FluxCommon.
From Flux Require Import Spec.FluxAlu.
From Flux Require Import Spec.FluxBranch.

#[local] Set Default Timeout 120.

Variant vmet_t :=
  | getPc
  | getReg
  | getMem
.

Variant amet_t :=
  | step
.

Definition CtrlSz := 55.

Definition getPc_sig : Methods.sig :=
  {| Methods.a := []; Methods.r := 32 |}.
Definition getReg_sig : Methods.sig :=
  {| Methods.a := [5]; Methods.r := 32 |}.
Definition getMem_sig : Methods.sig :=
  {| Methods.a := [32]; Methods.r := 32 |}.
Definition step_sig : Methods.sig :=
  {| Methods.a := [CtrlSz]; Methods.r := 0 |}.

#[export] Instance VMets : Methods.t vmet_t :=
{|
  Methods.met_list := [getPc; getReg; getMem];
  Methods.get_sig met :=
    match met with
    | getPc => getPc_sig
    | getReg => getReg_sig
    | getMem => getMem_sig
    end;
  Methods.get_name met :=
    match met with
    | getPc => "getPc"
    | getReg => "getReg"
    | getMem => "getMem"
    end;
|}.

#[export] Instance AMets : Methods.t amet_t :=
{|
  Methods.met_list := [step];
  Methods.get_sig met :=
    match met with
    | step => step_sig
    end;
  Methods.get_name met :=
    match met with
    | step => "step"
    end;
|}.

Definition ifc : Modules.interface := Modules.mkInterface _ _ VMets AMets.

(* ---- control-word fields (pure bit functions, used by BOTH machines) ---- *)

Definition ctrl_class (c : bits CtrlSz) : bits 4 := Bits.slice 0  4  c.
Definition ctrl_op    (c : bits CtrlSz) : bits 4 := Bits.slice 4  4  c.
Definition ctrl_rd    (c : bits CtrlSz) : RegIdx := Bits.slice 8  5  c.
Definition ctrl_rs1   (c : bits CtrlSz) : RegIdx := Bits.slice 13 5  c.
Definition ctrl_rs2   (c : bits CtrlSz) : RegIdx := Bits.slice 18 5  c.
Definition ctrl_imm   (c : bits CtrlSz) : Word   := Bits.slice 23 32 c.

(* ---- shared architectural constants / helpers ---- *)

(* pc + 4 *)
Definition plus4 (p : Word) : Word := Bits.plus p (Bits.of_nat 32 4).

(* JALR target mask: clear bit 0 (RV32I §2.5). *)
Definition maskJalr : Word := Bits.of_N 32 0xFFFFFFFE%N.

(* Word-aligned address: clear bits [1:0]. *)
Definition maskAlign : Word := Bits.of_N 32 0xFFFFFFFC%N.
Definition align4 (a : Word) : Word := Bits.and a maskAlign.

(* ---- sub-word memory access helpers (shared by spec and impl proofs) ----
   The memory is word-granular; byte/halfword accesses read-modify-write the
   aligned word, selected by the low address bits (the lane). *)

Definition sext8  (b : bits 8)  : Word := Bits.extend_end b 32 (Bits.msb b).
Definition zext8  (b : bits 8)  : Word := Bits.extend_end b 32 false.
Definition sext16 (h : bits 16) : Word := Bits.extend_end h 32 (Bits.msb h).
Definition zext16 (h : bits 16) : Word := Bits.extend_end h 32 false.

Definition load_byte (w : Word) (lane : bits 2) : bits 8 :=
  match Bits.to_nat lane with
  | 0 => Bits.slice 0  8 w
  | 1 => Bits.slice 8  8 w
  | 2 => Bits.slice 16 8 w
  | _ => Bits.slice 24 8 w
  end.

Definition load_half (w : Word) (lane : bits 1) : bits 16 :=
  match Bits.to_nat lane with
  | 0 => Bits.slice 0  16 w
  | _ => Bits.slice 16 16 w
  end.

Definition store_byte (w : Word) (lane : bits 2) (v : bits 8) : Word :=
  match Bits.to_nat lane with
  | 0 => Bits.slice_subst 0  8 w v
  | 1 => Bits.slice_subst 8  8 w v
  | 2 => Bits.slice_subst 16 8 w v
  | _ => Bits.slice_subst 24 8 w v
  end.

Definition store_half (w : Word) (lane : bits 1) (v : bits 16) : Word :=
  match Bits.to_nat lane with
  | 0 => Bits.slice_subst 0  16 w v
  | _ => Bits.slice_subst 16 16 w v
  end.

(* ---- instruction classes ---- *)

Variant iclass :=
  | CL_ALU | CL_ALUI
  | CL_BR
  | CL_JAL | CL_JALR
  | CL_LUI | CL_AUIPC
  | CL_LW  | CL_SW
  | CL_MUL
  | CL_LB  | CL_LBU
  | CL_LH  | CL_LHU
  | CL_SB  | CL_SH
.

(* Total: all 16 class codes decode. *)
Definition decode_class (b : bits 4) : option iclass :=
  match Bits.to_nat b with
  | 0 => Some CL_ALU
  | 1 => Some CL_ALUI
  | 2 => Some CL_BR
  | 3 => Some CL_JAL
  | 4 => Some CL_JALR
  | 5 => Some CL_LUI
  | 6 => Some CL_AUIPC
  | 7 => Some CL_LW
  | 8 => Some CL_SW
  | 9 => Some CL_MUL
  | 10 => Some CL_LB
  | 11 => Some CL_LBU
  | 12 => Some CL_LH
  | 13 => Some CL_LHU
  | 14 => Some CL_SB
  | 15 => Some CL_SH
  | _ => None
  end.

(* The ALU opcode map: the 15 ops with proven Kôika datapath circuits.
   Code 15 (XCLZ) has no verified circuit yet and is not decodable. *)
Definition decode_op (b : bits 4) : option alu_op :=
  match Bits.to_nat b with
  | 0  => Some ALU_AND
  | 1  => Some ALU_OR
  | 2  => Some ALU_XOR
  | 3  => Some ALU_ADD
  | 4  => Some ALU_SUB
  | 5  => Some ALU_COPY_B
  | 6  => Some ALU_SLL
  | 7  => Some ALU_SRL
  | 8  => Some ALU_SRA
  | 9  => Some ALU_SLT
  | 10 => Some ALU_SLTU
  | 11 => Some ALU_XMIN
  | 12 => Some ALU_XMAX
  | 13 => Some ALU_XLIDX
  | 14 => Some ALU_XABS
  | _  => None
  end.

(* Branch condition map (Spec/FluxBranch.v). *)
Definition decode_br (b : bits 4) : option branch_op :=
  match Bits.to_nat b with
  | 0 => Some BR_EQ
  | 1 => Some BR_NE
  | 2 => Some BR_LT
  | 3 => Some BR_GE
  | 4 => Some BR_LTU
  | 5 => Some BR_GEU
  | _ => None
  end.

(* RV32M multiply variants. *)
Variant mul_op :=
  | M_LO   (* MUL    *)
  | M_HI   (* MULH   *)
  | M_HISU (* MULHSU *)
  | M_HIU  (* MULHU  *)
.

Definition decode_mop (b : bits 4) : option mul_op :=
  match Bits.to_nat b with
  | 0 => Some M_LO
  | 1 => Some M_HI
  | 2 => Some M_HISU
  | 3 => Some M_HIU
  | _ => None
  end.
