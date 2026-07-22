// rtl/top/fluxcore_soc.sv
//
// FluxCore SOC — standalone synthesis top-level for Zybo Z7-20 (xc7z020clg400-1).
//
// This module is the Vivado synthesis entry point (Stage 2 of the integration
// progression in docs/fpga/zybo-z7-plan.md). It wires fluxcore_top to BRAM-
// backed instruction and data memories and exposes only clk and rst at the
// top level — no AXI, no PS block, no I/O other than clock and reset.
//
// Instruction memory timing (BRAM DO_REG=0):
//   bram_imem receives imem_addr_next_o (= next PC from fetch_unit) as its
//   address input. The BRAM registers this at each posedge, so its output
//   arrives in the FOLLOWING cycle when imem_addr_o = old imem_addr_next_o.
//   From the pipeline's perspective this is zero-latency: the instruction for
//   PC X is valid in the cycle that imem_addr_o = X.
//
// Data memory timing (BRAM DO_REG=0):
//   bram_dmem receives dmem_addr_o combinatorially and registers it at the
//   posedge ending the MEM stage. Its output is valid in the WB stage cycle.
//   wb_stage uses this live BRAM word for load writeback, bypassing the stale
//   mem_wb_q.rd_data value captured at the posedge ending MEM.
//   Stores are correct: the BRAM write fires at the architecturally correct
//   commit posedge (end of MEM stage).
//
// Parameters:
//   RESET_VECTOR  First instruction address after reset.
//   TRAP_VECTOR   Initial mtvec (M-mode trap handler base address).
//   IMEM_DEPTH    Instruction memory depth in 32-bit words. Default 4096 (16 KB).
//   DMEM_DEPTH    Data memory depth in 32-bit words. Default 2048 (8 KB).
//   IMEM_INIT     $readmemh hex file for instruction ROM. "" → zeroed ROM.
//   DMEM_INIT     $readmemh hex file for data RAM. "" → zeroed RAM.
//
// Synthesis notes:
//   • For bitstream generation, supply IMEM_INIT with the compiled program.
//   • Timing target: 50 MHz on xc7z020clg400-1 (20 ns period), constrained by
//     vivado/constraints/fluxcore_soc.xdc.
//   • Observation signals are intentionally internal. The XDC marks retirement
//     and exception nets for debug so Vivado can preserve/connect them to an
//     ILA during implementation debug setup.

