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

    // Instruction currently in ID (combinational decoder output + valid bit)
    // Used only for load-use hazard detection.
    input  wire decoded_instr_t  id_decoded_i,
    input  wire logic            id_valid_i,

    // Forwarded operand values for execute_stage
    output word_t           rs1_fwd_o,
    output word_t           rs2_fwd_o,

    // Load-use hazard: pipeline_ctrl stalls IF+ID and flushes ID/EX
    output logic            load_use_stall_o,

    // CSR RAW hazard: a CSR instruction in EX or MEM writes a CSR that the
    // instruction in ID is about to read.  No forwarding path exists for CSRs
    // (the CSR write is synchronous in csr_unit); the pipeline must stall for
    // 1 cycle (writer in MEM) or 2 cycles (writer in EX) until the write
    // completes.  Same stall action as load-use: hold IF+ID, flush ID/EX.
    output logic            csr_raw_stall_o
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
                        & id_ex_i.decoded.uses_rs1
                        & (ex_mem_i.decoded.rd == id_ex_i.decoded.rs1);

    assign fwd_em_rs2_s = ex_mem_i.valid
                        & ex_mem_i.decoded.writes_rd
                        & ex_mem_i.decoded.legal
                        & (ex_mem_i.decoded.rd != '0)
                        & ~ex_mem_i.decoded.is_load
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

    assign ldu_rs1_s = id_ex_i.valid
                     & id_ex_i.decoded.is_load
                     & id_ex_i.decoded.writes_rd
                     & (id_ex_i.decoded.rd != '0)
                     & id_valid_i
                     & id_decoded_i.uses_rs1
                     & (id_ex_i.decoded.rd == id_decoded_i.rs1);

    assign ldu_rs2_s = id_ex_i.valid
                     & id_ex_i.decoded.is_load
                     & id_ex_i.decoded.writes_rd
                     & (id_ex_i.decoded.rd != '0)
                     & id_valid_i
                     & id_decoded_i.uses_rs2
                     & (id_ex_i.decoded.rd == id_decoded_i.rs2);

    assign load_use_stall_o = ldu_rs1_s | ldu_rs2_s;

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

    assign csr_raw_stall_o = csr_raw_ex_s | csr_raw_mem_s;

endmodule : forwarding_unit

`default_nettype wire
