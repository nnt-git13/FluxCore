// verification/unit/top/tb_bram_dmem.sv
//
// Self-checking unit test for rtl/top/bram_dmem.sv.
//
// bram_dmem has 1-cycle registered read latency. Writes commit at posedge
// (end of the write cycle); read data appears one cycle after addr_i.
//
// Verifies:
//   1. Full-word write + read: store 32-bit value, read it back after 1 cycle.
//   2. Byte-enable writes: write selected bytes, verify only those lanes changed.
//   3. No-write read: rdata reflects last committed write.
//   4. Read-after-write same address: read immediately after write returns
//      the NEW value (write committed at posedge, read sees it next cycle).
//   5. Independent addresses: writes to different words don't alias.

`timescale 1ns / 1ps
`default_nettype none

module tb_bram_dmem;

    localparam int DEPTH = 64;

    logic        clk = 0;
    logic [31:0] addr;
    logic        wen;
    logic [3:0]  wstrb;
    logic [31:0] wdata;
    logic [31:0] rdata;

    always #5 clk = ~clk;

    bram_dmem #(.DEPTH(DEPTH), .INIT_FILE("")) dut (
        .clk    (clk),
        .addr_i (addr),
        .wen_i  (wen),
        .wstrb_i(wstrb),
        .wdata_i(wdata),
        .rdata_o(rdata)
    );

    // -----------------------------------------------------------------------
    // Helper: write then read back, check after 1 cycle
    // -----------------------------------------------------------------------
    task automatic write_word(
        input int    widx,
        input [31:0] data
    );
        addr  = widx << 2;
        wen   = 1; wstrb = 4'hF; wdata = data;
        @(posedge clk); #1;
        wen = 0;
    endtask

    task automatic check_read(
        input int    widx,
        input [31:0] exp,
        input string desc
    );
        addr = widx << 2;
        @(posedge clk); #1;
        if (rdata !== exp)
            $fatal(1, "[BRAM-DMEM] FAIL %-40s rdata=0x%08h expected=0x%08h",
                   desc, rdata, exp);
    endtask

    // -----------------------------------------------------------------------
    // Main test
    // -----------------------------------------------------------------------
    initial begin : test_body
        addr = '0; wen = 0; wstrb = '0; wdata = '0;
        @(posedge clk); #1;  // settle

        // ================================================================
        // 1. Full-word write + read-back
        // ================================================================
        write_word(0, 32'hDEAD_BEEF);
        check_read(0, 32'hDEAD_BEEF, "full-word write/read @ word 0");

        write_word(5, 32'h1234_5678);
        check_read(5, 32'h1234_5678, "full-word write/read @ word 5");

        // ================================================================
        // 2. Byte-enable writes: write initial value, then partial-write
        // ================================================================
        write_word(10, 32'hFFFF_FFFF);
        check_read(10, 32'hFFFF_FFFF, "byte-enable setup: all-ones @ word 10");

        // Write byte 0 only (bits [7:0] ← 0x42)
        addr = 10 << 2; wen = 1; wstrb = 4'b0001; wdata = 32'h0000_0042;
        @(posedge clk); #1; wen = 0;
        check_read(10, 32'hFFFF_FF42, "byte-enable: byte0 written, [31:8] intact");

        // Write bytes 2 and 3 (bits [31:16] ← 0x0000)
        addr = 10 << 2; wen = 1; wstrb = 4'b1100; wdata = 32'h0000_0000;
        @(posedge clk); #1; wen = 0;
        check_read(10, 32'h0000_FF42, "byte-enable: bytes2+3 zeroed, bytes0+1 intact");

        // ================================================================
        // 3. No-write read: rdata holds last value (address change, no write)
        // ================================================================
        write_word(20, 32'hCAFE_BABE);
        check_read(20, 32'hCAFE_BABE, "no-write read @ word 20 (first)");
        // Read again without a write: same value
        check_read(20, 32'hCAFE_BABE, "no-write read @ word 20 (second)");

        // ================================================================
        // 4. Read-after-write same address
        // ================================================================
        write_word(30, 32'hAAAA_5555);
        check_read(30, 32'hAAAA_5555, "read-after-write @ word 30");

        // ================================================================
        // 5. Independence: write to word 1, word 2 unaffected
        // ================================================================
        write_word(1, 32'h1111_1111);
        write_word(2, 32'h2222_2222);
        check_read(1, 32'h1111_1111, "independence: word 1");
        check_read(2, 32'h2222_2222, "independence: word 2");
        // Word 1 still holds its value after reading word 2
        check_read(1, 32'h1111_1111, "independence: word 1 after reading word 2");

        $display("[BRAM-DMEM] PASS: word write/read, byte enables, no-write, RAW, independence.");
        $finish;
    end : test_body

    initial begin
        #10_000;
        $fatal(1, "[BRAM-DMEM] TIMEOUT");
    end

endmodule : tb_bram_dmem

`default_nettype wire