`default_nettype none

module fluxcore_soc
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
    import pipeline_pkg::*;
#(
    parameter word_t RESET_VECTOR = 32'h0000_0000,
    parameter word_t TRAP_VECTOR  = 32'h0000_0100,
    parameter int    IMEM_DEPTH   = 4096,
    parameter int    DMEM_DEPTH   = 2048,
    parameter        IMEM_INIT    = "",
    parameter        DMEM_INIT    = "",
    // Set USE_DCACHE=1 to insert a data cache between the CPU and bram_dmem.
    // Default 0 = direct BRAM path (no stalls). Cache geometry/policy below;
    // the defaults give a 2 KiB 2-way write-back cache with 16 B lines.
    parameter int    USE_DCACHE   = 0,
    parameter int    DCACHE_SETS  = 64,  // sets; must be a power of two
    parameter int    DCACHE_LINE_WORDS = 4,   // words per line (power of two)
    parameter int    DCACHE_WAYS       = 2,   // associativity (power of two)
    parameter bit    DCACHE_WRITE_ALLOCATE = 1'b1,
    parameter bit    DCACHE_WRITE_BACK     = 1'b1,
    parameter bit    DCACHE_NONBLOCKING    = 1'b1,  // hit-under-miss MSHR
    // Set USE_ICACHE=1 to insert an instruction cache between fetch and
    // bram_imem (fetch stalls on I-miss via the imem_valid pin). Default 0 =
    // direct BRAM path, no fetch stalls, unchanged behavior.
    parameter int    USE_ICACHE   = 0,
    parameter int    ICACHE_SETS       = 64,
    parameter int    ICACHE_LINE_WORDS = 4,
    parameter int    ICACHE_WAYS       = 2,
    // Simulation override for the UART divisor (0 = derive from CLK_HZ/BAUD)
    parameter int    UART_BAUD_DIV = 0
)
(
    input  wire logic clk,
    input  wire logic rst,          // external active-high reset button
    output logic      uart_tx_o,    // 8N1 TX @ 115200 (PMOD pin)
    output logic [3:0] led_o        // board LEDs (GPIO register)
);

    // -----------------------------------------------------------------------
    // CPU ↔ memory wires
    // -----------------------------------------------------------------------
    word_t          imem_addr, imem_addr_next, imem_rdata;
    logic           imem_valid;
    logic           fencei_flush;
    word_t          dc_hits, dc_misses, ic_hits, ic_misses;
    word_t          dmem_addr, dmem_wdata,     dmem_rdata;
    logic           dmem_ren, dmem_wen;
    logic [3:0]     dmem_wstrb;
    logic           dmem_stall;  // 0 = direct BRAM, driven by dcache when USE_DCACHE=1
    // Non-blocking dcache handshake (tied off unless USE_DCACHE=1 with
    // DCACHE_NONBLOCKING=1)
    logic           dmem_defer_ok, dmem_defer, dmem_fill_done;
    word_t          dmem_fill_data;

    // Bus → memory-path (dcache/BRAM) signals
    word_t          mem_addr, mem_wdata, mem_rdata;
    logic           mem_ren, mem_wen;
    logic [3:0]     mem_wstrb;

    // Bus → peripheral signals
    logic           clint_sel, uart_sel, gpio_sel;
    logic [15:0]    clint_addr;
    logic [3:0]     periph_addr;
    logic           periph_wen;
    word_t          periph_wdata;
    word_t          clint_rdata, uart_rdata, gpio_rdata;

    // CLINT → core interrupt lines
    logic           mtip, msip;
    logic [63:0]    mtime;
    retirement_event_t retire;
    exception_meta_t   exc;
    word_t             exc_pc;
    logic [1:0]        rst_sync_q = 2'b11;
    logic              core_rst;

    always_ff @(posedge clk) begin
        rst_sync_q <= {rst_sync_q[0], rst};
    end

    assign core_rst = rst_sync_q[1];

    // -----------------------------------------------------------------------
    // Debug preservation wires
    //
    // fluxcore_soc intentionally has only clk/rst top-level ports in this
    // standalone milestone. These marked nets keep the CPU's architecturally
    // visible retirement/exception behavior observable for later ILA insertion
    // and prevent Vivado from trimming the entire core as unobservable logic.
    // -----------------------------------------------------------------------
    (* keep = "true", mark_debug = "true" *) logic     dbg_retire_valid;
    (* keep = "true", mark_debug = "true" *) word_t    dbg_retire_pc;
    (* keep = "true", mark_debug = "true" *) instr_t   dbg_retire_instr;
    (* keep = "true", mark_debug = "true" *) logic     dbg_retire_rd_wen;
    (* keep = "true", mark_debug = "true" *) reg_idx_t dbg_retire_rd_addr;
    (* keep = "true", mark_debug = "true" *) word_t    dbg_retire_rd_data;
    (* keep = "true", mark_debug = "true" *) logic     dbg_exception_valid;
    (* keep = "true", mark_debug = "true" *) logic [EXC_CAUSE_W-1:0] dbg_exception_cause;
    (* keep = "true", mark_debug = "true" *) word_t    dbg_exception_tval;
    (* keep = "true", mark_debug = "true" *) word_t    dbg_exception_pc;

    assign dbg_retire_valid    = retire.valid;
    assign dbg_retire_pc       = retire.pc;
    assign dbg_retire_instr    = retire.instr;
    assign dbg_retire_rd_wen   = retire.rd_wen;
    assign dbg_retire_rd_addr  = retire.rd_addr;
    assign dbg_retire_rd_data  = retire.rd_data;
    assign dbg_exception_valid = exc.valid;
    assign dbg_exception_cause = exc.cause;
    assign dbg_exception_tval  = exc.tval;
    assign dbg_exception_pc    = exc_pc;

    // -----------------------------------------------------------------------
    // CPU
    // -----------------------------------------------------------------------
    fluxcore_top #(
        .RESET_VECTOR(RESET_VECTOR),
        .TRAP_VECTOR (TRAP_VECTOR)
    ) u_cpu (
        .clk            (clk),
        .rst            (core_rst),
        .imem_addr_o    (imem_addr),
        .imem_addr_next_o(imem_addr_next),
        .imem_rdata_i   (imem_rdata),
        .imem_valid_i   (imem_valid),
        .fencei_flush_o (fencei_flush),
        .dc_hits_i      (dc_hits),
        .dc_misses_i    (dc_misses),
        .ic_hits_i      (ic_hits),
        .ic_misses_i    (ic_misses),
        .dmem_addr_o    (dmem_addr),
        .dmem_ren_o     (dmem_ren),
        .dmem_wen_o     (dmem_wen),
        .dmem_wstrb_o   (dmem_wstrb),
        .dmem_wdata_o   (dmem_wdata),
        .dmem_rdata_i   (dmem_rdata),
        .dmem_stall_i   (dmem_stall),
        .dmem_defer_ok_o(dmem_defer_ok),
        .dmem_defer_i   (dmem_defer),
        .dmem_fill_done_i(dmem_fill_done),
        .dmem_fill_data_i(dmem_fill_data),
        .mtip_i         (mtip),
        .msip_i         (msip),
        .mtime_i        (mtime),
        .retire_o       (retire),
        .exception_o    (exc),
        .exception_pc_o (exc_pc)
    );

    // -----------------------------------------------------------------------
    // Instruction BRAM
    // Addressed via imem_addr_next so output is ready when imem_addr_o = PC.
    // -----------------------------------------------------------------------
    if (USE_ICACHE) begin : g_icache
        // fetch -> icache (combinational hit) -> mem_if_bram -> bram_imem.
        // The BRAM behind the I-cache serves fill bursts, addressed by the
        // adapter, so the addr_next prefetch port is unused here.
        logic        i_req_valid, i_req_ready, i_rsp_valid, i_rsp_ready;
        mem_if_pkg::mem_req_t i_req;
        mem_if_pkg::mem_rsp_t i_rsp;
        word_t       ibram_addr, ibram_wdata, ibram_rdata;
        logic        ibram_wen;
        logic [3:0]  ibram_wstrb;

        icache #(
            .NSETS(ICACHE_SETS), .LINE_WORDS(ICACHE_LINE_WORDS),
            .WAYS(ICACHE_WAYS)
        ) u_icache (
            .clk(clk), .rst(core_rst),
            .pc_i(imem_addr),
            .instr_o(imem_rdata),
            .instr_valid_o(imem_valid),
            .flush_i(fencei_flush),
            .mem_req_valid_o(i_req_valid), .mem_req_ready_i(i_req_ready),
            .mem_req_o(i_req),
            .mem_rsp_valid_i(i_rsp_valid), .mem_rsp_ready_o(i_rsp_ready),
            .mem_rsp_i(i_rsp),
            .hit_count_o(ic_hits), .miss_count_o(ic_misses)
        );

        mem_if_bram u_imemif (
            .clk(clk), .rst(core_rst),
            .req_valid_i(i_req_valid), .req_ready_o(i_req_ready), .req_i(i_req),
            .rsp_valid_o(i_rsp_valid), .rsp_ready_i(i_rsp_ready), .rsp_o(i_rsp),
            .bram_addr_o(ibram_addr), .bram_wen_o(ibram_wen),
            .bram_wstrb_o(ibram_wstrb), .bram_wdata_o(ibram_wdata),
            .bram_rdata_i(ibram_rdata)
        );

        // Fill store: bram_imem (word-array ROM). Its addr_next_i registers
        // at the posedge and presents rdata next cycle — exactly the 1-cycle
        // contract mem_if_bram assumes. The adapter's write pins go nowhere:
        // instruction memory is a ROM on this side of the Harvard split.
        bram_imem #(
            .DEPTH    (IMEM_DEPTH),
            .INIT_FILE(IMEM_INIT)
        ) u_imem (
            .clk        (clk),
            .addr_next_i(ibram_addr),
            .rdata_o    (ibram_rdata)
        );
    end else begin : g_no_icache
        assign ic_hits    = '0;
        assign ic_misses  = '0;
        assign imem_valid = 1'b1;

    bram_imem #(
        .DEPTH    (IMEM_DEPTH),
        .INIT_FILE(IMEM_INIT)
    ) u_imem (
        .clk        (clk),
        .addr_next_i(imem_addr_next),
        .rdata_o    (imem_rdata)
    );
    end

    // -----------------------------------------------------------------------
    // SoC bus: decodes the CPU data port into {memory path, CLINT, UART, GPIO}
    // -----------------------------------------------------------------------
    soc_bus u_bus (
        .clk           (clk),
        .rst           (core_rst),
        .cpu_addr_i    (dmem_addr),
        .cpu_ren_i     (dmem_ren),
        .cpu_wen_i     (dmem_wen),
        .cpu_wstrb_i   (dmem_wstrb),
        .cpu_wdata_i   (dmem_wdata),
        .cpu_rdata_o   (dmem_rdata),
        .mem_addr_o    (mem_addr),
        .mem_ren_o     (mem_ren),
        .mem_wen_o     (mem_wen),
        .mem_wstrb_o   (mem_wstrb),
        .mem_wdata_o   (mem_wdata),
        .mem_rdata_i   (mem_rdata),
        .clint_sel_o   (clint_sel),
        .clint_addr_o  (clint_addr),
        .clint_rdata_i (clint_rdata),
        .uart_sel_o    (uart_sel),
        .uart_rdata_i  (uart_rdata),
        .gpio_sel_o    (gpio_sel),
        .gpio_rdata_i  (gpio_rdata),
        .periph_addr_o (periph_addr),
        .periph_wen_o  (periph_wen),
        .periph_wdata_o(periph_wdata)
    );

    clint u_clint (
        .clk     (clk),
        .rst     (core_rst),
        .sel_i   (clint_sel),
        .addr_i  (clint_addr),
        .wen_i   (periph_wen),
        .wdata_i (periph_wdata),
        .rdata_o (clint_rdata),
        .mtip_o  (mtip),
        .msip_o  (msip),
        .mtime_o (mtime)
    );

    uart_tx #(
        .CLK_HZ  (50_000_000),
        .BAUD    (115_200),
        .BAUD_DIV(UART_BAUD_DIV)
    ) u_uart (
        .clk     (clk),
        .rst     (core_rst),
        .sel_i   (uart_sel),
        .addr_i  (periph_addr),
        .wen_i   (periph_wen),
        .wdata_i (periph_wdata),
        .rdata_o (uart_rdata),
        .tx_o    (uart_tx_o)
    );

    gpio #(
        .WIDTH(4)
    ) u_gpio (
        .clk     (clk),
        .rst     (core_rst),
        .sel_i   (gpio_sel),
        .addr_i  (periph_addr),
        .wen_i   (periph_wen),
        .wdata_i (periph_wdata),
        .rdata_o (gpio_rdata),
        .gpio_o  (led_o)
    );

    // -----------------------------------------------------------------------
    // Data memory: optional dcache in front of bram_dmem
    //
    // USE_DCACHE=0 (default): direct BRAM path, dmem_stall is tied low.
    //   Read data arrives in WB cycle and is consumed live by wb_stage.
    //
    // USE_DCACHE=1: dcache sits between CPU and BRAM.
    //   Cache hits return registered data in the same WB cycle as direct BRAM
    //   (zero extra latency). Cache misses add 1 stall cycle.
    //   Hit/miss counters are preserved internally; connect to ILA or CSRs
    //   for CPI measurement.
    // -----------------------------------------------------------------------
    if (USE_DCACHE) begin : g_dcache
        logic [31:0] bram_addr_w, bram_wdata_w, bram_rdata_w;
        logic        bram_wen_w;
        logic [3:0]  bram_wstrb_w;
        // dcache <-> mem_if_bram (frozen protocol; ADR 0003)
        logic            m_req_valid, m_req_ready, m_rsp_valid, m_rsp_ready;
        mem_if_pkg::mem_req_t m_req;
        mem_if_pkg::mem_rsp_t m_rsp;

        dcache #(
            .NSETS         (DCACHE_SETS),
            .LINE_WORDS    (DCACHE_LINE_WORDS),
            .WAYS          (DCACHE_WAYS),
            .WRITE_ALLOCATE(DCACHE_WRITE_ALLOCATE),
            .WRITE_BACK    (DCACHE_WRITE_BACK),
            .NONBLOCKING   (DCACHE_NONBLOCKING)
        ) u_dcache (
            .clk          (clk),
            .rst          (core_rst),
            .cpu_addr_i   (mem_addr),
            .cpu_ren_i    (mem_ren),
            .cpu_wen_i    (mem_wen),
            .cpu_wstrb_i  (mem_wstrb),
            .cpu_wdata_i  (mem_wdata),
            .cpu_rdata_o  (mem_rdata),
            .dmem_stall_o (dmem_stall),
            .defer_ok_i   (dmem_defer_ok),
            .miss_defer_o (dmem_defer),
            .fill_done_o  (dmem_fill_done),
            .fill_data_o  (dmem_fill_data),
            .mem_req_valid_o(m_req_valid),
            .mem_req_ready_i(m_req_ready),
            .mem_req_o      (m_req),
            .mem_rsp_valid_i(m_rsp_valid),
            .mem_rsp_ready_o(m_rsp_ready),
            .mem_rsp_i      (m_rsp),
            .hit_count_o  (dc_hits),
            .miss_count_o (dc_misses)
        );

        // Protocol-to-BRAM adapter: bare-BRAM response timing, so the cache's
        // legacy cycle behavior against BRAM is preserved (see mem_if_bram).
        mem_if_bram u_memif (
            .clk         (clk),
            .rst         (core_rst),
            .req_valid_i (m_req_valid),
            .req_ready_o (m_req_ready),
            .req_i       (m_req),
            .rsp_valid_o (m_rsp_valid),
            .rsp_ready_i (m_rsp_ready),
            .rsp_o       (m_rsp),
            .bram_addr_o (bram_addr_w),
            .bram_wen_o  (bram_wen_w),
            .bram_wstrb_o(bram_wstrb_w),
            .bram_wdata_o(bram_wdata_w),
            .bram_rdata_i(bram_rdata_w)
        );

        bram_dmem #(
            .DEPTH    (DMEM_DEPTH),
            .INIT_FILE(DMEM_INIT)
        ) u_dmem (
            .clk     (clk),
            .addr_i  (bram_addr_w),
            .wen_i   (bram_wen_w),
            .wstrb_i (bram_wstrb_w),
            .wdata_i (bram_wdata_w),
            .rdata_o (bram_rdata_w)
        );
    end else begin : g_no_dcache
        assign dc_hits        = '0;
        assign dc_misses      = '0;
        assign dmem_stall     = 1'b0;
        assign dmem_defer     = 1'b0;
        assign dmem_fill_done = 1'b0;
        assign dmem_fill_data = '0;

        bram_dmem #(
            .DEPTH    (DMEM_DEPTH),
            .INIT_FILE(DMEM_INIT)
        ) u_dmem (
            .clk     (clk),
            .addr_i  (mem_addr),
            .wen_i   (mem_wen),
            .wstrb_i (mem_wstrb),
            .wdata_i (mem_wdata),
            .rdata_o (mem_rdata)
        );
    end

endmodule : fluxcore_soc

`default_nettype wire
