// verification/unit/execution/tb_fp_addsub.sv
//
// Directed self-checking testbench for rtl/execution/fp/fp_addsub.sv.
// Hand-verified IEEE-754 vectors: exact sums, effective subtraction and
// cancellation (incl. signed-zero result per rounding mode), the classic
// 0.1f+0.2f inexact case, sticky rounding, subnormal add, inf handling,
// inf-inf invalid, and overflow.
//
// fflags: [4]=NV [3]=DZ [2]=OF [1]=UF [0]=NX.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;

module tb_fp_addsub;

    word_t      a_w, b_w;
    fpu_op_e    op_w;
    logic [2:0] rm_w;
    word_t      result_w;
    logic [4:0] fflags_w;

    fp_addsub dut (.a_i(a_w), .b_i(b_w), .op_i(op_w), .rm_i(rm_w),
                   .result_o(result_w), .fflags_o(fflags_w));

    int errors = 0;

    task automatic chk(input fpu_op_e op, input word_t a, input word_t b, input logic [2:0] rm,
                       input word_t exp_res, input logic [4:0] exp_flags, input string lbl);
        a_w = a; b_w = b; op_w = op; rm_w = rm; #1;
        if (result_w !== exp_res || fflags_w !== exp_flags) begin
            errors++;
            $display("FAIL %-22s: res=%08h(exp %08h) fl=%05b(exp %05b)",
                     lbl, result_w, exp_res, fflags_w, exp_flags);
        end
    endtask

    initial begin : body
        // ---- exact adds ----
        chk(FPU_ADD, 32'h3F80_0000, 32'h3F80_0000, FRM_RNE, 32'h4000_0000, 5'b00000, "1+1=2");
        chk(FPU_ADD, 32'h3F80_0000, 32'h4000_0000, FRM_RNE, 32'h4040_0000, 5'b00000, "1+2=3");
        chk(FPU_ADD, 32'h3FC0_0000, 32'h4010_0000, FRM_RNE, 32'h4070_0000, 5'b00000, "1.5+2.25=3.75");
        chk(FPU_ADD, 32'h4000_0000, 32'hBF80_0000, FRM_RNE, 32'h3F80_0000, 5'b00000, "2+(-1)=1");
        // ---- subtract ----
        chk(FPU_SUB, 32'h4040_0000, 32'h3F80_0000, FRM_RNE, 32'h4000_0000, 5'b00000, "3-1=2");
        chk(FPU_SUB, 32'h3F80_0000, 32'h3F80_0000, FRM_RNE, 32'h0000_0000, 5'b00000, "1-1=+0 (RNE)");
        chk(FPU_SUB, 32'h3F80_0000, 32'h3F80_0000, FRM_RDN, 32'h8000_0000, 5'b00000, "1-1=-0 (RDN)");
        // ---- inexact (classic) ----
        chk(FPU_ADD, 32'h3DCC_CCCD, 32'h3E4C_CCCD, FRM_RNE, 32'h3E99_999A, 5'b00001, "0.1+0.2 NX");
        // ---- sticky rounding: 1 + 2^-25 -> 1.0, NX ----
        chk(FPU_ADD, 32'h3F80_0000, 32'h3300_0000, FRM_RNE, 32'h3F80_0000, 5'b00001, "1+2^-25 -> 1 NX");
        // ---- signed zeros ----
        chk(FPU_ADD, 32'h0000_0000, 32'h0000_0000, FRM_RNE, 32'h0000_0000, 5'b00000, "+0 + +0 = +0");
        chk(FPU_ADD, 32'h8000_0000, 32'h8000_0000, FRM_RNE, 32'h8000_0000, 5'b00000, "-0 + -0 = -0");
        chk(FPU_ADD, 32'h0000_0000, 32'h8000_0000, FRM_RNE, 32'h0000_0000, 5'b00000, "+0 + -0 = +0 (RNE)");
        chk(FPU_ADD, 32'h0000_0000, 32'h8000_0000, FRM_RDN, 32'h8000_0000, 5'b00000, "+0 + -0 = -0 (RDN)");
        // ---- zero operand passthrough ----
        chk(FPU_ADD, 32'h0000_0000, 32'h4000_0000, FRM_RNE, 32'h4000_0000, 5'b00000, "0+2=2");
        chk(FPU_SUB, 32'h0000_0000, 32'h4000_0000, FRM_RNE, 32'hC000_0000, 5'b00000, "0-2=-2");
        // ---- subnormal add (exact) ----
        chk(FPU_ADD, 32'h0000_0001, 32'h0000_0001, FRM_RNE, 32'h0000_0002, 5'b00000, "2^-149+2^-149");
        // ---- infinities ----
        chk(FPU_ADD, 32'h7F80_0000, 32'h7F80_0000, FRM_RNE, 32'h7F80_0000, 5'b00000, "inf+inf=inf");
        chk(FPU_ADD, 32'h7F80_0000, 32'hFF80_0000, FRM_RNE, 32'h7FC0_0000, 5'b10000, "inf+(-inf)=qNaN NV");
        chk(FPU_SUB, 32'h7F80_0000, 32'h7F80_0000, FRM_RNE, 32'h7FC0_0000, 5'b10000, "inf-inf=qNaN NV");
        // ---- NaN ----
        chk(FPU_ADD, 32'h7FC0_0000, 32'h3F80_0000, FRM_RNE, 32'h7FC0_0000, 5'b00000, "qNaN+1=qNaN");
        chk(FPU_ADD, 32'h7F80_0001, 32'h3F80_0000, FRM_RNE, 32'h7FC0_0000, 5'b10000, "sNaN+1=qNaN NV");
        // ---- overflow ----
        chk(FPU_ADD, 32'h7F7F_FFFF, 32'h7F7F_FFFF, FRM_RNE, 32'h7F80_0000, 5'b00101, "MAX+MAX=inf OF|NX");

        if (errors == 0)
            $display("[FP-ADDSUB-TEST] PASS: all add/sub vectors verified.");
        else
            $fatal(1, "[FP-ADDSUB-TEST] FAIL: %0d mismatches", errors);
        $finish;
    end : body

endmodule : tb_fp_addsub

`default_nettype wire
