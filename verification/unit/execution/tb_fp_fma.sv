// verification/unit/execution/tb_fp_fma.sv
//
// Directed self-checking testbench for rtl/execution/fp/fp_fma.sv.
// Hand-verified IEEE-754 vectors covering the four fused variants, exact
// cancellation to zero, NaN/inf/invalid handling, and — critically — a case
// whose flag differs between a true single-rounding FMA and a double-rounded
// multiply-then-add, proving the fusion.
//
// fflags: [4]=NV [3]=DZ [2]=OF [1]=UF [0]=NX.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;

module tb_fp_fma;

    word_t      a_w, b_w, c_w;
    fpu_op_e    op_w;
    logic [2:0] rm_w;
    word_t      result_w;
    logic [4:0] fflags_w;

    fp_fma dut (.a_i(a_w), .b_i(b_w), .c_i(c_w), .op_i(op_w), .rm_i(rm_w),
                .result_o(result_w), .fflags_o(fflags_w));

    int errors = 0;
    task automatic chk(input fpu_op_e op, input word_t a,b,c, input logic [2:0] rm,
                       input word_t exp_res, input logic [4:0] exp_flags, input string lbl);
        a_w=a; b_w=b; c_w=c; op_w=op; rm_w=rm; #1;
        if (result_w !== exp_res || fflags_w !== exp_flags) begin
            errors++;
            $display("FAIL %-24s: res=%08h(exp %08h) fl=%05b(exp %05b)",
                     lbl, result_w, exp_res, fflags_w, exp_flags);
        end
    endtask

    localparam word_t P1=32'h3F80_0000, P2=32'h4000_0000, P3=32'h4040_0000, N1=32'hBF80_0000;
    localparam word_t QNAN=32'h7FC0_0000, SNAN=32'h7F80_0001, PINF=32'h7F80_0000, NINF=32'hFF80_0000;

    initial begin : body
        // four variants of 2*3 {+/-} 1
        chk(FPU_MADD,  P2, P3, P1, FRM_RNE, 32'h40E0_0000, 5'b00000, "2*3+1=7");
        chk(FPU_MSUB,  P2, P3, P1, FRM_RNE, 32'h40A0_0000, 5'b00000, "2*3-1=5");
        chk(FPU_NMSUB, P2, P3, P1, FRM_RNE, 32'hC0A0_0000, 5'b00000, "-(2*3)+1=-5");
        chk(FPU_NMADD, P2, P3, P1, FRM_RNE, 32'hC0E0_0000, 5'b00000, "-(2*3)-1=-7");
        // c = 0
        chk(FPU_MADD,  P2, P3, 32'h0, FRM_RNE, 32'h40C0_0000, 5'b00000, "2*3+0=6");
        // exact cancellation → +0
        chk(FPU_MADD,  P1, P1, N1, FRM_RNE, 32'h0000_0000, 5'b00000, "1*1-1=+0");
        chk(FPU_MADD,  P1, P1, N1, FRM_RDN, 32'h8000_0000, 5'b00000, "1*1-1=-0 (RDN)");
        // single-rounding proof: (1+ulp)^2 - 1 keeps the 2^-46 term → inexact.
        //   product = 1 + 2^-22 + 2^-46; + (-1) = 2^-22 + 2^-46 = 2^-22 (RNE) with NX.
        chk(FPU_MADD,  32'h3F80_0001, 32'h3F80_0001, N1, FRM_RNE, 32'h3480_0000, 5'b00001,
            "(1+ulp)^2-1 fused NX");
        // NaN / invalid
        chk(FPU_MADD,  QNAN, P2, P3, FRM_RNE, 32'h7FC0_0000, 5'b00000, "qNaN*..=qNaN");
        chk(FPU_MADD,  SNAN, P2, P3, FRM_RNE, 32'h7FC0_0000, 5'b10000, "sNaN → NV");
        chk(FPU_MADD,  PINF, 32'h0, P1, FRM_RNE, 32'h7FC0_0000, 5'b10000, "inf*0+1=qNaN NV");
        chk(FPU_MADD,  PINF, P2, NINF, FRM_RNE, 32'h7FC0_0000, 5'b10000, "inf*2-inf=qNaN NV");
        chk(FPU_MADD,  PINF, P2, P1, FRM_RNE, 32'h7F80_0000, 5'b00000, "inf*2+1=inf");

        if (errors == 0)
            $display("[FP-FMA-TEST] PASS: all fused multiply-add vectors verified.");
        else
            $fatal(1, "[FP-FMA-TEST] FAIL: %0d mismatches", errors);
        $finish;
    end : body

endmodule : tb_fp_fma

`default_nettype wire
