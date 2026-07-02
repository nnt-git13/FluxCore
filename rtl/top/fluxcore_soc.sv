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
    // Set USE_DCACHE=1 to insert a direct-mapped write-through data cache
    // between the CPU and bram_dmem. Default 0 = direct BRAM path (no stalls).
    parameter int    USE_DCACHE   = 0,
    parameter int    DCACHE_SETS  = 64,  // cache lines; must be a power of two
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
    word_t          dmem_addr, dmem_wdata,     dmem_rdata;
    logic           dmem_ren, dmem_wen;
    logic [3:0]     dmem_wstrb;
    logic           dmem_stall;  // 0 = direct BRAM, driven by dcache when USE_DCACHE=1

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
        .dmem_addr_o    (dmem_addr),
        .dmem_ren_o     (dmem_ren),
        .dmem_wen_o     (dmem_wen),
        .dmem_wstrb_o   (dmem_wstrb),
        .dmem_wdata_o   (dmem_wdata),
        .dmem_rdata_i   (dmem_rdata),
        .dmem_stall_i   (dmem_stall),
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
    bram_imem #(
        .DEPTH    (IMEM_DEPTH),
        .INIT_FILE(IMEM_INIT)
    ) u_imem (
        .clk        (clk),
        .addr_next_i(imem_addr_next),
        .rdata_o    (imem_rdata)
    );

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

        dcache #(
            .NSETS(DCACHE_SETS)
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
            .mem_addr_o   (bram_addr_w),
            .mem_ren_o    (/* debug only */),
            .mem_wen_o    (bram_wen_w),
            .mem_wstrb_o  (bram_wstrb_w),
            .mem_wdata_o  (bram_wdata_w),
            .mem_rdata_i  (bram_rdata_w),
            .hit_count_o  (/* connect to CSR or ILA */),
            .miss_count_o (/* connect to CSR or ILA */)
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
        assign dmem_stall = 1'b0;

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
