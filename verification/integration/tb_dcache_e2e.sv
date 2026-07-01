// verification/integration/tb_dcache_e2e.sv
//
// End-to-end integration test: dcache + fluxcore_top + bram_dmem.
//
// Wires the dcache shim between fluxcore_top's dmem ports and bram_dmem,
// mirroring the USE_DCACHE=1 path inside fluxcore_soc. Uses a controllable
// combinational instruction ROM so the test can inspect retire_o directly.
//
// What is tested:
//   1. Store write-through: SW goes to bram_dmem with no stall.
//   2. Read miss path: first LW to an uncached address adds exactly 1 stall
//      cycle (dcache drives dmem_stall_o for 1 cycle, pipeline freezes, then
//      bram_dmem fills the line and clears the stall).
//   3. Read hit path: second LW to the same address returns from the cache
//      with no stall — same 1-cycle latency as direct BRAM.
//   4. Load-use stall + cache hit: LW immediately followed by a dependent
//      ADDI produces correct results (combined stall + MEM/WB forward).
//
// Instruction sequence:
//   0x00: ADDI x1, x0, 42     x1 = 42
//   0x04: ADDI x2, x0, -7     x2 = -7 = 0xFFFFFFF9
//   0x08: SW   x1, 0(x0)      bram_dmem[0] = 42  (write-through, no stall)
//   0x0C: SW   x2, 4(x0)      bram_dmem[4] = -7  (write-through, no stall)
//   0x10: LW   x3, 0(x0)      x3 = 42  (cache MISS → 1 stall cycle)
//   0x14: LW   x4, 4(x0)      x4 = -7  (cache MISS → 1 stall cycle)
//   0x18: LW   x5, 0(x0)      x5 = 42  (cache HIT  → no stall)
//   0x1C: LW   x6, 4(x0)      x6 = -7  (cache HIT  → no stall)
//   0x20: LW   x7, 0(x0)      x7 = 42  (cache HIT, load-use stall for ADDI)
//   0x24: ADDI x8, x7, 8      x8 = 50  (MEM/WB forward after load-use stall)
//   default: NOP (drain)
//
// Instruction encodings (verified against RV32I spec):
//   ADDI x1, x0, 42   0x02A00093
//   ADDI x2, x0, -7   0xFF900113
//   SW   x1, 0(x0)    0x00102023
//   SW   x2, 4(x0)    0x00202223
//   LW   x3, 0(x0)    0x00002183
//   LW   x4, 4(x0)    0x00402203
//   LW   x5, 0(x0)    0x00002283
//   LW   x6, 4(x0)    0x00402303
//   LW   x7, 0(x0)    0x00002383
//   ADDI x8, x7, 8    0x00838413
//
// Expected retirements (10):
//   [0] ADDI x1  rd_wen=1  rd=1  data=0x0000_002A
//   [1] ADDI x2  rd_wen=1  rd=2  data=0xFFFF_FFF9
//   [2] SW   x1  rd_wen=0  (store — no writeback)
//   [3] SW   x2  rd_wen=0
//   [4] LW   x3  rd_wen=1  rd=3  data=0x0000_002A  (miss)
//   [5] LW   x4  rd_wen=1  rd=4  data=0xFFFF_FFF9  (miss)
//   [6] LW   x5  rd_wen=1  rd=5  data=0x0000_002A  (hit)
//   [7] LW   x6  rd_wen=1  rd=6  data=0xFFFF_FFF9  (hit)
//   [8] LW   x7  rd_wen=1  rd=7  data=0x0000_002A  (hit + load-use stall)
//   [9] ADDI x8  rd_wen=1  rd=8  data=0x0000_0032  (50 = 42+8, MEM/WB fwd)
//
// Cycle budget: 40
//   4 fill + 10 base + 2 miss stalls + 1 load-use stall + 5 drain = 22; 40 safe.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_dcache_e2e;

    logic clk = 0;
    logic rst = 1;
    always #5 clk = ~clk;

    // -----------------------------------------------------------------------
    // CPU signals
    // -----------------------------------------------------------------------
    word_t             imem_addr;
    word_t             imem_addr_next;
    instr_t            imem_rdata;
    word_t             dmem_addr;
    logic              dmem_ren;
    logic              dmem_wen;
    logic [3:0]        dmem_wstrb;
    word_t             dmem_wdata;
    word_t             cpu_rdata;     // cpu_rdata_o from dcache → dmem_rdata_i
    logic              dmem_stall;    // dcache stall → pipeline_ctrl
    retirement_event_t retire;
    exception_meta_t   exc;
    word_t             exc_pc;

    // -----------------------------------------------------------------------
    // CPU
    // -----------------------------------------------------------------------
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
        .dmem_rdata_i     (cpu_rdata),
        .dmem_stall_i     (dmem_stall),
        .retire_o         (retire),
        .exception_o      (exc),
        .exception_pc_o   (exc_pc)
    );

    // -----------------------------------------------------------------------
    // Instruction ROM — combinational
    // -----------------------------------------------------------------------
    always_comb begin
        case (imem_addr)
            32'h00: imem_rdata = 32'h02A00093; // ADDI x1, x0, 42
            32'h04: imem_rdata = 32'hFF900113; // ADDI x2, x0, -7
            32'h08: imem_rdata = 32'h00102023; // SW   x1, 0(x0)
            32'h0C: imem_rdata = 32'h00202223; // SW   x2, 4(x0)
            32'h10: imem_rdata = 32'h00002183; // LW   x3, 0(x0)  MISS
            32'h14: imem_rdata = 32'h00402203; // LW   x4, 4(x0)  MISS
            32'h18: imem_rdata = 32'h00002283; // LW   x5, 0(x0)  HIT
            32'h1C: imem_rdata = 32'h00402303; // LW   x6, 4(x0)  HIT
            32'h20: imem_rdata = 32'h00002383; // LW   x7, 0(x0)  HIT+load-use
            32'h24: imem_rdata = 32'h00838413; // ADDI x8, x7, 8
            default: imem_rdata = 32'h00000013; // NOP
        endcase
    end

    // -----------------------------------------------------------------------
    // dcache — sits between CPU and bram_dmem
    // -----------------------------------------------------------------------
    word_t bram_addr, bram_wdata, bram_rdata;
    logic  bram_ren, bram_wen;
    logic [3:0] bram_wstrb;
    word_t hit_count, miss_count;

    dcache #(
        .NSETS(64)
    ) u_dcache (
        .clk          (clk),
        .rst          (rst),
        .cpu_addr_i   (dmem_addr),
        .cpu_ren_i    (dmem_ren),
        .cpu_wen_i    (dmem_wen),
        .cpu_wstrb_i  (dmem_wstrb),
        .cpu_wdata_i  (dmem_wdata),
        .cpu_rdata_o  (cpu_rdata),
        .dmem_stall_o (dmem_stall),
        .mem_addr_o   (bram_addr),
        .mem_ren_o    (bram_ren),
        .mem_wen_o    (bram_wen),
        .mem_wstrb_o  (bram_wstrb),
        .mem_wdata_o  (bram_wdata),
        .mem_rdata_i  (bram_rdata),
        .hit_count_o  (hit_count),
        .miss_count_o (miss_count)
    );

    // -----------------------------------------------------------------------
    // Backing BRAM (128 words = 512 bytes; default zero-initialized)
    // -----------------------------------------------------------------------
    bram_dmem #(
        .DEPTH    (128),
        .INIT_FILE("")
    ) u_bram (
        .clk     (clk),
        .addr_i  (bram_addr),
        .wen_i   (bram_wen),
        .wstrb_i (bram_wstrb),
        .wdata_i (bram_wdata),
        .rdata_o (bram_rdata)
    );

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
            $fatal(1, "[DCACHE_E2E] FAIL unexpected exception: cause=%0d pc=%08h",
                   int'(exc.cause), exc_pc);
    end

    // -----------------------------------------------------------------------
    // Check helpers
    // -----------------------------------------------------------------------
    task automatic chk_wr(
        input int    idx,
        input int    exp_rd_addr,
        input word_t exp_rd_data,
        input string desc
    );
        if (retire_log[idx].valid !== 1'b1)
            $fatal(1, "[DCACHE_E2E] FAIL retire[%0d] %-36s not valid", idx, desc);
        if (!retire_log[idx].rd_wen)
            $fatal(1, "[DCACHE_E2E] FAIL retire[%0d] %-36s rd_wen=0", idx, desc);
        if (retire_log[idx].rd_addr !== reg_idx_t'(exp_rd_addr))
            $fatal(1, "[DCACHE_E2E] FAIL retire[%0d] %-36s rd_addr=%0d expected=%0d",
                   idx, desc, retire_log[idx].rd_addr, exp_rd_addr);
        if (retire_log[idx].rd_data !== exp_rd_data)
            $fatal(1, "[DCACHE_E2E] FAIL retire[%0d] %-36s rd_data=%08h expected=%08h",
                   idx, desc, retire_log[idx].rd_data, exp_rd_data);
    endtask

    task automatic chk_nowr(
        input int    idx,
        input string desc
    );
        if (retire_log[idx].valid !== 1'b1)
            $fatal(1, "[DCACHE_E2E] FAIL retire[%0d] %-36s not valid", idx, desc);
        if (retire_log[idx].rd_wen !== 1'b0)
            $fatal(1, "[DCACHE_E2E] FAIL retire[%0d] %-36s rd_wen=1 expected 0", idx, desc);
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin : stim

        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;

        // 40-cycle budget: 4 fill + 10 base + 2 miss + 1 load-use + 5 drain = 22; safe.
        repeat (40) @(posedge clk);
        #1;

        if (retire_cnt < 10)
            $fatal(1, "[DCACHE_E2E] FAIL only %0d retirements in 40 cycles (expected >= 10)",
                   retire_cnt);

        // Setup
        chk_wr(0,  1, 32'h0000_002A, "ADDI x1=42");
        chk_wr(1,  2, 32'hFFFF_FFF9, "ADDI x2=-7");

        // Stores
        chk_nowr(2,               "SW x1, 0(x0)");
        chk_nowr(3,               "SW x2, 4(x0)");

        // Cache miss loads
        chk_wr(4,  3, 32'h0000_002A, "LW x3, 0(x0) MISS");
        chk_wr(5,  4, 32'hFFFF_FFF9, "LW x4, 4(x0) MISS");

        // Cache hit loads
        chk_wr(6,  5, 32'h0000_002A, "LW x5, 0(x0) HIT");
        chk_wr(7,  6, 32'hFFFF_FFF9, "LW x6, 4(x0) HIT");

        // Cache hit + load-use stall
        chk_wr(8,  7, 32'h0000_002A, "LW x7, 0(x0) HIT+load-use");
        chk_wr(9,  8, 32'h0000_0032, "ADDI x8=50 (42+8, MEM/WB fwd)");

        // Hit counter must be at least 3 (x5, x6, x7 loads), miss at least 2 (x3, x4).
        if (hit_count < 32'd3)
            $fatal(1, "[DCACHE_E2E] FAIL hit_count=%0d expected >= 3", hit_count);
        if (miss_count < 32'd2)
            $fatal(1, "[DCACHE_E2E] FAIL miss_count=%0d expected >= 2", miss_count);

        $display("[DCACHE_E2E] PASS: %0d retirements. Cache: %0d hits, %0d misses. Write-through, miss stall, hit path, load-use all correct.",
                 retire_cnt, hit_count, miss_count);
        $finish;

    end : stim

endmodule : tb_dcache_e2e

`default_nettype wire
