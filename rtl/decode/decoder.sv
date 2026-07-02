// rtl/decode/decoder.sv
//
// FluxCore RV32I instruction decoder.
//
// Purpose:
//   Converts a raw 32-bit instruction word into a fully-populated
//   decoded_instr_t for use by the pipeline. This is the ID-stage
//   combinational logic; it produces no state.
//
// Submodules:
//   imm_gen — extracts and sign-extends the immediate field based on
//   the format selected here. The format net (fmt_s) is driven entirely
//   inside this module's always_comb; imm_gen is a combinational pass-through.
//
// Legal vs. exception:
//   legal = 1  All fields are valid. The instruction executes normally.
//   legal = 0  exception.valid = 1; cause = EXC_ILLEGAL_INSTRUCTION;
//              tval = instr_i (the faulting encoding).
//              ECALL and EBREAK are legal (not illegal instructions) but
//              also set exception.valid = 1 with the appropriate cause code.
//              The pipeline suppresses all side effects when legal = 0.
//
// Field semantics:
//   uses_rs1 / uses_rs2  Only set when the register value is architecturally
//                        required. Hazard detection must not stall on an
//                        operand that is not actually read.
//   writes_rd            Set based on instruction semantics, not on rd == x0.
//                        The register file gates writes to x0 internally.
//   alu_op               For AUIPC/JAL the execute stage muxes PC onto
//                        operand A instead of rs1 (uses_rs1 = 0 signals this).
//                        No separate opa_src field exists yet; the execute stage
//                        infers PC-as-A from op_class or the absence of uses_rs1
//                        combined with alu_op = ALU_ADD.
//   imm                  For R-type instructions, imm = 0 (imm_gen default).

