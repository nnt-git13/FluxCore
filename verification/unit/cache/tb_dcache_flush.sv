// verification/unit/cache/tb_dcache_flush.sv
//
// Unit test for the D-cache maintenance walk (flush_req_i / flush_busy_o).
//
//   FL1. Dirty several lines (write-back mode: memory untouched), pulse
//        flush_req_i, wait for flush_busy_o to drop.
//   FL2. Backing memory now holds every dirtied word.
//   FL3. The cache is fully invalidated: re-reads MISS and return the
//        flushed values from memory.
//   FL4. A flush of a clean cache completes quickly and writes nothing.
//
// Pass/fail: accumulates failures, $fatal at end if any.

`timescale 1ns/1ps
`default_nettype none

import fluxcore_pkg::*;
import mem_if_pkg::*;

module tb_dcache_flush;

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
    logic        c_ren, c_wen, c_stall, flush_req, flush_busy;
    logic [3:0]  c_wstrb;
    logic        req_valid, req_ready, rsp_valid, rsp_ready;
    mem_req_t    req;
    mem_rsp_t    rsp;
    logic [31:0] hits, misses;

    dcache #(.NSETS(4), .LINE_WORDS(2), .WAYS(2),
             .WRITE_ALLOCATE(1'b1), .WRITE_BACK(1'b1)) dut (
        .clk(clk), .rst(rst),
        .cpu_addr_i(c_addr), .cpu_ren_i(c_ren), .cpu_wen_i(c_wen),
        .cpu_wstrb_i(c_wstrb), .cpu_wdata_i(c_wdata),
        .cpu_rdata_o(c_rdata), .dmem_stall_o(c_stall),
        .flush_req_i(flush_req), .flush_busy_o(flush_busy),
        .mem_req_valid_o(req_valid), .mem_req_ready_i(req_ready), .mem_req_o(req),
        .mem_rsp_valid_i(rsp_valid), .mem_rsp_ready_o(rsp_ready), .mem_rsp_i(rsp),
        .hit_count_o(hits), .miss_count_o(misses)
    );

    mem_model #(.MEM_WORDS(1024), .LATENCY(1)) u_mem (
        .clk(clk), .rst(rst),
        .req_valid_i(req_valid), .req_ready_o(req_ready), .req_i(req),
        .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready), .rsp_o(rsp)
    );

    int wbeats;
    always_ff @(posedge clk) begin
        if (rst) wbeats <= 0;
        else if (req_valid && req_ready && req.op == MEM_WRITE)
            wbeats <= wbeats + 1;
    end

    task automatic store(input logic [31:0] addr, input logic [31:0] d);
        c_addr = addr; c_wen = 1; c_wstrb = 4'hF; c_wdata = d;
        #1;
        while (c_stall === 1'b1) begin @(posedge clk); #1; end
        @(posedge clk); #1;
        c_wen = 0; c_wstrb = '0; c_addr = '0; c_wdata = '0;
        @(posedge clk); #1;
    endtask

    task automatic load(input logic [31:0] addr, output logic [31:0] d,
                        output int stalls);
        c_addr = addr; c_ren = 1;
        #1;
        stalls = 0;
        while (c_stall === 1'b1) begin @(posedge clk); #1; stalls++; end
        @(posedge clk); #1;
        c_ren = 0; c_addr = '0;
        d = c_rdata;
        @(posedge clk); #1;
    endtask

    task automatic do_flush(output int cycles);
        @(negedge clk); flush_req = 1; @(negedge clk); flush_req = 0;
        cycles = 0;
        #1;
        while (flush_busy === 1'b1 || dut.state_q != 0) begin
            @(posedge clk); #1; cycles++;
            if (cycles > 2000) $fatal(1, "flush never completed");
        end
    endtask

    logic [31:0] rd;
    int          st, fc, wb_before;

    initial begin
        for (int i = 0; i < 1024; i++) u_mem.mem[i] = 32'hF1D0_0000 | i;
        c_addr='0; c_ren=0; c_wen=0; c_wstrb='0; c_wdata='0; flush_req = 0;
        rst = 1;
        repeat (3) @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // FL1: dirty three lines across sets/ways.
        $display("\n--- FL1: dirty then flush ---");
        store(32'h0000_0000, 32'hAA00_0001);   // set 0
        store(32'h0000_0018, 32'hAA00_0002);   // set 3, word 1
        store(32'h0000_0020, 32'hAA00_0003);   // set 0, other tag (way 2)
        check("FL1.mem_untouched_yet",
              u_mem.mem[0] === (32'hF1D0_0000 | 0)
              && u_mem.mem[6] === (32'hF1D0_0000 | 6)
              && u_mem.mem[8] === (32'hF1D0_0000 | 8));
        do_flush(fc);
        $display("[FLUSH] walk took %0d cycles", fc);

        // FL2: memory now holds the dirty data.
        check("FL2.word0", u_mem.mem[0] === 32'hAA00_0001);
        check("FL2.word6", u_mem.mem[6] === 32'hAA00_0002);
        check("FL2.word8", u_mem.mem[8] === 32'hAA00_0003);

        // FL3: everything invalidated; re-reads miss and round-trip.
        load(32'h0000_0000, rd, st);
        check("FL3.miss_after_flush", st > 0);
        check("FL3.data_roundtrip", rd === 32'hAA00_0001);
        load(32'h0000_0018, rd, st);
        check("FL3.word1_roundtrip", rd === 32'hAA00_0002);

        // FL4: flushing a clean cache writes nothing.
        $display("\n--- FL4: clean flush is silent ---");
        wb_before = wbeats;
        do_flush(fc);
        check("FL4.no_writebacks", wbeats == wb_before);
        load(32'h0000_0000, rd, st);
        check("FL4.invalidated_again", st > 0 && rd === 32'hAA00_0001);

        repeat (2) @(posedge clk);
        $display("\n===== tb_dcache_flush: %0d passed, %0d failed =====",
                 pass_count, fail_count);
        if (fail_count != 0) $fatal(1, "tb_dcache_flush: FAILURES detected");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "tb_dcache_flush: timeout");
    end

endmodule : tb_dcache_flush

`default_nettype wire
