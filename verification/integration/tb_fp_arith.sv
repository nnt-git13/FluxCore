// verification/integration/tb_fp_arith.sv
//
// End-to-end RV32F integration test through fluxcore_top: enables FP via
// mstatus.FS, loads operands with FMV.W.X, then exercises FADD/FMUL/FSUB,
// compares (FEQ/FLT), conversions (FCVT.W.S / FCVT.S.W), FMV.X.W, FSGNJN, and
// FMIN — verifying both the FP register file and the integer register file,
// and exercising FP operand forwarding (dependent ops are adjacent).
//
// Results are checked by peeking the architectural register arrays after the
// program drains (integer dut.u_regfile.regs[], FP dut.u_fp_regfile.fregs[]).

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_fp_arith;

    logic clk = 0;
    logic rst = 1;
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

    // Instruction ROM
    always_comb begin
        case (imem_addr)
            32'h00: imem_rdata = 32'h000020B7; // lui   x1, 0x2         (x1=0x2000)
            32'h04: imem_rdata = 32'h3000A073; // csrrs x0, mstatus, x1 (enable FP: FS=Initial)
            32'h08: imem_rdata = 32'h00000013; // nop
            32'h0C: imem_rdata = 32'h00000013; // nop
            32'h10: imem_rdata = 32'h00000013; // nop
            32'h14: imem_rdata = 32'h40000137; // lui   x2, 0x40000     (2.0f bits)
            32'h18: imem_rdata = 32'h404001B7; // lui   x3, 0x40400     (3.0f bits)
            32'h1C: imem_rdata = 32'h00500713; // addi  x14, x0, 5
            32'h20: imem_rdata = 32'hF00100D3; // fmv.w.x f1, x2        (f1=2.0)
            32'h24: imem_rdata = 32'hF0018153; // fmv.w.x f2, x3        (f2=3.0)
            32'h28: imem_rdata = 32'h00208253; // fadd.s  f4, f1, f2    (f4=5.0)
            32'h2C: imem_rdata = 32'h10208353; // fmul.s  f6, f1, f2    (f6=6.0)
            32'h30: imem_rdata = 32'h08110453; // fsub.s  f8, f2, f1    (f8=1.0)
            32'h34: imem_rdata = 32'hA010A553; // feq.s   x10, f1, f1   (x10=1)
            32'h38: imem_rdata = 32'hA02095D3; // flt.s   x11, f1, f2   (x11=1)
            32'h3C: imem_rdata = 32'hC0010653; // fcvt.w.s x12, f2      (x12=3)
            32'h40: imem_rdata = 32'hD00706D3; // fcvt.s.w f13, x14     (f13=5.0)
            32'h44: imem_rdata = 32'hE0068853; // fmv.x.w x16, f13      (x16=0x40A00000)
            32'h48: imem_rdata = 32'h20209953; // fsgnjn.s f18, f1, f2  (f18=-2.0)
            32'h4C: imem_rdata = 32'h282089D3; // fmin.s  f19, f1, f2   (f19=2.0)
            default: imem_rdata = 32'h00000013; // nop
        endcase
    end

    // No unexpected traps
    always_ff @(posedge clk)
        if (!rst && exc.valid)
            $fatal(1, "[FP-ARITH] FAIL unexpected exception: cause=%0d pc=%08h",
                   int'(exc.cause), exc_pc);

    int errors = 0;
    task automatic chk_x(input int i, input word_t exp, input string lbl);
        if (dut.u_regfile.regs[i] !== exp) begin
            errors++;
            $display("FAIL %-14s: x%0d=%08h exp=%08h", lbl, i, dut.u_regfile.regs[i], exp);
        end
    endtask
    task automatic chk_f(input int i, input word_t exp, input string lbl);
        if (dut.u_fp_regfile.fregs[i] !== exp) begin
            errors++;
            $display("FAIL %-14s: f%0d=%08h exp=%08h", lbl, i, dut.u_fp_regfile.fregs[i], exp);
        end
    endtask

    initial begin : stim
        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;
        repeat (60) @(posedge clk);
        #1;

        // integer results
        chk_x(1,  32'h0000_2000, "x1 mstatus bit");
        chk_x(2,  32'h4000_0000, "x2 2.0 bits");
        chk_x(10, 32'h0000_0001, "feq x10");
        chk_x(11, 32'h0000_0001, "flt x11");
        chk_x(12, 32'h0000_0003, "fcvt.w.s x12");
        chk_x(14, 32'h0000_0005, "addi x14");
        chk_x(16, 32'h40A0_0000, "fmv.x.w x16");
        // FP results
        chk_f(1,  32'h4000_0000, "f1 = 2.0");
        chk_f(2,  32'h4040_0000, "f2 = 3.0");
        chk_f(4,  32'h40A0_0000, "fadd f4 = 5.0");
        chk_f(6,  32'h40C0_0000, "fmul f6 = 6.0");
        chk_f(8,  32'h3F80_0000, "fsub f8 = 1.0");
        chk_f(13, 32'h40A0_0000, "fcvt.s.w f13 = 5.0");
        chk_f(18, 32'hC000_0000, "fsgnjn f18 = -2.0");
        chk_f(19, 32'h4000_0000, "fmin f19 = 2.0");

        if (errors == 0)
            $display("[FP-ARITH] PASS: RV32F end-to-end arithmetic verified.");
        else
            $fatal(1, "[FP-ARITH] FAIL: %0d mismatches", errors);
        $finish;
    end : stim

endmodule : tb_fp_arith

`default_nettype wire
