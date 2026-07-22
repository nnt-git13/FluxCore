// verification/unit/cache/tb_dcache_multiword.sv
//
// Unit test for rtl/cache/dcache.sv with LINE_WORDS=4 (multi-word lines).
//
// Test plan:
//   M1. Read miss on word 0 of a line: stall for exactly 4 cycles (W beats),
//       then correct data. Fill addresses walk base+0/+4/+8/+C.
//   M2. Spatial locality: words 1..3 of the same line now HIT (the whole
//       point of multi-word lines).
//   M3. Miss on a NON-zero word offset: requested word (not word 0) is
//       returned; whole line still fills.
//   M4. Store hit to word 2: cache + BRAM updated; read of word 2 hits with
//       new data; neighboring word 1 unaffected.
//   M5. Store miss: write-through only (no allocate); read of that line
//       misses, then returns the stored value from BRAM.
//   M6. Aliasing/eviction: same index, different tag evicts the whole line;
//       all four words of the old line miss afterwards.
//   M7. Counters: exactly the expected hit/miss totals for the sequence.
//
// Pass/fail: accumulates failures, $fatal at end if any; prints
// "tb_dcache_multiword: N passed, 0 failed" on success.

`timescale 1ns/1ps
`default_nettype none

import fluxcore_pkg::*;
import mem_if_pkg::*;

