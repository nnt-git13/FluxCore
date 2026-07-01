// rtl/core/csr_unit.sv
//
// Machine-mode CSR register file for FluxCore.
//
// Implements the minimal M-mode CSR set needed for RV32I exception handling:
//
//   0x300  mstatus   MIE[3] and MPIE[7] are R/W; MPP[12:11]=2'b11 hardwired.
//                    All other bits WPRI (read 0, writes ignored).
//   0x305  mtvec     Machine trap-vector base; MODE forced to 0 (direct).
//                    bits[1:0] WARL=0.
//   0x340  mscratch  General-purpose scratch register (32-bit R/W).
//   0x341  mepc      Machine exception PC; bits[1:0] WARL=0 (no C extension).
//   0x342  mcause    Machine trap cause (R/W; interrupt bit + cause code).
//   0x343  mtval     Machine trap value (R/W; 0 for decode-detected traps).
//   0x344  mip       Machine interrupt pending — read-only, returns 0.
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
// overrides that counter's increment for the same cycle.

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

    // ── Outputs for pipeline_ctrl ────────────────────────────────────────────
    output word_t        mtvec_o,
    output word_t        mepc_o
);

    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------
    logic  mstatus_mie_q;
    logic  mstatus_mpie_q;
    word_t mtvec_q;
    word_t mscratch_q;
    word_t mepc_q;
    word_t mcause_q;
    word_t mtval_q;
    logic [63:0] mcycle_q;
    logic [63:0] minstret_q;

    assign mtvec_o = mtvec_q;
    assign mepc_o  = mepc_q;

    // -----------------------------------------------------------------------
    // Combinational read
    // mstatus: [31:13]=0, [12:11]=MPP=2'b11, [10:8]=0, [7]=MPIE,
    //          [6:4]=0, [3]=MIE, [2:0]=0
    // -----------------------------------------------------------------------
    always_comb begin
        case (raddr_i)
            CSR_MSTATUS : rdata_o = {19'b0, 2'b11, 3'b0, mstatus_mpie_q,
                                      3'b0, mstatus_mie_q, 3'b0};
            CSR_MIE     : rdata_o = '0;
            CSR_MTVEC   : rdata_o = mtvec_q;
            CSR_MSCRATCH: rdata_o = mscratch_q;
            CSR_MEPC    : rdata_o = mepc_q;
            CSR_MCAUSE  : rdata_o = mcause_q;
            CSR_MTVAL   : rdata_o = mtval_q;
            CSR_MIP     : rdata_o = '0;
            CSR_MCYCLE  : rdata_o = mcycle_q[31:0];
            CSR_MINSTRET: rdata_o = minstret_q[31:0];
            CSR_MCYCLEH : rdata_o = mcycle_q[63:32];
            CSR_MINSTRETH: rdata_o = minstret_q[63:32];
            CSR_MHARTID : rdata_o = '0;
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
    word_t mtvec_rmw_s;
    word_t mepc_rmw_s;
    word_t mcycle_lo_rmw_s;
    word_t mcycle_hi_rmw_s;
    word_t minstret_lo_rmw_s;
    word_t minstret_hi_rmw_s;

    always_comb begin
        mstatus_current_s = {19'b0, 2'b11, 3'b0, mstatus_mpie_q,
                             3'b0, mstatus_mie_q, 3'b0};
        mstatus_rmw_s     = csr_rmw(mstatus_current_s, wdata_i, wop_i);
        mtvec_rmw_s       = csr_rmw(mtvec_q,           wdata_i, wop_i);
        mepc_rmw_s        = csr_rmw(mepc_q,            wdata_i, wop_i);
        mcycle_lo_rmw_s   = csr_rmw(mcycle_q[31:0],    wdata_i, wop_i);
        mcycle_hi_rmw_s   = csr_rmw(mcycle_q[63:32],   wdata_i, wop_i);
        minstret_lo_rmw_s = csr_rmw(minstret_q[31:0],  wdata_i, wop_i);
        minstret_hi_rmw_s = csr_rmw(minstret_q[63:32], wdata_i, wop_i);
    end

    // -----------------------------------------------------------------------
    // Synchronous write
    // -----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            mstatus_mie_q  <= 1'b0;
            mstatus_mpie_q <= 1'b0;
            mtvec_q        <= MTVEC_RESET & ~32'h3;
            mscratch_q     <= '0;
            mepc_q         <= '0;
            mcause_q       <= '0;
            mtval_q        <= '0;
            mcycle_q       <= '0;
            minstret_q     <= '0;

        end else begin
            if (wen_i) begin
                case (waddr_i)
                    CSR_MCYCLE:    mcycle_q[31:0]     <= mcycle_lo_rmw_s;
                    CSR_MCYCLEH:   mcycle_q[63:32]    <= mcycle_hi_rmw_s;
                    default:       mcycle_q           <= mcycle_q + 64'd1;
                endcase
            end else begin
                mcycle_q <= mcycle_q + 64'd1;
            end

            if (wen_i) begin
                case (waddr_i)
                    CSR_MINSTRET:  minstret_q[31:0]   <= minstret_lo_rmw_s;
                    CSR_MINSTRETH: minstret_q[63:32]  <= minstret_hi_rmw_s;
                    default:       minstret_q         <= minstret_q + {63'b0, retire_i};
                endcase
            end else begin
                minstret_q <= minstret_q + {63'b0, retire_i};
            end
        end

        if (!rst && trap_i) begin
            mepc_q         <= {trap_epc_i[31:2], 2'b00};
            mcause_q       <= trap_cause_i;
            mtval_q        <= trap_tval_i;
            mstatus_mpie_q <= mstatus_mie_q;
            mstatus_mie_q  <= 1'b0;

        end else if (!rst && mret_i) begin
            mstatus_mie_q  <= mstatus_mpie_q;
            mstatus_mpie_q <= 1'b1;

        end else if (!rst && wen_i) begin
            case (waddr_i)
                CSR_MSTATUS: begin
                    // WARL: only MIE[3] and MPIE[7] are writable.
                    mstatus_mie_q  <= mstatus_rmw_s[3];
                    mstatus_mpie_q <= mstatus_rmw_s[7];
                end
                CSR_MTVEC:    mtvec_q    <= {mtvec_rmw_s[31:2], 2'b00};
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

endmodule : csr_unit

`default_nettype wire
