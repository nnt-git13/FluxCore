// verification/integration/tb_rv32i_alu.sv
//
// Integration test: all RV32I R-type and I-type ALU instructions end-to-end.
//
// Setup values:
//   x1 = 15  = 0x0000_000F   (ADDI x1, x0,  15)
//   x2 = -4  = 0xFFFF_FFFC   (ADDI x2, x0,  -4)
//
// R-type instructions (OPCODE_OP, funct7=0x00 / 0x20):
//   0x08: ADD   x3,  x1, x2   x3  = 15+(-4)           = 11   = 0x0000_000B
//   0x0C: SUB   x4,  x1, x2   x4  = 15-(-4)           = 19   = 0x0000_0013
//   0x10: AND   x5,  x1, x2   x5  = 0xF & 0xFFFFFFFC  = 0xC  = 0x0000_000C
//   0x14: OR    x6,  x1, x2   x6  = 0xF | 0xFFFFFFFC  = 0xFFFF_FFFF
//   0x18: XOR   x7,  x1, x2   x7  = 0xF ^ 0xFFFFFFFC  = 0xFFFF_FFF3
//   0x1C: SLL   x8,  x1, x2   x8  = 15 << 28  (x2[4:0]=28) = 0xF000_0000
//   0x20: SRL   x9,  x1, x2   x9  = 15 >> 28           = 0x0000_0000
//   0x24: SRA  x10,  x2, x1   x10 = -4 >>> 15 (x1[4:0]=15) = 0xFFFF_FFFF (-1)
//   0x28: SLT  x11,  x2, x1   x11 = signed(-4 < 15)    = 1   = 0x0000_0001
//   0x2C: SLTU x12,  x2, x1   x12 = unsigned(0xFFFFFFFC < 0xF) = 0 = 0x0000_0000
//
// I-type instructions (OPCODE_OP_IMM):
//   0x30: ANDI x13, x1,  7    x13 = 15 & 7             = 7   = 0x0000_0007
//   0x34: ORI  x14, x1, 16    x14 = 15 | 16            = 31  = 0x0000_001F
//   0x38: XORI x15, x2, -1    x15 = -4 ^ -1            = 3   = 0x0000_0003
//   0x3C: SLLI x16, x1,  2    x16 = 15 << 2            = 60  = 0x0000_003C
//   0x40: SRLI x17, x1,  1    x17 = 15 >> 1            = 7   = 0x0000_0007
//   0x44: SRAI x18, x2,  1    x18 = -4 >> 1 (arith)   = -2  = 0xFFFF_FFFE
//   0x48: SLTI  x19, x2,  0   x19 = signed(-4 < 0)     = 1   = 0x0000_0001
//   0x4C: SLTIU x20, x1, 20   x20 = unsigned(15 < 20)  = 1   = 0x0000_0001
//
// Forwarding stress chain (consecutive ADDI then ADD):
//   0x50: ADDI x21, x0, 100   x21 = 100
//   0x54: ADDI x22, x21,  1   x22 = 101  (EX/MEM forward on rs1=x21)
//   0x58: ADD  x23, x22, x21  x23 = 201  (EX/MEM: x22 in MEM; MEM/WB: x21 in WB)
//
//   default: NOP (drain)
//
// Instruction encodings (verified bit-by-bit):
//   ADDI x1, x0, 15    0x00F00093
//   ADDI x2, x0, -4    0xFFC00113
//   ADD  x3, x1, x2    0x002081B3
//   SUB  x4, x1, x2    0x40208233
//   AND  x5, x1, x2    0x0020F2B3
//   OR   x6, x1, x2    0x0020E333
//   XOR  x7, x1, x2    0x0020C3B3
//   SLL  x8, x1, x2    0x00209433
//   SRL  x9, x1, x2    0x0020D4B3
//   SRA x10, x2, x1    0x40115533
//   SLT x11, x2, x1    0x001125B3
//   SLTU x12, x2, x1   0x00113633
//   ANDI x13, x1,  7   0x0070F693
//   ORI  x14, x1, 16   0x0100E713
//   XORI x15, x2, -1   0xFFF14793
//   SLLI x16, x1,  2   0x00209813
//   SRLI x17, x1,  1   0x0010D893
//   SRAI x18, x2,  1   0x40115913
//   SLTI  x19, x2,  0  0x00012993
//   SLTIU x20, x1, 20  0x0140BA13
//   ADDI x21, x0, 100  0x06400A93
//   ADDI x22, x21,  1  0x001A8B13
//   ADD  x23, x22, x21 0x015B0BB3
//
// Expected retirements (23 instructions, no stalls):
//   [0]  ADDI x1  rd=1  0x0000_000F
//   [1]  ADDI x2  rd=2  0xFFFF_FFFC
//   [2]  ADD  x3  rd=3  0x0000_000B
//   [3]  SUB  x4  rd=4  0x0000_0013
//   [4]  AND  x5  rd=5  0x0000_000C
//   [5]  OR   x6  rd=6  0xFFFF_FFFF
//   [6]  XOR  x7  rd=7  0xFFFF_FFF3
//   [7]  SLL  x8  rd=8  0xF000_0000
//   [8]  SRL  x9  rd=9  0x0000_0000
//   [9]  SRA x10  rd=10 0xFFFF_FFFF
//   [10] SLT x11  rd=11 0x0000_0001
//   [11] SLTU x12 rd=12 0x0000_0000
//   [12] ANDI x13 rd=13 0x0000_0007
//   [13] ORI  x14 rd=14 0x0000_001F
//   [14] XORI x15 rd=15 0x0000_0003
//   [15] SLLI x16 rd=16 0x0000_003C
//   [16] SRLI x17 rd=17 0x0000_0007
//   [17] SRAI x18 rd=18 0xFFFF_FFFE
//   [18] SLTI  x19 rd=19 0x0000_0001
//   [19] SLTIU x20 rd=20 0x0000_0001
//   [20] ADDI x21  rd=21 0x0000_0064
//   [21] ADDI x22  rd=22 0x0000_0065
//   [22] ADD  x23  rd=23 0x0000_00C9
//
// Cycle budget: 50  (4 fill + 23 instr + 5 drain = 32; 50 is safe)

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_rv32i_alu;

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
        .clk              (clk),
        .rst              (rst),
        .imem_addr_o      (imem_addr),
        .imem_addr_next_o (imem_addr_next),
        .imem_rdata_i     (imem_rdata),
        .dmem_addr_o      (dmem_addr),
        .dmem_ren_o       (dmem_ren),
        .dmem_wen_o       (dmem_wen),
        .dmem_wstrb_o     (dmem_wstrb),
        .dmem_wdata_o     (dmem_wdata),
        .dmem_rdata_i     (dmem_rdata),
        .dmem_stall_i     (1'b0),
        .retire_o         (retire),
        .exception_o      (exc),
        .exception_pc_o   (exc_pc)
    );

    // -----------------------------------------------------------------------
    // Instruction ROM
    // -----------------------------------------------------------------------
    always_comb begin
        case (imem_addr)
            // Setup
            32'h00: imem_rdata = 32'h00F00093; // ADDI x1, x0, 15
            32'h04: imem_rdata = 32'hFFC00113; // ADDI x2, x0, -4
            // R-type
            32'h08: imem_rdata = 32'h002081B3; // ADD  x3, x1, x2
            32'h0C: imem_rdata = 32'h40208233; // SUB  x4, x1, x2
            32'h10: imem_rdata = 32'h0020F2B3; // AND  x5, x1, x2
            32'h14: imem_rdata = 32'h0020E333; // OR   x6, x1, x2
            32'h18: imem_rdata = 32'h0020C3B3; // XOR  x7, x1, x2
            32'h1C: imem_rdata = 32'h00209433; // SLL  x8, x1, x2
            32'h20: imem_rdata = 32'h0020D4B3; // SRL  x9, x1, x2
            32'h24: imem_rdata = 32'h40115533; // SRA x10, x2, x1
            32'h28: imem_rdata = 32'h001125B3; // SLT x11, x2, x1
            32'h2C: imem_rdata = 32'h00113633; // SLTU x12, x2, x1
            // I-type
            32'h30: imem_rdata = 32'h0070F693; // ANDI x13, x1, 7
            32'h34: imem_rdata = 32'h0100E713; // ORI  x14, x1, 16
            32'h38: imem_rdata = 32'hFFF14793; // XORI x15, x2, -1
            32'h3C: imem_rdata = 32'h00209813; // SLLI x16, x1, 2
            32'h40: imem_rdata = 32'h0010D893; // SRLI x17, x1, 1
            32'h44: imem_rdata = 32'h40115913; // SRAI x18, x2, 1
            32'h48: imem_rdata = 32'h00012993; // SLTI  x19, x2, 0
            32'h4C: imem_rdata = 32'h0140BA13; // SLTIU x20, x1, 20
            // Forwarding chain
            32'h50: imem_rdata = 32'h06400A93; // ADDI x21, x0, 100
            32'h54: imem_rdata = 32'h001A8B13; // ADDI x22, x21, 1  (EX/MEM fwd)
            32'h58: imem_rdata = 32'h015B0BB3; // ADD  x23, x22, x21 (EX/MEM+MEM/WB fwd)
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
            $fatal(1, "[ALUTEST] FAIL unexpected exception: cause=%0d pc=%08h",
                   int'(exc.cause), exc_pc);
    end

    always_ff @(posedge clk) begin
        if (!rst && dmem_wen)
            $fatal(1, "[ALUTEST] FAIL unexpected dmem write: addr=%08h", dmem_addr);
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
            $fatal(1, "[ALUTEST] FAIL retire[%0d] %-36s not valid", idx, desc);
        if (!retire_log[idx].rd_wen)
            $fatal(1, "[ALUTEST] FAIL retire[%0d] %-36s rd_wen=0", idx, desc);
        if (retire_log[idx].rd_addr !== reg_idx_t'(exp_rd_addr))
            $fatal(1, "[ALUTEST] FAIL retire[%0d] %-36s rd_addr=%0d expected=%0d",
                   idx, desc, retire_log[idx].rd_addr, exp_rd_addr);
        if (retire_log[idx].rd_data !== exp_rd_data)
            $fatal(1, "[ALUTEST] FAIL retire[%0d] %-36s rd_data=%08h expected=%08h",
                   idx, desc, retire_log[idx].rd_data, exp_rd_data);
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin : stim

        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;

        // 50-cycle budget: 4 fill + 23 instr + 5 drain = 32; 50 is safe.
        repeat (50) @(posedge clk);
        #1;

        if (retire_cnt < 23)
            $fatal(1, "[ALUTEST] FAIL only %0d retirements in 50 cycles (expected >= 23)",
                   retire_cnt);

        // Setup
        chk( 0,  1, 32'h0000_000F, "ADDI x1=15");
        chk( 1,  2, 32'hFFFF_FFFC, "ADDI x2=-4");

        // R-type
        chk( 2,  3, 32'h0000_000B, "ADD  x3: 15+(-4)=11");
        chk( 3,  4, 32'h0000_0013, "SUB  x4: 15-(-4)=19");
        chk( 4,  5, 32'h0000_000C, "AND  x5: 0xF&0xFFFFFFFC=0xC");
        chk( 5,  6, 32'hFFFF_FFFF, "OR   x6: 0xF|0xFFFFFFFC");
        chk( 6,  7, 32'hFFFF_FFF3, "XOR  x7: 0xF^0xFFFFFFFC");
        chk( 7,  8, 32'hF000_0000, "SLL  x8: 15<<28");
        chk( 8,  9, 32'h0000_0000, "SRL  x9: 15>>28=0");
        chk( 9, 10, 32'hFFFF_FFFF, "SRA x10: -4>>>15=-1");
        chk(10, 11, 32'h0000_0001, "SLT x11: signed(-4<15)=1");
        chk(11, 12, 32'h0000_0000, "SLTU x12: unsigned(0xFFFFFFFC<0xF)=0");

        // I-type
        chk(12, 13, 32'h0000_0007, "ANDI x13: 15&7=7");
        chk(13, 14, 32'h0000_001F, "ORI  x14: 15|16=31");
        chk(14, 15, 32'h0000_0003, "XORI x15: -4^-1=3");
        chk(15, 16, 32'h0000_003C, "SLLI x16: 15<<2=60");
        chk(16, 17, 32'h0000_0007, "SRLI x17: 15>>1=7");
        chk(17, 18, 32'hFFFF_FFFE, "SRAI x18: -4>>1=-2");
        chk(18, 19, 32'h0000_0001, "SLTI  x19: -4<0=1");
        chk(19, 20, 32'h0000_0001, "SLTIU x20: 15<20=1");

        // Forwarding chain
        chk(20, 21, 32'h0000_0064, "ADDI x21=100");
        chk(21, 22, 32'h0000_0065, "ADDI x22=101 (EX/MEM fwd x21)");
        chk(22, 23, 32'h0000_00C9, "ADD  x23=201 (EX/MEM x22, MEM/WB x21)");

        $display("[ALUTEST] PASS: %0d retirements — all RV32I ALU ops and forwarding paths correct.",
                 retire_cnt);
        $finish;

    end : stim

endmodule : tb_rv32i_alu

`default_nettype wire
