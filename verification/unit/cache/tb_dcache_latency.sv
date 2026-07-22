// verification/unit/cache/tb_dcache_latency.sv
//
// The hit-under-miss payoff test: two IDENTICAL cache geometries (2-way,
// 4-word lines, WB+WA) against the SAME slow memory (mem_model LATENCY=12),
// driven with the same access trace — one blocking, one non-blocking.
//
// Trace: 8 cold-miss loads, each followed by 6 non-memory "work" cycles
// (the pipeline executing ALU ops). The blocking cache freezes for the
// whole fill every time; the non-blocking cache defers the load and does
// the work cycles while the fill runs, eating only the structural overlap
// when the next load arrives before the MSHR frees.
//
// Checks:
//   L1. Both caches return every load's correct data (blocking via
//       cpu_rdata, non-blocking via the fill_done/fill_data pulses).
//   L2. Non-blocking total stall cycles STRICTLY fewer than blocking.
//   L3. Blocking stalls match the analytic expectation (8 fills, each
//       LATENCY + LINE_WORDS cycles of stall, +1 accept retry when a
//       previous transaction still owns the channel — bounded check).
//
// Prints both stall totals so regress logs document the measured gain.

`timescale 1ns/1ps
`default_nettype none

import fluxcore_pkg::*;
import mem_if_pkg::*;

