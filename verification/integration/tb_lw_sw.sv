// verification/integration/tb_lw_sw.sv
//
// Integration test: SW/LW round-trip and load-use stall.
//
// Exercises the full store→load→forwarding path end-to-end through
// fluxcore_top. Two stores write test values to separate dmem words,
// three loads read them back, and the final load-dependent ADDI
// validates that the load-use stall + MEM/WB → EX forward chain
// produces the correct result.
//
// Instruction ROM (RESET_VECTOR = 0x0000_0000):
//
//   0x00: ADDI x1,  x0,  42        x1 = 42 = 0x2A
//   0x04: SW   x1,  0(x0)           dmem[0x00] = 42   (EX/MEM fwd: x1 rs2)
//   0x08: ADDI x2,  x0, -7         x2 = -7 = 0xFFFFFFF9
//   0x0C: SW   x2,  4(x0)           dmem[0x04] = -7   (EX/MEM fwd: x2 rs2)
//   0x10: LW   x3,  0(x0)           x3 = 42            (no load-use hazard)
//   0x14: LW   x4,  4(x0)           x4 = -7            (no load-use hazard)
//   0x18: LW   x5,  0(x0)           x5 = 42            (load-use stall source)
//   0x1C: ADDI x6,  x5, 8          x6 = 50  LOAD-USE STALL, MEM/WB fwd
//   default: NOP (ADDI x0, x0, 0)
//
// Instruction encodings (all verified against RV32I spec):
//   ADDI x1, x0,  42  0x02A00093
//   SW   x1, 0(x0)    0x00102023
//   ADDI x2, x0,  -7  0xFF900113
//   SW   x2, 4(x0)    0x00202223
//   LW   x3, 0(x0)    0x00002183
//   LW   x4, 4(x0)    0x00402203
//   LW   x5, 0(x0)    0x00002283
//   ADDI x6, x5, 8    0x00828313
//   NOP               0x00000013
//
// Expected retirements (in program order):
//   [0] ADDI x1: rd_wen=1, rd_addr=1,  rd_data=0x0000002A
//   [1] SW   x1: rd_wen=0 (stores don't write rd)
//   [2] ADDI x2: rd_wen=1, rd_addr=2,  rd_data=0xFFFFFFF9
//   [3] SW   x2: rd_wen=0
//   [4] LW   x3: rd_wen=1, rd_addr=3,  rd_data=0x0000002A
//   [5] LW   x4: rd_wen=1, rd_addr=4,  rd_data=0xFFFFFFF9
//   [6] LW   x5: rd_wen=1, rd_addr=5,  rd_data=0x0000002A
//   [7] ADDI x6: rd_wen=1, rd_addr=6,  rd_data=0x00000032 (50)
//
// Pipeline hazard notes:
//   ADDI x1 → SW x1 (1-instr gap): EX/MEM forward fires on rs2=x1
//   ADDI x2 → SW x2 (1-instr gap): EX/MEM forward fires on rs2=x2
//   LW x5 → ADDI x6 (0-instr gap): load-use stall, bubble inserted,
//     then MEM/WB → EX forward delivers rd_data=42 to ADDI x6
//   execute_stage fix: stores use imm for ALU operand B (address),
//     not rs2 — confirmed by alu_result = x0+offset = {0,4}

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_lw_sw;

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
    word_t             dmem_rdata;
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
            32'h00: imem_rdata = 32'h02A00093; // ADDI x1, x0, 42
            32'h04: imem_rdata = 32'h00102023; // SW   x1, 0(x0)
            32'h08: imem_rdata = 32'hFF900113; // ADDI x2, x0, -7
            32'h0C: imem_rdata = 32'h00202223; // SW   x2, 4(x0)
            32'h10: imem_rdata = 32'h00002183; // LW   x3, 0(x0)
            32'h14: imem_rdata = 32'h00402203; // LW   x4, 4(x0)
            32'h18: imem_rdata = 32'h00002283; // LW   x5, 0(x0)
            32'h1C: imem_rdata = 32'h00828313; // ADDI x6, x5, 8  (load-use stall)
            default: imem_rdata = 32'h00000013; // NOP
        endcase
    end

    // -----------------------------------------------------------------------
    // Data memory model — synchronous write (byte enable), synchronous read
    //
    // 16 words (64 bytes) mapped at byte addresses 0x00–0x3F.
    //
    // Write: fires at posedge clk when dmem_wen=1 (MEM stage presents outputs).
    //
    // Read: data is registered one cycle after the address — matching real BRAM
    // behaviour.  fluxcore_top's wb_stage consumes dmem_rdata_i combinationally
    // in the WB cycle, which is exactly one cycle after MEM presented the load
    // address.  A combinational-read model breaks loads because by WB the MEM
    // stage has advanced to the next instruction, changing dmem_addr.
    // -----------------------------------------------------------------------
    word_t dmem [0:15];

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
        dmem_rdata <= dmem[dmem_addr[5:2]];
    end

    // -----------------------------------------------------------------------
    // Retirement log — capture all valid retirements
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
            $fatal(1, "[LWSW] FAIL unexpected exception: cause=%0d tval=%08h pc=%08h",
                   int'(exc.cause), exc.tval, exc_pc);
    end

    always_ff @(posedge clk) begin
        if (!rst && dmem_addr[1:0] != 2'b00 && dmem_wen)
            $fatal(1, "[LWSW] FAIL unaligned dmem write: addr=%08h", dmem_addr);
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
            $fatal(1, "[LWSW] FAIL retire[%0d] %-30s not valid", idx, desc);
        if (retire_log[idx].rd_wen !== logic'(exp_rd_wen))
            $fatal(1, "[LWSW] FAIL retire[%0d] %-30s rd_wen=%b expected=%0d",
                   idx, desc, retire_log[idx].rd_wen, exp_rd_wen);
        if (exp_rd_wen && retire_log[idx].rd_addr !== reg_idx_t'(exp_rd_addr))
            $fatal(1, "[LWSW] FAIL retire[%0d] %-30s rd_addr=%0d expected=%0d",
                   idx, desc, retire_log[idx].rd_addr, exp_rd_addr);
        if (exp_rd_wen && retire_log[idx].rd_data !== exp_rd_data)
            $fatal(1, "[LWSW] FAIL retire[%0d] %-30s rd_data=%08h expected=%08h",
                   idx, desc, retire_log[idx].rd_data, exp_rd_data);
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin : stim

        // Hold reset for 3 rising edges, then release
        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;

        // Run 30 active cycles.
        // Pipeline fill: 4 cycles.  8 instructions.  Load-use stall: +1 cycle.
        // Last retirement (ADDI x6 at 0x1C) completes ~cycle 12 from T=0.
        repeat (30) @(posedge clk);
        #1; // let combinational settle

        // Need at least 8 retirements
        if (retire_cnt < 8)
            $fatal(1, "[LWSW] FAIL only %0d retirements in 30 cycles (expected >= 8)",
                   retire_cnt);

        // --- Retirement checks ---
        // [0] ADDI x1 = 42
        chk(0, 1, 1, 32'h0000_002A, "ADDI x1=42");
        // [1] SW x1, 0(x0) — commits but does not write rd
        chk(1, 0, 0, '0,            "SW x1 0(x0): no rd write");
        // [2] ADDI x2 = -7 = 0xFFFFFFF9
        chk(2, 1, 2, 32'hFFFF_FFF9, "ADDI x2=-7");
        // [3] SW x2, 4(x0) — commits but does not write rd
        chk(3, 0, 0, '0,            "SW x2 4(x0): no rd write");
        // [4] LW x3 = dmem[0] = 42
        chk(4, 1, 3, 32'h0000_002A, "LW x3 from dmem[0]=42");
        // [5] LW x4 = dmem[4] = -7 = 0xFFFFFFF9
        chk(5, 1, 4, 32'hFFFF_FFF9, "LW x4 from dmem[4]=-7");
        // [6] LW x5 = dmem[0] = 42 (load-use stall fires for this)
        chk(6, 1, 5, 32'h0000_002A, "LW x5 from dmem[0]=42");
        // [7] ADDI x6 = x5 + 8 = 42 + 8 = 50 = 0x32
        //     Correct result proves: load-use stall fired AND MEM/WB fwd worked
        chk(7, 1, 6, 32'h0000_0032, "ADDI x6=50 (load-use+MEM/WB fwd)");

        $display("[LWSW] PASS: %0d retirements — SW/LW round-trip and load-use stall verified.",
                 retire_cnt);
        $finish;

    end : stim

endmodule : tb_lw_sw

`default_nettype wire
