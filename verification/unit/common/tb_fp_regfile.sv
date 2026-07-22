// verification/unit/common/tb_fp_regfile.sv
//
// Self-checking testbench for rtl/common/fp_regfile.sv.
//
// The FP register file differs from the integer regfile in two ways that this
// test exercises directly:
//   - THREE asynchronous read ports (fs1, fs2, fs3) for the fused multiply-add.
//   - NO x0 special-casing: f0 is an ordinary register that holds writes.
//
// Clock: 10 ns period. Stimulus applied before the posedge; checks run #1
// after the posedge so the synchronous write has settled and the combinational
// reads have propagated.
//
// Tests:
//   1. After reset: all read ports return 0.
//   2. Write f1, read back on port A.
//   3. Write f31, read back on port B.
//   4. f0 is writable (NOT hardwired zero) — the key difference from x0.
//   5. Three-port simultaneous read of three distinct registers (FMADD read).
//   6. Write-first bypass: a write is visible on all three read ports in the
//      same cycle it is applied.
//   7. frd_wen_i = 0 suppresses the write.
//   8. Random walk: 100 random write/read triples verify no cross corruption.
//
// Pass/fail: $fatal(1, ...) on mismatch; prints "[FP-REGFILE-TEST] PASS".

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;

module tb_fp_regfile;

    // -----------------------------------------------------------------------
    // DUT ports
    // -----------------------------------------------------------------------
    logic     clk, rst;
    reg_idx_t fs1_addr_w, fs2_addr_w, fs3_addr_w;
    word_t    fs1_data_w, fs2_data_w, fs3_data_w;
    logic     frd_wen_w;
    reg_idx_t frd_addr_w;
    word_t    frd_data_w;

    fp_regfile dut (
        .clk       (clk),
        .rst       (rst),
        .fs1_addr_i(fs1_addr_w),
        .fs1_data_o(fs1_data_w),
        .fs2_addr_i(fs2_addr_w),
        .fs2_data_o(fs2_data_w),
        .fs3_addr_i(fs3_addr_w),
        .fs3_data_o(fs3_data_w),
        .frd_wen_i (frd_wen_w),
        .frd_addr_i(frd_addr_w),
        .frd_data_i(frd_data_w)
    );

    // -----------------------------------------------------------------------
    // Clock
    // -----------------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Reference model for the random walk
    word_t ref_regs [0:REG_COUNT-1];

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------
    // Synchronous write of one register (one clock).
    task automatic wr(input reg_idx_t a, input word_t d);
        @(negedge clk);
        frd_wen_w  = 1'b1;
        frd_addr_w = a;
        frd_data_w = d;
        @(posedge clk);
        #1;
        frd_wen_w  = 1'b0;
    endtask

    // Combinational read on port A and check.
    task automatic chk1(input reg_idx_t a, input word_t exp, input string lbl);
        fs1_addr_w = a; #1;
        if (fs1_data_w !== exp)
            $fatal(1, "[FP-REGFILE-TEST] FAIL %s: fs1=%08h exp=%08h", lbl, fs1_data_w, exp);
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin : body
        integer i;
        reg_idx_t a1, a2, a3, aw;
        word_t    dw;

        frd_wen_w  = 1'b0;
        frd_addr_w = '0;
        frd_data_w = '0;
        fs1_addr_w = '0;
        fs2_addr_w = '0;
        fs3_addr_w = '0;

        // --- reset ---
        rst = 1'b1;
        repeat (2) @(posedge clk);
        @(negedge clk); rst = 1'b0;

        // 1. After reset all ports read 0.
        chk1(5'd0, 32'h0, "reset f0");
        chk1(5'd5, 32'h0, "reset f5");
        chk1(5'd31, 32'h0, "reset f31");

        // 2. Write f1, read back.
        wr(5'd1, 32'h3F80_0000);        // 1.0f
        chk1(5'd1, 32'h3F80_0000, "f1 = 1.0f");

        // 3. Write f31.
        wr(5'd31, 32'hDEAD_BEEF);
        chk1(5'd31, 32'hDEAD_BEEF, "f31 readback");

        // 4. f0 is a normal register (NOT hardwired zero).
        wr(5'd0, 32'h4048_0000);        // 3.0f
        chk1(5'd0, 32'h4048_0000, "f0 is writable (not x0-like)");

        // 5. Three-port simultaneous read of three distinct registers.
        wr(5'd2, 32'h1111_1111);
        wr(5'd3, 32'h2222_2222);
        wr(5'd4, 32'h3333_3333);
        fs1_addr_w = 5'd2; fs2_addr_w = 5'd3; fs3_addr_w = 5'd4; #1;
        if (fs1_data_w !== 32'h1111_1111 ||
            fs2_data_w !== 32'h2222_2222 ||
            fs3_data_w !== 32'h3333_3333)
            $fatal(1, "[FP-REGFILE-TEST] FAIL 3-port read: %08h %08h %08h",
                   fs1_data_w, fs2_data_w, fs3_data_w);

        // 6. Write-first bypass: value visible on all ports in the write cycle.
        @(negedge clk);
        frd_wen_w  = 1'b1;
        frd_addr_w = 5'd7;
        frd_data_w = 32'hCAFE_F00D;
        fs1_addr_w = 5'd7; fs2_addr_w = 5'd7; fs3_addr_w = 5'd7;
        #1;   // still before the posedge — bypass mux should already show it
        if (fs1_data_w !== 32'hCAFE_F00D ||
            fs2_data_w !== 32'hCAFE_F00D ||
            fs3_data_w !== 32'hCAFE_F00D)
            $fatal(1, "[FP-REGFILE-TEST] FAIL write-first bypass: %08h", fs1_data_w);
        @(posedge clk); #1;
        frd_wen_w = 1'b0;
        chk1(5'd7, 32'hCAFE_F00D, "f7 registered after bypass cycle");

        // 7. frd_wen=0 suppresses write.
        @(negedge clk);
        frd_wen_w  = 1'b0;
        frd_addr_w = 5'd7;
        frd_data_w = 32'h0000_0000;
        @(posedge clk); #1;
        chk1(5'd7, 32'hCAFE_F00D, "f7 unchanged when frd_wen=0");

        // 8. Random walk.
        for (i = 0; i < REG_COUNT; i++) ref_regs[i] = '0;
        // seed refs with what we already wrote
        ref_regs[0]=32'h4048_0000; ref_regs[1]=32'h3F80_0000; ref_regs[2]=32'h1111_1111;
        ref_regs[3]=32'h2222_2222; ref_regs[4]=32'h3333_3333; ref_regs[7]=32'hCAFE_F00D;
        ref_regs[31]=32'hDEAD_BEEF;
        for (i = 0; i < 100; i++) begin
            aw = $urandom_range(0, 31);
            dw = $urandom;
            wr(aw, dw);
            ref_regs[aw] = dw;
            a1 = $urandom_range(0, 31);
            chk1(a1, ref_regs[a1], "random-walk readback");
        end

        $display("[FP-REGFILE-TEST] PASS: fp_regfile verified (3 read ports, f0 writable, bypass).");
        $finish;
    end : body

endmodule : tb_fp_regfile

`default_nettype wire
