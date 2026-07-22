(* verification/formal/koika/Impl/FluxMulImpl.v
 *
 * Kôika combinational circuits for the directly-expressible RV32M multiply ops
 * (MUL, MULHU) — the Impl half of the multiply refinement.  Each slices the
 * 64-bit `Bits.mul` product; Refine/FluxMulRefine.v proves each partial-
 * evaluates to the reference in Spec/FluxMul.v.
 *)

From Koika Require Import Prelude.
From Flux Require Import FluxCommon.

#[local] Set Default Timeout 60.

Section mul_circuits.
  Context {mod_t} `{M : Modules.t mod_t} {V : nat -> Type}.

  (* MUL: low 32 bits of the 64-bit product. *)
  Definition mul_lo_expr  (a b : V 32) : PureExpr V 32 :=
    Abbr.slice 0 32 (Abbr.mul ${a} ${b}).

  (* MULHU: high 32 bits of the 64-bit unsigned product. *)
  Definition mul_hiu_expr (a b : V 32) : PureExpr V 32 :=
    Abbr.slice 32 32 (Abbr.mul ${a} ${b}).

  (* MULH: sign-extend both operands to 64, multiply, take bits [32,64) —
     the high word of the signed product (the low 64 bits of the 128-bit
     product of the extended operands equal the signed product mod 2^64). *)
  Definition mul_hi_expr (a b : V 32) : PureExpr V 32 :=
    Abbr.slice 32 32 (Abbr.mul (Abbr.sext 64 ${a}) (Abbr.sext 64 ${b})).

  (* MULHSU: sign-extend rs1, zero-extend rs2. *)
  Definition mul_hisu_expr (a b : V 32) : PureExpr V 32 :=
    Abbr.slice 32 32 (Abbr.mul (Abbr.sext 64 ${a}) (Abbr.zextL 64 ${b})).
End mul_circuits.
