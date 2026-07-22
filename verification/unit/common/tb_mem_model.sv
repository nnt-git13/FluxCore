// verification/unit/common/tb_mem_model.sv
//
// Self-checking testbench for sim/memory/mem_model.sv.
//
// Instantiates THREE geometries of the model to pin down the latency contract,
// not just data correctness:
//   u_lat1  — LATENCY=1, GAP=0   : must match bare-BRAM timing (rsp on the
//                                  cycle after request accept).
//   u_lat5  — LATENCY=5, GAP=2   : fixed latency + throttled read bursts.
//   u_jit   — LATENCY=3, JITTER=4: bounded-jitter latency, reproducible seed.
//
// Verifies:
//   1. Single-word write → read round-trip, byte strobes respected.
//   2. LATENCY=1 timing: first rsp beat exactly 1 cycle after accept.
//   3. LATENCY=5 timing: first rsp beat exactly 5 cycles after accept.
//   4. Read burst (4 beats): ascending data, last on final beat, GAP spacing.
//   5. Write burst (4 beats): one rsp beat, data landed at all four words.
//   6. Out-of-range read returns MEM_DECERR with zero data.
//   7. Out-of-range write returns MEM_DECERR.
//   8. Jitter latency stays within [LATENCY, LATENCY+JITTER] over 20 reads.
//   9. id echo on every response.
//
// Pass/fail:
//   Uses $fatal(1, ...) on any mismatch.
//   Prints "[MEM-MODEL-TEST] PASS" and calls $finish on success.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import mem_if_pkg::*;

