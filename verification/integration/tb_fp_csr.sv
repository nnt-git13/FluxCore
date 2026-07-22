// verification/integration/tb_fp_csr.sv
//
// End-to-end RV32F fcsr test through fluxcore_top: an FDIV by zero accrues the
// divide-by-zero (DZ) flag into fcsr.fflags, and executing an FP op sets
// mstatus.FS to Dirty (SD). Reads fflags / fcsr / mstatus back with CSR
// instructions and checks the integer results.
//
// This also exercises the fcsr flag-accrual interlock: the csrrs that reads
// fflags sits immediately after the fdiv (no NOP gap), and the forwarding unit
// must stall it until the DZ flag is committed at the fdiv's WB.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_fp_csr;

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

    always_comb begin
        case (imem_addr)
            32'h00: imem_rdata = 32'h000020B7; // lui   x1, 0x2
            32'h04: imem_rdata = 32'h3000A073; // csrrs x0, mstatus, x1   (enable FP)
            32'h08: imem_rdata = 32'h00000013; // nop
            32'h0C: imem_rdata = 32'h00000013; // nop
            32'h10: imem_rdata = 32'h00000013; // nop
            32'h14: imem_rdata = 32'h3F800237; // lui   x4, 0x3F800      (1.0 bits)
            32'h18: imem_rdata = 32'hF00200D3; // fmv.w.x f1, x4         (f1=1.0)
            32'h1C: imem_rdata = 32'hF0000153; // fmv.w.x f2, x0         (f2=0.0)
            32'h20: imem_rdata = 32'h182081D3; // fdiv.s  f3, f1, f2     (1/0=inf, DZ)
            // csrrs fflags IMMEDIATELY after the fdiv — the fcsr flag-accrual
            // interlock (forwarding_unit) must stall this read until the DZ flag
            // is committed at the fdiv's WB. No NOP gap here on purpose.
            32'h24: imem_rdata = 32'h00102573; // csrrs x10, fflags, x0  (x10 = fflags)
            32'h28: imem_rdata = 32'hE00185D3; // fmv.x.w x11, f3        (x11 = inf bits)
            32'h2C: imem_rdata = 32'h00302673; // csrrs x12, fcsr, x0    (x12 = fcsr)
            32'h30: imem_rdata = 32'h300026F3; // csrrs x13, mstatus, x0 (x13 = mstatus)
            default: imem_rdata = 32'h00000013; // nop
        endcase
    end

    always_ff @(posedge clk)
        if (!rst && exc.valid)
            $fatal(1, "[FP-CSR] FAIL unexpected exception: cause=%0d pc=%08h",
                   int'(exc.cause), exc_pc);

    int errors = 0;
    task automatic chk_x(input int i, input word_t exp, input string lbl);
        if (dut.u_regfile.regs[i] !== exp) begin
            errors++;
            $display("FAIL %-16s: x%0d=%08h exp=%08h", lbl, i, dut.u_regfile.regs[i], exp);
        end
    endtask

    initial begin : stim
        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;
        repeat (80) @(posedge clk);
        #1;

        chk_x(10, 32'h0000_0008, "fflags = DZ");
        chk_x(11, 32'h7F80_0000, "fdiv 1/0 = +inf");
        chk_x(12, 32'h0000_0008, "fcsr = {frm=0, DZ}");
        // mstatus: FS=Dirty (11) at [14:13] → 0x6000, MPP 0x1800, SD bit31.
        if ((dut.u_regfile.regs[13] & 32'h8000_6000) !== 32'h8000_6000) begin
            errors++;
            $display("FAIL mstatus FS/SD: x13=%08h", dut.u_regfile.regs[13]);
        end

        if (errors == 0)
            $display("[FP-CSR] PASS: fcsr fflags accrual + mstatus.FS dirty verified.");
        else
            $fatal(1, "[FP-CSR] FAIL: %0d mismatches", errors);
        $finish;
    end : stim

endmodule : tb_fp_csr

`default_nettype wire
