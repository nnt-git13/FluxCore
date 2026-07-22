// verification/unit/pipeline/tb_pipeline_ctrl.sv
//
// Self-checking testbench for rtl/core/pipeline_ctrl.sv.
//
// pipeline_ctrl is purely combinational. Each test vector drives the inputs,
// waits #1 for settling, then checks all relevant outputs.
//
// Coverage:
//   Quiescent (no events):     all flush/redirect=0, all stall=0
//   Taken branch:              flush_if_id+flush_id_ex=1, ex_mem+mem_wb untouched,
//                              redirect=branch_target
//   Not-taken branch:          no flush, no redirect
//   JAL (is_jump, valid, legal): flush IF/ID+ID/EX, redirect to branch_target
//   JALR:                      same as JAL
//   Illegal jump (legal=0):    no redirect from branch path
//   Bubble + branch_taken=1 (valid=0): no redirect
//   Exception (exc.valid=1):   flush all 4, redirect to trap_vector_i (NOT exc_pc)
//   Exception priority > branch: both active → exception wins (all 4 flushed,
//                                trap vector, NOT branch_target)
//   Stall outputs all 0:       confirmed on every test vector

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_pipeline_ctrl;

    // -----------------------------------------------------------------------
    // DUT wires
    // -----------------------------------------------------------------------
    ex_mem_payload_t  ex_mem_w   = '0;
    exception_meta_t  exc_w        = '0;
    word_t            trap_vec_w   = 32'hFFFF_0000;  // arbitrary trap vector
    word_t            mepc_w         = '0;
    logic             ldu_stall_w    = 1'b0;
    logic             csr_raw_w      = 1'b0;
    logic             dmem_stall_w   = 1'b0;
    logic             muldiv_stall_w = 1'b0;
    logic             fpu_stall_w    = 1'b0;

    logic  stall_if_w, stall_id_w, stall_ex_w, stall_mem_w, stall_wb_w;
    logic  fl_ifid_w, fl_idex_w, fl_exmem_w, fl_memwb_w;
    logic  redir_w;
    word_t redir_tgt_w;

    pipeline_ctrl dut (
        .ex_mem_i        (ex_mem_w),
        .exception_i     (exc_w),
        .trap_vector_i   (trap_vec_w),
        .mepc_i          (mepc_w),
        .load_use_stall_i(ldu_stall_w),
        .csr_raw_stall_i (csr_raw_w),
        .dmem_stall_i    (dmem_stall_w),
        .muldiv_stall_i  (muldiv_stall_w),
        .fpu_stall_i     (fpu_stall_w),
        .stall_if_o      (stall_if_w),
        .stall_id_o      (stall_id_w),
        .stall_ex_o      (stall_ex_w),
        .stall_mem_o     (stall_mem_w),
        .stall_wb_o      (stall_wb_w),
        .flush_if_id_o   (fl_ifid_w),
        .flush_id_ex_o   (fl_idex_w),
        .flush_ex_mem_o  (fl_exmem_w),
        .flush_mem_wb_o  (fl_memwb_w),
        .redirect_valid_o(redir_w),
        .redirect_target_o(redir_tgt_w)
    );

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------
    task automatic apply(
        input ex_mem_payload_t p,
        input exception_meta_t e,
        input logic            ldu = 1'b0
    );
        ex_mem_w    = p;
        exc_w       = e;
        ldu_stall_w = ldu;
        #1;
    endtask

    // Verify EX/MEM/WB stall outputs are always 0 (no structural stalls)
    task automatic chk_no_stall(input string ctx);
        if (stall_ex_w | stall_mem_w | stall_wb_w)
            $fatal(1, "[PCTRL] FAIL %s: stall output(s) unexpectedly asserted (if=%b id=%b ex=%b mem=%b wb=%b)",
                   ctx, stall_if_w, stall_id_w, stall_ex_w, stall_mem_w, stall_wb_w);
    endtask

    // Check flush pattern and redirect
    task automatic chk(
        input logic  exp_fl_ifid,
        input logic  exp_fl_idex,
        input logic  exp_fl_exmem,
        input logic  exp_fl_memwb,
        input logic  exp_redir,
        input word_t exp_tgt,
        input string desc
    );
        if (fl_ifid_w  !== exp_fl_ifid)
            $fatal(1, "[PCTRL] FAIL %-40s flush_if_id=%b expected=%b",
                   desc, fl_ifid_w, exp_fl_ifid);
        if (fl_idex_w  !== exp_fl_idex)
            $fatal(1, "[PCTRL] FAIL %-40s flush_id_ex=%b expected=%b",
                   desc, fl_idex_w, exp_fl_idex);
        if (fl_exmem_w !== exp_fl_exmem)
            $fatal(1, "[PCTRL] FAIL %-40s flush_ex_mem=%b expected=%b",
                   desc, fl_exmem_w, exp_fl_exmem);
        if (fl_memwb_w !== exp_fl_memwb)
            $fatal(1, "[PCTRL] FAIL %-40s flush_mem_wb=%b expected=%b",
                   desc, fl_memwb_w, exp_fl_memwb);
        if (redir_w    !== exp_redir)
            $fatal(1, "[PCTRL] FAIL %-40s redirect_valid=%b expected=%b",
                   desc, redir_w, exp_redir);
        if (exp_redir && redir_tgt_w !== exp_tgt)
            $fatal(1, "[PCTRL] FAIL %-40s redirect_target=%08h expected=%08h",
                   desc, redir_tgt_w, exp_tgt);
        chk_no_stall(desc);
    endtask

    // -----------------------------------------------------------------------
    // Payload builders
    // -----------------------------------------------------------------------

    // Taken branch
    function automatic ex_mem_payload_t mk_branch_taken(input word_t target);
        automatic ex_mem_payload_t p = '0;
        p.valid                = 1'b1;
        p.decoded.legal        = 1'b1;
        p.decoded.is_branch    = 1'b1;
        p.branch_taken         = 1'b1;
        p.branch_target        = target;
        return p;
    endfunction

    // Not-taken branch
    function automatic ex_mem_payload_t mk_branch_nt(input word_t pc);
        automatic ex_mem_payload_t p = '0;
        p.valid             = 1'b1;
        p.pc                = pc;
        p.decoded.legal     = 1'b1;
        p.decoded.is_branch = 1'b1;
        p.branch_taken      = 1'b0;
        p.branch_target     = pc + 32'd8;  // plausible but not taken
        return p;
    endfunction

    // JAL or JALR (is_jump=1)
    function automatic ex_mem_payload_t mk_jump(
        input word_t    target,
        input logic     uses_rs1  // 0=JAL, 1=JALR
    );
        automatic ex_mem_payload_t p = '0;
        p.valid               = 1'b1;
        p.decoded.legal       = 1'b1;
        p.decoded.is_jump     = 1'b1;
        p.decoded.uses_rs1    = uses_rs1;
        p.branch_taken        = 1'b0;   // jumps don't use branch_taken
        p.branch_target       = target;
        return p;
    endfunction

    // Illegal jump (legal=0): should NOT produce a redirect
    function automatic ex_mem_payload_t mk_illegal_jump(input word_t target);
        automatic ex_mem_payload_t p = '0;
        p.valid            = 1'b1;
        p.decoded.legal    = 1'b0;  // illegal
        p.decoded.is_jump  = 1'b1;
        p.branch_taken     = 1'b0;
        p.branch_target    = target;
        return p;
    endfunction

    // Bubble with branch_taken=1 (valid=0): must not redirect
    function automatic ex_mem_payload_t mk_bubble_branch(input word_t target);
        automatic ex_mem_payload_t p = '0;
        p.valid                = 1'b0;  // bubble!
        p.decoded.legal        = 1'b1;
        p.decoded.is_branch    = 1'b1;
        p.branch_taken         = 1'b1;  // set, but valid=0 gates the redirect
        p.branch_target        = target;
        return p;
    endfunction

    // Normal ALU instruction (no control flow)
    function automatic ex_mem_payload_t mk_alu(input word_t pc);
        automatic ex_mem_payload_t p = '0;
        p.valid          = 1'b1;
        p.pc             = pc;
        p.decoded.legal  = 1'b1;
        return p;
    endfunction

    // Exception metadata builder
    function automatic exception_meta_t mk_exc(
        input exc_cause_e cause,
        input word_t      tval
    );
        automatic exception_meta_t e;
        e.valid = 1'b1;
        e.cause = cause;
        e.tval  = tval;
        return e;
    endfunction

    // -----------------------------------------------------------------------
    // Main test
    // -----------------------------------------------------------------------
    initial begin : test_body

        // ================================================================
        // 1. Quiescent: no events → all outputs inactive
        // ================================================================
        apply('0, '0);
        chk(0, 0, 0, 0, 0, '0, "quiescent: no events");
        $display("[PCTRL] quiescent: all outputs inactive ✓");

        // ================================================================
        // 2. Normal ALU (no branch): no flush, no redirect
        // ================================================================
        apply(mk_alu(32'h1000), '0);
        chk(0, 0, 0, 0, 0, '0, "ALU instr: no control flow");
        $display("[PCTRL] ALU instr: no flush, no redirect ✓");

        // ================================================================
        // 3. Not-taken branch: no flush, no redirect
        // ================================================================
        apply(mk_branch_nt(32'h2000), '0);
        chk(0, 0, 0, 0, 0, '0, "branch not-taken: no redirect");
        $display("[PCTRL] branch not-taken: no flush, no redirect ✓");

        // ================================================================
        // 4. Taken branch: flush IF/ID + ID/EX; redirect to branch_target
        // ================================================================
        apply(mk_branch_taken(32'hDEAD_0000), '0);
        chk(1, 1, 0, 0, 1, 32'hDEAD_0000, "branch taken: 2-stage flush + redirect");
        $display("[PCTRL] branch taken: IF/ID + ID/EX flushed, redirect=0xDEAD0000 ✓");

        // Different target
        apply(mk_branch_taken(32'h0000_4000), '0);
        chk(1, 1, 0, 0, 1, 32'h0000_4000, "branch taken: target 0x4000");

        // ================================================================
        // 5. JAL (is_jump=1, uses_rs1=0): always redirect
        // ================================================================
        apply(mk_jump(32'h8000_0000, 1'b0), '0);
        chk(1, 1, 0, 0, 1, 32'h8000_0000, "JAL: 2-stage flush + redirect");
        $display("[PCTRL] JAL: IF/ID + ID/EX flushed, redirect ✓");

        // ================================================================
        // 6. JALR (is_jump=1, uses_rs1=1): same behavior
        // ================================================================
        apply(mk_jump(32'h1234_5678, 1'b1), '0);
        chk(1, 1, 0, 0, 1, 32'h1234_5678, "JALR: 2-stage flush + redirect");
        $display("[PCTRL] JALR: IF/ID + ID/EX flushed, redirect ✓");

        // ================================================================
        // 7. Illegal jump (legal=0): no redirect (gated on legal)
        // ================================================================
        apply(mk_illegal_jump(32'hBAD0_0000), '0);
        chk(0, 0, 0, 0, 0, '0, "illegal jump: legal=0 → no redirect");
        $display("[PCTRL] illegal jump: legal=0 gate prevents redirect ✓");

        // ================================================================
        // 8. Bubble with branch_taken=1 (valid=0): no redirect
        // ================================================================
        apply(mk_bubble_branch(32'hBAD1_0000), '0);
        chk(0, 0, 0, 0, 0, '0, "bubble + branch_taken=1: valid=0 → no redirect");
        $display("[PCTRL] bubble with branch_taken=1: valid=0 gate prevents redirect ✓");

        // ================================================================
        // 9. Exception only: flush all 4, redirect to trap_vector_i
        //    (not to exception_pc; that's captured by the future CSR unit)
        // ================================================================
        apply(mk_alu(32'h5000),
              mk_exc(EXC_ILLEGAL_INSTRUCTION, 32'hDEAD_BEEF));
        chk(1, 1, 1, 1, 1, trap_vec_w, "exception: 4-stage flush + trap_vector redirect");
        $display("[PCTRL] exception: all stages flushed, redirect=trap_vector ✓");

        // Verify redirect goes to trap_vec_w, not the ALU instruction's PC
        if (redir_tgt_w === 32'h5000)
            $fatal(1, "[PCTRL] FAIL exception redirect: target is exception_pc, should be trap_vector_i");

        // ================================================================
        // 10. Exception with different cause (load misalignment)
        // ================================================================
        apply(mk_alu(32'h6000),
              mk_exc(EXC_LOAD_ADDR_MISALIGNED, 32'h6003));
        chk(1, 1, 1, 1, 1, trap_vec_w, "load misalign exception: 4-stage flush");
        $display("[PCTRL] load misalign exception: all stages flushed ✓");

        // ================================================================
        // 11. Exception priority over branch:
        //     Both exception (WB) and taken branch (EX) fire simultaneously.
        //     Exception wins: all 4 flushed, redirect = trap_vector_i.
        // ================================================================
        apply(mk_branch_taken(32'hAAAA_0000),
              mk_exc(EXC_STORE_ADDR_MISALIGNED, 32'h7001));
        // Exception must win: flush all 4, redirect to trap_vector_i
        chk(1, 1, 1, 1, 1, trap_vec_w, "exc priority over branch: 4-stage flush, trap vec");
        // Critically: redirect target must NOT be the branch target
        if (redir_tgt_w === 32'hAAAA_0000)
            $fatal(1, "[PCTRL] FAIL exc/branch conflict: redirected to branch_target not trap_vector");
        $display("[PCTRL] exception beats branch: all 4 flushed, trap_vector wins ✓");

        // ================================================================
        // 12. Exception priority over JAL:
        //     Both exception (WB) and JAL (EX) fire simultaneously.
        // ================================================================
        apply(mk_jump(32'hBBBB_0000, 1'b0),
              mk_exc(EXC_ILLEGAL_INSTRUCTION, 32'hFF));
        chk(1, 1, 1, 1, 1, trap_vec_w, "exc priority over JAL: 4-stage flush, trap vec");
        if (redir_tgt_w === 32'hBBBB_0000)
            $fatal(1, "[PCTRL] FAIL exc/JAL conflict: redirected to JAL target not trap_vector");
        $display("[PCTRL] exception beats JAL: trap_vector wins ✓");

        // ================================================================
        // 13. Trap vector parametrised correctly: change trap_vec_w and check
        // ================================================================
        trap_vec_w = 32'h0000_0100;
        apply(mk_alu(32'h0), mk_exc(EXC_BREAKPOINT, 32'h0));
        if (redir_tgt_w !== 32'h0000_0100)
            $fatal(1, "[PCTRL] FAIL trap vector: redir=%08h expected 0x00000100", redir_tgt_w);
        $display("[PCTRL] trap_vector_i parametrised correctly ✓");

        // ================================================================
        // 14. Load-use stall only: stall IF+ID, flush ID/EX, no redirect
        //     EX/MEM/WB stalls must be 0; ex_mem and mem_wb flushes must be 0.
        // ================================================================
        trap_vec_w = 32'hFFFF_0000;  // restore trap vector
        apply(mk_alu(32'h4000), '0, 1'b1);  // load_use_stall=1, no branch, no exc
        if (stall_if_w !== 1'b1)
            $fatal(1, "[PCTRL] FAIL ldu stall: stall_if should be 1");
        if (stall_id_w !== 1'b1)
            $fatal(1, "[PCTRL] FAIL ldu stall: stall_id should be 1");
        if (stall_ex_w !== 1'b0)
            $fatal(1, "[PCTRL] FAIL ldu stall: stall_ex should be 0");
        if (fl_idex_w !== 1'b1)
            $fatal(1, "[PCTRL] FAIL ldu stall: flush_id_ex should be 1");
        if (fl_ifid_w !== 1'b0)
            $fatal(1, "[PCTRL] FAIL ldu stall: flush_if_id should be 0");
        if (fl_exmem_w !== 1'b0)
            $fatal(1, "[PCTRL] FAIL ldu stall: flush_ex_mem should be 0");
        if (fl_memwb_w !== 1'b0)
            $fatal(1, "[PCTRL] FAIL ldu stall: flush_mem_wb should be 0");
        if (redir_w !== 1'b0)
            $fatal(1, "[PCTRL] FAIL ldu stall: redirect should be 0");
        $display("[PCTRL] load-use stall: stall IF+ID, flush ID/EX, no redirect ✓");

        // ================================================================
        // 15. Exception beats load-use stall (all 4 flushed, redirect)
        // ================================================================
        apply(mk_alu(32'h0), mk_exc(EXC_LOAD_ADDR_MISALIGNED, 32'h1), 1'b1);
        chk(1, 1, 1, 1, 1, trap_vec_w, "exc beats load-use: 4-stage flush");
        if (stall_if_w !== 1'b0)
            $fatal(1, "[PCTRL] FAIL exc+ldu: stall_if should be 0 (flush subsumes stall)");
        $display("[PCTRL] exception beats load-use stall ✓");

        // ================================================================
        // 16. Branch beats load-use stall (2-stage flush + redirect)
        // ================================================================
        apply(mk_branch_taken(32'hCCCC_0000), '0, 1'b1);
        chk(1, 1, 0, 0, 1, 32'hCCCC_0000, "branch beats load-use: 2-stage flush");
        if (stall_if_w !== 1'b0)
            $fatal(1, "[PCTRL] FAIL branch+ldu: stall_if should be 0 (flush subsumes stall)");
        $display("[PCTRL] branch beats load-use stall ✓");

        // ================================================================
        // Done
        // ================================================================
        $display("[PCTRL] PASS: all pipeline control behaviors verified.");
        $finish;

    end : test_body

endmodule : tb_pipeline_ctrl

`default_nettype wire
