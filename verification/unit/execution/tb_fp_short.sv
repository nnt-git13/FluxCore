// verification/unit/execution/tb_fp_short.sv
//
// Directed self-checking testbench for rtl/execution/fp/fp_short.sv, which
// aggregates the single-cycle FP ops: FSGNJ[N/X], FMIN/FMAX, FEQ/FLT/FLE,
// FCLASS, FMV.X.W, FMV.W.X. (Conversions are covered by tb_fp_cvt.)
//
// Special-value coverage: quiet/signaling NaN, +/-inf, +/-0, subnormals.
// fflags layout: [4]=NV [3]=DZ [2]=OF [1]=UF [0]=NX.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;

module tb_fp_short;

    word_t      fa_w, fb_w, xrs1_w;
    fpu_op_e    op_w;
    logic [2:0] rm_w = 3'b000;
    word_t      result_w;
    logic [4:0] fflags_w;

    fp_short dut (
        .fa_i(fa_w), .fb_i(fb_w), .xrs1_i(xrs1_w), .op_i(op_w), .rm_i(rm_w),
        .result_o(result_w), .fflags_o(fflags_w)
    );

    int errors = 0;

    task automatic chk(
        input fpu_op_e   op,
        input word_t     fa, fb, xrs1,
        input word_t     exp_res,
        input logic [4:0] exp_flags,
        input string     lbl
    );
        fa_w = fa; fb_w = fb; xrs1_w = xrs1; op_w = op;
        #1;
        if (result_w !== exp_res || fflags_w !== exp_flags) begin
            errors++;
            $display("FAIL %-20s: res=%08h(exp %08h) flags=%05b(exp %05b)",
                     lbl, result_w, exp_res, fflags_w, exp_flags);
        end
    endtask

    // Common bit patterns
    localparam word_t P1  = 32'h3F80_0000;   //  1.0
    localparam word_t N1  = 32'hBF80_0000;   // -1.0
    localparam word_t P2  = 32'h4000_0000;   //  2.0
    localparam word_t N2  = 32'hC000_0000;   // -2.0
    localparam word_t P3  = 32'h4040_0000;   //  3.0
    localparam word_t PZ  = 32'h0000_0000;   // +0
    localparam word_t NZ  = 32'h8000_0000;   // -0
    localparam word_t PINF= 32'h7F80_0000;
    localparam word_t NINF= 32'hFF80_0000;
    localparam word_t QNAN= 32'h7FC0_0000;
    localparam word_t SNAN= 32'h7F80_0001;
    localparam word_t PSUB= 32'h0000_0001;   // +subnormal
    localparam word_t NSUB= 32'h8000_0001;   // -subnormal
    localparam word_t NV  = 5'b10000;
    localparam word_t Z   = 5'b00000;

    initial begin : body
        // ---- FSGNJ / FSGNJN / FSGNJX ----
        chk(FPU_SGNJ,  P1, N2, PZ, N1,           Z, "FSGNJ 1,-2 -> -1");
        chk(FPU_SGNJN, P1, N2, PZ, P1,           Z, "FSGNJN 1,-2 -> 1");
        chk(FPU_SGNJX, N1, N2, PZ, P1,           Z, "FSGNJX -1,-2 -> 1");
        chk(FPU_SGNJ,  QNAN, NZ, PZ, 32'hFFC0_0000, Z, "FSGNJ qNaN,-0 (bit-copy)");

        // ---- FMIN / FMAX ----
        chk(FPU_MIN, P2, P3, PZ, P2,             Z, "FMIN 2,3 -> 2");
        chk(FPU_MAX, P2, P3, PZ, P3,             Z, "FMAX 2,3 -> 3");
        chk(FPU_MIN, NZ, PZ, PZ, NZ,             Z, "FMIN -0,+0 -> -0");
        chk(FPU_MAX, NZ, PZ, PZ, PZ,             Z, "FMAX -0,+0 -> +0");
        chk(FPU_MIN, P1, QNAN, PZ, P1,           Z, "FMIN 1,qNaN -> 1");
        chk(FPU_MIN, P1, SNAN, PZ, P1,          NV, "FMIN 1,sNaN -> 1 NV");
        chk(FPU_MAX, QNAN, QNAN, PZ, QNAN,       Z, "FMAX qNaN,qNaN -> qNaN");
        chk(FPU_MIN, N1, P1, PZ, N1,             Z, "FMIN -1,1 -> -1");

        // ---- FEQ / FLT / FLE ----
        chk(FPU_EQ, P1, P1, PZ, 32'd1,           Z, "FEQ 1,1 -> 1");
        chk(FPU_EQ, P1, P2, PZ, 32'd0,           Z, "FEQ 1,2 -> 0");
        chk(FPU_EQ, PZ, NZ, PZ, 32'd1,           Z, "FEQ +0,-0 -> 1");
        chk(FPU_LT, P1, P2, PZ, 32'd1,           Z, "FLT 1,2 -> 1");
        chk(FPU_LT, P2, P1, PZ, 32'd0,           Z, "FLT 2,1 -> 0");
        chk(FPU_LE, P1, P1, PZ, 32'd1,           Z, "FLE 1,1 -> 1");
        chk(FPU_LT, N2, N1, PZ, 32'd1,           Z, "FLT -2,-1 -> 1");
        chk(FPU_LT, N1, P1, PZ, 32'd1,           Z, "FLT -1,1 -> 1");
        chk(FPU_LT, P1, QNAN, PZ, 32'd0,        NV, "FLT 1,qNaN -> 0 NV");
        chk(FPU_EQ, P1, QNAN, PZ, 32'd0,         Z, "FEQ 1,qNaN -> 0 (quiet)");
        chk(FPU_EQ, P1, SNAN, PZ, 32'd0,        NV, "FEQ 1,sNaN -> 0 NV");

        // ---- FCLASS ----
        chk(FPU_CLASS, NINF, PZ, PZ, 32'h001,    Z, "FCLASS -inf");
        chk(FPU_CLASS, N1,   PZ, PZ, 32'h002,    Z, "FCLASS -normal");
        chk(FPU_CLASS, NSUB, PZ, PZ, 32'h004,    Z, "FCLASS -subnormal");
        chk(FPU_CLASS, NZ,   PZ, PZ, 32'h008,    Z, "FCLASS -0");
        chk(FPU_CLASS, PZ,   PZ, PZ, 32'h010,    Z, "FCLASS +0");
        chk(FPU_CLASS, PSUB, PZ, PZ, 32'h020,    Z, "FCLASS +subnormal");
        chk(FPU_CLASS, P1,   PZ, PZ, 32'h040,    Z, "FCLASS +normal");
        chk(FPU_CLASS, PINF, PZ, PZ, 32'h080,    Z, "FCLASS +inf");
        chk(FPU_CLASS, SNAN, PZ, PZ, 32'h100,    Z, "FCLASS sNaN");
        chk(FPU_CLASS, QNAN, PZ, PZ, 32'h200,    Z, "FCLASS qNaN");

        // ---- FMV.X.W / FMV.W.X (raw bit moves) ----
        chk(FPU_MV_X_W, P1,   PZ, PZ,         P1,          Z, "FMV.X.W copies fp bits");
        chk(FPU_MV_W_X, PZ,   PZ, 32'hDEAD_BEEF, 32'hDEAD_BEEF, Z, "FMV.W.X copies int bits");

        if (errors == 0)
            $display("[FP-SHORT-TEST] PASS: all single-cycle FP ops verified.");
        else
            $fatal(1, "[FP-SHORT-TEST] FAIL: %0d mismatches", errors);
        $finish;
    end : body

endmodule : tb_fp_short

`default_nettype wire
