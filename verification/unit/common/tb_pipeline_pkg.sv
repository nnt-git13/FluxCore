// verification/unit/common/tb_pipeline_pkg.sv
//
// Self-checking testbench for rtl/common/pipeline_pkg.sv.
//
// Verifies:
//   1. All four payload types are accessible with named field syntax.
//   2. Packed widths match the arithmetic in the package comment:
//        if_id_payload_t  =  65 bits
//        id_ex_payload_t  = 256 bits  (was 239; +17 from decoded_instr_t wb_src+CSR fields)
//        ex_mem_payload_t = 321 bits  (was 289; +32 for csr_rdata field)
//        mem_wb_payload_t = 144 bits  (+3 for BRAM load metadata, +1 is_irq)
//   3. The `valid` field is the MSB of each payload (packed struct, MSB first).
//   4. Setting valid=0 produces a bit-vector whose MSB is 0.
//   5. A zero-initialised payload has valid=0 (bubble representation).
//   6. Field round-trips: write a value to a field and read it back.
//
// Pass/fail:
//   $fatal(1, ...) on any mismatch.
//   Prints "[PIPELINE-PKG-TEST] PASS" and $finish on success.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_pipeline_pkg;

    // -----------------------------------------------------------------------
    // Expected widths — computed from the constituent types
    // -----------------------------------------------------------------------
    // exception_meta_t : 1 + 1 + EXC_CAUSE_W + XLEN = 1 + 1 + 4 + 32 = 38  (valid, is_irq, cause, tval)
    // decoded_instr_t  : 128  (was 127; +1 from alu_op_e 4→5 bits for RV32M+XFlux ops)
    //
    // if_id   : 1 + 32 + 32                               = 65
    // id_ex   : 1 + 32 + 32 + 128 + 32 + 32                   = 257
    // ex_mem  : 1 + 32 + 32 + 128 + 32 + 32 + 1 + 32 + 32   = 322 (csr_rdata +32)
    // mem_wb  : 1 + 32 + 32 + 1 + REG_IDX_W + 32 + 1 + 2 + 37 = 143

    localparam int EXCEPTION_META_W =
        1 + 1 + EXC_CAUSE_W + XLEN;   // valid + is_irq + cause + tval   // 37

    localparam int DECODED_W = $bits(decoded_instr_t);  // 127

    localparam int EXP_IF_ID_W   = 1 + XLEN + INSTR_W;
    localparam int EXP_ID_EX_W   = 1 + XLEN + INSTR_W + DECODED_W + XLEN + XLEN;
    localparam int EXP_EX_MEM_W  = 1 + XLEN + INSTR_W + DECODED_W + XLEN + XLEN + 1 + XLEN + XLEN; // +XLEN for csr_rdata
    localparam int EXP_MEM_WB_W  = 1 + XLEN + INSTR_W + 1 + REG_IDX_W + XLEN + 1 + 2 + EXCEPTION_META_W;

    // -----------------------------------------------------------------------
    // Helper
    // -----------------------------------------------------------------------
    task automatic check_eq(input string name, input int actual, input int expected);
        if (actual !== expected)
            $fatal(1, "[PIPELINE-PKG-TEST] FAIL %s = %0d, expected %0d",
                   name, actual, expected);
    endtask

    // -----------------------------------------------------------------------
    // Main test
    // -----------------------------------------------------------------------
    initial begin : test_body

        // ================================================================
        // 1. Packed width checks
        // ================================================================
        check_eq("$bits(if_id_payload_t)",  $bits(if_id_payload_t),  EXP_IF_ID_W);
        check_eq("$bits(id_ex_payload_t)",  $bits(id_ex_payload_t),  EXP_ID_EX_W);
        check_eq("$bits(ex_mem_payload_t)", $bits(ex_mem_payload_t), EXP_EX_MEM_W);
        check_eq("$bits(mem_wb_payload_t)", $bits(mem_wb_payload_t), EXP_MEM_WB_W);

        // Confirm computed values against constants in the package comment
        check_eq("if_id_payload_t width",   EXP_IF_ID_W,   65);
        check_eq("id_ex_payload_t width",   EXP_ID_EX_W,  258);
        check_eq("ex_mem_payload_t width",  EXP_EX_MEM_W, 323);
        check_eq("mem_wb_payload_t width",  EXP_MEM_WB_W, 144);

        // ================================================================
        // 2. IF/ID payload: field accessibility and bubble invariant
        // ================================================================
        begin : check_if_id
            automatic if_id_payload_t p;

            // Zero-init → valid = 0 (bubble)
            p = '0;
            if (p.valid !== 1'b0)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL if_id: zeroed payload has valid=1");
            if (p.pc !== '0)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL if_id: zeroed pc not 0");
            if (p.instr !== '0)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL if_id: zeroed instr not 0");

            // Assign fields
            p.valid = 1'b1;
            p.pc    = 32'h0000_1000;
            p.instr = 32'h00500093;  // ADDI x1, x0, 5

            if (p.valid !== 1'b1)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL if_id valid readback");
            if (p.pc !== 32'h0000_1000)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL if_id pc readback");
            if (p.instr !== 32'h00500093)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL if_id instr readback");

            // valid is the MSB of the packed struct
            if (p[EXP_IF_ID_W-1] !== 1'b1)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL if_id valid is not MSB");
        end

        // ================================================================
        // 3. ID/EX payload: field accessibility
        // ================================================================
        begin : check_id_ex
            automatic id_ex_payload_t p;

            p = '0;
            if (p.valid !== 1'b0)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL id_ex: zeroed valid not 0");

            // Set a subset of fields and verify round-trips
            p.valid             = 1'b1;
            p.pc                = 32'h0000_2000;
            p.instr             = 32'h002081B3;  // ADD x3, x1, x2
            p.decoded.legal     = 1'b1;
            p.decoded.op_class  = OPCLASS_ALU;
            p.decoded.alu_op    = ALU_ADD;
            p.decoded.wb_src    = WB_ALU;
            p.decoded.uses_rs1  = 1'b1;
            p.decoded.uses_rs2  = 1'b1;
            p.decoded.writes_rd = 1'b1;
            p.decoded.rs1       = 5'd1;
            p.decoded.rs2       = 5'd2;
            p.decoded.rd        = 5'd3;
            p.decoded.imm       = 32'h0;
            p.rs1_data          = 32'hAAAA_AAAA;
            p.rs2_data          = 32'h5555_5555;

            if (p.valid !== 1'b1)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL id_ex valid readback");
            if (p.decoded.alu_op !== ALU_ADD)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL id_ex decoded.alu_op readback");
            if (p.decoded.rd !== 5'd3)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL id_ex decoded.rd readback");
            if (p.rs1_data !== 32'hAAAA_AAAA)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL id_ex rs1_data readback");
            if (p.rs2_data !== 32'h5555_5555)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL id_ex rs2_data readback");

            // Bubble: valid=0 passes through cleanly
            p = '0;
            if (p.valid !== 1'b0 || p.decoded.legal !== 1'b0)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL id_ex: bubble not zero");

            // valid is the MSB
            p.valid = 1'b1;
            if (p[EXP_ID_EX_W-1] !== 1'b1)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL id_ex valid is not MSB");
        end

        // ================================================================
        // 4. EX/MEM payload: branch_taken and branch_target fields
        // ================================================================
        begin : check_ex_mem
            automatic ex_mem_payload_t p;

            p = '0;
            if (p.valid !== 1'b0)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL ex_mem: zeroed valid not 0");

            // ALU result for a store instruction
            p.valid            = 1'b1;
            p.pc               = 32'h0000_3000;
            p.instr            = 32'h00102423;  // SW x1, 8(x0)
            p.decoded.legal    = 1'b1;
            p.decoded.op_class = OPCLASS_STORE;
            p.decoded.alu_op   = ALU_ADD;
            p.decoded.mem_op   = MEM_SW;
            p.decoded.is_store = 1'b1;
            p.alu_result       = 32'h0000_0008;  // effective address = 0+8
            p.rs2_data         = 32'hDEAD_BEEF;  // data to store
            p.branch_taken     = 1'b0;
            p.branch_target    = 32'h0;

            if (p.alu_result !== 32'h8)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL ex_mem alu_result readback");
            if (p.rs2_data !== 32'hDEAD_BEEF)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL ex_mem rs2_data readback");
            if (p.decoded.is_store !== 1'b1)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL ex_mem is_store readback");

            // csr_rdata field round-trip
            p = '0;
            p.valid      = 1'b1;
            p.decoded.is_csr  = 1'b1;
            p.decoded.csr_addr = 12'h300;
            p.csr_rdata  = 32'hDEAD_BEEF;
            if (p.csr_rdata !== 32'hDEAD_BEEF)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL ex_mem csr_rdata readback");

            // Branch taken: typical case
            p = '0;
            p.valid            = 1'b1;
            p.decoded.legal    = 1'b1;
            p.decoded.op_class = OPCLASS_BRANCH;
            p.decoded.is_branch= 1'b1;
            p.branch_taken     = 1'b1;
            p.branch_target    = 32'h0000_4000;

            if (p.branch_taken !== 1'b1)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL ex_mem branch_taken readback");
            if (p.branch_target !== 32'h0000_4000)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL ex_mem branch_target readback");

            // valid is the MSB
            p = '0;
            p.valid = 1'b1;
            if (p[EXP_EX_MEM_W-1] !== 1'b1)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL ex_mem valid is not MSB");
        end

        // ================================================================
        // 5. MEM/WB payload: writeback and exception fields
        // ================================================================
        begin : check_mem_wb
            automatic mem_wb_payload_t p;

            p = '0;
            if (p.valid !== 1'b0)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL mem_wb: zeroed valid not 0");

            // Normal writeback: ALU result
            p.valid     = 1'b1;
            p.pc        = 32'h0000_5000;
            p.instr     = 32'h00208133;  // ADD x2, x1, x2
            p.rd_wen    = 1'b1;
            p.rd_addr   = 5'd2;
            p.rd_data   = 32'h0000_0042;
            p.rd_from_mem  = 1'b1;
            p.mem_byte_off = 2'd3;
            p.exception = '0;

            if (p.rd_wen !== 1'b1)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL mem_wb rd_wen readback");
            if (p.rd_addr !== 5'd2)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL mem_wb rd_addr readback");
            if (p.rd_data !== 32'h42)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL mem_wb rd_data readback");
            if (p.rd_from_mem !== 1'b1)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL mem_wb rd_from_mem readback");
            if (p.mem_byte_off !== 2'd3)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL mem_wb mem_byte_off readback");
            if (p.exception.valid !== 1'b0)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL mem_wb exception.valid spurious");

            // Exception case: ECALL
            p = '0;
            p.valid              = 1'b1;
            p.rd_wen             = 1'b0;
            p.exception.valid    = 1'b1;
            p.exception.cause    = EXC_ECALL_M;
            p.exception.tval     = 32'h0;

            if (!p.exception.valid)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL mem_wb ECALL exception.valid");
            if (p.exception.cause !== EXC_ECALL_M)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL mem_wb ECALL exception.cause");
            if (p.rd_wen !== 1'b0)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL mem_wb ECALL rd_wen should be 0");

            // valid is the MSB
            p = '0;
            p.valid = 1'b1;
            if (p[EXP_MEM_WB_W-1] !== 1'b1)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL mem_wb valid is not MSB");
        end

        // ================================================================
        // 6. Bubble invariant: a fully-zeroed payload must have valid=0
        //    and be passable through the pipeline without side effects.
        // ================================================================
        begin : check_bubble
            automatic if_id_payload_t   p_if_id   = '0;
            automatic id_ex_payload_t   p_id_ex   = '0;
            automatic ex_mem_payload_t  p_ex_mem  = '0;
            automatic mem_wb_payload_t  p_mem_wb  = '0;

            if (p_if_id.valid  || p_id_ex.valid  ||
                p_ex_mem.valid || p_mem_wb.valid)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL bubble: zeroed payload has valid=1");

            // A bubble in id_ex should not indicate any register write
            if (p_id_ex.decoded.writes_rd)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL bubble: decoded.writes_rd set in bubble");

            // A bubble in mem_wb should not trigger register writeback
            if (p_mem_wb.rd_wen)
                $fatal(1, "[PIPELINE-PKG-TEST] FAIL bubble: mem_wb rd_wen set in bubble");
        end

        // ================================================================
        // Done
        // ================================================================
        $display("[PIPELINE-PKG-TEST] PASS: all pipeline payload types verified.");
        $display("[PIPELINE-PKG-TEST]   if_id=%0d  id_ex=%0d  ex_mem=%0d  mem_wb=%0d bits",
                 EXP_IF_ID_W, EXP_ID_EX_W, EXP_EX_MEM_W, EXP_MEM_WB_W);
        $finish;

    end : test_body

endmodule : tb_pipeline_pkg

`default_nettype wire
