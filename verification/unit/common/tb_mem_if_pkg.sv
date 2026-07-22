// verification/unit/common/tb_mem_if_pkg.sv
//
// Self-checking testbench for mem_if_pkg.sv — the frozen memory interface.
//
// Verifies:
//   1. Width localparams (MEM_STRB_W, MEM_ID_W, MEM_LEN_W, MEM_MAX_BEATS).
//   2. mem_req_t / mem_rsp_t packed widths (77 / 39 bits) — the freeze check:
//      if either width changes, the contract changed and this test must be
//      updated DELIBERATELY, never incidentally.
//   3. Enum encodings: mem_op_e; mem_err_e maps 1:1 onto AXI RRESP/BRESP.
//   4. Helper functions: mem_beats / mem_len_for round-trip, mem_beat_addr
//      stride, mem_read_req / mem_write_req field population.
//   5. Struct field packing order (id in MSBs, wdata/last in LSBs) via a
//      known-bits round-trip.
//
// Pass/fail:
//   Uses $fatal(1, ...) on any mismatch.
//   Prints "[MEM-IF-TEST] PASS" and calls $finish on success.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import mem_if_pkg::*;

module tb_mem_if_pkg;

    // -----------------------------------------------------------------------
    // Helper tasks
    // -----------------------------------------------------------------------
    task automatic check_eq(input string name, input int actual, input int expected);
        if (actual !== expected)
            $fatal(1, "[MEM-IF-TEST] %s: got %0d, expected %0d", name, actual, expected);
    endtask

    task automatic check_eq32(input string name, input logic [31:0] actual,
                              input logic [31:0] expected);
        if (actual !== expected)
            $fatal(1, "[MEM-IF-TEST] %s: got 0x%08h, expected 0x%08h", name, actual, expected);
    endtask

    // -----------------------------------------------------------------------
    // Test body
    // -----------------------------------------------------------------------
    initial begin
        mem_req_t req;
        mem_rsp_t rsp;

        // 1. Width localparams
        check_eq("MEM_STRB_W",    MEM_STRB_W,    4);
        check_eq("MEM_ID_W",      MEM_ID_W,      4);
        check_eq("MEM_ID_W == TXID_W", MEM_ID_W, TXID_W);
        check_eq("MEM_LEN_W",     MEM_LEN_W,     4);
        check_eq("MEM_MAX_BEATS", MEM_MAX_BEATS, 16);

        // 2. Frozen struct widths — the contract check.
        check_eq("$bits(mem_req_t)", $bits(mem_req_t), 77);
        check_eq("$bits(mem_rsp_t)", $bits(mem_rsp_t), 39);

        // 3. Enum encodings
        check_eq("MEM_READ",   int'(MEM_READ),   0);
        check_eq("MEM_WRITE",  int'(MEM_WRITE),  1);
        // mem_err_e must equal AXI RRESP/BRESP encodings (P3.2 relies on this).
        check_eq("MEM_OK",     int'(MEM_OK),     2'b00);
        check_eq("MEM_SLVERR", int'(MEM_SLVERR), 2'b10);
        check_eq("MEM_DECERR", int'(MEM_DECERR), 2'b11);

        // 4a. mem_beats / mem_len_for round-trip over the full range
        for (int unsigned b = 1; b <= 16; b++) begin
            check_eq("mem_beats(mem_len_for(b))", mem_beats(mem_len_for(b)), int'(b));
        end
        check_eq("mem_len_for(1) is zero", int'(mem_len_for(1)), 0);
        check_eq("mem_len_for(16)",        int'(mem_len_for(16)), 15);

        // 4b. mem_beat_addr strides by one word per beat
        check_eq32("beat_addr idx0", mem_beat_addr(32'h0000_1000, 0), 32'h0000_1000);
        check_eq32("beat_addr idx1", mem_beat_addr(32'h0000_1000, 1), 32'h0000_1004);
        check_eq32("beat_addr idx15", mem_beat_addr(32'h0000_1000, 15), 32'h0000_103C);

        // 4c. mem_read_req populates fields and zeroes write-side fields
        req = mem_read_req(4'hA, 32'h8000_0040);
        check_eq  ("read_req.id",    int'(req.id),   'hA);
        check_eq32("read_req.addr",  req.addr,       32'h8000_0040);
        check_eq  ("read_req.op",    int'(req.op),   int'(MEM_READ));
        check_eq  ("read_req.len",   int'(req.len),  0);
        check_eq  ("read_req.strb",  int'(req.strb), 0);
        check_eq32("read_req.wdata", req.wdata,      32'h0);

        // 4d. mem_write_req populates all fields
        req = mem_write_req(4'h3, 32'h0000_0200, 4'b0011, 32'hDEAD_BEEF);
        check_eq  ("write_req.id",    int'(req.id),   3);
        check_eq32("write_req.addr",  req.addr,       32'h0000_0200);
        check_eq  ("write_req.op",    int'(req.op),   int'(MEM_WRITE));
        check_eq  ("write_req.len",   int'(req.len),  0);
        check_eq  ("write_req.strb",  int'(req.strb), 'b0011);
        check_eq32("write_req.wdata", req.wdata,      32'hDEAD_BEEF);

        // 5. Packing order round-trip: declaration order packs id into the MSBs.
        //    mem_req_t: {id[76:73], addr[72:41], op[40], len[39:36],
        //                strb[35:32], wdata[31:0]}
        req = 77'h0;
        req.id    = 4'hF;
        req.wdata = 32'h0000_0001;
        if (req[76:73] !== 4'hF)
            $fatal(1, "[MEM-IF-TEST] req.id not packed in MSBs [76:73]");
        if (req[31:0] !== 32'h0000_0001)
            $fatal(1, "[MEM-IF-TEST] req.wdata not packed in LSBs [31:0]");

        //    mem_rsp_t: {id[38:35], rdata[34:3], err[2:1], last[0]}
        rsp = 39'h0;
        rsp.id   = 4'h5;
        rsp.err  = MEM_DECERR;
        rsp.last = 1'b1;
        if (rsp[38:35] !== 4'h5)
            $fatal(1, "[MEM-IF-TEST] rsp.id not packed in MSBs [38:35]");
        if (rsp[2:1] !== 2'b11)
            $fatal(1, "[MEM-IF-TEST] rsp.err not packed at [2:1]");
        if (rsp[0] !== 1'b1)
            $fatal(1, "[MEM-IF-TEST] rsp.last not packed at [0]");

        $display("[MEM-IF-TEST] PASS");
        $finish;
    end

endmodule : tb_mem_if_pkg

`default_nettype wire
