(* verification/formal/koika/Impl/FluxAluImpl.v
 *
 * Kôika combinational circuits for the FluxCore integer ALU / XFlux datapath —
 * the Impl half of the Path-A refinement.  These are real Kôika PureExpr
 * circuits (built from the DSL primitives Abbr.plus/and/or/xor/minus/…), the
 * same object Kôika compiles to Verilog.  Refine/FluxAluRefine.v proves each
 * circuit partial-evaluates (peval) to the reference function in Spec/FluxAlu.v.
 *
 * Each circuit is parameterised over the DSL variable carrier V, exactly like
 * the example datapaths in Gpu.Core.DecodeImpl; the refinement instantiates
 * V := bits and evaluates.
 *)

From Koika Require Import Prelude.
From Flux Require Import FluxCommon.

#[local] Set Default Timeout 60.

Section alu_circuits.
  Context {mod_t} `{M : Modules.t mod_t} {V : nat -> Type}.

  (* Bitwise and arithmetic ALU datapaths — one Kôika BOp each. *)
  Definition alu_and_expr (a b : V 32) : PureExpr V 32 := Abbr.and   ${a} ${b}.
  Definition alu_or_expr  (a b : V 32) : PureExpr V 32 := Abbr.or    ${a} ${b}.
  Definition alu_xor_expr (a b : V 32) : PureExpr V 32 := Abbr.xor   ${a} ${b}.
  Definition alu_add_expr (a b : V 32) : PureExpr V 32 := Abbr.plus  ${a} ${b}.
  Definition alu_sub_expr (a b : V 32) : PureExpr V 32 := Abbr.minus ${a} ${b}.

  (* Pass-through (LUI: result = operand b). *)
  Definition alu_copyb_expr (a b : V 32) : PureExpr V 32 := ${b}.

  (* Shifts: amount is the low 5 bits of b (RV32 §2.6). *)
  Definition alu_sll_expr (a b : V 32) : PureExpr V 32 := Abbr.lsl ${a} (Abbr.slice 0 5 ${b}).
  Definition alu_srl_expr (a b : V 32) : PureExpr V 32 := Abbr.lsr ${a} (Abbr.slice 0 5 ${b}).
  Definition alu_sra_expr (a b : V 32) : PureExpr V 32 := Abbr.asr ${a} (Abbr.slice 0 5 ${b}).

  (* Set-less-than: signed / unsigned comparison, 0/1 result. *)
  Definition alu_slt_expr  (a b : V 32) : PureExpr V 32 :=
    If (Abbr.slt ${a} ${b}) #{Bits.one} #{Bits.zero}.
  Definition alu_sltu_expr (a b : V 32) : PureExpr V 32 :=
    If (Abbr.lt  ${a} ${b}) #{Bits.one} #{Bits.zero}.

  (* XFlux signed min / max. *)
  Definition alu_xmin_expr (a b : V 32) : PureExpr V 32 := If (Abbr.slt ${a} ${b}) ${a} ${b}.
  Definition alu_xmax_expr (a b : V 32) : PureExpr V 32 := If (Abbr.slt ${b} ${a}) ${a} ${b}.

  (* XFlux XLIDX effective address: rs1 + (rs2 << 2). *)
  Definition alu_xlidx_expr (a b : V 32) : PureExpr V 32 :=
    Abbr.plus ${a} (Abbr.lsl ${b} #{Bits.of_nat 5 2}).

  (* XFlux XABS: |rs1| -- negative (signed < 0) selects the two's-complement
     negation 0 - a. *)
  Definition alu_xabs_expr (a b : V 32) : PureExpr V 32 :=
    If (Abbr.slt ${a} #{Bits.zero}) (Abbr.minus #{Bits.zero} ${a}) ${a}.
End alu_circuits.
