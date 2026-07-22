// verification/unit/execution/tb_fp_mul.sv
//
// Directed self-checking testbench for rtl/execution/fp/fp_mul.sv.
// Hand-verified IEEE-754 vectors: exact products, rounding, signed zero/inf,
// NaN propagation, invalid (inf*0), a subnormal result, and overflow-to-inf.
// The exhaustive host-softfloat sweep lands in Phase E.
//
// fflags: [4]=NV [3]=DZ [2]=OF [1]=UF [0]=NX.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;

module tb_fp_mul;

    word_t      a_w, b_w;
    logic [2:0] rm_w;
    word_t      result_w;
    logic [4:0] fflags_w;

    fp_mul dut (.a_i(a_w), .b_i(b_w), .rm_i(rm_w), .result_o(result_w), .fflags_o(fflags_w));

    int errors = 0;

    task automatic chk(input word_t a, input word_t b, input logic [2:0] rm,
                       input word_t exp_res, input logic [4:0] exp_flags, input string lbl);
        a_w = a; b_w = b; rm_w = rm; #1;
        if (result_w !== exp_res || fflags_w !== exp_flags) begin
            errors++;
            $display("FAIL %-22s: %08h*%08h res=%08h(exp %08h) fl=%05b(exp %05b)",
                     lbl, a, b, result_w, exp_res, fflags_w, exp_flags);
        end
    endtask

    initial begin : body
        // exact products
        chk(32'h4000_0000, 32'h4040_0000, FRM_RNE, 32'h40C0_0000, 5'b00000, "2*3=6");
        chk(32'h3FC0_0000, 32'h3FC0_0000, FRM_RNE, 32'h4010_0000, 5'b00000, "1.5*1.5=2.25");
        chk(32'hC000_0000, 32'h4040_0000, FRM_RNE, 32'hC0C0_0000, 5'b00000, "-2*3=-6");
        chk(32'h3F80_0000, 32'h3F80_0000, FRM_RNE, 32'h3F80_0000, 5'b00000, "1*1=1");
        // signed zero
        chk(32'h0000_0000, 32'h40A0_0000, FRM_RNE, 32'h0000_0000, 5'b00000, "+0*5=+0");
        chk(32'h8000_0000, 32'h40A0_0000, FRM_RNE, 32'h8000_0000, 5'b00000, "-0*5=-0");
        chk(32'h8000_0000, 32'hC0A0_0000, FRM_RNE, 32'h0000_0000, 5'b00000, "-0*-5=+0");
        // infinity
        chk(32'h7F80_0000, 32'h4000_0000, FRM_RNE, 32'h7F80_0000, 5'b00000, "inf*2=inf");
        chk(32'hFF80_0000, 32'h4000_0000, FRM_RNE, 32'hFF80_0000, 5'b00000, "-inf*2=-inf");
        chk(32'h7F80_0000, 32'h0000_0000, FRM_RNE, 32'h7FC0_0000, 5'b10000, "inf*0=qNaN NV");
        // NaN propagation
        chk(32'h7FC0_0000, 32'h4000_0000, FRM_RNE, 32'h7FC0_0000, 5'b00000, "qNaN*2=qNaN");
        chk(32'h7F80_0001, 32'h4000_0000, FRM_RNE, 32'h7FC0_0000, 5'b10000, "sNaN*2=qNaN NV");
        // rounding (inexact)
        chk(32'h3F80_0001, 32'h3F80_0001, FRM_RNE, 32'h3F80_0002, 5'b00001, "(1+ulp)^2 NX");
        // subnormal result (exact): 2^-126 * 0.5 = 2^-127
        chk(32'h0080_0000, 32'h3F00_0000, FRM_RNE, 32'h0040_0000, 5'b00000, "2^-126*0.5=2^-127 sub");
        // overflow to infinity: MAX * 2 -> inf, OF|NX
        chk(32'h7F7F_FFFF, 32'h4000_0000, FRM_RNE, 32'h7F80_0000, 5'b00101, "MAX*2=inf OF|NX");
        // overflow toward zero -> max finite
        chk(32'h7F7F_FFFF, 32'h4000_0000, FRM_RTZ, 32'h7F7F_FFFF, 5'b00101, "MAX*2 RTZ=MAX OF|NX");

        if (errors == 0)
            $display("[FP-MUL-TEST] PASS: all multiply vectors verified.");
        else
            $fatal(1, "[FP-MUL-TEST] FAIL: %0d mismatches", errors);
        $finish;
    end : body

endmodule : tb_fp_mul

`default_nettype wire
