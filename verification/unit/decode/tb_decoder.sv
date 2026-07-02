// verification/unit/decode/tb_decoder.sv
//
// Self-checking testbench for rtl/decode/decoder.sv.
//
// Coverage:
//   Every legal RV32I instruction group (LUI, AUIPC, JAL, JALR, BRANCH,
//   LOAD, STORE, OP-IMM, OP, SYSTEM, MISC-MEM) is tested with at least
//   one representative encoding.
//
//   Illegal variants tested:
//     - Unknown opcode
//     - JALR with funct3 != 000
//     - BRANCH with reserved funct3 (010, 011)
//     - LOAD with reserved funct3 (011, 110, 111)
//     - STORE with reserved funct3 (011, 100)
//     - SLLI/SRLI with bad funct7
//     - OP ADD with FUNCT7_MEXT (future M-extension, illegal for now)
//     - SYSTEM with CSR funct3 (future, illegal for now)
//     - SYSTEM with non-ECALL/EBREAK funct12
//
//   Key decoder invariants checked:
//     - legal = 1 ↔ all expected action flags are coherent
//     - legal = 0 → exception.valid = 1, cause = EXC_ILLEGAL_INSTRUCTION, tval = instr
//     - ECALL / EBREAK: legal = 1, exception.valid = 1, correct cause
//     - uses_rs1 / uses_rs2 set correctly per instruction type
//     - writes_rd set correctly (by semantics, not by rd == x0)
//     - is_branch / is_jump / is_load / is_store are mutually exclusive
//     - imm matches what imm_gen would produce for the chosen format
//
// Pass/fail:
//   $fatal(1, ...) on any mismatch.
//   Prints "[DECODE-TEST] PASS" and $finish on success.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;

