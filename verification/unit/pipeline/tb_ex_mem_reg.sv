// verification/unit/pipeline/tb_ex_mem_reg.sv
//
// Self-checking testbench for rtl/pipeline/ex_mem_reg.sv.
//
// Key additional checks beyond the basic contract:
//   - branch_taken and branch_target survive round-trip
//   - alu_result (store address) and rs2_data (store data) survive
//   - A bubble produced by flush has branch_taken=0 (no spurious redirect)

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_ex_mem_reg;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic            rst_w   = 1'b1;
    logic            stall_w = 1'b0;
    logic            flush_w = 1'b0;
    ex_mem_payload_t d_w     = '0;
    ex_mem_payload_t q_w;

    ex_mem_reg dut (
        .clk    (clk),
        .rst    (rst_w),
        .stall_i(stall_w),
        .flush_i(flush_w),
        .d_i    (d_w),
        .q_o    (q_w)
    );

    task automatic tick_check(
        input ex_mem_payload_t expected,
        input string           desc
    );
        @(posedge clk); #1;
        if (q_w !== expected)
            $fatal(1, "[EX-MEM-REG] FAIL %-35s", desc);
    endtask

    function automatic ex_mem_payload_t make_alu_payload(
        input word_t pc,
        input word_t alu_result,
        input reg_idx_t rd
    );
        automatic ex_mem_payload_t p = '0;
        p.valid             = 1'b1;
        p.pc                = pc;
        p.instr             = 32'h00208133;   // ADD x2,x1,x2
        p.decoded.legal     = 1'b1;
        p.decoded.op_class  = OPCLASS_ALU;
        p.decoded.alu_op    = ALU_ADD;
        p.decoded.wb_src    = WB_ALU;
        p.decoded.writes_rd = 1'b1;
        p.decoded.rd        = rd;
        p.alu_result        = alu_result;
        p.rs2_data          = 32'h0;
        p.branch_taken      = 1'b0;
        p.branch_target     = 32'h0;
        return p;
    endfunction

    function automatic ex_mem_payload_t make_branch_payload(
        input word_t  pc,
        input logic   taken,
        input word_t  target
    );
        automatic ex_mem_payload_t p = '0;
        p.valid              = 1'b1;
        p.pc                 = pc;
        p.instr              = 32'h00208063;
        p.decoded.legal      = 1'b1;
        p.decoded.op_class   = OPCLASS_BRANCH;
        p.decoded.is_branch  = 1'b1;
        p.branch_taken       = taken;
        p.branch_target      = target;
        return p;
    endfunction

    function automatic ex_mem_payload_t make_store_payload(
        input word_t pc,
        input word_t addr,
        input word_t data
    );
        automatic ex_mem_payload_t p = '0;
        p.valid             = 1'b1;
        p.pc                = pc;
        p.instr             = 32'h00102423;   // SW x1, 8(x0)
        p.decoded.legal     = 1'b1;
        p.decoded.op_class  = OPCLASS_STORE;
        p.decoded.mem_op    = MEM_SW;
        p.decoded.is_store  = 1'b1;
        p.alu_result        = addr;   // effective address
        p.rs2_data          = data;   // store data
        p.branch_taken      = 1'b0;
        p.branch_target     = 32'h0;
        return p;
    endfunction

    localparam ex_mem_payload_t BUBBLE = '0;

    initial begin : test_body

        // 1. Reset
        rst_w = 1'b1;
        d_w   = make_alu_payload(32'h1000, 32'hDEAD, 5'd1);
        tick_check(BUBBLE, "rst: output zeroed");

        // 2. ALU result capture
        rst_w = 1'b0;
        d_w   = make_alu_payload(32'h0000_1000, 32'hCAFE_BABE, 5'd7);
        tick_check(d_w, "capture: ALU payload");
        if (q_w.alu_result !== 32'hCAFE_BABE)
            $fatal(1, "[EX-MEM-REG] FAIL alu_result corrupted");
        if (q_w.decoded.rd !== 5'd7)
            $fatal(1, "[EX-MEM-REG] FAIL decoded.rd corrupted");

        // 3. Branch payload: taken=1
        d_w = make_branch_payload(32'h0000_1004, 1'b1, 32'h0000_2000);
        tick_check(d_w, "capture: branch taken");
        if (q_w.branch_taken !== 1'b1)
            $fatal(1, "[EX-MEM-REG] FAIL branch_taken corrupted");
        if (q_w.branch_target !== 32'h0000_2000)
            $fatal(1, "[EX-MEM-REG] FAIL branch_target corrupted");

        // Branch payload: taken=0
        d_w = make_branch_payload(32'h0000_1008, 1'b0, 32'h0000_1010);
        tick_check(d_w, "capture: branch not-taken");
        if (q_w.branch_taken !== 1'b0)
            $fatal(1, "[EX-MEM-REG] FAIL branch_taken should be 0");

        // 4. Store payload: address and store data survive
        d_w = make_store_payload(32'h0000_100C, 32'h0000_0100, 32'hDEAD_BEEF);
        tick_check(d_w, "capture: store payload");
        if (q_w.alu_result !== 32'h0000_0100)
            $fatal(1, "[EX-MEM-REG] FAIL store address (alu_result) corrupted");
        if (q_w.rs2_data !== 32'hDEAD_BEEF)
            $fatal(1, "[EX-MEM-REG] FAIL store data (rs2_data) corrupted");
        if (q_w.decoded.is_store !== 1'b1)
            $fatal(1, "[EX-MEM-REG] FAIL decoded.is_store corrupted");

        // 5. Stall hold
        begin : t_stall
            automatic ex_mem_payload_t held = d_w;
            stall_w = 1'b1;
            d_w     = make_alu_payload(32'h0000_2000, 32'h1234, 5'd5);
            tick_check(held, "stall: hold cycle 1");
            tick_check(held, "stall: hold cycle 2");
            stall_w = 1'b0;
            tick_check(d_w, "stall release: captures d_i");
        end

        // 6. Flush to bubble; verify branch_taken=0 in bubble (no spurious redirect)
        d_w     = make_branch_payload(32'h0000_3000, 1'b1, 32'hDEAD_4000);
        flush_w = 1'b1;
        tick_check(BUBBLE, "flush: bubble inserted");
        if (q_w.branch_taken !== 1'b0)
            $fatal(1, "[EX-MEM-REG] FAIL flush bubble has branch_taken=1 — would cause spurious redirect");

        flush_w = 1'b0;
        d_w     = make_alu_payload(32'h0000_4000, 32'h5A5A_5A5A, 5'd2);
        tick_check(d_w, "post-flush: capture resumes");

        // 7. Flush beats stall
        begin : t_flush_beats_stall
            stall_w = 1'b1;
            flush_w = 1'b1;
            d_w     = make_branch_payload(32'hDEAD_0000, 1'b1, 32'hDEAD_0000);
            tick_check(BUBBLE, "flush beats stall");
            stall_w = 1'b0;
            flush_w = 1'b0;
        end

        $display("[EX-MEM-REG] PASS: all behavioral contracts verified.");
        $finish;

    end : test_body

endmodule : tb_ex_mem_reg

`default_nettype wire
