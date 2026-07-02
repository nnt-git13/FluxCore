// rtl/peripherals/gpio.sv
//
// Memory-mapped GPIO output register (board LEDs).
//
// Register map (word offsets from the peripheral base):
//   +0x0  LEDS  (RW) bits[WIDTH-1:0] drive the LED pins.
//
// Read timing matches BRAM: rdata registered at end of MEM, consumed in WB.

`default_nettype none

module gpio #(
    parameter int unsigned WIDTH = 4
)(
    input  wire logic        clk,
    input  wire logic        rst,

    input  wire logic        sel_i,
    input  wire logic [3:0]  addr_i,
    input  wire logic        wen_i,
    input  wire logic [31:0] wdata_i,
    output logic [31:0]      rdata_o,

    output logic [WIDTH-1:0] gpio_o
);

    always_ff @(posedge clk) begin
        if (rst)
            gpio_o <= '0;
        else if (sel_i & wen_i & (addr_i[3:2] == 2'b00))
            gpio_o <= wdata_i[WIDTH-1:0];
    end

    always_ff @(posedge clk) begin
        if (rst)
            rdata_o <= '0;
        else if (sel_i)
            rdata_o <= {{(32-WIDTH){1'b0}}, gpio_o};
    end

endmodule : gpio

`default_nettype wire
