// verification/integration/tb_lui_auipc.sv
//
// Integration test: LUI (load-upper-immediate) and AUIPC (add-upper-immediate
// to PC) instruction correctness.
//
// Two phases:
//
//   Phase 1 — LUI coverage
//     Three LUI instructions exercising different upper-immediate patterns:
//       LUI x1, 1       → x1 = 0x0000_1000  (smallest non-zero upper-imm)
//       LUI x2, 0xFFFFF → x2 = 0xFFFF_F000  (all-ones; signed −4096)
//       LUI x3, 0x12345 → x3 = 0x1234_5000  (arbitrary pattern)
//     Confirms ALU COPY_B path (upper-imm passes straight through).
//
//   Phase 2 — AUIPC coverage + EX/MEM forwarding
//     Two AUIPC instructions with known PC values (RESET_VECTOR = 0):
//       AUIPC x4, 1 at PC=0x0C → x4 = 0x0C + 0x1000 = 0x0000_100C
//       AUIPC x5, 0 at PC=0x10 → x5 = 0x10 + 0      = 0x0000_0010
//     Confirms ALU ADD path with opa=PC operand.
//
//     LUI+ADDI two-instruction 32-bit constant idiom (EX/MEM forward for rs1):
//       LUI  x6, 0xABCDE at 0x14 → x6 = 0xABCDE000
//       ADDI x6, x6, 0x23 at 0x18 → x6 = 0xABCDE023
//     1-instruction gap ⇒ EX/MEM→EX forward for rs1=x6.
//     Without forwarding: stale x6=0 ⇒ ADDI result = 0x23 (wrong).
//
// Instruction ROM (RESET_VECTOR = 0x0000_0000):
//
//   0x00: LUI  x1, 1              x1 = 0x0000_1000
//   0x04: LUI  x2, 0xFFFFF        x2 = 0xFFFF_F000
//   0x08: LUI  x3, 0x12345        x3 = 0x1234_5000
//   0x0C: AUIPC x4, 1             x4 = 0x0C+0x1000 = 0x0000_100C
//   0x10: AUIPC x5, 0             x5 = 0x10+0      = 0x0000_0010
//   0x14: LUI  x6, 0xABCDE        x6 = 0xABCDE000
//   0x18: ADDI x6, x6, 0x23       x6 = 0xABCDE023 (EX/MEM fwd rs1)
//   default: NOP
//
// Encodings (all Python-verified):
//   LUI  x1, 1:           0x000010b7
//   LUI  x2, 0xFFFFF:     0xfffff137
//   LUI  x3, 0x12345:     0x123451b7
//   AUIPC x4, 1:          0x00001217
//   AUIPC x5, 0:          0x00000297
//   LUI  x6, 0xABCDE:     0xabcde337
//   ADDI x6, x6, 0x23:    0x02330313
//
// Expected retirements (RESET_VECTOR must = 0 for AUIPC checks to hold):
//   [0] LUI x1:    rd_wen=1, rd_addr=1, rd_data=0x0000_1000
//   [1] LUI x2:    rd_wen=1, rd_addr=2, rd_data=0xFFFF_F000
//   [2] LUI x3:    rd_wen=1, rd_addr=3, rd_data=0x1234_5000
//   [3] AUIPC x4:  rd_wen=1, rd_addr=4, rd_data=0x0000_100C
//   [4] AUIPC x5:  rd_wen=1, rd_addr=5, rd_data=0x0000_0010
//   [5] LUI x6:    rd_wen=1, rd_addr=6, rd_data=0xABCDE000
//   [6] ADDI x6:   rd_wen=1, rd_addr=6, rd_data=0xABCDE023

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_lui_auipc;

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
            32'h00: imem_rdata = 32'h000010b7; // LUI  x1, 1
            32'h04: imem_rdata = 32'hfffff137; // LUI  x2, 0xFFFFF
            32'h08: imem_rdata = 32'h123451b7; // LUI  x3, 0x12345
            32'h0C: imem_rdata = 32'h00001217; // AUIPC x4, 1
            32'h10: imem_rdata = 32'h00000297; // AUIPC x5, 0
            32'h14: imem_rdata = 32'habcde337; // LUI  x6, 0xABCDE
            32'h18: imem_rdata = 32'h02330313; // ADDI x6, x6, 0x23 (fwd)
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
    // Liveness guard
    // -----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst && exc.valid)
            $fatal(1, "[LUI] FAIL unexpected exception: cause=%0d pc=%08h",
                   int'(exc.cause), exc_pc);
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
            $fatal(1, "[LUI] FAIL retire[%0d] %-32s not valid", idx, desc);
        if (!retire_log[idx].rd_wen)
            $fatal(1, "[LUI] FAIL retire[%0d] %-32s rd_wen=0 (expected 1)", idx, desc);
        if (retire_log[idx].rd_addr !== reg_idx_t'(exp_rd_addr))
            $fatal(1, "[LUI] FAIL retire[%0d] %-32s rd_addr=%0d expected=%0d",
                   idx, desc, retire_log[idx].rd_addr, exp_rd_addr);
        if (retire_log[idx].rd_data !== exp_rd_data)
            $fatal(1, "[LUI] FAIL retire[%0d] %-32s rd_data=%08h expected=%08h",
                   idx, desc, retire_log[idx].rd_data, exp_rd_data);
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin : stim

        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;

        // 7 instructions + 4 pipeline fill = 11 cycles; use 25 for margin.
        repeat (25) @(posedge clk);
        #1;

        if (retire_cnt < 7)
            $fatal(1, "[LUI] FAIL only %0d retirements (expected >= 7)", retire_cnt);

        // Phase 1: LUI
        chk(0, 1, 32'h0000_1000, "LUI x1 1         → 0x00001000");
        chk(1, 2, 32'hFFFF_F000, "LUI x2 0xFFFFF   → 0xFFFFF000");
        chk(2, 3, 32'h1234_5000, "LUI x3 0x12345   → 0x12345000");

        // Phase 2: AUIPC (PC-relative)
        chk(3, 4, 32'h0000_100C, "AUIPC x4 1 @0x0C → pc+0x1000=0x100C");
        chk(4, 5, 32'h0000_0010, "AUIPC x5 0 @0x10 → pc+0=0x0010");

        // Phase 2 cont.: LUI+ADDI 32-bit constant idiom with EX/MEM forward
        chk(5, 6, 32'hABCDE000, "LUI x6 0xABCDE   → 0xABCDE000");
        // Without EX/MEM forwarding: stale x6=0 → ADDI produces 0x23 (wrong)
        chk(6, 6, 32'hABCDE023, "ADDI x6,x6,0x23  → 0xABCDE023 (fwd)");

        $display("[LUI] PASS: %0d retirements — LUI/AUIPC values and LUI+ADDI forwarding correct.",
                 retire_cnt);
        $finish;

    end : stim

endmodule : tb_lui_auipc

`default_nettype wire
