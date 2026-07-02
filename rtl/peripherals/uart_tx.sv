// rtl/peripherals/uart_tx.sv
//
// Minimal memory-mapped UART transmitter — 8N1, TX only.
//
// Register map (word offsets from the peripheral base):
//   +0x0  TXDATA  (WO) writing bits[7:0] queues one byte when idle.
//                 Writes while busy are dropped (software must poll STATUS).
//   +0x4  STATUS  (RO) bit0 = busy (1 while a frame is shifting out).
//
// Frame: 1 start bit (0), 8 data bits LSB-first, 1 stop bit (1).
// Baud divisor = CLK_HZ / BAUD, overridable for fast simulation via BAUD_DIV.
//
// Read timing matches BRAM: rdata is registered at the posedge that ends the
// MEM stage and consumed by the CPU in the WB cycle.

`default_nettype none

module uart_tx #(
    parameter int unsigned CLK_HZ   = 50_000_000,
    parameter int unsigned BAUD     = 115_200,
    // Direct divisor override (0 = derive from CLK_HZ/BAUD).
    // Simulations set a small value (e.g. 4) to keep runs short.
    parameter int unsigned BAUD_DIV = 0
)(
    input  wire logic        clk,
    input  wire logic        rst,

    // MMIO slave interface (selected by soc_bus)
    input  wire logic        sel_i,      // address decodes to this peripheral
    input  wire logic [3:0]  addr_i,     // low address bits (byte offset)
    input  wire logic        wen_i,
    input  wire logic [31:0] wdata_i,
    output logic [31:0]      rdata_o,    // registered; valid in WB cycle

    output logic             tx_o        // serial line (idle high)
);

    localparam int unsigned DIV = (BAUD_DIV != 0) ? BAUD_DIV : (CLK_HZ / BAUD);

    // -----------------------------------------------------------------------
    // Transmit shift engine
    // -----------------------------------------------------------------------
    logic [9:0]  shift_q;    // {stop, data[7:0], start}
    logic [3:0]  bits_q;     // bits remaining
    logic [31:0] baud_q;     // baud-tick down-counter
    logic        busy_q;

    wire wr_txdata = sel_i & wen_i & (addr_i[3:2] == 2'b00);

    always_ff @(posedge clk) begin
        if (rst) begin
            shift_q <= '1;
            bits_q  <= '0;
            baud_q  <= '0;
            busy_q  <= 1'b0;
            tx_o    <= 1'b1;
        end else if (!busy_q) begin
            tx_o <= 1'b1;
            if (wr_txdata) begin
                shift_q <= {1'b1, wdata_i[7:0], 1'b0};  // stop, data, start
                bits_q  <= 4'd10;
                baud_q  <= DIV - 1;
                busy_q  <= 1'b1;
            end
        end else begin
            if (baud_q == 0) begin
                tx_o    <= shift_q[0];
                shift_q <= {1'b1, shift_q[9:1]};
                baud_q  <= DIV - 1;
                if (bits_q == 1) begin
                    busy_q <= 1'b0;
                    bits_q <= '0;
                end else begin
                    bits_q <= bits_q - 1;
                end
            end else begin
                baud_q <= baud_q - 1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Registered MMIO read (STATUS at +4; TXDATA reads as 0)
    // -----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst)
            rdata_o <= '0;
        else if (sel_i)
            rdata_o <= (addr_i[3:2] == 2'b01) ? {31'b0, busy_q} : 32'h0;
    end

endmodule : uart_tx

`default_nettype wire
