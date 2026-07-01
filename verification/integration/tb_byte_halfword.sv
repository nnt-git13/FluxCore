// verification/integration/tb_byte_halfword.sv
//
// Integration test: SB, SH, LB, LBU, LH, LHU — byte and halfword transfers.
//
// Exercises all sub-word memory operations end-to-end through fluxcore_top.
// Three scenarios:
//   1. Write 0xFF to byte address 0 (SB), then read back as LB (→ 0xFFFFFFFF
//      sign-extended) and LBU (→ 0x000000FF zero-extended).
//   2. Write 0x7F to byte address 1 (SB), then read back as LB (→ 0x0000007F,
//      positive so sign_ext is a no-op) and LBU (→ 0x0000007F).
//   3. Write 0xFFFF to halfword address 4 (SH), then read back as LH
//      (→ 0xFFFFFFFF sign-extended) and LHU (→ 0x0000FFFF zero-extended).
//
// DMEM timing model (SYNCHRONOUS — BRAM-accurate):
//   wb_stage.sv lines 88-94 use the live dmem_rdata_i in the WB cycle for load
//   writeback. This matches bram_dmem.sv's 1-cycle registered read latency:
//   the address is presented in the MEM stage, and the data appears in WB.
//   The testbench must use the same synchronous read model; a combinational
//   "assign dmem_rdata = dmem[addr]" would reflect the NEXT instruction's
//   address and give wrong load values.
//
// Instruction ROM (RESET_VECTOR = 0x0000_0000):
//
//   0x00: ADDI x1, x0, 255       x1 = 0xFF
//   0x04: SB x1, 0(x0)           dmem byte addr 0 ← 0xFF
//   0x08: NOP                    pipeline spacing (BRAM write committed before LB MEM)
//   0x0C: LB x2, 0(x0)           x2 = sign_ext(0xFF) = 0xFFFF_FFFF
//   0x10: LBU x3, 0(x0)          x3 = zero_ext(0xFF) = 0x0000_00FF
//   0x14: ADDI x4, x0, 127       x4 = 0x7F
//   0x18: SB x4, 1(x0)           dmem byte addr 1 ← 0x7F
//   0x1C: NOP
//   0x20: LB x5, 1(x0)           x5 = sign_ext(0x7F) = 0x0000_007F  (positive)
//   0x24: LBU x6, 1(x0)          x6 = zero_ext(0x7F) = 0x0000_007F
//   0x28: ADDI x7, x0, -1        x7 = 0xFFFF_FFFF
//   0x2C: SH x7, 4(x0)           dmem byte addr 4-5 ← 0xFFFF
//   0x30: NOP
//   0x34: LH x8, 4(x0)           x8 = sign_ext(0xFFFF) = 0xFFFF_FFFF
//   0x38: LHU x9, 4(x0)          x9 = zero_ext(0xFFFF) = 0x0000_FFFF
//   0x3C: NOP, 0x40: NOP, 0x44: NOP   (drain pipeline)
//
// Encodings (manually assembled, RV32I spec):
//   ADDI x1, x0, 255     0x0FF00093
//   SB x1, 0(x0)         0x00100023
//   NOP                  0x00000013
//   LB x2, 0(x0)         0x00000103
//   LBU x3, 0(x0)        0x00004183
//   ADDI x4, x0, 127     0x07F00213
//   SB x4, 1(x0)         0x004000A3
//   NOP                  0x00000013
//   LB x5, 1(x0)         0x00100283
//   LBU x6, 1(x0)        0x00104303
//   ADDI x7, x0, -1      0xFFF00393
//   SH x7, 4(x0)         0x00701223
//   NOP                  0x00000013
//   LH x8, 4(x0)         0x00401403
//   LHU x9, 4(x0)        0x00405483
//
// Expected retirements (NOP = ADDI x0, x0, 0 → rd_wen=0; x0 is never written):
//   [0]  ADDI x1=255     rd_wen=1  rd_addr=1   rd_data=0x0000_00FF
//   [1]  SB x1           rd_wen=0
//   [2]  NOP             rd_wen=0
//   [3]  LB x2           rd_wen=1  rd_addr=2   rd_data=0xFFFF_FFFF
//   [4]  LBU x3          rd_wen=1  rd_addr=3   rd_data=0x0000_00FF
//   [5]  ADDI x4=127     rd_wen=1  rd_addr=4   rd_data=0x0000_007F
//   [6]  SB x4           rd_wen=0
//   [7]  NOP             rd_wen=0
//   [8]  LB x5           rd_wen=1  rd_addr=5   rd_data=0x0000_007F
//   [9]  LBU x6          rd_wen=1  rd_addr=6   rd_data=0x0000_007F
//   [10] ADDI x7=-1      rd_wen=1  rd_addr=7   rd_data=0xFFFF_FFFF
//   [11] SH x7           rd_wen=0
//   [12] NOP             rd_wen=0
//   [13] LH x8           rd_wen=1  rd_addr=8   rd_data=0xFFFF_FFFF
//   [14] LHU x9          rd_wen=1  rd_addr=9   rd_data=0x0000_FFFF

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_byte_halfword;

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
    word_t             dmem_rdata;
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
    // Instruction ROM — combinational, byte-addressed
    // -----------------------------------------------------------------------
    always_comb begin
        case (imem_addr)
            32'h00: imem_rdata = 32'h0FF00093; // ADDI x1, x0, 255
            32'h04: imem_rdata = 32'h00100023; // SB   x1, 0(x0)
            32'h08: imem_rdata = 32'h00000013; // NOP
            32'h0C: imem_rdata = 32'h00000103; // LB   x2, 0(x0)
            32'h10: imem_rdata = 32'h00004183; // LBU  x3, 0(x0)
            32'h14: imem_rdata = 32'h07F00213; // ADDI x4, x0, 127
            32'h18: imem_rdata = 32'h004000A3; // SB   x4, 1(x0)
            32'h1C: imem_rdata = 32'h00000013; // NOP
            32'h20: imem_rdata = 32'h00100283; // LB   x5, 1(x0)
            32'h24: imem_rdata = 32'h00104303; // LBU  x6, 1(x0)
            32'h28: imem_rdata = 32'hFFF00393; // ADDI x7, x0, -1
            32'h2C: imem_rdata = 32'h00701223; // SH   x7, 4(x0)
            32'h30: imem_rdata = 32'h00000013; // NOP
            32'h34: imem_rdata = 32'h00401403; // LH   x8, 4(x0)
            32'h38: imem_rdata = 32'h00405483; // LHU  x9, 4(x0)
            default: imem_rdata = 32'h00000013; // NOP
        endcase
    end

    // -----------------------------------------------------------------------
    // Data memory — synchronous read, synchronous byte-enable write (BRAM model)
    //
    // wb_stage uses live dmem_rdata_i in WB cycle (see wb_stage.sv lines 88-94).
    // With BRAM: address presented in MEM → data valid in WB (1-cycle latency).
    // This model replicates bram_dmem.sv exactly (read-first: NBAs for write and
    // read fire simultaneously, so the read sees the old value when writing and
    // reading the same address in the same cycle — irrelevant here since stores
    // and loads are separated by NOPs).
    //
    // 16 words (64 bytes) at byte addresses 0x00–0x3F.
    // -----------------------------------------------------------------------
    word_t dmem [0:15];
    word_t dmem_rdata_reg = '0;

    initial begin
        foreach (dmem[i]) dmem[i] = '0;
    end

    always_ff @(posedge clk) begin
        if (dmem_wen) begin
            if (dmem_wstrb[0]) dmem[dmem_addr[5:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_wstrb[1]) dmem[dmem_addr[5:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_wstrb[2]) dmem[dmem_addr[5:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) dmem[dmem_addr[5:2]][31:24] <= dmem_wdata[31:24];
        end
        // Read-first, 1-cycle latency: captures pre-write value if same address
        // is written this cycle (matches bram_dmem.sv's NBA read).
        dmem_rdata_reg <= dmem[dmem_addr[5:2]];
    end

    assign dmem_rdata = dmem_rdata_reg;

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
            $fatal(1, "[BYTEHALF] FAIL unexpected exception: cause=%0d tval=%08h pc=%08h",
                   int'(exc.cause), exc.tval, exc_pc);
    end

    always_ff @(posedge clk) begin
        if (!rst && dmem_wen && dmem_addr[1:0] != 2'b00 && dmem_wstrb == 4'hF)
            $fatal(1, "[BYTEHALF] FAIL unaligned word write: addr=%08h", dmem_addr);
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
            $fatal(1, "[BYTEHALF] FAIL retire[%0d] %-40s not valid", idx, desc);
        if (retire_log[idx].rd_wen !== logic'(exp_rd_wen))
            $fatal(1, "[BYTEHALF] FAIL retire[%0d] %-40s rd_wen=%b expected=%0d",
                   idx, desc, retire_log[idx].rd_wen, exp_rd_wen);
        if (exp_rd_wen) begin
            if (retire_log[idx].rd_addr !== reg_idx_t'(exp_rd_addr))
                $fatal(1, "[BYTEHALF] FAIL retire[%0d] %-40s rd_addr=%0d expected=%0d",
                       idx, desc, retire_log[idx].rd_addr, exp_rd_addr);
            if (retire_log[idx].rd_data !== exp_rd_data)
                $fatal(1, "[BYTEHALF] FAIL retire[%0d] %-40s rd_data=%08h expected=%08h",
                       idx, desc, retire_log[idx].rd_data, exp_rd_data);
        end
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin : stim

        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;

        // 55 cycles: 4 pipeline fill + 15 instructions + trailing NOPs.
        repeat (55) @(posedge clk);
        #1;

        if (retire_cnt < 15)
            $fatal(1, "[BYTEHALF] FAIL only %0d retirements in 55 cycles (expected >= 15)",
                   retire_cnt);

        // --- Byte write 0xFF at addr 0 ---
        chk(0, 1, 1, 32'h0000_00FF, "ADDI x1=0xFF");
        chk(1, 0, 0, '0,            "SB x1→byte[0]");
        chk(2, 0, 0, 32'h0000_0000, "NOP (ADDI x0)");
        chk(3, 1, 2, 32'hFFFF_FFFF, "LB x2: sign_ext(0xFF)=0xFFFFFFFF");
        chk(4, 1, 3, 32'h0000_00FF, "LBU x3: zero_ext(0xFF)=0x000000FF");

        // --- Byte write 0x7F at addr 1 ---
        chk(5, 1, 4, 32'h0000_007F, "ADDI x4=0x7F");
        chk(6, 0, 0, '0,            "SB x4→byte[1]");
        chk(7, 0, 0, 32'h0000_0000, "NOP");
        chk(8, 1, 5, 32'h0000_007F, "LB x5: sign_ext(0x7F)=0x0000007F (positive)");
        chk(9, 1, 6, 32'h0000_007F, "LBU x6: zero_ext(0x7F)=0x0000007F");

        // --- Halfword write 0xFFFF at byte addr 4 ---
        chk(10, 1, 7, 32'hFFFF_FFFF, "ADDI x7=-1 (0xFFFFFFFF)");
        chk(11, 0, 0, '0,             "SH x7→half[2] (byte 4-5)");
        chk(12, 0, 0, 32'h0000_0000,  "NOP");
        chk(13, 1, 8, 32'hFFFF_FFFF,  "LH x8: sign_ext(0xFFFF)=0xFFFFFFFF");
        chk(14, 1, 9, 32'h0000_FFFF,  "LHU x9: zero_ext(0xFFFF)=0x0000FFFF");

        $display("[BYTEHALF] PASS: %0d retirements — SB/SH/LB/LBU/LH/LHU all correct.",
                 retire_cnt);
        $finish;

    end : stim

endmodule : tb_byte_halfword

`default_nettype wire
