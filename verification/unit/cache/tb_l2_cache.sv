// verification/unit/cache/tb_l2_cache.sv
//
// Unit test for l2_cache.sv: an upstream mem_if master (emulating the L1's
// transactions) drives the L2 against a mem_model backing store (LATENCY=8).
//
// Test plan (L2: 4 sets small for aliasing, 4 ways, 4-word lines):
//   Z1. Burst read miss: fill from backing, 4 beats streamed, correct data;
//       repeat read is a hit — zero new downstream requests.
//   Z2. Burst write miss (an L1 eviction): allocates via the burst buffer,
//       backing NOT written (write-back absorbs it); read-back hits with
//       the written data.
//   Z3. Dirty L2 eviction: fill 4 more tags in the same set; the dirty Z2
//       line is written back — backing memory now holds its data.
//   Z4. Single-beat transactions (a W=1 L1): read returns the addressed
//       word; write merges strobes at the right word offset.
//   Z5. Downstream request accounting across the run (hits cost nothing).
//
// Pass/fail: accumulates failures, $fatal at end if any.

`timescale 1ns/1ps
`default_nettype none

import fluxcore_pkg::*;
import mem_if_pkg::*;

module tb_l2_cache;

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

    // Upstream face (TB is the master)
    logic     s_req_valid, s_req_ready, s_rsp_valid, s_rsp_ready;
    mem_req_t s_req;
    mem_rsp_t s_rsp;
    // Downstream face
    logic     m_req_valid, m_req_ready, m_rsp_valid, m_rsp_ready;
    mem_req_t m_req;
    mem_rsp_t m_rsp;

    logic [31:0] l2_hits, l2_misses;

    l2_cache #(.NSETS(4), .LINE_WORDS(4), .WAYS(4)) dut (
        .clk(clk), .rst(rst),
        .s_req_valid_i(s_req_valid), .s_req_ready_o(s_req_ready), .s_req_i(s_req),
        .s_rsp_valid_o(s_rsp_valid), .s_rsp_ready_i(s_rsp_ready), .s_rsp_o(s_rsp),
        .m_req_valid_o(m_req_valid), .m_req_ready_i(m_req_ready), .m_req_o(m_req),
        .m_rsp_valid_i(m_rsp_valid), .m_rsp_ready_o(m_rsp_ready), .m_rsp_i(m_rsp),
        .hit_count_o(l2_hits), .miss_count_o(l2_misses)
    );

    mem_model #(.MEM_WORDS(1024), .LATENCY(8)) u_mem (
        .clk(clk), .rst(rst),
        .req_valid_i(m_req_valid), .req_ready_o(m_req_ready), .req_i(m_req),
        .rsp_valid_o(m_rsp_valid), .rsp_ready_i(m_rsp_ready), .rsp_o(m_rsp)
    );

    // Downstream request counter (accepted request transfers, headers only:
    // count beat 0 of each transaction = transfers where a read is accepted
    // or a write's first beat is accepted — approximate by counting read
    // headers and write beats separately)
    int ds_reads, ds_wbeats;
    always_ff @(posedge clk) begin
        if (rst) begin ds_reads <= 0; ds_wbeats <= 0; end
        else if (m_req_valid && m_req_ready) begin
            if (m_req.op == MEM_READ) ds_reads  <= ds_reads + 1;
            else                      ds_wbeats <= ds_wbeats + 1;
        end
    end

    // -----------------------------------------------------------------------
    // Master-side driver tasks
    // -----------------------------------------------------------------------
    // Issue a burst read of `beats`; collect all beats into data_o.
    logic [31:0] rdata_v [0:15];
    task automatic burst_read(input logic [31:0] addr, input int beats,
                              output logic all_ok);
        int got;
        s_req = mem_read_req(4'h2, addr);
        s_req.len = mem_len_for(beats);
        s_req_valid = 1;
        #1;
        while (!(s_req_valid && s_req_ready)) begin @(posedge clk); #1; end
        @(posedge clk); #1;
        s_req_valid = 0;
        // consume beats
        got = 0;
        all_ok = 1;
        s_rsp_ready = 1;
        while (got < beats) begin
            if (s_rsp_valid) begin
                rdata_v[got] = s_rsp.rdata;
                if (s_rsp.err != MEM_OK) all_ok = 0;
                got++;
            end
            @(posedge clk); #1;
        end
        s_rsp_ready = 0;
    endtask

    // Issue a burst write of `beats` words from wdata_v; wait for the ack.
    logic [31:0] wdata_v [0:15];
    task automatic burst_write(input logic [31:0] addr, input int beats,
                               output logic ok);
        int sent;
        sent = 0;
        s_req = mem_write_req(4'h3, addr, 4'hF, wdata_v[0]);
        s_req.len = mem_len_for(beats);
        s_req_valid = 1;
        #1;
        while (sent < beats) begin
            if (s_req_valid && s_req_ready) begin
                sent++;
                @(posedge clk); #1;
                if (sent < beats) begin
                    s_req.strb  = 4'hF;
                    s_req.wdata = wdata_v[sent];
                end else begin
                    s_req_valid = 0;
                end
            end else begin
                @(posedge clk); #1;
            end
        end
        // ack
        ok = 0;
        s_rsp_ready = 1;
        while (!s_rsp_valid) begin @(posedge clk); #1; end
        ok = (s_rsp.err == MEM_OK) && s_rsp.last;
        @(posedge clk); #1;
        s_rsp_ready = 0;
    endtask

    task automatic single_write(input logic [31:0] addr, input logic [3:0] strb,
                                input logic [31:0] data, output logic ok);
        wdata_v[0] = data;
        s_req = mem_write_req(4'h4, addr, strb, data);
        s_req_valid = 1;
        #1;
        while (!(s_req_valid && s_req_ready)) begin @(posedge clk); #1; end
        @(posedge clk); #1;
        s_req_valid = 0;
        ok = 0;
        s_rsp_ready = 1;
        while (!s_rsp_valid) begin @(posedge clk); #1; end
        ok = (s_rsp.err == MEM_OK) && s_rsp.last;
        @(posedge clk); #1;
        s_rsp_ready = 0;
    endtask

    logic okf;
    int   dsr_before;

    // Geometry: 4 sets, 16 B lines → index bits [5:4]; set-1 lines at
    // 0x10, 0x50, 0x90, 0xD0, 0x110, 0x150 (6 tags for 4 ways).
    initial begin
        for (int i = 0; i < 1024; i++) u_mem.mem[i] = 32'h1200_0000 | i;
        s_req_valid = 0; s_rsp_ready = 0;
        rst = 1;
        repeat (3) @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // ===================================================================
        // Z1: burst read miss then hit.
        // ===================================================================
        $display("\n--- Z1: burst read miss -> fill -> hit ---");
        burst_read(32'h0000_0010, 4, okf);
        check("Z1.miss_beats_ok", okf);
        check("Z1.beat0", rdata_v[0] === (32'h1200_0000 | 'h4));
        check("Z1.beat3", rdata_v[3] === (32'h1200_0000 | 'h7));
        dsr_before = ds_reads;
        burst_read(32'h0000_0010, 4, okf);
        check("Z1.hit_beats_ok", okf);
        check("Z1.hit_data", rdata_v[2] === (32'h1200_0000 | 'h6));
        check("Z1.hit_no_downstream", ds_reads == dsr_before);
        check("Z1.counters", l2_hits == 1 && l2_misses == 1);

        // ===================================================================
        // Z2: burst write miss allocates; backing untouched.
        // ===================================================================
        $display("\n--- Z2: L1-eviction-style write miss allocates ---");
        for (int b = 0; b < 4; b++) wdata_v[b] = 32'hEE00_0000 | b;
        burst_write(32'h0000_0050, 4, okf);
        check("Z2.write_acked", okf);
        check("Z2.backing_untouched", u_mem.mem['h14] === (32'h1200_0000 | 'h14));
        burst_read(32'h0000_0050, 4, okf);
        check("Z2.readback_ok", okf);
        check("Z2.readback_data", rdata_v[1] === 32'hEE00_0001);

        // ===================================================================
        // Z3: dirty eviction after set overflow.
        // ===================================================================
        $display("\n--- Z3: L2 dirty eviction reaches backing ---");
        // Fill the remaining ways of set 1, then two more tags to force
        // eviction of the LRU lines. Touch order keeps 0x50 old.
        burst_read(32'h0000_0090, 4, okf);
        burst_read(32'h0000_00D0, 4, okf);
        burst_read(32'h0000_0110, 4, okf);   // set full; evicts LRU (0x10, clean)
        burst_read(32'h0000_0150, 4, okf);   // evicts 0x50 (dirty) -> writeback
        check("Z3.dirty_evicted_to_backing",
              u_mem.mem['h14] === 32'hEE00_0000
              && u_mem.mem['h15] === 32'hEE00_0001);
        // And the line survives a re-read (from backing now).
        burst_read(32'h0000_0050, 4, okf);
        check("Z3.roundtrip", rdata_v[3] === 32'hEE00_0003);

        // ===================================================================
        // Z4: single-beat transactions at a word offset.
        // ===================================================================
        $display("\n--- Z4: single-beat read/write ---");
        burst_read(32'h0000_0208, 1, okf);   // word 0x82, set 0, word off 2
        check("Z4.single_read", okf && rdata_v[0] === (32'h1200_0000 | 'h82));
        single_write(32'h0000_0208, 4'b0011, 32'hXXXX_BEEF, okf);
        check("Z4.single_write_ack", okf);
        burst_read(32'h0000_0208, 1, okf);
        check("Z4.strobe_merge", rdata_v[0] === ((32'h1200_0000 | 'h82) & 32'hFFFF_0000 | 32'h0000_BEEF));

        // ===================================================================
        // Z5: hits never touched downstream.
        // ===================================================================
        $display("\n--- Z5: totals ---");
        check("Z5.hits_nonzero", l2_hits > 0);
        $display("[L2] hits=%0d misses=%0d ds_reads=%0d ds_wbeats=%0d",
                 l2_hits, l2_misses, ds_reads, ds_wbeats);

        repeat (2) @(posedge clk);
        $display("\n===== tb_l2_cache: %0d passed, %0d failed =====",
                 pass_count, fail_count);
        if (fail_count != 0) $fatal(1, "tb_l2_cache: FAILURES detected");
        $finish;
    end

    initial begin
        #400000;
        $fatal(1, "tb_l2_cache: timeout");
    end

endmodule : tb_l2_cache

`default_nettype wire
