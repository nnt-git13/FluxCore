// verification/integration/tb_jal_jalr.sv
//
// Integration test: JAL and JALR link-address and jump-target correctness.
//
// Two phases:
//
//   Phase 1 — JAL
//     JAL x1, +16 at 0x00: link address x1=4 written to rd, fetch redirects
//     to 0x10.  The two instructions in the wrong-path slots (0x04, 0x08) are
//     squashed by the 2-cycle penalty.  ADDI x2=2 at 0x10 retires next,
//     confirming the redirect.
//
//   Phase 2 — JALR with EX/MEM forward for rs1
//     ADDI x5=44 at 0x18, immediately followed by JALR x6,x5,0 at 0x1C.
//     With EX/MEM → EX forwarding: x5=44 is presented to the branch-target
//     unit, so JALR jumps to (44+0)&~1 = 0x2C and writes x6=0x20 (pc+4).
//     Without forwarding: x5=0 (stale) → JALR would jump to 0x00, re-executing
//     the whole program.  Detection: ADDI x7=7 at 0x2C retires at index [5].
//
// Instruction ROM (RESET_VECTOR = 0x0000_0000):
//
//   0x00: JAL  x1, +16            link=4,   target=0x10
//   0x04: ADDI x20, x0, 99        SQUASHED  (wrong-path poison)
//   0x08: ADDI x21, x0, 99        SQUASHED  (wrong-path poison)
//   0x0C: NOP                      unreachable from this path
//   0x10: ADDI x2, x0, 2          x2=2     first after JAL
//   0x14: ADDI x3, x0, 3          x3=3     second after JAL
//   0x18: ADDI x5, x0, 44         x5=44    JALR base (EX/MEM fwd source)
//   0x1C: JALR x6, x5, 0          link=32,  target=(44+0)&~1=0x2C  (fwd)
//   0x20: ADDI x20, x0, 99        SQUASHED  (wrong-path poison)
//   0x24: ADDI x21, x0, 99        SQUASHED  (wrong-path poison)
//   0x28: NOP                      unreachable from 0x1C path
//   0x2C: ADDI x7, x0, 7          x7=7     first after JALR
//   0x30: ADDI x8, x0, 8          x8=8     second after JALR
//   default: NOP
//
// Encoding verification:
//   JAL  x1, +16   0x010000ef
//   JALR x6, x5, 0 0x00028367
//
// Expected retirements (in program order, RESET_VECTOR=0):
//   [0] JAL:      rd_wen=1, rd_addr=1,  rd_data=0x0000_0004  (link=pc+4)
//   [1] ADDI x2:  rd_wen=1, rd_addr=2,  rd_data=2
//   [2] ADDI x3:  rd_wen=1, rd_addr=3,  rd_data=3
//   [3] ADDI x5:  rd_wen=1, rd_addr=5,  rd_data=44
//   [4] JALR:     rd_wen=1, rd_addr=6,  rd_data=0x0000_0020  (link=pc+4=0x1C+4)
//   [5] ADDI x7:  rd_wen=1, rd_addr=7,  rd_data=7   ← proves JALR target was 0x2C
//   [6] ADDI x8:  rd_wen=1, rd_addr=8,  rd_data=8
//
// Poison check: rd_addr=20 or rd_addr=21 with rd_data=99 must never retire.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_jal_jalr;

    // -----------------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------------
    logic clk = 0;
    logic rst = 1;

    always #5 clk = ~clk;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    word_t             imem_addr;
    word_t             imem_addr_next;
    instr_t            imem_rdata;
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
        .dmem_addr_o      (),
        .dmem_wen_o    (),
        .dmem_wstrb_o  (),
        .dmem_wdata_o  (),
        .dmem_rdata_i  ('0),
        .dmem_ren_o    (),
        .dmem_stall_i  (1'b0),
        .retire_o      (retire),
        .exception_o   (exc),
        .exception_pc_o(exc_pc)
    );

    // -----------------------------------------------------------------------
    // Instruction ROM
    // -----------------------------------------------------------------------
    always_comb begin
        case (imem_addr)
            32'h00: imem_rdata = 32'h010000ef; // JAL  x1, +16
            32'h04: imem_rdata = 32'h06300a13; // ADDI x20,x0,99   SQUASHED
            32'h08: imem_rdata = 32'h06300a93; // ADDI x21,x0,99   SQUASHED
            32'h0C: imem_rdata = 32'h00000013; // NOP  (unreachable)
            32'h10: imem_rdata = 32'h00200113; // ADDI x2, x0, 2
            32'h14: imem_rdata = 32'h00300193; // ADDI x3, x0, 3
            32'h18: imem_rdata = 32'h02c00293; // ADDI x5, x0, 44
            32'h1C: imem_rdata = 32'h00028367; // JALR x6, x5, 0
            32'h20: imem_rdata = 32'h06300a13; // ADDI x20,x0,99   SQUASHED
            32'h24: imem_rdata = 32'h06300a93; // ADDI x21,x0,99   SQUASHED
            32'h28: imem_rdata = 32'h00000013; // NOP  (unreachable)
            32'h2C: imem_rdata = 32'h00700393; // ADDI x7, x0, 7
            32'h30: imem_rdata = 32'h00800413; // ADDI x8, x0, 8
            default: imem_rdata = 32'h00000013; // NOP
        endcase
    end

    // -----------------------------------------------------------------------
    // Retirement log
    // -----------------------------------------------------------------------
    retirement_event_t retire_log [0:31];
    int                retire_cnt = 0;

    always_ff @(posedge clk) begin
        if (retire.valid && retire_cnt < 32) begin
            retire_log[retire_cnt] <= retire;
            retire_cnt             <= retire_cnt + 1;
        end
    end

    // -----------------------------------------------------------------------
    // Liveness guards
    // -----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst && exc.valid)
            $fatal(1, "[JAL] FAIL unexpected exception: cause=%0d pc=%08h",
                   int'(exc.cause), exc_pc);
    end

    // Poison: wrong-path instructions (x20/x21 = 99) must never retire
    always_ff @(posedge clk) begin
        if (!rst && retire.valid && retire.rd_wen
            && retire.rd_data == 32'd99
            && (retire.rd_addr == 5'd20 || retire.rd_addr == 5'd21))
            $fatal(1, "[JAL] FAIL wrong-path retirement: rd_addr=%0d rd_data=99 — jump squash failed",
                   retire.rd_addr);
    end

    // -----------------------------------------------------------------------
    // Check helper
    // -----------------------------------------------------------------------
    task automatic chk(
        input int    idx,
        input int    exp_rd_addr,
        input word_t exp_rd_data,
        input string desc
    );
        if (!retire_log[idx].valid)
            $fatal(1, "[JAL] FAIL retire[%0d] %-32s not valid", idx, desc);
        if (!retire_log[idx].rd_wen)
            $fatal(1, "[JAL] FAIL retire[%0d] %-32s rd_wen=0 (expected 1)", idx, desc);
        if (retire_log[idx].rd_addr !== reg_idx_t'(exp_rd_addr))
            $fatal(1, "[JAL] FAIL retire[%0d] %-32s rd_addr=%0d expected=%0d",
                   idx, desc, retire_log[idx].rd_addr, exp_rd_addr);
        if (retire_log[idx].rd_data !== exp_rd_data)
            $fatal(1, "[JAL] FAIL retire[%0d] %-32s rd_data=%08h expected=%08h",
                   idx, desc, retire_log[idx].rd_data, exp_rd_data);
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin : stim

        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;

        // 7 instructions + 2×2 pipeline penalty + 4 fill ≈ 17 cycles; use 30.
        repeat (30) @(posedge clk);
        #1;

        if (retire_cnt < 7)
            $fatal(1, "[JAL] FAIL only %0d retirements (expected >= 7)", retire_cnt);

        // Phase 1: JAL
        chk(0, 1,  32'h0000_0004, "JAL x1: link=pc+4=4");
        chk(1, 2,  32'd2,          "ADDI x2=2: JAL target correct (0x10)");
        chk(2, 3,  32'd3,          "ADDI x3=3");
        // Phase 2: JALR with EX/MEM forward
        chk(3, 5,  32'd44,         "ADDI x5=44: JALR base");
        chk(4, 6,  32'h0000_0020,  "JALR x6: link=pc+4=0x20=32");
        chk(5, 7,  32'd7,          "ADDI x7=7: JALR target correct (0x2C)");
        chk(6, 8,  32'd8,          "ADDI x8=8");

        $display("[JAL] PASS: %0d retirements — JAL link+target and JALR forwarded target verified.",
                 retire_cnt);
        $finish;

    end : stim

endmodule : tb_jal_jalr

`default_nettype wire
