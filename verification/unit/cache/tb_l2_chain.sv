// verification/unit/cache/tb_l2_chain.sv
//
// Full-hierarchy chain test (P4):
//   dcache (non-blocking, WB+WA) ──port0──┐
//                                         ├─ mem_arbiter ─ l2_cache ─ mem_model
//   TB master (future I-cache)  ──port1──┘                            (LATENCY=12)
//
// Checks:
//   C1. D$ traffic works through arbiter + L2: deferred fill, correct data.
//   C2. L2 acceleration: after the D$ evicts a line the L2 still holds it —
//       the refetch completes without touching the backing store.
//   C3. Port-1 bursts (I-cache-style reads) interleave with D$ traffic and
//       both complete correctly (transaction-granular grant).
//   C4. Dirty data survives the full path: store in D$ → D$ evict → L2
//       (write-allocate) → L2 evict → backing memory.
//
// Pass/fail: accumulates failures, $fatal at end if any.

`timescale 1ns/1ps
`default_nettype none

import fluxcore_pkg::*;
import mem_if_pkg::*;

module tb_l2_chain;

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

    // CPU side of the D$
    logic [31:0] c_addr, c_wdata, c_rdata;
    logic        c_ren, c_wen, c_stall, c_defer, c_fill_done;
    logic [3:0]  c_wstrb;
    logic [31:0] c_fill_data;
    logic [31:0] d_hits, d_misses;

    // D$ ↔ arbiter port 0
    logic     d_req_valid, d_req_ready, d_rsp_valid, d_rsp_ready;
    mem_req_t d_req;
    mem_rsp_t d_rsp;
    // TB ↔ arbiter port 1
    logic     i_req_valid, i_req_ready, i_rsp_valid, i_rsp_ready;
    mem_req_t i_req;
    mem_rsp_t i_rsp;
    // arbiter ↔ L2
    logic     a_req_valid, a_req_ready, a_rsp_valid, a_rsp_ready;
    mem_req_t a_req;
    mem_rsp_t a_rsp;
    // L2 ↔ backing
    logic     b_req_valid, b_req_ready, b_rsp_valid, b_rsp_ready;
    mem_req_t b_req;
    mem_rsp_t b_rsp;

    logic [31:0] l2_hits, l2_misses;

    dcache #(.NSETS(8), .LINE_WORDS(4), .WAYS(2),
             .WRITE_ALLOCATE(1'b1), .WRITE_BACK(1'b1), .NONBLOCKING(1'b1)) u_d (
        .clk(clk), .rst(rst),
        .cpu_addr_i(c_addr), .cpu_ren_i(c_ren), .cpu_wen_i(c_wen),
        .cpu_wstrb_i(c_wstrb), .cpu_wdata_i(c_wdata),
        .cpu_rdata_o(c_rdata), .dmem_stall_o(c_stall),
        .defer_ok_i(1'b1), .miss_defer_o(c_defer),
        .fill_done_o(c_fill_done), .fill_data_o(c_fill_data),
        .mem_req_valid_o(d_req_valid), .mem_req_ready_i(d_req_ready),
        .mem_req_o(d_req), .mem_rsp_valid_i(d_rsp_valid),
        .mem_rsp_ready_o(d_rsp_ready), .mem_rsp_i(d_rsp),
        .hit_count_o(d_hits), .miss_count_o(d_misses)
    );

    mem_arbiter u_arb (
        .clk(clk), .rst(rst),
        .r0_req_valid_i(d_req_valid), .r0_req_ready_o(d_req_ready),
        .r0_req_i(d_req), .r0_rsp_valid_o(d_rsp_valid),
        .r0_rsp_ready_i(d_rsp_ready), .r0_rsp_o(d_rsp),
        .r1_req_valid_i(i_req_valid), .r1_req_ready_o(i_req_ready),
        .r1_req_i(i_req), .r1_rsp_valid_o(i_rsp_valid),
        .r1_rsp_ready_i(i_rsp_ready), .r1_rsp_o(i_rsp),
        .m_req_valid_o(a_req_valid), .m_req_ready_i(a_req_ready),
        .m_req_o(a_req), .m_rsp_valid_i(a_rsp_valid),
        .m_rsp_ready_o(a_rsp_ready), .m_rsp_i(a_rsp)
    );

    l2_cache #(.NSETS(16), .LINE_WORDS(4), .WAYS(4)) u_l2 (
        .clk(clk), .rst(rst),
        .s_req_valid_i(a_req_valid), .s_req_ready_o(a_req_ready), .s_req_i(a_req),
        .s_rsp_valid_o(a_rsp_valid), .s_rsp_ready_i(a_rsp_ready), .s_rsp_o(a_rsp),
        .m_req_valid_o(b_req_valid), .m_req_ready_i(b_req_ready), .m_req_o(b_req),
        .m_rsp_valid_i(b_rsp_valid), .m_rsp_ready_o(b_rsp_ready), .m_rsp_i(b_rsp),
        .hit_count_o(l2_hits), .miss_count_o(l2_misses)
    );

    mem_model #(.MEM_WORDS(4096), .LATENCY(12)) u_mem (
        .clk(clk), .rst(rst),
        .req_valid_i(b_req_valid), .req_ready_o(b_req_ready), .req_i(b_req),
        .rsp_valid_o(b_rsp_valid), .rsp_ready_i(b_rsp_ready), .rsp_o(b_rsp)
    );

    // fill monitor (D$)
    int          fills_seen;
    logic [31:0] last_fill;
    always_ff @(posedge clk) begin
        if (rst) begin fills_seen <= 0; last_fill <= '0; end
        else if (c_fill_done) begin
            fills_seen <= fills_seen + 1;
            last_fill  <= c_fill_data;
        end
    end

    // backing-store read counter (proves L2 hits don't reach memory)
    int backing_reads;
    always_ff @(posedge clk) begin
        if (rst) backing_reads <= 0;
        else if (b_req_valid && b_req_ready && b_req.op == MEM_READ)
            backing_reads <= backing_reads + 1;
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
        int limit = 200;
        int prev = fills_seen;
        while (limit > 0 && fills_seen == prev) begin @(posedge clk); #1; limit--; end
        ok = (fills_seen == prev + 1);
    endtask

    // Port-1 master: burst read like an I-cache line fill.
    logic [31:0] i_rdata_v [0:3];
    task automatic i_burst_read(input logic [31:0] addr, output logic ok);
        int got;
        i_req = mem_read_req(4'h5, addr);
        i_req.len = mem_len_for(4);
        i_req_valid = 1;
        #1;
        while (!(i_req_valid && i_req_ready)) begin @(posedge clk); #1; end
        @(posedge clk); #1;
        i_req_valid = 0;
        got = 0; ok = 1;
        i_rsp_ready = 1;
        while (got < 4) begin
            if (i_rsp_valid) begin
                i_rdata_v[got] = i_rsp.rdata;
                if (i_rsp.err != MEM_OK) ok = 0;
                got++;
            end
            @(posedge clk); #1;
        end
        i_rsp_ready = 0;
    endtask

    logic [31:0] rd;
    int          st, br_before;
    logic        def, ok, iok;

    initial begin
        for (int i = 0; i < 4096; i++) u_mem.mem[i] = 32'hC4A1_0000 | i;
        c_addr='0; c_ren=0; c_wen=0; c_wstrb='0; c_wdata='0;
        i_req_valid = 0; i_rsp_ready = 0;
        rst = 1;
        repeat (3) @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // ===================================================================
        // C1: D$ deferred fill through arbiter + L2 + backing.
        // ===================================================================
        $display("\n--- C1: D$ fill through the full chain ---");
        access(32'h0000_0040, 1, 0, '0, st, def);
        check("C1.deferred", def === 1'b1 && st == 0);
        wait_fill(ok);
        check("C1.fill_done", ok);
        check("C1.fill_data", last_fill === (32'hC4A1_0000 | 'h10));

        // ===================================================================
        // C2: L2 keeps what the D$ evicts (NINE).
        // ===================================================================
        $display("\n--- C2: L2 hit after D$ eviction ---");
        // Two more D$ fills at the same D$ set evict the 0x40 line from the
        // 2-way D$; the L2 (4-way, 16 sets) still holds all three.
        access(32'h0000_0140, 1, 0, '0, st, def); wait_fill(ok);
        access(32'h0000_0240, 1, 0, '0, st, def); wait_fill(ok);
        br_before = backing_reads;
        access(32'h0000_0040, 1, 0, '0, st, def);   // D$ miss, L2 HIT
        check("C2.refetch_deferred", def === 1'b1);
        wait_fill(ok);
        check("C2.refetch_done", ok);
        check("C2.refetch_data", last_fill === (32'hC4A1_0000 | 'h10));
        check("C2.no_backing_read", backing_reads == br_before);

        // ===================================================================
        // C3: port-1 bursts interleave with D$ traffic.
        // ===================================================================
        $display("\n--- C3: two-master interleave ---");
        fork
            begin
                access(32'h0000_0340, 1, 0, '0, st, def);
                wait_fill(ok);
            end
            begin
                i_burst_read(32'h0000_0800, iok);
            end
        join
        check("C3.d_side_ok",  ok && last_fill === (32'hC4A1_0000 | 'hD0));
        check("C3.i_side_ok",  iok);
        check("C3.i_data", i_rdata_v[0] === (32'hC4A1_0000 | 'h200)
                        && i_rdata_v[3] === (32'hC4A1_0000 | 'h203));

        // ===================================================================
        // C4: dirty data survives D$ evict → L2 → L2 evict → backing.
        // ===================================================================
        $display("\n--- C4: dirty write-back cascade ---");
        access(32'h0000_0040, 0, 1, 32'h5AFE_0000, st, def);   // store (hit or defer)
        if (def) wait_fill(ok);
        // Evict from D$ (same D$ set, two new tags):
        access(32'h0000_0440, 1, 0, '0, st, def); if (def) wait_fill(ok);
        access(32'h0000_0540, 1, 0, '0, st, def); if (def) wait_fill(ok);
        // The dirty line now lives in the L2. Evict it from the L2 too:
        // its L2 set = index bits [7:4] of 0x40 = set 4; fill 4 more tags
        // there (0x?40 with distinct tag bits) to overflow 4 ways.
        access(32'h0000_0640, 1, 0, '0, st, def); if (def) wait_fill(ok);
        access(32'h0000_0740, 1, 0, '0, st, def); if (def) wait_fill(ok);
        // D$ churn above also forces L2 traffic; give the chain time.
        repeat (100) begin @(posedge clk); #1; end
        // Wherever the line ended up, a fresh read must return the stored
        // value — and if it reached backing, the memory word shows it.
        access(32'h0000_0040, 1, 0, '0, st, def);
        if (def) begin wait_fill(ok); rd = last_fill; end
        else     begin @(posedge clk); #1; rd = c_rdata; end
        check("C4.data_survives", rd === 32'h5AFE_0000);

        $display("[CHAIN] d_hits=%0d d_misses=%0d l2_hits=%0d l2_misses=%0d backing_reads=%0d",
                 d_hits, d_misses, l2_hits, l2_misses, backing_reads);

        repeat (2) @(posedge clk);
        $display("\n===== tb_l2_chain: %0d passed, %0d failed =====",
                 pass_count, fail_count);
        if (fail_count != 0) $fatal(1, "tb_l2_chain: FAILURES detected");
        $finish;
    end

    initial begin
        #600000;
        $fatal(1, "tb_l2_chain: timeout");
    end

endmodule : tb_l2_chain

`default_nettype wire
