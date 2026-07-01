// rtl/common/pipeline_pkg.sv
//
// FluxCore inter-stage pipeline payload types.
//
// Purpose:
//   Defines the four packed structs that are registered at each pipeline
//   stage boundary. Every stage module imports this package alongside
//   fluxcore_pkg and rv32_isa_pkg.
//
// Stage boundaries:
//   IF  →[if_id_reg]→  ID  →[id_ex_reg]→  EX  →[ex_mem_reg]→  MEM  →[mem_wb_reg]→  WB
//         if_id_payload_t    id_ex_payload_t    ex_mem_payload_t    mem_wb_payload_t
//
// Validity:
//   Every payload carries a `valid` bit. An invalid payload ("bubble") has
//   valid=0 and all other fields must be treated as don't-care by the
//   receiving stage. Bubbles are inserted by:
//     - Reset (all stage registers hold a zeroed, invalid payload)
//     - Pipeline flush (redirect overwrites stage registers with bubbles)
//     - Stall of an upstream stage (a downstream stage receives a bubble
//       when the upstream stage is stalled and the downstream stage is not)
//
// Exception propagation:
//   An instruction with a decode-time exception (legal=0 in decoded_instr_t)
//   is carried through the pipeline as a valid payload. The exception field
//   inside decoded_instr_t triggers exception handling in the WB stage.
//   No ALU computation, memory access, or register writeback occurs for
//   such instructions — the pipeline gates all side effects on legal=1.
//
// Forwarding design:
//   rs1_data and rs2_data in id_ex_payload_t hold the register-file read
//   values at the time of the ID stage. The forwarding unit (future module)
//   muxes these with EX/MEM or MEM/WB stage results before the ALU consumes
//   them. This module does not model forwarding; it only defines the payload
//   interfaces through which data flows.
//
// AUIPC and JAL operand convention:
//   For AUIPC and JAL, the execute stage must use PC as ALU operand A rather
//   than rs1_data. The stage identifies this case by checking:
//     (decoded.op_class == OPCLASS_JUMP) ||
//     (decoded.op_class == OPCLASS_ALU && !decoded.uses_rs1)
//   A dedicated `opa_src` field will be added to id_ex_payload_t once the
//   execute stage module is written and the exact mux terms are confirmed.
//
// Packed widths (for testbench and differential testing reference):
//   if_id_payload_t  : 1 + XLEN + INSTR_W                = 65 bits
//   id_ex_payload_t  : 1 + XLEN + INSTR_W + $bits(decoded_instr_t) + XLEN + XLEN
//                    = 1 + 32 + 32 + 127 + 32 + 32       = 256 bits
//   ex_mem_payload_t : 1 + XLEN + INSTR_W + $bits(decoded_instr_t)
//                      + XLEN + XLEN + 1 + XLEN + XLEN (csr_rdata)
//                    = 1 + 32 + 32 + 127 + 32 + 32 + 1 + 32 + 32 = 321 bits
//   mem_wb_payload_t : 1 + XLEN + INSTR_W + 1 + REG_IDX_W + XLEN
//                      + 1 + 2 + $bits(exception_meta_t)
//                    = 1 + 32 + 32 + 1 + 5 + 32 + 1 + 2 + 37 = 143 bits
//
// Dependency order:
//   pipeline_pkg imports fluxcore_pkg and rv32_isa_pkg.
//   No other package may import pipeline_pkg (avoid circular dependencies).
//   Stage-specific payload extensions (e.g. future load-reservation bits)
//   belong in separate packages compiled after this one.