`default_nettype none

module decoder
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
(
    input  wire instr_t         instr_i,
    output decoded_instr_t decoded_o
);

    // -----------------------------------------------------------------------
    // Continuous field extractions
    // -----------------------------------------------------------------------
    opcode_t  opcode_s;
    funct3_t  funct3_s;
    funct7_t  funct7_s;
    reg_idx_t rs1_s, rs2_s, rd_s;

    assign opcode_s = opcode_t'(instr_i[INSTR_OPCODE_MSB:INSTR_OPCODE_LSB]);
    assign funct3_s = funct3_t'(instr_i[INSTR_FUNCT3_MSB:INSTR_FUNCT3_LSB]);
    assign funct7_s = funct7_t'(instr_i[INSTR_FUNCT7_MSB:INSTR_FUNCT7_LSB]);
    assign rs1_s    = reg_idx_t'(instr_i[INSTR_RS1_MSB:INSTR_RS1_LSB]);
    assign rs2_s    = reg_idx_t'(instr_i[INSTR_RS2_MSB:INSTR_RS2_LSB]);
    assign rd_s     = reg_idx_t'(instr_i[INSTR_RD_MSB:INSTR_RD_LSB]);

    // -----------------------------------------------------------------------
    // Immediate generator
    // -----------------------------------------------------------------------
    instr_fmt_e fmt_s;
    word_t      imm_s;

    imm_gen u_imm_gen (
        .instr_i(instr_i),
        .fmt_i  (fmt_s),
        .imm_o  (imm_s)
    );

    // -----------------------------------------------------------------------
    // Helper: produce a fully-zeroed decoded_instr_t for illegal instructions
    // -----------------------------------------------------------------------
    // Guarantees that all action fields (uses_rs1, writes_rd, is_load, …) are
    // 0 so the pipeline can unconditionally suppress side effects when
    // legal = 0 without checking every flag individually.
    function automatic decoded_instr_t make_illegal(input instr_t instr);
        automatic decoded_instr_t d;
        d                = '0;
        d.legal          = 1'b0;
        d.exception.valid = 1'b1;
        d.exception.cause = EXC_ILLEGAL_INSTRUCTION;
        d.exception.tval  = word_t'(instr);
        return d;
    endfunction

    // -----------------------------------------------------------------------
    // Decode logic
    // -----------------------------------------------------------------------
    always_comb begin

        // --- Structural defaults ---
        // Zeroing everything first means only the legal fields need to be
        // explicitly set per instruction.
        decoded_o = '0;
        fmt_s     = IFMT_R;

        // Register indices are always extracted from fixed encoding positions.
        // Even illegal instructions record them for diagnostics.
        decoded_o.rs1 = rs1_s;
        decoded_o.rs2 = rs2_s;
        decoded_o.rd  = rd_s;

        case (opcode_s)

            // ============================================================
            // LUI — load upper immediate
            // rd = imm (U-type); no register read.
            // ============================================================
            OPCODE_LUI: begin
                fmt_s               = IFMT_U;
                decoded_o.legal     = 1'b1;
                decoded_o.op_class  = OPCLASS_ALU;
                decoded_o.alu_op    = ALU_COPY_B;   // result = imm (operand B)
                decoded_o.wb_src    = WB_ALU;
                decoded_o.writes_rd = 1'b1;
            end

            // ============================================================
            // AUIPC — add upper immediate to PC
            // rd = PC + imm; operand A is PC (execute stage muxes, uses_rs1=0).
            // ============================================================
            OPCODE_AUIPC: begin
                fmt_s               = IFMT_U;
                decoded_o.legal     = 1'b1;
                decoded_o.op_class  = OPCLASS_ALU;
                decoded_o.alu_op    = ALU_ADD;
                decoded_o.wb_src    = WB_ALU;
                decoded_o.writes_rd = 1'b1;
            end

            // ============================================================
            // JAL — jump and link
            // PC target = PC + imm; rd = PC+4; operand A is PC (uses_rs1=0).
            // ============================================================
            OPCODE_JAL: begin
                fmt_s               = IFMT_J;
                decoded_o.legal     = 1'b1;
                decoded_o.op_class  = OPCLASS_JUMP;
                decoded_o.alu_op    = ALU_ADD;
                decoded_o.wb_src    = WB_PC4;
                decoded_o.writes_rd = 1'b1;
                decoded_o.is_jump   = 1'b1;
            end

            // ============================================================
            // JALR — jump and link register
            // PC target = (rs1 + imm) with bit 0 cleared; rd = PC+4.
            // funct3 must be 000; all other funct3 values are reserved.
            // ============================================================
            OPCODE_JALR: begin
                fmt_s = IFMT_I;
                if (funct3_s == FUNCT3_JALR) begin
                    decoded_o.legal     = 1'b1;
                    decoded_o.op_class  = OPCLASS_JUMP;
                    decoded_o.alu_op    = ALU_ADD;
                    decoded_o.wb_src    = WB_PC4;
                    decoded_o.uses_rs1  = 1'b1;
                    decoded_o.writes_rd = 1'b1;
                    decoded_o.is_jump   = 1'b1;
                end else begin
                    decoded_o = make_illegal(instr_i);
                end
            end

            // ============================================================
            // BRANCH — conditional branch
            // PC target = PC + imm; rs1 and rs2 are compared.
            // funct3 encodes the comparison type.
            // ============================================================
            OPCODE_BRANCH: begin
                fmt_s               = IFMT_B;
                decoded_o.legal     = 1'b1;
                decoded_o.op_class  = OPCLASS_BRANCH;
                decoded_o.uses_rs1  = 1'b1;
                decoded_o.uses_rs2  = 1'b1;
                decoded_o.is_branch = 1'b1;
                case (funct3_s)
                    FUNCT3_BEQ:  decoded_o.branch_op = BRANCH_EQ;
                    FUNCT3_BNE:  decoded_o.branch_op = BRANCH_NE;
                    FUNCT3_BLT:  decoded_o.branch_op = BRANCH_LT;
                    FUNCT3_BGE:  decoded_o.branch_op = BRANCH_GE;
                    FUNCT3_BLTU: decoded_o.branch_op = BRANCH_LTU;
                    FUNCT3_BGEU: decoded_o.branch_op = BRANCH_GEU;
                    default: decoded_o = make_illegal(instr_i);
                endcase
            end

            // ============================================================
            // LOAD — memory load
            // Effective address = rs1 + imm; result sign/zero-extended per funct3.
            // ============================================================
            OPCODE_LOAD: begin
                fmt_s               = IFMT_I;
                decoded_o.legal     = 1'b1;
                decoded_o.op_class  = OPCLASS_LOAD;
                decoded_o.alu_op    = ALU_ADD;
                decoded_o.wb_src    = WB_MEM;
                decoded_o.uses_rs1  = 1'b1;
                decoded_o.writes_rd = 1'b1;
                decoded_o.is_load   = 1'b1;
                case (funct3_s)
                    FUNCT3_LB:  decoded_o.mem_op = MEM_LB;
                    FUNCT3_LH:  decoded_o.mem_op = MEM_LH;
                    FUNCT3_LW:  decoded_o.mem_op = MEM_LW;
                    FUNCT3_LBU: decoded_o.mem_op = MEM_LBU;
                    FUNCT3_LHU: decoded_o.mem_op = MEM_LHU;
                    default:    decoded_o = make_illegal(instr_i);
                endcase
            end

            // ============================================================
            // STORE — memory store
            // Effective address = rs1 + imm; data source is rs2.
            // ============================================================
            OPCODE_STORE: begin
                fmt_s              = IFMT_S;
                decoded_o.legal    = 1'b1;
                decoded_o.op_class = OPCLASS_STORE;
                decoded_o.alu_op   = ALU_ADD;
                decoded_o.uses_rs1 = 1'b1;
                decoded_o.uses_rs2 = 1'b1;
                decoded_o.is_store = 1'b1;
                case (funct3_s)
                    FUNCT3_SB: decoded_o.mem_op = MEM_SB;
                    FUNCT3_SH: decoded_o.mem_op = MEM_SH;
                    FUNCT3_SW: decoded_o.mem_op = MEM_SW;
                    default:   decoded_o = make_illegal(instr_i);
                endcase
            end

            // ============================================================
            // OP-IMM — integer immediate arithmetic and logic
            // Result = op(rs1, imm); no rs2 read.
            // ============================================================
            OPCODE_OP_IMM: begin
                fmt_s               = IFMT_I;
                decoded_o.legal     = 1'b1;
                decoded_o.op_class  = OPCLASS_ALU;
                decoded_o.wb_src    = WB_ALU;
                decoded_o.uses_rs1  = 1'b1;
                decoded_o.writes_rd = 1'b1;
                case (funct3_s)
                    FUNCT3_ADD_SUB: decoded_o.alu_op = ALU_ADD;  // ADDI
                    FUNCT3_SLT:     decoded_o.alu_op = ALU_SLT;  // SLTI
                    FUNCT3_SLTU:    decoded_o.alu_op = ALU_SLTU; // SLTIU
                    FUNCT3_XOR:     decoded_o.alu_op = ALU_XOR;  // XORI
                    FUNCT3_OR:      decoded_o.alu_op = ALU_OR;   // ORI
                    FUNCT3_AND:     decoded_o.alu_op = ALU_AND;  // ANDI
                    // Shifts: imm[11:5] = funct7; only specific funct7 values legal.
                    FUNCT3_SLL: begin  // SLLI
                        if (funct7_s == FUNCT7_NORMAL)
                            decoded_o.alu_op = ALU_SLL;
                        else
                            decoded_o = make_illegal(instr_i);
                    end
                    FUNCT3_SRL_SRA: begin  // SRLI or SRAI
                        case (funct7_s)
                            FUNCT7_NORMAL: decoded_o.alu_op = ALU_SRL; // SRLI
                            FUNCT7_ALT:    decoded_o.alu_op = ALU_SRA; // SRAI
                            default:       decoded_o = make_illegal(instr_i);
                        endcase
                    end
                    default: ; // All 8 funct3 values are handled above
                endcase
            end

            // ============================================================
            // OP — register-register arithmetic/logic (RV32I) and
            //      multiply/divide (RV32M, funct7 = FUNCT7_MEXT).
            // funct7 = FUNCT7_MEXT selects the M-extension; all other funct7
            // values use base-ISA dispatch on funct3.
            // ============================================================
            OPCODE_OP: begin
                fmt_s               = IFMT_R;
                decoded_o.legal     = 1'b1;
                decoded_o.wb_src    = WB_ALU;
                decoded_o.uses_rs1  = 1'b1;
                decoded_o.uses_rs2  = 1'b1;
                decoded_o.writes_rd = 1'b1;

                if (funct7_s == FUNCT7_MEXT) begin
                    // ---- RV32M: multiply / divide ----
                    decoded_o.op_class = OPCLASS_LONG_LAT;
                    case (funct3_s)
                        FUNCT3_M_MUL:    decoded_o.alu_op = ALU_MUL;
                        FUNCT3_M_MULH:   decoded_o.alu_op = ALU_MULH;
                        FUNCT3_M_MULHSU: decoded_o.alu_op = ALU_MULHSU;
                        FUNCT3_M_MULHU:  decoded_o.alu_op = ALU_MULHU;
                        FUNCT3_M_DIV:  begin
                            decoded_o.alu_op          = ALU_DIV;
                            decoded_o.is_long_latency = 1'b1;
                        end
                        FUNCT3_M_DIVU: begin
                            decoded_o.alu_op          = ALU_DIVU;
                            decoded_o.is_long_latency = 1'b1;
                        end
                        FUNCT3_M_REM:  begin
                            decoded_o.alu_op          = ALU_REM;
                            decoded_o.is_long_latency = 1'b1;
                        end
                        FUNCT3_M_REMU: begin
                            decoded_o.alu_op          = ALU_REMU;
                            decoded_o.is_long_latency = 1'b1;
                        end
                        default: decoded_o = make_illegal(instr_i);
                    endcase

                end else begin
                    // ---- RV32I base integer ops ----
                    decoded_o.op_class = OPCLASS_ALU;
                    case (funct3_s)
                        FUNCT3_ADD_SUB: begin
                            case (funct7_s)
                                FUNCT7_NORMAL: decoded_o.alu_op = ALU_ADD; // ADD
                                FUNCT7_ALT:    decoded_o.alu_op = ALU_SUB; // SUB
                                default:       decoded_o = make_illegal(instr_i);
                            endcase
                        end
                        FUNCT3_SLL: begin
                            if (funct7_s == FUNCT7_NORMAL)
                                decoded_o.alu_op = ALU_SLL;
                            else
                                decoded_o = make_illegal(instr_i);
                        end
                        FUNCT3_SLT: begin
                            if (funct7_s == FUNCT7_NORMAL)
                                decoded_o.alu_op = ALU_SLT;
                            else
                                decoded_o = make_illegal(instr_i);
                        end
                        FUNCT3_SLTU: begin
                            if (funct7_s == FUNCT7_NORMAL)
                                decoded_o.alu_op = ALU_SLTU;
                            else
                                decoded_o = make_illegal(instr_i);
                        end
                        FUNCT3_XOR: begin
                            if (funct7_s == FUNCT7_NORMAL)
                                decoded_o.alu_op = ALU_XOR;
                            else
                                decoded_o = make_illegal(instr_i);
                        end
                        FUNCT3_SRL_SRA: begin
                            case (funct7_s)
                                FUNCT7_NORMAL: decoded_o.alu_op = ALU_SRL; // SRL
                                FUNCT7_ALT:    decoded_o.alu_op = ALU_SRA; // SRA
                                default:       decoded_o = make_illegal(instr_i);
                            endcase
                        end
                        FUNCT3_OR: begin
                            if (funct7_s == FUNCT7_NORMAL)
                                decoded_o.alu_op = ALU_OR;
                            else
                                decoded_o = make_illegal(instr_i);
                        end
                        FUNCT3_AND: begin
                            if (funct7_s == FUNCT7_NORMAL)
                                decoded_o.alu_op = ALU_AND;
                            else
                                decoded_o = make_illegal(instr_i);
                        end
                        default: ; // All 8 funct3 covered above
                    endcase
                end
            end

            // ============================================================
            // SYSTEM — privileged and CSR instructions
            //
            // funct3 = 000 (PRIV group): ECALL, EBREAK, MRET
            //   rs1 and rd must be zero (architectural requirement).
            //   MRET: instr[31:20] = 0x302.  Legal, no exception generated
            //   here; pipeline_ctrl handles the PC redirect to mepc.
            //
            // funct3 = 001/010/011 (CSRRW/CSRRS/CSRRC): register forms
            //   rs1 = source register, instr[31:20] = CSR address.
            //   writes_rd set when rd != x0 (though writes_rd=1 with rd=x0
            //   is also safe since the regfile and forwarding_unit both gate
            //   on rd!=0 internally; set explicitly for clarity).
            //
            // funct3 = 101/110/111 (CSRRWI/CSRRSI/CSRRCI): immediate forms
            //   zimm = zero-extended instr[19:15], uses_rs1 = 0.
            //   decoded_o.imm is overridden at the bottom of always_comb.
            //
            // funct3 = 100: reserved, illegal.
            // ============================================================
            OPCODE_SYSTEM: begin
                fmt_s = IFMT_I;
                case (funct3_s)

                    // ---- PRIV group: ECALL / EBREAK / MRET ----
                    3'b000: begin
                        if (rs1_s == '0 && rd_s == '0) begin
                            case (instr_i[31:20])
                                FUNCT12_ECALL: begin
                                    decoded_o.legal           = 1'b1;
                                    decoded_o.op_class        = OPCLASS_SYSTEM;
                                    decoded_o.exception.valid = 1'b1;
                                    decoded_o.exception.cause = EXC_ECALL_M;
                                end
                                FUNCT12_EBREAK: begin
                                    decoded_o.legal           = 1'b1;
                                    decoded_o.op_class        = OPCLASS_SYSTEM;
                                    decoded_o.exception.valid = 1'b1;
                                    decoded_o.exception.cause = EXC_BREAKPOINT;
                                end
                                FUNCT12_MRET: begin
                                    decoded_o.legal     = 1'b1;
                                    decoded_o.op_class  = OPCLASS_SYSTEM;
                                    decoded_o.is_mret   = 1'b1;
                                end
                                // WFI executes as a NOP (RISC-V priv spec
                                // permits this): no clock gating exists, and
                                // interrupts are level-sensitive so a pending
                                // interrupt is taken on the next instruction.
                                FUNCT12_WFI: begin
                                    decoded_o.legal    = 1'b1;
                                    decoded_o.op_class = OPCLASS_SYSTEM;
                                end
                                default: decoded_o = make_illegal(instr_i);
                            endcase
                        end else begin
                            decoded_o = make_illegal(instr_i);
                        end
                    end

                    // ---- CSR register forms (rs1 = source register) ----
                    // Illegal-instruction trap on: unimplemented CSR, or a
                    // write (CSRRW always; CSRRS/C with rs1!=x0) to a
                    // read-only CSR (priv spec 2.1).
                    3'b001,   // CSRRW
                    3'b010,   // CSRRS
                    3'b011: begin // CSRRC
                        if (!csr_addr_valid(instr_i[31:20])
                            || (csr_addr_readonly(instr_i[31:20])
                                && (funct3_s[1:0] == 2'b01 || rs1_s != '0))) begin
                            decoded_o = make_illegal(instr_i);
                        end else begin
                            decoded_o.legal     = 1'b1;
                            decoded_o.op_class  = OPCLASS_SYSTEM;
                            decoded_o.is_csr    = 1'b1;
                            decoded_o.csr_addr  = instr_i[31:20];
                            decoded_o.csr_op    = csr_op_e'({1'b0, funct3_s[1:0]});
                            decoded_o.uses_rs1  = 1'b1;
                            decoded_o.writes_rd = (rd_s != '0);
                            decoded_o.wb_src    = WB_CSR;
                        end
                    end

                    // ---- CSR immediate forms (zimm = instr[19:15]) ----
                    3'b101,   // CSRRWI
                    3'b110,   // CSRRSI
                    3'b111: begin // CSRRCI
                        if (!csr_addr_valid(instr_i[31:20])
                            || (csr_addr_readonly(instr_i[31:20])
                                && (funct3_s[1:0] == 2'b01 || instr_i[19:15] != '0))) begin
                            decoded_o = make_illegal(instr_i);
                        end else begin
                            decoded_o.legal     = 1'b1;
                            decoded_o.op_class  = OPCLASS_SYSTEM;
                            decoded_o.is_csr    = 1'b1;
                            decoded_o.csr_addr  = instr_i[31:20];
                            decoded_o.csr_op    = csr_op_e'({1'b0, funct3_s[1:0]});
                            decoded_o.uses_rs1  = 1'b0;  // zimm, not a register
                            decoded_o.writes_rd = (rd_s != '0);
                            decoded_o.wb_src    = WB_CSR;
                            // decoded_o.imm overridden below to {27'b0, instr[19:15]}
                        end
                    end

                    default: decoded_o = make_illegal(instr_i);  // funct3=100

                endcase
            end

            // ============================================================
            // MISC-MEM — FENCE / FENCE.I
            // Treated as NOP in the initial single-issue in-order implementation.
            // No caches or write buffers exist to drain. Future milestones that
            // add instruction cache or store buffers must revisit this.
            // ============================================================
            OPCODE_MISC_MEM: begin
                fmt_s = IFMT_I;
                case (funct3_s)
                    3'b000,     // FENCE
                    3'b001: begin  // FENCE.I
                        decoded_o.legal    = 1'b1;
                        decoded_o.op_class = OPCLASS_SYSTEM;
                    end
                    default: decoded_o = make_illegal(instr_i);
                endcase
            end

            // ============================================================
            // CUSTOM_0 — XFlux sparse/scientific custom instructions.
            //
            // All XFlux encodings are R-type with funct7 = FUNCT7_NORMAL.
            // funct3 selects the operation:
            //   000 XLIDX rd,rs1,rs2  rd = MEM[rs1 + rs2<<2]  (indexed word load)
            //   001 XABS  rd,rs1      rd = |rs1|               (absolute value)
            //   010 XMIN  rd,rs1,rs2  rd = signed_min(rs1,rs2)
            //   011 XMAX  rd,rs1,rs2  rd = signed_max(rs1,rs2)
            //   100 XCLZ  rd,rs1      rd = clz(rs1)            (count leading zeros)
            //   101 reserved: XMACC (rd=rd+rs1*rs2, pending 3-operand support)
            // ============================================================
            OPCODE_CUSTOM_0: begin
                fmt_s               = IFMT_R;
                decoded_o.legal     = 1'b1;
                decoded_o.op_class  = OPCLASS_CUSTOM;
                decoded_o.wb_src    = WB_ALU;
                decoded_o.writes_rd = 1'b1;

                if (funct7_s != FUNCT7_NORMAL) begin
                    decoded_o = make_illegal(instr_i);
                end else begin
                    case (funct3_s)
                        FUNCT3_XLIDX: begin
                            decoded_o.alu_op  = ALU_XLIDX_ADDR;
                            decoded_o.wb_src  = WB_MEM;
                            decoded_o.mem_op  = MEM_LW;
                            decoded_o.uses_rs1 = 1'b1;
                            decoded_o.uses_rs2 = 1'b1;
                            decoded_o.is_load  = 1'b1;
                        end
                        FUNCT3_XABS: begin
                            decoded_o.alu_op  = ALU_XABS;
                            decoded_o.uses_rs1 = 1'b1;
                        end
                        FUNCT3_XMIN: begin
                            decoded_o.alu_op  = ALU_XMIN;
                            decoded_o.uses_rs1 = 1'b1;
                            decoded_o.uses_rs2 = 1'b1;
                        end
                        FUNCT3_XMAX: begin
                            decoded_o.alu_op  = ALU_XMAX;
                            decoded_o.uses_rs1 = 1'b1;
                            decoded_o.uses_rs2 = 1'b1;
                        end
                        FUNCT3_XCLZ: begin
                            decoded_o.alu_op  = ALU_XCLZ;
                            decoded_o.uses_rs1 = 1'b1;
                        end
                        default: decoded_o = make_illegal(instr_i);
                    endcase
                end
            end

            // ============================================================
            // Unknown opcode
            // ============================================================
            default: decoded_o = make_illegal(instr_i);

        endcase

        // Connect the generated immediate.
        // fmt_s was set above; imm_gen has already computed imm_s.
        // This assignment overrides the zero set by decoded_o = '0.
        // For illegal instructions (decoded_o = make_illegal), this sets
        // decoded_o.imm to whatever imm_gen produces for the given fmt_s
        // and raw instr_i — harmless, since the pipeline ignores the imm
        // of illegal instructions.
        decoded_o.imm = imm_s;

        // CSR immediate forms (CSRRWI/CSRRSI/CSRRCI, funct3[2]=1):
        // The write operand is a zero-extended 5-bit unsigned immediate encoded
        // in instr[19:15] (the rs1 field).  Override imm_s, which would be the
        // sign-extended I-type immediate of the CSR address — wrong for data.
        if (opcode_s == OPCODE_SYSTEM && funct3_s[2] && decoded_o.legal)
            decoded_o.imm = {27'b0, instr_i[19:15]};

        // Per the RISC-V privileged spec:
        //   CSRRS / CSRRC  with rs1 = x0  must NOT write the CSR (read-only access).
        //   CSRRSI / CSRRCI with zimm = 0  must NOT write the CSR (read-only access).
        // Set csr_op to CSR_NOP so the write port is suppressed; the CSR read
        // result still reaches rd via WB_CSR.  CSRRW(I) always writes regardless.
        if (opcode_s == OPCODE_SYSTEM && decoded_o.legal && decoded_o.is_csr) begin
            // Register forms (funct3[2]=0): 001=CSRRW, 010=CSRRS, 011=CSRRC
            if (!funct3_s[2] && funct3_s != 3'b001 && rs1_s == '0)
                decoded_o.csr_op = CSR_NOP;
            // Immediate forms (funct3[2]=1): 101=CSRRWI, 110=CSRRSI, 111=CSRRCI
            if (funct3_s[2] && funct3_s != 3'b101 && instr_i[19:15] == '0)
                decoded_o.csr_op = CSR_NOP;
        end

    end // always_comb

endmodule : decoder

`default_nettype wire