module tb_dcache_multiword;

    localparam int NSETS      = 8;
    localparam int LINE_WORDS = 4;
    // Geometry: byte offset [1:0], word offset [3:2], index [6:4], tag [31:7].
    // Line size 16 B; one set spans 16 B; index wraps every 128 B.

    logic clk = 0;
    always #5 clk = ~clk;

    logic        rst;
    logic [31:0] cpu_addr;
    logic        cpu_ren;
    logic        cpu_wen;
    logic [3:0]  cpu_wstrb;
    logic [31:0] cpu_wdata;
    logic [31:0] cpu_rdata;
    logic        dmem_stall;
    logic        req_valid, req_ready, rsp_valid, rsp_ready;
    mem_req_t    req;
    mem_rsp_t    rsp;
    logic [31:0] hit_count;
    logic [31:0] miss_count;

    // Backing store: P0 sim memory, LATENCY=1 = bare-BRAM timing.
    mem_model #(.MEM_WORDS(1024), .LATENCY(1)) u_mem (
        .clk(clk), .rst(rst),
        .req_valid_i(req_valid), .req_ready_o(req_ready), .req_i(req),
        .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready), .rsp_o(rsp)
    );

    dcache #(.NSETS(NSETS), .LINE_WORDS(LINE_WORDS)) dut (
        .clk         (clk),
        .rst         (rst),
        .cpu_addr_i  (cpu_addr),
        .cpu_ren_i   (cpu_ren),
        .cpu_wen_i   (cpu_wen),
        .cpu_wstrb_i (cpu_wstrb),
        .cpu_wdata_i (cpu_wdata),
        .cpu_rdata_o (cpu_rdata),
        .dmem_stall_o(dmem_stall),
        .mem_req_valid_o(req_valid),
        .mem_req_ready_i(req_ready),
        .mem_req_o      (req),
        .mem_rsp_valid_i(rsp_valid),
        .mem_rsp_ready_o(rsp_ready),
        .mem_rsp_i      (rsp),
        .hit_count_o (hit_count),
        .miss_count_o(miss_count)
    );

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

    task idle_cycle;
        cpu_addr = '0; cpu_ren = 0; cpu_wen = 0; cpu_wstrb = '0; cpu_wdata = '0;
        @(posedge clk); #1;
    endtask

    // Emulate the pipeline on a read: hold the request while dmem_stall is
    // high (MEM stage frozen), one further cycle to complete, then sample
    // cpu_rdata in the following (WB) cycle. Returns stall cycle count.
    task automatic read_and_wait(input logic [31:0] addr,
                                 output logic [31:0] data,
                                 output int stalls);
        cpu_addr = addr; cpu_ren = 1;
        #1;
        stalls = 0;
        while (dmem_stall === 1'b1) begin
            @(posedge clk); #1;
            stalls++;
        end
        @(posedge clk); #1;      // MEM completes (data captured at this edge)
        cpu_ren = 0; cpu_addr = '0;
        data = cpu_rdata;        // WB cycle: registered capture
    endtask

    logic [31:0] rd;
    int          st;
    // Record accepted read requests: with mem_if the whole line is ONE burst
    // transaction — check its base address and length instead of per-beat
    // addresses.
    logic [31:0] fill_req_addr;
    logic [3:0]  fill_req_len;
    int          fill_reqs_seen;
    always @(posedge clk) begin
        if (!rst && req_valid && req_ready && req.op == MEM_READ) begin
            fill_req_addr  <= req.addr;
            fill_req_len   <= req.len;
            fill_reqs_seen <= fill_reqs_seen + 1;
        end
    end

    initial begin
        // BRAM: word i holds 0xA0000000 | i (word index)
        for (int i = 0; i < 1024; i++) u_mem.mem[i] = 32'hA000_0000 | i;
        fill_reqs_seen = 0;

        cpu_addr = '0; cpu_ren = 0; cpu_wen = 0; cpu_wstrb = '0; cpu_wdata = '0;
        rst = 1;
        repeat (3) @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // ===================================================================
        // M1: Miss on word 0 of line at 0x40 (index 4). 4 stall cycles.
        // ===================================================================
        $display("\n--- M1: 4-beat fill on read miss ---");
        fill_reqs_seen = 0;
        read_and_wait(32'h0000_0040, rd, st);
        check("M1.stall_cycles_eq_4", st == 4);
        check("M1.rdata", rd === (32'hA000_0000 | 'h10));   // word idx 0x10
        idle_cycle;
        check("M1.one_burst_req",  fill_reqs_seen == 1);
        check("M1.burst_base",     fill_req_addr === 32'h0000_0040);
        check("M1.burst_len_4",    fill_req_len  === mem_len_for(4));

        // ===================================================================
        // M2: Spatial locality — words 1..3 of the same line all hit.
        // ===================================================================
        $display("\n--- M2: neighboring words hit ---");
        for (int w = 1; w < 4; w++) begin
            read_and_wait(32'h0000_0040 + 32'(4*w), rd, st);
            check($sformatf("M2.word%0d_hit", w), st == 0);
            check($sformatf("M2.word%0d_data", w), rd === (32'hA000_0000 | (32'h10 + 32'(w))));
            idle_cycle;
        end

        // ===================================================================
        // M3: Miss with requested word != 0 (word 2 of line at 0x80).
        // ===================================================================
        $display("\n--- M3: miss on non-zero word offset ---");
        read_and_wait(32'h0000_0088, rd, st);   // word idx 0x22
        check("M3.stalls", st == 4);
        check("M3.rdata_is_word2", rd === (32'hA000_0000 | 'h22));
        idle_cycle;
        read_and_wait(32'h0000_0080, rd, st);   // word 0 of same line: hit
        check("M3.word0_now_hits", st == 0);
        check("M3.word0_data", rd === (32'hA000_0000 | 'h20));
        idle_cycle;

        // ===================================================================
        // M4: Store hit to word 2 of the 0x40 line.
        // ===================================================================
        $display("\n--- M4: store hit updates the right word ---");
        cpu_addr  = 32'h0000_0048;  // word 2 of line 0x40
        cpu_wen   = 1;
        cpu_wstrb = 4'hF;
        cpu_wdata = 32'hDEAD_BEEF;
        #1;
        check("M4.no_stall_store", dmem_stall === 1'b0);
        check("M4.writethrough",   req_valid === 1'b1 && req.op === MEM_WRITE
                                   && req.addr === 32'h0000_0048);
        @(posedge clk); #1;
        cpu_wen = 0; cpu_wstrb = '0; cpu_addr = '0;
        idle_cycle;

        read_and_wait(32'h0000_0048, rd, st);
        check("M4.hit_after_store", st == 0);
        check("M4.new_data",        rd === 32'hDEAD_BEEF);
        idle_cycle;
        read_and_wait(32'h0000_0044, rd, st);
        check("M4.neighbor_untouched", rd === (32'hA000_0000 | 'h11));
        idle_cycle;

        // ===================================================================
        // M5: Store miss — no allocate.
        // ===================================================================
        $display("\n--- M5: store miss does not allocate ---");
        cpu_addr  = 32'h0000_0300;  // index 6 line, not cached
        cpu_wen   = 1;
        cpu_wstrb = 4'hF;
        cpu_wdata = 32'h1234_5678;
        #1;
        check("M5.no_stall", dmem_stall === 1'b0);
        @(posedge clk); #1;
        cpu_wen = 0; cpu_wstrb = '0; cpu_addr = '0;
        idle_cycle;
        read_and_wait(32'h0000_0300, rd, st);
        check("M5.read_misses", st == 4);
        check("M5.stored_value_from_bram", rd === 32'h1234_5678);
        idle_cycle;

        // ===================================================================
        // M6: Aliasing — 0x40 and 0x40+128 share index 4; eviction is whole-line.
        // ===================================================================
        $display("\n--- M6: whole-line eviction on alias ---");
        read_and_wait(32'h0000_00C0, rd, st);   // index 4, different tag
        check("M6.alias_miss", st == 4);
        idle_cycle;
        read_and_wait(32'h0000_0044, rd, st);   // old line word 1: evicted
        check("M6.old_line_evicted", st == 4);
        check("M6.old_line_data_back", rd === (32'hA000_0000 | 'h11));
        idle_cycle;

        // ===================================================================
        // M7: Counter totals for the exact sequence above.
        //     Misses: M1, M3, M5-read, M6-alias, M6-refetch          = 5
        //     Hits:   M2 (3), M3-word0, M4-read, M4-neighbor         = 6
        // ===================================================================
        $display("\n--- M7: counters ---");
        check("M7.miss_count", miss_count === 32'd5);
        check("M7.hit_count",  hit_count  === 32'd6);

        repeat (2) idle_cycle;
        $display("\n===== tb_dcache_multiword: %0d passed, %0d failed =====",
                 pass_count, fail_count);
        if (fail_count != 0) $fatal(1, "tb_dcache_multiword: FAILURES detected");
        $finish;
    end

    initial begin
        #50000;
        $fatal(1, "tb_dcache_multiword: timeout");
    end

endmodule : tb_dcache_multiword

`default_nettype wire
