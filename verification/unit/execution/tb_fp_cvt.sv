// verification/unit/execution/tb_fp_cvt.sv
//
// Directed self-checking testbench for rtl/execution/fp/fp_cvt.sv.
// Every expected result/flag below is hand-computed from the IEEE-754 and
// RISC-V F-extension rules. The exhaustive host-softfloat sweep lands in
// Phase E; this file pins the corner cases and the rounding-mode matrix.
//
// fflags bit layout: [4]=NV [3]=DZ [2]=OF [1]=UF [0]=NX.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;

module tb_fp_cvt;

    word_t      a_w, int_w;
    fpu_op_e    op_w;
    logic [2:0] rm_w;
    word_t      result_w;
    logic [4:0] fflags_w;

    fp_cvt dut (
        .a_i(a_w), .int_i(int_w), .op_i(op_w), .rm_i(rm_w),
        .result_o(result_w), .fflags_o(fflags_w)
    );

    int errors = 0;

    // Drive an input (float or integer bits) and check result + flags.
    task automatic chk(
        input fpu_op_e   op,
        input logic [2:0] rm,
        input word_t     din,
        input word_t     exp_res,
        input logic [4:0] exp_flags,
        input string     lbl
    );
        a_w = din; int_w = din; op_w = op; rm_w = rm;
        #1;
        if (result_w !== exp_res || fflags_w !== exp_flags) begin
            errors++;
            $display("FAIL %-22s: in=%08h res=%08h(exp %08h) flags=%05b(exp %05b)",
                     lbl, din, result_w, exp_res, fflags_w, exp_flags);
        end
    endtask

    initial begin : body
        // ---- FCVT.W.S : float -> signed int, round-to-nearest-even ----
        chk(FPU_CVT_W_S, FRM_RNE, 32'h4000_0000, 32'd2,          5'b00000, "2.0 -> 2");
        chk(FPU_CVT_W_S, FRM_RNE, 32'hC000_0000, -32'sd2,        5'b00000, "-2.0 -> -2");
        chk(FPU_CVT_W_S, FRM_RNE, 32'h4049_0FDB, 32'd3,          5'b00001, "3.14159 -> 3 NX");
        chk(FPU_CVT_W_S, FRM_RNE, 32'h3F00_0000, 32'd0,          5'b00001, "0.5 -> 0 (even) NX");
        chk(FPU_CVT_W_S, FRM_RNE, 32'h3FC0_0000, 32'd2,          5'b00001, "1.5 -> 2 (even) NX");
        chk(FPU_CVT_W_S, FRM_RNE, 32'h4020_0000, 32'd2,          5'b00001, "2.5 -> 2 (even) NX");
        chk(FPU_CVT_W_S, FRM_RNE, 32'h0000_0000, 32'd0,          5'b00000, "+0 -> 0");
        chk(FPU_CVT_W_S, FRM_RNE, 32'h8000_0000, 32'd0,          5'b00000, "-0 -> 0");
        // Boundaries / specials
        chk(FPU_CVT_W_S, FRM_RNE, 32'h4F00_0000, 32'h7FFF_FFFF,  5'b10000, "2^31 -> INT_MAX NV");
        chk(FPU_CVT_W_S, FRM_RNE, 32'hCF00_0000, 32'h8000_0000,  5'b00000, "-2^31 -> INT_MIN exact");
        chk(FPU_CVT_W_S, FRM_RNE, 32'h7F80_0000, 32'h7FFF_FFFF,  5'b10000, "+inf -> INT_MAX NV");
        chk(FPU_CVT_W_S, FRM_RNE, 32'hFF80_0000, 32'h8000_0000,  5'b10000, "-inf -> INT_MIN NV");
        chk(FPU_CVT_W_S, FRM_RNE, 32'h7FC0_0000, 32'h7FFF_FFFF,  5'b10000, "qNaN -> INT_MAX NV");

        // ---- Rounding-mode matrix on +/-2.5 (signed) ----
        chk(FPU_CVT_W_S, FRM_RTZ, 32'h4020_0000, 32'd2,   5'b00001, "RTZ 2.5 -> 2");
        chk(FPU_CVT_W_S, FRM_RDN, 32'h4020_0000, 32'd2,   5'b00001, "RDN 2.5 -> 2");
        chk(FPU_CVT_W_S, FRM_RUP, 32'h4020_0000, 32'd3,   5'b00001, "RUP 2.5 -> 3");
        chk(FPU_CVT_W_S, FRM_RMM, 32'h4020_0000, 32'd3,   5'b00001, "RMM 2.5 -> 3");
        chk(FPU_CVT_W_S, FRM_RTZ, 32'hC020_0000, -32'sd2, 5'b00001, "RTZ -2.5 -> -2");
        chk(FPU_CVT_W_S, FRM_RDN, 32'hC020_0000, -32'sd3, 5'b00001, "RDN -2.5 -> -3");
        chk(FPU_CVT_W_S, FRM_RUP, 32'hC020_0000, -32'sd2, 5'b00001, "RUP -2.5 -> -2");
        chk(FPU_CVT_W_S, FRM_RMM, 32'hC020_0000, -32'sd3, 5'b00001, "RMM -2.5 -> -3");

        // ---- FCVT.WU.S : float -> unsigned int ----
        chk(FPU_CVT_WU_S, FRM_RNE, 32'h4049_0FDB, 32'd3,         5'b00001, "u 3.14 -> 3 NX");
        chk(FPU_CVT_WU_S, FRM_RNE, 32'h4F00_0000, 32'h8000_0000, 5'b00000, "u 2^31 -> 2147483648 exact");
        chk(FPU_CVT_WU_S, FRM_RNE, 32'hBF80_0000, 32'h0000_0000, 5'b10000, "u -1.0 -> 0 NV");
        chk(FPU_CVT_WU_S, FRM_RNE, 32'hBE80_0000, 32'h0000_0000, 5'b00001, "u -0.25 -> 0 NX");
        chk(FPU_CVT_WU_S, FRM_RNE, 32'h7FC0_0000, 32'hFFFF_FFFF, 5'b10000, "u qNaN -> UMAX NV");
        chk(FPU_CVT_WU_S, FRM_RNE, 32'h7F80_0000, 32'hFFFF_FFFF, 5'b10000, "u +inf -> UMAX NV");
        // 2^32 exactly (0x4F800000) overflows unsigned:
        chk(FPU_CVT_WU_S, FRM_RNE, 32'h4F80_0000, 32'hFFFF_FFFF, 5'b10000, "u 2^32 -> UMAX NV");

        // ---- FCVT.S.W : signed int -> float ----
        chk(FPU_CVT_S_W, FRM_RNE, 32'd0,          32'h0000_0000, 5'b00000, "i 0 -> +0");
        chk(FPU_CVT_S_W, FRM_RNE, 32'd1,          32'h3F80_0000, 5'b00000, "i 1 -> 1.0");
        chk(FPU_CVT_S_W, FRM_RNE, -32'sd1,        32'hBF80_0000, 5'b00000, "i -1 -> -1.0");
        chk(FPU_CVT_S_W, FRM_RNE, 32'd2,          32'h4000_0000, 5'b00000, "i 2 -> 2.0");
        chk(FPU_CVT_S_W, FRM_RNE, 32'h7FFF_FFFF,  32'h4F00_0000, 5'b00001, "i INT_MAX -> 2^31f NX");
        chk(FPU_CVT_S_W, FRM_RNE, 32'h8000_0000,  32'hCF00_0000, 5'b00000, "i INT_MIN -> -2^31f");

        // ---- FCVT.S.WU : unsigned int -> float ----
        chk(FPU_CVT_S_WU, FRM_RNE, 32'd0,         32'h0000_0000, 5'b00000, "u 0 -> +0");
        chk(FPU_CVT_S_WU, FRM_RNE, 32'h8000_0000, 32'h4F00_0000, 5'b00000, "u 2^31 -> 2^31f exact");
        chk(FPU_CVT_S_WU, FRM_RNE, 32'hFFFF_FFFF, 32'h4F80_0000, 5'b00001, "u UMAX -> 2^32f NX");

        if (errors == 0)
            $display("[FP-CVT-TEST] PASS: all conversion vectors verified.");
        else
            $fatal(1, "[FP-CVT-TEST] FAIL: %0d mismatches", errors);
        $finish;
    end : body

endmodule : tb_fp_cvt

`default_nettype wire
