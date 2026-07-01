// verification/integration/tb_fluxcore_top.sv
//
// Pipeline integration test for rtl/core/fluxcore_top.sv.
//
// Two test phases, run back-to-back in a single simulation:
//
//   PHASE 1 — hazard-free smoke (8 instructions, x0 sources only):
//     Verifies correct pipeline fill, retirement ordering, and basic
//     ALU-to-regfile path with no RAW hazards.
//
//   PHASE 2 — forwarding correctness (3 dependent ADDI instructions):
//     Exercises the EX/MEM → EX and MEM/WB → EX forwarding paths.
//     All three write to x10 in consecutive instructions:
//       ADDI x10, x0, 7       x10 = 7
//       ADDI x10, x10, 3      x10 = 10   (MEM/WB → EX after stall-free forward)
//       ADDI x10, x10, 1      x10 = 11
//     A load-use stall is NOT exercised here (no load instructions in this slice).
//
// Instruction ROM layout (RESET_VECTOR = 0x0000_0000):
//
//   Phase 1 (addr 0x00 – 0x1C):
//     0x00: ADDI x1,  x0,  1        = 0x0010_0093
//     0x04: ADDI x2,  x0,  2        = 0x0020_0113
//     0x08: ADDI x3,  x0,  3        = 0x0030_0193
//     0x0C: ADDI x4,  x0,  4        = 0x0040_0213
//     0x10: ADDI x5,  x0,  5        = 0x0050_0293
//     0x14: ADDI x6,  x0,  2047     = 0x7FF0_0313
//     0x18: ADDI x7,  x0,  -1       = 0xFFF0_0393
//     0x1C: ADDI x8,  x0,  100      = 0x0640_0413
//
//   Phase 2 (addr 0x20 – 0x28):
//     0x20: ADDI x10, x0,  7        = 0x0070_0513   x10 = 7
//     0x24: ADDI x10, x10, 3        = 0x0035_0513   x10 = 10  (1-cycle dep → EX/MEM fwd)
//     0x28: ADDI x10, x10, 1        = 0x0015_0513   x10 = 11  (1-cycle dep → EX/MEM fwd)
//
//   default: NOP (ADDI x0, x0, 0)   = 0x0000_0013   fills trailing stages
//
// Encoding verification for Phase 2 (I-type: imm[11:0] | rs1[4:0] | funct3 | rd[4:0] | opcode):
//   opcode=0x13 (0010011), funct3=000 (ADDI)
//   ADDI x10, x0,  7: imm=0x007, rs1=x0 (00000), rd=x10 (01010) → 0x0000_0513 | 7<<20 = 0x0070_0513
//   ADDI x10, x10, 3: imm=0x003, rs1=x10(01010), rd=x10 (01010) → base=0x0005_0513, imm=3<<20=0x0030_0000 → 0x0035_0513
//   ADDI x10, x10, 1: imm=0x001, rs1=x10(01010), rd=x10 (01010) → 0x0015_0513
//
// Expected retirements (in program order):
//   Phase 1 (indices 0–7): rd_addr=1..8, rd_data=1,2,3,4,5,2047,0xFFFFFFFF,100
//   Phase 2 (indices 8–10): rd_addr=10, rd_data=7, 10, 11

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_fluxcore_top;

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
    word_t             dmem_rdata = '0;  // no loads in this test
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
        .dmem_ren_o    (),
        .dmem_stall_i  (1'b0),
        .retire_o      (retire),
        .exception_o   (exc),
        .exception_pc_o(exc_pc)
    );

    // -----------------------------------------------------------------------
    // Instruction ROM — combinational, byte-addressed
    // -----------------------------------------------------------------------
    always_comb begin
        case (imem_addr)
            // Phase 1: hazard-free, all read x0
            32'h00: imem_rdata = 32'h0010_0093; // ADDI x1,  x0,  1
            32'h04: imem_rdata = 32'h0020_0113; // ADDI x2,  x0,  2
            32'h08: imem_rdata = 32'h0030_0193; // ADDI x3,  x0,  3
            32'h0C: imem_rdata = 32'h0040_0213; // ADDI x4,  x0,  4
            32'h10: imem_rdata = 32'h0050_0293; // ADDI x5,  x0,  5
            32'h14: imem_rdata = 32'h7FF0_0313; // ADDI x6,  x0,  2047
            32'h18: imem_rdata = 32'hFFF0_0393; // ADDI x7,  x0, -1
            32'h1C: imem_rdata = 32'h0640_0413; // ADDI x8,  x0,  100
            // Phase 2: back-to-back RAW hazards on x10 (forward path test)
            32'h20: imem_rdata = 32'h0070_0513; // ADDI x10, x0,  7   → x10 = 7
            32'h24: imem_rdata = 32'h0035_0513; // ADDI x10, x10, 3   → x10 = 10
            32'h28: imem_rdata = 32'h0015_0513; // ADDI x10, x10, 1   → x10 = 11
            // Trailing NOPs to drain the pipeline
            default: imem_rdata = 32'h0000_0013; // NOP (ADDI x0, x0, 0)
        endcase
    end

    // -----------------------------------------------------------------------
    // Retirement log — collect up to 32 events
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
    // Liveness checks
    // -----------------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!rst && exc.valid)
            $fatal(1, "[TOP] FAIL unexpected exception: cause=%0d tval=%08h pc=%08h",
                   int'(exc.cause), exc.tval, exc_pc);
    end

    always_ff @(posedge clk) begin
        if (!rst && dmem_wen)
            $fatal(1, "[TOP] FAIL unexpected dmem write: addr=%08h wstrb=%04b data=%08h",
                   dmem_addr, dmem_wstrb, dmem_wdata);
    end

    // -----------------------------------------------------------------------
    // Check helper
    // -----------------------------------------------------------------------
    task automatic chk_retire(
        input int    idx,
        input int    exp_rd_addr,
        input word_t exp_rd_data,
        input string desc
    );
        if (!retire_log[idx].rd_wen)
            $fatal(1, "[TOP] FAIL retire[%0d] %-30s rd_wen=0 (expected 1)", idx, desc);
        if (retire_log[idx].rd_addr !== reg_idx_t'(exp_rd_addr))
            $fatal(1, "[TOP] FAIL retire[%0d] %-30s rd_addr=%0d expected=%0d",
                   idx, desc, retire_log[idx].rd_addr, exp_rd_addr);
        if (retire_log[idx].rd_data !== exp_rd_data)
            $fatal(1, "[TOP] FAIL retire[%0d] %-30s rd_data=%08h expected=%08h",
                   idx, desc, retire_log[idx].rd_data, exp_rd_data);
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin : stim

        // Hold reset for 3 rising edges
        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;

        // Run enough cycles for all 11 instructions to retire.
        // Pipeline fill: 4 cycles. 11 instructions = 11 retirements after fill.
        // With 2 forwarding instructions each back-to-back (no stall because
        // ADDI→ADDI, not load→ADDI), 11 retirements arrive by cycle ~15.
        // Run 35 cycles for margin.
        repeat (35) @(posedge clk);
        #1; // let combinational settle

        // Require at least 11 retirements
        if (retire_cnt < 11)
            $fatal(1, "[TOP] FAIL only %0d retirements in 35 cycles (expected >= 11)",
                   retire_cnt);

        // --- Phase 1: hazard-free ---
        chk_retire(0,  1,  32'h0000_0001, "P1: ADDI x1=1");
        chk_retire(1,  2,  32'h0000_0002, "P1: ADDI x2=2");
        chk_retire(2,  3,  32'h0000_0003, "P1: ADDI x3=3");
        chk_retire(3,  4,  32'h0000_0004, "P1: ADDI x4=4");
        chk_retire(4,  5,  32'h0000_0005, "P1: ADDI x5=5");
        chk_retire(5,  6,  32'h0000_07FF, "P1: ADDI x6=2047");
        chk_retire(6,  7,  32'hFFFF_FFFF, "P1: ADDI x7=-1");
        chk_retire(7,  8,  32'h0000_0064, "P1: ADDI x8=100");

        // --- Phase 2: forwarding ---
        chk_retire(8,  10, 32'h0000_0007, "P2: ADDI x10=7");
        chk_retire(9,  10, 32'h0000_000A, "P2: ADDI x10=10 (fwd)");
        chk_retire(10, 10, 32'h0000_000B, "P2: ADDI x10=11 (fwd)");

        $display("[TOP] PASS: %0d retirements — hazard-free + forwarding verified.",
                 retire_cnt);
        $finish;

    end : stim

endmodule : tb_fluxcore_top

`default_nettype wire