`default_nettype none

package pipeline_pkg;

    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;

    // =========================================================================
    // 1. IF/ID payload — carries fetch result from IF to ID stage
    // =========================================================================
    // The IF stage produces one instruction per cycle (or a bubble on stall
    // or redirect). The ID stage latches this, decodes the instruction, reads
    // the register file, and passes the results downstream.
    //
    // Fields:
    //   valid   — 1 if this slot contains a real instruction; 0 = bubble.
    //   pc      — program counter of this instruction (byte address).
    //   instr   — raw 32-bit instruction word, as fetched from instruction memory.
    //
    // The pc is kept through all stages for:
    //   - Branch/jump target computation in EX (PC + imm)
    //   - AUIPC (PC + upper immediate) in EX
    //   - Retirement trace in WB (identifies which instruction retired)
    //   - Exception tval for instruction-address-misaligned (set in IF, not here)

    typedef struct packed {
        logic    valid;
        word_t   pc;
        instr_t  instr;
    } if_id_payload_t;  // 1 + 32 + 32 = 65 bits

    // =========================================================================
    // 2. ID/EX payload — carries decode result and operands from ID to EX stage
    // =========================================================================
    // The ID stage decodes the raw instruction into decoded_instr_t, reads
    // rs1 and rs2 from the register file, and passes everything to EX.
    //
    // Fields:
    //   valid      — bubble flag (see above).
    //   pc         — forwarded from IF/ID.
    //   instr      — raw instruction word, forwarded for retirement trace and
    //                exception tval.
    //   decoded    — fully decoded instruction: all control signals, immediate,
    //                register indices, exception metadata.
    //   rs1_data   — register file read value for rs1 (may be overridden by
    //                the forwarding unit before the ALU sees it).
    //   rs2_data   — register file read value for rs2.
    //
    // Note on rs1_data for AUIPC and JAL:
    //   decoded.uses_rs1 = 0 for these instructions. The execute stage must
    //   substitute PC for ALU operand A when uses_rs1 = 0. rs1_data is still
    //   passed through (its value is irrelevant for those instructions).

    typedef struct packed {
        logic           valid;
        word_t          pc;
        instr_t         instr;
        decoded_instr_t decoded;
        word_t          rs1_data;
        word_t          rs2_data;
    } id_ex_payload_t;  // 1 + 32 + 32 + 110 + 32 + 32 = 239 bits

    // =========================================================================
    // 3. EX/MEM payload — carries execution result from EX to MEM stage
    // =========================================================================
    // The EX stage runs the ALU, resolves branch conditions, and computes
    // jump/branch targets. It passes the results to MEM.
    //
    // Fields:
    //   valid          — bubble flag.
    //   pc             — forwarded for retirement trace.
    //   instr          — forwarded for retirement trace.
    //   decoded        — forwarded (MEM needs mem_op, wb_src, rd, writes_rd,
    //                    exception; WB needs rd and wb_src to select result).
    //   alu_result     — ALU output:
    //                    • For LOAD/STORE: effective memory address (rs1+imm).
    //                    • For ALU ops:    arithmetic/logic result.
    //                    • For LUI:        the upper immediate (COPY_B result).
    //   rs2_data       — store data for STORE instructions, or the CSR write
    //                    source operand for CSR instructions (execute_stage
    //                    selects: rs1_data for reg forms, {27'b0,zimm} for imm).
    //                    Forwarding may have updated rs1/rs2 in ID/EX; the
    //                    post-forward value is captured here.
    //   branch_taken   — 1 if a conditional branch evaluated as taken.
    //                    Only valid when decoded.is_branch = 1.
    //   branch_target  — resolved branch or jump target address.
    //                    For conditional branches: PC + imm (computed by ALU).
    //                    For JAL:   PC + imm.
    //                    For JALR:  (rs1 + imm) with bit 0 forced to 0 by EX.
    //                    The pipeline control unit uses (branch_taken || is_jump)
    //                    combined with branch_target to redirect the fetch unit.
    //   csr_rdata      — old CSR value captured by the combinatorial read in EX.
    //                    Only valid when decoded.is_csr = 1.  This is the value
    //                    that will be written to rd (WB_CSR writeback source).
    //                    The mem_stage selects it when wb_src = WB_CSR.

    typedef struct packed {
        logic           valid;
        word_t          pc;
        instr_t         instr;
        decoded_instr_t decoded;
        word_t          alu_result;
        word_t          rs2_data;
        logic           branch_taken;
        word_t          branch_target;
        word_t          csr_rdata;
    } ex_mem_payload_t;  // 1 + 32 + 32 + 127 + 32 + 32 + 1 + 32 + 32 = 321 bits

    // =========================================================================
    // 4. MEM/WB payload — carries writeback data from MEM to WB stage
    // =========================================================================
    // The MEM stage performs memory loads and stores, sign/zero-extends load
    // results, and selects the writeback data. By the time this payload reaches
    // WB, rd_data is the final value to write to the register file.
    //
    // Fields:
    //   valid     — bubble flag.
    //   pc        — for retirement trace and PC-relative exception tval.
    //   instr     — for retirement trace.
    //   rd_wen    — 1 = write rd_data to rd_addr in the register file.
    //               This is decoded.writes_rd from the earlier stages, stripped
    //               out here to avoid carrying the full decoded_instr_t further.
    //   rd_addr   — destination register index (from decoded.rd).
    //   rd_data   — final writeback value for combinational-memory simulation,
    //               selected from:
    //               • ALU result (wb_src = WB_ALU)
    //               • Load data, sign/zero-extended (wb_src = WB_MEM)
    //               • PC + 4 (wb_src = WB_PC4, for JAL/JALR)
    //               For BRAM synthesis loads, this value is stale; wb_stage
    //               recomputes load writeback from live dmem_rdata_i when
    //               rd_from_mem=1.
    //   rd_from_mem — 1 when the WB value comes from data memory (WB_MEM).
    //   mem_byte_off — original effective address [1:0], used by wb_stage to
    //               extract/sign-extend byte and halfword loads from the BRAM
    //               word that arrives during the WB cycle.
    //   exception — propagated exception metadata. The WB stage commits this
    //               to the trap handler if valid. A decode-time exception has
    //               already been captured in decoded_instr_t.exception; the
    //               MEM stage may additionally raise EXC_LOAD_ADDR_MISALIGNED,
    //               EXC_STORE_ADDR_MISALIGNED, EXC_LOAD_ACCESS_FAULT, or
    //               EXC_STORE_ACCESS_FAULT.

    typedef struct packed {
        logic            valid;
        word_t           pc;
        instr_t          instr;
        logic            rd_wen;
        reg_idx_t        rd_addr;
        word_t           rd_data;
        logic            rd_from_mem;
        logic [1:0]      mem_byte_off;
        exception_meta_t exception;
    } mem_wb_payload_t;  // 1 + 32 + 32 + 1 + 5 + 32 + 1 + 2 + 37 = 143 bits

endpackage : pipeline_pkg

`default_nettype wire
