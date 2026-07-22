(* verification/formal/koika/Spec/FluxAlu.v
 *
 * Reference semantics for the FluxCore integer ALU and the custom XFlux
 * operations — the "what the datapath is supposed to compute", written as pure
 * Rocq functions over machine words.  This is the Spec half of the Path-A
 * refinement: the Kôika ALU (Impl/FluxAluImpl.v) is proven to compute exactly
 * this function (Refine/FluxAluRefine.v).
 *
 * The op set mirrors alu_op_e in rtl/common/rv32_isa_pkg.sv.  The XFlux ops are
 * FluxCore's own extension, so their semantics are defined here and their
 * intended algebraic properties are proven below.
 *)

From Koika Require Import Prelude.
From Flux Require Import FluxCommon.

(* Koika's Prelude sets a 2s tactic timeout; a few of these reductions need more. *)
#[local] Set Default Timeout 60.

(* ALU operation selector — subset of alu_op_e handled by the combinational ALU
   (the RV32M multiply/divide ops are a separate unit). *)
Inductive alu_op :=
| ALU_ADD | ALU_SUB | ALU_AND | ALU_OR  | ALU_XOR
| ALU_SLL | ALU_SRL | ALU_SRA | ALU_SLT | ALU_SLTU | ALU_COPY_B
| ALU_XABS | ALU_XMIN | ALU_XMAX | ALU_XCLZ | ALU_XLIDX.

(* Shift amount is the low 5 bits of operand b (RV32 semantics). *)
Definition shamt (b : Word) : nat := Bits.to_nat (Bits.slice 0 5 b).

(* Count leading zeros of a 32-bit word: 32 if zero, else 31 - index of the
   most-significant set bit.  Matches the ALU_XCLZ loop in rtl/execution/alu.sv. *)
Definition clz32 (a : Word) : Word :=
  let v := Bits.to_nat a in
  if Nat.eqb v 0 then Bits.of_nat 32 32
  else Bits.of_nat 32 (31 - Nat.log2 v).

(* The ALU specification. *)
Definition alu_spec (op : alu_op) (a b : Word) : Word :=
  match op with
  | ALU_ADD    => Bits.plus a b
  | ALU_SUB    => Bits.minus a b
  | ALU_AND    => Bits.and a b
  | ALU_OR     => Bits.or a b
  | ALU_XOR    => Bits.xor a b
  | ALU_SLL    => Bits.lsl (shamt b) a
  | ALU_SRL    => Bits.lsr (shamt b) a
  | ALU_SRA    => Bits.asr (shamt b) a
  | ALU_SLT    => if Bits.signed_lt   a b then Bits.one else Bits.zero
  | ALU_SLTU   => if Bits.unsigned_lt a b then Bits.one else Bits.zero
  | ALU_COPY_B => b
  (* --- XFlux custom operations --- *)
  | ALU_XABS   => if Bits.msb a then Bits.minus Bits.zero a else a
  | ALU_XMIN   => if Bits.signed_lt a b then a else b
  | ALU_XMAX   => if Bits.signed_lt b a then a else b
  | ALU_XCLZ   => clz32 a
  | ALU_XLIDX  => Bits.plus a (Bits.lsl 2 b)      (* rs1 + (rs2 << 2) *)
  end.

(* ======================================================================== *)
(* Intended-property theorems (machine-checked).                             *)
(* ======================================================================== *)

(* Integer ALU: the comparison ops compute the signed / unsigned orders. *)
Theorem slt_is_signed_lt : forall a b,
  alu_spec ALU_SLT a b = (if Bits.signed_lt a b then Bits.one else Bits.zero).
Proof. reflexivity. Qed.

Theorem sltu_is_unsigned_lt : forall a b,
  alu_spec ALU_SLTU a b = (if Bits.unsigned_lt a b then Bits.one else Bits.zero).
Proof. reflexivity. Qed.

(* XABS: the sign of the input selects identity vs two's-complement negation
   (the RTL: result = a[31] ? -a : a).  b is ignored (unary op). *)
Theorem xabs_nonneg : forall a b, Bits.msb a = false -> alu_spec ALU_XABS a b = a.
Proof. intros a b H. cbn [alu_spec]; rewrite H. reflexivity. Qed.

Theorem xabs_neg : forall a b,
  Bits.msb a = true -> alu_spec ALU_XABS a b = Bits.minus Bits.zero a.
Proof. intros a b H. cbn [alu_spec]; rewrite H. reflexivity. Qed.

(* XMIN / XMAX are idempotent (min a a = max a a = a), independent of how the
   signed comparator resolves the tie — a small but real correctness fact. *)
Theorem xmin_idem : forall a, alu_spec ALU_XMIN a a = a.
Proof. intro a. cbn [alu_spec]; destruct (Bits.signed_lt a a); reflexivity. Qed.

Theorem xmax_idem : forall a, alu_spec ALU_XMAX a a = a.
Proof. intro a. cbn [alu_spec]; destruct (Bits.signed_lt a a); reflexivity. Qed.

(* XMIN always returns one of its two inputs; likewise XMAX.  (A lower/upper
   bound proof would additionally need signed-order antisymmetry lemmas.) *)
Theorem xmin_selects : forall a b,
  alu_spec ALU_XMIN a b = a \/ alu_spec ALU_XMIN a b = b.
Proof. intros a b. cbn [alu_spec]; destruct (Bits.signed_lt a b); [left|right]; reflexivity. Qed.

Theorem xmax_selects : forall a b,
  alu_spec ALU_XMAX a b = a \/ alu_spec ALU_XMAX a b = b.
Proof. intros a b. cbn [alu_spec]; destruct (Bits.signed_lt b a); [left|right]; reflexivity. Qed.

(* XCLZ of zero is 32 (all bits are leading zeros). *)
Theorem xclz_zero : forall b, alu_spec ALU_XCLZ Bits.zero b = Bits.of_nat 32 32.
Proof. intro b. vm_compute. reflexivity. Qed.

(* XLIDX computes the indexed-load effective address rs1 + (rs2 << 2). *)
Theorem xlidx_addr : forall a b, alu_spec ALU_XLIDX a b = Bits.plus a (Bits.lsl 2 b).
Proof. reflexivity. Qed.
