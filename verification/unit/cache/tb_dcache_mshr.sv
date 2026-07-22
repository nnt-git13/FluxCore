// verification/unit/cache/tb_dcache_mshr.sv
//
// Unit test for dcache.sv NONBLOCKING mode (1-entry MSHR, hit-under-miss).
//
// DUT: NSETS=4, LINE_WORDS=4, WAYS=2, WRITE_ALLOCATE=1, WRITE_BACK=1,
//      NONBLOCKING=1. Geometry: word off [3:2], index [5:4], tag [31:6].
//
// Test plan:
//   N1. Deferred read miss: miss_defer_o pulses, dmem_stall_o stays low;
//       fill_done_o pulses within the fill latency with the correct word.
//   N2. Hit-under-miss: while the fill runs, a read hit to a pre-warmed
//       OTHER line is served stall-free with correct data.
//   N3. Miss-under-miss is structural: a second miss during the fill stalls
//       until the MSHR frees, then defers in its turn.
//   N4. Deferred allocating STORE is fire-and-forget: no stall, no
//       fill_done pulse; the line later hits with merged data.
//   N5. defer_ok_i=0 forces the legacy blocking path: stall for the full
//       fill, data returned on cpu_rdata_o.
//   N6. Access to the in-flux (victim) line during replacement stalls
//       rather than reading half-replaced data.
//
// Pass/fail: accumulates failures, $fatal at end if any.

`timescale 1ns/1ps
`default_nettype none

import fluxcore_pkg::*;
import mem_if_pkg::*;

