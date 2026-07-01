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

    // --- Data memory (word-wide with byte enables) ---
    output word_t             dmem_addr_o,   // effective byte address
    output logic              dmem_ren_o,    // 1 = load is in MEM stage (connect to dcache cpu_ren_i)
    output logic              dmem_wen_o,    // write enable (stores, gated on exceptions)
    output logic [3:0]        dmem_wstrb_o,  // byte enables
    output word_t             dmem_wdata_o,  // store write data
    input  wire word_t             dmem_rdata_i,  // load read data
    input  wire logic              dmem_stall_i,  // 1 = cache miss, stall all stages

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
    word_t   csr_rdata_s;          // combinatorial read from csr_unit (→ execute_stage)
    word_t   mtvec_s, mepc_s;      // csr_unit outputs used for redirects
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
        .decoded_o(decoded_s)
    );

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
        .rd_data_i (rd_data_s)
    );

    // Assemble ID/EX payload
    always_comb begin
        id_ex_s.valid    = if_id_q.valid;
        id_ex_s.pc       = if_id_q.pc;
        id_ex_s.instr    = if_id_q.instr;
        id_ex_s.decoded  = decoded_s;
        id_ex_s.rs1_data = rs1_data_s;
        id_ex_s.rs2_data = rs2_data_s;
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
        .id_ex_i         (id_ex_q),
        .ex_mem_i        (ex_mem_q),
        .mem_wb_i        (mem_wb_q),
        .mem_wb_rd_data_i(rd_data_s),
        .id_decoded_i    (decoded_s),
        .id_valid_i      (if_id_q.valid),
        .rs1_fwd_o       (rs1_fwd_s),
        .rs2_fwd_o       (rs2_fwd_s),
        .load_use_stall_o(load_use_stall_s),
        .csr_raw_stall_o (csr_raw_stall_s)
    );

    always_comb begin
        id_ex_fwd_s          = id_ex_q;
        id_ex_fwd_s.rs1_data = rs1_fwd_s;
        id_ex_fwd_s.rs2_data = rs2_fwd_s;
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
        .trap_cause_i ({28'b0, exception_s.cause}),
        .trap_tval_i  (exception_s.tval),
        // MRET commit (pulsed by MEM stage when MRET instruction is there)
        .mret_i       (mret_s),
        .retire_i     (retire_s.valid),
        // Redirect targets for pipeline_ctrl
        .mtvec_o      (mtvec_s),
        .mepc_o       (mepc_s)
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

    execute_stage u_execute (
        .id_ex_i        (id_ex_fwd_s),
        .csr_rdata_i    (csr_rdata_s),
        .muldiv_result_i(muldiv_result_s),
        .ex_mem_o       (ex_mem_s)
    );

    // =========================================================================
    // EX/MEM stage register
    // =========================================================================

    ex_mem_reg u_ex_mem_reg (
        .clk    (clk),
        .rst    (rst),
        .stall_i(stall_mem_s),
        .flush_i(flush_ex_mem_s),
        .d_i    (ex_mem_s),
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

    pipeline_ctrl u_pctrl (
        .ex_mem_i        (ex_mem_s),
        .exception_i     (exception_s),
        .trap_vector_i   (mtvec_s),
        .mepc_i          (mepc_s),
        .load_use_stall_i(load_use_stall_s),
        .csr_raw_stall_i (csr_raw_stall_s),
        .dmem_stall_i    (dmem_stall_i),
        .muldiv_stall_i  (muldiv_busy_s),
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
