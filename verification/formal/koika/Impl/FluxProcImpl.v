(* verification/formal/koika/Impl/FluxProcImpl.v
 *
 * FluxCoreImpl — the FluxCore machine as a Kôika MODULE (the compile-to-
 * hardware object): a PC register + 32 architectural register submodules +
 * a word-memory submodule + the proven datapath circuits (ALU/XFlux, branch
 * comparisons, RV32M multiplies), glued by real mux circuits (mux_expr
 * elaborates the full 2^n If-tree over a runtime index).
 * Interface: FluxProc.ifc; proven against Spec/FluxProcSpec.v in
 * Refine/FluxProcRefine.v (`FluxCore_refines`).
 *
 * v2 machine shape (stated honestly):
 *   - single-cycle / transactional: `step` retires one whole instruction; the
 *     pipelined machine is a later Impl proven against the SAME spec via
 *     refines_trans (pipelined ⊑ this ⊑ ISASpec);
 *   - the FluxCore integer ISA: ALU/ALU-imm (15 proven ops), the 6 branches,
 *     JAL/JALR, LUI/AUIPC, LW/SW (word, aligned), MUL/MULH/MULHSU/MULHU;
 *     invalid class/op words Rollback (the method refuses, matching the spec);
 *   - x0 is hardwired: writes to register 0 are dropped at the write demux;
 *   - out of scope (documented): DIV/REM, F, CSRs/traps, byte/halfword lanes.
 *)

From Koika Require Import Prelude.
From Gpu Require Import Reg.
From Flux Require Import FluxCommon.
From Flux Require Import Spec.FluxAlu.
From Flux Require Import Spec.FluxBranch.
From Flux Require Import Impl.FluxAluImpl.
From Flux Require Import Impl.FluxBranchImpl.
From Flux Require Import Impl.FluxMulImpl.
From Flux Require Import FluxMem.
From Flux Require Import FluxProc.

Import Abbr.

#[local] Set Default Timeout 120.

