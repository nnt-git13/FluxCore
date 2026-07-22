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
    parameter int    USE_DCACHE    = 0,          // 1 = insert the write-through dcache
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
        .USE_DCACHE(USE_DCACHE)
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

module tb_csr_probe;
    soc_bench_runner #(
        .BENCH_NAME   ("csr_probe"),
        .IMEM_INIT    ("build/sw/csr_probe/imem.hex"),
        .EXP_CHECKSUM (499500),
        .TIMEOUT_CYCS (50_000)
    ) runner ();
endmodule : tb_csr_probe

// RV32F demonstration kernel (-march=rv32imf): checksum = float bits of the
// result 166.0f = 0x43260000 = 1126563840; extra0 = its integer truncation (166).
module tb_fp_kernel;
    soc_bench_runner #(
        .BENCH_NAME   ("fp_kernel"),
        .IMEM_INIT    ("build/sw/fp_kernel/imem.hex"),
        .EXP_CHECKSUM (1126563840),
        .TIMEOUT_CYCS (50_000)
    ) runner ();

    // Deep check: the integer truncation of the FP result.
    initial begin
        wait (runner.done);
        @(negedge runner.clk);
        if (runner.result_shadow[4] !== 32'd166)
            $fatal(1, "[fp_kernel] FAIL extra0 (int result)=%0d expected=166",
                   runner.result_shadow[4]);
    end
endmodule : tb_fp_kernel

// Timer-interrupt test: checksum = number of interrupts taken (3).
// extra0 must additionally show mcause = 0x80000007 (machine timer);
// the runner prints it for the transcript.
module tb_timer_irq;
    soc_bench_runner #(
        .BENCH_NAME   ("timer_irq"),
        .IMEM_INIT    ("build/sw/timer_irq/imem.hex"),
        .EXP_CHECKSUM (3),
        .TIMEOUT_CYCS (50_000)
    ) runner ();

    // Deep check: the last mcause captured by the handler
    initial begin
        wait (runner.done);
        @(negedge runner.clk);   // before the runner's posedge-timed $finish
        if (runner.result_shadow[4] !== 32'h8000_0007)
            $fatal(1, "[timer_irq] FAIL mcause=0x%08h expected 0x80000007",
                   runner.result_shadow[4]);
        if (runner.result_shadow[5] !== 32'h0000_0008)
            $fatal(1, "[timer_irq] FAIL mstatus.MIE not restored after mret");
    end
endmodule : tb_timer_irq

// Fetch-misalignment test: checksum = trap count (1);
// extra0 = mcause (0 = EXC_INSTR_ADDR_MISALIGNED), extra1 = mtval (0x102).
module tb_misalign_trap;
    soc_bench_runner #(
        .BENCH_NAME   ("misalign_trap"),
        .IMEM_INIT    ("build/sw/misalign_trap/imem.hex"),
        .EXP_CHECKSUM (1),
        .TIMEOUT_CYCS (50_000)
    ) runner ();

    initial begin
        wait (runner.done);
        @(negedge runner.clk);
        if (runner.result_shadow[4] !== 32'h0000_0000)
            $fatal(1, "[misalign_trap] FAIL mcause=0x%08h expected 0 (INSTR_ADDR_MISALIGNED)",
                   runner.result_shadow[4]);
        if (runner.result_shadow[5] !== 32'h0000_0102)
            $fatal(1, "[misalign_trap] FAIL mtval=0x%08h expected 0x102",
                   runner.result_shadow[5]);
    end
endmodule : tb_misalign_trap

// XFlux-from-C benchmark: checksum must be nonzero (scalar/xflux agreement);
// extra2 = xflux_clz(1) = 31 verified below.
module tb_xflux_kernel;
    soc_bench_runner #(
        .BENCH_NAME   ("xflux_kernel"),
        .IMEM_INIT    ("build/sw/xflux_kernel/imem.hex"),
        .EXP_CHECKSUM (-1),
        .TIMEOUT_CYCS (100_000)
    ) runner ();

    initial begin
        wait (runner.done);
        @(negedge runner.clk);
        if (runner.result_shadow[3] == 32'h0)
            $fatal(1, "[xflux_kernel] FAIL: scalar and XFlux checksums disagree");
        if (runner.result_shadow[6] !== 32'd31)
            $fatal(1, "[xflux_kernel] FAIL: xflux_clz(1)=%0d expected 31",
                   runner.result_shadow[6]);
        $display("[xflux_kernel] scalar cycles=%0d  xflux cycles=%0d",
                 runner.result_shadow[4], runner.result_shadow[5]);
    end
endmodule : tb_xflux_kernel

// Memory-hierarchy variants: the same benchmark programs through the
// write-through direct-mapped D-cache (USE_DCACHE=1, miss = +1 stall cycle).
module tb_hello_cpi_dcache;
    soc_bench_runner #(
        .BENCH_NAME   ("hello_cpi_dcache"),
        .IMEM_INIT    ("build/sw/hello_cpi/imem.hex"),
        .EXP_CHECKSUM (499500),
        .TIMEOUT_CYCS (100_000),
        .USE_DCACHE   (1)
    ) runner ();
endmodule : tb_hello_cpi_dcache

module tb_spmv_csr_dcache;
    soc_bench_runner #(
        .BENCH_NAME   ("spmv_csr_dcache"),
        .IMEM_INIT    ("build/sw/spmv_csr/imem.hex"),
        .EXP_CHECKSUM (416),
        .TIMEOUT_CYCS (100_000),
        .USE_DCACHE   (1)
    ) runner ();
endmodule : tb_spmv_csr_dcache

`default_nettype wire
