// verification/integration/tb_fp_muldiv.sv
//
// End-to-end RV32F test through fluxcore_top for the fused multiply-add and the
// iterative divide / square root. Verifies FMADD/FMSUB, FDIV.S and FSQRT.S run
// correctly through the pipeline, including the fpu_stall freeze during the
// multi-cycle div/sqrt (instructions behind them stall, then resume).

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_fp_muldiv;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    word_t             imem_addr, imem_addr_next;
    instr_t            imem_rdata;
    word_t             dmem_addr;
    logic              dmem_ren, dmem_wen;
    logic [3:0]        dmem_wstrb;
    word_t             dmem_wdata;
    word_t             dmem_rdata = '0;
    retirement_event_t retire;
    exception_meta_t   exc;
    word_t             exc_pc;

    fluxcore_top dut (
        .clk(clk), .rst(rst),
        .imem_addr_o(imem_addr), .imem_addr_next_o(imem_addr_next), .imem_rdata_i(imem_rdata),
        .dmem_addr_o(dmem_addr), .dmem_ren_o(dmem_ren), .dmem_wen_o(dmem_wen),
        .dmem_wstrb_o(dmem_wstrb), .dmem_wdata_o(dmem_wdata), .dmem_rdata_i(dmem_rdata),
        .dmem_stall_i(1'b0),
        .retire_o(retire), .exception_o(exc), .exception_pc_o(exc_pc)
    );

    // f1=2.0, f2=3.0, f3=4.0 loaded via FMV.W.X; then FMADD/FMSUB/FDIV/FSQRT.
    always_comb begin
        case (imem_addr)
            32'h00: imem_rdata = 32'h000020B7; // lui   x1, 0x2
            32'h04: imem_rdata = 32'h3000A073; // csrrs x0, mstatus, x1  (enable FP)
            32'h08: imem_rdata = 32'h00000013; // nop
            32'h0C: imem_rdata = 32'h00000013; // nop
            32'h10: imem_rdata = 32'h00000013; // nop
            32'h14: imem_rdata = 32'h40000137; // lui   x2, 0x40000     (2.0)
            32'h18: imem_rdata = 32'h404001B7; // lui   x3, 0x40400     (3.0)
            32'h1C: imem_rdata = 32'h40800237; // lui   x4, 0x40800     (4.0)
            32'h20: imem_rdata = 32'hF00100D3; // fmv.w.x f1, x2        (f1=2.0)
            32'h24: imem_rdata = 32'hF0018153; // fmv.w.x f2, x3        (f2=3.0)
            32'h28: imem_rdata = 32'hF00201D3; // fmv.w.x f3, x4        (f3=4.0)
            // fmadd.s f5, f1, f2, f3 = 2*3+4 = 10.0   (rs3=f3, fmt=00, rm=000)
            32'h2C: imem_rdata = 32'h182082C3; // fmadd.s f5, f1, f2, f3
            // fmsub.s f6, f1, f2, f3 = 2*3-4 = 2.0
            32'h30: imem_rdata = 32'h18208347; // fmsub.s f6, f1, f2, f3
            // fdiv.s f7, f3, f1 = 4/2 = 2.0
            32'h34: imem_rdata = 32'h181183D3; // fdiv.s f7, f3, f1
            // fsqrt.s f8, f3 = sqrt(4) = 2.0
            32'h38: imem_rdata = 32'h58018453; // fsqrt.s f8, f3
            default: imem_rdata = 32'h00000013; // nop
        endcase
    end

    always_ff @(posedge clk)
        if (!rst && exc.valid)
            $fatal(1, "[FP-MULDIV] FAIL unexpected exception: cause=%0d pc=%08h",
                   int'(exc.cause), exc_pc);

    int errors = 0;
    task automatic chk_f(input int i, input word_t exp, input string lbl);
        if (dut.u_fp_regfile.fregs[i] !== exp) begin
            errors++;
            $display("FAIL %-14s: f%0d=%08h exp=%08h", lbl, i, dut.u_fp_regfile.fregs[i], exp);
        end
    endtask

    initial begin : stim
        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;
        repeat (120) @(posedge clk);   // budget covers two ~28-cycle div/sqrt stalls
        #1;

        chk_f(1, 32'h4000_0000, "f1 = 2.0");
        chk_f(3, 32'h4080_0000, "f3 = 4.0");
        chk_f(5, 32'h4120_0000, "fmadd = 10.0");
        chk_f(6, 32'h4000_0000, "fmsub = 2.0");
        chk_f(7, 32'h4000_0000, "fdiv 4/2 = 2.0");
        chk_f(8, 32'h4000_0000, "fsqrt(4) = 2.0");

        if (errors == 0)
            $display("[FP-MULDIV] PASS: FMA + iterative divide/sqrt verified end-to-end.");
        else
            $fatal(1, "[FP-MULDIV] FAIL: %0d mismatches", errors);
        $finish;
    end : stim

endmodule : tb_fp_muldiv

`default_nettype wire
