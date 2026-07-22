(* verification/formal/koika/Refine/Top.v
 *
 * Top of the FluxCore ↔ Kôika Path-A development.
 *
 * PROVEN (Qed, no axioms):
 *
 *   FluxCore_refines : refines FluxCoreImpl ISASpec
 *     (Refine/FluxProcRefine.v — re-exported and Checked below.)
 *   THE machine-level refinement, in the framework's simulation relation
 *   (Koika.Lang.BigStepSemantics: refines := mod_init ⊑ sim).  FluxCoreImpl
 *   (Impl/FluxProcImpl.v) is a real Kôika module — PC register, 32 register
 *   submodules, mux/demux indexing, the proven ALU circuits as datapath —
 *   and ISASpec (Spec/FluxProcSpec.v) is the sequential ISA machine.  The
 *   simulation quantifies over ALL instruction streams and method traces.
 *
 *   alu_datapath_correct / branch_unit_correct / mul_datapath_correct —
 *   the combinational datapath refinements (this file, below); the ALU/branch/multiply bundles
 *   are consumed BY FluxCore_refines through alu_expr_of_correct + peval.
 *
 * WHAT THE MACHINE THEOREM COVERS TODAY (v2 — stated honestly):
 *   single-cycle transactional machine over the FluxCore integer ISA:
 *   ALU/ALU-imm (15 proven ops incl. XABS/XMIN/XMAX/XLIDX), the 6 branches,
 *   JAL/JALR, LUI/AUIPC, LW/SW and LB/LBU/LH/LHU/SB/SH (word-granular magic
 *   memory, aligned base), MUL/MULH/MULHSU/MULHU; x0 hardwired; invalid
 *   class/op words refused by both machines; instructions arrive pre-decoded
 *   (a 55-bit control word).
 *
 * REMAINING OBLIGATIONS (each grows Impl+Spec+proof, same statement shape):
 *     a. DIV/DIVU/REM/REMU — needs a verified iterative divider circuit
 *        (no Kôika division primitive); XCLZ — priority-encoder proof
 *     b. decode: raw RV32 instruction bits -> control word (template:
 *        Gpu.Basic.Decode), replacing the pre-decoded step argument
 *     c. CSRs / traps / interrupts (template: Gpu.CsrFile)
 *     d. FPU ⊑ Flocq (Bplus/Bmult/Bfma/Bdiv/Bsqrt) for the F extension
 *     e. the PIPELINED FluxCoreImpl — five-stage, forwarding/hazards — proven
 *        against the SAME ISASpec via refines_trans (pipelined ⊑ v2 ⊑ ISA);
 *        this is the research-grade step
 *     f. Kôika backend compile of FluxProcImpl to Verilog for the hardware
 *        artifact
 *)

From Koika Require Import Prelude.
From Flux Require Import FluxCommon.
From Flux Require Import Spec.FluxAlu.
From Flux Require Import Spec.FluxBranch.
From Flux Require Import Spec.FluxMul.
From Flux Require Import Spec.FluxIsa.
From Flux Require Import FluxProc.
From Flux Require Import Spec.FluxProcSpec.
From Flux Require Import Impl.FluxAluImpl.
From Flux Require Import Impl.FluxBranchImpl.
From Flux Require Import Impl.FluxMulImpl.
From Flux Require Import Impl.FluxProcImpl.
From Flux Require Import Refine.FluxAluRefine.
From Flux Require Import Refine.FluxBranchRefine.
From Flux Require Import Refine.FluxMulRefine.
From Flux Require Import Refine.FluxProcRefine.

#[local] Set Default Timeout 60.

