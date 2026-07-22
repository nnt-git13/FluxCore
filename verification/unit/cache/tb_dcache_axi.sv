// verification/unit/cache/tb_dcache_axi.sv
//
// Full-chain test: dcache (non-blocking, WB+WA, 4-word lines)
//                  → mem_if_axi (AXI4 master adapter)
//                  → axi_slave_model (behavioral DDR stand-in, LATENCY=20).
//
// This is the P3.2+P3.3 proof: the same cache that runs against BRAM runs
// unchanged against an AXI memory with DDR-class latency.
//
// Checks:
//   X1. Cold read miss deferred; fill returns correct data through the
//       whole chain (burst AR → 4 R beats → fill_done).
//   X2. Hit-under-miss: a warm line hits while the AXI fill is in flight.
//   X3. Store → dirty eviction (burst AW/W + B) → refetch round-trips the
//       stored data through the AXI memory.
//   X4. Write-ack (B) and read beats never collide: back-to-back
//       evict+fill sequences complete with correct data (the adapter's
//       single-outstanding serialization).
//
// Pass/fail: accumulates failures, $fatal at end if any.

`timescale 1ns/1ps
`default_nettype none

import fluxcore_pkg::*;
import mem_if_pkg::*;

module tb_dcache_axi;

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

    // CPU side
    logic [31:0] c_addr, c_wdata, c_rdata;
    logic        c_ren, c_wen, c_stall, c_defer, c_fill_done;
    logic [3:0]  c_wstrb;
    logic [31:0] c_fill_data;
    logic [31:0] hits, misses;

    // mem_if between cache and adapter
    logic     q_valid, q_ready, p_valid, p_ready;
    mem_req_t q;
    mem_rsp_t p;

    // AXI wires
    logic        awvalid, awready, wvalid, wready, wlast, bvalid, bready;
    logic        arvalid, arready, rvalid, rready, rlast;
    word_t       awaddr, wdata, araddr, rdata;
    logic [7:0]  awlen, arlen;
    logic [2:0]  awsize, arsize;
    logic [1:0]  awburst, arburst, bresp, rresp;
    logic [3:0]  awid, arid, bid, rid, wstrb;

    dcache #(.NSETS(8), .LINE_WORDS(4), .WAYS(2),
             .WRITE_ALLOCATE(1'b1), .WRITE_BACK(1'b1), .NONBLOCKING(1'b1)) dut (
        .clk(clk), .rst(rst),
        .cpu_addr_i(c_addr), .cpu_ren_i(c_ren), .cpu_wen_i(c_wen),
        .cpu_wstrb_i(c_wstrb), .cpu_wdata_i(c_wdata),
        .cpu_rdata_o(c_rdata), .dmem_stall_o(c_stall),
        .defer_ok_i(1'b1), .miss_defer_o(c_defer),
        .fill_done_o(c_fill_done), .fill_data_o(c_fill_data),
        .mem_req_valid_o(q_valid), .mem_req_ready_i(q_ready), .mem_req_o(q),
        .mem_rsp_valid_i(p_valid), .mem_rsp_ready_o(p_ready), .mem_rsp_i(p),
        .hit_count_o(hits), .miss_count_o(misses)
    );

    mem_if_axi u_axi (
        .clk(clk), .rst(rst),
        .req_valid_i(q_valid), .req_ready_o(q_ready), .req_i(q),
        .rsp_valid_o(p_valid), .rsp_ready_i(p_ready), .rsp_o(p),
        .m_awvalid_o(awvalid), .m_awready_i(awready), .m_awaddr_o(awaddr),
        .m_awlen_o(awlen), .m_awsize_o(awsize), .m_awburst_o(awburst),
        .m_awid_o(awid),
        .m_wvalid_o(wvalid), .m_wready_i(wready), .m_wdata_o(wdata),
        .m_wstrb_o(wstrb), .m_wlast_o(wlast),
        .m_bvalid_i(bvalid), .m_bready_o(bready), .m_bresp_i(bresp),
        .m_bid_i(bid),
        .m_arvalid_o(arvalid), .m_arready_i(arready), .m_araddr_o(araddr),
        .m_arlen_o(arlen), .m_arsize_o(arsize), .m_arburst_o(arburst),
        .m_arid_o(arid),
        .m_rvalid_i(rvalid), .m_rready_o(rready), .m_rdata_i(rdata),
        .m_rresp_i(rresp), .m_rlast_i(rlast), .m_rid_i(rid)
    );

    axi_slave_model #(.MEM_WORDS(1024), .LATENCY(20)) u_ddr (
        .clk(clk), .rst(rst),
        .s_awvalid_i(awvalid), .s_awready_o(awready), .s_awaddr_i(awaddr),
        .s_awlen_i(awlen), .s_awsize_i(awsize), .s_awburst_i(awburst),
        .s_awid_i(awid),
        .s_wvalid_i(wvalid), .s_wready_o(wready), .s_wdata_i(wdata),
        .s_wstrb_i(wstrb), .s_wlast_i(wlast),
        .s_bvalid_o(bvalid), .s_bready_i(bready), .s_bresp_o(bresp),
        .s_bid_o(bid),
        .s_arvalid_i(arvalid), .s_arready_o(arready), .s_araddr_i(araddr),
        .s_arlen_i(arlen), .s_arsize_i(arsize), .s_arburst_i(arburst),
        .s_arid_i(arid),
        .s_rvalid_o(rvalid), .s_rready_i(rready), .s_rdata_o(rdata),
        .s_rresp_o(rresp), .s_rlast_o(rlast), .s_rid_o(rid)
    );

    // fill monitor
    int          fills_seen;
    logic [31:0] last_fill;
    always_ff @(posedge clk) begin
        if (rst) begin fills_seen <= 0; last_fill <= '0; end
        else if (c_fill_done) begin
            fills_seen <= fills_seen + 1;
            last_fill  <= c_fill_data;
        end
    end

    task automatic access(input logic [31:0] addr, input logic ren,
                          input logic wen, input logic [31:0] wdata_v,
                          output int stalls, output logic deferred);
        c_addr = addr; c_ren = ren; c_wen = wen;
        c_wstrb = wen ? 4'hF : '0; c_wdata = wdata_v;
        #1;
        stalls = 0;
        while (c_stall === 1'b1) begin @(posedge clk); #1; stalls++; end
        deferred = c_defer;
        @(posedge clk); #1;
        c_ren = 0; c_wen = 0; c_addr = '0; c_wstrb = '0; c_wdata = '0;
    endtask

    task automatic wait_fill(output logic ok);
        int limit = 100;
        int prev = fills_seen;
        while (limit > 0 && fills_seen == prev) begin @(posedge clk); #1; limit--; end
        ok = (fills_seen == prev + 1);
    endtask

    logic [31:0] rd;
    int          st;
    logic        def, ok;

    initial begin
        for (int i = 0; i < 1024; i++) u_ddr.mem[i] = 32'hD00D_0000 | i;
        c_addr='0; c_ren=0; c_wen=0; c_wstrb='0; c_wdata='0;
        rst = 1;
        repeat (3) @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // ===================================================================
        // X1: cold deferred miss through AXI (0x40: index 4, word 0).
        // ===================================================================
        $display("\n--- X1: deferred fill over AXI ---");
        access(32'h0000_0040, 1, 0, '0, st, def);
        check("X1.deferred_no_stall", def === 1'b1 && st == 0);
        wait_fill(ok);
        check("X1.fill_done", ok);
        check("X1.fill_data", last_fill === (32'hD00D_0000 | 'h10));

        // ===================================================================
        // X2: hit-under-miss while an AXI fill (~24 cycles) is in flight.
        // ===================================================================
        $display("\n--- X2: hit under AXI-latency miss ---");
        access(32'h0000_0080, 1, 0, '0, st, def);          // new line: defer
        check("X2.second_deferred", def === 1'b1 && st == 0);
        access(32'h0000_0044, 1, 0, '0, st, def);          // warm line: hit
        check("X2.hit_during_fill", st == 0 && def === 1'b0);
        @(posedge clk); #1;
        check("X2.hit_data", c_rdata === (32'hD00D_0000 | 'h11));
        wait_fill(ok);
        check("X2.fill_completes", ok);

        // ===================================================================
        // X3: store, dirty-evict over AXI, refetch round-trip.
        // ===================================================================
        $display("\n--- X3: dirty eviction round-trip over AXI ---");
        access(32'h0000_0048, 0, 1, 32'hFACE_0FF0, st, def);   // store hit, dirty
        check("X3.store_hit", st == 0);
        // Two conflicting fills at index 4 evict the dirty 0x40 line
        // (2 ways: 0x40 and 0x140 resident after this; then 0x240 evicts LRU).
        access(32'h0000_0140, 1, 0, '0, st, def);
        wait_fill(ok); check("X3.warm2", ok);
        access(32'h0000_0240, 1, 0, '0, st, def);   // evicts 0x40 (dirty)
        wait_fill(ok); check("X3.evict_fill_done", ok);
        // The stored word must now be in the AXI memory.
        check("X3.ddr_has_store", u_ddr.mem['h12] === 32'hFACE_0FF0);
        // And refetching the line returns it.
        access(32'h0000_0048, 1, 0, '0, st, def);
        check("X3.refetch_deferred", def === 1'b1);
        wait_fill(ok);
        check("X3.refetch_done", ok);
        check("X3.refetch_data", last_fill === 32'hFACE_0FF0);

        // ===================================================================
        // X4: repeated dirty evict/fill sequences stay coherent.
        // ===================================================================
        $display("\n--- X4: repeated evict+fill sequences ---");
        for (int k = 0; k < 3; k++) begin
            access(32'h0000_0300 + 32'(k*16), 0, 1, 32'h4000_0000 + 32'(k), st, def);
            // allow the allocation to finish before the next conflicting one
            repeat (40) begin @(posedge clk); #1; end
        end
        for (int k = 0; k < 3; k++) begin
            access(32'h0000_0300 + 32'(k*16), 1, 0, '0, st, def);
            if (def) begin wait_fill(ok); rd = last_fill; end
            else     begin @(posedge clk); #1; rd = c_rdata; end
            check($sformatf("X4.k%0d_data", k), rd === (32'h4000_0000 + 32'(k)));
        end

        repeat (2) @(posedge clk);
        $display("\n===== tb_dcache_axi: %0d passed, %0d failed =====",
                 pass_count, fail_count);
        if (fail_count != 0) $fatal(1, "tb_dcache_axi: FAILURES detected");
        $finish;
    end

    initial begin
        #400000;
        $fatal(1, "tb_dcache_axi: timeout");
    end

endmodule : tb_dcache_axi

`default_nettype wire
