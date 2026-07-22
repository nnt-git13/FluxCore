// rtl/core/csr_unit.sv
//
// Machine-mode CSR register file for FluxCore.
//
// Implements the minimal M-mode CSR set needed for RV32I exception handling:
//
//   0x300  mstatus   MIE[3] and MPIE[7] are R/W; MPP[12:11]=2'b11 hardwired.
//                    All other bits WPRI (read 0, writes ignored).
//   0x305  mtvec     Machine trap-vector base; MODE[0] writable (0=direct,
//                    1=vectored); bit[1] WARL=0.
//   0x340  mscratch  General-purpose scratch register (32-bit R/W).
//   0x341  mepc      Machine exception PC; bits[1:0] WARL=0 (no C extension).
//   0x342  mcause    Machine trap cause (R/W; interrupt bit + cause code).
//   0x343  mtval     Machine trap value (R/W; 0 for decode-detected traps).
//   0x344  mip       Machine interrupt pending — read-only composition of
//                    the mtip_i / msip_i inputs (MTIP[7], MSIP[3]).
//   0xB00  mcycle    Cycle counter low 32 bits.
//   0xB02  minstret  Retired-instruction counter low 32 bits.
//   0xB80  mcycleh   Cycle counter high 32 bits.
//   0xB82  minstreth Retired-instruction counter high 32 bits.
//   0xF14  mhartid   Hart identifier — read-only, returns 0 (single hart).
//   other            Read returns 0; writes silently ignored.
//
// Write port (wop_i, driven from WB stage for CSR instructions):
//   CSR_WRITE : csr[waddr] ← wdata_i
//   CSR_SET   : csr[waddr] ← csr[waddr] | wdata_i
//   CSR_CLR   : csr[waddr] ← csr[waddr] & ~wdata_i
//
// Trap-entry sequence (driven by pipeline_ctrl on exception commit):
//   mepc             ← {trap_epc_i[31:2], 2'b00}
//   mcause           ← trap_cause_i
//   mtval            ← trap_tval_i
//   mstatus.MPIE     ← mstatus.MIE
//   mstatus.MIE      ← 0
//
// MRET sequence (driven by pipeline_ctrl when MRET commits):
//   mstatus.MIE      ← mstatus.MPIE
//   mstatus.MPIE     ← 1
//   (PC redirect to mepc_o handled by pipeline_ctrl)
//
// Write priority (posedge, highest first): rst > trap_i > mret_i > wen_i.
// Performance counters update every non-reset cycle. A CSR write to a counter
// half overrides that half's increment for the same cycle; the un-written
// half still takes the increment (including any carry out of the low half).

