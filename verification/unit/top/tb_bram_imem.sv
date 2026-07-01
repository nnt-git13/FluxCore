// verification/unit/top/tb_bram_imem.sv
//
// Self-checking unit test for rtl/top/bram_imem.sv.
//
// bram_imem has a 1-cycle registered read: data for address A appears ONE
// clock cycle after addr_next_i = A was presented (= the cycle when it would
// be the "current PC" in a running pipeline).
//
// This test verifies:
//   1. 1-cycle latency: rdata_o = mem[A] one cycle after addr_next_i = A.
//   2. Sequential reads: consecutive addresses return the right words.
//   3. Re-read: same address twice returns the same data.
//   4. Address wrap: words at DEPTH-1 and 0 are accessible.
//
// Memory is initialised via backdoor (hierarchical reference dut.mem[i])
// so no INIT_FILE is required. DEPTH is set to 64 words (256 B) to keep
// the test fast; the logic scales to any power-of-2 depth.

`timescale 1ns / 1ps
`default_nettype none

module tb_bram_imem;

    localparam int DEPTH = 64;  // small depth for fast simulation

    logic        clk = 0;
    logic [31:0] addr_next;
    logic [31:0] rdata;

    always #5 clk = ~clk;

    bram_imem #(.DEPTH(DEPTH), .INIT_FILE("")) dut (
        .clk        (clk),
        .addr_next_i(addr_next),
        .rdata_o    (rdata)
    );

    // -----------------------------------------------------------------------
    // Backdoor memory initialisation
    // -----------------------------------------------------------------------
    initial begin
        for (int i = 0; i < DEPTH; i++)
            dut.mem[i] = 32'hA000_0000 | i;  // unique pattern per word
    end

    // -----------------------------------------------------------------------
    // Helper: present addr_next_i for one cycle, then check rdata_o
    // -----------------------------------------------------------------------
    task automatic check_read(
        input int    word_idx,
        input string desc
    );
        automatic logic [31:0] exp = 32'hA000_0000 | word_idx;
        // Present the address as addr_next_i
        addr_next = word_idx << 2;  // byte address (word-aligned)
        @(posedge clk); #1;         // BRAM registers addr_next_i
        // Now addr_next_i has advanced; rdata_o = mem[word_idx]
        if (rdata !== exp)
            $fatal(1, "[BRAM-IMEM] FAIL %s rdata=0x%08h expected=0x%08h",
                   desc, rdata, exp);
    endtask

    // -----------------------------------------------------------------------
    // Main test
    // -----------------------------------------------------------------------
    initial begin : test_body
        addr_next = '0;
        // One warm-up cycle: present addr=0 so the BRAM can register it
        @(posedge clk); #1;
        // rdata_o is now mem[0]; verify sequential reads

        // ================================================================
        // 1. Single read: word 0
        // ================================================================
        if (rdata !== (32'hA000_0000 | 0))
            $fatal(1, "[BRAM-IMEM] FAIL word0 after warmup rdata=0x%08h expected=0x%08h",
                   rdata, 32'hA000_0000);

        // ================================================================
        // 2. Sequential reads: words 1..7
        // ================================================================
        for (int i = 1; i <= 7; i++)
            check_read(i, $sformatf("sequential word %0d", i));

        // ================================================================
        // 3. Re-read same address: word 3 twice
        // ================================================================
        check_read(3, "re-read word 3 (first)");
        check_read(3, "re-read word 3 (second)");

        // ================================================================
        // 4. Jump to last word, wrap to first
        // ================================================================
        check_read(DEPTH - 1, "last word");
        check_read(0,         "wrap to word 0");

        // ================================================================
        // 5. Middle-of-range spot check
        // ================================================================
        check_read(32, "mid-range word 32");

        $display("[BRAM-IMEM] PASS: 1-cycle latency, sequential, re-read, wrap.");
        $finish;
    end : test_body

    initial begin
        #10_000;
        $fatal(1, "[BRAM-IMEM] TIMEOUT");
    end

endmodule : tb_bram_imem

`default_nettype wire