Section top.
  Context {mod_t} `{M : Modules.t mod_t}.

  (* The execute-stage datapath refinement, bundled: for every ALU op with a
     circuit, the Kôika circuit computes exactly the reference function. *)
  Theorem alu_datapath_correct (a b : Word) :
    peval (alu_and_expr   a b) = inl (alu_spec ALU_AND   a b) /\
    peval (alu_or_expr    a b) = inl (alu_spec ALU_OR    a b) /\
    peval (alu_xor_expr   a b) = inl (alu_spec ALU_XOR   a b) /\
    peval (alu_add_expr   a b) = inl (alu_spec ALU_ADD   a b) /\
    peval (alu_sub_expr   a b) = inl (alu_spec ALU_SUB   a b) /\
    peval (alu_copyb_expr a b) = inl (alu_spec ALU_COPY_B a b) /\
    peval (alu_sll_expr   a b) = inl (alu_spec ALU_SLL   a b) /\
    peval (alu_srl_expr   a b) = inl (alu_spec ALU_SRL   a b) /\
    peval (alu_sra_expr   a b) = inl (alu_spec ALU_SRA   a b) /\
    peval (alu_slt_expr   a b) = inl (alu_spec ALU_SLT   a b) /\
    peval (alu_sltu_expr  a b) = inl (alu_spec ALU_SLTU  a b) /\
    peval (alu_xmin_expr  a b) = inl (alu_spec ALU_XMIN  a b) /\
    peval (alu_xmax_expr  a b) = inl (alu_spec ALU_XMAX  a b) /\
    peval (alu_xlidx_expr a b) = inl (alu_spec ALU_XLIDX a b) /\
    peval (alu_xabs_expr  a b) = inl (alu_spec ALU_XABS  a b).
  Proof.
    repeat split;
      auto using alu_and_correct, alu_or_correct, alu_xor_correct,
                 alu_add_correct, alu_sub_correct, alu_copyb_correct,
                 alu_sll_correct, alu_srl_correct, alu_sra_correct,
                 alu_slt_correct, alu_sltu_correct, alu_xmin_correct,
                 alu_xmax_correct, alu_xlidx_correct, alu_xabs_correct.
  Qed.

  (* Execute-stage branch resolution: every conditional-branch circuit computes
     exactly its `branch_taken` reference bit. *)
  Theorem branch_unit_correct (a b : Word) :
    peval (branch_eq_expr  a b) = inl (Ob~(branch_taken BR_EQ  a b)) /\
    peval (branch_ne_expr  a b) = inl (Ob~(branch_taken BR_NE  a b)) /\
    peval (branch_lt_expr  a b) = inl (Ob~(branch_taken BR_LT  a b)) /\
    peval (branch_ge_expr  a b) = inl (Ob~(branch_taken BR_GE  a b)) /\
    peval (branch_ltu_expr a b) = inl (Ob~(branch_taken BR_LTU a b)) /\
    peval (branch_geu_expr a b) = inl (Ob~(branch_taken BR_GEU a b)).
  Proof.
    repeat split;
      auto using branch_eq_correct, branch_ne_correct, branch_lt_correct,
                 branch_ge_correct, branch_ltu_correct, branch_geu_correct.
  Qed.

  (* RV32M multiply — the full family: low word, and the three high words
     (signed, signed x unsigned, unsigned). *)
  Theorem mul_datapath_correct (a b : Word) :
    peval (mul_lo_expr   a b) = inl (mul_lo   a b) /\
    peval (mul_hi_expr   a b) = inl (mul_hi   a b) /\
    peval (mul_hisu_expr a b) = inl (mul_hisu a b) /\
    peval (mul_hiu_expr  a b) = inl (mul_hiu  a b).
  Proof.
    repeat split;
      auto using mul_lo_correct, mul_hi_correct, mul_hisu_correct,
                 mul_hiu_correct.
  Qed.

End top.

(* Sanity: the ISA-level ALU step is well defined and its writeback is the
   datapath result. *)
Check arch_step_alu_writes_rd.

(* THE top-level theorem, re-exported from Refine/FluxProcRefine.v:
   the FluxCore Kôika machine refines the ISA specification machine. *)
Check FluxCore_refines.
