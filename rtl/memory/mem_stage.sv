`default_nettype none

// mem_stage — purely combinational MEM stage datapath.
//
// Receives an ex_mem_payload_t (from the EX/MEM stage register) and produces:
//   • Data memory read/write signals for the data SRAM or BRAM wrapper.
//   • A mem_wb_payload_t for the MEM/WB stage register to latch.
//
// Memory model assumed here:
//   The memory is word-wide (32 bits) with byte-enable writes.
//   mem_addr_o is the byte address of the access (alu_result from EX stage).
//   On loads, the memory returns mem_rdata_i as the 32-bit word that contains
//   the requested byte/halfword. This module extracts and sign/zero-extends it.
//   On stores, mem_wstrb_o selects which bytes to write; mem_wdata_o carries
//   the data replicated to the appropriate byte lanes.
//   mem_wen_o gates all writes; it is 0 for non-store instructions, illegal
//   instructions, and instructions with a misalignment exception.
//
// Misalignment detection (RV32I §2.6):
//   LH/LHU/SH: faulting if alu_result[0] == 1  (not 2-byte aligned)
//   LW/SW:      faulting if alu_result[1:0] != 00 (not 4-byte aligned)
//   Faulting loads: suppress rd_wen; raise EXC_LOAD_ADDR_MISALIGNED.
//   Faulting stores: suppress mem_wen_o; raise EXC_STORE_ADDR_MISALIGNED.
//   Misalignment is only checked when the prior decoded exception is absent
//   (decoded.legal=1 and decoded.exception.valid=0).
//
// Exception priority:
//   Decode-time exceptions (illegal instruction, ECALL, EBREAK) take
//   precedence. A misalignment exception can only be raised when the
//   instruction reached the MEM stage legally.
//
// Writeback source mux (wb_src):
//   WB_ALU → ex_mem_i.alu_result   (integer arithmetic, LUI, AUIPC)
//   WB_MEM → sign/zero-extended load data
//   WB_PC4 → ex_mem_i.pc + 4       (JAL, JALR link register)
//   WB_CSR → ex_mem_i.csr_rdata    (old CSR value captured in EX — returned to rd)
//   WB_NONE→ 32'h0                  (branches, stores — rd_wen=0 anyway)
//
// CSR write outputs (wired to csr_unit at fluxcore_top level):
//   csr_wen_o / csr_waddr_o / csr_wdata_o / csr_wop_o commit the write when a
//   CSR instruction is in the MEM stage and the instruction is legal.
//   ex_mem_i.rs2_data carries the write source: rs1 for register forms,
//   zero-extended zimm for immediate forms (set by execute_stage).
//
// mret_o: asserted for one cycle when an MRET instruction is in the MEM stage.
//   Wired to csr_unit.mret_i to update MIE←MPIE, MPIE←1.
//   The pipeline redirect to mepc happens one cycle earlier in pipeline_ctrl
//   (when MRET is observed in the EX combinational output).

module mem_stage
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
    import pipeline_pkg::*;
(
    input  wire ex_mem_payload_t ex_mem_i,

    // Data memory interface
    output word_t           mem_addr_o,   // byte address (alu_result)
    output logic            mem_wen_o,    // write enable (stores only, gated on exceptions)
    output logic [3:0]      mem_wstrb_o,  // byte enables
    output word_t           mem_wdata_o,  // write data aligned to 32-bit word lanes
    input  wire word_t           mem_rdata_i,  // 32-bit word returned by memory

    // Non-blocking dcache: this cycle's MEM-stage miss was accepted (MSHR).
    // The load retires with deferred=1 and no rd write; the fill port
    // delivers the data later. Tied off in blocking configurations.
    input  wire logic            dmem_defer_i = 1'b0,

    // RV32A (raw-detected from ex_mem_i.instr; decoder marked legality):
    //   amo_phase_w_i — 1 during an AMO's write phase (top-level FSM).
    //   res_*        — LR/SC reservation state (register lives in the top).
    input  wire logic            amo_phase_w_i = 1'b0,
    input  wire logic            res_valid_i   = 1'b0,
    input  wire word_t           res_addr_i    = '0,
    output logic                 res_set_o,    // LR completing: set reservation
    output logic                 res_clr_o,    // committed store / any SC: clear

    // CSR write interface (wire to csr_unit in fluxcore_top)
    output logic            csr_wen_o,    // CSR write enable
    output logic [11:0]     csr_waddr_o,  // CSR write address
    output word_t           csr_wdata_o,  // CSR write source (rs1 or zimm)
    output csr_op_e         csr_wop_o,    // WRITE / SET / CLR
    output logic            mret_o,       // MRET commit pulse (MIE←MPIE in csr_unit)

    output mem_wb_payload_t mem_wb_o
);

    // -----------------------------------------------------------------------
    // Byte / halfword offset within the 32-bit memory word
    // -----------------------------------------------------------------------
    logic [1:0] byte_off_s;
    logic       half_off_s;

    assign byte_off_s = ex_mem_i.alu_result[1:0];
    assign half_off_s = ex_mem_i.alu_result[1];

    // -----------------------------------------------------------------------
    // Byte / halfword extraction from the 32-bit memory read word
    //
    // The memory returns the full word; we mux the appropriate byte or
    // halfword based on the byte offset in the effective address.
    // -----------------------------------------------------------------------
    logic [7:0]  byte_s;
    logic [15:0] half_s;

    always_comb begin
        case (byte_off_s)
            2'd0: byte_s = mem_rdata_i[ 7: 0];
            2'd1: byte_s = mem_rdata_i[15: 8];
            2'd2: byte_s = mem_rdata_i[23:16];
            2'd3: byte_s = mem_rdata_i[31:24];
        endcase
    end

    always_comb begin
        case (half_off_s)
            1'd0: half_s = mem_rdata_i[15: 0];
            1'd1: half_s = mem_rdata_i[31:16];
        endcase
    end

    // -----------------------------------------------------------------------
    // Sign / zero-extended load result
    // -----------------------------------------------------------------------
    word_t load_data_s;

    always_comb begin
        load_data_s = '0;
        case (ex_mem_i.decoded.mem_op)
            MEM_LB:  load_data_s = {{24{byte_s[7]}}, byte_s};
            MEM_LBU: load_data_s = {24'h0,            byte_s};
            MEM_LH:  load_data_s = {{16{half_s[15]}}, half_s};
            MEM_LHU: load_data_s = {16'h0,             half_s};
            MEM_LW:  load_data_s = mem_rdata_i;
            default: load_data_s = '0;
        endcase
    end

    // -----------------------------------------------------------------------
    // Store byte enables and lane-replicated write data
    //
    // The memory controller uses wstrb to select which byte lanes to update.
    // Replicating rs2_data to all lanes means the controller can blindly
    // write all four bytes and rely solely on wstrb for selection.
    // -----------------------------------------------------------------------
    // ---- RV32A decode-from-raw (FENCE.I precedent: no payload change) ----
    logic       amo_class_s, amo_is_lr_s, amo_is_sc_s, amo_is_op_s, sc_ok_s;
    logic [4:0] amo_f5_s;
    assign amo_f5_s    = ex_mem_i.instr[31:27];
    assign amo_class_s = ex_mem_i.valid
                       & (ex_mem_i.instr[6:0] == OPCODE_AMO)
                       & ex_mem_i.decoded.legal
                       & ~ex_mem_i.decoded.exception.valid;
    assign amo_is_lr_s = amo_class_s & (amo_f5_s == 5'b00010);
    assign amo_is_sc_s = amo_class_s & (amo_f5_s == 5'b00011);
    assign amo_is_op_s = amo_class_s & ~amo_is_lr_s & ~amo_is_sc_s;
    // SC succeeds iff the reservation covers this word address.
    assign sc_ok_s     = res_valid_i & (res_addr_i == ex_mem_i.alu_result);

    // AMO ALU: new = f(old, rs2). Old value = mem_rdata_i, which still
    // presents the phase-R capture during the write phase (no read between).
    word_t amo_old_s, amo_result_s;
    assign amo_old_s = mem_rdata_i;
    always_comb begin
        unique case (amo_f5_s)
            5'b00001: amo_result_s = ex_mem_i.rs2_data;                 // SWAP
            5'b00000: amo_result_s = amo_old_s + ex_mem_i.rs2_data;     // ADD
            5'b00100: amo_result_s = amo_old_s ^ ex_mem_i.rs2_data;     // XOR
            5'b01100: amo_result_s = amo_old_s & ex_mem_i.rs2_data;     // AND
            5'b01000: amo_result_s = amo_old_s | ex_mem_i.rs2_data;     // OR
            5'b10000: amo_result_s = ($signed(amo_old_s) < $signed(ex_mem_i.rs2_data))
                                   ? amo_old_s : ex_mem_i.rs2_data;     // MIN
            5'b10100: amo_result_s = ($signed(amo_old_s) > $signed(ex_mem_i.rs2_data))
                                   ? amo_old_s : ex_mem_i.rs2_data;     // MAX
            5'b11000: amo_result_s = (amo_old_s < ex_mem_i.rs2_data)
                                   ? amo_old_s : ex_mem_i.rs2_data;     // MINU
            5'b11100: amo_result_s = (amo_old_s > ex_mem_i.rs2_data)
                                   ? amo_old_s : ex_mem_i.rs2_data;     // MAXU
            default:  amo_result_s = ex_mem_i.rs2_data;
        endcase
    end

    logic [3:0] wstrb_s;
    word_t      wdata_s;
    // Store data source: FSW (uses_fs2) writes the FP operand fp_store_data;
    // integer stores use rs2_data. (Only FSW sets uses_fs2 among stores.)
    word_t      store_src_s;
    assign store_src_s = ex_mem_i.decoded.uses_fs2 ? ex_mem_i.fp_store_data
                                                   : ex_mem_i.rs2_data;

    always_comb begin
        wstrb_s = 4'b0000;
        wdata_s = '0;
        case (ex_mem_i.decoded.mem_op)
            MEM_SB: begin
                wstrb_s = 4'b0001 << byte_off_s;
                wdata_s = {4{store_src_s[7:0]}};
            end
            MEM_SH: begin
                wstrb_s = half_off_s ? 4'b1100 : 4'b0011;
                wdata_s = {2{store_src_s[15:0]}};
            end
            MEM_SW: begin
                wstrb_s = 4'b1111;
                wdata_s = store_src_s;
            end
            default: begin
                wstrb_s = 4'b0000;
                wdata_s = '0;
            end
        endcase
    end

    // -----------------------------------------------------------------------
    // Misalignment exception detection
    //
    // Only active when the instruction is legal and has no prior exception.
    // A prior exception (legal=0 → exception.valid=1, or ECALL/EBREAK)
    // propagates unchanged; misalignment is not checked in that case.
    // -----------------------------------------------------------------------
    logic            new_exc_s;
    exception_meta_t exc_s;

    always_comb begin
        new_exc_s = 1'b0;
        exc_s     = ex_mem_i.decoded.exception;   // forward decode exception by default

        if (ex_mem_i.decoded.legal && !ex_mem_i.decoded.exception.valid) begin

            if (ex_mem_i.decoded.is_load) begin
                case (ex_mem_i.decoded.mem_op)
                    MEM_LH, MEM_LHU: begin
                        if (ex_mem_i.alu_result[0]) begin
                            new_exc_s   = 1'b1;
                            exc_s.valid = 1'b1;
                            exc_s.cause = EXC_LOAD_ADDR_MISALIGNED;
                            exc_s.tval  = ex_mem_i.alu_result;
                        end
                    end
                    MEM_LW: begin
                        if (ex_mem_i.alu_result[1:0] != 2'b00) begin
                            new_exc_s   = 1'b1;
                            exc_s.valid = 1'b1;
                            // AMO*.W raise the store/AMO cause (spec); LR.W
                            // and plain loads the load cause.
                            exc_s.cause = amo_is_op_s ? EXC_STORE_ADDR_MISALIGNED
                                                      : EXC_LOAD_ADDR_MISALIGNED;
                            exc_s.tval  = ex_mem_i.alu_result;
                        end
                    end
                    default: ;
                endcase
            end

            if (ex_mem_i.decoded.is_store) begin
                case (ex_mem_i.decoded.mem_op)
                    MEM_SH: begin
                        if (ex_mem_i.alu_result[0]) begin
                            new_exc_s   = 1'b1;
                            exc_s.valid = 1'b1;
                            exc_s.cause = EXC_STORE_ADDR_MISALIGNED;
                            exc_s.tval  = ex_mem_i.alu_result;
                        end
                    end
                    MEM_SW: begin
                        if (ex_mem_i.alu_result[1:0] != 2'b00) begin
                            new_exc_s   = 1'b1;
                            exc_s.valid = 1'b1;
                            exc_s.cause = EXC_STORE_ADDR_MISALIGNED;
                            exc_s.tval  = ex_mem_i.alu_result;
                        end
                    end
                    default: ;
                endcase
            end

        end
    end

    // -----------------------------------------------------------------------
    // Data memory outputs
    // -----------------------------------------------------------------------
    assign mem_addr_o  = ex_mem_i.alu_result;
    assign mem_wen_o   = ex_mem_i.valid
                       & ex_mem_i.decoded.legal
                       & ~ex_mem_i.decoded.exception.valid
                       & ~new_exc_s
                       & ( (ex_mem_i.decoded.is_store & ~amo_is_sc_s)  // plain
                         | (amo_is_sc_s & sc_ok_s)                     // SC ok
                         | (amo_is_op_s & amo_phase_w_i) );            // AMO W
    assign mem_wstrb_o = (amo_is_op_s & amo_phase_w_i) ? 4'hF : wstrb_s;
    assign mem_wdata_o = (amo_is_op_s & amo_phase_w_i) ? amo_result_s : wdata_s;

    // Reservation control (committed by the top when MEM completes unflushed)
    assign res_set_o = amo_is_lr_s & ~new_exc_s;
    assign res_clr_o = mem_wen_o | amo_is_sc_s;   // any SC clears, even a failed one

    // -----------------------------------------------------------------------
    // Writeback data mux
    // -----------------------------------------------------------------------
    word_t rd_data_s;

    always_comb begin
        rd_data_s = '0;
        case (ex_mem_i.decoded.wb_src)
            WB_ALU: rd_data_s = ex_mem_i.alu_result;
            WB_MEM: rd_data_s = load_data_s;
            WB_PC4: rd_data_s = ex_mem_i.pc + 32'd4;
            WB_CSR: rd_data_s = ex_mem_i.csr_rdata;  // old value read in EX
            WB_FPU: rd_data_s = ex_mem_i.fp_result;  // FP→int (FCMP/FCVT.W/FMV.X/FCLASS)
            default: rd_data_s = '0;
        endcase
    end

    // -----------------------------------------------------------------------
    // CSR write outputs
    // Gated on: valid, is_csr, legal, no exception raised in MEM (new_exc_s).
    // CSR instructions never touch memory so new_exc_s is always 0 for them;
    // the gate is nonetheless included for defensive correctness.
    // rs2_data carries the write source operand (set by execute_stage).
    // -----------------------------------------------------------------------
    assign csr_wen_o   = ex_mem_i.valid
                       & ex_mem_i.decoded.is_csr
                       & ex_mem_i.decoded.legal
                       & (ex_mem_i.decoded.csr_op != CSR_NOP)
                       & ~ex_mem_i.decoded.exception.valid
                       & ~new_exc_s;
    assign csr_waddr_o = ex_mem_i.decoded.csr_addr;
    assign csr_wdata_o = ex_mem_i.rs2_data;
    assign csr_wop_o   = ex_mem_i.decoded.csr_op;

    // -----------------------------------------------------------------------
    // MRET commit pulse
    // Asserted for one cycle when a legal MRET reaches the MEM stage.
    // pipeline_ctrl already flushed IF/ID+ID/EX and redirected PC to mepc
    // one cycle earlier (when MRET was in EX). This pulse updates csr_unit's
    // mstatus: MIE←MPIE, MPIE←1.
    // -----------------------------------------------------------------------
    assign mret_o = ex_mem_i.valid & ex_mem_i.decoded.is_mret
                  & ex_mem_i.decoded.legal
                  & ~ex_mem_i.decoded.exception.valid;

    // -----------------------------------------------------------------------
    // Assemble MEM/WB payload
    // -----------------------------------------------------------------------
    always_comb begin
        mem_wb_o.valid     = ex_mem_i.valid;
        mem_wb_o.pc        = ex_mem_i.pc;
        mem_wb_o.instr     = ex_mem_i.instr;
        // Suppress writeback when: instruction is illegal, or a new memory
        // misalignment exception was raised in this stage.
        // A deferred integer load must not write rd in WB (the fill write
        // does) and must not be forwarded from (its rd_data is garbage) —
        // clearing rd_wen accomplishes both.
        mem_wb_o.deferred  = ex_mem_i.valid
                           & ex_mem_i.decoded.is_load
                           & ~ex_mem_i.decoded.writes_frd
                           & dmem_defer_i;
        mem_wb_o.rd_wen    = ex_mem_i.decoded.writes_rd
                           & ex_mem_i.decoded.legal
                           & ~ex_mem_i.decoded.exception.valid
                           & ~new_exc_s
                           & ~mem_wb_o.deferred;
        mem_wb_o.rd_addr   = ex_mem_i.decoded.rd;
        // SC.W: rd is the success flag (0 = stored), not a datapath value.
        mem_wb_o.rd_data   = amo_is_sc_s ? {31'b0, ~sc_ok_s} : rd_data_s;
        mem_wb_o.rd_from_mem  = ex_mem_i.valid
                              & ex_mem_i.decoded.legal
                              & ~new_exc_s
                              & (ex_mem_i.decoded.wb_src == WB_MEM);
        mem_wb_o.mem_byte_off = ex_mem_i.alu_result[1:0];
        mem_wb_o.exception = exc_s;
        // ---- RV32F writeback ----
        // FP register write: FP-producing ops (writes_frd) and FLW (is_load &
        // writes_frd, data from memory).  Gated like the integer rd write.
        mem_wb_o.frd_wen    = ex_mem_i.decoded.writes_frd
                            & ex_mem_i.decoded.legal
                            & ~ex_mem_i.decoded.exception.valid
                            & ~new_exc_s;
        mem_wb_o.frd_addr   = ex_mem_i.decoded.rd;   // frd shares the rd field
        // FLW routes the loaded word; compute ops route fp_result. For FLW the
        // final word is recomputed from live memory in WB (fp_from_mem), mirroring
        // the integer load path; frd_data holds the combinational-sim value.
        mem_wb_o.frd_data   = ex_mem_i.decoded.is_load ? load_data_s
                                                       : ex_mem_i.fp_result;
        mem_wb_o.fp_from_mem = ex_mem_i.decoded.is_load & ex_mem_i.decoded.writes_frd;
        // fflags accrual: only FP compute ops set flags (is_fp); FLW/FSW do not.
        mem_wb_o.fflags_wen = ex_mem_i.valid
                            & ex_mem_i.decoded.is_fp
                            & ex_mem_i.decoded.legal
                            & ~ex_mem_i.decoded.exception.valid;
        mem_wb_o.fflags     = ex_mem_i.fflags;
    end

endmodule : mem_stage

`default_nettype wire
