// verification/unit/cache/tb_dcache_wb.sv
//
// Unit test for dcache.sv write policies: write-allocate + write-back.
//
// DUT A (WB+WA): NSETS=4, LINE_WORDS=2, WAYS=1, WRITE_ALLOCATE=1, WRITE_BACK=1.
//   Geometry: byte off [1:0], word off [2], index [4:3], tag [31:5].
//   W1. Store miss allocates: 2 stall cycles (clean victim), then the line
//       hits — and memory was NOT written (write-back absorbs the store).
//   W2. Store hit dirties the line, still no memory write.
//   W3. Conflicting read evicts the dirty line: 4 stalls (evict 2 + req 1 +
//       fill 1), memory now holds BOTH stored words; re-reading the original
//       line misses and returns the stored values from memory.
//   W4. Clean eviction writes nothing: fill by read, evict by conflict,
//       memory write count unchanged.
//
// DUT B (WT+WA): NSETS=4, LINE_WORDS=1, WAYS=1, WRITE_ALLOCATE=1.
//   T1. Store miss: 2 stalls (write-through cycle + FILLREQ), line then
//       hits with the stored value — and memory ALSO has it immediately.
//
// Memory writes are counted via mem_wen pulses to pin down exactly when the
// backing store is touched — the essence of the write-back contract.
//
// Pass/fail: accumulates failures, $fatal at end if any.

`timescale 1ns/1ps
`default_nettype none

import fluxcore_pkg::*;
import mem_if_pkg::*;

