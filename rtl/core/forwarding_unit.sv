`default_nettype none

// forwarding_unit — purely combinational data-hazard resolution unit.
//
// Provides two services:
//
// 1. Operand forwarding (bypassing):
//    Replaces stale rs1_data / rs2_data from the pipeline register with the
//    most-recently-computed value of the same architectural register, so that
//    dependent instructions in EX see correct operands without a stall.
//
//    Two forward paths, highest priority first:
//
//    EX/MEM → EX (1-cycle stale): instruction now in MEM produced a result
//    one cycle ago.  The forwarded value mirrors mem_stage's writeback mux:
//    alu_result (ALU/AUIPC/LUI), pc+4 (JAL/JALR link), or csr_rdata (CSR old
//    value captured in EX).  Forward is NOT issued for loads (is_load=1)
//    because the load data is computed by the MEM stage in the same cycle and
//    is not yet available; a load-use stall is issued instead (see below).
//    Gated on: ex_mem_i.valid & decoded.writes_rd & decoded.legal & rd != x0
//              & !decoded.is_load
//
//    MEM/WB → EX (2-cycle stale): instruction now in WB produced a result
//    two cycles ago.  mem_wb_rd_data_i is the canonical value from wb_stage,
//    including live-BRAM load data when the MEM/WB payload's rd_data field is
//    stale in synthesis.
//    Gated on: mem_wb_i.rd_wen & rd_addr != x0
//    EX/MEM forward takes priority when both paths match the same register
//    (WAW-adjacent: newer producer is correct).
//
// 2. Load-use stall detection:
//    When the instruction currently in EX is a load (id_ex_i.decoded.is_load)
//    and the instruction currently in ID uses the load's destination register
//    as an operand, no forwarding path can bridge the gap — the load data is
//    not available until after the MEM stage.  The pipeline must be stalled
//    for one cycle:
//      • PC and IF/ID register are held (fetch and decode stall).
//      • ID/EX register is flushed (bubble replaces the dependent instruction
//        in EX for one cycle, so the load can complete through MEM).
//    After the stall, the dependent instruction enters EX when the load result
//    is in MEM/WB, and the 2-cycle MEM/WB → EX forward path supplies the value.
//
//    id_valid_i must be the valid bit of the ID instruction (if_id_q.valid).
//    A bubble in ID never triggers a stall.

module forwarding_unit
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
    import pipeline_pkg::*;
(
    // Instruction currently in EX (output of id_ex_reg)
    input  wire id_ex_payload_t  id_ex_i,

    // Instruction currently in MEM (output of ex_mem_reg)
    input  wire ex_mem_payload_t ex_mem_i,

    // Instruction currently in WB (output of mem_wb_reg)
    input  wire mem_wb_payload_t mem_wb_i,
    input  wire word_t           mem_wb_rd_data_i,
    // Canonical FP writeback value from wb_stage (for FP forwarding).
    input  wire word_t           mem_wb_frd_data_i,

    // Instruction currently in ID (combinational decoder output + valid bit)
    // Used only for load-use hazard detection.
    input  wire decoded_instr_t  id_decoded_i,
    input  wire logic            id_valid_i,

    // Forwarded operand values for execute_stage
    output word_t           rs1_fwd_o,
    output word_t           rs2_fwd_o,
    // Forwarded FP operand values (RV32F)
    output word_t           fs1_fwd_o,
    output word_t           fs2_fwd_o,
    output word_t           fs3_fwd_o,

    // Load-use hazard: pipeline_ctrl stalls IF+ID and flushes ID/EX
    output logic            load_use_stall_o,

    // CSR RAW hazard: a CSR instruction in EX or MEM writes a CSR that the
    // instruction in ID is about to read.  No forwarding path exists for CSRs
    // (the CSR write is synchronous in csr_unit); the pipeline must stall for
    // 1 cycle (writer in MEM) or 2 cycles (writer in EX) until the write
    // completes.  Same stall action as load-use: hold IF+ID, flush ID/EX.
    output logic            csr_raw_stall_o,

    // Deferred-load scoreboard (non-blocking dcache). sb_pending_i/sb_rd_i
    // name a register whose load data is still in flight; any ID-stage
    // instruction that READS it (RAW) or WRITES it (WAW — the late fill
    // write must never clobber a younger result) stalls until the fill
    // lands. Tied off (defaults) in blocking configurations.
    input  wire logic       sb_pending_i = 1'b0,
    input  wire reg_idx_t   sb_rd_i      = '0,
    output logic            sb_stall_o
);

    // -----------------------------------------------------------------------
    // EX/MEM forwarded value — must mirror mem_stage's writeback mux exactly,
    // forwarding the value that WILL be written to rd, not the raw ALU result.
    //
    // WB_ALU (ALU, AUIPC, LUI):  alu_result.
    // WB_PC4 (JAL/JALR):         pc+4 (alu_result holds the jump target).
    // WB_CSR (CSRRW/S/C[I]):     csr_rdata — the old CSR value captured in EX.
    //   (alu_result for a CSR op is the I-imm passthrough, i.e. the
    //    sign-extended CSR address — forwarding it corrupts the consumer.)
    // WB_MEM (load): forwarding suppressed — load-use stall handles this case.
    // -----------------------------------------------------------------------
    word_t ex_mem_fwd_s;
    always_comb begin
        case (ex_mem_i.decoded.wb_src)
            WB_PC4:  ex_mem_fwd_s = ex_mem_i.pc + 32'd4;
            WB_CSR:  ex_mem_fwd_s = ex_mem_i.csr_rdata;
            WB_FPU:  ex_mem_fwd_s = ex_mem_i.fp_result;  // FP→int (FCMP/FCVT.W/FMV.X/FCLASS)
            default: ex_mem_fwd_s = ex_mem_i.alu_result;
        endcase
    end

    // -----------------------------------------------------------------------
    // EX/MEM → EX forward enable (1-cycle staleness)
    //
    // Suppressed for loads (is_load): the load data is computed by mem_stage
    // in the same cycle that the consumer is in EX.  The load-use stall (below)
    // serialises this case; after the stall the MEM/WB path forwards correctly.
    // -----------------------------------------------------------------------
    logic fwd_em_rs1_s, fwd_em_rs2_s;

    assign fwd_em_rs1_s = ex_mem_i.valid
                        & ex_mem_i.decoded.writes_rd
                        & ex_mem_i.decoded.legal
                        & (ex_mem_i.decoded.rd != '0)
                        & ~ex_mem_i.decoded.is_load
                        // SC.W: is_store & writes_rd — its rd (the success
                        // flag) is computed in MEM; alu_result here is the
                        // ADDRESS. Never forward it; the load-use-style
                        // stall + MEM/WB path handles SC consumers.
                        & ~(ex_mem_i.decoded.is_store
                            & ex_mem_i.decoded.writes_rd)
                        & id_ex_i.decoded.uses_rs1
                        & (ex_mem_i.decoded.rd == id_ex_i.decoded.rs1);

    assign fwd_em_rs2_s = ex_mem_i.valid
                        & ex_mem_i.decoded.writes_rd
                        & ex_mem_i.decoded.legal
                        & (ex_mem_i.decoded.rd != '0)
                        & ~ex_mem_i.decoded.is_load
                        // SC.W: is_store & writes_rd — its rd (the success
                        // flag) is computed in MEM; alu_result here is the
                        // ADDRESS. Never forward it; the load-use-style
                        // stall + MEM/WB path handles SC consumers.
                        & ~(ex_mem_i.decoded.is_store
                            & ex_mem_i.decoded.writes_rd)
                        & id_ex_i.decoded.uses_rs2
                        & (ex_mem_i.decoded.rd == id_ex_i.decoded.rs2);

    // -----------------------------------------------------------------------
    // MEM/WB → EX forward enable (2-cycle staleness)
    //
    // mem_wb_rd_data_i reflects the final writeback value for all instruction
    // classes (load data, ALU result, CSR result, or pc+4 for jumps).
    // EX/MEM forward takes priority; suppress MEM/WB when EX/MEM already fires.
    // -----------------------------------------------------------------------
    logic fwd_mw_rs1_s, fwd_mw_rs2_s;

    assign fwd_mw_rs1_s = mem_wb_i.valid
                        & mem_wb_i.rd_wen
                        & (mem_wb_i.rd_addr != '0)
                        & id_ex_i.decoded.uses_rs1
                        & (mem_wb_i.rd_addr == id_ex_i.decoded.rs1)
                        & ~fwd_em_rs1_s;  // EX/MEM has priority

    assign fwd_mw_rs2_s = mem_wb_i.valid
                        & mem_wb_i.rd_wen
                        & (mem_wb_i.rd_addr != '0)
                        & id_ex_i.decoded.uses_rs2
                        & (mem_wb_i.rd_addr == id_ex_i.decoded.rs2)
                        & ~fwd_em_rs2_s;

    // -----------------------------------------------------------------------
    // Output operands: forwarded value wins, otherwise use regfile value
    // -----------------------------------------------------------------------
    assign rs1_fwd_o = fwd_em_rs1_s ? ex_mem_fwd_s :
                       fwd_mw_rs1_s ? mem_wb_rd_data_i :
                                      id_ex_i.rs1_data;

    assign rs2_fwd_o = fwd_em_rs2_s ? ex_mem_fwd_s :
                       fwd_mw_rs2_s ? mem_wb_rd_data_i :
                                      id_ex_i.rs2_data;

    // -----------------------------------------------------------------------
    // FP operand forwarding (RV32F).
    // FP-register indices reuse the rs1/rs2 fields (fs1=rs1, fs2=rs2) plus the
    // dedicated fs3 field.  The integer and FP register files are independent,
    // so an FP forward is gated on uses_fs*, never on uses_rs*.
    //   EX/MEM → EX : producer's writes_frd value = ex_mem_i.fp_result
    //                 (suppressed for FLW — load-use stall serialises that).
    //   MEM/WB → EX : mem_wb_frd_data_i (canonical, incl. live FLW data).
    // No x0 special case: f0 is an ordinary register.
    // -----------------------------------------------------------------------
    logic fwd_em_fs1_s, fwd_em_fs2_s, fwd_em_fs3_s;
    logic fwd_mw_fs1_s, fwd_mw_fs2_s, fwd_mw_fs3_s;

    assign fwd_em_fs1_s = ex_mem_i.valid & ex_mem_i.decoded.writes_frd
                        & ex_mem_i.decoded.legal & ~ex_mem_i.decoded.is_load
                        & id_ex_i.decoded.uses_fs1
                        & (ex_mem_i.decoded.rd == id_ex_i.decoded.rs1);
    assign fwd_em_fs2_s = ex_mem_i.valid & ex_mem_i.decoded.writes_frd
                        & ex_mem_i.decoded.legal & ~ex_mem_i.decoded.is_load
                        & id_ex_i.decoded.uses_fs2
                        & (ex_mem_i.decoded.rd == id_ex_i.decoded.rs2);
    assign fwd_em_fs3_s = ex_mem_i.valid & ex_mem_i.decoded.writes_frd
                        & ex_mem_i.decoded.legal & ~ex_mem_i.decoded.is_load
                        & id_ex_i.decoded.uses_fs3
                        & (ex_mem_i.decoded.rd == id_ex_i.decoded.fs3);

    assign fwd_mw_fs1_s = mem_wb_i.valid & mem_wb_i.frd_wen
                        & id_ex_i.decoded.uses_fs1
                        & (mem_wb_i.frd_addr == id_ex_i.decoded.rs1) & ~fwd_em_fs1_s;
    assign fwd_mw_fs2_s = mem_wb_i.valid & mem_wb_i.frd_wen
                        & id_ex_i.decoded.uses_fs2
                        & (mem_wb_i.frd_addr == id_ex_i.decoded.rs2) & ~fwd_em_fs2_s;
    assign fwd_mw_fs3_s = mem_wb_i.valid & mem_wb_i.frd_wen
                        & id_ex_i.decoded.uses_fs3
                        & (mem_wb_i.frd_addr == id_ex_i.decoded.fs3) & ~fwd_em_fs3_s;

    assign fs1_fwd_o = fwd_em_fs1_s ? ex_mem_i.fp_result :
                       fwd_mw_fs1_s ? mem_wb_frd_data_i  : id_ex_i.fs1_data;
    assign fs2_fwd_o = fwd_em_fs2_s ? ex_mem_i.fp_result :
                       fwd_mw_fs2_s ? mem_wb_frd_data_i  : id_ex_i.fs2_data;
    assign fs3_fwd_o = fwd_em_fs3_s ? ex_mem_i.fp_result :
                       fwd_mw_fs3_s ? mem_wb_frd_data_i  : id_ex_i.fs3_data;

    // -----------------------------------------------------------------------
    // Load-use hazard detection
    //
    // The load (id_ex_i) is in EX now; its result is not available until
    // after the MEM stage.  If the instruction in ID (id_decoded_i) reads
    // the load's destination, one stall cycle is required.
    //
    // Bubble in ID (id_valid_i=0) never generates a stall.
    // Load with rd=x0 (decoder sets writes_rd=1 but rd=0) never generates a
    // stall because no instruction architecturally reads x0 for a hazard.
    // -----------------------------------------------------------------------
    logic ldu_rs1_s, ldu_rs2_s;

    // "late-rd" producers: loads, and SC.W (the only store that writes rd,
    // whose flag also materialises in MEM).
    logic id_ex_late_rd_s;
    assign id_ex_late_rd_s = id_ex_i.decoded.is_load
                           | (id_ex_i.decoded.is_store
                              & id_ex_i.decoded.writes_rd);

    assign ldu_rs1_s = id_ex_i.valid
                     & id_ex_late_rd_s
                     & id_ex_i.decoded.writes_rd
                     & (id_ex_i.decoded.rd != '0)
                     & id_valid_i
                     & id_decoded_i.uses_rs1
                     & (id_ex_i.decoded.rd == id_decoded_i.rs1);

    assign ldu_rs2_s = id_ex_i.valid
                     & id_ex_late_rd_s
                     & id_ex_i.decoded.writes_rd
                     & (id_ex_i.decoded.rd != '0)
                     & id_valid_i
                     & id_decoded_i.uses_rs2
                     & (id_ex_i.decoded.rd == id_decoded_i.rs2);

    // FP load-use: an FLW in EX (is_load & writes_frd) whose destination f-reg
    // is read by the FP instruction now in ID.  No forward path bridges this;
    // one stall cycle, then the MEM/WB→EX FP forward supplies the value.
    logic fp_ldu_s;
    assign fp_ldu_s = id_ex_i.valid
                    & id_ex_i.decoded.is_load
                    & id_ex_i.decoded.writes_frd
                    & id_valid_i
                    & ( (id_decoded_i.uses_fs1 & (id_ex_i.decoded.rd == id_decoded_i.rs1))
                      | (id_decoded_i.uses_fs2 & (id_ex_i.decoded.rd == id_decoded_i.rs2))
                      | (id_decoded_i.uses_fs3 & (id_ex_i.decoded.rd == id_decoded_i.fs3)) );

    // WAW guard for the non-blocking cache: a load in EX whose rd the ID
    // instruction WRITES (without reading it — that is the load-use case)
    // gets one bubble, so the writer is still in ID when the load's miss
    // defers in MEM and the scoreboard rd-match can hold it there. Without
    // this, `lw x5,..; addi x5,..` at distance 1 slips past the scoreboard
    // and the late fill write clobbers the younger addi result.
    logic ldu_waw_s;
    assign ldu_waw_s = id_ex_i.valid
                     & id_ex_late_rd_s
                     & id_ex_i.decoded.writes_rd
                     & (id_ex_i.decoded.rd != '0)
                     & id_valid_i
                     & id_decoded_i.writes_rd
                     & (id_ex_i.decoded.rd == id_decoded_i.rd);

    assign load_use_stall_o = ldu_rs1_s | ldu_rs2_s | fp_ldu_s | ldu_waw_s;

    // Scoreboard stall: the ID instruction touches the in-flight load's rd.
    assign sb_stall_o = sb_pending_i
                      & (sb_rd_i != '0)
                      & id_valid_i
                      & ( (id_decoded_i.uses_rs1  & (id_decoded_i.rs1 == sb_rd_i))
                        | (id_decoded_i.uses_rs2  & (id_decoded_i.rs2 == sb_rd_i))
                        | (id_decoded_i.writes_rd & (id_decoded_i.rd  == sb_rd_i)) );

    // -----------------------------------------------------------------------
    // CSR RAW hazard detection
    //
    // A CSR read occurs combinationally in EX (csr_unit.rdata_o feeds the
    // execute stage).  A CSR write completes synchronously at the end of the
    // MEM stage cycle (csr_unit.wen_i is asserted from mem_stage; the new
    // value is registered on posedge).  Therefore:
    //
    //   Writer in EX, reader in ID → 2 stall cycles required.
    //     (writer goes EX→MEM→WB; write takes effect at posedge of MEM cycle;
    //      reader must be in EX one cycle AFTER the write posedge.)
    //   Writer in MEM, reader in ID → 1 stall cycle required.
    //     (write takes effect at posedge of MEM cycle; reader enters EX next.)
    //
    // The stall automatically self-propagates: after 1 cycle of stall, the
    // writer moves from EX to MEM, which fires the MEM stall for one more
    // cycle, giving the correct 2-cycle total.
    //
    // Gated on csr_op != CSR_NOP: CSRRS/CSRRC with rs1=x0 (or zimm=0) set
    // csr_op=CSR_NOP in the decoder and never write the CSR, so no stall.
    // -----------------------------------------------------------------------
    logic csr_raw_ex_s, csr_raw_mem_s;

    assign csr_raw_ex_s = id_ex_i.valid
                        & id_ex_i.decoded.is_csr
                        & (id_ex_i.decoded.csr_op != CSR_NOP)
                        & id_valid_i
                        & id_decoded_i.is_csr
                        & (id_ex_i.decoded.csr_addr == id_decoded_i.csr_addr);

    assign csr_raw_mem_s = ex_mem_i.valid
                         & ex_mem_i.decoded.is_csr
                         & (ex_mem_i.decoded.csr_op != CSR_NOP)
                         & id_valid_i
                         & id_decoded_i.is_csr
                         & (ex_mem_i.decoded.csr_addr == id_decoded_i.csr_addr);

    // -----------------------------------------------------------------------
    // fcsr flag-accrual RAW hazard (RV32F)
    //
    // An FP compute op (is_fp) accrues its IEEE exception flags into fcsr only
    // at its WB stage (wb_stage → csr_unit at that posedge).  A following CSR
    // access to fflags/fcsr reads the CSR combinationally in EX, so if it is
    // within two instructions of the FP op it would return stale flags.
    //
    // Stall the fflags/fcsr access in ID while an fflags-accruing FP op is still
    // in EX or MEM (not yet committed).  When the FP op reaches WB the condition
    // clears, and the reader — entering EX the following cycle — sees the
    // just-committed flags.  Same stall action as the CSR-CSR RAW hazard.
    //
    // The stall action flushes the ID/EX register, which outranks a stall in the
    // stage register.  For a SINGLE-CYCLE FP op that is harmless (it has already
    // advanced EX→MEM), but a multi-cycle FDIV/FSQRT lives in EX for its whole
    // iteration and must NOT be flushed.  While a divide/sqrt iterates, fpu_stall
    // already holds the reader in ID; once it advances to MEM the MEM-stage term
    // below catches it.  So the EX-stage term excludes div/sqrt.
    //
    // Only fflags/fcsr carry the accrued flags; frm is never modified by an FP
    // op, so reads of frm alone are not stalled.  FLW/FSW have is_fp=0 and do
    // not accrue flags, so they never trigger this.
    // -----------------------------------------------------------------------
    logic id_reads_fcsr_s, fp_flags_inflight_s, fcsr_fp_raw_s;

    assign id_reads_fcsr_s = id_valid_i
                           & id_decoded_i.is_csr
                           & ((id_decoded_i.csr_addr == CSR_FFLAGS)
                            | (id_decoded_i.csr_addr == CSR_FCSR));

    assign fp_flags_inflight_s =
          (id_ex_i.valid  & id_ex_i.decoded.is_fp
                          & (id_ex_i.decoded.fpu_op != FPU_DIV)
                          & (id_ex_i.decoded.fpu_op != FPU_SQRT))  // single-cycle FP in EX
        | (ex_mem_i.valid & ex_mem_i.decoded.is_fp);               // any FP op in MEM

    assign fcsr_fp_raw_s = id_reads_fcsr_s & fp_flags_inflight_s;

    // -----------------------------------------------------------------------
    // MRET's implicit mepc read.
    //
    // MRET redirects from EX using csr_unit.mepc_o; a CSR write to mepc
    // commits at the writer's MEM stage. An unseparated `csrw mepc; mret`
    // would therefore redirect to the STALE mepc. Hold MRET in ID while a
    // CSR write to mepc is still in EX or MEM — the same interlock the
    // explicit-CSR-read path gets, extended to this implicit reader (trap
    // handlers emitted by real toolchains do not insert the NOP the early
    // hand-written tests carried).
    // -----------------------------------------------------------------------
    logic mret_mepc_raw_s;
    assign mret_mepc_raw_s = id_valid_i
                           & id_decoded_i.is_mret
                           & ( (id_ex_i.valid  & id_ex_i.decoded.is_csr
                                & (id_ex_i.decoded.csr_addr == CSR_MEPC))
                             | (ex_mem_i.valid & ex_mem_i.decoded.is_csr
                                & (ex_mem_i.decoded.csr_addr == CSR_MEPC)) );

    assign csr_raw_stall_o = csr_raw_ex_s | csr_raw_mem_s | fcsr_fp_raw_s
                           | mret_mepc_raw_s;

endmodule : forwarding_unit

`default_nettype wire
