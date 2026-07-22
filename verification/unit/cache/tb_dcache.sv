// verification/unit/cache/tb_dcache.sv
//
// Unit test for rtl/cache/dcache.sv.
//
// Test plan:
//   S1. After reset: every access is a miss; no stall on writes.
//   S2. Read miss: dmem_stall_o=1 on miss cycle; next cycle data from BRAM.
//   S3. Read hit: same address after fill → dmem_stall_o=0, cpu_rdata_o=cached.
//   S4. Write-through hit: store updates BRAM and cache; subsequent read is a hit.
//   S5. Write-through miss: store goes to BRAM only; no stall; subsequent read misses.
//   S6. Tag aliasing: two addresses mapping to same index → eviction.
//   S7. Hit/miss counters increment correctly.

`timescale 1ns/1ps
`default_nettype none

import fluxcore_pkg::*;
import mem_if_pkg::*;

module tb_dcache;

    // -----------------------------------------------------------------------
    // DUT parameters
    // -----------------------------------------------------------------------
    localparam int NSETS    = 8;   // small for exhaustive aliasing tests
    localparam int INDEX_W  = $clog2(NSETS);   // 3
    localparam int TAG_W    = 32 - INDEX_W - 2; // 27

    // Clock
    logic clk = 0;
    always #5 clk = ~clk;

    // DUT ports
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

    // Backing store: the P0 sim memory at LATENCY=1 — timing-equivalent to
    // the bare BRAM the original TB modeled (accept at N, data during N+1).
    mem_model #(.MEM_WORDS(256), .LATENCY(1)) u_mem (
        .clk(clk), .rst(rst),
        .req_valid_i(req_valid), .req_ready_o(req_ready), .req_i(req),
        .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready), .rsp_o(rsp)
    );

    dcache #(.NSETS(NSETS)) dut (
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

    // -----------------------------------------------------------------------
    // Test helpers
    // -----------------------------------------------------------------------
    int  pass_count = 0;
    int  fail_count = 0;

    task check(input string name, input logic cond);
        if (!cond) begin
            $display("FAIL  %0t  %s", $time, name);
            fail_count++;
        end else begin
            $display("PASS  %0t  %s", $time, name);
            pass_count++;
        end
    endtask

    // Single-cycle helper: drive combinatorial inputs for 1 cycle
    task drive(
        input logic [31:0] addr,
        input logic        ren,
        input logic        wen,
        input logic [3:0]  wstrb,
        input logic [31:0] wdata
    );
        cpu_addr  = addr;
        cpu_ren   = ren;
        cpu_wen   = wen;
        cpu_wstrb = wstrb;
        cpu_wdata = wdata;
        @(posedge clk); #1;
    endtask

    task idle_cycle;
        cpu_addr = '0; cpu_ren = 0; cpu_wen = 0; cpu_wstrb = '0; cpu_wdata = '0;
        @(posedge clk); #1;
    endtask

    // -----------------------------------------------------------------------
    // DUT reset
    // -----------------------------------------------------------------------
    initial begin
        // Initialize backing memory (hierarchical: sim-only preload)
        for (int i = 0; i < 256; i++) u_mem.mem[i] = 32'hA000_0000 | i;

        cpu_addr = '0; cpu_ren = 0; cpu_wen = 0; cpu_wstrb = '0; cpu_wdata = '0;
        rst = 1;
        repeat(3) @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // ===================================================================
        // S1: After reset, read should miss
        // ===================================================================
        $display("\n--- S1: Read miss after reset ---");
        // Cycle N: present load address → should see miss this cycle
        cpu_addr = 32'h0000_0008;  // index=2, tag=big number
        cpu_ren  = 1;
        // Sample combinatorial miss before posedge
        #0; // already 1ns after last posedge
        check("S1.miss_stall", dmem_stall === 1'b1);
        @(posedge clk); #1;  // posedge N: state→FILL, BRAM registers 0x8

        // Cycle N+1: FILL state — stall should be de-asserted
        check("S1.fill_nostall", dmem_stall === 1'b0);
        @(posedge clk); #1;  // posedge N+1: cache refilled, state→IDLE; cpu_rdata_q = bram[2]

        // Cycle N+2: IDLE — cpu_rdata should now hold bram[2] = 0xA000_0002
        cpu_ren = 0; cpu_addr = '0;
        check("S1.rdata_N2", cpu_rdata === (32'hA000_0000 | 2));

        // ===================================================================
        // S2: Hit on same address
        // ===================================================================
        $display("\n--- S2: Read hit on cached line ---");
        idle_cycle;

        cpu_addr = 32'h0000_0008;  // same address, now cached
        cpu_ren  = 1;
        check("S2.no_miss", dmem_stall === 1'b0);
        @(posedge clk); #1;
        // hit_count_q is registered at posedge — readable now (1ns after posedge)
        cpu_ren = 0; cpu_addr = '0;
        check("S2.hit_count_inc", hit_count === 32'd1);
        check("S2.rdata", cpu_rdata === (32'hA000_0000 | 2));

        // ===================================================================
        // S3: Write-through hit — store to cached address
        // ===================================================================
        $display("\n--- S3: Write-through hit ---");
        idle_cycle;

        // Store 0xDEAD_BEEF to address 0x8 (cached, index=2)
        cpu_addr  = 32'h0000_0008;
        cpu_wen   = 1;
        cpu_wstrb = 4'hF;
        cpu_wdata = 32'hDEAD_BEEF;
        #0;  // flush scheduler so always@(*) sees updated inputs
        check("S3.no_stall_store", dmem_stall === 1'b0);
        check("S3.req_is_write",   req_valid === 1'b1 && req.op === MEM_WRITE);
        check("S3.req_addr",       req.addr  === 32'h0000_0008);
        check("S3.req_wdata",      req.wdata === 32'hDEAD_BEEF);
        @(posedge clk); #1;  // bram gets updated; cache gets updated

        cpu_wen = 0; cpu_addr = '0; cpu_wstrb = '0;
        idle_cycle;

        // Now read back — should hit and return 0xDEAD_BEEF
        cpu_addr = 32'h0000_0008;
        cpu_ren  = 1;
        check("S3.hit_after_store", dmem_stall === 1'b0);
        @(posedge clk); #1;
        cpu_ren = 0; cpu_addr = '0;
        check("S3.rdata_after_store", cpu_rdata === 32'hDEAD_BEEF);

        // ===================================================================
        // S4: Write-through miss — store to uncached address; no stall
        // ===================================================================
        $display("\n--- S4: Write-through miss (no stall, no cache fill) ---");
        idle_cycle;

        // Address 0x100 = index=0, new tag → not cached
        cpu_addr  = 32'h0000_0100;
        cpu_wen   = 1;
        cpu_wstrb = 4'hF;
        cpu_wdata = 32'h1234_5678;
        #0;  // flush scheduler so always@(*) sees updated inputs
        check("S4.no_stall", dmem_stall === 1'b0);
        check("S4.write_req",    req_valid === 1'b1 && req.op === MEM_WRITE);
        @(posedge clk); #1;
        cpu_wen = 0; cpu_addr = '0;

        // Subsequent read to same address should MISS (no-write-allocate)
        idle_cycle;
        cpu_addr = 32'h0000_0100;
        cpu_ren  = 1;
        #0;
        check("S4.miss_after_store", dmem_stall === 1'b1);
        @(posedge clk); #1;  // FILL: BRAM presents value written by write-through store
        @(posedge clk); #1;  // back to IDLE
        cpu_ren = 0; cpu_addr = '0;
        check("S4.rdata_after_fill", cpu_rdata === 32'h1234_5678);

        // ===================================================================
        // S5: Tag aliasing — fill index=0 with two different tags
        // ===================================================================
        $display("\n--- S5: Tag aliasing / eviction ---");
        idle_cycle;

        // Fill index=0 tag A: address 0x000
        cpu_addr = 32'h0000_0000; cpu_ren = 1;
        #0;
        check("S5.first_miss", dmem_stall === 1'b1);
        @(posedge clk); #1;
        @(posedge clk); #1;
        cpu_ren = 0; cpu_addr = '0;

        idle_cycle;
        // Hit check
        cpu_addr = 32'h0000_0000; cpu_ren = 1;
        check("S5.hit_A", dmem_stall === 1'b0);
        @(posedge clk); #1;
        cpu_ren = 0; cpu_addr = '0;
        idle_cycle;

        // Access index=0 with different tag: address 0x100 already done above.
        // Use a fresh aliasing address: 0x200 (tag differs, same index=0)
        cpu_addr = 32'h0000_0200; cpu_ren = 1;
        #0;
        check("S5.alias_miss", dmem_stall === 1'b1);
        @(posedge clk); #1;
        @(posedge clk); #1;
        cpu_ren = 0; cpu_addr = '0;
        idle_cycle;

        // Now address 0x000 should miss (evicted by 0x200)
        cpu_addr = 32'h0000_0000; cpu_ren = 1;
        #0;
        check("S5.eviction_miss", dmem_stall === 1'b1);
        @(posedge clk); #1;
        @(posedge clk); #1;
        cpu_ren = 0; cpu_addr = '0;

        // ===================================================================
        // S6: Counter totals
        // ===================================================================
        $display("\n--- S6: Counters sanity ---");
        idle_cycle;
        check("S6.hit_count_nonzero",  hit_count  > 0);
        check("S6.miss_count_nonzero", miss_count > 0);

        // ===================================================================
        // Summary
        // ===================================================================
        repeat(2) idle_cycle;
        $display("\n============ tb_dcache: %0d passed, %0d failed ============",
                 pass_count, fail_count);
        if (fail_count != 0) $fatal(1, "tb_dcache: FAILURES detected");
        $finish;
    end

    initial begin
        #50000;
        $fatal(1, "tb_dcache: timeout");
    end

endmodule : tb_dcache

`default_nettype wire
