// verification/unit/pipeline/tb_id_ex_reg.sv
//
// Self-checking testbench for rtl/pipeline/id_ex_reg.sv.
//
// Exercises the same contract as tb_if_id_reg but with the wider
// id_ex_payload_t type (239 bits). Key additional check: decoded_instr_t
// fields inside the payload survive a round-trip through the register.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_id_ex_reg;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic           rst_w   = 1'b1;
    logic           stall_w = 1'b0;
    logic           flush_w = 1'b0;
    id_ex_payload_t d_w     = '0;
    id_ex_payload_t q_w;

    id_ex_reg dut (
        .clk    (clk),
        .rst    (rst_w),
        .stall_i(stall_w),
        .flush_i(flush_w),
        .d_i    (d_w),
        .q_o    (q_w)
    );

    task automatic tick_check(
        input id_ex_payload_t expected,
        input string          desc
    );
        @(posedge clk); #1;
        if (q_w !== expected)
            $fatal(1, "[ID-EX-REG] FAIL %-35s", desc);
    endtask

    // Build a payload representing ADD x3, x1, x2
    function automatic id_ex_payload_t make_add_payload(input word_t pc);
        automatic id_ex_payload_t p = '0;
        p.valid             = 1'b1;
        p.pc                = pc;
        p.instr             = 32'h002081B3;   // ADD x3, x1, x2
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
        p.rs1_data          = 32'hAAAA_AAAA;
        p.rs2_data          = 32'h5555_5555;
        return p;
    endfunction

    // Build a payload representing BEQ x1, x2, target
    function automatic id_ex_payload_t make_branch_payload(input word_t pc, input word_t imm);
        automatic id_ex_payload_t p = '0;
        p.valid              = 1'b1;
        p.pc                 = pc;
        p.instr              = 32'h00208063;
        p.decoded.legal      = 1'b1;
        p.decoded.op_class   = OPCLASS_BRANCH;
        p.decoded.branch_op  = BRANCH_EQ;
        p.decoded.uses_rs1   = 1'b1;
        p.decoded.uses_rs2   = 1'b1;
        p.decoded.is_branch  = 1'b1;
        p.decoded.rs1        = 5'd1;
        p.decoded.rs2        = 5'd2;
        p.decoded.imm        = imm;
        p.rs1_data           = 32'h7;
        p.rs2_data           = 32'h7;
        return p;
    endfunction

    localparam id_ex_payload_t BUBBLE = '0;

    initial begin : test_body

        // 1. Reset
        rst_w = 1'b1;
        d_w   = make_add_payload(32'h1000);
        tick_check(BUBBLE, "rst: output zeroed");
        tick_check(BUBBLE, "rst: stays zero");

        // 2. Normal capture
        rst_w = 1'b0;
        d_w   = make_add_payload(32'h0000_1000);
        tick_check(d_w, "capture: ADD payload round-trip");

        // Verify specific fields survived
        if (q_w.decoded.alu_op !== ALU_ADD)
            $fatal(1, "[ID-EX-REG] FAIL decoded.alu_op corrupted after capture");
        if (q_w.decoded.rd !== 5'd3)
            $fatal(1, "[ID-EX-REG] FAIL decoded.rd corrupted after capture");
        if (q_w.rs1_data !== 32'hAAAA_AAAA)
            $fatal(1, "[ID-EX-REG] FAIL rs1_data corrupted after capture");
        if (q_w.rs2_data !== 32'h5555_5555)
            $fatal(1, "[ID-EX-REG] FAIL rs2_data corrupted after capture");

        // 3. Branch payload
        d_w = make_branch_payload(32'h0000_1004, 32'hFFFF_FFD8); // imm=-40
        tick_check(d_w, "capture: BEQ payload round-trip");

        if (q_w.decoded.branch_op !== BRANCH_EQ)
            $fatal(1, "[ID-EX-REG] FAIL decoded.branch_op corrupted");
        if (q_w.decoded.is_branch !== 1'b1)
            $fatal(1, "[ID-EX-REG] FAIL decoded.is_branch corrupted");
        if (q_w.decoded.imm !== 32'hFFFF_FFD8)
            $fatal(1, "[ID-EX-REG] FAIL decoded.imm corrupted");

        // 4. Stall hold
        begin : t_stall
            automatic id_ex_payload_t held = d_w;
            stall_w = 1'b1;
            d_w     = make_add_payload(32'h0000_1008);
            tick_check(held, "stall: hold cycle 1");
            d_w = make_add_payload(32'h0000_100C);
            tick_check(held, "stall: hold cycle 2");
            stall_w = 1'b0;
            tick_check(d_w, "stall release: captures d_i");
        end

        // 5. Flush to bubble
        d_w     = make_add_payload(32'h0000_2000);
        flush_w = 1'b1;
        tick_check(BUBBLE, "flush: bubble inserted");
        if (q_w.decoded.writes_rd !== 1'b0)
            $fatal(1, "[ID-EX-REG] FAIL flush: decoded.writes_rd set in bubble");

        flush_w = 1'b0;
        d_w     = make_add_payload(32'h0000_2004);
        tick_check(d_w, "post-flush: capture resumes");

        // 6. Flush beats stall
        begin : t_flush_beats_stall
            stall_w = 1'b1;
            flush_w = 1'b1;
            d_w     = make_add_payload(32'hDEAD_0000);
            tick_check(BUBBLE, "flush beats stall");
            stall_w = 1'b0;
            flush_w = 1'b0;
        end

        // 7. Illegal instruction (exception in decoded)
        begin : t_illegal
            automatic id_ex_payload_t p = '0;
            p.valid                  = 1'b1;
            p.pc                     = 32'h0000_3000;
            p.instr                  = 32'hFFFF_FFFF;
            p.decoded.legal          = 1'b0;
            p.decoded.exception.valid= 1'b1;
            p.decoded.exception.cause= EXC_ILLEGAL_INSTRUCTION;
            p.decoded.exception.tval = 32'hFFFF_FFFF;
            d_w = p;
            tick_check(d_w, "illegal instr payload round-trip");
            if (q_w.decoded.exception.cause !== EXC_ILLEGAL_INSTRUCTION)
                $fatal(1, "[ID-EX-REG] FAIL exception.cause corrupted");
        end

        $display("[ID-EX-REG] PASS: all behavioral contracts verified.");
        $finish;

    end : test_body

endmodule : tb_id_ex_reg

`default_nettype wire
