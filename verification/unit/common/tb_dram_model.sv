// verification/unit/common/tb_dram_model.sv
//
// Unit test for dram_model.sv — the bank/row timing contract.
//
//   D1. Write→read round-trip (burst) through the model.
//   D2. Row locality: a read in an OPEN row (tCAS) is measurably faster
//       than one that must precharge+activate (tRP+tRCD+tCAS).
//   D3. Bank interleave: consecutive lines land in different banks, so a
//       row conflict in bank 0 does not close bank 1's row.
//   D4. Refresh: with T_REFI shrunk, refreshes occur and accesses issued
//       during tRFC are delayed but complete correctly.
//   D5. Counters: row_hits/row_misses/refreshes move as expected.
//
// Pass/fail: accumulates failures, $fatal at end if any.

`timescale 1ns/1ps
`default_nettype none

import fluxcore_pkg::*;
import mem_if_pkg::*;

module tb_dram_model;

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

    logic     req_valid, req_ready, rsp_valid, rsp_ready;
    mem_req_t req;
    mem_rsp_t rsp;
    logic [31:0] rhits, rmisses, refr;

    // Small REFI so D4 sees refreshes inside the test window.
    dram_model #(.MEM_WORDS(65536), .T_REFI(300), .T_RFC(12)) dut (
        .clk(clk), .rst(rst),
        .req_valid_i(req_valid), .req_ready_o(req_ready), .req_i(req),
        .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready), .rsp_o(rsp),
        .row_hits_o(rhits), .row_misses_o(rmisses), .refreshes_o(refr)
    );

    logic [31:0] rdata_v [0:15];
    int          cycles_v;

    // Burst read; reports data and total cycles from issue to last beat.
    task automatic bread(input logic [31:0] addr, input int beats);
        int got, t0;
        req = mem_read_req(4'h1, addr);
        req.len = mem_len_for(beats);
        req_valid = 1;
        t0 = 0;
        #1;
        while (!(req_valid && req_ready)) begin @(posedge clk); #1; t0++; end
        @(posedge clk); #1; t0++;
        req_valid = 0;
        got = 0;
        rsp_ready = 1;
        while (got < beats) begin
            if (rsp_valid) begin rdata_v[got] = rsp.rdata; got++; end
            @(posedge clk); #1; t0++;
        end
        rsp_ready = 0;
        cycles_v = t0;
    endtask

    logic [31:0] wdata_v [0:15];
    task automatic bwrite(input logic [31:0] addr, input int beats);
        int sent;
        sent = 0;
        req = mem_write_req(4'h2, addr, 4'hF, wdata_v[0]);
        req.len = mem_len_for(beats);
        req_valid = 1;
        #1;
        while (sent < beats) begin
            if (req_valid && req_ready) begin
                sent++;
                @(posedge clk); #1;
                if (sent < beats) begin
                    req.strb = 4'hF; req.wdata = wdata_v[sent];
                end else req_valid = 0;
            end else begin @(posedge clk); #1; end
        end
        rsp_ready = 1;
        while (!rsp_valid) begin @(posedge clk); #1; end
        @(posedge clk); #1;
        rsp_ready = 0;
    endtask

    int t_hit, t_miss;

    initial begin
        for (int i = 0; i < 65536; i++) dut.mem[i] = 32'hD3A0_0000 | i[15:0];
        req_valid = 0; rsp_ready = 0;
        rst = 1;
        repeat (3) @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // D1: write→read round-trip.
        $display("\n--- D1: round-trip ---");
        for (int b = 0; b < 4; b++) wdata_v[b] = 32'hBEEF_0000 | b;
        bwrite(32'h0000_1000, 4);
        bread (32'h0000_1000, 4);
        check("D1.data0", rdata_v[0] === 32'hBEEF_0000);
        check("D1.data3", rdata_v[3] === 32'hBEEF_0003);

        // D2: row hit vs row conflict.
        // Bank = addr[6:4], row = addr[16:7] (10 bits). 0x2000 and 0xA000
        // share bank 0 but differ in row — a genuine conflict. (A larger
        // stride like 0x40000 would overflow the row field and alias back.)
        $display("\n--- D2: open-row locality ---");
        bread(32'h0000_2000, 4);           // opens the row
        bread(32'h0000_2000, 4);           // row HIT
        t_hit = cycles_v;
        bread(32'h0000_A000, 4);           // same bank, different row: CONFLICT
        t_miss = cycles_v;
        $display("[DRAM] hit=%0d cycles, conflict=%0d cycles", t_hit, t_miss);
        check("D2.hit_faster", t_hit < t_miss);
        check("D2.conflict_cost", t_miss - t_hit >= 10);  // ~tRP+tRCD

        // D3: bank interleave isolates rows.
        $display("\n--- D3: bank isolation ---");
        bread(32'h0000_2010, 4);           // next line -> DIFFERENT bank
        bread(32'h0000_A000, 4);           // bank of D2 conflict: still open
        check("D3.other_bank_row_still_open", cycles_v <= t_hit + 2);

        // D4+D5: refreshes happen and don't corrupt.
        $display("\n--- D4: refresh ---");
        repeat (700) begin @(posedge clk); #1; end   // > 2 REFI idle
        check("D4.refreshes_seen", refr >= 2);
        bread(32'h0000_1000, 4);
        check("D4.data_survives_refresh", rdata_v[0] === 32'hBEEF_0000);
        check("D5.counters_sane", rhits > 0 && rmisses > 0);
        $display("[DRAM] row_hits=%0d row_misses=%0d refreshes=%0d",
                 rhits, rmisses, refr);

        repeat (2) @(posedge clk);
        $display("\n===== tb_dram_model: %0d passed, %0d failed =====",
                 pass_count, fail_count);
        if (fail_count != 0) $fatal(1, "tb_dram_model: FAILURES detected");
        $finish;
    end

    initial begin
        #300000;
        $fatal(1, "tb_dram_model: timeout");
    end

endmodule : tb_dram_model

`default_nettype wire
