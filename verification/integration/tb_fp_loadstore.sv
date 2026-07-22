// verification/integration/tb_fp_loadstore.sv
//
// End-to-end RV32F load/store test through fluxcore_top: FSW writes an FP
// value to data memory and FLW reads it back, with FMV.X.W right after the load
// (exercising the FP load-use stall). The data memory uses a registered read
// (BRAM 1-cycle latency), matching tb_lw_sw, so the load word lands in WB.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_fp_loadstore;

    logic clk = 0;
    logic rst = 1;
    always #5 clk = ~clk;

    word_t             imem_addr, imem_addr_next;
    instr_t            imem_rdata;
    word_t             dmem_addr;
    logic              dmem_ren, dmem_wen;
    logic [3:0]        dmem_wstrb;
    word_t             dmem_wdata;
    word_t             dmem_rdata;
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
            32'h04: imem_rdata = 32'h3000A073; // csrrs x0, mstatus, x1  (enable FP)
            32'h08: imem_rdata = 32'h00000013; // nop
            32'h0C: imem_rdata = 32'h00000013; // nop
            32'h10: imem_rdata = 32'h00000013; // nop
            32'h14: imem_rdata = 32'h02000113; // addi  x2, x0, 0x20     (address)
            32'h18: imem_rdata = 32'h400001B7; // lui   x3, 0x40000      (2.0f bits)
            32'h1C: imem_rdata = 32'hF00180D3; // fmv.w.x f1, x3         (f1=2.0)
            32'h20: imem_rdata = 32'h00112027; // fsw   f1, 0(x2)        (mem[0x20]=2.0)
            32'h24: imem_rdata = 32'h00012107; // flw   f2, 0(x2)        (f2=mem[0x20])
            32'h28: imem_rdata = 32'hE00102D3; // fmv.x.w x5, f2         (x5=0x40000000)
            default: imem_rdata = 32'h00000013; // nop
        endcase
    end

    // Data memory: 256 words, registered read (1-cycle BRAM latency).
    word_t dmem [0:255];
    initial foreach (dmem[i]) dmem[i] = '0;
    always_ff @(posedge clk) begin
        if (dmem_wen) begin
            if (dmem_wstrb[0]) dmem[dmem_addr[9:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_wstrb[1]) dmem[dmem_addr[9:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_wstrb[2]) dmem[dmem_addr[9:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) dmem[dmem_addr[9:2]][31:24] <= dmem_wdata[31:24];
        end
        dmem_rdata <= dmem[dmem_addr[9:2]];
    end

    always_ff @(posedge clk)
        if (!rst && exc.valid)
            $fatal(1, "[FP-LDST] FAIL unexpected exception: cause=%0d pc=%08h",
                   int'(exc.cause), exc_pc);

    int errors = 0;
    task automatic chk_x(input int i, input word_t exp, input string lbl);
        if (dut.u_regfile.regs[i] !== exp) begin
            errors++;
            $display("FAIL %-16s: x%0d=%08h exp=%08h", lbl, i, dut.u_regfile.regs[i], exp);
        end
    endtask
    task automatic chk_f(input int i, input word_t exp, input string lbl);
        if (dut.u_fp_regfile.fregs[i] !== exp) begin
            errors++;
            $display("FAIL %-16s: f%0d=%08h exp=%08h", lbl, i, dut.u_fp_regfile.fregs[i], exp);
        end
    endtask

    initial begin : stim
        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;
        repeat (40) @(posedge clk);
        #1;

        chk_f(1, 32'h4000_0000, "f1 = 2.0");
        chk_f(2, 32'h4000_0000, "f2 = FLW result");
        chk_x(5, 32'h4000_0000, "x5 = fmv.x.w f2");
        if (dmem[8] !== 32'h4000_0000) begin
            errors++;
            $display("FAIL dmem[0x20]=%08h exp=40000000", dmem[8]);
        end

        if (errors == 0)
            $display("[FP-LDST] PASS: FSW/FLW round-trip verified.");
        else
            $fatal(1, "[FP-LDST] FAIL: %0d mismatches", errors);
        $finish;
    end : stim

endmodule : tb_fp_loadstore

`default_nettype wire
