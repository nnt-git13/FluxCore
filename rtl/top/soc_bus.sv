// rtl/top/soc_bus.sv
//
// Single-master data-side address decoder for the FluxCore SoC.
//
// Address map (Spike-flavored so RISCOF signatures line up later):
//   0x0200_0000 .. 0x0200_FFFF  CLINT  (msip / mtimecmp / mtime)
//   0x1000_0000 .. 0x1000_0FFF  UART   (TXDATA +0, STATUS +4)
//   0x1000_1000 .. 0x1000_1FFF  GPIO   (LEDs +0)
//   everything else             data memory (dcache/BRAM path)
//
// MMIO accesses never enter the data cache: the bus sits between the CPU and
// the cache, and peripheral windows bypass it entirely.
//
// Read-return timing: BRAM (and each peripheral) registers its read data at
// the posedge that ends the MEM stage; the CPU consumes dmem_rdata_i live in
// the WB cycle.  The bus registers WHICH target was selected at the same
// posedge and muxes the return path in the WB cycle.

`default_nettype none

module soc_bus
    import fluxcore_pkg::*;
(
    input  wire logic        clk,
    input  wire logic        rst,

    // ── CPU data port ────────────────────────────────────────────────────────
    input  wire word_t       cpu_addr_i,
    input  wire logic        cpu_ren_i,
    input  wire logic        cpu_wen_i,
    input  wire logic [3:0]  cpu_wstrb_i,
    input  wire word_t       cpu_wdata_i,
    output word_t            cpu_rdata_o,

    // ── Memory path (dcache or BRAM) ─────────────────────────────────────────
    output word_t            mem_addr_o,
    output logic             mem_ren_o,
    output logic             mem_wen_o,
    output logic [3:0]       mem_wstrb_o,
    output word_t            mem_wdata_o,
    input  wire word_t       mem_rdata_i,

    // ── CLINT ────────────────────────────────────────────────────────────────
    output logic             clint_sel_o,
    output logic [15:0]      clint_addr_o,
    input  wire word_t       clint_rdata_i,

    // ── UART ─────────────────────────────────────────────────────────────────
    output logic             uart_sel_o,
    input  wire word_t       uart_rdata_i,

    // ── GPIO ─────────────────────────────────────────────────────────────────
    output logic             gpio_sel_o,
    input  wire word_t       gpio_rdata_i,

    // Shared peripheral write strobe / address / data
    output logic [3:0]       periph_addr_o,   // low byte-offset bits (UART/GPIO)
    output logic             periph_wen_o,
    output word_t            periph_wdata_o
);

    // -----------------------------------------------------------------------
    // Combinational decode
    // -----------------------------------------------------------------------
    logic is_clint_s, is_uart_s, is_gpio_s, is_mem_s;

    assign is_clint_s = (cpu_addr_i[31:16] == 16'h0200);
    assign is_uart_s  = (cpu_addr_i[31:12] == 20'h10000);
    assign is_gpio_s  = (cpu_addr_i[31:12] == 20'h10001);
    assign is_mem_s   = ~(is_clint_s | is_uart_s | is_gpio_s);

    // Memory path — gated so MMIO never reaches the dcache
    assign mem_addr_o  = cpu_addr_i;
    assign mem_ren_o   = cpu_ren_i & is_mem_s;
    assign mem_wen_o   = cpu_wen_i & is_mem_s;
    assign mem_wstrb_o = cpu_wstrb_i;
    assign mem_wdata_o = cpu_wdata_i;

    // Peripheral side (word accesses assumed; sub-word MMIO is not supported)
    assign clint_sel_o    = is_clint_s;
    assign clint_addr_o   = cpu_addr_i[15:0];
    assign uart_sel_o     = is_uart_s;
    assign gpio_sel_o     = is_gpio_s;
    assign periph_addr_o  = cpu_addr_i[3:0];
    assign periph_wen_o   = cpu_wen_i & ~is_mem_s;
    assign periph_wdata_o = cpu_wdata_i;

    // -----------------------------------------------------------------------
    // Read-return mux — target registered at the MEM→WB boundary
    // -----------------------------------------------------------------------
    logic [1:0] grant_q;   // 00 = mem, 01 = clint, 10 = uart, 11 = gpio

    always_ff @(posedge clk) begin
        if (rst)
            grant_q <= 2'b00;
        else
            grant_q <= is_clint_s ? 2'b01 :
                       is_uart_s  ? 2'b10 :
                       is_gpio_s  ? 2'b11 : 2'b00;
    end

    always_comb begin
        case (grant_q)
            2'b01:   cpu_rdata_o = clint_rdata_i;
            2'b10:   cpu_rdata_o = uart_rdata_i;
            2'b11:   cpu_rdata_o = gpio_rdata_i;
            default: cpu_rdata_o = mem_rdata_i;
        endcase
    end

endmodule : soc_bus

`default_nettype wire
