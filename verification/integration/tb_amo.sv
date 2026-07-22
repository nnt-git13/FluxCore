// verification/integration/tb_amo.sv
//
// RV32A integration test on fluxcore_top (combinational ROM + BRAM-style
// dmem model, mirroring tb_lw_sw's harness).
//
// Program (RESET_VECTOR = 0; all atomics target mem[0x20]):
//   0x00  ADDI  x1, x0, 0x20     base address
//   0x04  ADDI  x2, x0, 5
//   0x08  SW    x2, 0(x1)        mem = 5
//   0x0C  LR.W  x3, (x1)         x3 = 5, reservation set
//   0x10  ADDI  x4, x0, 7
//   0x14  SC.W  x5, x4, (x1)     succeeds: mem = 7, x5 = 0
//   0x18  SC.W  x6, x2, (x1)     fails (reservation consumed): x6 = 1
//   0x1C  AMOADD.W  x7, x2, (x1) x7 = 7  (old), mem = 12
//   0x20  AMOSWAP.W x8, x2, (x1) x8 = 12 (old), mem = 5
//   0x24  AMOMAX.W  x9, x4, (x1) x9 = 5  (old), mem = max(5,7) = 7
//   0x28  LW    x10, 0(x1)       x10 = 7
//   0x2C  LR.W  x11, (x1)        x11 = 7, reservation set
//   0x30  SW    x2, 0(x1)        intervening store: mem = 5, reservation CLEARED
//   0x34  SC.W  x12, x4, (x1)    fails: x12 = 1, mem still 5
//   0x38  AMOADD.W x13, x3, (x1) forwarding: x13 = 5 (old), mem = 10
//   0x3C  ADDI  x14, x13, 1      load-use-style hazard on AMO rd: x14 = 6
//   0x40+ NOP
//
// Checks: every x-register above + final memory word + retirement count.

`timescale 1ns/1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_amo;

    logic clk = 0;
    logic rst = 1;
    always #5 clk = ~clk;

    word_t             imem_addr, imem_addr_next;
    instr_t            imem_rdata;
    word_t             dmem_addr, dmem_wdata, dmem_rdata;
    logic              dmem_wen, dmem_ren;
    logic [3:0]        dmem_wstrb;
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
        .dmem_ren_o    (dmem_ren),
        .dmem_stall_i  (1'b0),
        .retire_o      (retire),
        .exception_o   (exc),
        .exception_pc_o(exc_pc)
    );

    always_comb begin
        case (imem_addr)
            32'h00: imem_rdata = 32'h02000093; // ADDI x1, x0, 0x20
            32'h04: imem_rdata = 32'h00500113; // ADDI x2, x0, 5
            32'h08: imem_rdata = 32'h0020A023; // SW   x2, 0(x1)
            32'h0C: imem_rdata = 32'h1000A1AF; // LR.W x3, (x1)
            32'h10: imem_rdata = 32'h00700213; // ADDI x4, x0, 7
            32'h14: imem_rdata = 32'h1840A2AF; // SC.W x5, x4, (x1)
            32'h18: imem_rdata = 32'h1820A32F; // SC.W x6, x2, (x1)
            32'h1C: imem_rdata = 32'h0020A3AF; // AMOADD.W  x7, x2, (x1)
            32'h20: imem_rdata = 32'h0820A42F; // AMOSWAP.W x8, x2, (x1)
            32'h24: imem_rdata = 32'hA040A4AF; // AMOMAX.W  x9, x4, (x1)
            32'h28: imem_rdata = 32'h0000A503; // LW   x10, 0(x1)
            32'h2C: imem_rdata = 32'h1000A5AF; // LR.W x11, (x1)
            32'h30: imem_rdata = 32'h0020A023; // SW   x2, 0(x1)
            32'h34: imem_rdata = 32'h1840A62F; // SC.W x12, x4, (x1)
            32'h38: imem_rdata = 32'h0030A6AF; // AMOADD.W x13, x3, (x1)
            32'h3C: imem_rdata = 32'h00168713; // ADDI x14, x13, 1
            default: imem_rdata = 32'h00000013; // NOP
        endcase
    end

    // BRAM-style dmem: registered read, byte-enable write (16 words).
    word_t dmem [0:15];
    always_ff @(posedge clk) begin
        if (dmem_wen) begin
            if (dmem_wstrb[0]) dmem[dmem_addr[5:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_wstrb[1]) dmem[dmem_addr[5:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_wstrb[2]) dmem[dmem_addr[5:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) dmem[dmem_addr[5:2]][31:24] <= dmem_wdata[31:24];
        end
        dmem_rdata <= dmem[dmem_addr[5:2]];
    end

    int fails = 0;
    task check(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("FAIL  %s: got 0x%08h expected 0x%08h", name, got, exp);
            fails++;
        end else $display("PASS  %s", name);
    endtask

    int exc_seen = 0;
    always_ff @(posedge clk) if (!rst && exc.valid) exc_seen <= exc_seen + 1;

    // Debug: report each exception once
    always_ff @(posedge clk)
        if (!rst && exc.valid)
            $display("[EXC] t=%0t cause=%0d pc=%h tval=%h",
                     $time, exc.cause, exc_pc, exc.tval);

    initial begin
        for (int i = 0; i < 16; i++) dmem[i] = '0;
        repeat (5) @(posedge clk);
        @(negedge clk); rst = 0;
        repeat (80) @(posedge clk);

        check("x3  (LR old)",        dut.u_regfile.regs[3],  32'd5);
        check("x5  (SC ok flag)",    dut.u_regfile.regs[5],  32'd0);
        check("x6  (SC fail flag)",  dut.u_regfile.regs[6],  32'd1);
        check("x7  (AMOADD old)",    dut.u_regfile.regs[7],  32'd7);
        check("x8  (AMOSWAP old)",   dut.u_regfile.regs[8],  32'd12);
        check("x9  (AMOMAX old)",    dut.u_regfile.regs[9],  32'd5);
        check("x10 (LW)",            dut.u_regfile.regs[10], 32'd7);
        check("x11 (LR2 old)",       dut.u_regfile.regs[11], 32'd7);
        check("x12 (SC after store)",dut.u_regfile.regs[12], 32'd1);
        check("x13 (AMOADD fwd)",    dut.u_regfile.regs[13], 32'd5);
        check("x14 (hazard on AMO)", dut.u_regfile.regs[14], 32'd6);
        check("mem[0x20] final",     dmem[8],                32'd10);
        check("no exceptions",       exc_seen,               0);

        if (fails != 0) $fatal(1, "tb_amo: FAILURES detected");
        $display("\n[AMO] PASS: LR/SC, all AMO ops, reservation clearing, hazards verified.");
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "tb_amo: timeout");
    end

endmodule : tb_amo

`default_nettype wire
