// verification/integration/tb_ecall_mret.sv
//
// Integration test: ECALL trap, M-mode CSR handler, MRET return.
//
// Verifies the complete trap-handler-return cycle:
//   1. ECALL triggers exception: pipeline flushes to mtvec=0x100; mepc=0x008;
//      mcause=EXC_ECALL_M (11).
//   2. Handler reads old mepc into x10 (proves mepc was captured), then writes
//      mepc=0x00C (ECALL_PC+4) and returns via MRET.
//   3. MRET redirects to mepc=0x00C and pipeline continues from there.
//   4. Post-trap instructions retire with the correct values, proving that
//      the MRET actually returned to the expected address.
//
// Instruction ROM (RESET_VECTOR=0x000, TRAP_VECTOR/mtvec=0x100):
//
//   0x000: ADDI x1, x0, 5          x1 = 5   (retires before trap)
//   0x004: ADDI x2, x0, 7          x2 = 7   (retires before trap)
//   0x008: ECALL                    mepc←0x008, mcause←11; redirect to 0x100
//   0x00C: ADDI x3, x0, 3          x3 = 3   (post-MRET continuation)
//   0x010: ADDI x4, x0, 4          x4 = 4
//
// Trap handler at 0x100:
//   0x100: CSRRWI x10, mepc, 12    reads old mepc→x10, writes mepc=0x00C
//   0x104: NOP (ADDI x0,x0,0)      1-cycle gap: CSR write commits in MEM stage;
//                                   mepc_o is stable before MRET reaches EX
//   0x108: MRET                     redirect to mepc=0x00C; MIE←MPIE
//   0x10C: ADDI x20, x0, 99        POISON — must be squashed by MRET flush
//
// Encoding notes:
//   ECALL          0x00000073
//   CSRRWI x10,mepc,12             0x34165573
//     csr=0x341(mepc), zimm=12=0x00C, funct3=101 (CSRRWI), rd=x10
//   MRET           0x30200073
//   ADDI x20,x0,99 0x06300A13      (poison register)
//
// Expected retirement sequence (7 events; ECALL does not retire):
//   [0] ADDI x1=5
//   [1] ADDI x2=7
//   ECALL: exception.valid=1 → retire_o.valid=0, not logged
//   [2] CSRRWI x10: wb_src=WB_CSR, rd_data=old_mepc=0x008, rd_addr=10
//   [3] NOP:        rd_wen=0
//   [4] MRET:       rd_wen=0
//   [5] ADDI x3=3   at 0x00C — proves MRET returned to correct address
//   [6] ADDI x4=4   at 0x010
//
// Poison check: ADDI x20=99 at 0x10C must never retire.
//   If it does, the MRET flush failed and the wrong path continued.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_ecall_mret;

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
        .TRAP_VECTOR (32'h0000_0100)    // mtvec initial value = handler base
    ) dut (
        .clk           (clk),
        .rst           (rst),
        .imem_addr_o      (imem_addr),
        .imem_addr_next_o (imem_addr_next),
        .imem_rdata_i     (imem_rdata),
        .dmem_addr_o   (dmem_addr),
        .dmem_wen_o    (dmem_wen),
        .dmem_wstrb_o  (dmem_wstrb),
        .dmem_wdata_o  (dmem_wdata),
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
            // ---- main code ----
            32'h000: imem_rdata = 32'h0050_0093; // ADDI x1,  x0,  5
            32'h004: imem_rdata = 32'h0070_0113; // ADDI x2,  x0,  7
            32'h008: imem_rdata = 32'h0000_0073; // ECALL
            32'h00C: imem_rdata = 32'h0030_0193; // ADDI x3,  x0,  3  (post-MRET)
            32'h010: imem_rdata = 32'h0040_0213; // ADDI x4,  x0,  4
            // ---- trap handler at mtvec=0x100 ----
            32'h100: imem_rdata = 32'h3416_5573; // CSRRWI x10, mepc(0x341), 12
            32'h104: imem_rdata = 32'h0000_0013; // NOP (CSR write gap)
            32'h108: imem_rdata = 32'h3020_0073; // MRET
            32'h10C: imem_rdata = 32'h0630_0A13; // ADDI x20, x0, 99   POISON
            default: imem_rdata = 32'h0000_0013; // NOP
        endcase
    end

    // -----------------------------------------------------------------------
    // Retirement log (max 32 entries)
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
    // Exception capture: latch the first exception committed by wb_stage.
    // Used to verify mepc (exc_pc) and cause after the run completes.
    // -----------------------------------------------------------------------
    logic       exc_seen     = 0;
    exc_cause_e exc_cause_q  = EXC_ECALL_M;  // initialised to expected value
    word_t      exc_pc_q     = '0;

    always_ff @(posedge clk) begin
        if (!rst && exc.valid && !exc_seen) begin
            exc_seen    <= 1'b1;
            exc_cause_q <= exc.cause;
            exc_pc_q    <= exc_pc;
        end
    end

    // -----------------------------------------------------------------------
    // Liveness guard: no unexpected dmem writes
    // -----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst && dmem_wen)
            $fatal(1, "[ECALL-MRET] FAIL unexpected dmem write (no stores in this test)");
    end

    // -----------------------------------------------------------------------
    // Poison check: ADDI x20=99 at 0x10C must never retire.
    // If it does, MRET failed to flush the pipeline and the wrong-path ran.
    // -----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst && retire.valid && retire.rd_wen
                && retire.rd_addr == 5'd20 && retire.rd_data == 32'd99)
            $fatal(1, "[ECALL-MRET] FAIL poison retired (ADDI x20=99) — MRET flush did not squash 0x10C");
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
            $fatal(1, "[ECALL-MRET] FAIL retire[%0d] %-40s not valid", idx, desc);
        if (retire_log[idx].rd_wen !== logic'(exp_rd_wen))
            $fatal(1, "[ECALL-MRET] FAIL retire[%0d] %-40s rd_wen=%b expected=%0d",
                   idx, desc, retire_log[idx].rd_wen, exp_rd_wen);
        if (exp_rd_wen) begin
            if (retire_log[idx].rd_addr !== reg_idx_t'(exp_rd_addr))
                $fatal(1, "[ECALL-MRET] FAIL retire[%0d] %-40s rd_addr=%0d expected=%0d",
                       idx, desc, retire_log[idx].rd_addr, exp_rd_addr);
            if (retire_log[idx].rd_data !== exp_rd_data)
                $fatal(1, "[ECALL-MRET] FAIL retire[%0d] %-40s rd_data=0x%08h expected=0x%08h",
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

        // Allow 60 active cycles:
        // 2 pre-trap ADDIs (retire cycles 5-6) + ECALL pipeline drain (~4)
        // + redirect to 0x100 + 3 handler instrs (~4+4+5) + 4 post-MRET instrs
        // = ~30 cycles.  60 gives comfortable margin.
        repeat (60) @(posedge clk);
        #1;

        // ---- Liveness: enough retirements ----
        if (retire_cnt < 7)
            $fatal(1, "[ECALL-MRET] FAIL only %0d retirements, expected >= 7", retire_cnt);

        // ---- Exception was seen ----
        if (!exc_seen)
            $fatal(1, "[ECALL-MRET] FAIL no exception committed to WB — ECALL did not trap");
        if (exc_cause_q !== EXC_ECALL_M)
            $fatal(1, "[ECALL-MRET] FAIL exception cause=%0d expected EXC_ECALL_M=%0d",
                   int'(exc_cause_q), int'(EXC_ECALL_M));
        if (exc_pc_q !== 32'h0000_0008)
            $fatal(1, "[ECALL-MRET] FAIL exception_pc=0x%08h expected 0x00000008 — mepc wrong",
                   exc_pc_q);

        // ---- Retirement sequence ----
        // [0] Pre-trap: ADDI x1=5 at 0x000
        chk(0, 1,  1, 32'd5,       "ADDI x1=5 before ECALL");
        // [1] Pre-trap: ADDI x2=7 at 0x004
        chk(1, 1,  2, 32'd7,       "ADDI x2=7 before ECALL");
        // ECALL at 0x008: does NOT retire (exception.valid=1 suppresses retire_o.valid)
        // [2] Handler: CSRRWI x10, mepc, 12 at 0x100
        //     wb_src=WB_CSR → rd_data = old mepc captured at trap = 0x008
        //     This proves mepc was set to the ECALL's PC by the trap logic.
        chk(2, 1, 10, 32'h0000_0008, "CSRRWI: old mepc=0x008 returned to x10");
        // [3] Handler: NOP at 0x104
        chk(3, 0,  0, 32'd0,       "NOP: no rd write (CSR commit gap)");
        // [4] Handler: MRET at 0x108  (redirect to mepc=0x00C already issued 2 cycles before WB)
        chk(4, 0,  0, 32'd0,       "MRET: no rd write");
        // [5] Post-MRET: ADDI x3=3 at 0x00C
        //     Retiring proves MRET redirected to 0x00C and not to the wrong address.
        chk(5, 1,  3, 32'd3,       "ADDI x3=3 at 0x00C: MRET returned to correct PC");
        // [6] Post-MRET: ADDI x4=4 at 0x010
        chk(6, 1,  4, 32'd4,       "ADDI x4=4 at 0x010");

        $display("[ECALL-MRET] PASS: trap, CSR handler, and MRET return all verified.");
        $display("[ECALL-MRET]   ECALL @ 0x008 → mtvec=0x100; mepc=0x008 captured.");
        $display("[ECALL-MRET]   Handler wrote mepc=0x00C; MRET returned there.");
        $display("[ECALL-MRET]   ADDI x3=3 @ 0x00C proves correct return address.");
        $finish;

    end : stim

    // -----------------------------------------------------------------------
    // Timeout
    // -----------------------------------------------------------------------
    initial begin
        #100_000;
        $fatal(1, "[ECALL-MRET] TIMEOUT after 100 us — simulation hung");
    end

endmodule : tb_ecall_mret

`default_nettype wire
