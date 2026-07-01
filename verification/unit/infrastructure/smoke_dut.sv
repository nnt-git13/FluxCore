// verification/unit/infrastructure/smoke_dut.sv
//
// Toolchain infrastructure smoke-test module.
//
// This module is NOT FluxCore processor RTL. It exists solely to confirm
// that the SystemVerilog toolchain is operational: compilation succeeds,
// packed logic ports are handled correctly, and combinational arithmetic
// produces the expected result.
//
// A parameterized adder is used as the simplest non-trivial synthesizable
// circuit that exercises these properties.

`timescale 1ns / 1ps

module smoke_dut #(
    parameter int unsigned WIDTH = 8
) (
    input  logic [WIDTH-1:0] a_i,
    input  logic [WIDTH-1:0] b_i,
    output logic [WIDTH:0]   sum_o,   // WIDTH+1 bits: full sum with carry
    output logic [WIDTH-1:0] xor_o    // bitwise XOR: no overflow
);

    assign sum_o = {1'b0, a_i} + {1'b0, b_i};
    assign xor_o = a_i ^ b_i;

endmodule
