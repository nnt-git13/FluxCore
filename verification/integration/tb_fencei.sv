// verification/integration/tb_fencei.sv
//
// FENCE.I integration test on fluxcore_top (combinational ROM).
//
// Program (RESET_VECTOR = 0):
//   0x00  ADDI x1, x0, 1      older instruction — must retire
//   0x04  FENCE.I             flush pulse + restart at 0x08
//   0x08  ADDI x2, x0, 2      the two fetches behind FENCE.I are squashed
//   0x0C  ADDI x3, x0, 3      and refetched — all must retire exactly once
//   0x10+ NOP
//
// Checks:
//   F1. fencei_flush_o pulses exactly once.
//   F2. x1=1, x2=2, x3=3 after the run (each retired exactly once — a
//       double-retire of x2/x3 would still leave the right values, so the
//       retirement count is checked too).
//   F3. Retirement stream: exactly 1 FENCE.I retires (opcode check).

`timescale 1ns/1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_fencei;

    logic clk = 0;
    logic rst = 1;
    always #5 clk = ~clk;

    word_t             imem_addr;
    word_t             imem_addr_next;
    instr_t            imem_rdata;
    word_t             dmem_addr;
    logic              dmem_wen;
    logic [3:0]        dmem_wstrb;
    word_t             dmem_wdata;
    word_t             dmem_rdata = '0;
    logic              fencei_flush;
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
        .fencei_flush_o   (fencei_flush),
        .dmem_addr_o      (dmem_addr),
        .dmem_wen_o    (dmem_wen),
        .dmem_wstrb_o  (dmem_wstrb),
        .dmem_wdata_o  (dmem_wdata),
        .dmem_rdata_i  (dmem_rdata),
        .dmem_ren_o    (),
        .dmem_stall_i  (1'b0),
        .retire_o      (retire),
        .exception_o   (exc),
        .exception_pc_o(exc_pc)
    );

    always_comb begin
        case (imem_addr)
            32'h00: imem_rdata = 32'h00100093; // ADDI x1, x0, 1
            32'h04: imem_rdata = 32'h0000100F; // FENCE.I
            32'h08: imem_rdata = 32'h00200113; // ADDI x2, x0, 2
            32'h0C: imem_rdata = 32'h00300193; // ADDI x3, x0, 3
            default: imem_rdata = 32'h00000013; // NOP
        endcase
    end

    int flush_pulses = 0;
    int fencei_retires = 0;
    int addi_retires = 0;
    logic flush_seen_prev = 0;
    always_ff @(posedge clk) begin
        if (!rst) begin
            // count rising occurrences (a multi-cycle level counts once)
            if (fencei_flush && !flush_seen_prev) flush_pulses <= flush_pulses + 1;
            flush_seen_prev <= fencei_flush;
            if (retire.valid) begin
                if (retire.instr === 32'h0000100F) fencei_retires <= fencei_retires + 1;
                if (retire.instr[6:0] == 7'b0010011 && retire.instr !== 32'h00000013)
                    addi_retires <= addi_retires + 1;
            end
        end
    end

    int fails = 0;
    task check(input string name, input logic cond);
        if (!cond) begin $display("FAIL  %s", name); fails++; end
        else begin $display("PASS  %s", name); end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        @(negedge clk); rst = 0;
        repeat (40) @(posedge clk);

        check("F1.one_flush_pulse",  flush_pulses == 1);
        check("F2.x1", dut.u_regfile.regs[1] === 32'd1);
        check("F2.x2", dut.u_regfile.regs[2] === 32'd2);
        check("F2.x3", dut.u_regfile.regs[3] === 32'd3);
        check("F2.addi_retire_count", addi_retires == 3);
        check("F3.one_fencei_retire", fencei_retires == 1);

        if (fails != 0) $fatal(1, "tb_fencei: FAILURES detected");
        $display("\n[FENCEI] PASS: flush pulse, restart, and exact retirement verified.");
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "tb_fencei: timeout");
    end

endmodule : tb_fencei

`default_nettype wire
