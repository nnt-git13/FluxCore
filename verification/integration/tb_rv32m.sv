// verification/integration/tb_rv32m.sv
//
// Integration test: RV32M multiply and divide instructions.
//
// Tests all 8 M-extension instructions end-to-end through fluxcore_top.
// Also checks the two RISC-V-mandated special cases:
//   1. Divide by zero: DIV/DIVU = 0xFFFFFFFF, REM/REMU = dividend.
//   2. Signed overflow (INT_MIN / -1): DIV = 0x80000000, REM = 0.
//
// Instruction ROM:
//
//   --- Setup ---
//   0x00: ADDI x1, x0, -20     x1 = 0xFFFF_FFEC  (signed -20, unsigned 4294967276)
//   0x04: ADDI x2, x0,   5     x2 = 5
//
//   --- Multiply (single-cycle, no stall) ---
//   0x08: MUL     x3,  x1, x2  x3  = (-20*5)[31:0]          = 0xFFFF_FF9C (-100)
//   0x0C: MULH    x4,  x1, x2  x4  = (signed -20*5)[63:32]  = 0xFFFF_FFFF
//   0x10: MULHU   x5,  x1, x2  x5  = (unsigned prod)[63:32] = 0x0000_0004
//   0x14: MULHSU  x6,  x1, x2  x6  = (signed*unsigned)[63:32]=0xFFFF_FFFF
//
//   --- Divide (33-cycle stall each) ---
//   0x18: DIV     x7,  x1, x2  x7  = signed  -20 / 5  = -4  = 0xFFFF_FFFC
//   0x1C: DIVU    x8,  x1, x2  x8  = unsigned 4294967276/5   = 0x3333_332F
//   0x20: REM     x9,  x1, x2  x9  = signed  -20 % 5  = 0   = 0x0000_0000
//   0x24: REMU    x10, x1, x2  x10 = unsigned 4294967276%5   = 0x0000_0001
//
//   --- Special case 1: divide by zero ---
//   0x28: ADDI x1, x0, -1      x1 = 0xFFFF_FFFF
//   0x2C: ADDI x2, x0,  0      x2 = 0
//   0x30: DIV   x11, x1, x2   x11 = 0xFFFF_FFFF  (spec: all-ones)
//   0x34: REM   x12, x1, x2   x12 = 0xFFFF_FFFF  (spec: rs1)
//
//   --- Special case 2: signed overflow (INT_MIN / -1) ---
//   0x38: LUI   x1, 0x80000   x1 = 0x8000_0000  (INT_MIN)
//   0x3C: ADDI  x2, x0, -1    x2 = 0xFFFF_FFFF
//   0x40: DIV   x13, x1, x2   x13 = 0x8000_0000  (spec: INT_MIN)
//   0x44: REM   x14, x1, x2   x14 = 0x0000_0000  (spec: 0)
//
//   default: NOP (drain pipeline)
//
// Instruction encodings (verified with Python encoder):
//   ADDI x1,x0,-20     0xFEC00093
//   ADDI x2,x0,5       0x00500113
//   MUL     x3,x1,x2   0x022081B3
//   MULH    x4,x1,x2   0x02209233
//   MULHU   x5,x1,x2   0x0220B2B3
//   MULHSU  x6,x1,x2   0x0220A333
//   DIV     x7,x1,x2   0x0220C3B3
//   DIVU    x8,x1,x2   0x0220D433
//   REM     x9,x1,x2   0x0220E4B3
//   REMU    x10,x1,x2  0x0220F533
//   ADDI x1,x0,-1      0xFFF00093
//   ADDI x2,x0,0       0x00000113
//   DIV  x11,x1,x2     0x0220C5B3
//   REM  x12,x1,x2     0x0220E633
//   LUI  x1, 0x80000   0x800000B7
//   ADDI x2,x0,-1      0xFFF00113
//   DIV  x13,x1,x2     0x0220C6B3
//   REM  x14,x1,x2     0x0220E733
//
// Expected retirements (18 instructions):
//   [0]  ADDI x1=-20    rd=1  data=0xFFFF_FFEC
//   [1]  ADDI x2=5      rd=2  data=0x0000_0005
//   [2]  MUL  x3        rd=3  data=0xFFFF_FF9C
//   [3]  MULH x4        rd=4  data=0xFFFF_FFFF
//   [4]  MULHU x5       rd=5  data=0x0000_0004
//   [5]  MULHSU x6      rd=6  data=0xFFFF_FFFF
//   [6]  DIV  x7        rd=7  data=0xFFFF_FFFC
//   [7]  DIVU x8        rd=8  data=0x3333_332F
//   [8]  REM  x9        rd=9  data=0x0000_0000
//   [9]  REMU x10       rd=10 data=0x0000_0001
//   [10] ADDI x1=-1     rd=1  data=0xFFFF_FFFF
//   [11] ADDI x2=0      rd=2  data=0x0000_0000
//   [12] DIV  x11       rd=11 data=0xFFFF_FFFF  (div-by-zero)
//   [13] REM  x12       rd=12 data=0xFFFF_FFFF  (div-by-zero, rem=rs1)
//   [14] LUI  x1        rd=1  data=0x8000_0000
//   [15] ADDI x2=-1     rd=2  data=0xFFFF_FFFF
//   [16] DIV  x13       rd=13 data=0x8000_0000  (INT_MIN/-1 overflow)
//   [17] REM  x14       rd=14 data=0x0000_0000  (INT_MIN/-1 overflow)
//
// Cycle budget: 200 cycles
//   Pipeline fill: 4. 10 base cycles. 6 DIV × 33 stall = 198 stall cycles.
//   Drain: 5. Comfortable margin within 200 cycles — use 250.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_rv32m;

    logic clk = 0;
    logic rst = 1;
    always #5 clk = ~clk;

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
        .clk             (clk),
        .rst             (rst),
        .imem_addr_o     (imem_addr),
        .imem_addr_next_o(imem_addr_next),
        .imem_rdata_i    (imem_rdata),
        .dmem_addr_o     (dmem_addr),
        .dmem_ren_o      (dmem_ren),
        .dmem_wen_o      (dmem_wen),
        .dmem_wstrb_o    (dmem_wstrb),
        .dmem_wdata_o    (dmem_wdata),
        .dmem_rdata_i    (dmem_rdata),
        .dmem_stall_i    (1'b0),
        .retire_o        (retire),
        .exception_o     (exc),
        .exception_pc_o  (exc_pc)
    );

    // -----------------------------------------------------------------------
    // Instruction ROM
    // -----------------------------------------------------------------------
    always_comb begin
        case (imem_addr)
            32'h00: imem_rdata = 32'hFEC00093; // ADDI x1, x0, -20
            32'h04: imem_rdata = 32'h00500113; // ADDI x2, x0,  5
            // Multiply
            32'h08: imem_rdata = 32'h022081B3; // MUL    x3, x1, x2
            32'h0C: imem_rdata = 32'h02209233; // MULH   x4, x1, x2
            32'h10: imem_rdata = 32'h0220B2B3; // MULHU  x5, x1, x2
            32'h14: imem_rdata = 32'h0220A333; // MULHSU x6, x1, x2
            // Divide
            32'h18: imem_rdata = 32'h0220C3B3; // DIV    x7, x1, x2
            32'h1C: imem_rdata = 32'h0220D433; // DIVU   x8, x1, x2
            32'h20: imem_rdata = 32'h0220E4B3; // REM    x9, x1, x2
            32'h24: imem_rdata = 32'h0220F533; // REMU   x10, x1, x2
            // Special: divide by zero
            32'h28: imem_rdata = 32'hFFF00093; // ADDI x1, x0, -1
            32'h2C: imem_rdata = 32'h00000113; // ADDI x2, x0,  0
            32'h30: imem_rdata = 32'h0220C5B3; // DIV  x11, x1, x2
            32'h34: imem_rdata = 32'h0220E633; // REM  x12, x1, x2
            // Special: signed overflow (INT_MIN / -1)
            32'h38: imem_rdata = 32'h800000B7; // LUI  x1, 0x80000
            32'h3C: imem_rdata = 32'hFFF00113; // ADDI x2, x0, -1
            32'h40: imem_rdata = 32'h0220C6B3; // DIV  x13, x1, x2
            32'h44: imem_rdata = 32'h0220E733; // REM  x14, x1, x2
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
            $fatal(1, "[RV32M] FAIL unexpected exception: cause=%0d pc=%08h",
                   int'(exc.cause), exc_pc);
    end

    always_ff @(posedge clk) begin
        if (!rst && dmem_wen)
            $fatal(1, "[RV32M] FAIL unexpected dmem write: addr=%08h", dmem_addr);
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
        if (retire_log[idx].valid !== 1'b1)
            $fatal(1, "[RV32M] FAIL retire[%0d] %-38s not valid", idx, desc);
        if (!retire_log[idx].rd_wen)
            $fatal(1, "[RV32M] FAIL retire[%0d] %-38s rd_wen=0", idx, desc);
        if (retire_log[idx].rd_addr !== reg_idx_t'(exp_rd_addr))
            $fatal(1, "[RV32M] FAIL retire[%0d] %-38s rd_addr=%0d expected=%0d",
                   idx, desc, retire_log[idx].rd_addr, exp_rd_addr);
        if (retire_log[idx].rd_data !== exp_rd_data)
            $fatal(1, "[RV32M] FAIL retire[%0d] %-38s rd_data=%08h expected=%08h",
                   idx, desc, retire_log[idx].rd_data, exp_rd_data);
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin : stim

        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;

        // 250-cycle budget:
        //   4 fill + 18 base + 6 DIV×33 stall + 5 drain = 225; 250 is safe.
        repeat (250) @(posedge clk);
        #1;

        if (retire_cnt < 18)
            $fatal(1, "[RV32M] FAIL only %0d retirements in 250 cycles (expected >= 18)",
                   retire_cnt);

        // --- Setup ---
        chk(0,  1,  32'hFFFF_FFEC, "ADDI x1=-20");
        chk(1,  2,  32'h0000_0005, "ADDI x2=5");

        // --- Multiply ---
        chk(2,  3,  32'hFFFF_FF9C, "MUL  x3: (-20*5)[31:0]=-100");
        chk(3,  4,  32'hFFFF_FFFF, "MULH x4: signed(-20*5)>>32");
        chk(4,  5,  32'h0000_0004, "MULHU x5: unsigned product>>32");
        chk(5,  6,  32'hFFFF_FFFF, "MULHSU x6: signed×unsigned>>32");

        // --- Divide ---
        chk(6,  7,  32'hFFFF_FFFC, "DIV  x7: -20/5=-4");
        chk(7,  8,  32'h3333_332F, "DIVU x8: 0xFFFFFFEC/5");
        chk(8,  9,  32'h0000_0000, "REM  x9: -20%5=0");
        chk(9,  10, 32'h0000_0001, "REMU x10: 0xFFFFFFEC%5=1");

        // --- Divide by zero ---
        chk(10, 1,  32'hFFFF_FFFF, "ADDI x1=-1");
        chk(11, 2,  32'h0000_0000, "ADDI x2=0");
        chk(12, 11, 32'hFFFF_FFFF, "DIV  x11: -1/0 → 0xFFFFFFFF");
        chk(13, 12, 32'hFFFF_FFFF, "REM  x12: -1%0 → rs1=0xFFFFFFFF");

        // --- Signed overflow ---
        chk(14, 1,  32'h8000_0000, "LUI  x1: INT_MIN");
        chk(15, 2,  32'hFFFF_FFFF, "ADDI x2=-1");
        chk(16, 13, 32'h8000_0000, "DIV  x13: INT_MIN/-1 → INT_MIN");
        chk(17, 14, 32'h0000_0000, "REM  x14: INT_MIN%-1 → 0");

        $display("[RV32M] PASS: %0d retirements — MUL/MULH/MULHU/MULHSU/DIV/DIVU/REM/REMU all correct.",
                 retire_cnt);
        $finish;

    end : stim

endmodule : tb_rv32m

`default_nettype wire
