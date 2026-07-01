// verification/integration/tb_branch_compare.sv
//
// Integration test: BLT, BGE, BLTU, BGEU — taken/not-taken and unsigned.
//
// Exercises all four remaining branch types (the existing tb_branch.sv covers
// only BEQ and BNE).  Tests both taken and not-taken outcomes, and validates
// that BLTU/BGEU treat operands as unsigned (so negative-signed values become
// large unsigned values and invert the comparison result).
//
// Register setup:
//   x1 = -5  = 0xFFFF_FFFB  (negative signed, large unsigned: 4294967291)
//   x2 =  5  = 0x0000_0005  (positive signed and unsigned)
//
// Instruction ROM (RESET_VECTOR = 0x0000_0000):
//
//   0x00: ADDI x1,  x0, -5      x1 = -5 = 0xFFFF_FFFB
//   0x04: ADDI x2,  x0,  5      x2 =  5
//   0x08: ADDI x10, x0,  1      x10 = 1 (fills EX stage while setup settles)
//
//   0x0C: BLT  x1, x2, +8       −5 <  5 → TAKEN   (x1 signed < x2)
//   0x10: ADDI x3,  x0, 99      SQUASHED (wrong path)
//   0x14: ADDI x4,  x0, 10      proof: TAKEN path executes
//
//   0x18: BGE  x2, x1, +8        5 >= −5 → TAKEN   (x2 signed >= x1)
//   0x1C: ADDI x5,  x0, 99      SQUASHED (wrong path)
//   0x20: ADDI x6,  x0, 20      proof: TAKEN path executes
//
//   0x24: BLT  x2, x1, +8        5 <  −5 → NOT TAKEN (5 is not signed < -5)
//   0x28: ADDI x7,  x0, 30      EXECUTES (fall-through)
//
//   0x2C: BLTU x1, x2, +8       0xFFFFFFFB < 5 → NOT TAKEN (large unsigned not < 5)
//   0x30: ADDI x8,  x0, 40      EXECUTES (fall-through)
//
//   0x34: BGEU x1, x2, +8       0xFFFFFFFB >= 5 → TAKEN   (large unsigned >= 5)
//   0x38: ADDI x9,  x0, 99      SQUASHED (wrong path)
//   0x3C: ADDI x11, x0, 50      proof: TAKEN path executes
//
//   default: NOP
//
// Encodings (assembled with riscv64-unknown-elf-as -march=rv32i):
//   ADDI x1,  x0, -5    0xFFB00093
//   ADDI x2,  x0,  5    0x00500113
//   ADDI x10, x0,  1    0x00100513
//   BLT  x1,  x2, +8    0x0020C463
//   ADDI x3,  x0, 99    0x06300193  [SQUASH]
//   ADDI x4,  x0, 10    0x00A00213
//   BGE  x2,  x1, +8    0x00115463
//   ADDI x5,  x0, 99    0x06300293  [SQUASH]
//   ADDI x6,  x0, 20    0x01400313
//   BLT  x2,  x1, +8    0x00114463  not-taken
//   ADDI x7,  x0, 30    0x01E00393
//   BLTU x1,  x2, +8    0x0020E463  not-taken (unsigned)
//   ADDI x8,  x0, 40    0x02800413
//   BGEU x1,  x2, +8    0x0020F463  taken (unsigned)
//   ADDI x9,  x0, 99    0x06300493  [SQUASH]
//   ADDI x11, x0, 50    0x03200593
//
// Expected retirements (program-order, squashed instructions never appear):
//   [0]  ADDI x1  = -5         rd_wen=1 rd_addr=1  rd_data=0xFFFF_FFFB
//   [1]  ADDI x2  =  5         rd_wen=1 rd_addr=2  rd_data=0x0000_0005
//   [2]  ADDI x10 =  1         rd_wen=1 rd_addr=10 rd_data=0x0000_0001
//   [3]  BLT taken             rd_wen=0
//   [4]  ADDI x4  = 10         rd_wen=1 rd_addr=4  rd_data=0x0000_000A
//   [5]  BGE taken             rd_wen=0
//   [6]  ADDI x6  = 20         rd_wen=1 rd_addr=6  rd_data=0x0000_0014
//   [7]  BLT not-taken         rd_wen=0
//   [8]  ADDI x7  = 30         rd_wen=1 rd_addr=7  rd_data=0x0000_001E
//   [9]  BLTU not-taken        rd_wen=0
//   [10] ADDI x8  = 40         rd_wen=1 rd_addr=8  rd_data=0x0000_0028
//   [11] BGEU taken            rd_wen=0
//   [12] ADDI x11 = 50         rd_wen=1 rd_addr=11 rd_data=0x0000_0032
//
// Poison check: x3, x5, x9 with data=99 must NEVER retire.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_branch_compare;

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
    word_t             dmem_addr;
    logic              dmem_ren;
    logic              dmem_wen;
    logic [3:0]        dmem_wstrb;
    word_t             dmem_wdata;
    word_t             dmem_rdata = '0;
    retirement_event_t retire;
    exception_meta_t   exc;
    word_t             exc_pc;

    fluxcore_top #(
        .RESET_VECTOR(32'h0000_0000),
        .TRAP_VECTOR (32'h0000_0000)
    ) dut (
        .clk            (clk),
        .rst            (rst),
        .imem_addr_o    (imem_addr),
        .imem_addr_next_o(imem_addr_next),
        .imem_rdata_i   (imem_rdata),
        .dmem_addr_o    (dmem_addr),
        .dmem_ren_o     (dmem_ren),
        .dmem_wen_o     (dmem_wen),
        .dmem_wstrb_o   (dmem_wstrb),
        .dmem_wdata_o   (dmem_wdata),
        .dmem_rdata_i   (dmem_rdata),
        .dmem_stall_i   (1'b0),
        .retire_o       (retire),
        .exception_o    (exc),
        .exception_pc_o (exc_pc)
    );

    // -----------------------------------------------------------------------
    // Instruction ROM
    // -----------------------------------------------------------------------
    always_comb begin
        case (imem_addr)
            32'h00: imem_rdata = 32'hFFB00093; // ADDI x1, x0, -5
            32'h04: imem_rdata = 32'h00500113; // ADDI x2, x0,  5
            32'h08: imem_rdata = 32'h00100513; // ADDI x10, x0, 1
            32'h0C: imem_rdata = 32'h0020C463; // BLT  x1, x2, +8  → TAKEN
            32'h10: imem_rdata = 32'h06300193; // ADDI x3, x0, 99  [SQUASH]
            32'h14: imem_rdata = 32'h00A00213; // ADDI x4, x0, 10
            32'h18: imem_rdata = 32'h00115463; // BGE  x2, x1, +8  → TAKEN
            32'h1C: imem_rdata = 32'h06300293; // ADDI x5, x0, 99  [SQUASH]
            32'h20: imem_rdata = 32'h01400313; // ADDI x6, x0, 20
            32'h24: imem_rdata = 32'h00114463; // BLT  x2, x1, +8  → NOT TAKEN
            32'h28: imem_rdata = 32'h01E00393; // ADDI x7, x0, 30
            32'h2C: imem_rdata = 32'h0020E463; // BLTU x1, x2, +8  → NOT TAKEN (unsigned)
            32'h30: imem_rdata = 32'h02800413; // ADDI x8, x0, 40
            32'h34: imem_rdata = 32'h0020F463; // BGEU x1, x2, +8  → TAKEN (unsigned)
            32'h38: imem_rdata = 32'h06300493; // ADDI x9, x0, 99  [SQUASH]
            32'h3C: imem_rdata = 32'h03200593; // ADDI x11, x0, 50
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
            $fatal(1, "[BRANCHCMP] FAIL unexpected exception: cause=%0d pc=%08h",
                   int'(exc.cause), exc_pc);
    end

    always_ff @(posedge clk) begin
        if (!rst && dmem_wen)
            $fatal(1, "[BRANCHCMP] FAIL unexpected dmem write: addr=%08h", dmem_addr);
    end

    // Poison: squashed ADDIs (x3, x5, x9 = 99) must never retire
    always_ff @(posedge clk) begin
        if (!rst && retire.valid && retire.rd_wen
                 && (retire.rd_addr == 5'd3  ||
                     retire.rd_addr == 5'd5  ||
                     retire.rd_addr == 5'd9)
                 && retire.rd_data == 32'd99)
            $fatal(1, "[BRANCHCMP] FAIL squashed ADDI(rd=%0d,data=99) retired — branch flush failed",
                   retire.rd_addr);
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
        if (retire_log[idx].valid !== 1'b1)
            $fatal(1, "[BRANCHCMP] FAIL retire[%0d] %-38s not valid", idx, desc);
        if (retire_log[idx].rd_wen !== logic'(exp_rd_wen))
            $fatal(1, "[BRANCHCMP] FAIL retire[%0d] %-38s rd_wen=%b expected=%0d",
                   idx, desc, retire_log[idx].rd_wen, exp_rd_wen);
        if (exp_rd_wen) begin
            if (retire_log[idx].rd_addr !== reg_idx_t'(exp_rd_addr))
                $fatal(1, "[BRANCHCMP] FAIL retire[%0d] %-38s rd_addr=%0d expected=%0d",
                       idx, desc, retire_log[idx].rd_addr, exp_rd_addr);
            if (retire_log[idx].rd_data !== exp_rd_data)
                $fatal(1, "[BRANCHCMP] FAIL retire[%0d] %-38s rd_data=%08h expected=%08h",
                       idx, desc, retire_log[idx].rd_data, exp_rd_data);
        end
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin : stim

        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;

        // Run 50 cycles:
        // Pipeline fill: 4 cycles. 13 retirements + 3 × 2-cycle branch penalty = 19.
        // 50 cycles comfortably covers all retirements.
        repeat (50) @(posedge clk);
        #1;

        if (retire_cnt < 13)
            $fatal(1, "[BRANCHCMP] FAIL only %0d retirements in 50 cycles (expected >= 13)",
                   retire_cnt);

        // Setup
        chk(0,  1,  1, 32'hFFFF_FFFB, "ADDI x1=-5");
        chk(1,  1,  2, 32'h0000_0005, "ADDI x2=5");
        chk(2,  1, 10, 32'h0000_0001, "ADDI x10=1");

        // BLT x1, x2 (TAKEN: −5 < 5 signed)
        chk(3,  0,  0, '0,            "BLT taken: −5 < 5");
        chk(4,  1,  4, 32'h0000_000A, "ADDI x4=10: BLT target reached");

        // BGE x2, x1 (TAKEN: 5 >= −5 signed)
        chk(5,  0,  0, '0,            "BGE taken: 5 >= −5");
        chk(6,  1,  6, 32'h0000_0014, "ADDI x6=20: BGE target reached");

        // BLT x2, x1 (NOT TAKEN: 5 < −5 is false)
        chk(7,  0,  0, '0,            "BLT not-taken: 5 < −5 is false");
        chk(8,  1,  7, 32'h0000_001E, "ADDI x7=30: fall-through after not-taken BLT");

        // BLTU x1, x2 (NOT TAKEN: 0xFFFFFFFB < 5 is false unsigned)
        chk(9,  0,  0, '0,            "BLTU not-taken: 0xFFFFFFFB >= 5 unsigned");
        chk(10, 1,  8, 32'h0000_0028, "ADDI x8=40: fall-through after not-taken BLTU");

        // BGEU x1, x2 (TAKEN: 0xFFFFFFFB >= 5 unsigned)
        chk(11, 0,  0, '0,            "BGEU taken: 0xFFFFFFFB >= 5 unsigned");
        chk(12, 1, 11, 32'h0000_0032, "ADDI x11=50: BGEU target reached");

        $display("[BRANCHCMP] PASS: %0d retirements — BLT/BGE/BLTU/BGEU all correct.",
                 retire_cnt);
        $finish;

    end : stim

endmodule : tb_branch_compare

`default_nettype wire
