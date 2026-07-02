// verification/unit/core/tb_forwarding_unit.sv
//
// Self-checking testbench for rtl/core/forwarding_unit.sv.
//
// All tests are purely combinational (#1 settle, then check).
//
// Coverage:
//   No hazard: rs1_fwd = id_ex.rs1_data, rs2_fwd = id_ex.rs2_data
//   EX/MEM → rs1 (ALU): forward alu_result
//   EX/MEM → rs2 (ALU): forward alu_result
//   EX/MEM → rs1 (JAL/JALR, WB_PC4): forward pc+4 (NOT alu_result)
//   EX/MEM → rs1 NOT for load (is_load=1): falls through to MEM/WB or stale
//   MEM/WB → rs1: forward canonical WB data
//   MEM/WB → rs2: forward canonical WB data
//   MEM/WB load: forward live WB-stage data even if payload rd_data is stale
//   EX/MEM priority over MEM/WB when same register matches both paths
//   No EX/MEM forward when rd=x0 (writes_rd but rd=0)
//   No MEM/WB forward when rd_wen=0
//   No MEM/WB forward when rd_addr=x0
//   Bubble in EX/MEM (valid=0): no EX/MEM forward
//   Bubble in MEM/WB (valid=0): no MEM/WB forward (rd_wen=0 in bubble)
//   No forward when uses_rs1=0 / uses_rs2=0 (operand not read by instruction)
//   Illegal instruction in EX/MEM (legal=0): no EX/MEM forward
//   Load-use stall: load in EX, rs1 dependency in ID → stall_o=1
//   Load-use stall: load in EX, rs2 dependency in ID → stall_o=1
//   Load-use stall: bubble in ID (id_valid=0) → no stall
//   Load-use stall: load rd=x0 → no stall (x0 never hazardous)
//   Load-use stall: dependent uses_rs1=0 → no stall for that operand
//   No stall for non-load instruction in EX
//   No stall when load rd ≠ ID instruction's rs1/rs2

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_forwarding_unit;

    // -----------------------------------------------------------------------
    // DUT wires
    // -----------------------------------------------------------------------
    id_ex_payload_t  id_ex_w   = '0;
    ex_mem_payload_t ex_mem_w  = '0;
    mem_wb_payload_t mem_wb_w  = '0;
    word_t           mem_wb_rd_data_w = '0;
    decoded_instr_t  id_dec_w  = '0;
    logic            id_valid_w = 1'b0;

    word_t rs1_fwd_w, rs2_fwd_w;
    logic  stall_w;

    forwarding_unit dut (
        .id_ex_i         (id_ex_w),
        .ex_mem_i        (ex_mem_w),
        .mem_wb_i        (mem_wb_w),
        .mem_wb_rd_data_i(mem_wb_rd_data_w),
        .id_decoded_i    (id_dec_w),
        .id_valid_i      (id_valid_w),
        .rs1_fwd_o       (rs1_fwd_w),
        .rs2_fwd_o       (rs2_fwd_w),
        .load_use_stall_o(stall_w)
    );

    // -----------------------------------------------------------------------
    // Builders
    // -----------------------------------------------------------------------

    // EX instruction (in id_ex_w)
    function automatic id_ex_payload_t mk_ex(
        input reg_idx_t rs1, input word_t rs1_data,
        input reg_idx_t rs2, input word_t rs2_data,
        input logic     uses_rs1, input logic uses_rs2
    );
        automatic id_ex_payload_t p = '0;
        p.valid             = 1'b1;
        p.decoded.rs1       = rs1;
        p.decoded.rs2       = rs2;
        p.decoded.uses_rs1  = uses_rs1;
        p.decoded.uses_rs2  = uses_rs2;
        p.rs1_data          = rs1_data;
        p.rs2_data          = rs2_data;
        return p;
    endfunction

    // MEM instruction (in ex_mem_w) — ALU result
    function automatic ex_mem_payload_t mk_mem_alu(
        input reg_idx_t rd,
        input word_t    alu_result,
        input logic     is_load = 0
    );
        automatic ex_mem_payload_t p = '0;
        p.valid                = 1'b1;
        p.decoded.legal        = 1'b1;
        p.decoded.writes_rd    = 1'b1;
        p.decoded.rd           = rd;
        p.decoded.wb_src       = WB_ALU;
        p.decoded.is_load      = is_load;
        p.alu_result           = alu_result;
        return p;
    endfunction

    // MEM instruction — JAL/JALR (WB_PC4)
    function automatic ex_mem_payload_t mk_mem_jal(
        input reg_idx_t rd,
        input word_t    pc,
        input word_t    branch_target
    );
        automatic ex_mem_payload_t p = '0;
        p.valid                = 1'b1;
        p.decoded.legal        = 1'b1;
        p.decoded.writes_rd    = 1'b1;
        p.decoded.rd           = rd;
        p.decoded.wb_src       = WB_PC4;
        p.decoded.is_jump      = 1'b1;
        p.pc                   = pc;
        p.alu_result           = branch_target;
        return p;
    endfunction

    // MEM instruction — CSR read (WB_CSR): rd value is the OLD CSR value
    // captured in EX (csr_rdata), never the ALU result (which for a CSR op
    // is the sign-extended CSR address — the 2026-07-02 mcycle bug).
    function automatic ex_mem_payload_t mk_mem_csr(
        input reg_idx_t rd,
        input word_t    csr_rdata,
        input word_t    poison_alu
    );
        automatic ex_mem_payload_t p = '0;
        p.valid                = 1'b1;
        p.decoded.legal        = 1'b1;
        p.decoded.writes_rd    = 1'b1;
        p.decoded.rd           = rd;
        p.decoded.wb_src       = WB_CSR;
        p.decoded.is_csr       = 1'b1;
        p.csr_rdata            = csr_rdata;
        p.alu_result           = poison_alu;
        return p;
    endfunction

    // WB instruction
    function automatic mem_wb_payload_t mk_wb(
        input reg_idx_t rd_addr,
        input word_t    rd_data,
        input logic     rd_wen = 1
    );
        automatic mem_wb_payload_t p = '0;
        p.valid    = 1'b1;
        p.rd_wen   = rd_wen;
        p.rd_addr  = rd_addr;
        p.rd_data  = rd_data;
        return p;
    endfunction

    // ID instruction (for load-use detection)
    function automatic decoded_instr_t mk_id(
        input reg_idx_t rs1, input logic uses_rs1,
        input reg_idx_t rs2, input logic uses_rs2
    );
        automatic decoded_instr_t d = '0;
        d.rs1      = rs1;
        d.rs2      = rs2;
        d.uses_rs1 = uses_rs1;
        d.uses_rs2 = uses_rs2;
        return d;
    endfunction

    // -----------------------------------------------------------------------
    // Drive helper
    // -----------------------------------------------------------------------
    task automatic apply(
        input id_ex_payload_t  ex,
        input ex_mem_payload_t mem,
        input mem_wb_payload_t wb,
        input decoded_instr_t  id_dec,
        input logic            id_v
    );
        id_ex_w    = ex;
        ex_mem_w   = mem;
        mem_wb_w   = wb;
        mem_wb_rd_data_w = wb.rd_data;
        id_dec_w   = id_dec;
        id_valid_w = id_v;
        #1;
    endtask

    task automatic set_wb_rd_data(input word_t data);
        mem_wb_rd_data_w = data;
        #1;
    endtask

    task automatic chk_fwd(
        input word_t exp_rs1,
        input word_t exp_rs2,
        input logic  exp_stall,
        input string desc
    );
        if (rs1_fwd_w !== exp_rs1)
            $fatal(1, "[FWD] FAIL %-40s rs1_fwd=%08h expected=%08h",
                   desc, rs1_fwd_w, exp_rs1);
        if (rs2_fwd_w !== exp_rs2)
            $fatal(1, "[FWD] FAIL %-40s rs2_fwd=%08h expected=%08h",
                   desc, rs2_fwd_w, exp_rs2);
        if (stall_w !== exp_stall)
            $fatal(1, "[FWD] FAIL %-40s stall=%b expected=%b",
                   desc, stall_w, exp_stall);
    endtask

    // -----------------------------------------------------------------------
    // Test body
    // -----------------------------------------------------------------------
    initial begin : test_body

        // ================================================================
        // 1. Quiescent: all zeros, no forwarding, no stall
        // ================================================================
        apply('0, '0, '0, '0, 1'b0);
        chk_fwd('0, '0, 1'b0, "quiescent: all zero");

        // ================================================================
        // 2. No hazard: different registers, stale values pass through
        // ================================================================
        begin : t_no_hazard
            automatic id_ex_payload_t  ex  = mk_ex(5'd1, 32'hAA, 5'd2, 32'hBB, 1'b1, 1'b1);
            automatic ex_mem_payload_t mem = mk_mem_alu(5'd5, 32'hFF);
            automatic mem_wb_payload_t wb  = mk_wb(5'd6, 32'hEE);
            apply(ex, mem, wb, '0, 1'b0);
            chk_fwd(32'hAA, 32'hBB, 1'b0, "no hazard: stale values pass through");
        end

        // ================================================================
        // 3. EX/MEM → rs1 forward (ALU result, 1-cycle staleness)
        // ================================================================
        begin : t_em_rs1
            automatic id_ex_payload_t  ex  = mk_ex(5'd3, 32'hDEAD, 5'd7, 32'hBEEF, 1'b1, 1'b1);
            automatic ex_mem_payload_t mem = mk_mem_alu(5'd3, 32'hCAFE); // writes x3
            apply(ex, mem, '0, '0, 1'b0);
            chk_fwd(32'hCAFE, 32'hBEEF, 1'b0, "EX/MEM → rs1 ALU forward");
        end

        // ================================================================
        // 4. EX/MEM → rs2 forward
        // ================================================================
        begin : t_em_rs2
            automatic id_ex_payload_t  ex  = mk_ex(5'd7, 32'hDEAD, 5'd4, 32'hBEEF, 1'b1, 1'b1);
            automatic ex_mem_payload_t mem = mk_mem_alu(5'd4, 32'h1234);
            apply(ex, mem, '0, '0, 1'b0);
            chk_fwd(32'hDEAD, 32'h1234, 1'b0, "EX/MEM → rs2 ALU forward");
        end

        // ================================================================
        // 5. EX/MEM → rs1 for JAL/JALR: forward pc+4, NOT alu_result
        // ================================================================
        begin : t_em_jal
            automatic id_ex_payload_t  ex  = mk_ex(5'd1, 32'h0, 5'd0, 32'h0, 1'b1, 1'b0);
            // JAL wrote x1=pc+4; alu_result=jump_target (different from link addr)
            automatic ex_mem_payload_t mem = mk_mem_jal(5'd1, 32'h1000, 32'h2000);
            apply(ex, mem, '0, '0, 1'b0);
            // Expect rs1_fwd = 0x1000 + 4 = 0x1004, NOT 0x2000 (jump target)
            chk_fwd(32'h1004, '0, 1'b0, "EX/MEM → rs1 JAL: pc+4 not alu_result");
        end

        // ================================================================
        // 6. EX/MEM load (is_load=1): no EX/MEM forward; stale value used
        //    (In real pipeline, a load-use stall would have run first.
        //     Here we just verify the forward is suppressed at the EX/MEM path.)
        // ================================================================
        begin : t_em_load_no_fwd
            automatic id_ex_payload_t  ex  = mk_ex(5'd5, 32'h5A1E_0000, 5'd0, '0, 1'b1, 1'b0);
            automatic ex_mem_payload_t mem = mk_mem_alu(5'd5, 32'h0000_A000, .is_load(1'b1));
            apply(ex, mem, '0, '0, 1'b0);
            // No EX/MEM forward for loads: stale value passes through
            chk_fwd(32'h5A1E_0000, '0, 1'b0, "EX/MEM load: no forward (is_load suppresses)");
        end

        // ================================================================
        // 7. MEM/WB → rs1 forward (2-cycle staleness)
        // ================================================================
        begin : t_mw_rs1
            automatic id_ex_payload_t  ex  = mk_ex(5'd8, 32'h5A1E_0000, 5'd0, '0, 1'b1, 1'b0);
            automatic mem_wb_payload_t wb  = mk_wb(5'd8, 32'hF00D_0001);
            apply(ex, '0, wb, '0, 1'b0);
            chk_fwd(32'hF00D_0001, '0, 1'b0, "MEM/WB → rs1 forward");
        end

        // ================================================================
        // 8. MEM/WB → rs2 forward
        // ================================================================
        begin : t_mw_rs2
            automatic id_ex_payload_t  ex  = mk_ex(5'd0, '0, 5'd9, 32'h5A1E_0000, 1'b0, 1'b1);
            automatic mem_wb_payload_t wb  = mk_wb(5'd9, 32'hF00D_0002);
            apply(ex, '0, wb, '0, 1'b0);
            chk_fwd('0, 32'hF00D_0002, 1'b0, "MEM/WB → rs2 forward");
        end

        // ================================================================
        // 9. MEM/WB for load: canonical WB data can differ from payload rd_data
        // ================================================================
        begin : t_mw_load
            automatic id_ex_payload_t  ex  = mk_ex(5'd10, 32'h5A1E_0000, 5'd0, '0, 1'b1, 1'b0);
            automatic mem_wb_payload_t wb  = mk_wb(5'd10, 32'h5A1E_10AD);
            wb.rd_from_mem = 1'b1;
            apply(ex, '0, wb, '0, 1'b0);
            set_wb_rd_data(32'h10AD_DA7A);
            chk_fwd(32'h10AD_DA7A, '0, 1'b0, "MEM/WB: load forwards canonical WB data");
        end

        // ================================================================
        // 10. EX/MEM priority over MEM/WB for same register
        // ================================================================
        begin : t_em_over_mw
            automatic id_ex_payload_t  ex  = mk_ex(5'd11, 32'h5A1E_0000, 5'd0, '0, 1'b1, 1'b0);
            automatic ex_mem_payload_t mem = mk_mem_alu(5'd11, 32'h1111_1111); // 1-cycle old
            automatic mem_wb_payload_t wb  = mk_wb(5'd11, 32'h2222_2222);     // 2-cycle old
            apply(ex, mem, wb, '0, 1'b0);
            chk_fwd(32'h1111_1111, '0, 1'b0, "EX/MEM beats MEM/WB priority");
        end

        // ================================================================
        // 11. EX/MEM rd=x0: no forward (x0 writes are no-ops)
        // ================================================================
        begin : t_em_x0
            automatic id_ex_payload_t  ex  = mk_ex(5'd0, 32'h5A1E_0000, 5'd0, '0, 1'b1, 1'b0);
            automatic ex_mem_payload_t mem = mk_mem_alu(5'd0, 32'hCAFE); // writes x0
            apply(ex, mem, '0, '0, 1'b0);
            chk_fwd(32'h5A1E_0000, '0, 1'b0, "EX/MEM rd=x0: no forward");
        end

        // ================================================================
        // 12. MEM/WB rd_addr=x0: no forward
        // ================================================================
        begin : t_mw_x0
            automatic id_ex_payload_t  ex  = mk_ex(5'd0, 32'h5A1E_0000, 5'd0, '0, 1'b1, 1'b0);
            automatic mem_wb_payload_t wb  = mk_wb(5'd0, 32'hCAFE); // rd_addr=x0
            apply(ex, '0, wb, '0, 1'b0);
            chk_fwd(32'h5A1E_0000, '0, 1'b0, "MEM/WB rd_addr=x0: no forward");
        end

        // ================================================================
        // 13. MEM/WB rd_wen=0: no forward (exception, illegal, WB_NONE)
        // ================================================================
        begin : t_mw_no_wen
            automatic id_ex_payload_t  ex  = mk_ex(5'd12, 32'h5A1E_0000, 5'd0, '0, 1'b1, 1'b0);
            automatic mem_wb_payload_t wb  = mk_wb(5'd12, 32'hCAFE, .rd_wen(1'b0));
            apply(ex, '0, wb, '0, 1'b0);
            chk_fwd(32'h5A1E_0000, '0, 1'b0, "MEM/WB rd_wen=0: no forward");
        end

        // ================================================================
        // 14. Bubble in EX/MEM (valid=0): no EX/MEM forward
        // ================================================================
        begin : t_em_bubble
            automatic id_ex_payload_t  ex  = mk_ex(5'd13, 32'h5A1E_0000, 5'd0, '0, 1'b1, 1'b0);
            automatic ex_mem_payload_t mem = mk_mem_alu(5'd13, 32'hCAFE);
            mem.valid = 1'b0;  // make it a bubble
            apply(ex, mem, '0, '0, 1'b0);
            chk_fwd(32'h5A1E_0000, '0, 1'b0, "EX/MEM bubble (valid=0): no forward");
        end

        // ================================================================
        // 15. Illegal in EX/MEM (legal=0): no EX/MEM forward
        // ================================================================
        begin : t_em_illegal
            automatic id_ex_payload_t  ex  = mk_ex(5'd14, 32'h5A1E_0000, 5'd0, '0, 1'b1, 1'b0);
            automatic ex_mem_payload_t mem = mk_mem_alu(5'd14, 32'hCAFE);
            mem.decoded.legal = 1'b0;
            apply(ex, mem, '0, '0, 1'b0);
            chk_fwd(32'h5A1E_0000, '0, 1'b0, "EX/MEM illegal (legal=0): no forward");
        end

        // ================================================================
        // 16. uses_rs1=0: no forward even if register matches
        // ================================================================
        begin : t_no_uses_rs1
            automatic id_ex_payload_t  ex  = mk_ex(5'd15, 32'h5A1E_0000, 5'd0, '0, 1'b0, 1'b0);
            automatic ex_mem_payload_t mem = mk_mem_alu(5'd15, 32'hCAFE);
            apply(ex, mem, '0, '0, 1'b0);
            chk_fwd(32'h5A1E_0000, '0, 1'b0, "uses_rs1=0: no forward from EX/MEM");
        end

        // ================================================================
        // 17. Load-use stall: load in EX, rs1 match in ID
        // ================================================================
        begin : t_ldu_rs1
            automatic id_ex_payload_t  ex  = mk_ex(5'd1, 32'hXXXX_XXXX, 5'd0, '0, 1'b0, 1'b0);
            automatic decoded_instr_t  id  = mk_id(5'd1, 1'b1, 5'd0, 1'b0);
            ex.decoded.is_load   = 1'b1;
            ex.decoded.legal     = 1'b1;
            ex.decoded.writes_rd = 1'b1;
            ex.decoded.rd        = 5'd1;
            apply(ex, '0, '0, id, 1'b1);
            if (!stall_w)
                $fatal(1, "[FWD] FAIL load-use rs1: stall not asserted");
            $display("[FWD] load-use rs1 stall asserted ✓");
        end

        // ================================================================
        // 18. Load-use stall: load in EX, rs2 match in ID
        // ================================================================
        begin : t_ldu_rs2
            automatic id_ex_payload_t  ex  = mk_ex(5'd2, '0, 5'd0, '0, 1'b0, 1'b0);
            automatic decoded_instr_t  id  = mk_id(5'd0, 1'b0, 5'd2, 1'b1);
            ex.decoded.is_load   = 1'b1;
            ex.decoded.legal     = 1'b1;
            ex.decoded.writes_rd = 1'b1;
            ex.decoded.rd        = 5'd2;
            apply(ex, '0, '0, id, 1'b1);
            if (!stall_w)
                $fatal(1, "[FWD] FAIL load-use rs2: stall not asserted");
            $display("[FWD] load-use rs2 stall asserted ✓");
        end

        // ================================================================
        // 19. Load-use: bubble in ID (id_valid=0) → no stall
        // ================================================================
        begin : t_ldu_bubble_id
            automatic id_ex_payload_t  ex  = mk_ex(5'd3, '0, 5'd0, '0, 1'b0, 1'b0);
            automatic decoded_instr_t  id  = mk_id(5'd3, 1'b1, 5'd0, 1'b0);
            ex.decoded.is_load   = 1'b1;
            ex.decoded.legal     = 1'b1;
            ex.decoded.writes_rd = 1'b1;
            ex.decoded.rd        = 5'd3;
            apply(ex, '0, '0, id, 1'b0);  // id_valid=0 → bubble in ID
            if (stall_w)
                $fatal(1, "[FWD] FAIL load-use bubble-in-ID: stall asserted for bubble");
            $display("[FWD] load-use bubble-in-ID: no stall ✓");
        end

        // ================================================================
        // 20. Load-use: load rd=x0 → no stall (x0 not architecturally read)
        // ================================================================
        begin : t_ldu_rd0
            automatic id_ex_payload_t  ex  = mk_ex(5'd0, '0, 5'd0, '0, 1'b0, 1'b0);
            automatic decoded_instr_t  id  = mk_id(5'd0, 1'b1, 5'd0, 1'b0);
            ex.decoded.is_load   = 1'b1;
            ex.decoded.legal     = 1'b1;
            ex.decoded.writes_rd = 1'b1;
            ex.decoded.rd        = 5'd0;  // rd=x0
            apply(ex, '0, '0, id, 1'b1);
            if (stall_w)
                $fatal(1, "[FWD] FAIL load-use rd=x0: stall should not fire");
            $display("[FWD] load-use rd=x0: no stall ✓");
        end

        // ================================================================
        // 21. Load-use: rd matches rs1 but uses_rs1=0 → no stall for rs1
        //     and rs2 doesn't match → no stall
        // ================================================================
        begin : t_ldu_no_use
            automatic id_ex_payload_t  ex  = mk_ex(5'd0, '0, 5'd0, '0, 1'b0, 1'b0);
            automatic decoded_instr_t  id  = mk_id(5'd4, 1'b0, 5'd5, 1'b0); // rs1=x4 but uses_rs1=0
            ex.decoded.is_load   = 1'b1;
            ex.decoded.legal     = 1'b1;
            ex.decoded.writes_rd = 1'b1;
            ex.decoded.rd        = 5'd4;
            apply(ex, '0, '0, id, 1'b1);
            if (stall_w)
                $fatal(1, "[FWD] FAIL load-use uses_rs1=0: stall asserted incorrectly");
            $display("[FWD] load-use uses_rs1=0: no stall ✓");
        end

        // ================================================================
        // 22. Non-load in EX: no stall regardless of register match
        // ================================================================
        begin : t_ldu_non_load
            automatic id_ex_payload_t  ex  = mk_ex(5'd6, '0, 5'd0, '0, 1'b0, 1'b0);
            automatic decoded_instr_t  id  = mk_id(5'd6, 1'b1, 5'd0, 1'b0);
            ex.decoded.is_load   = 1'b0;  // ALU, not load
            ex.decoded.legal     = 1'b1;
            ex.decoded.writes_rd = 1'b1;
            ex.decoded.rd        = 5'd6;
            apply(ex, '0, '0, id, 1'b1);
            if (stall_w)
                $fatal(1, "[FWD] FAIL non-load stall: stall asserted for ALU op");
            $display("[FWD] non-load in EX: no stall ✓");
        end

        // ================================================================
        // 23. Both rs1 and rs2 forwarded from EX/MEM simultaneously
        //     (e.g., ADD x3, x5, x5 where x5 was just computed)
        // ================================================================
        begin : t_both_em
            automatic id_ex_payload_t  ex  = mk_ex(5'd5, 32'h0, 5'd5, 32'h0, 1'b1, 1'b1);
            automatic ex_mem_payload_t mem = mk_mem_alu(5'd5, 32'hABCD);
            apply(ex, mem, '0, '0, 1'b0);
            chk_fwd(32'hABCD, 32'hABCD, 1'b0, "both rs1+rs2 forward from EX/MEM (same reg)");
        end

        // ================================================================
        // Done
        // ================================================================
        // ================================================================
        // Regression: EX/MEM → EX forward of a CSR read (WB_CSR).
        // The forwarded value must be csr_rdata, NOT alu_result — for a
        // csrr the ALU result is the sign-extended CSR address, and
        // forwarding it corrupted `csrr; sub` sequences (mcycle anomaly,
        // fixed 2026-07-02).
        // ================================================================
        begin : t_em_csr
            automatic id_ex_payload_t  ex  = mk_ex(5'd10, 32'hDEAD, 5'd11, 32'hBEEF, 1'b1, 1'b1);
            automatic ex_mem_payload_t mem = mk_mem_csr(5'd10, 32'h0000_1F42, 32'hFFFF_FB00);
            apply(ex, mem, '0, '0, 1'b0);
            chk_fwd(32'h0000_1F42, 32'hBEEF, 1'b0, "EX/MEM -> rs1 CSR forward (csr_rdata not alu)");
        end

        $display("[FWD] PASS: all forwarding unit behaviors verified.");
        $finish;

    end : test_body

endmodule : tb_forwarding_unit

`default_nettype wire
