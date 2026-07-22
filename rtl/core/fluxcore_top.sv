`default_nettype none

// fluxcore_top — single-issue, in-order, five-stage RV32I pipeline.
//
// Stage layout:
//   IF  fetch_unit → imem interface → if_id_reg
//   ID  decoder + regfile read    → id_ex_reg
//   EX  execute_stage (alu + branch_unit) → ex_mem_reg
//   MEM mem_stage (load/store + misalignment) → mem_wb_reg
//   WB  wb_stage (regfile write + retirement)
//
// Pipeline control:
//   pipeline_ctrl is purely combinational. It observes:
//     • execute_stage's COMBINATIONAL output (ex_mem_s) — before ex_mem_reg —
//       to detect branches/jumps and generate flushes in the same cycle.
//     • wb_stage's exception output (exception_s) — derived from mem_wb_q.
//   On a taken branch or jump: flush if_id_reg and id_ex_reg, redirect PC.
//   On an exception:           flush all four stage registers, redirect to
//                              TRAP_VECTOR (placeholder; → mtvec when CSR lands).
//
// External memory interfaces:
//   Instruction memory: fetch_unit exposes both imem_addr_o (current PC) and
//   imem_addr_next_o (next PC). Simulation testbenches drive imem_rdata_i
//   combinatorially from imem_addr_o. For BRAM synthesis, imem_addr_next_o
//   feeds the BRAM address so its registered output is valid in the same cycle
//   as imem_addr_o (hiding the 1-cycle BRAM latency transparently).
//   Data memory: combinational simulation memories can return dmem_rdata_i in
//   the MEM cycle, where mem_stage selects mem_wb_s.rd_data. BRAM synthesis
//   returns dmem_rdata_i in the WB cycle; wb_stage recomputes load writeback
//   from that live word when mem_wb_q.rd_from_mem=1.
//
// Parameters:
//   RESET_VECTOR  First PC after reset (default 0x00000000).
//   TRAP_VECTOR   Initial value of mtvec (passed to csr_unit as MTVEC_RESET).
//                 After reset, mtvec can be overwritten by CSRRW.
//                 Default 0x00000000.

module fluxcore_top
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
    import pipeline_pkg::*;
#(
    parameter word_t RESET_VECTOR = 32'h0000_0000,
    parameter word_t TRAP_VECTOR  = 32'h0000_0000
)
(
    input  wire logic              clk,
    input  wire logic              rst,           // synchronous, active-high

    // --- Instruction memory ---
    // imem_addr_o      : current fetch address (combinatorial from pc_q).
    //                    Use this for the if_id payload PC and for simulation ROMs.
    // imem_addr_next_o : next fetch address (combinatorial, before posedge).
    //                    Connect to BRAM address input for synthesis so the
    //                    BRAM's registered output arrives in the correct cycle.
    output word_t             imem_addr_o,      // current PC (4-byte aligned)
    output word_t             imem_addr_next_o, // next PC, for BRAM prefetch
    input  wire instr_t            imem_rdata_i,     // instruction word for imem_addr_o
    // 0 = instruction not available this cycle (I-cache miss): fetch holds
    // the PC and emits bubbles. Default 1 = original always-valid behavior.
    input  wire logic         imem_valid_i = 1'b1,

    // --- Data memory (word-wide with byte enables) ---
    output word_t             dmem_addr_o,   // effective byte address
    output logic              dmem_ren_o,    // 1 = load is in MEM stage (connect to dcache cpu_ren_i)
    output logic              dmem_wen_o,    // write enable (stores, gated on exceptions)
    output logic [3:0]        dmem_wstrb_o,  // byte enables
    output word_t             dmem_wdata_o,  // store write data
    input  wire word_t             dmem_rdata_i,  // load read data
    input  wire logic              dmem_stall_i,  // 1 = cache miss, stall all stages

    // Non-blocking dcache handshake (all tied off for blocking configs).
    // defer_ok: the access now in MEM may be deferred (int load or store —
    // FP loads keep blocking, the FP regfile has no fill port).
    // FENCE.I flush pulse for an external I-cache (1+ cycles while the
    // FENCE.I sits in EX). Unconnected in cacheless configurations.
    output logic              fencei_flush_o,

    // Cache hierarchy counters into the 0xFC0+ CSRs (defaults for
    // cacheless configurations).
    input  wire word_t        dc_hits_i   = '0,
    input  wire word_t        dc_misses_i = '0,
    input  wire word_t        ic_hits_i   = '0,
    input  wire word_t        ic_misses_i = '0,

    output logic              dmem_defer_ok_o,
    input  wire logic         dmem_defer_i     = 1'b0,  // miss accepted this cycle
    input  wire logic         dmem_fill_done_i = 1'b0,  // deferred read completed
    input  wire word_t        dmem_fill_data_i = '0,    // its data

    // --- Interrupt inputs (from CLINT; level-sensitive) ---
    // Defaults keep legacy instantiations (unit/integration TBs) interrupt-free.
    input  wire logic         mtip_i = 1'b0,   // machine timer interrupt
    input  wire logic         msip_i = 1'b0,   // machine software interrupt
    input  wire logic [63:0]  mtime_i = 64'd0, // CLINT mtime for time/timeh CSRs

    // --- Retirement and exception outputs ---
    // retire_o: one retirement event per architecturally committed instruction.
    // exception_o / exception_pc_o: captured by the future CSR/trap unit.
    output retirement_event_t retire_o,
    output exception_meta_t   exception_o,
    output word_t             exception_pc_o
);

    // =========================================================================
    // Stage-boundary signals
    //
    // Naming convention:
    //   *_s  Combinational (pre-register): output of the stage's logic
    //   *_q  Registered (post-register): output of the pipeline stage register
    // =========================================================================

    if_id_payload_t  if_id_s, if_id_q;
    id_ex_payload_t  id_ex_s, id_ex_q, id_ex_fwd_s;
    ex_mem_payload_t ex_mem_s, ex_mem_q;
    mem_wb_payload_t mem_wb_s, mem_wb_q;

    // =========================================================================
    // Pipeline control signals
    // =========================================================================

    logic  stall_if_s, stall_id_s, stall_ex_s, stall_mem_s, stall_wb_s;
    logic  flush_if_id_s, flush_id_ex_s, flush_ex_mem_s, flush_mem_wb_s;
    logic  redirect_valid_s;
    word_t redirect_target_s;

    // Forwarding unit outputs
    word_t rs1_fwd_s, rs2_fwd_s;
    logic  load_use_stall_s;
    logic  csr_raw_stall_s;

    // CSR unit signals
    logic    irq_pending_s;        // enabled interrupt pending (csr_unit)
    logic [EXC_CAUSE_W-1:0] irq_cause_s;  // highest-priority pending cause
    ex_mem_payload_t ex_mem_tag_s; // EX output with interrupt tag applied
    word_t   csr_rdata_s;          // combinatorial read from csr_unit (→ execute_stage)
    word_t   mtvec_s, mepc_s;      // csr_unit outputs used for redirects
    logic    fs_off_s;             // mstatus.FS==Off → decoder gates FP instructions
    logic [2:0] frm_s;             // dynamic rounding mode (fcsr.frm) → FPU (Phase C)
    logic    csr_wen_s;            // CSR write enable from mem_stage
    logic [11:0] csr_waddr_s;      // CSR write address from mem_stage
    word_t   csr_wdata_s;          // CSR write data from mem_stage
    csr_op_e csr_wop_s;            // CSR RMW op from mem_stage
    logic    mret_s;               // MRET commit pulse from mem_stage

    // WB-stage register-file write port and canonical forwarding value
    logic            rd_wen_s;
    reg_idx_t        rd_addr_s;
    word_t           rd_data_s;
    exception_meta_t exception_s;
    retirement_event_t retire_s;

    // RV32F signals
    word_t   fs1_data_s, fs2_data_s, fs3_data_s;      // fp_regfile read ports
    word_t   fs1_fwd_s, fs2_fwd_s, fs3_fwd_s;          // forwarded FP operands
    word_t   fp_result_s;                              // FPU result → execute_stage
    fflags_t fp_fflags_s;                              // FPU flags → execute_stage
    logic [2:0] rm_resolved_s;                         // rounding mode (DYN resolved)
    // WB → fp_regfile write port + fcsr accrual
    logic     frd_wen_s;
    reg_idx_t frd_addr_s;
    word_t    frd_data_s;
    word_t    frd_fwd_data_s;
    logic     fflags_wen_s;
    fflags_t  fflags_val_s;
    logic     fs_dirty_s;

    // MUL/DIV unit signals
    word_t muldiv_result_s;
    logic  muldiv_busy_s;   // busy_q|start_i — drives muldiv_stall_i
    logic  muldiv_idle_s;   // ~busy_q (registered) — no combinational loop
    // start_i: one-cycle pulse. div_started_q prevents re-triggering: when the
    // 33-cycle divider finishes (busy_q→0), muldiv_idle_s immediately goes 1 in
    // the same delta, which would re-assert start_i and keep busy_o=1 forever.
    // div_started_q stays 1 until stall_ex_s deasserts (EX stage advances) or
    // flush_id_ex_s fires (DIV cancelled), ensuring exactly one start pulse per
    // DIV instruction.
    logic  muldiv_start_s;
    logic  div_started_q;

    always_ff @(posedge clk) begin
        if (rst || flush_id_ex_s)
            div_started_q <= 1'b0;
        else if (!stall_ex_s)
            div_started_q <= 1'b0;
        else if (muldiv_start_s)
            div_started_q <= 1'b1;
    end

    assign muldiv_start_s = id_ex_q.valid
                          & id_ex_q.decoded.is_long_latency
                          & muldiv_idle_s
                          & ~div_started_q;

    // FPU divide/sqrt handshake — same one-shot start pattern as the divider.
    logic fpu_busy_s, fpu_idle_s, fpu_start_s, fpu_started_q;
    logic fpu_is_ds_s;
    assign fpu_is_ds_s = id_ex_q.decoded.is_fp
                       & ((id_ex_q.decoded.fpu_op == FPU_DIV)
                        | (id_ex_q.decoded.fpu_op == FPU_SQRT));

    always_ff @(posedge clk) begin
        if (rst || flush_id_ex_s)
            fpu_started_q <= 1'b0;
        else if (!stall_ex_s)
            fpu_started_q <= 1'b0;
        else if (fpu_start_s)
            fpu_started_q <= 1'b1;
    end

    assign fpu_start_s = id_ex_q.valid
                       & fpu_is_ds_s
                       & fpu_idle_s
                       & ~fpu_started_q;

    // =========================================================================
    // IF stage — fetch unit
    //
    // fetch_unit drives imem_addr_o with the current PC and presents the
    // instruction received from imem_rdata_i as if_id_s to the IF/ID register.
    // if_id_s.valid is always 1 from the fetch unit; the IF/ID register
    // converts a flush into a bubble (valid = 0).
    // =========================================================================

    fetch_unit #(
        .RESET_VECTOR(RESET_VECTOR)
    ) u_fetch (
        .clk              (clk),
        .rst              (rst),
        .stall_i          (stall_if_s),
        .redirect_valid_i (redirect_valid_s),
        .redirect_target_i(redirect_target_s),
        .fetch_addr_o     (imem_addr_o),
        .fetch_addr_next_o(imem_addr_next_o),
        .instr_i          (imem_rdata_i),
        .instr_valid_i    (imem_valid_i),
        .if_id_o          (if_id_s)
    );

    // =========================================================================
    // IF/ID stage register
    // =========================================================================

    if_id_reg u_if_id_reg (
        .clk    (clk),
        .rst    (rst),
        .stall_i(stall_id_s),
        .flush_i(flush_if_id_s),
        .d_i    (if_id_s),
        .q_o    (if_id_q)
    );

    // =========================================================================
    // ID stage — decode and register file read
    //
    // The decoder (which internally instantiates imm_gen) produces the full
    // decoded_instr_t including the sign-extended immediate.
    // Register reads use the decoded rs1 / rs2 indices.
    // =========================================================================

    decoded_instr_t decoded_s;
    word_t          rs1_data_s, rs2_data_s;

    decoder u_decoder (
        .instr_i  (if_id_q.instr),
        .fs_off_i (fs_off_s),
        .decoded_o(decoded_s)
    );

    // =========================================================================
    // Deferred-load scoreboard (non-blocking dcache).
    // One entry, matching the cache's one MSHR. Set when an integer load's
    // miss is accepted in MEM (unless the exception flush is squashing that
    // load this very cycle); cleared when the fill returns. x0 loads defer
    // but are not tracked - their fill is discarded at the write port.
    // sb_*_s are the same-cycle views so a dependent sitting in ID stalls in
    // the defer cycle itself, not one cycle late.
    // =========================================================================
    logic     sb_pending_q;
    reg_idx_t sb_rd_q;
    logic     sb_set_s, sb_pending_s, sb_stall_s;
    reg_idx_t sb_rd_s;

    assign dmem_defer_ok_o = ex_mem_q.valid
                           & (ex_mem_q.decoded.is_store
                              | (ex_mem_q.decoded.is_load
                                 & ~ex_mem_q.decoded.writes_frd));

    assign sb_set_s = dmem_defer_i
                    & ex_mem_q.valid
                    & ex_mem_q.decoded.is_load
                    & ~ex_mem_q.decoded.writes_frd
                    & (ex_mem_q.decoded.rd != '0)
                    & ~flush_ex_mem_s;   // exception squashes the load: don't track

    assign sb_pending_s = sb_pending_q | sb_set_s;
    assign sb_rd_s      = sb_set_s ? ex_mem_q.decoded.rd : sb_rd_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            sb_pending_q <= 1'b0;
            sb_rd_q      <= '0;
        end else if (sb_set_s) begin
            sb_pending_q <= 1'b1;
            sb_rd_q      <= ex_mem_q.decoded.rd;
        end else if (dmem_fill_done_i) begin
            sb_pending_q <= 1'b0;
        end
    end

    regfile u_regfile (
        .clk       (clk),
        .rst       (rst),
        // Read port A — rs1
        .rs1_addr_i(decoded_s.rs1),
        .rs1_data_o(rs1_data_s),
        // Read port B — rs2
        .rs2_addr_i(decoded_s.rs2),
        .rs2_data_o(rs2_data_s),
        // Write port — from WB stage (wired below)
        .rd_wen_i  (rd_wen_s),
        .rd_addr_i (rd_addr_s),
        .rd_data_i (rd_data_s),
        // Fill port - deferred-load return (see scoreboard above)
        .fill_wen_i (dmem_fill_done_i & sb_pending_q),
        .fill_addr_i(sb_rd_q),
        .fill_data_i(dmem_fill_data_i)
    );

    // FP register file (RV32F). Three read ports for the FMADD family; the
    // FP register indices reuse the rs1/rs2 fields plus the dedicated fs3 field.
    fp_regfile u_fp_regfile (
        .clk       (clk),
        .rst       (rst),
        .fs1_addr_i(decoded_s.rs1),
        .fs1_data_o(fs1_data_s),
        .fs2_addr_i(decoded_s.rs2),
        .fs2_data_o(fs2_data_s),
        .fs3_addr_i(decoded_s.fs3),
        .fs3_data_o(fs3_data_s),
        .frd_wen_i (frd_wen_s),
        .frd_addr_i(frd_addr_s),
        .frd_data_i(frd_data_s)
    );

    // Assemble ID/EX payload
    always_comb begin
        id_ex_s.valid    = if_id_q.valid;
        id_ex_s.pc       = if_id_q.pc;
        id_ex_s.instr    = if_id_q.instr;
        id_ex_s.decoded  = decoded_s;
        id_ex_s.rs1_data = rs1_data_s;
        id_ex_s.rs2_data = rs2_data_s;
        id_ex_s.fs1_data = fs1_data_s;
        id_ex_s.fs2_data = fs2_data_s;
        id_ex_s.fs3_data = fs3_data_s;
    end

    // =========================================================================
    // ID/EX stage register
    // =========================================================================

    id_ex_reg u_id_ex_reg (
        .clk    (clk),
        .rst    (rst),
        .stall_i(stall_ex_s),
        .flush_i(flush_id_ex_s),
        .d_i    (id_ex_s),
        .q_o    (id_ex_q)
    );

    // =========================================================================
    // Forwarding unit
    //
    // Computes forwarded rs1/rs2 for the instruction currently in EX (id_ex_q)
    // and detects load-use hazards.  id_ex_fwd_s is id_ex_q with rs1_data and
    // rs2_data replaced by the forwarded values; this is what execute_stage sees.
    // =========================================================================

    forwarding_unit u_fwd (
        .id_ex_i          (id_ex_q),
        .ex_mem_i         (ex_mem_q),
        .mem_wb_i         (mem_wb_q),
        .mem_wb_rd_data_i (rd_data_s),
        .mem_wb_frd_data_i(frd_fwd_data_s),
        .id_decoded_i     (decoded_s),
        .id_valid_i       (if_id_q.valid),
        .rs1_fwd_o        (rs1_fwd_s),
        .rs2_fwd_o        (rs2_fwd_s),
        .fs1_fwd_o        (fs1_fwd_s),
        .fs2_fwd_o        (fs2_fwd_s),
        .fs3_fwd_o        (fs3_fwd_s),
        .load_use_stall_o (load_use_stall_s),
        .sb_pending_i     (sb_pending_s),
        .sb_rd_i          (sb_rd_s),
        .sb_stall_o       (sb_stall_s),
        .csr_raw_stall_o  (csr_raw_stall_s)
    );

    always_comb begin
        id_ex_fwd_s          = id_ex_q;
        id_ex_fwd_s.rs1_data = rs1_fwd_s;
        id_ex_fwd_s.rs2_data = rs2_fwd_s;
        id_ex_fwd_s.fs1_data = fs1_fwd_s;
        id_ex_fwd_s.fs2_data = fs2_fwd_s;
        id_ex_fwd_s.fs3_data = fs3_fwd_s;
    end

    // =========================================================================
    // EX stage — execute
    //
    // Receives id_ex_fwd_s (forwarded operands) rather than id_ex_q directly.
    // ex_mem_s is the COMBINATIONAL output, used by pipeline_ctrl in the same
    // cycle to generate redirect and flush signals.
    // =========================================================================

    // =========================================================================
    // CSR unit
    //
    // Combinatorial read: raddr_i driven from the EX-stage input; rdata_o
    // carried into execute_stage as csr_rdata_i → ex_mem_o.csr_rdata.
    // Write: driven from mem_stage outputs (csr_wen_s, etc.) when a CSR
    // instruction commits from the MEM stage.
    // Trap: driven from wb_stage exception outputs when an exception commits.
    // MRET: pulsed by mem_stage.mret_o when MRET instruction is in MEM.
    // mtvec_o / mepc_o feed pipeline_ctrl for exception / MRET redirects.
    // =========================================================================

    csr_unit #(
        .MTVEC_RESET(TRAP_VECTOR)
    ) u_csr (
        .clk          (clk),
        .rst          (rst),
        // Combinatorial read port (driven from EX stage input)
        .raddr_i      (id_ex_fwd_s.decoded.csr_addr),
        .rdata_o      (csr_rdata_s),
        // Write port (driven from MEM stage when CSR instruction commits)
        .wen_i        (csr_wen_s),
        .waddr_i      (csr_waddr_s),
        .wdata_i      (csr_wdata_s),
        .wop_i        (csr_wop_s),
        // Trap entry (driven from WB stage when exception commits)
        .trap_i       (exception_s.valid),
        .trap_epc_i   (exception_pc_o),
        // mcause: interrupt bit 31 from is_irq, cause code in the low bits
        .trap_cause_i ({exception_s.is_irq, 27'b0, exception_s.cause}),
        .trap_tval_i  (exception_s.tval),
        // MRET commit (pulsed by MEM stage when MRET instruction is there)
        .mret_i       (mret_s),
        .retire_i     (retire_s.valid),
        // RV32F fcsr accrual (from WB stage)
        .dc_hits_i    (dc_hits_i),
        .dc_misses_i  (dc_misses_i),
        .ic_hits_i    (ic_hits_i),
        .ic_misses_i  (ic_misses_i),
        .fflags_wen_i (fflags_wen_s),
        .fflags_i     (fflags_val_s),
        .fs_dirty_i   (fs_dirty_s),
        // Interrupt lines from the CLINT
        .mtip_i       (mtip_i),
        .msip_i       (msip_i),
        .mtime_i      (mtime_i),
        // Redirect targets for pipeline_ctrl
        .mtvec_o      (mtvec_s),
        .mepc_o       (mepc_s),
        .irq_pending_o(irq_pending_s),
        .irq_cause_o  (irq_cause_s),
        // RV32F: FP-disabled gate to the decoder + dynamic rounding mode.
        // fflags accrual / fs-dirty inputs are tied off until the FPU lands
        // (Phase C); they default to 0 and keep FS/fflags inert for now.
        .fs_off_o     (fs_off_s),
        .frm_o        (frm_s)
    );

    // =========================================================================
    // MUL/DIV unit
    //
    // rs1/rs2/op are wired to id_ex_fwd_s (the same forwarded values that
    // execute_stage sees).  MUL results are combinationally valid every cycle.
    // For DIV: start_i fires for one cycle when the DIV instruction first enters
    // EX (id_ex_q.valid & is_long_latency & !busy); operands are registered
    // inside the unit; busy_o freezes the pipeline for 33 cycles.
    // =========================================================================

    mul_div_unit u_muldiv (
        .clk      (clk),
        .rst      (rst),
        .rs1_i    (id_ex_fwd_s.rs1_data),
        .rs2_i    (id_ex_fwd_s.rs2_data),
        .op_i     (id_ex_fwd_s.decoded.alu_op),
        .start_i  (muldiv_start_s),
        .result_o (muldiv_result_s),
        .busy_o   (muldiv_busy_s),
        .idle_o   (muldiv_idle_s)
    );

    // =========================================================================
    // FPU (RV32F) — single-cycle combinational ops (mul/add/sub + short ops).
    // Fed the forwarded FP operands and the resolved rounding mode; the result
    // and IEEE flags are captured into ex_mem by execute_stage.  Div/sqrt and
    // the fused multiply-add arrive in Phase D.
    // =========================================================================
    // Resolve the rounding mode: a static frm from the instruction, or the
    // dynamic fcsr.frm when the encoded field is DYN (0b111).
    assign rm_resolved_s = (id_ex_fwd_s.decoded.frm == FRM_DYN)
                         ? frm_s : id_ex_fwd_s.decoded.frm;

    fpu u_fpu (
        .clk     (clk),
        .rst     (rst),
        .fs1_i   (id_ex_fwd_s.fs1_data),
        .fs2_i   (id_ex_fwd_s.fs2_data),
        .fs3_i   (id_ex_fwd_s.fs3_data),
        .xrs1_i  (id_ex_fwd_s.rs1_data),   // integer rs1 for FCVT.S.W[U] / FMV.W.X
        .op_i    (id_ex_fwd_s.decoded.fpu_op),
        .rm_i    (rm_resolved_s),
        .start_i (fpu_start_s),
        .busy_o  (fpu_busy_s),
        .idle_o  (fpu_idle_s),
        .result_o(fp_result_s),
        .fflags_o(fp_fflags_s)
    );

    execute_stage u_execute (
        .id_ex_i        (id_ex_fwd_s),
        .csr_rdata_i    (csr_rdata_s),
        .muldiv_result_i(muldiv_result_s),
        .fp_result_i    (fp_result_s),
        .fp_fflags_i    (fp_fflags_s),
        .ex_mem_o       (ex_mem_s)
    );

    // -------------------------------------------------------------------------
    // Interrupt injection — tag the valid instruction leaving EX.
    //
    // The tagged instruction travels to MEM and WB like a synchronous
    // exception: its store / CSR write / rd write are suppressed (mem_stage
    // gates on decoded.exception.valid), it does not retire, and when it
    // reaches WB the trap gate sets mepc to its PC — the first un-executed
    // instruction — and flushes the pipeline to the trap vector.
    //
    // Injection happens at EX (never WB): stores commit at the end of MEM, so
    // interrupting at WB would require replaying a committed store.
    // Interrupts are level-sensitive; if EX holds a bubble the request simply
    // waits for the next valid instruction.  An interrupt outranks a
    // same-instruction synchronous exception (the instruction is re-executed
    // after the handler returns, re-raising the sync exception then).
    // -------------------------------------------------------------------------
    always_comb begin
        ex_mem_tag_s = ex_mem_s;
        // Fetch misalignment: a taken control transfer whose target is not
        // 4-byte aligned raises EXC_INSTR_ADDR_MISALIGNED on the transfer
        // instruction itself (mtval = the bad target).  The transient
        // redirect is harmless: every wrong-path fetch is flushed when the
        // exception commits in WB.
        if (ex_mem_s.valid
            & (ex_mem_s.branch_taken
               | (ex_mem_s.decoded.is_jump & ex_mem_s.decoded.legal))
            & (ex_mem_s.branch_target[1:0] != 2'b00)
            & ~ex_mem_s.decoded.exception.valid) begin
            ex_mem_tag_s.decoded.exception.valid  = 1'b1;
            ex_mem_tag_s.decoded.exception.is_irq = 1'b0;
            ex_mem_tag_s.decoded.exception.cause  = EXC_INSTR_ADDR_MISALIGNED;
            ex_mem_tag_s.decoded.exception.tval   = ex_mem_s.branch_target;
            // Do not redirect into the misaligned target
            ex_mem_tag_s.branch_taken = 1'b0;
        end
        if (irq_pending_s & ex_mem_s.valid) begin
            ex_mem_tag_s.decoded.exception.valid  = 1'b1;
            ex_mem_tag_s.decoded.exception.is_irq = 1'b1;
            ex_mem_tag_s.decoded.exception.cause  = exc_cause_e'(irq_cause_s);
            ex_mem_tag_s.decoded.exception.tval   = '0;
        end
    end

    // =========================================================================
    // EX/MEM stage register
    // =========================================================================

    ex_mem_reg u_ex_mem_reg (
        .clk    (clk),
        .rst    (rst),
        .stall_i(stall_mem_s),
        .flush_i(flush_ex_mem_s),
        .d_i    (ex_mem_tag_s),
        .q_o    (ex_mem_q)
    );

    // =========================================================================
    // MEM stage — data memory access
    // =========================================================================

    mem_stage u_mem (
        .ex_mem_i   (ex_mem_q),
        .mem_addr_o (dmem_addr_o),
        .mem_wen_o  (dmem_wen_o),
        .mem_wstrb_o(dmem_wstrb_o),
        .mem_wdata_o(dmem_wdata_o),
        .mem_rdata_i(dmem_rdata_i),
        .dmem_defer_i(dmem_defer_i),
        .csr_wen_o  (csr_wen_s),
        .csr_waddr_o(csr_waddr_s),
        .csr_wdata_o(csr_wdata_s),
        .csr_wop_o  (csr_wop_s),
        .mret_o     (mret_s),
        .mem_wb_o   (mem_wb_s)
    );

    // =========================================================================
    // MEM/WB stage register
    // =========================================================================

    mem_wb_reg u_mem_wb_reg (
        .clk    (clk),
        .rst    (rst),
        .stall_i(stall_wb_s),
        .flush_i(flush_mem_wb_s),
        .d_i    (mem_wb_s),
        .q_o    (mem_wb_q)
    );

    // =========================================================================
    // WB stage — register file write and retirement
    // =========================================================================

    wb_stage u_wb (
        .mem_wb_i      (mem_wb_q),
        .dmem_rdata_i  (dmem_rdata_i),
        .stall_i       (stall_wb_s),
        .rd_addr_o     (rd_addr_s),
        .rd_data_o     (rd_data_s),
        .rd_wen_o      (rd_wen_s),
        // RV32F: FP register write port + fcsr accrual
        .frd_addr_o    (frd_addr_s),
        .frd_data_o    (frd_data_s),
        .frd_wen_o     (frd_wen_s),
        .frd_fwd_data_o(frd_fwd_data_s),
        .fflags_wen_o  (fflags_wen_s),
        .fflags_o      (fflags_val_s),
        .fs_dirty_o    (fs_dirty_s),
        .retire_o      (retire_s),
        .exception_o   (exception_s),
        .exception_pc_o(exception_pc_o)
    );

    // Retire output is already driven directly by wb_stage.
    // Exception outputs to top level:
    assign retire_o    = retire_s;
    assign exception_o = exception_s;
    // Load-in-MEM indicator: used by dcache to assert cpu_ren_i correctly.
    assign dmem_ren_o  = ex_mem_q.valid & ex_mem_q.decoded.is_load & ~exception_s.valid;

    // =========================================================================
    // Pipeline control unit
    //
    // Observes ex_mem_s (combinational EX output, not the registered ex_mem_q)
    // so that branch/jump flushes are generated in the same cycle the branch
    // resolves, producing the correct 2-cycle penalty without an extra delay.
    // =========================================================================

    // FENCE.I detection from the raw encoding in EX (MISC_MEM, funct3=001).
    // No decoder/payload change needed: the instruction word rides in every
    // pipeline payload. Uses the tagged EX view so an interrupt-tagged
    // FENCE.I traps instead of flushing.
    assign fencei_flush_o = ex_mem_tag_s.valid
                          & ex_mem_tag_s.decoded.legal
                          & ~ex_mem_tag_s.decoded.exception.valid
                          & (ex_mem_tag_s.instr[6:0]   == 7'b0001111)
                          & (ex_mem_tag_s.instr[14:12] == 3'b001);

    pipeline_ctrl u_pctrl (
        .ex_mem_i        (ex_mem_tag_s),
        .fencei_i        (fencei_flush_o),
        .exception_i     (exception_s),
        .trap_vector_i   (mtvec_s),
        .mepc_i          (mepc_s),
        .load_use_stall_i(load_use_stall_s | sb_stall_s),
        .csr_raw_stall_i (csr_raw_stall_s),
        .dmem_stall_i    (dmem_stall_i),
        .muldiv_stall_i  (muldiv_busy_s),
        .fpu_stall_i     (fpu_busy_s),
        .stall_if_o      (stall_if_s),
        .stall_id_o      (stall_id_s),
        .stall_ex_o      (stall_ex_s),
        .stall_mem_o     (stall_mem_s),
        .stall_wb_o      (stall_wb_s),
        .flush_if_id_o   (flush_if_id_s),
        .flush_id_ex_o   (flush_id_ex_s),
        .flush_ex_mem_o  (flush_ex_mem_s),
        .flush_mem_wb_o  (flush_mem_wb_s),
        .redirect_valid_o(redirect_valid_s),
        .redirect_target_o(redirect_target_s)
    );

endmodule : fluxcore_top

`default_nettype wire
