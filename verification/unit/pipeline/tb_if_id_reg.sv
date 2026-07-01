// verification/unit/pipeline/tb_if_id_reg.sv
//
// Self-checking testbench for rtl/pipeline/if_id_reg.sv.
//
// Behavioral contract under test:
//   1. rst=1  → q_o = '0 on next posedge (synchronous, overrides all)
//   2. flush_i=1, rst=0  → q_o = '0 on next posedge (bubble insert)
//   3. stall_i=1, flush_i=0, rst=0  → q_o holds (no change)
//   4. stall_i=0, flush_i=0, rst=0  → q_o = d_i on next posedge
//   5. flush_i=1 beats stall_i=1  → q_o = '0 (not held)
//   6. After flush, normal capture resumes on the following cycle

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_if_id_reg;

    // -----------------------------------------------------------------------
    // Clock
    // -----------------------------------------------------------------------
    logic clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // -----------------------------------------------------------------------
    // DUT ports
    // -----------------------------------------------------------------------
    logic           rst_w   = 1'b1;
    logic           stall_w = 1'b0;
    logic           flush_w = 1'b0;
    if_id_payload_t d_w     = '0;
    if_id_payload_t q_w;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    if_id_reg dut (
        .clk    (clk),
        .rst    (rst_w),
        .stall_i(stall_w),
        .flush_i(flush_w),
        .d_i    (d_w),
        .q_o    (q_w)
    );

    // -----------------------------------------------------------------------
    // Helper: advance one clock and check q
    // -----------------------------------------------------------------------
    task automatic tick_check(
        input if_id_payload_t expected,
        input string          desc
    );
        @(posedge clk); #1;
        if (q_w !== expected)
            $fatal(1, "[IF-ID-REG] FAIL %-30s q=%0b expected=%0b",
                   desc, q_w, expected);
    endtask

    // -----------------------------------------------------------------------
    // Helpers: build typical payloads
    // -----------------------------------------------------------------------
    function automatic if_id_payload_t make_payload(
        input logic   valid,
        input word_t  pc,
        input instr_t instr
    );
        automatic if_id_payload_t p;
        p.valid = valid;
        p.pc    = pc;
        p.instr = instr;
        return p;
    endfunction

    localparam if_id_payload_t BUBBLE = '0;

    // -----------------------------------------------------------------------
    // Main test
    // -----------------------------------------------------------------------
    initial begin : test_body

        // ================================================================
        // 1. Synchronous reset: q_o must be '0 while rst=1
        // ================================================================
        rst_w = 1'b1; stall_w = 1'b0; flush_w = 1'b0;
        d_w = make_payload(1'b1, 32'hDEAD_0000, 32'hFFFF_FFFF);

        tick_check(BUBBLE, "rst: output zeroed on clk1");
        tick_check(BUBBLE, "rst: output stays zero on clk2");
        tick_check(BUBBLE, "rst: output stays zero on clk3");

        // ================================================================
        // 2. Normal capture: release reset, verify d_i is latched
        // ================================================================
        rst_w = 1'b0;
        d_w   = make_payload(1'b1, 32'h0000_1000, 32'h00500093); // ADDI x1,x0,5

        tick_check(d_w, "capture: first instruction latched");

        // Change input; q_o must follow
        d_w = make_payload(1'b1, 32'h0000_1004, 32'h00A00113); // ADDI x2,x0,10
        tick_check(d_w, "capture: second instruction latched");

        // ================================================================
        // 3. Stall hold: q_o must not change while stall_i=1
        // ================================================================
        begin : t_stall
            automatic if_id_payload_t held;
            held  = d_w;   // current q value after previous tick
            stall_w = 1'b1;
            d_w     = make_payload(1'b1, 32'h0000_1008, 32'h00300193); // ADDI x3,x0,3

            tick_check(held, "stall: q holds on first stall cycle");

            d_w = make_payload(1'b1, 32'h0000_100C, 32'h00400213); // ADDI x4,x0,4
            tick_check(held, "stall: q holds on second stall cycle");

            // Release stall — next cycle should capture the current d_i
            stall_w = 1'b0;
            tick_check(d_w, "stall release: q captures d_i");
        end

        // ================================================================
        // 4. Flush to bubble: flush_i=1 must zero q_o
        // ================================================================
        d_w     = make_payload(1'b1, 32'h0000_2000, 32'hABCD_EF01);
        flush_w = 1'b1;
        tick_check(BUBBLE, "flush: q becomes bubble");

        // After flush, next cycle with flush=0 should capture d_i
        flush_w = 1'b0;
        d_w     = make_payload(1'b1, 32'h0000_2004, 32'h00000013); // NOP
        tick_check(d_w, "post-flush: normal capture resumes");

        // ================================================================
        // 5. Flush beats stall: both asserted → q_o becomes '0
        // ================================================================
        begin : t_flush_beats_stall
            // Set up a non-zero q first
            flush_w = 1'b0; stall_w = 1'b0;
            d_w = make_payload(1'b1, 32'h0000_3000, 32'h00C00293); // ADDI x5,x0,12
            tick_check(d_w, "flush-beats-stall: setup");

            // Now assert both stall and flush simultaneously
            stall_w = 1'b1;
            flush_w = 1'b1;
            d_w     = make_payload(1'b1, 32'h0000_3004, 32'hDEAD_BEEF);

            tick_check(BUBBLE, "flush beats stall: q becomes bubble");
        end

        // ================================================================
        // 6. Back-to-back flushes
        // ================================================================
        flush_w = 1'b1; stall_w = 1'b0;
        d_w = make_payload(1'b1, 32'h0000_4000, 32'hFFFF_FFFF);
        tick_check(BUBBLE, "consecutive flush 1");
        tick_check(BUBBLE, "consecutive flush 2");

        flush_w = 1'b0;
        d_w     = make_payload(1'b1, 32'h0000_4008, 32'h00000013); // NOP
        tick_check(d_w, "post-consecutive-flush: capture");

        // ================================================================
        // 7. Bubble input is latched correctly (valid=0 payload)
        // ================================================================
        d_w = BUBBLE;
        tick_check(BUBBLE, "bubble input latched as bubble");

        // ================================================================
        // 8. Reset mid-flight overrides stall and flush
        // ================================================================
        flush_w = 1'b0; stall_w = 1'b1;
        d_w = make_payload(1'b1, 32'hDEAD_BEEF, 32'hFFFF_FFFF);
        rst_w = 1'b1;
        tick_check(BUBBLE, "rst mid-stall: output zeroed");

        stall_w = 1'b0; rst_w = 1'b0;
        d_w = make_payload(1'b1, 32'h0000_5000, 32'h00500093);
        tick_check(d_w, "post-rst capture");

        // ================================================================
        // Done
        // ================================================================
        $display("[IF-ID-REG] PASS: all behavioral contracts verified.");
        $finish;

    end : test_body

endmodule : tb_if_id_reg

`default_nettype wire
