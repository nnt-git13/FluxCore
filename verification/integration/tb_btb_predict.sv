// verification/integration/tb_btb_predict.sv
//
// Branch-prediction integration test: an 8-iteration counted loop.
//
//   0x00  ADDI x1, x0, 8        loop counter
//   0x04  ADDI x2, x0, 0        sum
//   0x08  ADDI x2, x2, 1        loop body
//   0x0C  ADDI x1, x1, -1
//   0x10  BNE  x1, x0, -8      -> 0x08; taken 7x, not-taken on exit
//   0x14  ADDI x3, x0, 55       post-loop marker
//
// With static not-taken, each taken BNE costs a 2-cycle flush: 14 penalty
// cycles. With the BTB: iteration 1 mispredicts (cold, allocates),
// iterations 2..7 are predicted taken with the right target (zero penalty),
// and the exit iteration predicts taken but resolves not-taken — the
// pred_wrong_pc4 recovery redirects to 0x14 (2 cycles). Net: 4 penalty
// cycles instead of 14.
//
// Checks:
//   B1. Architectural correctness through every prediction path:
//       x2 = 8, x3 = 55 (the exit recovery is the risky one).
//   B2. Exactly 8 BNE retirements (no double-retire on redirects).
//   B3. The run completes measurably faster than the static-not-taken
//       bound (last retirement before cycle 42; static needs ~46).
//   B4. No exceptions.

`timescale 1ns/1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_btb_predict;

    logic clk = 0;
    logic rst = 1;
    always #5 clk = ~clk;

    word_t             imem_addr, imem_addr_next;
    instr_t            imem_rdata;
    word_t             dmem_addr, dmem_wdata;
    word_t             dmem_rdata = '0;
    logic              dmem_wen, dmem_ren;
    logic [3:0]        dmem_wstrb;
    retirement_event_t retire;
    exception_meta_t   exc;
    word_t             exc_pc;

    fluxcore_top #(
        .RESET_VECTOR(32'h0000_0000),
        .TRAP_VECTOR (32'h0000_0000)
    ) dut (
        .clk           (clk),
        .rst           (rst),
        .imem_addr_o      (imem_addr),
        .imem_addr_next_o (imem_addr_next),
        .imem_rdata_i     (imem_rdata),
        .dmem_addr_o      (dmem_addr),
        .dmem_wen_o    (dmem_wen),
        .dmem_wstrb_o  (dmem_wstrb),
        .dmem_wdata_o  (dmem_wdata),
        .dmem_rdata_i  (dmem_rdata),
        .dmem_ren_o    (dmem_ren),
        .dmem_stall_i  (1'b0),
        .retire_o      (retire),
        .exception_o   (exc),
        .exception_pc_o(exc_pc)
    );

    always_comb begin
        case (imem_addr)
            32'h00: imem_rdata = 32'h00800093; // ADDI x1, x0, 8
            32'h04: imem_rdata = 32'h00000113; // ADDI x2, x0, 0
            32'h08: imem_rdata = 32'h00110113; // ADDI x2, x2, 1
            32'h0C: imem_rdata = 32'hFFF08093; // ADDI x1, x1, -1
            32'h10: imem_rdata = 32'hFE009CE3; // BNE  x1, x0, -8
            32'h14: imem_rdata = 32'h03700193; // ADDI x3, x0, 55
            default: imem_rdata = 32'h00000013; // NOP
        endcase
    end

    int unsigned cyc = 0;
    always_ff @(posedge clk) if (!rst) cyc <= cyc + 1;

    int bne_retires = 0, exc_seen = 0;
    int unsigned x3_cycle = 0;
    always_ff @(posedge clk) begin
        if (!rst) begin
            if (retire.valid && retire.instr === 32'hFE009CE3)
                bne_retires <= bne_retires + 1;
            if (retire.valid && retire.instr === 32'h03700193 && x3_cycle == 0)
                x3_cycle <= cyc;
            if (exc.valid) exc_seen <= exc_seen + 1;
        end
    end

    int fails = 0;
    task check(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("FAIL  %s: got %0d expected %0d", name, got, exp);
            fails++;
        end else $display("PASS  %s", name);
    endtask

    initial begin
        repeat (5) @(posedge clk);
        @(negedge clk); rst = 0;
        repeat (70) @(posedge clk);

        $display("[BTB] loop finished: x3 retired at cycle %0d (static-not-taken needs ~46)",
                 x3_cycle);
        check("B1.x2_sum",       dut.u_regfile.regs[2], 32'd8);
        check("B1.x3_marker",    dut.u_regfile.regs[3], 32'd55);
        check("B1.x1_zero",      dut.u_regfile.regs[1], 32'd0);
        check("B2.bne_retires",  bne_retires,           8);
        check("B4.no_exceptions",exc_seen,              0);
        if (x3_cycle == 0 || x3_cycle >= 42) begin
            $display("FAIL  B3.speedup: x3 at cycle %0d (want < 42)", x3_cycle);
            fails++;
        end else $display("PASS  B3.speedup");

        if (fails != 0) $fatal(1, "tb_btb_predict: FAILURES detected");
        $display("\n[BTB] PASS: prediction fires, exit recovery correct, cycles saved.");
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "tb_btb_predict: timeout");
    end

endmodule : tb_btb_predict

`default_nettype wire
