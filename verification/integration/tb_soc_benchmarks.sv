// verification/integration/tb_soc_benchmarks.sv
//
// SOC-level benchmark simulation testbenches.
//
// Instantiates fluxcore_soc with a real BRAM hex image, runs the program to
// completion, and verifies the result block that fluxcore_report() writes to
// DMEM at RESULT_BASE = 0x1FE0.
//
// Two top-level modules (one per benchmark):
//   tb_hello_cpi  — 1000-iteration ADD loop;  expected checksum = 499500
//   tb_spmv_csr   — 8×8 CSR SpMV;            expected checksum = 416
//
// Termination protocol (from software/runtime/fluxcore.h):
//   fluxcore_report() writes 8 words to RESULT_BASE then writes the sentinel
//   RESULT_DONE = 0x600D_D00E to RESULT_BASE+28 (0x1FFC) last.  The
//   testbench watches every DMEM SW and fires when it sees that sentinel.
//
// Note: 0x1FFC coincides with main()'s saved-ra slot on the stack.
//   fluxcore_report() overwrites ra with RESULT_DONE; after returning, main()
//   would jump to 0x600DD00E (out of IMEM range).  This is harmless in
//   simulation because $finish is called before the ret executes.

`timescale 1ns / 1ps
`default_nettype none

// ============================================================================
// soc_bench_runner — shared parameterised harness
// ============================================================================
module soc_bench_runner #(
    parameter string BENCH_NAME    = "benchmark",
    parameter string IMEM_INIT     = "",         // path relative to vsim CWD
    parameter int    EXP_CHECKSUM  = -1,         // -1 = skip correctness check
    parameter int    TIMEOUT_CYCS  = 200_000,    // simulation cycle budget
    // Must match software/runtime/fluxcore.h
    parameter logic [31:0] RESULT_BASE  = 32'h0000_1FE0,
    parameter logic [31:0] RESULT_MAGIC = 32'hF10C_CAFE,
    parameter logic [31:0] RESULT_DONE  = 32'h600D_D00E
);

    // -----------------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------------
    logic clk = 0;
    logic rst = 1;
    always #5 clk = ~clk;   // 100 MHz

    // -----------------------------------------------------------------------
    // DUT — full SoC, direct BRAM path
    // -----------------------------------------------------------------------
    fluxcore_soc #(
        .IMEM_INIT (IMEM_INIT),
        .USE_DCACHE(0)
    ) u_soc (
        .clk(clk),
        .rst(rst)
    );

    // -----------------------------------------------------------------------
    // Cycle counter for timeout
    // -----------------------------------------------------------------------
    int unsigned cyc = 0;
    always_ff @(posedge clk) cyc <= cyc + 1;

    // -----------------------------------------------------------------------
    // Result shadow — intercept writes to the 8-word result block at RESULT_BASE
    // -----------------------------------------------------------------------
    localparam logic [31:0] RESULT_DONE_ADDR = RESULT_BASE + 32'd28;  // 0x1FFC

    // Hierarchical references into the SoC for DMEM bus monitoring.
    // These are module-level wires inside fluxcore_soc and are visible to the
    // testbench via the normal SV hierarchical name u_soc.<signal>.
    wire [31:0] mon_addr  = u_soc.dmem_addr;
    wire        mon_wen   = u_soc.dmem_wen;
    wire [3:0]  mon_wstrb = u_soc.dmem_wstrb;
    wire [31:0] mon_wdata = u_soc.dmem_wdata;

    logic [31:0] result_shadow [0:7];
    logic        done = 0;

    always_ff @(posedge clk) begin
        if (mon_wen && mon_wstrb == 4'hF
                    && mon_addr >= RESULT_BASE
                    && mon_addr <= RESULT_DONE_ADDR) begin
            result_shadow[(mon_addr - RESULT_BASE) >> 2] <= mon_wdata;
            if (mon_addr == RESULT_DONE_ADDR && mon_wdata == RESULT_DONE)
                done <= 1'b1;
        end
    end

    // -----------------------------------------------------------------------
    // Stimulus + verification
    // -----------------------------------------------------------------------
    initial begin : stim

        // Release reset after 5 rising edges
        repeat (5) @(posedge clk);
        @(negedge clk); rst = 0;

        // Wait for RESULT_DONE sentinel or timeout
        wait (done || cyc >= TIMEOUT_CYCS);
        @(posedge clk); #1;   // settle non-blocking assignments

        if (!done)
            $fatal(1, "[%s] TIMEOUT: %0d cycles elapsed, RESULT_DONE never seen at 0x%08h",
                   BENCH_NAME, cyc, RESULT_DONE_ADDR);

        // Verify magic
        if (result_shadow[0] !== RESULT_MAGIC)
            $fatal(1, "[%s] FAIL result_magic=0x%08h expected=0x%08h",
                   BENCH_NAME, result_shadow[0], RESULT_MAGIC);

        begin
            automatic int unsigned cycles_v   = result_shadow[1];
            automatic int unsigned instrets_v = result_shadow[2];
            automatic int unsigned checksum_v = result_shadow[3];
            automatic real         cpi;

            cpi = (instrets_v > 0) ? real'(cycles_v) / real'(instrets_v) : 0.0;

            $display("[%s] --------------------------------------------------", BENCH_NAME);
            $display("[%s]  cycles    = %0d",        BENCH_NAME, cycles_v);
            $display("[%s]  instrets  = %0d",        BENCH_NAME, instrets_v);
            $display("[%s]  CPI       = %.3f",       BENCH_NAME, cpi);
            $display("[%s]  checksum  = %0d (0x%08h)", BENCH_NAME, checksum_v, checksum_v);
            $display("[%s]  extra0    = %0d",        BENCH_NAME, result_shadow[4]);
            $display("[%s]  extra1    = %0d",        BENCH_NAME, result_shadow[5]);
            $display("[%s]  extra2    = %0d",        BENCH_NAME, result_shadow[6]);
            $display("[%s] --------------------------------------------------", BENCH_NAME);

            if (EXP_CHECKSUM >= 0 && int'(checksum_v) !== EXP_CHECKSUM)
                $fatal(1, "[%s] FAIL checksum=%0d expected=%0d",
                       BENCH_NAME, checksum_v, EXP_CHECKSUM);
        end

        $display("[%s] PASS", BENCH_NAME);
        $finish;

    end : stim

endmodule : soc_bench_runner

// ============================================================================
// Top-level wrappers — one per benchmark, selected by vsim top module name
// ============================================================================

module tb_hello_cpi;
    soc_bench_runner #(
        .BENCH_NAME   ("hello_cpi"),
        .IMEM_INIT    ("build/sw/hello_cpi/imem.hex"),
        .EXP_CHECKSUM (499500),
        .TIMEOUT_CYCS (50_000)
    ) runner ();
endmodule : tb_hello_cpi

module tb_spmv_csr;
    soc_bench_runner #(
        .BENCH_NAME   ("spmv_csr"),
        .IMEM_INIT    ("build/sw/spmv_csr/imem.hex"),
        .EXP_CHECKSUM (416),
        .TIMEOUT_CYCS (50_000)
    ) runner ();
endmodule : tb_spmv_csr

`default_nettype wire
