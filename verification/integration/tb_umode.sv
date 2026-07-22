// verification/integration/tb_umode.sv
//
// U-mode integration test: M sets up mtvec/mepc/MPP=U, MRETs into user
// code; user code triggers both U-mode trap classes and resumes after each.
//
//   M @0x00: ADDI x1,x0,0x100 ; CSRRW mtvec,x1
//            ADDI x2,x0,0x40  ; CSRRW mepc,x2
//            CSRRW mstatus,x0            (MPP <- 00 = U)
//            MRET                        -> U @0x40
//   U @0x40: ADDI x3,x0,33              executes in U
//            CSRRS x4,mstatus,x0        ILLEGAL from U -> trap (cause 2)
//            ADDI x5,x0,44              resumes here after handler
//            ECALL                      -> trap (cause 8 = ecall-from-U)
//            ADDI x6,x0,66              resumes here
//            NOPs
//   H @0x100: CSRRS x8,mcause ; ADD x9,x9,x8   (x9 accumulates causes)
//             CSRRS x10,mepc ; ADDI x10,x10,4 ; CSRRW mepc,x10
//             MRET                      (back to U at the skipped PC)
//
// Checks:
//   U1. x3=33, x5=44, x6=66 — U-mode code ran and resumed after both traps.
//   U2. x9 = 2 + 8 — illegal-instruction then ecall-FROM-U (the remap).
//   U3. x4 = 0 — the faulting CSR read never wrote its rd.
//   U4. exactly 2 handler entries.

`timescale 1ns/1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_umode;

    logic clk = 0;
    logic rst = 1;
    always #5 clk = ~clk;

    word_t             imem_addr, imem_addr_next;
    instr_t            imem_rdata;
    word_t             dmem_addr, dmem_wdata;
    word_t             dmem_rdata = '0;
    logic              dmem_wen, dmem_ren;
    logic [3:0]        dmem_wstrb;
    retirement_event_t retire;
    exception_meta_t   exc;
    word_t             exc_pc;

    fluxcore_top #(
        .RESET_VECTOR(32'h0000_0000),
        .TRAP_VECTOR (32'h0000_0100)
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
        .dmem_ren_o    (dmem_ren),
        .dmem_stall_i  (1'b0),
        .retire_o      (retire),
        .exception_o   (exc),
        .exception_pc_o(exc_pc)
    );

    always_comb begin
        case (imem_addr)
            // ---- M-mode setup ----
            32'h000: imem_rdata = 32'h10000093; // ADDI x1, x0, 0x100
            32'h004: imem_rdata = 32'h30509073; // CSRRW x0, mtvec, x1
            32'h008: imem_rdata = 32'h04000113; // ADDI x2, x0, 0x40
            32'h00C: imem_rdata = 32'h34111073; // CSRRW x0, mepc, x2
            32'h010: imem_rdata = 32'h30001073; // CSRRW x0, mstatus, x0 (MPP<-U)
            32'h014: imem_rdata = 32'h30200073; // MRET -> U @0x40
            // ---- U-mode code ----
            32'h040: imem_rdata = 32'h02100193; // ADDI x3, x0, 33
            32'h044: imem_rdata = 32'h30002273; // CSRRS x4, mstatus, x0 (ILLEGAL in U)
            32'h048: imem_rdata = 32'h02C00293; // ADDI x5, x0, 44
            32'h04C: imem_rdata = 32'h00000073; // ECALL (cause 8 from U)
            32'h050: imem_rdata = 32'h04200313; // ADDI x6, x0, 66
            32'h054: imem_rdata = 32'h0000006F; // JAL x0, 0 (spin: U code must
                                                // NOT fall through to 0x100)
            // ---- M-mode trap handler ----
            32'h100: imem_rdata = 32'h34202473; // CSRRS x8, mcause, x0
            32'h104: imem_rdata = 32'h008484B3; // ADD  x9, x9, x8
            32'h108: imem_rdata = 32'h34102573; // CSRRS x10, mepc, x0
            32'h10C: imem_rdata = 32'h00450513; // ADDI x10, x10, 4
            32'h110: imem_rdata = 32'h34151073; // CSRRW x0, mepc, x10
            32'h114: imem_rdata = 32'h30200073; // MRET
            default: imem_rdata = 32'h00000013; // NOP
        endcase
    end

    logic exc_prev = 0;
    always_ff @(posedge clk) begin
        exc_prev <= exc.valid;
        if (!rst && exc.valid && !exc_prev)
            $display("[EXC] t=%0t cause=%0d pc=%h tval=%h",
                     $time, exc.cause, exc_pc, exc.tval);
    end

    int handler_entries = 0;
    always_ff @(posedge clk)
        if (!rst && retire.valid && retire.pc === 32'h0000_0100)
            handler_entries <= handler_entries + 1;

    int fails = 0;
    task check(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("FAIL  %s: got 0x%08h expected 0x%08h", name, got, exp);
            fails++;
        end else $display("PASS  %s", name);
    endtask

    initial begin
        repeat (5) @(posedge clk);
        @(negedge clk); rst = 0;
        repeat (120) @(posedge clk);

        check("U1.x3 (U executes)",     dut.u_regfile.regs[3],  32'd33);
        check("U1.x5 (resume 1)",       dut.u_regfile.regs[5],  32'd44);
        check("U1.x6 (resume 2)",       dut.u_regfile.regs[6],  32'd66);
        check("U2.cause_sum (2+8)",     dut.u_regfile.regs[9],  32'd10);
        check("U3.x4 (no rd write)",    dut.u_regfile.regs[4],  32'd0);
        check("U4.handler_entries",     handler_entries,        2);

        if (fails != 0) $fatal(1, "tb_umode: FAILURES detected");
        $display("\n[UMODE] PASS: MRET->U, privileged-CSR trap, ecall-from-U remap, resume.");
        $finish;
    end

    initial begin
        #30000;
        $fatal(1, "tb_umode: timeout");
    end

endmodule : tb_umode

`default_nettype wire
