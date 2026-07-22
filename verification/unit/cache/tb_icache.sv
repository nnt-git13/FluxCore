// verification/unit/cache/tb_icache.sv
//
// Unit test for icache.sv against mem_model (LATENCY=6).
//
//   I1. Cold miss: instr_valid_o low for >= LATENCY cycles, then the
//       correct instruction appears combinationally.
//   I2. Within-line sequential PCs hit in the same cycle (word mux).
//   I3. Redirect mid-fill: while a miss for line B fills, pointing the PC
//       back at warm line A gives a hit IMMEDIATELY (fills don't hold the
//       front end hostage); the B fill still completes and installs.
//   I4. FENCE.I: flush_i invalidates a warm line — next access misses and
//       refills (with updated memory contents).
//   I5. FENCE.I mid-fill: the in-flight fill is not installed.
//
// Pass/fail: accumulates failures, $fatal at end if any.

`timescale 1ns/1ps
`default_nettype none

import fluxcore_pkg::*;
import mem_if_pkg::*;

module tb_icache;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst;

    int pass_count = 0;
    int fail_count = 0;

    task check(input string name, input logic cond);
        if (!cond) begin
            $display("FAIL  %0t  %s", $time, name);
            fail_count++;
        end else begin
            $display("PASS  %0t  %s", $time, name);
            pass_count++;
        end
    endtask

    logic [31:0] pc, instr;
    logic        ivalid, flush;
    logic        req_valid, req_ready, rsp_valid, rsp_ready;
    mem_req_t    req;
    mem_rsp_t    rsp;
    logic [31:0] hits, misses;

    icache #(.NSETS(8), .LINE_WORDS(4), .WAYS(2)) dut (
        .clk(clk), .rst(rst),
        .pc_i(pc), .instr_o(instr), .instr_valid_o(ivalid),
        .flush_i(flush),
        .mem_req_valid_o(req_valid), .mem_req_ready_i(req_ready), .mem_req_o(req),
        .mem_rsp_valid_i(rsp_valid), .mem_rsp_ready_o(rsp_ready), .mem_rsp_i(rsp),
        .hit_count_o(hits), .miss_count_o(misses)
    );

    mem_model #(.MEM_WORDS(1024), .LATENCY(6)) u_mem (
        .clk(clk), .rst(rst),
        .req_valid_i(req_valid), .req_ready_o(req_ready), .req_i(req),
        .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready), .rsp_o(rsp)
    );

    // Fetch-style access: present pc, count cycles until valid, sample.
    task automatic fetch(input logic [31:0] a, output logic [31:0] d,
                         output int waits);
        pc = a;
        #1;
        waits = 0;
        while (ivalid !== 1'b1) begin @(posedge clk); #1; waits++; end
        d = instr;
    endtask

    logic [31:0] d;
    int          w;

    initial begin
        for (int i = 0; i < 1024; i++) u_mem.mem[i] = 32'h1057_0000 | i;
        pc = '0; flush = 0;
        rst = 1;
        repeat (3) @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // I1: cold miss at 0x40 (line A).
        $display("\n--- I1: cold miss ---");
        fetch(32'h0000_0040, d, w);
        check("I1.latency_visible", w >= 6);
        check("I1.instr", d === (32'h1057_0000 | 'h10));

        // I2: neighbors hit same-cycle.
        $display("\n--- I2: within-line hits ---");
        fetch(32'h0000_0044, d, w);
        check("I2.word1_hit_now", w == 0);
        check("I2.word1", d === (32'h1057_0000 | 'h11));
        fetch(32'h0000_004C, d, w);
        check("I2.word3_hit_now", w == 0);
        check("I2.word3", d === (32'h1057_0000 | 'h13));

        // I3: redirect mid-fill back to the warm line.
        $display("\n--- I3: redirect during fill ---");
        pc = 32'h0000_0080;      // line B: miss starts
        #1;
        check("I3.B_misses", ivalid === 1'b0);
        repeat (2) begin @(posedge clk); #1; end   // fill under way
        pc = 32'h0000_0040;      // redirect to warm line A
        #1;
        check("I3.A_hits_immediately", ivalid === 1'b1
                                       && instr === (32'h1057_0000 | 'h10));
        // The B fill completes in the background and installs:
        repeat (15) begin @(posedge clk); #1; end
        fetch(32'h0000_0080, d, w);
        check("I3.B_installed", w == 0);
        check("I3.B_data", d === (32'h1057_0000 | 'h20));

        // I4: FENCE.I invalidates; refill sees new memory.
        $display("\n--- I4: flush + refill ---");
        u_mem.mem['h10] = 32'hAFFE_C7ED;   // "self-modified" instruction
        @(negedge clk); flush = 1; @(negedge clk); flush = 0;
        #1;
        pc = 32'h0000_0040;
        #1;
        check("I4.miss_after_flush", ivalid === 1'b0);
        fetch(32'h0000_0040, d, w);
        check("I4.new_instr", d === 32'hAFFE_C7ED);

        // I5: flush mid-fill is not installed.
        $display("\n--- I5: flush poisons in-flight fill ---");
        pc = 32'h0000_0100;      // fresh line: miss starts
        #1;
        repeat (2) begin @(posedge clk); #1; end
        @(negedge clk); flush = 1; @(negedge clk); flush = 0;
        // Wait past where the fill would have installed.
        repeat (15) begin @(posedge clk); #1; end
        pc = 32'h0000_0100;
        #1;
        check("I5.not_installed", ivalid === 1'b0);
        // And it refills correctly afterwards.
        fetch(32'h0000_0100, d, w);
        check("I5.refill_ok", d === (32'h1057_0000 | 'h40));

        $display("[ICACHE] hits=%0d misses=%0d", hits, misses);

        repeat (2) @(posedge clk);
        $display("\n===== tb_icache: %0d passed, %0d failed =====",
                 pass_count, fail_count);
        if (fail_count != 0) $fatal(1, "tb_icache: FAILURES detected");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "tb_icache: timeout");
    end

endmodule : tb_icache

`default_nettype wire
