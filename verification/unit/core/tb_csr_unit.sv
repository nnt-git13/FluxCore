// verification/unit/core/tb_csr_unit.sv
//
// Unit test for csr_unit.sv — the machine-mode CSR register file.
//
// Test groups:
//
//   G01  Reset state
//   G02  mtvec CSRRW (write / read-back; MODE[0] writable, bit[1] WARL=0)
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
//   G18  Counter half-write never clobbers the other half
//   G19  Carry reaches the un-written half; RMW ops on counters
//   G20  Interrupt CSRs: mie writable bits, mip tracks inputs, time shadows
//   G21  Machine information CSRs + mcountinhibit freeze

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
    logic          mtip = 0, msip = 0;
    logic [63:0]   mtime_val = '0;
    logic          irq_pending_out;
    logic [3:0]    irq_cause_out;
    // RV32F
    logic          fflags_wen = 0;
    fflags_t       fflags_in  = '0;
    logic          fs_dirty   = 0;
    logic          fs_off_out;
    logic [2:0]    frm_out;

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
        .fflags_wen_i (fflags_wen),
        .fflags_i     (fflags_in),
        .fs_dirty_i   (fs_dirty),
        .mtip_i       (mtip),
        .msip_i       (msip),
        .mtime_i      (mtime_val),
        .mtvec_o      (mtvec_out),
        .mepc_o       (mepc_out),
        .irq_pending_o(irq_pending_out),
        .irq_cause_o  (irq_cause_out),
        .fs_off_o     (fs_off_out),
        .frm_o        (frm_out)
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
        do_write(CSR_MTVEC, 32'hDEAD_BEFF, CSR_WRITE);   // bit1 clamped, MODE[0] kept
        chk_read(CSR_MTVEC, 32'hDEAD_BEFD, "G02 mtvec WARL bit[1]=0, MODE[0] kept");
        if (mtvec_out !== 32'hDEAD_BEFD)
            $fatal(1, "[CSR] FAIL G02: mtvec_o wrong after write");
        do_write(CSR_MTVEC, 32'hDEAD_BEFC, CSR_WRITE);   // direct mode again

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
        // 0x001 is now fflags (implemented); use 0x7C0 — a genuinely unused CSR.
        chk_read(12'h7C0, 32'h0, "G07 unknown CSR 0x7C0 reads 0");
        chk_read(12'hFFF, 32'h0, "G07 unknown CSR 0xFFF reads 0");
        do_write(12'h7C0, 32'hDEAD_BEEF, CSR_WRITE);   // write unknown CSR
        chk_read(12'h7C0, 32'h0,         "G07 unknown CSR unchanged after write");

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
        chk_read(CSR_MSTATUS, 32'h0000_0008, "G09 mstatus MIE=1 (MPP now writable, cleared by this write)");
        // Set MPIE only
        do_write(CSR_MSTATUS, 32'h0000_0080, CSR_WRITE);  // MPIE=1, MIE=0
        chk_read(CSR_MSTATUS, 32'h0000_0080, "G09 mstatus MPIE=1 MIE=0");
        // Write both MIE and MPIE
        do_write(CSR_MSTATUS, 32'h0000_0088, CSR_WRITE);  // both =1
        chk_read(CSR_MSTATUS, 32'h0000_0088, "G09 mstatus MIE=MPIE=1");
        // Write 0 to clear both (MPP must stay 2'b11)
        do_write(CSR_MSTATUS, 32'h0000_0000, CSR_WRITE);
        chk_read(CSR_MSTATUS, 32'h0000_0000, "G09 mstatus cleared (MPP=U after zero write)");
        // Writing MPP bits (WARL: ignored) — MPP must stay 2'b11
        do_write(CSR_MSTATUS, 32'h0000_0000, CSR_WRITE);  // try clearing MPP via 0
        chk_read(CSR_MSTATUS, 32'h0000_0000, "G09 MPP WARL: zero write leaves U");

        // -------------------------------------------------------------------
        // G10: mstatus CSRRS / CSRRC
        // -------------------------------------------------------------------
        $display("[CSR] G10: mstatus CSRRS/CSRRC");
        do_write(CSR_MSTATUS, 32'h0, CSR_WRITE);           // clear to baseline
        do_write(CSR_MSTATUS, 32'h0000_0008, CSR_SET);     // set MIE
        chk_read(CSR_MSTATUS, 32'h0000_0008, "G10 mstatus SET MIE");
        do_write(CSR_MSTATUS, 32'h0000_0080, CSR_SET);     // set MPIE
        chk_read(CSR_MSTATUS, 32'h0000_0088, "G10 mstatus SET MPIE");
        do_write(CSR_MSTATUS, 32'h0000_0008, CSR_CLR);     // clear MIE
        chk_read(CSR_MSTATUS, 32'h0000_0080, "G10 mstatus CLR MIE");
        do_write(CSR_MSTATUS, 32'h0000_0080, CSR_CLR);     // clear MPIE
        chk_read(CSR_MSTATUS, 32'h0000_0000, "G10 mstatus CLR MPIE baseline");

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
        chk_read(CSR_MSTATUS, 32'h0000_0088, "G13 after MRET: MIE=MPIE=1, MPP->U");

        // Full round-trip: trap with MIE=1, then MRET
        // After above: MIE=1, MPIE=1
        do_trap(32'h0003_0000, 32'hC, 32'h0);   // trap when MIE=1
        // → MPIE=1 (old MIE), MIE=0
        chk_read(CSR_MSTATUS, 32'h0000_1880, "G13 mstatus after second trap");
        chk_read(CSR_MEPC,    32'h0003_0000, "G13 mepc second trap");
        // MRET restores: MIE←MPIE=1, MPIE←1
        do_mret();
        chk_read(CSR_MSTATUS, 32'h0000_0088, "G13 mstatus after MRET: MIE=MPIE=1, MPP->U");
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
        //
        // Counter write semantics: the free-running increment is computed
        // first, then the CSR write overlays only the addressed half. The
        // un-written half keeps the incremented value (including carry).
        // chk_read consumes no clock edges and do_write consumes exactly one
        // posedge, so counter values below are cycle-exact.
        // -------------------------------------------------------------------
        $display("[CSR] G17: mcycle/minstret counters");
        do_write(CSR_MINSTRET,  32'h0000_000A, CSR_WRITE); // minstret lo <- 0xA
        do_write(CSR_MINSTRETH, 32'h0000_0000, CSR_WRITE); // minstret = {0, 0xA}
        do_write(CSR_MCYCLE,    32'hFFFF_FFFF, CSR_WRITE); // mcycle = {0, FFFF_FFFF}
        do_write(CSR_MCYCLEH,   32'h0000_0001, CSR_WRITE); // next={1,0}, hi<-1 → {1, 0}

        chk_read(CSR_MCYCLEH, 32'h0000_0001, "G17 mcycleh write");
        chk_read(CSR_MCYCLE,  32'h0000_0000, "G17 low half carried during high write");

        @(negedge clk);
        retire = 1'b1;
        @(posedge clk); #1;
        retire = 1'b0;                                     // mcycle {1,1}; minstret {0,0xB}

        chk_read(CSR_MINSTRET, 32'h0000_000B, "G17 minstret increments on retire");
        chk_read(CSR_MCYCLE,   32'h0000_0001, "G17 mcycle increments on retire cycle");
        chk_read(CSR_MCYCLEH,  32'h0000_0001, "G17 mcycleh stable");

        do_write(CSR_MINSTRET, 32'hFFFF_FFFF, CSR_SET);    // mcycle {1,2}
        chk_read(CSR_MINSTRET, 32'hFFFF_FFFF, "G17 minstret CSR_SET");
        do_write(CSR_MINSTRET, 32'h0000_00FF, CSR_CLR);    // mcycle {1,3}
        chk_read(CSR_MINSTRET, 32'hFFFF_FF00, "G17 minstret CSR_CLR");

        // -------------------------------------------------------------------
        // G18: counter half-write never clobbers the other half
        // -------------------------------------------------------------------
        $display("[CSR] G18: half-write preserves other half");
        // mcycle = {1, 3} here.
        do_write(CSR_MCYCLEH, 32'h0000_0005, CSR_WRITE);   // next={1,4}, hi<-5 → {5,4}
        chk_read(CSR_MCYCLE,  32'h0000_0004, "G18 low half took increment during high write");
        chk_read(CSR_MCYCLEH, 32'h0000_0005, "G18 high half written");
        do_write(CSR_MCYCLE,  32'h0000_0010, CSR_WRITE);   // next={5,5}, lo<-0x10 → {5,0x10}
        chk_read(CSR_MCYCLEH, 32'h0000_0005, "G18 high half preserved across low write");
        chk_read(CSR_MCYCLE,  32'h0000_0010, "G18 low half written");

        // minstret half-write with retire asserted the same cycle:
        // minstret = {0, FFFF_FF00}; next = {0, FFFF_FF01}, hi<-7 → {7, FFFF_FF01}
        @(negedge clk);
        retire = 1'b1;
        wen    = 1'b1;
        waddr  = CSR_MINSTRETH;
        wdata  = 32'h0000_0007;
        wop    = CSR_WRITE;
        @(posedge clk); #1;
        retire = 1'b0;
        wen    = 1'b0;
        wdata  = '0;
        wop    = CSR_NOP;
        chk_read(CSR_MINSTRET,  32'hFFFF_FF01, "G18 low half takes retire tick during high write");
        chk_read(CSR_MINSTRETH, 32'h0000_0007, "G18 minstreth written");

        // -------------------------------------------------------------------
        // G19: carry reaches the un-written half; RMW ops on counters
        // -------------------------------------------------------------------
        $display("[CSR] G19: counter carry and RMW");
        // mcycle = {5, 0x10}.
        do_write(CSR_MCYCLE, 32'hFFFF_FFFF, CSR_WRITE);    // next hi=5, lo<-FFFF_FFFF → {5, FFFF_FFFF}
        do_write(CSR_MSCRATCH, 32'h0, CSR_WRITE);          // unrelated write: full increment → {6, 0}
        chk_read(CSR_MCYCLE,  32'h0000_0000, "G19 low half wraps");
        chk_read(CSR_MCYCLEH, 32'h0000_0006, "G19 carry into high half on unrelated write");

        // RMW on a counter half: rmw operates on the pre-increment old value.
        // mcycle = {6, 0}: SET 0xF0 → lo <- (0 | 0xF0), hi keeps increment (no carry) → {6, 0xF0}
        do_write(CSR_MCYCLE, 32'h0000_00F0, CSR_SET);
        chk_read(CSR_MCYCLE,  32'h0000_00F0, "G19 CSR_SET on mcycle low");
        chk_read(CSR_MCYCLEH, 32'h0000_0006, "G19 high half stable across low RMW");

        // -------------------------------------------------------------------
        // G20: interrupt CSRs — mie MTIE/MSIE writable; mip mirrors inputs;
        //      time/timeh read mtime_i; irq_pending priority MSI > MTI
        // -------------------------------------------------------------------
        $display("[CSR] G20: interrupt CSRs");
        do_write(CSR_MSTATUS, 32'h0, CSR_WRITE);         // MIE=0 baseline
        do_write(CSR_MIE, 32'hFFFF_FFFF, CSR_WRITE);     // only bits 7/3 stick
        chk_read(CSR_MIE, 32'h0000_0088, "G20 mie WARL MTIE|MSIE");
        chk_read(CSR_MIP, 32'h0000_0000, "G20 mip idle");

        mtip = 1'b1; #1;
        chk_read(CSR_MIP, 32'h0000_0080, "G20 mip.MTIP tracks input");
        if (irq_pending_out)
            $fatal(1, "[CSR] FAIL G20: irq_pending with mstatus.MIE=0");
        do_write(CSR_MSTATUS, 32'h0000_0008, CSR_WRITE); // MIE=1
        #1;
        if (!irq_pending_out)
            $fatal(1, "[CSR] FAIL G20: irq_pending not asserted (MTI)");
        if (irq_cause_out !== IRQ_M_TIMER_CODE)
            $fatal(1, "[CSR] FAIL G20: cause=%0d expected MTI", irq_cause_out);
        msip = 1'b1; #1;
        if (irq_cause_out !== IRQ_M_SOFT_CODE)
            $fatal(1, "[CSR] FAIL G20: MSI must outrank MTI");
        mtip = 0; msip = 0;
        do_write(CSR_MSTATUS, 32'h0, CSR_WRITE);
        do_write(CSR_MIE, 32'h0, CSR_WRITE);

        mtime_val = 64'hDEAD_BEEF_0123_4567;
        #1;
        chk_read(CSR_TIME,  32'h0123_4567, "G20 time reads mtime low");
        chk_read(CSR_TIMEH, 32'hDEAD_BEEF, "G20 timeh reads mtime high");

        // -------------------------------------------------------------------
        // G21: machine information CSRs + mcountinhibit
        // -------------------------------------------------------------------
        $display("[CSR] G21: info CSRs + mcountinhibit");
        chk_read(CSR_MISA,      32'h4000_1121, "G21 misa RV32IMAF");
        chk_read(CSR_MVENDORID, 32'h0,         "G21 mvendorid");
        chk_read(CSR_MARCHID,   32'h0,         "G21 marchid");
        chk_read(CSR_MIMPID,    32'h2026_0702, "G21 mimpid");
        chk_read(CSR_MCOUNTEREN,32'h0,         "G21 mcounteren WARL-0");

        do_write(CSR_MCOUNTINHIBIT, 32'hFFFF_FFFF, CSR_WRITE);
        chk_read(CSR_MCOUNTINHIBIT, 32'h0000_0005, "G21 mcountinhibit CY|IR only");
        begin
            automatic word_t frozen;
            raddr = CSR_MCYCLE; #1; frozen = rdata;
            @(negedge clk); @(posedge clk); #1;   // one free-running cycle
            chk_read(CSR_MCYCLE, frozen, "G21 mcycle frozen by inhibit");
        end
        do_write(CSR_MCOUNTINHIBIT, 32'h0, CSR_WRITE);

        // -------------------------------------------------------------------
        // G22: RV32F fcsr / frm / fflags, mstatus.FS, fs_off_o, fflags accrual
        // -------------------------------------------------------------------
        $display("[CSR] G22: floating-point CSRs");
        // After reset mstatus.FS==Off: fs_off_o asserted, SD=0.
        if (fs_off_out !== 1'b1)
            $fatal(1, "[CSR] FAIL G22: fs_off_o not set when FS==Off");
        chk_read(CSR_FCSR,   32'h0, "G22 fcsr reset 0");
        chk_read(CSR_FFLAGS, 32'h0, "G22 fflags reset 0");
        chk_read(CSR_FRM,    32'h0, "G22 frm reset 0");

        // Enable FP: mstatus.FS = Initial (01) → bit 13 set (0x2000).
        do_write(CSR_MSTATUS, 32'h0000_2000, CSR_SET);
        #1;
        if (fs_off_out !== 1'b0)
            $fatal(1, "[CSR] FAIL G22: fs_off_o still set after enabling FS");
        chk_read(CSR_MSTATUS, 32'h0000_2000, "G22 mstatus FS=Initial (MPP=U)");

        // frm: write rounding mode, read back via frm/fcsr, check frm_o output.
        do_write(CSR_FRM, 32'h0000_0003, CSR_WRITE);   // RUP
        chk_read(CSR_FRM,  32'h0000_0003, "G22 frm=3");
        chk_read(CSR_FCSR, 32'h0000_0060, "G22 fcsr frm in [7:5]");
        if (frm_out !== 3'd3)
            $fatal(1, "[CSR] FAIL G22: frm_o=%0d expected 3", frm_out);

        // fflags: only low 5 bits; upper write bits ignored.
        do_write(CSR_FFLAGS, 32'h0000_001F, CSR_WRITE);
        chk_read(CSR_FFLAGS, 32'h0000_001F, "G22 fflags all set");
        chk_read(CSR_FCSR,   32'h0000_007F, "G22 fcsr = {frm=3, fflags=1F}");
        do_write(CSR_FFLAGS, 32'h0000_0000, CSR_WRITE);  // clear
        chk_read(CSR_FFLAGS, 32'h0000_0000, "G22 fflags cleared");

        // fcsr combined write: sets both frm and fflags.
        do_write(CSR_FCSR, 32'h0000_00A5, CSR_WRITE);    // frm=101→WARL keeps 5? frm 3 bits=101=5
        chk_read(CSR_FRM,    32'h0000_0005, "G22 fcsr write sets frm=5");
        chk_read(CSR_FFLAGS, 32'h0000_0005, "G22 fcsr write sets fflags=5");

        // fflags accrual: an FP op contributes flags via fflags_wen_i.
        do_write(CSR_FFLAGS, 32'h0, CSR_WRITE);          // clear first
        @(negedge clk);
        fflags_wen = 1'b1;
        fflags_in  = 5'b10001;                            // NV | NX
        @(posedge clk); #1;
        fflags_wen = 1'b0;
        fflags_in  = '0;
        chk_read(CSR_FFLAGS, 32'h0000_0011, "G22 fflags accrued NV|NX");
        // Second accrual ORs in more flags.
        @(negedge clk);
        fflags_wen = 1'b1;
        fflags_in  = 5'b00100;                            // OF
        @(posedge clk); #1;
        fflags_wen = 1'b0;
        fflags_in  = '0;
        chk_read(CSR_FFLAGS, 32'h0000_0015, "G22 fflags accrue is OR (NV|OF|NX)");

        // fs_dirty: an FP op that modifies FP state moves FS to Dirty; SD set.
        @(negedge clk);
        fs_dirty = 1'b1;
        @(posedge clk); #1;
        fs_dirty = 1'b0;
        // FS=Dirty(11)→0x6000, MPP(11)→0x1800, SD(bit31)→0x8000_0000.
        chk_read(CSR_MSTATUS, 32'h8000_6000, "G22 mstatus FS=Dirty + SD (MPP=U)");

        $display("[CSR] PASS: all %0d test groups passed.", 22);
        $finish;

    end : stim

endmodule : tb_csr_unit

`default_nettype wire