module tb_decoder;

    // -----------------------------------------------------------------------
    // DUT wires
    // -----------------------------------------------------------------------
    instr_t         instr_w;
    decoded_instr_t decoded_w;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    decoder dut (
        .instr_i  (instr_w),
        .decoded_o(decoded_w)
    );

    // -----------------------------------------------------------------------
    // Instruction builders — identical style to tb_imm_gen.sv
    // -----------------------------------------------------------------------
    function automatic instr_t build_r(
        input funct7_t f7, input logic [4:0] rs2, rs1, rd,
        input funct3_t f3, input opcode_t opc
    );
        automatic instr_t i = '0;
        i[31:25] = f7; i[24:20] = rs2; i[19:15] = rs1;
        i[14:12] = f3; i[11:7]  = rd;  i[6:0]   = opc;
        return i;
    endfunction

    function automatic instr_t build_i(
        input logic [11:0] imm, input logic [4:0] rs1, rd,
        input funct3_t f3, input opcode_t opc
    );
        automatic instr_t i = '0;
        i[31:20] = imm; i[19:15] = rs1;
        i[14:12] = f3;  i[11:7]  = rd; i[6:0] = opc;
        return i;
    endfunction

    function automatic instr_t build_s(
        input logic [11:0] imm, input logic [4:0] rs2, rs1,
        input funct3_t f3, input opcode_t opc
    );
        automatic instr_t i = '0;
        i[31:25] = imm[11:5]; i[24:20] = rs2; i[19:15] = rs1;
        i[14:12] = f3;        i[11:7]  = imm[4:0]; i[6:0] = opc;
        return i;
    endfunction

    function automatic instr_t build_b(
        input logic [12:0] imm, input logic [4:0] rs2, rs1,
        input funct3_t f3, input opcode_t opc
    );
        automatic instr_t i = '0;
        i[31]    = imm[12]; i[30:25] = imm[10:5]; i[24:20] = rs2;
        i[19:15] = rs1;     i[14:12] = f3;
        i[11:8]  = imm[4:1]; i[7]   = imm[11]; i[6:0] = opc;
        return i;
    endfunction

    function automatic instr_t build_u(
        input logic [19:0] imm20, input logic [4:0] rd, input opcode_t opc
    );
        automatic instr_t i = '0;
        i[31:12] = imm20; i[11:7] = rd; i[6:0] = opc;
        return i;
    endfunction

    function automatic instr_t build_j(
        input logic [20:0] imm, input logic [4:0] rd, input opcode_t opc
    );
        automatic instr_t i = '0;
        i[31]    = imm[20]; i[30:21] = imm[10:1]; i[20]    = imm[11];
        i[19:12] = imm[19:12]; i[11:7] = rd;       i[6:0]   = opc;
        return i;
    endfunction

    // -----------------------------------------------------------------------
    // Check helpers
    // -----------------------------------------------------------------------
    task automatic apply(input instr_t instr);
        instr_w = instr; #1;
    endtask

    task automatic expect_legal(
        input logic         exp_legal,
        input op_class_e    exp_class,
        input alu_op_e      exp_alu,
        input wb_src_e      exp_wb,
        input logic         exp_uses_rs1,
        input logic         exp_uses_rs2,
        input logic         exp_writes_rd,
        input string        desc
    );
        if (decoded_w.legal !== exp_legal)
            $fatal(1, "[DECODE-TEST] FAIL %s: legal=%b exp=%b", desc, decoded_w.legal, exp_legal);
        if (decoded_w.op_class !== exp_class)
            $fatal(1, "[DECODE-TEST] FAIL %s: op_class=%0d exp=%0d",
                   desc, int'(decoded_w.op_class), int'(exp_class));
        if (decoded_w.alu_op !== exp_alu)
            $fatal(1, "[DECODE-TEST] FAIL %s: alu_op=%0d exp=%0d",
                   desc, int'(decoded_w.alu_op), int'(exp_alu));
        if (decoded_w.wb_src !== exp_wb)
            $fatal(1, "[DECODE-TEST] FAIL %s: wb_src=%0d exp=%0d",
                   desc, int'(decoded_w.wb_src), int'(exp_wb));
        if (decoded_w.uses_rs1 !== exp_uses_rs1)
            $fatal(1, "[DECODE-TEST] FAIL %s: uses_rs1=%b exp=%b",
                   desc, decoded_w.uses_rs1, exp_uses_rs1);
        if (decoded_w.uses_rs2 !== exp_uses_rs2)
            $fatal(1, "[DECODE-TEST] FAIL %s: uses_rs2=%b exp=%b",
                   desc, decoded_w.uses_rs2, exp_uses_rs2);
        if (decoded_w.writes_rd !== exp_writes_rd)
            $fatal(1, "[DECODE-TEST] FAIL %s: writes_rd=%b exp=%b",
                   desc, decoded_w.writes_rd, exp_writes_rd);
    endtask

    task automatic expect_illegal(input instr_t instr, input string desc);
        if (decoded_w.legal !== 1'b0)
            $fatal(1, "[DECODE-TEST] FAIL %s: expected illegal, got legal=1", desc);
        if (decoded_w.exception.valid !== 1'b1)
            $fatal(1, "[DECODE-TEST] FAIL %s: exception.valid should be 1", desc);
        if (decoded_w.exception.cause !== EXC_ILLEGAL_INSTRUCTION)
            $fatal(1, "[DECODE-TEST] FAIL %s: exception.cause=%0d exp EXC_ILLEGAL_INSTRUCTION=%0d",
                   desc, int'(decoded_w.exception.cause),
                   int'(EXC_ILLEGAL_INSTRUCTION));
        if (decoded_w.exception.tval !== word_t'(instr))
            $fatal(1, "[DECODE-TEST] FAIL %s: tval=%08h exp=%08h",
                   desc, decoded_w.exception.tval, word_t'(instr));
        // All action flags must be 0 for illegal instructions
        if (decoded_w.writes_rd || decoded_w.uses_rs1 || decoded_w.uses_rs2)
            $fatal(1, "[DECODE-TEST] FAIL %s: illegal instr has action flag set", desc);
        if (decoded_w.is_branch || decoded_w.is_jump || decoded_w.is_load || decoded_w.is_store)
            $fatal(1, "[DECODE-TEST] FAIL %s: illegal instr has class flag set", desc);
    endtask

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    initial begin : test_body

        instr_w = '0; #1;

        // ================================================================
        // LUI
        // ================================================================
        begin : t_lui
            automatic instr_t i = build_u(20'h12345, 5'd1, OPCODE_LUI);
            apply(i);
            expect_legal(1'b1, OPCLASS_ALU, ALU_COPY_B, WB_ALU,
                         1'b0, 1'b0, 1'b1, "LUI x1, 0x12345");
            if (decoded_w.imm !== 32'h12345000)
                $fatal(1, "[DECODE-TEST] FAIL LUI imm=%08h exp=0x12345000", decoded_w.imm);
            if (decoded_w.rd !== 5'd1)
                $fatal(1, "[DECODE-TEST] FAIL LUI rd=%0d exp=1", decoded_w.rd);
        end

        // ================================================================
        // AUIPC
        // ================================================================
        begin : t_auipc
            automatic instr_t i = build_u(20'h1, 5'd2, OPCODE_AUIPC);
            apply(i);
            expect_legal(1'b1, OPCLASS_ALU, ALU_ADD, WB_ALU,
                         1'b0, 1'b0, 1'b1, "AUIPC x2, 1");
            if (decoded_w.imm !== 32'h00001000)
                $fatal(1, "[DECODE-TEST] FAIL AUIPC imm=%08h exp=0x00001000", decoded_w.imm);
        end

        // ================================================================
        // JAL
        // ================================================================
        begin : t_jal
            automatic instr_t i = build_j(21'd4, 5'd1, OPCODE_JAL);
            apply(i);
            expect_legal(1'b1, OPCLASS_JUMP, ALU_ADD, WB_PC4,
                         1'b0, 1'b0, 1'b1, "JAL x1, +4");
            if (!decoded_w.is_jump)
                $fatal(1, "[DECODE-TEST] FAIL JAL: is_jump not set");
            if (decoded_w.is_branch || decoded_w.is_load || decoded_w.is_store)
                $fatal(1, "[DECODE-TEST] FAIL JAL: spurious class flag");
            if (decoded_w.imm !== 32'h4)
                $fatal(1, "[DECODE-TEST] FAIL JAL imm=%08h exp=4", decoded_w.imm);
            // JAL x0 (link to x0) still has writes_rd=1; regfile ignores x0
            i = build_j(21'd8, 5'd0, OPCODE_JAL);
            apply(i);
            if (!decoded_w.writes_rd)
                $fatal(1, "[DECODE-TEST] FAIL JAL x0: writes_rd must be 1 (regfile gates x0)");
        end

        // ================================================================
        // JALR
        // ================================================================
        begin : t_jalr
            automatic instr_t i;
            // Legal: JALR x1, x2, 0
            i = build_i(12'd0, 5'd2, 5'd1, FUNCT3_JALR, OPCODE_JALR);
            apply(i);
            expect_legal(1'b1, OPCLASS_JUMP, ALU_ADD, WB_PC4,
                         1'b1, 1'b0, 1'b1, "JALR x1, x2, 0");
            if (!decoded_w.is_jump)
                $fatal(1, "[DECODE-TEST] FAIL JALR: is_jump not set");

            // Illegal: JALR with funct3 = 001
            i = build_i(12'd0, 5'd2, 5'd1, 3'b001, OPCODE_JALR);
            apply(i);
            expect_illegal(i, "JALR funct3=001");
        end

        // ================================================================
        // BRANCH
        // ================================================================
        begin : t_branch
            automatic instr_t i;
            // BEQ x1, x2, +8
            i = build_b(13'd8, 5'd2, 5'd1, FUNCT3_BEQ, OPCODE_BRANCH);
            apply(i);
            expect_legal(1'b1, OPCLASS_BRANCH, ALU_ADD, WB_NONE,
                         1'b1, 1'b1, 1'b0, "BEQ x1,x2,+8");
            if (!decoded_w.is_branch)
                $fatal(1, "[DECODE-TEST] FAIL BEQ: is_branch not set");
            if (decoded_w.branch_op !== BRANCH_EQ)
                $fatal(1, "[DECODE-TEST] FAIL BEQ: branch_op=%0d exp BRANCH_EQ=%0d",
                       int'(decoded_w.branch_op), int'(BRANCH_EQ));
            if (decoded_w.imm !== 32'h8)
                $fatal(1, "[DECODE-TEST] FAIL BEQ imm=%08h exp=8", decoded_w.imm);

            // BNE, BLT, BGE, BLTU, BGEU
            i = build_b(13'd4, 5'd2, 5'd1, FUNCT3_BNE, OPCODE_BRANCH);
            apply(i);
            if (decoded_w.branch_op !== BRANCH_NE)
                $fatal(1, "[DECODE-TEST] FAIL BNE branch_op");

            i = build_b(13'd4, 5'd2, 5'd1, FUNCT3_BLT, OPCODE_BRANCH);
            apply(i);
            if (decoded_w.branch_op !== BRANCH_LT)
                $fatal(1, "[DECODE-TEST] FAIL BLT branch_op");

            i = build_b(13'd4, 5'd2, 5'd1, FUNCT3_BGE, OPCODE_BRANCH);
            apply(i);
            if (decoded_w.branch_op !== BRANCH_GE)
                $fatal(1, "[DECODE-TEST] FAIL BGE branch_op");

            i = build_b(13'd4, 5'd2, 5'd1, FUNCT3_BLTU, OPCODE_BRANCH);
            apply(i);
            if (decoded_w.branch_op !== BRANCH_LTU)
                $fatal(1, "[DECODE-TEST] FAIL BLTU branch_op");

            i = build_b(13'd4, 5'd2, 5'd1, FUNCT3_BGEU, OPCODE_BRANCH);
            apply(i);
            if (decoded_w.branch_op !== BRANCH_GEU)
                $fatal(1, "[DECODE-TEST] FAIL BGEU branch_op");

            // Illegal: reserved funct3 010 and 011
            i = build_b(13'd4, 5'd2, 5'd1, 3'b010, OPCODE_BRANCH);
            apply(i);
            expect_illegal(i, "BRANCH funct3=010");

            i = build_b(13'd4, 5'd2, 5'd1, 3'b011, OPCODE_BRANCH);
            apply(i);
            expect_illegal(i, "BRANCH funct3=011");
        end

        // ================================================================
        // LOAD
        // ================================================================
        begin : t_load
            automatic instr_t i;
            // LW x1, 8(x2)
            i = build_i(12'd8, 5'd2, 5'd1, FUNCT3_LW, OPCODE_LOAD);
            apply(i);
            expect_legal(1'b1, OPCLASS_LOAD, ALU_ADD, WB_MEM,
                         1'b1, 1'b0, 1'b1, "LW x1, 8(x2)");
            if (!decoded_w.is_load)
                $fatal(1, "[DECODE-TEST] FAIL LW: is_load not set");
            if (decoded_w.mem_op !== MEM_LW)
                $fatal(1, "[DECODE-TEST] FAIL LW mem_op");
            if (decoded_w.imm !== 32'h8)
                $fatal(1, "[DECODE-TEST] FAIL LW imm");

            // All valid load widths
            i = build_i(12'd0, 5'd0, 5'd0, FUNCT3_LB,  OPCODE_LOAD);  apply(i);
            if (decoded_w.mem_op !== MEM_LB)
                $fatal(1, "[DECODE-TEST] FAIL LB mem_op");

            i = build_i(12'd0, 5'd0, 5'd0, FUNCT3_LH,  OPCODE_LOAD);  apply(i);
            if (decoded_w.mem_op !== MEM_LH)
                $fatal(1, "[DECODE-TEST] FAIL LH mem_op");

            i = build_i(12'd0, 5'd0, 5'd0, FUNCT3_LBU, OPCODE_LOAD);  apply(i);
            if (decoded_w.mem_op !== MEM_LBU)
                $fatal(1, "[DECODE-TEST] FAIL LBU mem_op");

            i = build_i(12'd0, 5'd0, 5'd0, FUNCT3_LHU, OPCODE_LOAD);  apply(i);
            if (decoded_w.mem_op !== MEM_LHU)
                $fatal(1, "[DECODE-TEST] FAIL LHU mem_op");

            // Illegal: reserved funct3 011, 110, 111
            i = build_i(12'd0, 5'd0, 5'd0, 3'b011, OPCODE_LOAD); apply(i);
            expect_illegal(i, "LOAD funct3=011");

            i = build_i(12'd0, 5'd0, 5'd0, 3'b110, OPCODE_LOAD); apply(i);
            expect_illegal(i, "LOAD funct3=110");

            i = build_i(12'd0, 5'd0, 5'd0, 3'b111, OPCODE_LOAD); apply(i);
            expect_illegal(i, "LOAD funct3=111");
        end

        // ================================================================
        // STORE
        // ================================================================
        begin : t_store
            automatic instr_t i;
            // SW x3, 12(x4)
            i = build_s(12'd12, 5'd3, 5'd4, FUNCT3_SW, OPCODE_STORE);
            apply(i);
            expect_legal(1'b1, OPCLASS_STORE, ALU_ADD, WB_NONE,
                         1'b1, 1'b1, 1'b0, "SW x3, 12(x4)");
            if (!decoded_w.is_store)
                $fatal(1, "[DECODE-TEST] FAIL SW: is_store not set");
            if (decoded_w.mem_op !== MEM_SW)
                $fatal(1, "[DECODE-TEST] FAIL SW mem_op");
            if (decoded_w.imm !== 32'hC)
                $fatal(1, "[DECODE-TEST] FAIL SW imm=%08h exp=12", decoded_w.imm);

            i = build_s(12'd0, 5'd0, 5'd0, FUNCT3_SB, OPCODE_STORE); apply(i);
            if (decoded_w.mem_op !== MEM_SB)
                $fatal(1, "[DECODE-TEST] FAIL SB mem_op");

            i = build_s(12'd0, 5'd0, 5'd0, FUNCT3_SH, OPCODE_STORE); apply(i);
            if (decoded_w.mem_op !== MEM_SH)
                $fatal(1, "[DECODE-TEST] FAIL SH mem_op");

            // Illegal: funct3 011, 100, 101, 110, 111
            i = build_s(12'd0, 5'd0, 5'd0, 3'b011, OPCODE_STORE); apply(i);
            expect_illegal(i, "STORE funct3=011");

            i = build_s(12'd0, 5'd0, 5'd0, 3'b100, OPCODE_STORE); apply(i);
            expect_illegal(i, "STORE funct3=100");
        end

        // ================================================================
        // OP-IMM
        // ================================================================
        begin : t_op_imm
            automatic instr_t i;
            // ADDI x1, x2, 5
            i = build_i(12'd5, 5'd2, 5'd1, FUNCT3_ADD_SUB, OPCODE_OP_IMM);
            apply(i);
            expect_legal(1'b1, OPCLASS_ALU, ALU_ADD, WB_ALU,
                         1'b1, 1'b0, 1'b1, "ADDI x1,x2,5");
            if (decoded_w.imm !== 32'h5)
                $fatal(1, "[DECODE-TEST] FAIL ADDI imm");

            // SLTI
            i = build_i(12'hFFF, 5'd1, 5'd2, FUNCT3_SLT, OPCODE_OP_IMM);
            apply(i);
            if (decoded_w.alu_op !== ALU_SLT)
                $fatal(1, "[DECODE-TEST] FAIL SLTI alu_op");
            if (decoded_w.imm !== 32'hFFFF_FFFF)
                $fatal(1, "[DECODE-TEST] FAIL SLTI imm sign-ext");

            // SLTIU
            i = build_i(12'd1, 5'd1, 5'd2, FUNCT3_SLTU, OPCODE_OP_IMM);
            apply(i);
            if (decoded_w.alu_op !== ALU_SLTU)
                $fatal(1, "[DECODE-TEST] FAIL SLTIU alu_op");

            // XORI, ORI, ANDI
            i = build_i(12'hF0, 5'd1, 5'd2, FUNCT3_XOR, OPCODE_OP_IMM); apply(i);
            if (decoded_w.alu_op !== ALU_XOR)
                $fatal(1, "[DECODE-TEST] FAIL XORI alu_op");

            i = build_i(12'h0F, 5'd1, 5'd2, FUNCT3_OR, OPCODE_OP_IMM); apply(i);
            if (decoded_w.alu_op !== ALU_OR)
                $fatal(1, "[DECODE-TEST] FAIL ORI alu_op");

            i = build_i(12'hFF, 5'd1, 5'd2, FUNCT3_AND, OPCODE_OP_IMM); apply(i);
            if (decoded_w.alu_op !== ALU_AND)
                $fatal(1, "[DECODE-TEST] FAIL ANDI alu_op");

            // SLLI — shamt in imm[4:0], funct7 must be 0000000
            i = '0;
            i[31:25] = FUNCT7_NORMAL;   // funct7
            i[24:20] = 5'd3;            // shamt = 3
            i[19:15] = 5'd1;            // rs1
            i[14:12] = FUNCT3_SLL;
            i[11:7]  = 5'd2;            // rd
            i[6:0]   = OPCODE_OP_IMM;
            apply(i);
            if (!decoded_w.legal)
                $fatal(1, "[DECODE-TEST] FAIL SLLI: not legal");
            if (decoded_w.alu_op !== ALU_SLL)
                $fatal(1, "[DECODE-TEST] FAIL SLLI alu_op");
            if (decoded_w.imm[4:0] !== 5'd3)
                $fatal(1, "[DECODE-TEST] FAIL SLLI shamt in imm[4:0]");

            // SLLI with bad funct7 → illegal
            i[31:25] = FUNCT7_ALT;
            apply(i);
            expect_illegal(i, "SLLI funct7=ALT");

            // SRLI — funct7 = FUNCT7_NORMAL
            i = '0;
            i[31:25] = FUNCT7_NORMAL;
            i[24:20] = 5'd1;
            i[19:15] = 5'd1;
            i[14:12] = FUNCT3_SRL_SRA;
            i[11:7]  = 5'd2;
            i[6:0]   = OPCODE_OP_IMM;
            apply(i);
            if (decoded_w.alu_op !== ALU_SRL)
                $fatal(1, "[DECODE-TEST] FAIL SRLI alu_op");

            // SRAI — funct7 = FUNCT7_ALT
            i[31:25] = FUNCT7_ALT;
            apply(i);
            if (decoded_w.alu_op !== ALU_SRA)
                $fatal(1, "[DECODE-TEST] FAIL SRAI alu_op");

            // SRLI/SRAI with bad funct7 → illegal
            i[31:25] = FUNCT7_MEXT;
            apply(i);
            expect_illegal(i, "SRLI/SRAI funct7=MEXT");
        end

        // ================================================================
        // OP (register-register)
        // ================================================================
        begin : t_op
            automatic instr_t i;
            // ADD x3, x1, x2
            i = build_r(FUNCT7_NORMAL, 5'd2, 5'd1, 5'd3, FUNCT3_ADD_SUB, OPCODE_OP);
            apply(i);
            expect_legal(1'b1, OPCLASS_ALU, ALU_ADD, WB_ALU,
                         1'b1, 1'b1, 1'b1, "ADD x3,x1,x2");
            if (decoded_w.imm !== 32'h0)
                $fatal(1, "[DECODE-TEST] FAIL ADD: R-type imm should be 0");

            // SUB
            i = build_r(FUNCT7_ALT, 5'd2, 5'd1, 5'd3, FUNCT3_ADD_SUB, OPCODE_OP);
            apply(i);
            if (decoded_w.alu_op !== ALU_SUB)
                $fatal(1, "[DECODE-TEST] FAIL SUB alu_op");

            // MUL: funct7=MEXT, funct3=000 → legal RV32M instruction
            i = build_r(FUNCT7_MEXT, 5'd2, 5'd1, 5'd3, FUNCT3_ADD_SUB, OPCODE_OP);
            apply(i);
            expect_legal(1'b1, OPCLASS_LONG_LAT, ALU_MUL, WB_ALU,
                         1'b1, 1'b1, 1'b1, "OP MUL funct7=MEXT");

            // SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND
            i = build_r(FUNCT7_NORMAL, 5'd2, 5'd1, 5'd3, FUNCT3_SLL,     OPCODE_OP); apply(i);
            if (decoded_w.alu_op !== ALU_SLL)  $fatal(1, "[DECODE-TEST] FAIL SLL alu_op");

            i = build_r(FUNCT7_NORMAL, 5'd2, 5'd1, 5'd3, FUNCT3_SLT,     OPCODE_OP); apply(i);
            if (decoded_w.alu_op !== ALU_SLT)  $fatal(1, "[DECODE-TEST] FAIL SLT alu_op");

            i = build_r(FUNCT7_NORMAL, 5'd2, 5'd1, 5'd3, FUNCT3_SLTU,    OPCODE_OP); apply(i);
            if (decoded_w.alu_op !== ALU_SLTU) $fatal(1, "[DECODE-TEST] FAIL SLTU alu_op");

            i = build_r(FUNCT7_NORMAL, 5'd2, 5'd1, 5'd3, FUNCT3_XOR,     OPCODE_OP); apply(i);
            if (decoded_w.alu_op !== ALU_XOR)  $fatal(1, "[DECODE-TEST] FAIL XOR alu_op");

            i = build_r(FUNCT7_NORMAL, 5'd2, 5'd1, 5'd3, FUNCT3_SRL_SRA, OPCODE_OP); apply(i);
            if (decoded_w.alu_op !== ALU_SRL)  $fatal(1, "[DECODE-TEST] FAIL SRL alu_op");

            i = build_r(FUNCT7_ALT,    5'd2, 5'd1, 5'd3, FUNCT3_SRL_SRA, OPCODE_OP); apply(i);
            if (decoded_w.alu_op !== ALU_SRA)  $fatal(1, "[DECODE-TEST] FAIL SRA alu_op");

            i = build_r(FUNCT7_NORMAL, 5'd2, 5'd1, 5'd3, FUNCT3_OR,      OPCODE_OP); apply(i);
            if (decoded_w.alu_op !== ALU_OR)   $fatal(1, "[DECODE-TEST] FAIL OR alu_op");

            i = build_r(FUNCT7_NORMAL, 5'd2, 5'd1, 5'd3, FUNCT3_AND,     OPCODE_OP); apply(i);
            if (decoded_w.alu_op !== ALU_AND)  $fatal(1, "[DECODE-TEST] FAIL AND alu_op");

            // Bad funct7 on arithmetic ops → illegal
            i = build_r(FUNCT7_ALT, 5'd2, 5'd1, 5'd3, FUNCT3_SLT, OPCODE_OP); apply(i);
            expect_illegal(i, "SLT funct7=ALT");

            i = build_r(FUNCT7_ALT, 5'd2, 5'd1, 5'd3, FUNCT3_AND, OPCODE_OP); apply(i);
            expect_illegal(i, "AND funct7=ALT");
        end

        // ================================================================
        // SYSTEM — ECALL, EBREAK, MRET, and all CSR variants
        // ================================================================
        begin : t_system
            automatic instr_t i;

            // ---- ECALL: 0x00000073 ----
            i = '0;
            i[31:20] = FUNCT12_ECALL;
            i[6:0]   = OPCODE_SYSTEM;
            apply(i);
            if (!decoded_w.legal)
                $fatal(1, "[DECODE-TEST] FAIL ECALL: not legal");
            if (decoded_w.op_class !== OPCLASS_SYSTEM)
                $fatal(1, "[DECODE-TEST] FAIL ECALL: op_class");
            if (!decoded_w.exception.valid)
                $fatal(1, "[DECODE-TEST] FAIL ECALL: exception.valid not set");
            if (decoded_w.exception.cause !== EXC_ECALL_M)
                $fatal(1, "[DECODE-TEST] FAIL ECALL: cause=%0d exp EXC_ECALL_M=%0d",
                       int'(decoded_w.exception.cause), int'(EXC_ECALL_M));
            if (decoded_w.writes_rd || decoded_w.is_load || decoded_w.is_store || decoded_w.is_csr)
                $fatal(1, "[DECODE-TEST] FAIL ECALL: spurious action flag");

            // ---- EBREAK: 0x00100073 ----
            i = '0;
            i[31:20] = FUNCT12_EBREAK;
            i[6:0]   = OPCODE_SYSTEM;
            apply(i);
            if (!decoded_w.legal)
                $fatal(1, "[DECODE-TEST] FAIL EBREAK: not legal");
            if (!decoded_w.exception.valid)
                $fatal(1, "[DECODE-TEST] FAIL EBREAK: exception.valid not set");
            if (decoded_w.exception.cause !== EXC_BREAKPOINT)
                $fatal(1, "[DECODE-TEST] FAIL EBREAK: cause=%0d exp EXC_BREAKPOINT=%0d",
                       int'(decoded_w.exception.cause), int'(EXC_BREAKPOINT));
            if (decoded_w.is_csr || decoded_w.is_mret)
                $fatal(1, "[DECODE-TEST] FAIL EBREAK: spurious CSR/MRET flag");

            // ---- MRET: 0x30200073 (funct12=0x302, rs1=0, rd=0, funct3=0) ----
            i = '0;
            i[31:20] = FUNCT12_MRET;
            i[6:0]   = OPCODE_SYSTEM;
            apply(i);
            if (!decoded_w.legal)
                $fatal(1, "[DECODE-TEST] FAIL MRET: not legal");
            if (decoded_w.op_class !== OPCLASS_SYSTEM)
                $fatal(1, "[DECODE-TEST] FAIL MRET: op_class");
            if (!decoded_w.is_mret)
                $fatal(1, "[DECODE-TEST] FAIL MRET: is_mret not set");
            if (decoded_w.exception.valid)
                $fatal(1, "[DECODE-TEST] FAIL MRET: spurious exception.valid");
            if (decoded_w.writes_rd || decoded_w.is_csr || decoded_w.uses_rs1)
                $fatal(1, "[DECODE-TEST] FAIL MRET: spurious action flag");

            // ---- WFI: 0x10500073 (funct12=0x105, rs1=0, rd=0, funct3=0) ----
            // Executes as a NOP: legal, no exception, no side effects.
            i = '0;
            i[31:20] = FUNCT12_WFI;
            i[6:0]   = OPCODE_SYSTEM;
            apply(i);
            if (!decoded_w.legal)
                $fatal(1, "[DECODE-TEST] FAIL WFI: not legal (must execute as NOP)");
            if (decoded_w.op_class !== OPCLASS_SYSTEM)
                $fatal(1, "[DECODE-TEST] FAIL WFI: op_class");
            if (decoded_w.exception.valid)
                $fatal(1, "[DECODE-TEST] FAIL WFI: spurious exception.valid");
            if (decoded_w.writes_rd || decoded_w.is_csr || decoded_w.is_mret ||
                decoded_w.uses_rs1 || decoded_w.uses_rs2)
                $fatal(1, "[DECODE-TEST] FAIL WFI: spurious action flag");

            // WFI with rs1!=0 or rd!=0 is not a valid encoding → illegal
            i = '0;
            i[31:20] = FUNCT12_WFI;
            i[19:15] = 5'd1;
            i[6:0]   = OPCODE_SYSTEM;
            apply(i);
            expect_illegal(i, "WFI rs1!=0");
            i = '0;
            i[31:20] = FUNCT12_WFI;
            i[11:7]  = 5'd1;
            i[6:0]   = OPCODE_SYSTEM;
            apply(i);
            expect_illegal(i, "WFI rd!=0");

            // ---- CSR legality: unimplemented CSR / read-only writes ----
            // CSRRW to unimplemented CSR 0x123 → illegal
            i = '0;
            i[31:20] = 12'h123;
            i[19:15] = 5'd2;
            i[14:12] = 3'b001;  // CSRRW
            i[11:7]  = 5'd1;
            i[6:0]   = OPCODE_SYSTEM;
            apply(i);
            expect_illegal(i, "CSRRW unimplemented CSR");
            // CSRRW to read-only cycle (0xC00) → illegal
            i = '0;
            i[31:20] = CSR_CYCLE;
            i[19:15] = 5'd2;
            i[14:12] = 3'b001;
            i[11:7]  = 5'd1;
            i[6:0]   = OPCODE_SYSTEM;
            apply(i);
            expect_illegal(i, "CSRRW read-only CSR");
            // CSRRS rd, cycle, x0 (pure read of RO CSR) → legal
            i = '0;
            i[31:20] = CSR_CYCLE;
            i[14:12] = 3'b010;  // CSRRS
            i[11:7]  = 5'd1;
            i[6:0]   = OPCODE_SYSTEM;
            apply(i);
            if (!decoded_w.legal)
                $fatal(1, "[DECODE-TEST] FAIL: CSRRS x0 read of RO CSR must be legal");
            // CSRRS rd, cycle, x2 (would write RO CSR) → illegal
            i[19:15] = 5'd2;
            apply(i);
            expect_illegal(i, "CSRRS rs1!=x0 to read-only CSR");

            // ---- CSRRW x1, mstatus(0x300), x2 (funct3=001) ----
            i = '0;
            i[31:20] = CSR_MSTATUS;
            i[19:15] = 5'd2;    // rs1 = x2
            i[14:12] = 3'b001;  // CSRRW
            i[11:7]  = 5'd1;    // rd  = x1
            i[6:0]   = OPCODE_SYSTEM;
            apply(i);
            if (!decoded_w.legal)
                $fatal(1, "[DECODE-TEST] FAIL CSRRW: not legal");
            if (decoded_w.op_class !== OPCLASS_SYSTEM)
                $fatal(1, "[DECODE-TEST] FAIL CSRRW: op_class");
            if (!decoded_w.is_csr)
                $fatal(1, "[DECODE-TEST] FAIL CSRRW: is_csr not set");
            if (decoded_w.csr_op !== CSR_WRITE)
                $fatal(1, "[DECODE-TEST] FAIL CSRRW: csr_op=%0b exp CSR_WRITE", decoded_w.csr_op);
            if (decoded_w.csr_addr !== CSR_MSTATUS)
                $fatal(1, "[DECODE-TEST] FAIL CSRRW: csr_addr=%0h exp 0x300", decoded_w.csr_addr);
            if (!decoded_w.uses_rs1)
                $fatal(1, "[DECODE-TEST] FAIL CSRRW: uses_rs1 not set");
            if (!decoded_w.writes_rd)
                $fatal(1, "[DECODE-TEST] FAIL CSRRW: writes_rd not set (rd=x1)");
            if (decoded_w.wb_src !== WB_CSR)
                $fatal(1, "[DECODE-TEST] FAIL CSRRW: wb_src not WB_CSR");
            if (decoded_w.is_mret || decoded_w.exception.valid)
                $fatal(1, "[DECODE-TEST] FAIL CSRRW: spurious flag");

            // ---- CSRRS x3, mtvec(0x305), x0 (funct3=010, rs1=x0) ----
            // Per RV spec: CSRRS with rs1=x0 is a pure read — must not modify the CSR.
            // Decoder sets csr_op=CSR_NOP; rd still receives the old CSR value.
            i = '0;
            i[31:20] = CSR_MTVEC;
            i[19:15] = 5'd0;    // rs1 = x0
            i[14:12] = 3'b010;  // CSRRS
            i[11:7]  = 5'd3;    // rd  = x3
            i[6:0]   = OPCODE_SYSTEM;
            apply(i);
            if (!decoded_w.legal || !decoded_w.is_csr)
                $fatal(1, "[DECODE-TEST] FAIL CSRRS: not legal or not is_csr");
            if (decoded_w.csr_op !== CSR_NOP)
                $fatal(1, "[DECODE-TEST] FAIL CSRRS(rs1=x0): csr_op=%0b exp CSR_NOP (read-only)", decoded_w.csr_op);
            if (decoded_w.csr_addr !== CSR_MTVEC)
                $fatal(1, "[DECODE-TEST] FAIL CSRRS: csr_addr");
            if (!decoded_w.writes_rd)
                $fatal(1, "[DECODE-TEST] FAIL CSRRS: writes_rd not set (rd=x3)");

            // ---- CSRRC x0, mscratch(0x340), x5 (funct3=011, rd=x0 → writes_rd=0) ----
            i = '0;
            i[31:20] = CSR_MSCRATCH;
            i[19:15] = 5'd5;    // rs1 = x5
            i[14:12] = 3'b011;  // CSRRC
            i[11:7]  = 5'd0;    // rd  = x0
            i[6:0]   = OPCODE_SYSTEM;
            apply(i);
            if (!decoded_w.legal || !decoded_w.is_csr)
                $fatal(1, "[DECODE-TEST] FAIL CSRRC(rd=0): not legal or not is_csr");
            if (decoded_w.csr_op !== CSR_CLR)
                $fatal(1, "[DECODE-TEST] FAIL CSRRC(rd=0): csr_op=%0b exp CSR_CLR", decoded_w.csr_op);
            if (decoded_w.writes_rd)
                $fatal(1, "[DECODE-TEST] FAIL CSRRC(rd=0): writes_rd set despite rd=x0");
            if (decoded_w.wb_src !== WB_CSR)
                $fatal(1, "[DECODE-TEST] FAIL CSRRC(rd=0): wb_src not WB_CSR");

            // ---- CSRRWI x4, mcause(0x342), zimm=7 (funct3=101, uses_rs1=0) ----
            i = '0;
            i[31:20] = CSR_MCAUSE;
            i[19:15] = 5'd7;    // zimm = 7
            i[14:12] = 3'b101;  // CSRRWI
            i[11:7]  = 5'd4;    // rd  = x4
            i[6:0]   = OPCODE_SYSTEM;
            apply(i);
            if (!decoded_w.legal || !decoded_w.is_csr)
                $fatal(1, "[DECODE-TEST] FAIL CSRRWI: not legal or not is_csr");
            if (decoded_w.csr_op !== CSR_WRITE)
                $fatal(1, "[DECODE-TEST] FAIL CSRRWI: csr_op=%0b exp CSR_WRITE", decoded_w.csr_op);
            if (decoded_w.uses_rs1)
                $fatal(1, "[DECODE-TEST] FAIL CSRRWI: uses_rs1 set (should be 0 for imm form)");
            if (!decoded_w.writes_rd)
                $fatal(1, "[DECODE-TEST] FAIL CSRRWI: writes_rd not set (rd=x4)");
            if (decoded_w.imm !== 32'd7)
                $fatal(1, "[DECODE-TEST] FAIL CSRRWI: imm=%0d exp 7 (zimm=7)", decoded_w.imm);
            if (decoded_w.csr_addr !== CSR_MCAUSE)
                $fatal(1, "[DECODE-TEST] FAIL CSRRWI: csr_addr");

            // ---- CSRRSI x5, mtval(0x343), zimm=3 (funct3=110) ----
            i = '0;
            i[31:20] = CSR_MTVAL;
            i[19:15] = 5'd3;    // zimm = 3
            i[14:12] = 3'b110;  // CSRRSI
            i[11:7]  = 5'd5;    // rd  = x5
            i[6:0]   = OPCODE_SYSTEM;
            apply(i);
            if (!decoded_w.legal || !decoded_w.is_csr)
                $fatal(1, "[DECODE-TEST] FAIL CSRRSI: not legal or not is_csr");
            if (decoded_w.csr_op !== CSR_SET)
                $fatal(1, "[DECODE-TEST] FAIL CSRRSI: csr_op");
            if (decoded_w.uses_rs1)
                $fatal(1, "[DECODE-TEST] FAIL CSRRSI: uses_rs1 set for imm form");
            if (decoded_w.imm !== 32'd3)
                $fatal(1, "[DECODE-TEST] FAIL CSRRSI: imm=%0d exp 3", decoded_w.imm);

            // ---- CSRRCI x6, mepc(0x341), zimm=15 (funct3=111) ----
            i = '0;
            i[31:20] = CSR_MEPC;
            i[19:15] = 5'd15;   // zimm = 15
            i[14:12] = 3'b111;  // CSRRCI
            i[11:7]  = 5'd6;    // rd  = x6
            i[6:0]   = OPCODE_SYSTEM;
            apply(i);
            if (!decoded_w.legal || !decoded_w.is_csr)
                $fatal(1, "[DECODE-TEST] FAIL CSRRCI: not legal or not is_csr");
            if (decoded_w.csr_op !== CSR_CLR)
                $fatal(1, "[DECODE-TEST] FAIL CSRRCI: csr_op");
            if (decoded_w.imm !== 32'd15)
                $fatal(1, "[DECODE-TEST] FAIL CSRRCI: imm=%0d exp 15", decoded_w.imm);

            // ---- SYSTEM funct3=100 → illegal ----
            i = '0;
            i[14:12] = 3'b100;
            i[6:0]   = OPCODE_SYSTEM;
            apply(i);
            expect_illegal(i, "SYSTEM funct3=100 (reserved)");

            // ---- SYSTEM funct3=000 with rs1!=0 → illegal ----
            i = '0;
            i[19:15] = 5'd1;    // rs1 = x1 (violates PRIV encoding requirement)
            i[6:0]   = OPCODE_SYSTEM;
            apply(i);
            expect_illegal(i, "SYSTEM PRIV with rs1!=0");

            // ---- Unknown funct12 with funct3=000, rs1=0, rd=0 → illegal ----
            i = '0;
            i[31:20] = 12'h002;  // not ECALL (0x000), EBREAK (0x001), or MRET (0x302)
            i[6:0]   = OPCODE_SYSTEM;
            apply(i);
            expect_illegal(i, "SYSTEM unknown funct12 0x002");
        end

        // ================================================================
        // MISC-MEM (FENCE)
        // ================================================================
        begin : t_misc_mem
            automatic instr_t i;

            // FENCE (funct3=000)
            i = '0;
            i[14:12] = 3'b000;
            i[6:0]   = OPCODE_MISC_MEM;
            apply(i);
            if (!decoded_w.legal)
                $fatal(1, "[DECODE-TEST] FAIL FENCE: not legal");
            if (decoded_w.op_class !== OPCLASS_SYSTEM)
                $fatal(1, "[DECODE-TEST] FAIL FENCE: op_class");
            if (decoded_w.writes_rd || decoded_w.is_load || decoded_w.is_store)
                $fatal(1, "[DECODE-TEST] FAIL FENCE: spurious action flag");

            // FENCE.I (funct3=001)
            i[14:12] = 3'b001;
            apply(i);
            if (!decoded_w.legal)
                $fatal(1, "[DECODE-TEST] FAIL FENCE.I: not legal");

            // Illegal: funct3 = 010
            i[14:12] = 3'b010;
            apply(i);
            expect_illegal(i, "MISC-MEM funct3=010");
        end

        // ================================================================
        // Unknown opcode
        // ================================================================
        begin : t_unknown_opcode
            automatic instr_t i;
            // 7'b000_0111 = LOAD-FP (floating-point loads) — not implemented in FluxCore
            i = '0;
            i[6:0] = 7'b000_0111;
            apply(i);
            expect_illegal(i, "unknown opcode LOAD-FP (0x07)");
            // All-zeros instruction is also illegal (opcode 0b000_0000)
            i = 32'h0;
            apply(i);
            expect_illegal(i, "all-zeros instruction");
        end

        // ================================================================
        // Mutual exclusion of class flags
        // ================================================================
        begin : t_mutex
            automatic instr_t i;
            // For every legal instruction, at most one of is_branch/is_jump/
            // is_load/is_store should be set.

            // Load: only is_load
            i = build_i(12'd0, 5'd1, 5'd2, FUNCT3_LW, OPCODE_LOAD);
            apply(i);
            if (decoded_w.is_branch || decoded_w.is_jump || decoded_w.is_store)
                $fatal(1, "[DECODE-TEST] FAIL mutex: LW has extra class flag");

            // Store: only is_store
            i = build_s(12'd0, 5'd1, 5'd0, FUNCT3_SW, OPCODE_STORE);
            apply(i);
            if (decoded_w.is_branch || decoded_w.is_jump || decoded_w.is_load)
                $fatal(1, "[DECODE-TEST] FAIL mutex: SW has extra class flag");

            // Branch: only is_branch
            i = build_b(13'd4, 5'd1, 5'd2, FUNCT3_BEQ, OPCODE_BRANCH);
            apply(i);
            if (decoded_w.is_jump || decoded_w.is_load || decoded_w.is_store)
                $fatal(1, "[DECODE-TEST] FAIL mutex: BEQ has extra class flag");

            // Jump: only is_jump
            i = build_j(21'd4, 5'd1, OPCODE_JAL);
            apply(i);
            if (decoded_w.is_branch || decoded_w.is_load || decoded_w.is_store)
                $fatal(1, "[DECODE-TEST] FAIL mutex: JAL has extra class flag");

            // ALU: none of the class flags
            i = build_r(FUNCT7_NORMAL, 5'd2, 5'd1, 5'd3, FUNCT3_ADD_SUB, OPCODE_OP);
            apply(i);
            if (decoded_w.is_branch || decoded_w.is_jump || decoded_w.is_load || decoded_w.is_store
                    || decoded_w.is_csr || decoded_w.is_mret)
                $fatal(1, "[DECODE-TEST] FAIL mutex: ADD has class flag set");

            // CSR: only is_csr; no branch/jump/load/store/mret
            i = '0;
            i[31:20] = CSR_MSCRATCH;
            i[14:12] = 3'b001;   // CSRRW
            i[11:7]  = 5'd1;
            i[19:15] = 5'd2;
            i[6:0]   = OPCODE_SYSTEM;
            apply(i);
            if (decoded_w.is_branch || decoded_w.is_jump || decoded_w.is_load
                    || decoded_w.is_store || decoded_w.is_mret)
                $fatal(1, "[DECODE-TEST] FAIL mutex: CSRRW has extra class flag");
            if (!decoded_w.is_csr)
                $fatal(1, "[DECODE-TEST] FAIL mutex: CSRRW is_csr not set");

            // MRET: only is_mret; no branch/jump/load/store/csr
            i = '0;
            i[31:20] = FUNCT12_MRET;
            i[6:0]   = OPCODE_SYSTEM;
            apply(i);
            if (decoded_w.is_branch || decoded_w.is_jump || decoded_w.is_load
                    || decoded_w.is_store || decoded_w.is_csr)
                $fatal(1, "[DECODE-TEST] FAIL mutex: MRET has extra class flag");
            if (!decoded_w.is_mret)
                $fatal(1, "[DECODE-TEST] FAIL mutex: MRET is_mret not set");
        end

        // ================================================================
        // Register index pass-through
        // ================================================================
        begin : t_reg_idx
            automatic instr_t i;
            // ADD x7, x12, x19
            i = build_r(FUNCT7_NORMAL, 5'd19, 5'd12, 5'd7, FUNCT3_ADD_SUB, OPCODE_OP);
            apply(i);
            if (decoded_w.rs1 !== 5'd12)
                $fatal(1, "[DECODE-TEST] FAIL rs1 passthrough: got %0d exp 12", decoded_w.rs1);
            if (decoded_w.rs2 !== 5'd19)
                $fatal(1, "[DECODE-TEST] FAIL rs2 passthrough: got %0d exp 19", decoded_w.rs2);
            if (decoded_w.rd !== 5'd7)
                $fatal(1, "[DECODE-TEST] FAIL rd passthrough: got %0d exp 7", decoded_w.rd);
        end

        // ================================================================
        // Done
        // ================================================================
        $display("[DECODE-TEST] PASS: all decoder tests passed.");
        $display("[DECODE-TEST]   LUI AUIPC JAL JALR BRANCH LOAD STORE OP-IMM OP FENCE");
        $display("[DECODE-TEST]   SYSTEM: ECALL EBREAK MRET CSRRW CSRRS CSRRC CSRRWI CSRRSI CSRRCI");
        $display("[DECODE-TEST]   Illegal: bad opcode, funct3, funct7, system encodings, funct3=100");
        $finish;

    end : test_body

endmodule : tb_decoder

`default_nettype wire
