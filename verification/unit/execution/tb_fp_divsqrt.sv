// verification/unit/execution/tb_fp_divsqrt.sv
//
// Clocked self-checking testbench for rtl/execution/fp/fp_divsqrt.sv.
// Drives the start/busy handshake, waits for completion, and checks the result
// and IEEE flags against hand-verified IEEE-754 values: exact and inexact
// divides, divide-by-zero (DZ), inf/zero/NaN cases, perfect and inexact square
// roots, and sqrt of a negative (NV).
//
// fflags: [4]=NV [3]=DZ [2]=OF [1]=UF [0]=NX.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;

module tb_fp_divsqrt;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    word_t      a_w, b_w;
    fpu_op_e    op_w;
    logic [2:0] rm_w;
    logic       start_w;
    word_t      result_w;
    logic [4:0] fflags_w;
    logic       busy_w, idle_w;

    fp_divsqrt dut (
        .clk(clk), .rst(rst), .a_i(a_w), .b_i(b_w), .op_i(op_w), .rm_i(rm_w),
        .start_i(start_w), .result_o(result_w), .fflags_o(fflags_w),
        .busy_o(busy_w), .idle_o(idle_w)
    );

    int errors = 0;

    task automatic run(input fpu_op_e op, input word_t a, input word_t b, input logic [2:0] rm,
                       input word_t exp_res, input logic [4:0] exp_flags, input string lbl);
        @(negedge clk);
        a_w=a; b_w=b; op_w=op; rm_w=rm; start_w=1'b1;
        @(negedge clk); start_w=1'b0;
        // wait for completion
        while (busy_w) @(negedge clk);
        #1;
        if (result_w !== exp_res || fflags_w !== exp_flags) begin
            errors++;
            $display("FAIL %-20s: res=%08h(exp %08h) fl=%05b(exp %05b)",
                     lbl, result_w, exp_res, fflags_w, exp_flags);
        end
    endtask

    initial begin : body
        start_w = 1'b0; a_w='0; b_w='0; op_w=FPU_DIV; rm_w=FRM_RNE;
        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;

        // ---- divide ----
        run(FPU_DIV, 32'h40C0_0000, 32'h4000_0000, FRM_RNE, 32'h4040_0000, 5'b00000, "6/2=3");
        run(FPU_DIV, 32'h3F80_0000, 32'h4000_0000, FRM_RNE, 32'h3F00_0000, 5'b00000, "1/2=0.5");
        run(FPU_DIV, 32'h4040_0000, 32'h4000_0000, FRM_RNE, 32'h3FC0_0000, 5'b00000, "3/2=1.5");
        run(FPU_DIV, 32'h3F80_0000, 32'h4040_0000, FRM_RNE, 32'h3EAA_AAAB, 5'b00001, "1/3 NX");
        run(FPU_DIV, 32'h3F80_0000, 32'h0000_0000, FRM_RNE, 32'h7F80_0000, 5'b01000, "1/0=inf DZ");
        run(FPU_DIV, 32'hBF80_0000, 32'h0000_0000, FRM_RNE, 32'hFF80_0000, 5'b01000, "-1/0=-inf DZ");
        run(FPU_DIV, 32'h0000_0000, 32'h40A0_0000, FRM_RNE, 32'h0000_0000, 5'b00000, "0/5=0");
        run(FPU_DIV, 32'h7F80_0000, 32'h4000_0000, FRM_RNE, 32'h7F80_0000, 5'b00000, "inf/2=inf");
        run(FPU_DIV, 32'h4000_0000, 32'h7F80_0000, FRM_RNE, 32'h0000_0000, 5'b00000, "2/inf=0");
        run(FPU_DIV, 32'h7F80_0000, 32'h7F80_0000, FRM_RNE, 32'h7FC0_0000, 5'b10000, "inf/inf=NV");
        run(FPU_DIV, 32'h0000_0000, 32'h0000_0000, FRM_RNE, 32'h7FC0_0000, 5'b10000, "0/0=NV");
        run(FPU_DIV, 32'h7FC0_0000, 32'h4000_0000, FRM_RNE, 32'h7FC0_0000, 5'b00000, "qNaN/2=qNaN");

        // ---- sqrt ----
        run(FPU_SQRT, 32'h4080_0000, 32'h0, FRM_RNE, 32'h4000_0000, 5'b00000, "sqrt(4)=2");
        run(FPU_SQRT, 32'h3F80_0000, 32'h0, FRM_RNE, 32'h3F80_0000, 5'b00000, "sqrt(1)=1");
        run(FPU_SQRT, 32'h4110_0000, 32'h0, FRM_RNE, 32'h4040_0000, 5'b00000, "sqrt(9)=3");
        run(FPU_SQRT, 32'h3E80_0000, 32'h0, FRM_RNE, 32'h3F00_0000, 5'b00000, "sqrt(0.25)=0.5");
        run(FPU_SQRT, 32'h4000_0000, 32'h0, FRM_RNE, 32'h3FB5_04F3, 5'b00001, "sqrt(2) NX");
        run(FPU_SQRT, 32'h0000_0000, 32'h0, FRM_RNE, 32'h0000_0000, 5'b00000, "sqrt(+0)=+0");
        run(FPU_SQRT, 32'h8000_0000, 32'h0, FRM_RNE, 32'h8000_0000, 5'b00000, "sqrt(-0)=-0");
        run(FPU_SQRT, 32'hBF80_0000, 32'h0, FRM_RNE, 32'h7FC0_0000, 5'b10000, "sqrt(-1)=NV");
        run(FPU_SQRT, 32'h7F80_0000, 32'h0, FRM_RNE, 32'h7F80_0000, 5'b00000, "sqrt(inf)=inf");

        if (errors == 0)
            $display("[FP-DIVSQRT-TEST] PASS: all divide/sqrt vectors verified.");
        else
            $fatal(1, "[FP-DIVSQRT-TEST] FAIL: %0d mismatches", errors);
        $finish;
    end : body

endmodule : tb_fp_divsqrt

`default_nettype wire
