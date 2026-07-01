// verification/integration/tb_branch.sv
//
// Integration test: branch direction and forwarding correctness.
//
// Two phases:
//
//   Phase 1 — not-taken BEQ with forwarded operands
//     ADDI x1=5 and ADDI x2=7 are 2 and 1 instruction before BEQ respectively.
//     Without forwarding both would read stale 0 and BEQ(0,0) would be
//     incorrectly TAKEN. With forwarding BEQ(5,7) is correctly NOT TAKEN and
//     sequential execution continues.
//       x1: MEM/WB → EX forward (2-instruction gap)
//       x2: EX/MEM → EX forward (1-instruction gap)
//
//   Phase 2 — taken BNE with EX/MEM forward for rs1
//     ADDI x11=4 is 1 instruction before BNE x11,x0. Without forwarding
//     x11 reads stale 0 and BNE(0,0) is incorrectly NOT TAKEN. With
//     forwarding BNE(4,0) is correctly TAKEN, the pipeline flushes IF/ID and
//     ID/EX (2-cycle penalty), and execution resumes at the branch target.
//
// Instruction ROM (RESET_VECTOR = 0x0000_0000):
//
//   0x00: ADDI x1,  x0,  5       x1 = 5          (rs1 for BEQ, MEM/WB fwd)
//   0x04: ADDI x2,  x0,  7       x2 = 7          (rs2 for BEQ, EX/MEM fwd)
//   0x08: BEQ  x1,  x2, +20      5≠7 → NOT taken; wrong-target = 0x1C
//   0x0C: ADDI x3,  x0,  3       x3 = 3          (correct sequential path)
//   0x10: ADDI x4,  x0,  4       x4 = 4          (correct sequential path)
//   0x14: ADDI x11, x0,  4       x11 = 4         (rs1 for BNE, EX/MEM fwd)
//   0x18: BNE  x11, x0, +12      4≠0 → TAKEN;    target = 0x24
//   0x1C: ADDI x7,  x0, 99       SQUASHED (wrong path; also BEQ wrong-target)
//   0x20: ADDI x8,  x0, 99       SQUASHED (wrong path, 2-cycle BNE penalty)
//   0x24: ADDI x9,  x0,  9       x9 = 9          (first on correct BNE path)
//   0x28: ADDI x10, x0, 10       x10 = 10        (second on correct BNE path)
//   default: NOP (ADDI x0, x0, 0)
//
// Encoding verification (BEQ/BNE B-type):
//   BEQ  x1,  x2, +20   0x00208a63
//   BNE  x11, x0, +12   0x00059663
//
// Expected retirements in program order:
//   [0] ADDI x1:  rd_wen=1, rd_addr=1,  rd_data=5
//   [1] ADDI x2:  rd_wen=1, rd_addr=2,  rd_data=7
//   [2] BEQ:      rd_wen=0, valid=1     (branch retires; not-taken path)
//   [3] ADDI x3:  rd_wen=1, rd_addr=3,  rd_data=3   ← proves BEQ not taken
//   [4] ADDI x4:  rd_wen=1, rd_addr=4,  rd_data=4
//   [5] ADDI x11: rd_wen=1, rd_addr=11, rd_data=4
//   [6] BNE:      rd_wen=0, valid=1     (branch retires; taken path)
//   [7] ADDI x9:  rd_wen=1, rd_addr=9,  rd_data=9   ← proves BNE taken (fwd)
//   [8] ADDI x10: rd_wen=1, rd_addr=10, rd_data=10
//
// Poison check: rd_addr=7 or rd_addr=8 with rd_data=99 must never appear.
//   If seen → forwarding failed and wrong-path executed.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_branch;

    // -----------------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------------
    logic clk = 0;
    logic rst = 1;

    always #5 clk = ~clk;

    // -----------------------------------------------------------------------
    // DUT ports
    // -----------------------------------------------------------------------
    word_t             imem_addr;
    word_t             imem_addr_next;
    instr_t            imem_rdata;
    word_t             dmem_addr;
    logic              dmem_wen;
    logic [3:0]        dmem_wstrb;
    word_t             dmem_wdata;
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
        .dmem_rdata_i  ('0),           // no loads in this test
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
            32'h00: imem_rdata = 32'h00500093; // ADDI x1,  x0, 5
            32'h04: imem_rdata = 32'h00700113; // ADDI x2,  x0, 7
            32'h08: imem_rdata = 32'h00208a63; // BEQ  x1,  x2, +20  (not-taken)
            32'h0C: imem_rdata = 32'h00300193; // ADDI x3,  x0, 3    (sequential)
            32'h10: imem_rdata = 32'h00400213; // ADDI x4,  x0, 4    (sequential)
            32'h14: imem_rdata = 32'h00400593; // ADDI x11, x0, 4
            32'h18: imem_rdata = 32'h00059663; // BNE  x11, x0, +12  (taken)
            32'h1C: imem_rdata = 32'h06300393; // ADDI x7,  x0, 99   SQUASHED
            32'h20: imem_rdata = 32'h06300413; // ADDI x8,  x0, 99   SQUASHED
            32'h24: imem_rdata = 32'h00900493; // ADDI x9,  x0, 9    (first after BNE)
            32'h28: imem_rdata = 32'h00a00513; // ADDI x10, x0, 10   (second after BNE)
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
            $fatal(1, "[BRANCH] FAIL unexpected exception: cause=%0d pc=%08h",
                   int'(exc.cause), exc_pc);
    end

    always_ff @(posedge clk) begin
        if (!rst && dmem_wen)
            $fatal(1, "[BRANCH] FAIL unexpected dmem write (no stores expected)");
    end

    // -----------------------------------------------------------------------
    // Poison check: wrong-path instructions must never retire
    // -----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst && retire.valid && retire.rd_wen
            && retire.rd_data == 32'd99
            && (retire.rd_addr == 5'd7 || retire.rd_addr == 5'd8))
            $fatal(1, "[BRANCH] FAIL wrong-path retirement: rd_addr=%0d rd_data=%0d — branch forwarding failed",
                   retire.rd_addr, retire.rd_data);
    end

    // -----------------------------------------------------------------------
    // Check helper
    // -----------------------------------------------------------------------
    task automatic chk(
        input int    idx,
        input int    exp_rd_wen,
        input int    exp_rd_addr,
        input word_t exp_rd_data,
        input string desc
    );
        if (!retire_log[idx].valid)
            $fatal(1, "[BRANCH] FAIL retire[%0d] %-32s not valid", idx, desc);
        if (retire_log[idx].rd_wen !== logic'(exp_rd_wen))
            $fatal(1, "[BRANCH] FAIL retire[%0d] %-32s rd_wen=%b expected=%0d",
                   idx, desc, retire_log[idx].rd_wen, exp_rd_wen);
        if (exp_rd_wen) begin
            if (retire_log[idx].rd_addr !== reg_idx_t'(exp_rd_addr))
                $fatal(1, "[BRANCH] FAIL retire[%0d] %-32s rd_addr=%0d expected=%0d",
                       idx, desc, retire_log[idx].rd_addr, exp_rd_addr);
            if (retire_log[idx].rd_data !== exp_rd_data)
                $fatal(1, "[BRANCH] FAIL retire[%0d] %-32s rd_data=%08h expected=%08h",
                       idx, desc, retire_log[idx].rd_data, exp_rd_data);
        end
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin : stim

        // Hold reset for 3 rising edges
        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;

        // Run 30 active cycles:
        // 9 program instructions + 2-cycle BNE penalty + 4 pipeline fill ≈ 15.
        // 30 provides comfortable margin for drain NOPs.
        repeat (30) @(posedge clk);
        #1;

        if (retire_cnt < 9)
            $fatal(1, "[BRANCH] FAIL only %0d retirements (expected >= 9)", retire_cnt);

        // --- Phase 1: not-taken BEQ with operand forwarding ---
        chk(0, 1,  1, 32'd5,  "ADDI x1=5");
        chk(1, 1,  2, 32'd7,  "ADDI x2=7");
        chk(2, 0,  0, '0,     "BEQ not-taken: retires, no rd write");
        chk(3, 1,  3, 32'd3,  "ADDI x3=3: proves BEQ not taken (sequential path)");
        chk(4, 1,  4, 32'd4,  "ADDI x4=4");

        // --- Phase 2: taken BNE with EX/MEM forward for rs1 ---
        chk(5, 1, 11, 32'd4,  "ADDI x11=4: BNE producer");
        chk(6, 0,  0, '0,     "BNE taken: retires, no rd write");
        // retire[7] must be ADDI x9=9 (0x24), NOT ADDI x7=99 (0x1C).
        // Presence of x9=9 here proves the 2-cycle flush squashed 0x1C/0x20
        // and the forwarded BNE directed fetch to 0x24.
        chk(7, 1,  9, 32'd9,  "ADDI x9=9: proves BNE taken to correct target");
        chk(8, 1, 10, 32'd10, "ADDI x10=10");

        $display("[BRANCH] PASS: %0d retirements — not-taken BEQ, taken BNE, forwarded operands all correct.",
                 retire_cnt);
        $finish;

    end : stim

endmodule : tb_branch

`default_nettype wire
