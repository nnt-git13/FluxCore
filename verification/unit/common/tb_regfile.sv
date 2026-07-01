// verification/unit/common/tb_regfile.sv
//
// Self-checking testbench for rtl/common/regfile.sv.
//
// Clock: 10 ns period (posedge at 5 ns, 15 ns, …).
// All stimulus is applied before the relevant posedge; all checks run #1
// after the posedge so the synchronous write has settled and the
// combinational read outputs have propagated.
//
// Tests:
//   1. After reset: all read addresses return 0.
//   2. Write to x1 and read it back.
//   3. Write to x31 and read it back.
//   4. Write to x0: read must still return 0 (suppressed silently).
//   5. Overwrite: write a new value to an already-written register.
//   6. Two independent read ports: simultaneously read two different regs.
//   7. rd_wen_i = 0: write must NOT take effect.
//   8. Read-after-write: asynchronous read reflects the new value in the
//      same simulation delta after the clock edge.
//   9. Full reset after writes: all registers return to 0.
//  10. Random walk: 100 random write/read pairs verify no cross-register
//      corruption.
//
// Pass/fail:
//   $fatal(1, ...) on any mismatch.
//   Prints "[REGFILE-TEST] PASS" and $finish on success.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;

module tb_regfile;

    // -----------------------------------------------------------------------
    // DUT ports
    // -----------------------------------------------------------------------
    logic      clk, rst;
    reg_idx_t  rs1_addr_w, rs2_addr_w;
    word_t     rs1_data_w, rs2_data_w;
    logic      rd_wen_w;
    reg_idx_t  rd_addr_w;
    word_t     rd_data_w;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    regfile dut (
        .clk       (clk),
        .rst       (rst),
        .rs1_addr_i(rs1_addr_w),
        .rs1_data_o(rs1_data_w),
        .rs2_addr_i(rs2_addr_w),
        .rs2_data_o(rs2_data_w),
        .rd_wen_i  (rd_wen_w),
        .rd_addr_i (rd_addr_w),
        .rd_data_i (rd_data_w)
    );

    // -----------------------------------------------------------------------
    // Clock — 10 ns period
    // -----------------------------------------------------------------------
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // -----------------------------------------------------------------------
    // Simulation timeout
    // -----------------------------------------------------------------------
    initial begin : timeout_guard
        #50_000;
        $fatal(1, "[REGFILE-TEST] TIMEOUT: simulation did not complete");
    end

    // -----------------------------------------------------------------------
    // Shadow model: mirror of the register file for expected-value tracking
    // -----------------------------------------------------------------------
    word_t shadow [0:REG_COUNT-1];

    // -----------------------------------------------------------------------
    // Helper: apply a synchronous write and update shadow
    // -----------------------------------------------------------------------
    task automatic do_write(input reg_idx_t addr, input word_t data);
        rd_wen_w  = 1'b1;
        rd_addr_w = addr;
        rd_data_w = data;
        @(posedge clk); #1;
        rd_wen_w = 1'b0;
        // Reflect the write in the shadow (x0 suppressed)
        if (addr != '0) shadow[addr] = data;
    endtask

    // -----------------------------------------------------------------------
    // Helper: check both read ports against expected values
    // -----------------------------------------------------------------------
    task automatic check_read(
        input reg_idx_t addr,
        input word_t    expected,
        input string    desc
    );
        rs1_addr_w = addr;
        rs2_addr_w = addr;
        #1;
        if (rs1_data_w !== expected)
            $fatal(1, "[REGFILE-TEST] FAIL %s (rs1): addr=x%0d got=%08h exp=%08h",
                   desc, addr, rs1_data_w, expected);
        if (rs2_data_w !== expected)
            $fatal(1, "[REGFILE-TEST] FAIL %s (rs2): addr=x%0d got=%08h exp=%08h",
                   desc, addr, rs2_data_w, expected);
    endtask

    // -----------------------------------------------------------------------
    // Helper: check the entire register file against shadow
    // -----------------------------------------------------------------------
    task automatic check_all(input string desc);
        for (int unsigned r = 0; r < REG_COUNT; r++) begin
            rs1_addr_w = reg_idx_t'(r);
            #1;
            if (rs1_data_w !== shadow[r])
                $fatal(1, "[REGFILE-TEST] FAIL check_all %s: x%0d got=%08h exp=%08h",
                       desc, r, rs1_data_w, shadow[r]);
        end
    endtask

    // -----------------------------------------------------------------------
    // Helper: reset the DUT and shadow
    // -----------------------------------------------------------------------
    task automatic do_reset();
        rst = 1'b1;
        repeat (2) @(posedge clk);
        #1;
        rst = 1'b0;
        for (int unsigned i = 0; i < REG_COUNT; i++)
            shadow[i] = '0;
    endtask

    // -----------------------------------------------------------------------
    // Main test
    // -----------------------------------------------------------------------
    initial begin : test_body

        // --- Initial state ---
        clk       = 1'b0;
        rst       = 1'b0;
        rs1_addr_w = '0;
        rs2_addr_w = '0;
        rd_wen_w   = 1'b0;
        rd_addr_w  = '0;
        rd_data_w  = '0;
        for (int unsigned i = 0; i < REG_COUNT; i++)
            shadow[i] = '0;

        // ================================================================
        // 1. Reset — all registers must return 0
        // ================================================================
        do_reset();
        check_all("after-reset");
        $display("[REGFILE-TEST] 1. Reset: PASS");

        // ================================================================
        // 2. Write to x1 and read back
        // ================================================================
        do_write(5'd1, 32'hDEAD_BEEF);
        check_read(5'd1, 32'hDEAD_BEEF, "x1 write");
        $display("[REGFILE-TEST] 2. Write x1: PASS");

        // ================================================================
        // 3. Write to x31 (highest index) and read back
        // ================================================================
        do_write(5'd31, 32'h1234_5678);
        check_read(5'd31, 32'h1234_5678, "x31 write");
        $display("[REGFILE-TEST] 3. Write x31: PASS");

        // ================================================================
        // 4. Write to x0 — must be suppressed; read must still return 0
        // ================================================================
        do_write(5'd0, 32'hFFFF_FFFF);
        check_read(5'd0, 32'h0, "x0 write suppressed");
        $display("[REGFILE-TEST] 4. x0 write suppressed: PASS");

        // ================================================================
        // 5. Overwrite: write a new value to x1 (already written)
        // ================================================================
        do_write(5'd1, 32'hC0DE_C0DE);
        check_read(5'd1, 32'hC0DE_C0DE, "x1 overwrite");
        $display("[REGFILE-TEST] 5. Overwrite x1: PASS");

        // ================================================================
        // 6. Two read ports simultaneously — x1 and x31
        // ================================================================
        begin : t_two_ports
            rs1_addr_w = 5'd1;
            rs2_addr_w = 5'd31;
            #1;
            if (rs1_data_w !== shadow[1])
                $fatal(1, "[REGFILE-TEST] FAIL dual-read rs1: got=%08h exp=%08h",
                       rs1_data_w, shadow[1]);
            if (rs2_data_w !== shadow[31])
                $fatal(1, "[REGFILE-TEST] FAIL dual-read rs2: got=%08h exp=%08h",
                       rs2_data_w, shadow[31]);
        end
        $display("[REGFILE-TEST] 6. Dual read ports: PASS");

        // ================================================================
        // 7. rd_wen_i = 0: no write should occur
        // ================================================================
        begin : t_no_write
            automatic word_t prev_val;
            // Read current x2 value (should still be 0 from reset)
            rs1_addr_w = 5'd2; #1;
            prev_val = rs1_data_w;
            // Attempt write with wen=0
            rd_wen_w  = 1'b0;
            rd_addr_w = 5'd2;
            rd_data_w = 32'hBAAD_F00D;
            @(posedge clk); #1;
            rs1_addr_w = 5'd2; #1;
            if (rs1_data_w !== prev_val)
                $fatal(1, "[REGFILE-TEST] FAIL no-write: x2 changed to %08h (wen=0)",
                       rs1_data_w);
        end
        $display("[REGFILE-TEST] 7. wen=0 suppresses write: PASS");

        // ================================================================
        // 8. Read-after-write in the same delta after posedge
        //    (asynchronous reads must reflect the new value immediately)
        // ================================================================
        begin : t_raw
            automatic word_t new_val = 32'hA5A5_A5A5;
            rd_wen_w  = 1'b1;
            rd_addr_w = 5'd5;
            rd_data_w = new_val;
            rs1_addr_w = 5'd5;
            @(posedge clk); #1;  // write latches; read port already looking at x5
            rd_wen_w = 1'b0;
            if (rs1_data_w !== new_val)
                $fatal(1, "[REGFILE-TEST] FAIL read-after-write: x5=%08h exp=%08h",
                       rs1_data_w, new_val);
            shadow[5] = new_val;
        end
        $display("[REGFILE-TEST] 8. Read-after-write (async read): PASS");

        // ================================================================
        // 9. Full reset clears all previously written registers
        // ================================================================
        // First, write to several registers
        do_write(5'd10, 32'h1111_1111);
        do_write(5'd20, 32'h2222_2222);
        do_write(5'd30, 32'h3333_3333);
        // Reset
        do_reset();
        check_all("post-second-reset");
        $display("[REGFILE-TEST] 9. Second reset clears all: PASS");

        // ================================================================
        // 10. Random walk — 100 write/read pairs; no cross-register corruption
        // ================================================================
        begin : t_random
            automatic int unsigned addr;
            automatic word_t       data;

            do_reset();

            for (int k = 0; k < 100; k++) begin
                addr = $urandom_range(1, REG_COUNT-1);  // 1..31 (not x0)
                data = word_t'($urandom());
                do_write(reg_idx_t'(addr), data);
                check_read(reg_idx_t'(addr), data, $sformatf("random wr x%0d", addr));
                // Verify no other register was disturbed by checking the full shadow
                check_all($sformatf("random shadow k=%0d", k));
            end
        end
        $display("[REGFILE-TEST] 10. Random walk (100 iters): PASS");

        // ================================================================
        // Done
        // ================================================================
        $display("[REGFILE-TEST] PASS: all register file tests passed.");
        $display("[REGFILE-TEST]   Clocked module, async read, sync write, x0 hardwired.");
        $finish;

    end : test_body

endmodule : tb_regfile

`default_nettype wire