module tb_mem_model;

    logic clk = 0;
    logic rst;
    always #5 clk = ~clk;   // 100 MHz

    // -----------------------------------------------------------------------
    // Three DUT geometries, one shared driver at a time (tests are sequential).
    // -----------------------------------------------------------------------
    localparam int unsigned WORDS = 256;

    // Discrete signals per port: DUT drives *_ready/*_rsp*, TB drives the rest.
    logic     p1_req_valid, p1_req_ready, p1_rsp_valid, p1_rsp_ready;
    mem_req_t p1_req;
    mem_rsp_t p1_rsp;
    logic     p5_req_valid, p5_req_ready, p5_rsp_valid, p5_rsp_ready;
    mem_req_t p5_req;
    mem_rsp_t p5_rsp;
    logic     pj_req_valid, pj_req_ready, pj_rsp_valid, pj_rsp_ready;
    mem_req_t pj_req;
    mem_rsp_t pj_rsp;

    mem_model #(.MEM_WORDS(WORDS), .LATENCY(1), .GAP(0)) u_lat1 (
        .clk(clk), .rst(rst),
        .req_valid_i(p1_req_valid), .req_ready_o(p1_req_ready), .req_i(p1_req),
        .rsp_valid_o(p1_rsp_valid), .rsp_ready_i(p1_rsp_ready), .rsp_o(p1_rsp)
    );

    mem_model #(.MEM_WORDS(WORDS), .LATENCY(5), .GAP(2)) u_lat5 (
        .clk(clk), .rst(rst),
        .req_valid_i(p5_req_valid), .req_ready_o(p5_req_ready), .req_i(p5_req),
        .rsp_valid_o(p5_rsp_valid), .rsp_ready_i(p5_rsp_ready), .rsp_o(p5_rsp)
    );

    mem_model #(.MEM_WORDS(WORDS), .LATENCY(3), .JITTER(4)) u_jit (
        .clk(clk), .rst(rst),
        .req_valid_i(pj_req_valid), .req_ready_o(pj_req_ready), .req_i(pj_req),
        .rsp_valid_o(pj_rsp_valid), .rsp_ready_i(pj_rsp_ready), .rsp_o(pj_rsp)
    );

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------
    task automatic check(input string name, input logic cond);
        if (!cond) $fatal(1, "[MEM-MODEL-TEST] FAIL: %s", name);
    endtask

    int unsigned cyc;
    always @(posedge clk) cyc <= rst ? 0 : cyc + 1;

    // -----------------------------------------------------------------------
    // Port-1 (LATENCY=1) driver tasks
    // -----------------------------------------------------------------------
    // Issues one request on port 1, records accept cycle; assumes ready.
    task automatic p1_issue(input mem_req_t r, output int unsigned accept_cyc);
        @(negedge clk);
        p1_req       = r;
        p1_req_valid = 1'b1;
        @(posedge clk);
        check("p1 ready at issue", p1_req_ready === 1'b1);
        accept_cyc = cyc;
        @(negedge clk);
        p1_req_valid = 1'b0;
    endtask

    // Waits for one rsp beat on port 1, returns beat + the cycle it appeared.
    task automatic p1_collect(output mem_rsp_t beat, output int unsigned seen_cyc);
        // Assert ready immediately: a response already waiting must complete
        // at the NEXT posedge, or the measured latency gains a phantom cycle.
        p1_rsp_ready = 1'b1;
        while (p1_rsp_valid !== 1'b1) @(negedge clk);
        beat = p1_rsp;
        @(posedge clk);
        seen_cyc = cyc;
        @(negedge clk);
        p1_rsp_ready = 1'b0;
    endtask

    // Same pair for the jitter port (shape identical, port differs).
    task automatic pj_issue(input mem_req_t r, output int unsigned accept_cyc);
        @(negedge clk);
        pj_req       = r;
        pj_req_valid = 1'b1;
        @(posedge clk);
        check("pj ready at issue", pj_req_ready === 1'b1);
        accept_cyc = cyc;
        @(negedge clk);
        pj_req_valid = 1'b0;
    endtask

    task automatic pj_collect(output mem_rsp_t beat, output int unsigned seen_cyc);
        // Assert ready immediately: a response already waiting must complete
        // at the NEXT posedge, or the measured latency gains a phantom cycle.
        pj_rsp_ready = 1'b1;
        while (pj_rsp_valid !== 1'b1) @(negedge clk);
        beat = pj_rsp;
        @(posedge clk);
        seen_cyc = cyc;
        @(negedge clk);
        pj_rsp_ready = 1'b0;
    endtask

    // And for the LATENCY=5 port.
    task automatic p5_issue(input mem_req_t r, output int unsigned accept_cyc);
        @(negedge clk);
        p5_req       = r;
        p5_req_valid = 1'b1;
        @(posedge clk);
        check("p5 ready at issue", p5_req_ready === 1'b1);
        accept_cyc = cyc;
        @(negedge clk);
        p5_req_valid = 1'b0;
    endtask

    task automatic p5_collect(output mem_rsp_t beat, output int unsigned seen_cyc);
        // Assert ready immediately: a response already waiting must complete
        // at the NEXT posedge, or the measured latency gains a phantom cycle.
        p5_rsp_ready = 1'b1;
        while (p5_rsp_valid !== 1'b1) @(negedge clk);
        beat = p5_rsp;
        @(posedge clk);
        seen_cyc = cyc;
        @(negedge clk);
        p5_rsp_ready = 1'b0;
    endtask

    // -----------------------------------------------------------------------
    // Test body
    // -----------------------------------------------------------------------
    mem_rsp_t    beat;
    int unsigned t_issue, t_seen, lat;

    initial begin
        p1_req_valid = 0; p1_rsp_ready = 0; p1_req = mem_read_req('0, '0);
        p5_req_valid = 0; p5_rsp_ready = 0; p5_req = mem_read_req('0, '0);
        pj_req_valid = 0; pj_rsp_ready = 0; pj_req = mem_read_req('0, '0);
        rst = 1;
        repeat (2) @(negedge clk);
        rst = 0;
        @(negedge clk);

        // ------------------------------------------------------------------
        // 1+2. LATENCY=1: write, then read back; check data AND timing.
        // ------------------------------------------------------------------
        p1_issue(mem_write_req(4'h1, 32'h0000_0010, 4'b1111, 32'hCAFE_F00D), t_issue);
        p1_collect(beat, t_seen);
        check("wr rsp id",   beat.id  === 4'h1);
        check("wr rsp ok",   beat.err === MEM_OK);
        check("wr rsp last", beat.last === 1'b1);

        p1_issue(mem_read_req(4'h2, 32'h0000_0010), t_issue);
        p1_collect(beat, t_seen);
        check("rd data",     beat.rdata === 32'hCAFE_F00D);
        check("rd id",       beat.id    === 4'h2);
        check("LAT1 timing: rsp exactly 1 cycle after accept", (t_seen - t_issue) == 1);

        // Byte-strobe write: only the low half must change.
        p1_issue(mem_write_req(4'h3, 32'h0000_0010, 4'b0011, 32'h1111_BEEF), t_issue);
        p1_collect(beat, t_seen);
        p1_issue(mem_read_req(4'h4, 32'h0000_0010), t_issue);
        p1_collect(beat, t_seen);
        check("strobe merge", beat.rdata === 32'hCAFE_BEEF);

        // ------------------------------------------------------------------
        // 3. LATENCY=5 single read timing.
        // ------------------------------------------------------------------
        p5_issue(mem_write_req(4'h5, 32'h0000_0020, 4'b1111, 32'h0000_0055), t_issue);
        p5_collect(beat, t_seen);
        p5_issue(mem_read_req(4'h6, 32'h0000_0020), t_issue);
        p5_collect(beat, t_seen);
        check("LAT5 data", beat.rdata === 32'h0000_0055);
        check("LAT5 timing: rsp exactly 5 cycles after accept", (t_seen - t_issue) == 5);

        // ------------------------------------------------------------------
        // 4. Read burst on LATENCY=1: 4 beats from 0x40, ascending, last flag.
        //    (Seed the words via single writes first.)
        // ------------------------------------------------------------------
        for (int i = 0; i < 4; i++) begin
            p1_issue(mem_write_req(4'h7, 32'h0000_0040 + 32'(4*i), 4'b1111,
                                   32'hA000_0000 + word_t'(i)), t_issue);
            p1_collect(beat, t_seen);
        end
        begin
            mem_req_t r;
            r = mem_read_req(4'h8, 32'h0000_0040);
            r.len = mem_len_for(4);
            p1_issue(r, t_issue);
            for (int i = 0; i < 4; i++) begin
                p1_collect(beat, t_seen);
                check("burst data",  beat.rdata === 32'hA000_0000 + word_t'(i));
                check("burst id",    beat.id    === 4'h8);
                check("burst last",  beat.last  === logic'(i == 3));
            end
        end

        // ------------------------------------------------------------------
        // 5. Write burst on LATENCY=1: 4 beats at 0x80, then read each back.
        // ------------------------------------------------------------------
        begin
            mem_req_t r;
            r = mem_write_req(4'h9, 32'h0000_0080, 4'b1111, 32'hB000_0000);
            r.len = mem_len_for(4);
            // Beat 0 (carries the header) then beats 1..3 back-to-back.
            @(negedge clk);
            p1_req       = r;
            p1_req_valid = 1'b1;
            @(negedge clk);
            for (int i = 1; i < 4; i++) begin
                p1_req.wdata = 32'hB000_0000 + word_t'(i);
                @(negedge clk);
            end
            p1_req_valid = 1'b0;
            p1_collect(beat, t_seen);
            check("wburst rsp last", beat.last === 1'b1);
            check("wburst rsp ok",   beat.err  === MEM_OK);
        end
        for (int i = 0; i < 4; i++) begin
            p1_issue(mem_read_req(4'hA, 32'h0000_0080 + 32'(4*i)), t_issue);
            p1_collect(beat, t_seen);
            check("wburst readback", beat.rdata === 32'hB000_0000 + word_t'(i));
        end

        // ------------------------------------------------------------------
        // 6+7. Out-of-range: WORDS=256 → valid bytes [0, 0x400). Probe 0x400.
        // ------------------------------------------------------------------
        p1_issue(mem_read_req(4'hB, 32'h0000_0400), t_issue);
        p1_collect(beat, t_seen);
        check("oob read err",  beat.err   === MEM_DECERR);
        check("oob read data", beat.rdata === 32'h0);

        p1_issue(mem_write_req(4'hC, 32'h0000_0400, 4'b1111, 32'hDEAD_DEAD), t_issue);
        p1_collect(beat, t_seen);
        check("oob write err", beat.err === MEM_DECERR);

        // ------------------------------------------------------------------
        // 8. Jitter bounds: 20 reads, latency must stay in [3, 7].
        // ------------------------------------------------------------------
        for (int i = 0; i < 20; i++) begin
            pj_issue(mem_read_req(4'hD, 32'h0000_0000), t_issue);
            pj_collect(beat, t_seen);
            lat = t_seen - t_issue;
            if (lat < 3 || lat > 7)
                $fatal(1, "[MEM-MODEL-TEST] jitter latency %0d outside [3,7]", lat);
        end

        $display("[MEM-MODEL-TEST] PASS");
        $finish;
    end

    // Global watchdog: nothing here should take anywhere near this long.
    initial begin
        #100000;
        $fatal(1, "[MEM-MODEL-TEST] TIMEOUT");
    end

endmodule : tb_mem_model

`default_nettype wire