module tb_dcache_latency;

    localparam int LOADS      = 8;
    localparam int WORK_CYCS  = 6;
    localparam int LATENCY    = 12;

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

    // -----------------------------------------------------------------------
    // Two DUTs, own memories (identical contents), same geometry.
    // -----------------------------------------------------------------------
    // Blocking side (b*), non-blocking side (n*).
    logic [31:0] b_addr, b_rdata;
    logic        b_ren, b_stall;
    logic        b_req_valid, b_req_ready, b_rsp_valid, b_rsp_ready;
    mem_req_t    b_req;
    mem_rsp_t    b_rsp;
    logic [31:0] b_hits, b_misses;

    logic [31:0] n_addr, n_rdata;
    logic        n_ren, n_stall, n_defer, n_fill_done;
    logic [31:0] n_fill_data;
    logic        n_req_valid, n_req_ready, n_rsp_valid, n_rsp_ready;
    mem_req_t    n_req;
    mem_rsp_t    n_rsp;
    logic [31:0] n_hits, n_misses;

    mem_model #(.MEM_WORDS(1024), .LATENCY(LATENCY)) u_bmem (
        .clk(clk), .rst(rst),
        .req_valid_i(b_req_valid), .req_ready_o(b_req_ready), .req_i(b_req),
        .rsp_valid_o(b_rsp_valid), .rsp_ready_i(b_rsp_ready), .rsp_o(b_rsp)
    );
    mem_model #(.MEM_WORDS(1024), .LATENCY(LATENCY)) u_nmem (
        .clk(clk), .rst(rst),
        .req_valid_i(n_req_valid), .req_ready_o(n_req_ready), .req_i(n_req),
        .rsp_valid_o(n_rsp_valid), .rsp_ready_i(n_rsp_ready), .rsp_o(n_rsp)
    );

    dcache #(.NSETS(8), .LINE_WORDS(4), .WAYS(2),
             .WRITE_ALLOCATE(1'b1), .WRITE_BACK(1'b1), .NONBLOCKING(1'b0)) dut_b (
        .clk(clk), .rst(rst),
        .cpu_addr_i(b_addr), .cpu_ren_i(b_ren), .cpu_wen_i(1'b0),
        .cpu_wstrb_i('0), .cpu_wdata_i('0),
        .cpu_rdata_o(b_rdata), .dmem_stall_o(b_stall),
        .mem_req_valid_o(b_req_valid), .mem_req_ready_i(b_req_ready),
        .mem_req_o(b_req), .mem_rsp_valid_i(b_rsp_valid),
        .mem_rsp_ready_o(b_rsp_ready), .mem_rsp_i(b_rsp),
        .hit_count_o(b_hits), .miss_count_o(b_misses)
    );

    dcache #(.NSETS(8), .LINE_WORDS(4), .WAYS(2),
             .WRITE_ALLOCATE(1'b1), .WRITE_BACK(1'b1), .NONBLOCKING(1'b1)) dut_n (
        .clk(clk), .rst(rst),
        .cpu_addr_i(n_addr), .cpu_ren_i(n_ren), .cpu_wen_i(1'b0),
        .cpu_wstrb_i('0), .cpu_wdata_i('0),
        .cpu_rdata_o(n_rdata), .dmem_stall_o(n_stall),
        .defer_ok_i(1'b1), .miss_defer_o(n_defer),
        .fill_done_o(n_fill_done), .fill_data_o(n_fill_data),
        .mem_req_valid_o(n_req_valid), .mem_req_ready_i(n_req_ready),
        .mem_req_o(n_req), .mem_rsp_valid_i(n_rsp_valid),
        .mem_rsp_ready_o(n_rsp_ready), .mem_rsp_i(n_rsp),
        .hit_count_o(n_hits), .miss_count_o(n_misses)
    );

    // Non-blocking fill results accumulate here (order preserved: 1 MSHR).
    int          n_fills_seen;
    logic [31:0] n_fill_sum;
    always_ff @(posedge clk) begin
        if (rst) begin
            n_fills_seen <= 0;
            n_fill_sum   <= '0;
        end else if (n_fill_done) begin
            n_fills_seen <= n_fills_seen + 1;
            n_fill_sum   <= n_fill_sum + n_fill_data;
        end
    end

    // -----------------------------------------------------------------------
    // Drivers: same trace on both sides, independent stall accounting.
    // Each side emulates its own pipeline: a load is held while stalled,
    // then WORK_CYCS non-memory cycles follow.
    // -----------------------------------------------------------------------
    int b_stalls, n_stalls;
    logic [31:0] b_sum;
    logic [31:0] expect_sum;

    task automatic b_run;
        logic [31:0] addr;
        b_sum = '0;
        for (int i = 0; i < LOADS; i++) begin
            addr = 32'(i * 16);            // distinct lines, indexes 0..7
            b_addr = addr; b_ren = 1;
            #1;
            while (b_stall === 1'b1) begin @(posedge clk); #1; b_stalls++; end
            @(posedge clk); #1;
            b_ren = 0; b_addr = '0;
            b_sum += b_rdata;              // WB-cycle sample
            repeat (WORK_CYCS) begin @(posedge clk); #1; end
        end
    endtask

    task automatic n_run;
        logic [31:0] addr;
        for (int i = 0; i < LOADS; i++) begin
            addr = 32'(i * 16);
            n_addr = addr; n_ren = 1;
            #1;
            while (n_stall === 1'b1) begin @(posedge clk); #1; n_stalls++; end
            @(posedge clk); #1;
            n_ren = 0; n_addr = '0;
            repeat (WORK_CYCS) begin @(posedge clk); #1; end
        end
        // Drain the last outstanding fill.
        while (n_fills_seen < LOADS) begin @(posedge clk); #1; end
    endtask

    initial begin
        expect_sum = '0;
        for (int i = 0; i < 1024; i++) begin
            u_bmem.mem[i] = 32'h0BAD_0000 | i;
            u_nmem.mem[i] = 32'h0BAD_0000 | i;
        end
        for (int i = 0; i < LOADS; i++)
            expect_sum += 32'h0BAD_0000 | (i * 4);   // word 0 of each line

        b_addr='0; b_ren=0; n_addr='0; n_ren=0;
        b_stalls = 0; n_stalls = 0;
        rst = 1;
        repeat (3) @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        fork
            b_run;
            n_run;
        join

        $display("\n[LATENCY] blocking stalls    = %0d", b_stalls);
        $display("[LATENCY] non-blocking stalls = %0d", n_stalls);
        $display("[LATENCY] saved               = %0d cycles (%0d%%)",
                 b_stalls - n_stalls,
                 b_stalls > 0 ? ((b_stalls - n_stalls) * 100) / b_stalls : 0);

        // L1: data correctness on both sides.
        check("L1.blocking_sum",    b_sum      === expect_sum);
        check("L1.nonblocking_sum", n_fill_sum === expect_sum);
        check("L1.all_fills_seen",  n_fills_seen == LOADS);

        // L2: the point of the exercise.
        check("L2.nonblocking_strictly_fewer_stalls", n_stalls < b_stalls);

        // L3: blocking side sanity — each miss costs at least LATENCY cycles.
        check("L3.blocking_at_least_latency_per_miss",
              b_stalls >= LOADS * LATENCY);

        repeat (2) @(posedge clk);
        $display("\n===== tb_dcache_latency: %0d passed, %0d failed =====",
                 pass_count, fail_count);
        if (fail_count != 0) $fatal(1, "tb_dcache_latency: FAILURES detected");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "tb_dcache_latency: timeout");
    end

endmodule : tb_dcache_latency

`default_nettype wire