`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;

module csr_unit #(
    parameter word_t MTVEC_RESET = '0
) (
    input  wire logic     clk,
    input  wire logic     rst,

    // ── Combinational read port ──────────────────────────────────────────────
    input  wire logic [11:0] raddr_i,
    output word_t        rdata_o,

    // ── Synchronous write port ───────────────────────────────────────────────
    // Driven by WB stage for CSRRW / CSRRS / CSRRC (and immediate variants).
    input  wire logic        wen_i,
    input  wire logic [11:0] waddr_i,
    input  wire word_t        wdata_i,   // write operand (rs1 forwarded, or zimm)
    input  wire csr_op_e     wop_i,

    // ── Trap entry ───────────────────────────────────────────────────────────
    // Asserted by pipeline_ctrl when an exception instruction commits.
    input  wire logic        trap_i,
    input  wire word_t        trap_epc_i,
    input  wire word_t        trap_cause_i,
    input  wire word_t        trap_tval_i,

    // ── MRET ─────────────────────────────────────────────────────────────────
    // Asserted by pipeline_ctrl when the MRET instruction commits.
    input  wire logic        mret_i,

    // ── Performance counter inputs ──────────────────────────────────────────
    // Asserted for one cycle when WB retires a non-exception instruction.
    input  wire logic        retire_i,

    // ── Floating-point status accrual (RV32F) ───────────────────────────────
    // fflags_wen_i pulses for one cycle when a retiring FP op contributes IEEE
    // exception flags; fflags_i carries the flags to OR into fcsr.fflags.
    // fs_dirty_i marks that a retiring FP op modified FP state (an f register
    // or fflags), which sets mstatus.FS to Dirty.  Defaults keep pre-FP
    // instantiations inert.
    // Cache hierarchy counters (read-only CSRs 0xFC0-0xFC3; SoC-wired,
    // zero in cacheless configurations).
    // Cache maintenance (CSR 0x7C0): any write pulses cacheop_flush_o for
    // one cycle; reads return bit 0 = the walk is still busy.
    input  wire logic        cacheflush_busy_i = 1'b0,
    output logic             cacheop_flush_o,

    input  wire word_t       dc_hits_i   = '0,
    input  wire word_t       dc_misses_i = '0,
    input  wire word_t       ic_hits_i   = '0,
    input  wire word_t       ic_misses_i = '0,

    input  wire logic        fflags_wen_i = 1'b0,
    input  wire fflags_t     fflags_i     = 5'b0,
    input  wire logic        fs_dirty_i   = 1'b0,

    // ── Interrupt inputs (from CLINT) ────────────────────────────────────────
    // Level-sensitive.  Defaults keep legacy instantiations interrupt-free.
    input  wire logic        mtip_i = 1'b0,        // machine timer interrupt pending
    input  wire logic        msip_i = 1'b0,        // machine software interrupt pending
    input  wire logic [63:0] mtime_i = 64'd0,      // CLINT mtime (for time/timeh CSRs)

    // ── Outputs for pipeline_ctrl / interrupt injection ─────────────────────
    output word_t        mtvec_o,     // raw mtvec including MODE bit[0]
    output word_t        mepc_o,
    // 1 when an enabled interrupt is pending and mstatus.MIE is set.
    output logic         irq_pending_o,
    // Cause code of the highest-priority pending interrupt (MSI > MTI).
    output logic [EXC_CAUSE_W-1:0] irq_cause_o,

    // ── RV32F ────────────────────────────────────────────────────────────────
    // fs_off_o = 1 when mstatus.FS == Off; wired to the decoder so it raises
    // illegal-instruction on FP instructions / fcsr accesses while FP is disabled.
    // frm_o exposes the dynamic rounding mode for the FPU (FRM_DYN resolution).
    // Current privilege (2'b11 = M, 2'b00 = U) for the decoder's CSR and
    // MRET legality gates.
    output logic [1:0]   priv_o,

    output logic         fs_off_o,
    output logic [2:0]   frm_o
);

    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------
    logic  mstatus_mie_q;
    logic  mstatus_mpie_q;
    // Privilege state (M+U): 2'b11 = machine, 2'b00 = user. MPP is now a
    // real WARL field restricted to those two values.
    logic [1:0] priv_q;
    logic [1:0] mpp_q;
    logic  mtie_q;           // mie.MTIE (bit 7)
    logic  msie_q;           // mie.MSIE (bit 3)
    logic  inh_cy_q;         // mcountinhibit.CY (bit 0): freeze mcycle
    logic  inh_ir_q;         // mcountinhibit.IR (bit 2): freeze minstret
    word_t mtvec_q;
    word_t mscratch_q;
    word_t mepc_q;
    word_t mcause_q;
    word_t mtval_q;
    logic [63:0] mcycle_q;
    logic [63:0] minstret_q;
    // RV32F floating-point CSR state
    logic [2:0]  frm_q;             // fcsr[7:5] dynamic rounding mode
    fflags_t     fflags_q;          // fcsr[4:0] accrued IEEE exception flags
    logic [1:0]  fs_q;              // mstatus.FS[14:13] (00=Off,01=Init,10=Clean,11=Dirty)

    assign mtvec_o = mtvec_q;
    assign mepc_o  = mepc_q;
    assign priv_o   = priv_q;
    assign fs_off_o = (fs_q == 2'b00);
    assign frm_o    = frm_q;

    // mstatus composition helper: FS in [14:13]; SD (bit 31) = (FS==Dirty).
    // MPP hardwired 2'b11 in [12:11]; MPIE[7], MIE[3] are the only other R/W bits.
    function automatic word_t mstatus_compose(input logic mie, input logic mpie,
                                               input logic [1:0] fs,
                                               input logic [1:0] mpp);
        return {(fs == 2'b11), 16'b0, fs, mpp, 3'b0, mpie, 3'b0, mie, 3'b0};
    endfunction

    // -----------------------------------------------------------------------
    // Combinational read
    // mstatus: [31:13]=0, [12:11]=MPP=2'b11, [10:8]=0, [7]=MPIE,
    //          [6:4]=0, [3]=MIE, [2:0]=0
    // -----------------------------------------------------------------------
    always_comb begin
        case (raddr_i)
            CSR_MSTATUS : rdata_o = mstatus_compose(mstatus_mie_q, mstatus_mpie_q, fs_q, mpp_q);
            CSR_MIE     : rdata_o = {24'b0, mtie_q, 3'b0, msie_q, 3'b0};
            CSR_MTVEC   : rdata_o = mtvec_q;
            CSR_CACHEOP : rdata_o = {31'b0, cacheflush_busy_i};
            CSR_DCHITS  : rdata_o = dc_hits_i;
            CSR_DCMISSES: rdata_o = dc_misses_i;
            CSR_ICHITS  : rdata_o = ic_hits_i;
            CSR_ICMISSES: rdata_o = ic_misses_i;
            CSR_MSCRATCH: rdata_o = mscratch_q;
            CSR_MEPC    : rdata_o = mepc_q;
            CSR_MCAUSE  : rdata_o = mcause_q;
            CSR_MTVAL   : rdata_o = mtval_q;
            CSR_MIP     : rdata_o = {24'b0, mtip_i, 3'b0, msip_i, 3'b0};
            CSR_MCYCLE  : rdata_o = mcycle_q[31:0];
            CSR_MINSTRET: rdata_o = minstret_q[31:0];
            CSR_MCYCLEH : rdata_o = mcycle_q[63:32];
            CSR_MINSTRETH: rdata_o = minstret_q[63:32];
            CSR_MHARTID : rdata_o = '0;
            // RV32F floating-point CSRs
            CSR_FFLAGS  : rdata_o = {27'b0, fflags_q};
            CSR_FRM     : rdata_o = {29'b0, frm_q};
            CSR_FCSR    : rdata_o = {24'b0, frm_q, fflags_q};
            // Machine information / configuration registers
            CSR_MISA    : rdata_o = 32'h4000_1121;   // RV32IMAF (A|I|M|F)
            CSR_MVENDORID : rdata_o = '0;            // non-commercial
            CSR_MARCHID   : rdata_o = '0;            // not registered
            CSR_MIMPID    : rdata_o = 32'h2026_0702; // implementation date
            CSR_MCONFIGPTR: rdata_o = '0;
            CSR_MCOUNTEREN: rdata_o = '0;            // WARL-0 (no U-mode)
            CSR_MCOUNTINHIBIT: rdata_o = {29'b0, inh_ir_q, 1'b0, inh_cy_q};
            // Zicntr read-only shadows + CLINT-backed time
            CSR_CYCLE   : rdata_o = mcycle_q[31:0];
            CSR_CYCLEH  : rdata_o = mcycle_q[63:32];
            CSR_INSTRET : rdata_o = minstret_q[31:0];
            CSR_INSTRETH: rdata_o = minstret_q[63:32];
            CSR_TIME    : rdata_o = mtime_i[31:0];
            CSR_TIMEH   : rdata_o = mtime_i[63:32];
            default     : rdata_o = '0;
        endcase
    end

    // -----------------------------------------------------------------------
    // Read-modify-write helper (pure combinational, used in write path)
    // -----------------------------------------------------------------------
    function automatic word_t csr_rmw(
        input word_t   old_v,
        input word_t   wr_v,
        input csr_op_e op
    );
        case (op)
            CSR_WRITE : return wr_v;
            CSR_SET   : return old_v |  wr_v;
            CSR_CLR   : return old_v & ~wr_v;
            default   : return old_v;   // CSR_NOP
        endcase
    endfunction

    word_t mstatus_current_s;
    word_t mstatus_rmw_s;
    word_t mie_current_s;
    word_t mie_rmw_s;
    word_t mtvec_rmw_s;
    word_t mepc_rmw_s;
    word_t mcycle_lo_rmw_s;
    word_t mcycle_hi_rmw_s;
    word_t minstret_lo_rmw_s;
    word_t minstret_hi_rmw_s;
    word_t fflags_rmw_s;
    word_t frm_rmw_s;
    word_t fcsr_rmw_s;

    always_comb begin
        mstatus_current_s = mstatus_compose(mstatus_mie_q, mstatus_mpie_q, fs_q, mpp_q);
        mstatus_rmw_s     = csr_rmw(mstatus_current_s, wdata_i, wop_i);
        mie_current_s     = {24'b0, mtie_q, 3'b0, msie_q, 3'b0};
        mie_rmw_s         = csr_rmw(mie_current_s,     wdata_i, wop_i);
        mtvec_rmw_s       = csr_rmw(mtvec_q,           wdata_i, wop_i);
        mepc_rmw_s        = csr_rmw(mepc_q,            wdata_i, wop_i);
        mcycle_lo_rmw_s   = csr_rmw(mcycle_q[31:0],    wdata_i, wop_i);
        mcycle_hi_rmw_s   = csr_rmw(mcycle_q[63:32],   wdata_i, wop_i);
        minstret_lo_rmw_s = csr_rmw(minstret_q[31:0],  wdata_i, wop_i);
        minstret_hi_rmw_s = csr_rmw(minstret_q[63:32], wdata_i, wop_i);
        // FP CSRs: RMW against the current fcsr view; only the low bits matter.
        fflags_rmw_s      = csr_rmw({27'b0, fflags_q},          wdata_i, wop_i);
        frm_rmw_s         = csr_rmw({29'b0, frm_q},             wdata_i, wop_i);
        fcsr_rmw_s        = csr_rmw({24'b0, frm_q, fflags_q},   wdata_i, wop_i);
    end

    // -----------------------------------------------------------------------
    // Counter next-value: free-running increment computed first, then a CSR
    // write overlays only the addressed 32-bit half. The un-written half
    // keeps the incremented value, so a carry out of the low half is never
    // lost, and a half-write never clobbers the other half.
    // -----------------------------------------------------------------------
    logic [63:0] mcycle_next_s;
    logic [63:0] minstret_next_s;

    always_comb begin
        mcycle_next_s   = mcycle_q   + (inh_cy_q ? 64'd0 : 64'd1);
        minstret_next_s = minstret_q + (inh_ir_q ? 64'd0 : {63'b0, retire_i});
        if (wen_i) begin
            case (waddr_i)
                CSR_MCYCLE:    mcycle_next_s[31:0]    = mcycle_lo_rmw_s;
                CSR_MCYCLEH:   mcycle_next_s[63:32]   = mcycle_hi_rmw_s;
                CSR_MINSTRET:  minstret_next_s[31:0]  = minstret_lo_rmw_s;
                CSR_MINSTRETH: minstret_next_s[63:32] = minstret_hi_rmw_s;
                default: ;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // FP status next-value.  fflags accrue every cycle (OR-in the flags of a
    // retiring FP op); an FP op that changes FP state moves FS to Dirty.
    // An explicit CSR write to fflags/frm/fcsr/mstatus overrides for that
    // register (software intent wins over same-cycle accrual).
    // -----------------------------------------------------------------------
    fflags_t    fflags_next_s;
    logic [2:0] frm_next_s;
    logic [1:0] fs_next_s;

    always_comb begin
        fflags_next_s = fflags_q | (fflags_wen_i ? fflags_i : 5'b0);
        frm_next_s    = frm_q;
        fs_next_s     = fs_q;
        // FP op modified FP state → Dirty (only meaningful while FP is enabled).
        if (fs_dirty_i && fs_q != 2'b00)
            fs_next_s = 2'b11;
        if (wen_i) begin
            case (waddr_i)
                CSR_FFLAGS:  fflags_next_s = fflags_rmw_s[4:0];
                CSR_FRM:     frm_next_s    = frm_rmw_s[2:0];
                CSR_FCSR: begin
                    frm_next_s    = fcsr_rmw_s[7:5];
                    fflags_next_s = fcsr_rmw_s[4:0];
                end
                CSR_MSTATUS: fs_next_s = mstatus_rmw_s[14:13];  // WARL, all 4 legal
                default: ;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Synchronous write
    // -----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            mstatus_mie_q  <= 1'b0;
            mstatus_mpie_q <= 1'b0;
            priv_q         <= 2'b11;   // boot in machine mode
            mpp_q          <= 2'b11;
            mtie_q         <= 1'b0;
            msie_q         <= 1'b0;
            inh_cy_q       <= 1'b0;
            inh_ir_q       <= 1'b0;
            mtvec_q        <= MTVEC_RESET & ~32'h3;
            mscratch_q     <= '0;
            mepc_q         <= '0;
            mcause_q       <= '0;
            mtval_q        <= '0;
            mcycle_q       <= '0;
            minstret_q     <= '0;
            // RV32F: FS resets to Off (FP disabled until software enables it);
            // rounding mode and accrued flags reset to zero.
            fs_q           <= 2'b00;
            frm_q          <= 3'b000;
            fflags_q       <= '0;

        end else begin
            mcycle_q   <= mcycle_next_s;
            minstret_q <= minstret_next_s;
            fs_q       <= fs_next_s;
            frm_q      <= frm_next_s;
            fflags_q   <= fflags_next_s;
        end

        if (!rst && trap_i) begin
            mepc_q         <= {trap_epc_i[31:2], 2'b00};
            // ECALL's cause depends on the ORIGIN mode; the decoder tags it
            // statically as ECALL_M, remapped here at commit.
            mcause_q       <= (trap_cause_i[EXC_CAUSE_W-1:0] == EXC_ECALL_M
                               && priv_q == 2'b00)
                            ? {trap_cause_i[31:EXC_CAUSE_W],
                               EXC_CAUSE_W'(EXC_ECALL_U)}
                            : trap_cause_i;
            mtval_q        <= trap_tval_i;
            mstatus_mpie_q <= mstatus_mie_q;
            mstatus_mie_q  <= 1'b0;
            mpp_q          <= priv_q;      // remember where we came from
            priv_q         <= 2'b11;       // traps always target M

        end else if (!rst && mret_i) begin
            mstatus_mie_q  <= mstatus_mpie_q;
            mstatus_mpie_q <= 1'b1;
            priv_q         <= mpp_q;       // return to the trapped-from mode
            mpp_q          <= 2'b00;       // spec: xPP set to least-privileged

        end else if (!rst && wen_i) begin
            case (waddr_i)
                CSR_MSTATUS: begin
                    // WARL: MIE[3], MPIE[7], and MPP[12:11] (values 00/11
                    // only; anything else squashes to 00 = user).
                    mstatus_mie_q  <= mstatus_rmw_s[3];
                    mstatus_mpie_q <= mstatus_rmw_s[7];
                    mpp_q          <= (mstatus_rmw_s[12:11] == 2'b11)
                                    ? 2'b11 : 2'b00;
                end
                CSR_MCOUNTINHIBIT: begin
                    // WARL: only CY[0] and IR[2] implemented
                    inh_cy_q <= csr_rmw({29'b0, inh_ir_q, 1'b0, inh_cy_q}, wdata_i, wop_i) >> 0;
                    inh_ir_q <= csr_rmw({29'b0, inh_ir_q, 1'b0, inh_cy_q}, wdata_i, wop_i) >> 2;
                end
                CSR_MIE: begin
                    // WARL: only MTIE[7] and MSIE[3] are writable.
                    mtie_q <= mie_rmw_s[7];
                    msie_q <= mie_rmw_s[3];
                end
                // MODE[0] writable (0=direct, 1=vectored); bit[1] WARL=0.
                CSR_MTVEC:    mtvec_q    <= {mtvec_rmw_s[31:2], 1'b0, mtvec_rmw_s[0]};
                CSR_MSCRATCH: mscratch_q <= csr_rmw(mscratch_q,  wdata_i, wop_i);
                CSR_MEPC:     mepc_q     <= {mepc_rmw_s[31:2], 2'b00};
                CSR_MCAUSE:   mcause_q   <= csr_rmw(mcause_q,    wdata_i, wop_i);
                CSR_MTVAL:    mtval_q    <= csr_rmw(mtval_q,     wdata_i, wop_i);
                CSR_MCYCLE,
                CSR_MCYCLEH,
                CSR_MINSTRET,
                CSR_MINSTRETH: ; // handled by the counter update path above
                default: ;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Interrupt pending / cause (level-sensitive; priority MSI > MTI)
    // -----------------------------------------------------------------------
    // M-mode interrupts are enabled when MIE is set OR when executing in a
    // less-privileged mode (spec 3.1.6.1: interrupts for higher modes are
    // always enabled regardless of that mode's global bit).
    assign irq_pending_o = (mstatus_mie_q | (priv_q != 2'b11))
                         & ((mtip_i & mtie_q) | (msip_i & msie_q));
    assign irq_cause_o   = (msip_i & msie_q) ? IRQ_M_SOFT_CODE : IRQ_M_TIMER_CODE;

    // CACHEOP write pulse (1 cycle, at the synchronous write commit point)
    logic cacheop_q;
    always_ff @(posedge clk) begin
        if (rst) cacheop_q <= 1'b0;
        else     cacheop_q <= wen_i && (waddr_i == CSR_CACHEOP);
    end
    assign cacheop_flush_o = cacheop_q;

endmodule : csr_unit

`default_nettype wire
