(* verification/formal/koika/Spec/FluxMul.v
 *
 * Reference semantics for the directly-expressible half of the RV32M multiply
 * family: MUL (low 32 bits of the product) and MULHU (high 32 bits of the
 * unsigned product).  Kôika's `Bits.mul` is the 64-bit *unsigned* product
 * `of_N (sz1+sz2) (to_N a * to_N b)`, so these two ops are one primitive each.
 *
 * MULH / MULHSU require sign-extending an operand before the multiply, and
 * DIV/DIVU/REM/REMU are iterative — those remain as the rest of the RV32M
 * module (see Refine/Top.v roadmap, step 3).
 *)

From Koika Require Import Prelude.
From Flux Require Import FluxCommon.

#[local] Set Default Timeout 60.

(* Full 64-bit unsigned product of two 32-bit words. *)
Definition mul_full (a b : Word) : bits 64 := Bits.mul a b.

(* MUL: low 32 bits (identical for signed/unsigned — the low half of a two's
   complement product does not depend on the sign interpretation). *)
Definition mul_lo  (a b : Word) : Word := Bits.slice 0 32 (mul_full a b).

(* MULHU: high 32 bits of the unsigned product. *)
Definition mul_hiu (a b : Word) : Word := Bits.slice 32 32 (mul_full a b).

(* Sign- and zero-extension of a word to 64 bits (the operand preparation the
   signed multiplies are defined over — RV32M §7.1: MULH/MULHSU are the high
   word of the 64-bit product of the sign-/zero-extended operands). *)
Definition sext64 (a : Word) : bits 64 := Bits.extend_end a 64 (Bits.msb a).
Definition zext64 (a : Word) : bits 64 := Bits.extend_end a 64 false.

(* MULH: high 32 bits of the 64-bit signed×signed product. *)
Definition mul_hi (a b : Word) : Word :=
  Bits.slice 32 32 (Bits.mul (sext64 a) (sext64 b)).

(* MULHSU: high 32 bits of the 64-bit signed×unsigned product. *)
Definition mul_hisu (a b : Word) : Word :=
  Bits.slice 32 32 (Bits.mul (sext64 a) (zext64 b)).