module tb_dcache_wb;

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

    // =======================================================================
    // DUT A: write-back + write-allocate, 2-word lines
    // =======================================================================
    logic [31:0] a_addr, a_wdata, a_rdata;
    logic        a_ren, a_wen, a_stall;
    logic [3:0]  a_wstrb;
    logic [31:0] a_hits, a_misses;
    logic        a_req_valid, a_req_ready, a_rsp_valid, a_rsp_ready;
    mem_req_t    a_req;
    mem_rsp_t    a_rsp;
    int          a_memwrites;

    // Backing store: P0 sim memory, LATENCY=1 = bare-BRAM timing.
    mem_model #(.MEM_WORDS(1024), .LATENCY(1)) u_mema (
        .clk(clk), .rst(rst),
        .req_valid_i(a_req_valid), .req_ready_o(a_req_ready), .req_i(a_req),
        .rsp_valid_o(a_rsp_valid), .rsp_ready_i(a_rsp_ready), .rsp_o(a_rsp)
    );

    // Memory-write counter: accepted write request beats on the mem_if
    // channel (burst evictions count one per beat, same as before).
    always_ff @(posedge clk) begin
        if (rst)                                              a_memwrites <= 0;
        else if (a_req_valid && a_req_ready
                 && a_req.op == MEM_WRITE)                    a_memwrites <= a_memwrites + 1;
    end

    dcache #(.NSETS(4), .LINE_WORDS(2), .WAYS(1),
             .WRITE_ALLOCATE(1'b1), .WRITE_BACK(1'b1)) dut_a (
        .clk(clk), .rst(rst),
        .cpu_addr_i(a_addr), .cpu_ren_i(a_ren), .cpu_wen_i(a_wen),
        .cpu_wstrb_i(a_wstrb), .cpu_wdata_i(a_wdata),
        .cpu_rdata_o(a_rdata), .dmem_stall_o(a_stall),
        .mem_req_valid_o(a_req_valid), .mem_req_ready_i(a_req_ready),
        .mem_req_o(a_req), .mem_rsp_valid_i(a_rsp_valid),
        .mem_rsp_ready_o(a_rsp_ready), .mem_rsp_i(a_rsp),
        .hit_count_o(a_hits), .miss_count_o(a_misses)
    );

    // Pipeline-faithful read: hold while stalled, complete, sample in WB cycle.
    task automatic rda(input logic [31:0] addr, output logic [31:0] data,
                       output int stalls);
        a_addr = addr; a_ren = 1;
        #1;
        stalls = 0;
        while (a_stall === 1'b1) begin @(posedge clk); #1; stalls++; end
        @(posedge clk); #1;
        a_ren = 0; a_addr = '0;
        data = a_rdata;
        @(posedge clk); #1;
    endtask

    // Pipeline-faithful store: held in MEM while stalled (allocating misses).
    task automatic wra(input logic [31:0] addr, input logic [31:0] wdata,
                       output int stalls);
        a_addr = addr; a_wen = 1; a_wstrb = 4'hF; a_wdata = wdata;
        #1;
        stalls = 0;
        while (a_stall === 1'b1) begin @(posedge clk); #1; stalls++; end
        @(posedge clk); #1;
        a_wen = 0; a_wstrb = '0; a_addr = '0; a_wdata = '0;
        @(posedge clk); #1;
    endtask

    // =======================================================================
    // DUT B: write-through + write-allocate, 1-word lines
    // =======================================================================
    logic [31:0] b_addr, b_wdata, b_rdata;
    logic        b_ren, b_wen, b_stall;
    logic [3:0]  b_wstrb;
    logic [31:0] b_hits, b_misses;
    logic        b_req_valid, b_req_ready, b_rsp_valid, b_rsp_ready;
    mem_req_t    b_req;
    mem_rsp_t    b_rsp;

    // Backing store: P0 sim memory, LATENCY=1 = bare-BRAM timing.
    mem_model #(.MEM_WORDS(1024), .LATENCY(1)) u_memb (
        .clk(clk), .rst(rst),
        .req_valid_i(b_req_valid), .req_ready_o(b_req_ready), .req_i(b_req),
        .rsp_valid_o(b_rsp_valid), .rsp_ready_i(b_rsp_ready), .rsp_o(b_rsp)
    );

    dcache #(.NSETS(4), .LINE_WORDS(1), .WAYS(1),
             .WRITE_ALLOCATE(1'b1), .WRITE_BACK(1'b0)) dut_b (
        .clk(clk), .rst(rst),
        .cpu_addr_i(b_addr), .cpu_ren_i(b_ren), .cpu_wen_i(b_wen),
        .cpu_wstrb_i(b_wstrb), .cpu_wdata_i(b_wdata),
        .cpu_rdata_o(b_rdata), .dmem_stall_o(b_stall),
        .mem_req_valid_o(b_req_valid), .mem_req_ready_i(b_req_ready),
        .mem_req_o(b_req), .mem_rsp_valid_i(b_rsp_valid),
        .mem_rsp_ready_o(b_rsp_ready), .mem_rsp_i(b_rsp),
        .hit_count_o(b_hits), .miss_count_o(b_misses)
    );

    task automatic rdb(input logic [31:0] addr, output logic [31:0] data,
                       output int stalls);
        b_addr = addr; b_ren = 1;
        #1;
        stalls = 0;
        while (b_stall === 1'b1) begin @(posedge clk); #1; stalls++; end
        @(posedge clk); #1;
        b_ren = 0; b_addr = '0;
        data = b_rdata;
        @(posedge clk); #1;
    endtask

    task automatic wrb(input logic [31:0] addr, input logic [31:0] wdata,
                       output int stalls);
        b_addr = addr; b_wen = 1; b_wstrb = 4'hF; b_wdata = wdata;
        #1;
        stalls = 0;
        while (b_stall === 1'b1) begin @(posedge clk); #1; stalls++; end
        @(posedge clk); #1;
        b_wen = 0; b_wstrb = '0; b_addr = '0; b_wdata = '0;
        @(posedge clk); #1;
    endtask

    // =======================================================================
    // Test body
    // =======================================================================
    logic [31:0] rd;
    int          st, wr_before;

    // DUT A addresses, all index 0 (bits [4:3] = 00), 8-byte lines:
    localparam logic [31:0] LA  = 32'h0000_0000;  // line A word 0
    localparam logic [31:0] LA1 = 32'h0000_0004;  // line A word 1
    localparam logic [31:0] LB  = 32'h0000_0020;  // conflicting line B word 0
    localparam logic [31:0] LC  = 32'h0000_0040;  // conflicting line C word 0

    initial begin
        for (int i = 0; i < 1024; i++) begin
            u_mema.mem[i] = 32'hAB00_0000 | i;
            u_memb.mem[i] = 32'hCD00_0000 | i;
        end
        a_addr='0; a_ren=0; a_wen=0; a_wstrb='0; a_wdata='0;
        b_addr='0; b_ren=0; b_wen=0; b_wstrb='0; b_wdata='0;
        rst = 1;
        repeat (3) @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // ===================================================================
        // W1: store miss allocates; memory NOT written.
        // ===================================================================
        $display("\n--- W1: write-back store-miss allocation ---");
        wr_before = a_memwrites;
        wra(LA, 32'h1111_1111, st);
        check("W1.store_stalls_for_fill", st == 2);          // clean victim, W=2
        check("W1.no_mem_write", a_memwrites == wr_before);  // absorbed
        check("W1.bram_untouched", u_mema.mem[LA >> 2] === (32'hAB00_0000 | (LA >> 2)));
        rda(LA, rd, st);
        check("W1.line_hits", st == 0);
        check("W1.stored_data", rd === 32'h1111_1111);
        rda(LA1, rd, st);
        check("W1.neighbor_filled", st == 0);
        check("W1.neighbor_data", rd === (32'hAB00_0000 | (LA1 >> 2)));

        // ===================================================================
        // W2: store hit dirties without memory write.
        // ===================================================================
        $display("\n--- W2: write-back store-hit absorption ---");
        wr_before = a_memwrites;
        wra(LA1, 32'h2222_2222, st);
        check("W2.hit_no_stall", st == 0);
        check("W2.no_mem_write", a_memwrites == wr_before);
        rda(LA1, rd, st);
        check("W2.hit_new_data", rd === 32'h2222_2222);

        // ===================================================================
        // W3: dirty eviction on conflict.
        // ===================================================================
        $display("\n--- W3: dirty eviction writes the line back ---");
        wr_before = a_memwrites;
        rda(LB, rd, st);
        check("W3.evict_stalls", st == 5);   // evict 2 + ack shadow 1 + fillreq 1 + fill 1
        check("W3.two_writeback_beats", a_memwrites == wr_before + 2);
        check("W3.mem_word0", u_mema.mem[LA  >> 2] === 32'h1111_1111);
        check("W3.mem_word1", u_mema.mem[LA1 >> 2] === 32'h2222_2222);
        check("W3.read_data_ok", rd === (32'hAB00_0000 | (LB >> 2)));
        // Original line comes back from memory with the stored values.
        rda(LA, rd, st);
        check("W3.orig_missed", st == 4 || st == 2);  // victim LB is clean → 2
        check("W3.orig_word0_roundtrip", rd === 32'h1111_1111);

        // ===================================================================
        // W4: clean eviction writes nothing.
        // ===================================================================
        $display("\n--- W4: clean eviction is silent ---");
        wr_before = a_memwrites;
        rda(LC, rd, st);                     // evicts LA (clean: only read since fill)
        check("W4.clean_evict_stalls", st == 2);
        check("W4.no_writeback", a_memwrites == wr_before);

        // ===================================================================
        // T1: write-through + allocate.
        // ===================================================================
        $display("\n--- T1: write-through store-miss allocation ---");
        wrb(32'h0000_0008, 32'h3333_3333, st);
        check("T1.store_stalls", st == 3);   // WT write + ack shadow + FILLREQ
        check("T1.mem_has_it_now", u_memb.mem[2] === 32'h3333_3333);
        rdb(32'h0000_0008, rd, st);
        check("T1.line_hits", st == 0);
        check("T1.data", rd === 32'h3333_3333);

        repeat (2) @(posedge clk);
        $display("\n===== tb_dcache_wb: %0d passed, %0d failed =====",
                 pass_count, fail_count);
        if (fail_count != 0) $fatal(1, "tb_dcache_wb: FAILURES detected");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "tb_dcache_wb: timeout");
    end

endmodule : tb_dcache_wb

`default_nettype wire
