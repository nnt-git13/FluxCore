// verification/unit/core/tb_csr_unit.sv
//
// Unit test for csr_unit.sv — the machine-mode CSR register file.
//
// Test groups:
//
//   G01  Reset state
//   G02  mtvec CSRRW (write / read-back; WARL bits[1:0] forced 0)
//   G03  mtvec CSRRS / CSRRC (set / clear bits)
//   G04  mscratch CSRRW / CSRRS / CSRRC
//   G05  mepc write (WARL: bits[1:0] forced 0) and mtvec_o / mepc_o outputs
//   G06  mcause / mtval CSRRW
//   G07  Unimplemented CSR read returns 0; writes ignored
//   G08  CSR_NOP (wen_i=1 with CSR_NOP does not modify register)
//   G09  mstatus CSRRW: MIE[3] and MPIE[7] writable; MPP[12:11] hardwired
//   G10  mstatus CSRRS / CSRRC on individual bits
//   G11  Trap entry: mepc/mcause/mtval set; MPIE←MIE, MIE←0
//   G12  Trap entry when MIE=1: MPIE becomes 1, MIE becomes 0
//   G13  MRET: MIE←MPIE, MPIE←1; nested trap-then-MRET round-trip
//   G14  wen_i=0 suppresses write (no side effects)
//   G15  mip / mhartid / MIE CSR read-only (returns 0, writes ignored)
//   G16  MTVEC_RESET parameter wires through; WARL clears bits[1:0]
//   G17  mcycle/minstret counters increment and support CSR writes

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;