Section impl.

  Variant proc_mod_t :=
    | pc
    | mem
    | reg (i : RegIdx)
  .

  #[export] Instance EqDecProcModT : EqDec proc_mod_t := _.

  #[local] Instance submodules : Modules.t proc_mod_t :=
  {|
    Modules.mod_list :=
      pc :: mem ::
      map reg (map (Bits.of_index 5) (vect_to_list (all_indices 32)));
    Modules.mod_list_wf := list_wf!;
    Modules.get_name m :=
      match m with
      | pc => "pc"
      | mem => "mem"
      | reg i => nth_name "reg_" (Bits.to_nat i)
      end;
    Modules.get_sig m :=
      match m with
      | pc => Reg.ifc 32
      | mem => WordMem.ifc
      | reg _ => Reg.ifc 32
      end;
  |}.

  Notation VMet := (VMet (M:=submodules)).
  Notation AMet := (AMet (M:=submodules)).

  (* Dynamic register read: a 32-way read mux over the register submodules. *)
  Definition read_reg {V} (i : V 5) : PureExpr V 32 :=
    mux_expr i (fun iv => VMet (reg iv) Reg.read <[]>)
  .

  (* Dynamic register write: a 32-way write demux; lane 0 drops the write —
     x0 is hardwired to zero. *)
  Definition write_reg {V} (i : V 5) (v : V 32) : EffExpr V 0 :=
    mux_expr i (fun iv =>
      if eq_dec iv (Bits.zero : RegIdx) then Ret #{Ob}
      else AMet (reg iv) Reg.write <[${v}]>)
  .

  (* pc <- pc + 4 *)
  Definition wr_pc4 {V} (pcv : V 32) : EffExpr V 0 :=
    AMet pc Reg.write <[plus ${pcv} #{Bits.of_nat 32 4}]>
  .

  (* The ALU datapath: dispatch a decoded op to its PROVEN Kôika circuit
     (Impl/FluxAluImpl.v).  XCLZ has no verified circuit and is never produced
     by decode_op; its arm is dead code. *)
  Definition alu_expr_of {V} (o : alu_op) (a b : V 32) : PureExpr V 32 :=
    match o with
    | ALU_AND    => alu_and_expr a b
    | ALU_OR     => alu_or_expr a b
    | ALU_XOR    => alu_xor_expr a b
    | ALU_ADD    => alu_add_expr a b
    | ALU_SUB    => alu_sub_expr a b
    | ALU_COPY_B => alu_copyb_expr a b
    | ALU_SLL    => alu_sll_expr a b
    | ALU_SRL    => alu_srl_expr a b
    | ALU_SRA    => alu_sra_expr a b
    | ALU_SLT    => alu_slt_expr a b
    | ALU_SLTU   => alu_sltu_expr a b
    | ALU_XMIN   => alu_xmin_expr a b
    | ALU_XMAX   => alu_xmax_expr a b
    | ALU_XLIDX  => alu_xlidx_expr a b
    | ALU_XABS   => alu_xabs_expr a b
    | ALU_XCLZ   => ${a}   (* unreachable via decode_op *)
    end
  .

  (* The branch-condition datapath (Impl/FluxBranchImpl.v). *)
  Definition br_expr_of {V} (bo : branch_op) (a b : V 32) : PureExpr V 1 :=
    match bo with
    | BR_EQ  => branch_eq_expr a b
    | BR_NE  => branch_ne_expr a b
    | BR_LT  => branch_lt_expr a b
    | BR_GE  => branch_ge_expr a b
    | BR_LTU => branch_ltu_expr a b
    | BR_GEU => branch_geu_expr a b
    end
  .

  (* Branch next-PC: taken selects pc+imm, else pc+4. *)
  Definition br_nextpc_expr {V} (bo : branch_op) (a b pcv imm : V 32)
    : PureExpr V 32 :=
    If (br_expr_of bo a b)
       (plus ${pcv} ${imm})
       (plus ${pcv} #{Bits.of_nat 32 4})
  .

  (* The RV32M multiply datapath (Impl/FluxMulImpl.v). *)
  Definition mul_expr_of {V} (m : mul_op) (a b : V 32) : PureExpr V 32 :=
    match m with
    | M_LO   => mul_lo_expr a b
    | M_HI   => mul_hi_expr a b
    | M_HISU => mul_hisu_expr a b
    | M_HIU  => mul_hiu_expr a b
    end
  .

  (* Byte / halfword lane muxes: select or replace the addressed sub-word of
     the aligned memory word, steered by the low address bits.  These mirror
     the load_byte/load_half/store_byte/store_half reference functions. *)
  Definition byte_mux {V} (lane : V 2) (w : V 32) : PureExpr V 8 :=
    mux_expr lane (fun lv =>
      match Bits.to_nat lv with
      | 0 => slice 0  8 ${w}
      | 1 => slice 8  8 ${w}
      | 2 => slice 16 8 ${w}
      | _ => slice 24 8 ${w}
      end)
  .

  Definition half_mux {V} (lane : V 1) (w : V 32) : PureExpr V 16 :=
    mux_expr lane (fun lv =>
      match Bits.to_nat lv with
      | 0 => slice 0  16 ${w}
      | _ => slice 16 16 ${w}
      end)
  .

  Definition byte_subst_mux {V} (lane : V 2) (w : V 32) (v : V 8)
    : PureExpr V 32 :=
    mux_expr lane (fun lv =>
      match Bits.to_nat lv with
      | 0 => BOp (PrimTyped.SliceSubst 32 0  8) ${w} ${v}
      | 1 => BOp (PrimTyped.SliceSubst 32 8  8) ${w} ${v}
      | 2 => BOp (PrimTyped.SliceSubst 32 16 8) ${w} ${v}
      | _ => BOp (PrimTyped.SliceSubst 32 24 8) ${w} ${v}
      end)
  .

  Definition half_subst_mux {V} (lane : V 1) (w : V 32) (v : V 16)
    : PureExpr V 32 :=
    mux_expr lane (fun lv =>
      match Bits.to_nat lv with
      | 0 => BOp (PrimTyped.SliceSubst 32 0  16) ${w} ${v}
      | _ => BOp (PrimTyped.SliceSubst 32 16 16) ${w} ${v}
      end)
  .

  (* Sub-word extension circuits (result type forced to 32 so the binder
     types stay reduced). *)
  Definition sext8_expr  {V} (b : V 8)  : PureExpr V 32 := sext 32 ${b}.
  Definition zext8_expr  {V} (b : V 8)  : PureExpr V 32 := zextL 32 ${b}.
  Definition sext16_expr {V} (h : V 16) : PureExpr V 32 := sext 32 ${h}.
  Definition zext16_expr {V} (h : V 16) : PureExpr V 32 := zextL 32 ${h}.

  (* ---- interface methods ---- *)

  Definition getPc_syn {V} : PureExpr V 32 :=
    VMet pc Reg.read <[]>
  .

  Definition getReg_syn {V} (args : context V [5]) : PureExpr V 32 :=
    read_reg (chd args)
  .

  Definition getMem_syn {V} (args : context V [32]) : PureExpr V 32 :=
    VMet mem rdMem <[${chd args}]>
  .

  (* step(ctrl): retire one instruction — slice the control word, read the
     sources, dispatch the class mux, execute the proven datapath, write back
     through the x0-hardwired demux, update the PC. *)
  Definition step_syn {V} (args : context V [CtrlSz]) : EffExpr V 0 :=
    let/var cls  : V 4  <- slice 0  4  ${chd args} in
    let/var opb  : V 4  <- slice 4  4  ${chd args} in
    let/var rd   : V 5  <- slice 8  5  ${chd args} in
    let/var rs1  : V 5  <- slice 13 5  ${chd args} in
    let/var rs2  : V 5  <- slice 18 5  ${chd args} in
    let/var imm  : V 32 <- slice 23 32 ${chd args} in
    let/var a    : V 32 <- read_reg rs1 in
    let/var b    : V 32 <- read_reg rs2 in
    let/var pcv  : V 32 <- VMet pc Reg.read <[]> in
    mux_expr cls (fun clv =>
      match decode_class clv with
      | Some CL_ALU =>
        mux_expr opb (fun opv =>
          match decode_op opv with
          | Some o =>
            let/var res : V 32 <- alu_expr_of o a b in
            write_reg rd res ;; wr_pc4 pcv
          | None => Ret Rollback
          end)
      | Some CL_ALUI =>
        mux_expr opb (fun opv =>
          match decode_op opv with
          | Some o =>
            let/var res : V 32 <- alu_expr_of o a imm in
            write_reg rd res ;; wr_pc4 pcv
          | None => Ret Rollback
          end)
      | Some CL_BR =>
        mux_expr opb (fun opv =>
          match decode_br opv with
          | Some bo =>
            let/var npc : V 32 <- br_nextpc_expr bo a b pcv imm in
            AMet pc Reg.write <[${npc}]>
          | None => Ret Rollback
          end)
      | Some CL_JAL =>
        let/var lnk : V 32 <- plus ${pcv} #{Bits.of_nat 32 4} in
        write_reg rd lnk ;;
        AMet pc Reg.write <[plus ${pcv} ${imm}]>
      | Some CL_JALR =>
        let/var lnk : V 32 <- plus ${pcv} #{Bits.of_nat 32 4} in
        let/var tgt : V 32 <- and (plus ${a} ${imm}) #{maskJalr} in
        write_reg rd lnk ;;
        AMet pc Reg.write <[${tgt}]>
      | Some CL_LUI =>
        write_reg rd imm ;; wr_pc4 pcv
      | Some CL_AUIPC =>
        let/var v : V 32 <- plus ${pcv} ${imm} in
        write_reg rd v ;; wr_pc4 pcv
      | Some CL_LW =>
        let/var addr : V 32 <- and (plus ${a} ${imm}) #{maskAlign} in
        let/var v : V 32 <- VMet mem rdMem <[${addr}]> in
        write_reg rd v ;; wr_pc4 pcv
      | Some CL_SW =>
        let/var addr : V 32 <- and (plus ${a} ${imm}) #{maskAlign} in
        AMet mem wrMem <[${addr}; ${b}]> ;; wr_pc4 pcv
      | Some CL_MUL =>
        mux_expr opb (fun opv =>
          match decode_mop opv with
          | Some m =>
            let/var res : V 32 <- mul_expr_of m a b in
            write_reg rd res ;; wr_pc4 pcv
          | None => Ret Rollback
          end)
      | Some CL_LB =>
        let/var ea   : V 32 <- plus ${a} ${imm} in
        let/var wa   : V 32 <- and ${ea} #{maskAlign} in
        let/var lane : V 2  <- slice 0 2 ${ea} in
        let/var w    : V 32 <- VMet mem rdMem <[${wa}]> in
        let/var bv   : V 8  <- byte_mux lane w in
        let/var res  : V 32 <- sext8_expr bv in
        write_reg rd res ;; wr_pc4 pcv
      | Some CL_LBU =>
        let/var ea   : V 32 <- plus ${a} ${imm} in
        let/var wa   : V 32 <- and ${ea} #{maskAlign} in
        let/var lane : V 2  <- slice 0 2 ${ea} in
        let/var w    : V 32 <- VMet mem rdMem <[${wa}]> in
        let/var bv   : V 8  <- byte_mux lane w in
        let/var res  : V 32 <- zext8_expr bv in
        write_reg rd res ;; wr_pc4 pcv
      | Some CL_LH =>
        let/var ea   : V 32 <- plus ${a} ${imm} in
        let/var wa   : V 32 <- and ${ea} #{maskAlign} in
        let/var lane : V 1  <- slice 1 1 ${ea} in
        let/var w    : V 32 <- VMet mem rdMem <[${wa}]> in
        let/var hv   : V 16 <- half_mux lane w in
        let/var res  : V 32 <- sext16_expr hv in
        write_reg rd res ;; wr_pc4 pcv
      | Some CL_LHU =>
        let/var ea   : V 32 <- plus ${a} ${imm} in
        let/var wa   : V 32 <- and ${ea} #{maskAlign} in
        let/var lane : V 1  <- slice 1 1 ${ea} in
        let/var w    : V 32 <- VMet mem rdMem <[${wa}]> in
        let/var hv   : V 16 <- half_mux lane w in
        let/var res  : V 32 <- zext16_expr hv in
        write_reg rd res ;; wr_pc4 pcv
      | Some CL_SB =>
        let/var ea   : V 32 <- plus ${a} ${imm} in
        let/var wa   : V 32 <- and ${ea} #{maskAlign} in
        let/var lane : V 2  <- slice 0 2 ${ea} in
        let/var w    : V 32 <- VMet mem rdMem <[${wa}]> in
        let/var bv   : V 8  <- slice 0 8 ${b} in
        let/var w'   : V 32 <- byte_subst_mux lane w bv in
        AMet mem wrMem <[${wa}; ${w'}]> ;; wr_pc4 pcv
      | Some CL_SH =>
        let/var ea   : V 32 <- plus ${a} ${imm} in
        let/var wa   : V 32 <- and ${ea} #{maskAlign} in
        let/var lane : V 1  <- slice 1 1 ${ea} in
        let/var w    : V 32 <- VMet mem rdMem <[${wa}]> in
        let/var hv   : V 16 <- slice 0 16 ${b} in
        let/var w'   : V 32 <- half_subst_mux lane w hv in
        AMet mem wrMem <[${wa}; ${w'}]> ;; wr_pc4 pcv
      | None => Ret Rollback
      end)
  .

  Definition Σ (m : proc_mod_t) : Sem.t (Modules.get_sig m) :=
    match m as m' return Sem.t (Modules.get_sig m') with
    | pc => mkReg 32 Bits.zero
    | mem => mkWordMem
    | reg _ => mkReg 32 Bits.zero
    end.

  Definition syn {V} : mod_syn V FluxProc.ifc.
  Proof.
    refine {|
      Syntax.rules := Rules.empty;
    |}.
    - destruct v.
      + exact (fun _ => getPc_syn).
      + exact getReg_syn.
      + exact getMem_syn.
    - destruct a.
      + exact step_syn.
    - destruct 1.
  Defined.

  Definition FluxCoreImpl : Sem.t FluxProc.ifc := interp_mod (Σ := Σ) _ syn.

End impl.
