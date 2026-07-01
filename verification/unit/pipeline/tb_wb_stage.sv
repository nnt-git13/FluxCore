// verification/unit/pipeline/tb_wb_stage.sv
//
// Self-checking testbench for rtl/core/wb_stage.sv.
//
// wb_stage is purely combinational. Test vectors drive mem_wb_i and check
// all outputs immediately after #1 propagation.
//
// Coverage:
//   Bubble (valid=0):       rd_wen_o=0, retire_o.valid=0, exception_o.valid=0
//   Normal ALU writeback:   rd_wen_o=1, rd_addr/data correct, retire_o.valid=1
//   No-writeback (branch):  rd_wen_o=0, retire_o.valid=1 (retired, no rd write)
//   No-writeback (store):   rd_wen_o=0, retire_o.valid=1
//   Illegal instruction:    rd_wen_o=0, retire_o.valid=0, exception_o.valid=1
//   Misalignment exception: rd_wen_o=0, retire_o.valid=0, exception_o.valid=1
//   ECALL:                  rd_wen_o=0, retire_o.valid=0, exception_o.valid=1
//   x0 writeback:           rd_wen_o=1, rd_addr_o=0 (regfile handles x0 guard)
//   Defensive valid gate:   payload rd_wen=1 but valid=0 → rd_wen_o=0
//   exception_pc_o:         matches mem_wb_i.pc when exception.valid=1
//   retire_o field check:   pc, instr, rd_addr, rd_data all forwarded correctly
//   retire_o.mem_valid=0:   not populated in this vertical slice
//   BRAM load bypass:       live dmem_rdata_i overrides stale mem_wb_i.rd_data
//                            for WB_MEM byte/halfword/word loads

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_wb_stage;

    // -----------------------------------------------------------------------
    // DUT wires
    // -----------------------------------------------------------------------
    mem_wb_payload_t    mem_wb_w   = '0;
    word_t              dmem_rdata_w = '0;
    reg_idx_t           rd_addr_w;
    word_t              rd_data_w;
    logic               rd_wen_w;
    retirement_event_t  retire_w;
    exception_meta_t    exc_o_w;
    word_t              exc_pc_w;

    wb_stage dut (
        .mem_wb_i      (mem_wb_w),
        .dmem_rdata_i  (dmem_rdata_w),
        .stall_i       (1'b0),
        .rd_addr_o     (rd_addr_w),
        .rd_data_o     (rd_data_w),
        .rd_wen_o      (rd_wen_w),
        .retire_o      (retire_w),
        .exception_o   (exc_o_w),
        .exception_pc_o(exc_pc_w)
    );

    // -----------------------------------------------------------------------
    // Drive helper
    // -----------------------------------------------------------------------
    task automatic apply(input mem_wb_payload_t p);
        mem_wb_w = p;
        #1;
    endtask

    function automatic instr_t mk_load_instr(
        input funct3_t  funct3,
        input reg_idx_t rd
    );
        instr_t instr;
        begin
            instr = '0;
            instr[INSTR_OPCODE_MSB:INSTR_OPCODE_LSB] = OPCODE_LOAD;
            instr[INSTR_FUNCT3_MSB:INSTR_FUNCT3_LSB] = funct3;
            instr[INSTR_RD_MSB:INSTR_RD_LSB]         = rd;
            return instr;
        end
    endfunction

    // -----------------------------------------------------------------------
    // Payload builders
    // -----------------------------------------------------------------------

    // Normal writeback: valid instruction, no exception, rd_wen=1
    function automatic mem_wb_payload_t mk_wb(
        input word_t    pc,
        input instr_t   instr,
        input reg_idx_t rd_addr,
        input word_t    rd_data
    );
        automatic mem_wb_payload_t p = '0;
        p.valid     = 1'b1;
        p.pc        = pc;
        p.instr     = instr;
        p.rd_wen    = 1'b1;
        p.rd_addr   = rd_addr;
        p.rd_data   = rd_data;
        // exception defaults to '0 (valid=0)
        return p;
    endfunction

    function automatic mem_wb_payload_t mk_load_wb(
        input word_t    pc,
        input funct3_t  funct3,
        input reg_idx_t rd_addr,
        input word_t    stale_rd_data,
        input logic [1:0] byte_off
    );
        automatic mem_wb_payload_t p = mk_wb(pc, mk_load_instr(funct3, rd_addr), rd_addr, stale_rd_data);
        p.rd_from_mem  = 1'b1;
        p.mem_byte_off = byte_off;
        return p;
    endfunction

    // No-writeback: valid instruction, no rd write (branch, store)
    function automatic mem_wb_payload_t mk_nowb(
        input word_t  pc,
        input instr_t instr
    );
        automatic mem_wb_payload_t p = '0;
        p.valid  = 1'b1;
        p.pc     = pc;
        p.instr  = instr;
        p.rd_wen = 1'b0;
        return p;
    endfunction

    // Exception: illegal instruction, load fault, etc.
    function automatic mem_wb_payload_t mk_exc(
        input word_t      pc,
        input instr_t     instr,
        input exc_cause_e cause,
        input word_t      tval
    );
        automatic mem_wb_payload_t p = '0;
        p.valid           = 1'b1;
        p.pc              = pc;
        p.instr           = instr;
        p.rd_wen          = 1'b0;  // always suppressed for exceptions
        p.exception.valid = 1'b1;
        p.exception.cause = cause;
        p.exception.tval  = tval;
        return p;
    endfunction

    // -----------------------------------------------------------------------
    // Check helpers
    // -----------------------------------------------------------------------
    task automatic chk(
        input logic  exp_rd_wen,
        input word_t exp_rd_data,
        input logic  exp_retire,
        input logic  exp_exc_valid,
        input string desc
    );
        if (rd_wen_w !== exp_rd_wen)
            $fatal(1, "[WB] FAIL %-40s rd_wen=%b expected=%b",
                   desc, rd_wen_w, exp_rd_wen);
        if (exp_rd_wen && rd_data_w !== exp_rd_data)
            $fatal(1, "[WB] FAIL %-40s rd_data=%08h expected=%08h",
                   desc, rd_data_w, exp_rd_data);
        if (retire_w.valid !== exp_retire)
            $fatal(1, "[WB] FAIL %-40s retire.valid=%b expected=%b",
                   desc, retire_w.valid, exp_retire);
        if (exc_o_w.valid !== exp_exc_valid)
            $fatal(1, "[WB] FAIL %-40s exception_o.valid=%b expected=%b",
                   desc, exc_o_w.valid, exp_exc_valid);
    endtask

    // -----------------------------------------------------------------------
    // Main test
    // -----------------------------------------------------------------------
    initial begin : test_body

        // ================================================================
        // 1. Bubble: all outputs should be inactive
        // ================================================================
        apply('0);
        if (rd_wen_w !== 1'b0)
            $fatal(1, "[WB] FAIL bubble: rd_wen_o should be 0");
        if (retire_w.valid !== 1'b0)
            $fatal(1, "[WB] FAIL bubble: retire_o.valid should be 0");
        if (exc_o_w.valid !== 1'b0)
            $fatal(1, "[WB] FAIL bubble: exception_o.valid should be 0");
        $display("[WB] bubble: all outputs inactive ✓");

        // ================================================================
        // 2. Normal ALU writeback (ADD x3, x1, x2)
        // ================================================================
        apply(mk_wb(32'h1000, 32'h00208133, 5'd3, 32'h0000_0042));
        chk(1'b1, 32'h0000_0042, 1'b1, 1'b0, "ALU writeback x3=0x42");
        if (rd_addr_w !== 5'd3)
            $fatal(1, "[WB] FAIL ALU writeback: rd_addr_o=%0d expected 3", rd_addr_w);
        if (retire_w.pc !== 32'h1000)
            $fatal(1, "[WB] FAIL ALU writeback: retire_o.pc=%08h expected 0x1000", retire_w.pc);
        if (retire_w.rd_addr !== 5'd3)
            $fatal(1, "[WB] FAIL ALU writeback: retire_o.rd_addr=%0d expected 3", retire_w.rd_addr);
        if (retire_w.rd_data !== 32'h0000_0042)
            $fatal(1, "[WB] FAIL ALU writeback: retire_o.rd_data=%08h", retire_w.rd_data);
        if (retire_w.rd_wen !== 1'b1)
            $fatal(1, "[WB] FAIL ALU writeback: retire_o.rd_wen should be 1");
        if (retire_w.mem_valid !== 1'b0)
            $fatal(1, "[WB] FAIL ALU writeback: retire_o.mem_valid should be 0");
        if (retire_w.thread_id !== '0)
            $fatal(1, "[WB] FAIL ALU writeback: retire_o.thread_id should be 0");
        $display("[WB] ALU writeback: rd, retire, fields ✓");

        // ================================================================
        // 3. Large positive and large negative writeback values
        // ================================================================
        apply(mk_wb(32'h2000, 32'h00000013, 5'd7, 32'hFFFF_FFFF));
        chk(1'b1, 32'hFFFF_FFFF, 1'b1, 1'b0, "writeback all-ones");

        apply(mk_wb(32'h2004, 32'h00000013, 5'd15, 32'h8000_0000));
        chk(1'b1, 32'h8000_0000, 1'b1, 1'b0, "writeback MSB-set");

        // ================================================================
        // 4. x0 writeback: rd_wen_o=1, rd_addr_o=0
        //    The regfile independently ignores writes to x0.
        //    wb_stage should NOT suppress it — that is the regfile's job.
        // ================================================================
        apply(mk_wb(32'h3000, 32'h00000013, 5'd0, 32'hDEAD_BEEF));
        if (rd_wen_w !== 1'b1)
            $fatal(1, "[WB] FAIL x0 writeback: rd_wen_o should be 1 (regfile gates x0)");
        if (rd_addr_w !== 5'd0)
            $fatal(1, "[WB] FAIL x0 writeback: rd_addr_o should be 0");
        if (retire_w.valid !== 1'b1)
            $fatal(1, "[WB] FAIL x0 writeback: retire_o.valid should be 1");
        $display("[WB] x0 writeback: passes rd_wen=1 to regfile (x0 guard in regfile) ✓");

        // ================================================================
        // 5. No-writeback instruction: branch (BEQ)
        //    retire_o.valid=1 (instruction retired), rd_wen_o=0
        // ================================================================
        apply(mk_nowb(32'h4000, 32'h00208063));   // BEQ x1, x2, +0
        chk(1'b0, '0, 1'b1, 1'b0, "branch no-writeback: retired, rd_wen=0");
        if (retire_w.rd_wen !== 1'b0)
            $fatal(1, "[WB] FAIL branch: retire_o.rd_wen should be 0");
        $display("[WB] branch: retired, no rd write ✓");

        // ================================================================
        // 6. No-writeback: store (SW)
        // ================================================================
        apply(mk_nowb(32'h5000, 32'h0020A023));   // SW x2, 0(x1)
        chk(1'b0, '0, 1'b1, 1'b0, "store no-writeback: retired, rd_wen=0");
        $display("[WB] store: retired, no rd write ✓");

        // ================================================================
        // 7. Illegal instruction exception
        //    rd_wen_o=0, retire_o.valid=0, exception_o.valid=1
        //    exception_pc_o = faulting PC
        // ================================================================
        apply(mk_exc(32'h6000, 32'hFFFF_FFFF,
                     EXC_ILLEGAL_INSTRUCTION, 32'hFFFF_FFFF));
        chk(1'b0, '0, 1'b0, 1'b1, "illegal instr exception");
        if (exc_o_w.cause !== EXC_ILLEGAL_INSTRUCTION)
            $fatal(1, "[WB] FAIL illegal: exc cause=%0d expected EXC_ILLEGAL_INSTRUCTION",
                   int'(exc_o_w.cause));
        if (exc_o_w.tval !== 32'hFFFF_FFFF)
            $fatal(1, "[WB] FAIL illegal: tval=%08h expected 0xFFFFFFFF", exc_o_w.tval);
        if (exc_pc_w !== 32'h6000)
            $fatal(1, "[WB] FAIL illegal: exception_pc_o=%08h expected 0x6000", exc_pc_w);
        $display("[WB] illegal: exception forwarded, pc correct ✓");

        // ================================================================
        // 8. Load misalignment exception
        // ================================================================
        apply(mk_exc(32'h7004, 32'h00082503,   // LW x10, 2(x16) — misaligned
                     EXC_LOAD_ADDR_MISALIGNED, 32'h7006));
        chk(1'b0, '0, 1'b0, 1'b1, "LW misalign exception");
        if (exc_o_w.cause !== EXC_LOAD_ADDR_MISALIGNED)
            $fatal(1, "[WB] FAIL LW misalign: cause=%0d", int'(exc_o_w.cause));
        if (exc_o_w.tval !== 32'h7006)
            $fatal(1, "[WB] FAIL LW misalign: tval=%08h expected 0x7006", exc_o_w.tval);
        if (exc_pc_w !== 32'h7004)
            $fatal(1, "[WB] FAIL LW misalign: pc=%08h expected 0x7004", exc_pc_w);
        $display("[WB] load misalign: exception forwarded ✓");

        // ================================================================
        // 9. Store misalignment exception
        // ================================================================
        apply(mk_exc(32'h8000, 32'h0020B223,   // SH — misaligned
                     EXC_STORE_ADDR_MISALIGNED, 32'h8001));
        chk(1'b0, '0, 1'b0, 1'b1, "SH misalign exception");
        if (exc_o_w.cause !== EXC_STORE_ADDR_MISALIGNED)
            $fatal(1, "[WB] FAIL SH misalign: cause=%0d", int'(exc_o_w.cause));
        $display("[WB] store misalign: exception forwarded ✓");

        // ================================================================
        // 10. ECALL: does not retire, exception_o.valid=1 with EXC_ECALL_M
        // ================================================================
        apply(mk_exc(32'h9000, 32'h00000073,   // ECALL opcode
                     EXC_ECALL_M, 32'h0));
        chk(1'b0, '0, 1'b0, 1'b1, "ECALL: no retire, exception raised");
        if (exc_o_w.cause !== EXC_ECALL_M)
            $fatal(1, "[WB] FAIL ECALL: cause=%0d expected EXC_ECALL_M", int'(exc_o_w.cause));
        if (exc_pc_w !== 32'h9000)
            $fatal(1, "[WB] FAIL ECALL: pc=%08h expected 0x9000", exc_pc_w);
        $display("[WB] ECALL: trapped, not retired ✓");

        // ================================================================
        // 11. Defensive valid gate: rd_wen=1 in payload but valid=0
        //     A bubble where rd_wen was set by accident — wb_stage must
        //     gate on valid so no spurious regfile write occurs.
        // ================================================================
        begin : t_defgate
            automatic mem_wb_payload_t p = mk_wb(32'hA000, 32'h1, 5'd8, 32'hCAFE);
            p.valid = 1'b0;  // mark as bubble post-construction
            apply(p);
            if (rd_wen_w !== 1'b0)
                $fatal(1, "[WB] FAIL defensive gate: rd_wen_o=1 for bubble with rd_wen=1 in payload");
            if (retire_w.valid !== 1'b0)
                $fatal(1, "[WB] FAIL defensive gate: retire_o.valid=1 for bubble");
            $display("[WB] defensive valid gate: rd_wen_o=0 for bubble ✓");
        end

        // ================================================================
        // 12. retire_o.instr field forwarded correctly
        // ================================================================
        begin : t_instr_fwd
            automatic instr_t enc = 32'hDEAD_C0DE;
            apply(mk_wb(32'hB000, enc, 5'd1, 32'h1));
            if (retire_w.instr !== enc)
                $fatal(1, "[WB] FAIL instr fwd: retire_o.instr=%08h expected %08h",
                       retire_w.instr, enc);
            $display("[WB] retire_o.instr forwarded ✓");
        end

        // ================================================================
        // 13. BRAM load bypass: live dmem_rdata_i overrides stale rd_data
        // ================================================================
        dmem_rdata_w = 32'h1122_3344;
        apply(mk_load_wb(32'hC000, FUNCT3_LW, 5'd4, 32'hDEAD_BEEF, 2'd0));
        chk(1'b1, 32'h1122_3344, 1'b1, 1'b0, "LW uses live dmem_rdata");
        if (retire_w.rd_data !== 32'h1122_3344)
            $fatal(1, "[WB] FAIL LW bypass: retire rd_data=%08h", retire_w.rd_data);

        dmem_rdata_w = 32'h80AA_7F01;
        apply(mk_load_wb(32'hC004, FUNCT3_LB, 5'd5, 32'hDEAD_BEEF, 2'd3));
        chk(1'b1, 32'hFFFF_FF80, 1'b1, 1'b0, "LB sign-extends live byte");

        apply(mk_load_wb(32'hC008, FUNCT3_LBU, 5'd6, 32'hDEAD_BEEF, 2'd2));
        chk(1'b1, 32'h0000_00AA, 1'b1, 1'b0, "LBU zero-extends live byte");

        dmem_rdata_w = 32'h8001_7FFF;
        apply(mk_load_wb(32'hC00C, FUNCT3_LH, 5'd7, 32'hDEAD_BEEF, 2'd2));
        chk(1'b1, 32'hFFFF_8001, 1'b1, 1'b0, "LH sign-extends live halfword");

        apply(mk_load_wb(32'hC010, FUNCT3_LHU, 5'd8, 32'hDEAD_BEEF, 2'd0));
        chk(1'b1, 32'h0000_7FFF, 1'b1, 1'b0, "LHU zero-extends live halfword");
        dmem_rdata_w = '0;
        $display("[WB] BRAM load bypass: live data selected and extended ✓");

        // ================================================================
        // Done
        // ================================================================
        $display("[WB] PASS: all writeback stage behaviors verified.");
        $finish;

    end : test_body

endmodule : tb_wb_stage

`default_nettype wire
