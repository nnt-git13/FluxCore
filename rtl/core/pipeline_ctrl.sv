`default_nettype none

// pipeline_ctrl — purely combinational pipeline control unit.
//
// Generates flush/stall signals for all stage registers and the fetch unit.
//
// Redirect sources, highest priority first:
//
//   1. Exception from WB (exception_i.valid):
//        Flush all four stage registers; redirect fetch to trap_vector_i
//        (= csr_unit.mtvec_o after the CSR wiring milestone).
//        The faulting instruction's PC travels on wb_stage.exception_pc_o and
//        is captured by csr_unit.trap_epc_i → mepc.
//
//   2. MRET in EX (ex_mem_i.decoded.is_mret & legal):
//        Flush the two youngest stage registers (IF/ID, ID/EX).
//        Redirect fetch to mepc_i (= csr_unit.mepc_o).
//        One cycle later, MRET reaches MEM and pulses mret_o → csr_unit.mret_i
//        to restore MIE←MPIE, MPIE←1.
//
//   3. Branch taken, or unconditional jump (JAL/JALR):
//        Flush the two stage registers younger than the resolved instruction
//        (if_id_reg and id_ex_reg), squashing the two wrong-path fetches.
//        Redirect fetch to ex_mem_i.branch_target.
//
//        Condition: ex_mem_i.branch_taken
//                   OR (ex_mem_i.valid & is_jump & legal)
//
//        branch_taken is already gated on (is_branch & legal) in execute_stage;
//        the is_jump arm handles JAL and JALR, which always redirect.
//
// Load-use stall (load_use_stall_i from forwarding_unit):
//   When a load in EX is followed immediately by an instruction that reads the
//   load destination in ID, the pipeline must stall for one cycle.  Action:
//     • stall_if_o = 1   — hold PC (fetch unit does not advance)
//     • stall_id_o = 1   — hold IF/ID register (dependent stays in ID)
//     • flush_id_ex_o = 1 — zero ID/EX register (bubble inserted into EX)
//   EX, MEM, and WB are not stalled; the load proceeds to MEM normally.
//   Priority: exception > MRET > branch/jump > load-use.
//
// CSR RAW stall (csr_raw_stall_i from forwarding_unit):
//   When a CSR instruction in EX or MEM writes a CSR that a following CSR
//   instruction in ID is about to read, the pipeline stalls 1 or 2 cycles
//   until the write completes (csr_unit writes are synchronous).  Same action
//   as load-use stall.  Handled at equal priority: OR'd with load_use_stall_i.
//   CSRRS/CSRRC with rs1=x0 and CSRRSI/CSRRCI with zimm=0 are CSR_NOP in the
//   decoder and do not trigger this stall.

module pipeline_ctrl
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
    import pipeline_pkg::*;
(
    // EX stage combinational output (evaluated before ex_mem_reg latches it)
    input  wire ex_mem_payload_t  ex_mem_i,

    // WB stage exception output
    input  wire exception_meta_t  exception_i,

    // Trap redirect target: wire to csr_unit.mtvec_o
    input  wire word_t            trap_vector_i,

    // MRET redirect target: wire to csr_unit.mepc_o
    input  wire word_t            mepc_i,

    // Load-use hazard from forwarding_unit: stall IF+ID, flush ID/EX
    input  wire logic             load_use_stall_i,

    // CSR RAW hazard from forwarding_unit: stall IF+ID, flush ID/EX.
    // Same action as load-use; the two signals are OR'd in the stall block.
    input  wire logic             csr_raw_stall_i,

    // Data-cache miss: stall all 5 stages until cache fills
    input  wire logic             dmem_stall_i,

    // MUL/DIV unit busy: stall all 5 stages until the result is ready.
    // Additive — applied in a separate block below, same pattern as dmem_stall_i.
    input  wire logic             muldiv_stall_i,

    // Stall outputs
    output logic             stall_if_o,
    output logic             stall_id_o,
    output logic             stall_ex_o,
    output logic             stall_mem_o,
    output logic             stall_wb_o,

    // Flush outputs
    output logic             flush_if_id_o,
    output logic             flush_id_ex_o,
    output logic             flush_ex_mem_o,
    output logic             flush_mem_wb_o,

    // Redirect to fetch unit
    output logic             redirect_valid_o,
    output word_t            redirect_target_o
);

    // -----------------------------------------------------------------------
    // Redirect conditions
    // -----------------------------------------------------------------------
    logic redirect_exc_s;
    logic redirect_mret_s;
    logic redirect_branch_s;

    assign redirect_exc_s = exception_i.valid;

    assign redirect_mret_s = ex_mem_i.valid
                           & ex_mem_i.decoded.is_mret
                           & ex_mem_i.decoded.legal;

    assign redirect_branch_s = ex_mem_i.valid
                             & (ex_mem_i.branch_taken
                                | (ex_mem_i.decoded.is_jump & ex_mem_i.decoded.legal));

    // -----------------------------------------------------------------------
    // Stall / flush / redirect
    //
    // Priority (highest first):
    //   1. Exception: flush all 4 stages, redirect to trap vector.
    //      Subsumes branch and load-use actions.
    //   2. Branch/jump: flush IF/ID + ID/EX, redirect.
    //      Subsumes load-use (the dependent instruction is squashed anyway).
    //   3. Load-use stall: hold IF+ID, flush ID/EX (insert bubble into EX).
    //      EX, MEM, WB are unaffected — load continues to MEM normally.
    // -----------------------------------------------------------------------
    always_comb begin
        stall_if_o        = 1'b0;
        stall_id_o        = 1'b0;
        stall_ex_o        = 1'b0;
        stall_mem_o       = 1'b0;
        stall_wb_o        = 1'b0;
        flush_if_id_o     = 1'b0;
        flush_id_ex_o     = 1'b0;
        flush_ex_mem_o    = 1'b0;
        flush_mem_wb_o    = 1'b0;
        redirect_valid_o  = 1'b0;
        redirect_target_o = '0;

        if (redirect_exc_s) begin
            flush_if_id_o     = 1'b1;
            flush_id_ex_o     = 1'b1;
            flush_ex_mem_o    = 1'b1;
            flush_mem_wb_o    = 1'b1;
            redirect_valid_o  = 1'b1;
            redirect_target_o = trap_vector_i;
        end else if (redirect_mret_s) begin
            // MRET: squash the two wrong-path fetches behind MRET,
            // redirect to mepc.  CSR state update (MIE←MPIE) fires
            // one cycle later when MRET's mret_o pulse reaches csr_unit.
            flush_if_id_o     = 1'b1;
            flush_id_ex_o     = 1'b1;
            redirect_valid_o  = 1'b1;
            redirect_target_o = mepc_i;
        end else if (redirect_branch_s) begin
            flush_if_id_o     = 1'b1;
            flush_id_ex_o     = 1'b1;
            redirect_valid_o  = 1'b1;
            redirect_target_o = ex_mem_i.branch_target;
        end else if (load_use_stall_i | csr_raw_stall_i) begin
            stall_if_o    = 1'b1;
            stall_id_o    = 1'b1;
            flush_id_ex_o = 1'b1;
        end
        // Cache miss: freeze entire pipeline. Additive — flush takes priority
        // because flush clears stage registers regardless of stall.
        if (dmem_stall_i) begin
            stall_if_o  = 1'b1;
            stall_id_o  = 1'b1;
            stall_ex_o  = 1'b1;
            stall_mem_o = 1'b1;
            stall_wb_o  = 1'b1;
        end
        // MUL/DIV stall: same freeze pattern.  The DIV instruction stays in EX
        // until the iterative unit completes; instructions behind it stall in IF/ID.
        if (muldiv_stall_i) begin
            stall_if_o  = 1'b1;
            stall_id_o  = 1'b1;
            stall_ex_o  = 1'b1;
            stall_mem_o = 1'b1;
            stall_wb_o  = 1'b1;
        end
    end

endmodule : pipeline_ctrl

`default_nettype wire
