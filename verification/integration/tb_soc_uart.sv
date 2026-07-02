// verification/integration/tb_soc_uart.sv
//
// End-to-end UART console test.
//
// Runs software/benchmarks/hello_uart.c on the full SoC with a shortened
// baud divisor (UART_BAUD_DIV=16), decodes the serial line with a behavioral
// 8N1 receiver, and checks the exact banner string — proving the whole path
// C runtime → soc_bus → uart_tx → serial framing.
//
// Also snoops the result block like tb_soc_benchmarks (checksum 0xC0) and
// checks the GPIO LED register took the last written value (0x5).

`timescale 1ns / 1ps
`default_nettype none

module tb_soc_uart;

    localparam int    BAUD_DIV  = 16;
    localparam string EXP_STR   = "hello from fluxcore\n";
    localparam logic [31:0] RESULT_BASE  = 32'h0000_1FE0;
    localparam logic [31:0] RESULT_DONE  = 32'h600D_D00E;
    localparam int    TIMEOUT_CYCS = 200_000;

    logic clk = 0;
    logic rst = 1;
    always #5 clk = ~clk;

    logic       uart_tx;
    logic [3:0] led;

    fluxcore_soc #(
        .IMEM_INIT    ("build/sw/hello_uart/imem.hex"),
        .USE_DCACHE   (0),
        .UART_BAUD_DIV(BAUD_DIV)
    ) u_soc (
        .clk      (clk),
        .rst      (rst),
        .uart_tx_o(uart_tx),
        .led_o    (led)
    );

    int unsigned cyc = 0;
    always_ff @(posedge clk) cyc <= cyc + 1;

    // -----------------------------------------------------------------------
    // Behavioral 8N1 receiver (samples mid-bit at the known divisor)
    // -----------------------------------------------------------------------
    byte rx_buf [$];

    task automatic uart_rx_byte();
        logic [7:0] data;
        // start bit already low on entry; move to the middle of bit 0
        repeat (BAUD_DIV + BAUD_DIV/2) @(posedge clk);
        for (int i = 0; i < 8; i++) begin
            data[i] = uart_tx;
            repeat (BAUD_DIV) @(posedge clk);
        end
        if (uart_tx !== 1'b1)
            $fatal(1, "[soc_uart] FAIL: missing stop bit (cyc=%0d)", cyc);
        rx_buf.push_back(byte'(data));
    endtask

    initial begin : rx_engine
        @(negedge rst);
        forever begin
            @(negedge uart_tx);   // start-bit edge
            uart_rx_byte();
        end
    end

    // -----------------------------------------------------------------------
    // Result-block snoop (same protocol as tb_soc_benchmarks)
    // -----------------------------------------------------------------------
    wire [31:0] mon_addr  = u_soc.dmem_addr;
    wire        mon_wen   = u_soc.dmem_wen;
    wire [3:0]  mon_wstrb = u_soc.dmem_wstrb;
    wire [31:0] mon_wdata = u_soc.dmem_wdata;

    logic [31:0] result_shadow [0:7];
    logic        done = 0;

    always_ff @(posedge clk) begin
        if (mon_wen && mon_wstrb == 4'hF
                    && mon_addr >= RESULT_BASE
                    && mon_addr <= RESULT_BASE + 32'd28) begin
            result_shadow[(mon_addr - RESULT_BASE) >> 2] <= mon_wdata;
            if (mon_addr == RESULT_BASE + 32'd28 && mon_wdata == RESULT_DONE)
                done <= 1'b1;
        end
    end

    // -----------------------------------------------------------------------
    // Stimulus and checks
    // -----------------------------------------------------------------------
    initial begin : stim
        string got;

        repeat (5) @(posedge clk);
        @(negedge clk); rst = 0;

        wait (done || cyc >= TIMEOUT_CYCS);
        // Allow the final character to finish shifting out
        repeat (BAUD_DIV * 12) @(posedge clk);

        if (!done)
            $fatal(1, "[soc_uart] TIMEOUT after %0d cycles", cyc);

        if (result_shadow[3] !== 32'h0000_00C0)
            $fatal(1, "[soc_uart] FAIL checksum=0x%08h expected 0xC0", result_shadow[3]);

        got = "";
        foreach (rx_buf[i]) got = {got, string'(rx_buf[i])};

        if (got != EXP_STR) begin
            $display("[soc_uart] expected: %s", EXP_STR);
            $display("[soc_uart] received: %s", got);
            $fatal(1, "[soc_uart] FAIL: banner mismatch (%0d chars received)", rx_buf.size());
        end

        if (led !== 4'h5)
            $fatal(1, "[soc_uart] FAIL: led=0x%h expected 0x5", led);

        $display("[soc_uart] banner received over TX line: %s", got);
        $display("[soc_uart] PASS");
        $finish;
    end : stim

endmodule : tb_soc_uart

`default_nettype wire