module tb_dcache_mshr;

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

    logic [31:0] c_addr, c_wdata, c_rdata;
    logic        c_ren, c_wen, c_stall;
    logic [3:0]  c_wstrb;
    logic        m_req_valid, m_req_ready, m_rsp_valid, m_rsp_ready;
    mem_req_t    m_req;
    mem_rsp_t    m_rsp;
    logic        defer_ok, miss_defer, fill_done;
    logic [31:0] fill_data;
    logic [31:0] hits, misses;

    // Backing store: P0 sim memory, LATENCY=1 = bare-BRAM timing.
    mem_model #(.MEM_WORDS(1024), .LATENCY(1)) u_mem (
        .clk(clk), .rst(rst),
        .req_valid_i(m_req_valid), .req_ready_o(m_req_ready), .req_i(m_req),
        .rsp_valid_o(m_rsp_valid), .rsp_ready_i(m_rsp_ready), .rsp_o(m_rsp)
    );

    dcache #(.NSETS(4), .LINE_WORDS(4), .WAYS(2),
             .WRITE_ALLOCATE(1'b1), .WRITE_BACK(1'b1), .NONBLOCKING(1'b1)) dut (
        .clk(clk), .rst(rst),
        .cpu_addr_i(c_addr), .cpu_ren_i(c_ren), .cpu_wen_i(c_wen),
        .cpu_wstrb_i(c_wstrb), .cpu_wdata_i(c_wdata),
        .cpu_rdata_o(c_rdata), .dmem_stall_o(c_stall),
        .defer_ok_i(defer_ok), .miss_defer_o(miss_defer),
        .fill_done_o(fill_done), .fill_data_o(fill_data),
        .mem_req_valid_o(m_req_valid), .mem_req_ready_i(m_req_ready),
        .mem_req_o(m_req), .mem_rsp_valid_i(m_rsp_valid),
        .mem_rsp_ready_o(m_rsp_ready), .mem_rsp_i(m_rsp),
        .hit_count_o(hits), .miss_count_o(misses)
    );

    // Background fill_done monitor: records every pulse + its data.
    int          done_count;
    logic [31:0] last_fill_data;
    always_ff @(posedge clk) begin
        if (rst) begin
            done_count     <= 0;
            last_fill_data <= '0;
        end else if (fill_done) begin
            done_count     <= done_count + 1;
            last_fill_data <= fill_data;
        end
    end

    // Issue one access for exactly one un-stalled cycle (pipeline behavior:
    // held while stalled, advances when stall drops). Reports stalls and
    // whether the access was deferred.
    task automatic access(input logic [31:0] addr, input logic ren,
                          input logic wen, input logic [31:0] wdata,
                          output int stalls, output logic deferred);
        c_addr = addr; c_ren = ren; c_wen = wen;
        c_wstrb = wen ? 4'hF : '0; c_wdata = wdata;
        #1;
        stalls = 0;
        while (c_stall === 1'b1) begin @(posedge clk); #1; stalls++; end
        deferred = miss_defer;
        @(posedge clk); #1;
        c_ren = 0; c_wen = 0; c_addr = '0; c_wstrb = '0; c_wdata = '0;
    endtask

    // Wait (bounded) for the next fill_done pulse.
    task automatic wait_fill(output logic ok);
        int limit = 20;
        int prev = done_count;
        ok = 0;
        while (limit > 0 && done_count == prev) begin
            @(posedge clk); #1;
            limit--;
        end
        ok = (done_count == prev + 1);
    endtask

    logic [31:0] rd;
    int          st;
    logic        def, ok;

    // Index-1 lines (bits [5:4]=01): 0x10, 0x50, 0x90 conflict at 2 ways.
    // Index-2 line: 0x20 (the hit-under-miss target).
    initial begin
        for (int i = 0; i < 1024; i++) u_mem.mem[i] = 32'hE000_0000 | i;
        c_addr='0; c_ren=0; c_wen=0; c_wstrb='0; c_wdata='0; defer_ok = 1;
        rst = 1;
        repeat (3) @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // Warm line 0x20 (index 2) BLOCKING so later hits are guaranteed.
        defer_ok = 0;
        access(32'h0000_0020, 1, 0, '0, st, def);
        check("warm.blocking_stalled", st == 4);
        check("warm.not_deferred", def === 1'b0);
        @(posedge clk); #1;
        // N5 while we're here: blocking data path.
        check("N5.blocking_rdata", c_rdata === (32'hE000_0000 | 'h8));
        defer_ok = 1;

        // ===================================================================
        // N1: deferred read miss (0x14 = index 1, word 1).
        // ===================================================================
        $display("\n--- N1: deferred read miss ---");
        access(32'h0000_0014, 1, 0, '0, st, def);
        check("N1.no_stall", st == 0);
        check("N1.deferred", def === 1'b1);

        // ===================================================================
        // N2: hit-under-miss while the N1 fill is in flight.
        // ===================================================================
        $display("\n--- N2: hit-under-miss ---");
        access(32'h0000_0020, 1, 0, '0, st, def);
        check("N2.hit_no_stall", st == 0);
        check("N2.not_deferred", def === 1'b0);
        @(posedge clk); #1;
        check("N2.hit_data", c_rdata === (32'hE000_0000 | 'h8));

        wait_fill(ok);
        check("N1.fill_done_seen", ok);
        check("N1.fill_data", last_fill_data === (32'hE000_0000 | 'h5));

        // The N1 line is now resident: hit.
        access(32'h0000_0014, 1, 0, '0, st, def);
        check("N1.line_now_hits", st == 0);
        @(posedge clk); #1;
        check("N1.hit_data", c_rdata === (32'hE000_0000 | 'h5));

        // ===================================================================
        // N3: miss-under-miss stalls, then defers.
        // ===================================================================
        $display("\n--- N3: miss-under-miss is structural ---");
        access(32'h0000_0050, 1, 0, '0, st, def);     // index 1, way 2 fill
        check("N3.first_deferred", def === 1'b1 && st == 0);
        access(32'h0000_0090, 1, 0, '0, st, def);     // index 1 again: busy!
        check("N3.second_stalled_then_deferred", st > 0 && def === 1'b1);
        wait_fill(ok);
        check("N3.second_fill_done", ok);
        check("N3.second_fill_data", last_fill_data === (32'hE000_0000 | 'h24));

        // ===================================================================
        // N4: deferred allocating store.
        // ===================================================================
        $display("\n--- N4: deferred store ---");
        begin
            int prev = done_count;
            access(32'h0000_0028, 0, 1, 32'hFEED_FACE, st, def);  // idx 2 hit? no:
            // 0x28 is word 2 of line 0x20 — that line is WARM → store HIT.
            // Use a genuinely missing line instead: 0x60 (index 2, other tag).
            check("N4.storehit_no_stall", st == 0);
            access(32'h0000_0060, 0, 1, 32'h0DDB_A115, st, def);
            check("N4.store_deferred", def === 1'b1 && st == 0);
            // Let the fill finish (no fill_done pulse for stores).
            repeat (10) begin @(posedge clk); #1; end
            check("N4.no_done_pulse_for_store", done_count == prev);
        end
        access(32'h0000_0060, 1, 0, '0, st, def);
        check("N4.line_hits", st == 0);
        @(posedge clk); #1;
        check("N4.merged_data", c_rdata === 32'h0DDB_A115);

        // ===================================================================
        // N6: victim-line access during replacement stalls.
        // ===================================================================
        $display("\n--- N6: in-flux line access stalls ---");
        // Index 1 holds {0x10-line? (evicted earlier), 0x50, 0x90}. Dirty one:
        access(32'h0000_0054, 0, 1, 32'hD1D1_D1D1, st, def);   // store hit, dirty
        check("N6.dirty_store_hit", st == 0 && def === 1'b0);
        // New tag at index 1 → evicts LRU. Immediately touch the DUT with an
        // access to the line being replaced (whichever it is, 0x90's LRU
        // status after N3 ordering: 0x50 touched just now → victim is 0x90).
        access(32'h0000_00D0, 1, 0, '0, st, def);              // defer, evict 0x90? (clean) or 0x50
        check("N6.new_deferred", def === 1'b1);
        // Access the victim line 0x90 while replacement is in flight: must
        // NOT serve stale/in-flux data. It stalls until the MSHR frees, then
        // misses/defers again.
        access(32'h0000_0090, 1, 0, '0, st, def);
        check("N6.victim_access_waits", st > 0);
        check("N6.victim_refetch_deferred", def === 1'b1);
        wait_fill(ok);
        check("N6.refetch_done", ok);
        check("N6.refetch_data", last_fill_data === (32'hE000_0000 | 'h24));

        repeat (2) @(posedge clk);
        $display("\n===== tb_dcache_mshr: %0d passed, %0d failed =====",
                 pass_count, fail_count);
        if (fail_count != 0) $fatal(1, "tb_dcache_mshr: FAILURES detected");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "tb_dcache_mshr: timeout");
    end

endmodule : tb_dcache_mshr

`default_nettype wire