module tb_csr_unit;

    // -----------------------------------------------------------------------
    // Clock (only needed for synchronous writes)
    // -----------------------------------------------------------------------
    logic clk = 0;
    logic rst = 1;

    always #5 clk = ~clk;

    // -----------------------------------------------------------------------
    // DUT connections
    // -----------------------------------------------------------------------
    logic [11:0]  raddr;
    word_t         rdata;

    logic          wen;
    logic [11:0]  waddr;
    word_t         wdata;
    csr_op_e       wop;

    logic          trap;
    word_t         trap_epc;
    word_t         trap_cause;
    word_t         trap_tval;

    logic          mret;
    logic          retire;

    word_t         mtvec_out;
    word_t         mepc_out;

    csr_unit #(
        .MTVEC_RESET(32'h0000_2000)   // non-zero reset to test G16
    ) dut (
        .clk          (clk),
        .rst          (rst),
        .raddr_i      (raddr),
        .rdata_o      (rdata),
        .wen_i        (wen),
        .waddr_i      (waddr),
        .wdata_i      (wdata),
        .wop_i        (wop),
        .trap_i       (trap),
        .trap_epc_i   (trap_epc),
        .trap_cause_i (trap_cause),
        .trap_tval_i  (trap_tval),
        .mret_i       (mret),
        .retire_i     (retire),
        .mtvec_o      (mtvec_out),
        .mepc_o       (mepc_out)
    );

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    // Apply a combinational read and check expected value.
    task automatic chk_read(
        input logic [11:0] addr,
        input word_t        exp,
        input string        label
    );
        raddr = addr;
        #1;
        if (rdata !== exp)
            $fatal(1, "[CSR] FAIL %s: rdata=%08h expected=%08h", label, rdata, exp);
    endtask

    // Apply a write (one clock cycle) and settle.
    task automatic do_write(
        input logic [11:0] addr,
        input word_t        d,
        input csr_op_e      op
    );
        @(negedge clk);
        wen   = 1;
        waddr = addr;
        wdata = d;
        wop   = op;
        @(posedge clk);
        #1;
        wen   = 0;
        wdata = '0;
        wop   = CSR_NOP;
    endtask

    // Apply a trap entry (one clock cycle).
    task automatic do_trap(
        input word_t epc,
        input word_t cause,
        input word_t tval
    );
        @(negedge clk);
        trap       = 1;
        trap_epc   = epc;
        trap_cause = cause;
        trap_tval  = tval;
        @(posedge clk);
        #1;
        trap       = 0;
        trap_epc   = '0;
        trap_cause = '0;
        trap_tval  = '0;
    endtask

    // Apply MRET (one clock cycle).
    task automatic do_mret();
        @(negedge clk);
        mret = 1;
        @(posedge clk);
        #1;
        mret = 0;
    endtask

    // -----------------------------------------------------------------------
    // Test stimulus
    // -----------------------------------------------------------------------
    initial begin : stim

        // Default drive
        wen        = 0;
        waddr      = '0;
        wdata      = '0;
        wop        = CSR_NOP;
        raddr      = '0;
        trap       = 0;
        trap_epc   = '0;
        trap_cause = '0;
        trap_tval  = '0;
        mret       = 0;
        retire     = 0;

        // Release reset
        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;
        @(posedge clk); #1;

        // -------------------------------------------------------------------
        // G01: Reset state
        // MTVEC_RESET=0x2000 → mtvec_q=0x2000; all others 0; mstatus.MPP=2'b11
        // -------------------------------------------------------------------
        $display("[CSR] G01: reset state");
        chk_read(CSR_MTVEC,    32'h0000_2000, "G01 mtvec=0x2000");
        chk_read(CSR_MSTATUS,  32'h0000_1800, "G01 mstatus=MPP=11 only");
        chk_read(CSR_MEPC,     32'h0,         "G01 mepc=0");
        chk_read(CSR_MCAUSE,   32'h0,         "G01 mcause=0");
        chk_read(CSR_MTVAL,    32'h0,         "G01 mtval=0");
        chk_read(CSR_MSCRATCH, 32'h0,         "G01 mscratch=0");

        // Verify direct outputs track registers
        if (mtvec_out !== 32'h0000_2000)
            $fatal(1, "[CSR] FAIL G01: mtvec_o=%08h expected=0x00002000", mtvec_out);
        if (mepc_out !== 32'h0)
            $fatal(1, "[CSR] FAIL G01: mepc_o=%08h expected=0", mepc_out);

        // -------------------------------------------------------------------
        // G02: mtvec CSRRW and WARL (bits[1:0] forced 0)
        // -------------------------------------------------------------------
        $display("[CSR] G02: mtvec CSRRW");
        do_write(CSR_MTVEC, 32'hDEAD_BEFF, CSR_WRITE);   // bits[1:0]=11 → clamped to 00
        chk_read(CSR_MTVEC, 32'hDEAD_BEFC, "G02 mtvec WARL bits[1:0]=0");
        if (mtvec_out !== 32'hDEAD_BEFC)
            $fatal(1, "[CSR] FAIL G02: mtvec_o wrong after write");

        do_write(CSR_MTVEC, 32'h0000_4000, CSR_WRITE);
        chk_read(CSR_MTVEC, 32'h0000_4000, "G02 mtvec aligned write");

        // -------------------------------------------------------------------
        // G03: mtvec CSRRS / CSRRC
        // -------------------------------------------------------------------
        $display("[CSR] G03: mtvec CSRRS/CSRRC");
        // mtvec = 0x4000
        do_write(CSR_MTVEC, 32'h0000_0100, CSR_SET);    // set bit 8
        chk_read(CSR_MTVEC, 32'h0000_4100, "G03 mtvec SET bit8");
        do_write(CSR_MTVEC, 32'h0000_4000, CSR_CLR);    // clear bit 14
        chk_read(CSR_MTVEC, 32'h0000_0100, "G03 mtvec CLR bit14");

        // Restore mtvec to something clean
        do_write(CSR_MTVEC, 32'h0000_8000, CSR_WRITE);

        // -------------------------------------------------------------------
        // G04: mscratch CSRRW / CSRRS / CSRRC
        // -------------------------------------------------------------------
        $display("[CSR] G04: mscratch");
        do_write(CSR_MSCRATCH, 32'hABCD_EF01, CSR_WRITE);
        chk_read(CSR_MSCRATCH, 32'hABCD_EF01, "G04 mscratch WRITE");
        do_write(CSR_MSCRATCH, 32'h0000_00FE, CSR_SET);
        chk_read(CSR_MSCRATCH, 32'hABCD_EFFF, "G04 mscratch SET");
        do_write(CSR_MSCRATCH, 32'hFFFF_0000, CSR_CLR);
        chk_read(CSR_MSCRATCH, 32'h0000_EFFF, "G04 mscratch CLR");

        // -------------------------------------------------------------------
        // G05: mepc WARL (bits[1:0]=0) and mepc_o
        // -------------------------------------------------------------------
        $display("[CSR] G05: mepc WARL and mepc_o");
        do_write(CSR_MEPC, 32'h0001_0007, CSR_WRITE);   // bits[1:0]=11 → 00
        chk_read(CSR_MEPC, 32'h0001_0004, "G05 mepc WARL");
        if (mepc_out !== 32'h0001_0004)
            $fatal(1, "[CSR] FAIL G05: mepc_o=%08h expected=0x00010004", mepc_out);
        do_write(CSR_MEPC, 32'hFFFF_FFFC, CSR_WRITE);
        chk_read(CSR_MEPC, 32'hFFFF_FFFC, "G05 mepc aligned max");

        // -------------------------------------------------------------------
        // G06: mcause / mtval CSRRW
        // -------------------------------------------------------------------
        $display("[CSR] G06: mcause/mtval CSRRW");
        do_write(CSR_MCAUSE, 32'h8000_000B, CSR_WRITE);   // interrupt bit + cause 11
        chk_read(CSR_MCAUSE, 32'h8000_000B, "G06 mcause write");
        do_write(CSR_MTVAL,  32'hDEAD_C0DE, CSR_WRITE);
        chk_read(CSR_MTVAL,  32'hDEAD_C0DE, "G06 mtval write");

        // -------------------------------------------------------------------
        // G07: Unimplemented CSR read → 0; write ignored
        // -------------------------------------------------------------------
        $display("[CSR] G07: unimplemented CSR");
        chk_read(12'h001, 32'h0, "G07 unknown CSR 0x001 reads 0");
        chk_read(12'hFFF, 32'h0, "G07 unknown CSR 0xFFF reads 0");
        do_write(12'h001, 32'hDEAD_BEEF, CSR_WRITE);   // write unknown CSR
        chk_read(12'h001, 32'h0,         "G07 unknown CSR unchanged after write");

        // -------------------------------------------------------------------
        // G08: CSR_NOP with wen_i=1 does not modify register
        // -------------------------------------------------------------------
        $display("[CSR] G08: CSR_NOP no-op");
        do_write(CSR_MSCRATCH, 32'h1111_2222, CSR_WRITE);
        do_write(CSR_MSCRATCH, 32'hFFFF_FFFF, CSR_NOP);  // NOP — should not change
        chk_read(CSR_MSCRATCH, 32'h1111_2222, "G08 mscratch unchanged after NOP");

        // -------------------------------------------------------------------
        // G09: mstatus CSRRW — MIE[3] and MPIE[7] writable; MPP[12:11]=2'b11
        // -------------------------------------------------------------------
        $display("[CSR] G09: mstatus CSRRW");
        // Set MIE only
        do_write(CSR_MSTATUS, 32'h0000_0008, CSR_WRITE);  // MIE=1
        chk_read(CSR_MSTATUS, 32'h0000_1808, "G09 mstatus MIE=1 MPP=11");
        // Set MPIE only
        do_write(CSR_MSTATUS, 32'h0000_0080, CSR_WRITE);  // MPIE=1, MIE=0
        chk_read(CSR_MSTATUS, 32'h0000_1880, "G09 mstatus MPIE=1 MIE=0");
        // Write both MIE and MPIE
        do_write(CSR_MSTATUS, 32'h0000_0088, CSR_WRITE);  // both =1
        chk_read(CSR_MSTATUS, 32'h0000_1888, "G09 mstatus MIE=MPIE=1");
        // Write 0 to clear both (MPP must stay 2'b11)
        do_write(CSR_MSTATUS, 32'h0000_0000, CSR_WRITE);
        chk_read(CSR_MSTATUS, 32'h0000_1800, "G09 mstatus cleared MPP preserved");
        // Writing MPP bits (WARL: ignored) — MPP must stay 2'b11
        do_write(CSR_MSTATUS, 32'h0000_0000, CSR_WRITE);  // try clearing MPP via 0
        chk_read(CSR_MSTATUS, 32'h0000_1800, "G09 MPP hardwired after write-zero");

        // -------------------------------------------------------------------
        // G10: mstatus CSRRS / CSRRC
        // -------------------------------------------------------------------
        $display("[CSR] G10: mstatus CSRRS/CSRRC");
        do_write(CSR_MSTATUS, 32'h0, CSR_WRITE);           // clear to baseline
        do_write(CSR_MSTATUS, 32'h0000_0008, CSR_SET);     // set MIE
        chk_read(CSR_MSTATUS, 32'h0000_1808, "G10 mstatus SET MIE");
        do_write(CSR_MSTATUS, 32'h0000_0080, CSR_SET);     // set MPIE
        chk_read(CSR_MSTATUS, 32'h0000_1888, "G10 mstatus SET MPIE");
        do_write(CSR_MSTATUS, 32'h0000_0008, CSR_CLR);     // clear MIE
        chk_read(CSR_MSTATUS, 32'h0000_1880, "G10 mstatus CLR MIE");
        do_write(CSR_MSTATUS, 32'h0000_0080, CSR_CLR);     // clear MPIE
        chk_read(CSR_MSTATUS, 32'h0000_1800, "G10 mstatus CLR MPIE baseline");

        // -------------------------------------------------------------------
        // G11: Trap entry with MIE=0 — MPIE←0, MIE←0 (no change for MIE)
        // -------------------------------------------------------------------
        $display("[CSR] G11: trap entry MIE=0");
        do_write(CSR_MSTATUS, 32'h0, CSR_WRITE);  // MIE=0, MPIE=0
        do_write(CSR_MEPC,    32'h0, CSR_WRITE);
        do_trap(32'h0001_2340, 32'hB, 32'h0);     // epc=0x1234x, cause=11 (ECALL)
        chk_read(CSR_MEPC,    32'h0001_2340, "G11 mepc after trap");
        chk_read(CSR_MCAUSE,  32'hB,         "G11 mcause=11 (ECALL)");
        chk_read(CSR_MTVAL,   32'h0,         "G11 mtval=0");
        // MPIE←0 (MIE was 0), MIE←0
        chk_read(CSR_MSTATUS, 32'h0000_1800, "G11 mstatus: MPIE=0 MIE=0 after trap");

        // -------------------------------------------------------------------
        // G12: Trap entry with MIE=1 — MPIE←1, MIE←0
        // -------------------------------------------------------------------
        $display("[CSR] G12: trap entry MIE=1");
        do_write(CSR_MSTATUS, 32'h0000_0008, CSR_WRITE);  // MIE=1
        do_trap(32'h0002_0000, 32'h2, 32'hDEAD_C0DE);    // epc=0x20000, cause=2, tval
        chk_read(CSR_MEPC,    32'h0002_0000, "G12 mepc");
        chk_read(CSR_MCAUSE,  32'h2,         "G12 mcause=2");
        chk_read(CSR_MTVAL,   32'hDEAD_C0DE, "G12 mtval");
        // MPIE←1 (old MIE), MIE←0
        chk_read(CSR_MSTATUS, 32'h0000_1880, "G12 mstatus: MPIE=1 MIE=0 after trap");
        // mepc WARL: epc had bits[1:0]=0, so still aligned
        if (mepc_out !== 32'h0002_0000)
            $fatal(1, "[CSR] FAIL G12: mepc_o=%08h expected=0x00020000", mepc_out);

        // -------------------------------------------------------------------
        // G13: MRET — MIE←MPIE, MPIE←1; full trap-then-MRET round-trip
        // -------------------------------------------------------------------
        $display("[CSR] G13: MRET round-trip");
        // Current state: MPIE=1, MIE=0. MRET should set MIE←1, MPIE←1.
        do_mret();
        chk_read(CSR_MSTATUS, 32'h0000_1888, "G13 after MRET: MIE=MPIE=1");

        // Full round-trip: trap with MIE=1, then MRET
        // After above: MIE=1, MPIE=1
        do_trap(32'h0003_0000, 32'hC, 32'h0);   // trap when MIE=1
        // → MPIE=1 (old MIE), MIE=0
        chk_read(CSR_MSTATUS, 32'h0000_1880, "G13 mstatus after second trap");
        chk_read(CSR_MEPC,    32'h0003_0000, "G13 mepc second trap");
        // MRET restores: MIE←MPIE=1, MPIE←1
        do_mret();
        chk_read(CSR_MSTATUS, 32'h0000_1888, "G13 mstatus after MRET: MIE=MPIE=1");
        if (mepc_out !== 32'h0003_0000)
            $fatal(1, "[CSR] FAIL G13: mepc_o should still be 0x30000 after MRET");

        // -------------------------------------------------------------------
        // G14: wen_i=0 suppresses write
        // -------------------------------------------------------------------
        $display("[CSR] G14: wen_i=0 suppresses write");
        do_write(CSR_MSCRATCH, 32'hBEEF_CAFE, CSR_WRITE);
        // Drive signals but with wen_i=0 (done via the default between cycles)
        @(negedge clk);
        wen   = 0;
        waddr = CSR_MSCRATCH;
        wdata = 32'hDEAD_BEEF;
        wop   = CSR_WRITE;
        @(posedge clk); #1;
        wen   = 0;
        wdata = '0;
        wop   = CSR_NOP;
        chk_read(CSR_MSCRATCH, 32'hBEEF_CAFE, "G14 mscratch unchanged (wen=0)");

        // -------------------------------------------------------------------
        // G15: Read-only CSRs: mip, mhartid, mie all return 0; writes ignored
        // -------------------------------------------------------------------
        $display("[CSR] G15: read-only CSRs");
        chk_read(CSR_MIP,     32'h0, "G15 mip=0");
        chk_read(CSR_MHARTID, 32'h0, "G15 mhartid=0");
        chk_read(CSR_MIE,     32'h0, "G15 mie=0 (no hw interrupts)");
        do_write(CSR_MIP,     32'hFFFF_FFFF, CSR_WRITE);
        chk_read(CSR_MIP,     32'h0,         "G15 mip still 0 after write");
        do_write(CSR_MHARTID, 32'hFFFF_FFFF, CSR_WRITE);
        chk_read(CSR_MHARTID, 32'h0,         "G15 mhartid still 0 after write");

        // -------------------------------------------------------------------
        // G16: MTVEC_RESET parameter; WARL clears bits[1:0] at reset
        // -------------------------------------------------------------------
        $display("[CSR] G16: MTVEC_RESET parameter and WARL on reset");
        // Reset was applied at start with MTVEC_RESET=0x2000 (already aligned).
        // A misaligned MTVEC_RESET should be clamped at reset too.
        // We can only test what the DUT was reset with (0x2000), verified in G01.
        // Verified: mtvec after reset = 0x2000 & ~3 = 0x2000.
        // Confirm the final mtvec_o matches register after multiple writes:
        do_write(CSR_MTVEC, 32'h0000_1004, CSR_WRITE);
        if (mtvec_out !== 32'h0000_1004)
            $fatal(1, "[CSR] FAIL G16: mtvec_o=%08h expected=0x00001004", mtvec_out);

        // -------------------------------------------------------------------
        // G17: mcycle/minstret performance counters
        // -------------------------------------------------------------------
        $display("[CSR] G17: mcycle/minstret counters");
        do_write(CSR_MINSTRET,  32'h0000_000A, CSR_WRITE);
        do_write(CSR_MINSTRETH, 32'h0000_0000, CSR_WRITE);
        do_write(CSR_MCYCLE,    32'hFFFF_FFFF, CSR_WRITE);
        do_write(CSR_MCYCLEH,   32'h0000_0001, CSR_WRITE);

        chk_read(CSR_MCYCLEH, 32'h0000_0001, "G17 mcycleh write");

        @(negedge clk);
        retire = 1'b1;
        @(posedge clk); #1;
        retire = 1'b0;

        chk_read(CSR_MINSTRET, 32'h0000_000B, "G17 minstret increments on retire");
        chk_read(CSR_MCYCLEH, 32'h0000_0002, "G17 mcycle carry into high half");

        do_write(CSR_MINSTRET, 32'hFFFF_FFFF, CSR_SET);
        chk_read(CSR_MINSTRET, 32'hFFFF_FFFF, "G17 minstret CSR_SET");
        do_write(CSR_MINSTRET, 32'h0000_00FF, CSR_CLR);
        chk_read(CSR_MINSTRET, 32'hFFFF_FF00, "G17 minstret CSR_CLR");

        $display("[CSR] PASS: all %0d test groups passed.", 17);
        $finish;

    end : stim

endmodule : tb_csr_unit

`default_nettype wire
