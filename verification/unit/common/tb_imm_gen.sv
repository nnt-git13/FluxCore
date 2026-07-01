// verification/unit/common/tb_imm_gen.sv
//
// Self-checking testbench for rtl/common/imm_gen.sv.
//
// Strategy:
//   All instructions are assembled field-by-field from RISC-V bit positions
//   (no pre-computed hex constants). This makes the expected encoding the
//   authoritative reference, not a magic number.
//
//   Directed tests per format:
//     IFMT_R  — zero immediate regardless of instruction content
//     IFMT_I  — positive, negative, zero, max-positive (+2047), min-negative (-2048)
//     IFMT_S  — positive (8), negative (-4), max positive (+2047), min negative (-2048)
//     IFMT_B  — positive (8), negative (-4), max (+4094), min (-4096)
//     IFMT_U  — zero upper bits, all-ones upper bits, arbitrary upper bits
//     IFMT_J  — zero, positive (+4), negative (-4), large positive, large negative
//
//   Structural invariants:
//     B-format result[0] must always be 0.
//     J-format result[0] must always be 0.
//     U-format result[11:0] must always be 0.
//     I-format: all of result[31:12] must equal result[11] (sign).
//
// Pass/fail:
//   $fatal(1, ...) on any mismatch.
//   Prints "[IMMGEN-TEST] PASS" and $finish on success.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;

module tb_imm_gen;

    // -----------------------------------------------------------------------
    // DUT wires
    // -----------------------------------------------------------------------
    instr_t     instr_w;
    instr_fmt_e fmt_w;
    word_t      imm_w;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    imm_gen dut (
        .instr_i(instr_w),
        .fmt_i  (fmt_w),
        .imm_o  (imm_w)
    );

    // -----------------------------------------------------------------------
    // Helper
    // -----------------------------------------------------------------------
    task automatic check_imm(
        input instr_t     instr,
        input instr_fmt_e fmt,
        input word_t      expected,
        input string      desc
    );
        instr_w = instr;
        fmt_w   = fmt;
        #1;
        if (imm_w !== expected)
            $fatal(1, "[IMMGEN-TEST] FAIL %-20s instr=%08h fmt=%0d imm=%08h expected=%08h",
                   desc, instr, int'(fmt), imm_w, expected);
    endtask

    // -----------------------------------------------------------------------
    // Helper: construct a clean instr_t with all fields zeroed first
    // -----------------------------------------------------------------------
    // Used to avoid relying on uninitialised bits when assigning subfields.

    function automatic instr_t make_i_type(
        input logic [11:0] imm,
        input logic [4:0]  rs1,
        input logic [2:0]  funct3,
        input logic [4:0]  rd,
        input logic [6:0]  opcode
    );
        automatic instr_t i;
        i = '0;
        i[31:20] = imm;
        i[19:15] = rs1;
        i[14:12] = funct3;
        i[11:7]  = rd;
        i[6:0]   = opcode;
        return i;
    endfunction

    function automatic instr_t make_s_type(
        input logic [11:0] imm,
        input logic [4:0]  rs2,
        input logic [4:0]  rs1,
        input logic [2:0]  funct3,
        input logic [6:0]  opcode
    );
        automatic instr_t i;
        i = '0;
        i[31:25] = imm[11:5];
        i[24:20] = rs2;
        i[19:15] = rs1;
        i[14:12] = funct3;
        i[11:7]  = imm[4:0];
        i[6:0]   = opcode;
        return i;
    endfunction

    function automatic instr_t make_b_type(
        input logic [12:0] imm,   // imm[0] should be 0; caller's responsibility
        input logic [4:0]  rs2,
        input logic [4:0]  rs1,
        input logic [2:0]  funct3,
        input logic [6:0]  opcode
    );
        automatic instr_t i;
        i = '0;
        i[31]    = imm[12];
        i[30:25] = imm[10:5];
        i[24:20] = rs2;
        i[19:15] = rs1;
        i[14:12] = funct3;
        i[11:8]  = imm[4:1];
        i[7]     = imm[11];
        i[6:0]   = opcode;
        return i;
    endfunction

    function automatic instr_t make_u_type(
        input logic [19:0] imm_upper20,
        input logic [4:0]  rd,
        input logic [6:0]  opcode
    );
        automatic instr_t i;
        i = '0;
        i[31:12] = imm_upper20;
        i[11:7]  = rd;
        i[6:0]   = opcode;
        return i;
    endfunction

    function automatic instr_t make_j_type(
        input logic [20:0] imm,   // imm[0] should be 0; caller's responsibility
        input logic [4:0]  rd,
        input logic [6:0]  opcode
    );
        automatic instr_t i;
        i = '0;
        i[31]    = imm[20];
        i[30:21] = imm[10:1];
        i[20]    = imm[11];
        i[19:12] = imm[19:12];
        i[11:7]  = rd;
        i[6:0]   = opcode;
        return i;
    endfunction

    // -----------------------------------------------------------------------
    // Main test
    // -----------------------------------------------------------------------
    initial begin : test_body

        instr_w = '0; fmt_w = IFMT_R;
        #1;

        // ================================================================
        // IFMT_R — no immediate; result must be 0 regardless of fields
        // ================================================================
        begin : test_r
            automatic instr_t i;
            // ADD x3, x1, x2 — canonical R-type
            i = '0;
            i[31:25] = FUNCT7_NORMAL;
            i[24:20] = 5'd2;         // rs2
            i[19:15] = 5'd1;         // rs1
            i[14:12] = FUNCT3_ADD_SUB;
            i[11:7]  = 5'd3;         // rd
            i[6:0]   = OPCODE_OP;
            check_imm(i, IFMT_R, 32'h0, "R ADD x3,x1,x2");

            // Poison all instruction bits — result must still be 0
            i = '1;
            i[6:0] = OPCODE_OP;
            check_imm(i, IFMT_R, 32'h0, "R all-ones");
        end

        // ================================================================
        // IFMT_I — sign-extended 12-bit immediate in instr[31:20]
        // ================================================================
        begin : test_i
            automatic instr_t i;
            automatic word_t  exp;

            // ADDI x1, x0, 0
            i   = make_i_type(12'h0, 5'd0, FUNCT3_ADD_SUB, 5'd1, OPCODE_OP_IMM);
            check_imm(i, IFMT_I, 32'h0, "I ADDI +0");

            // ADDI x1, x0, 5
            i   = make_i_type(12'd5, 5'd0, FUNCT3_ADD_SUB, 5'd1, OPCODE_OP_IMM);
            check_imm(i, IFMT_I, 32'h5, "I ADDI +5");

            // ADDI x1, x0, 1
            i   = make_i_type(12'd1, 5'd0, FUNCT3_ADD_SUB, 5'd1, OPCODE_OP_IMM);
            check_imm(i, IFMT_I, 32'h1, "I ADDI +1");

            // ADDI x1, x0, 2047 (max positive I-immediate)
            i   = make_i_type(12'h7FF, 5'd0, FUNCT3_ADD_SUB, 5'd1, OPCODE_OP_IMM);
            check_imm(i, IFMT_I, 32'h7FF, "I ADDI +2047");

            // ADDI x1, x0, -1 → 12'hFFF → sign-extended to 32'hFFFFFFFF
            i   = make_i_type(12'hFFF, 5'd0, FUNCT3_ADD_SUB, 5'd1, OPCODE_OP_IMM);
            check_imm(i, IFMT_I, 32'hFFFF_FFFF, "I ADDI -1");

            // ADDI x1, x0, -2048 (min negative I-immediate: 12'h800)
            i   = make_i_type(12'h800, 5'd0, FUNCT3_ADD_SUB, 5'd1, OPCODE_OP_IMM);
            check_imm(i, IFMT_I, 32'hFFFF_F800, "I ADDI -2048");

            // LW x1, 0(x0) — load with zero offset (also I-type)
            i   = make_i_type(12'h0, 5'd0, FUNCT3_LW, 5'd1, OPCODE_LOAD);
            check_imm(i, IFMT_I, 32'h0, "I LW +0");

            // LW x1, 100(x2)
            i   = make_i_type(12'd100, 5'd2, FUNCT3_LW, 5'd1, OPCODE_LOAD);
            check_imm(i, IFMT_I, 32'd100, "I LW +100");

            // JALR x0, x1, -4 (JALR is I-type)
            i   = make_i_type(12'hFFC, 5'd1, FUNCT3_JALR, 5'd0, OPCODE_JALR);
            check_imm(i, IFMT_I, 32'hFFFF_FFFC, "I JALR -4");

            // Sign extension invariant: for any negative I-imm, bits [31:12] are all 1
            i   = make_i_type(12'hFFF, 5'd0, FUNCT3_ADD_SUB, 5'd1, OPCODE_OP_IMM);
            check_imm(i, IFMT_I, 32'hFFFF_FFFF, "I sign ext all-1");
            if (imm_w[31:12] !== 20'hFFFFF)
                $fatal(1, "[IMMGEN-TEST] FAIL I-format negative sign extension");
        end

        // ================================================================
        // IFMT_S — sign-extended 12-bit, upper 7 in [31:25], lower 5 in [11:7]
        // ================================================================
        begin : test_s
            automatic instr_t i;

            // SW x1, 0(x0)
            i = make_s_type(12'd0, 5'd1, 5'd0, FUNCT3_SW, OPCODE_STORE);
            check_imm(i, IFMT_S, 32'h0, "S SW +0");

            // SW x1, 8(x0)
            i = make_s_type(12'd8, 5'd1, 5'd0, FUNCT3_SW, OPCODE_STORE);
            check_imm(i, IFMT_S, 32'h8, "S SW +8");

            // SB x2, 1(x3)
            i = make_s_type(12'd1, 5'd2, 5'd3, FUNCT3_SB, OPCODE_STORE);
            check_imm(i, IFMT_S, 32'h1, "S SB +1");

            // SW x1, 2047(x0) — max positive S-imm
            i = make_s_type(12'h7FF, 5'd1, 5'd0, FUNCT3_SW, OPCODE_STORE);
            check_imm(i, IFMT_S, 32'h7FF, "S SW +2047");

            // SW x1, -1(x0)
            i = make_s_type(12'hFFF, 5'd1, 5'd0, FUNCT3_SW, OPCODE_STORE);
            check_imm(i, IFMT_S, 32'hFFFF_FFFF, "S SW -1");

            // SW x1, -4(x0)
            i = make_s_type(12'hFFC, 5'd1, 5'd0, FUNCT3_SW, OPCODE_STORE);
            check_imm(i, IFMT_S, 32'hFFFF_FFFC, "S SW -4");

            // SW x1, -2048(x0) — min negative S-imm
            i = make_s_type(12'h800, 5'd1, 5'd0, FUNCT3_SW, OPCODE_STORE);
            check_imm(i, IFMT_S, 32'hFFFF_F800, "S SW -2048");

            // SH x3, 100(x5)
            i = make_s_type(12'd100, 5'd3, 5'd5, FUNCT3_SH, OPCODE_STORE);
            check_imm(i, IFMT_S, 32'd100, "S SH +100");
        end

        // ================================================================
        // IFMT_B — 13-bit signed offset (bit 0 always 0); scrambled in instr
        // ================================================================
        begin : test_b
            automatic instr_t i;

            // BEQ x0, x0, 0 — stay in place
            i = make_b_type(13'd0, 5'd0, 5'd0, FUNCT3_BEQ, OPCODE_BRANCH);
            check_imm(i, IFMT_B, 32'h0, "B BEQ +0");

            // BEQ x1, x2, 8
            i = make_b_type(13'd8, 5'd2, 5'd1, FUNCT3_BEQ, OPCODE_BRANCH);
            check_imm(i, IFMT_B, 32'h8, "B BEQ +8");

            // BNE x1, x2, 4
            i = make_b_type(13'd4, 5'd2, 5'd1, FUNCT3_BNE, OPCODE_BRANCH);
            check_imm(i, IFMT_B, 32'h4, "B BNE +4");

            // BEQ x1, x2, 4094 — max positive B-immediate (12-bit + sign = 13-bit, max = 4094)
            i = make_b_type(13'h0FFE, 5'd2, 5'd1, FUNCT3_BEQ, OPCODE_BRANCH);
            check_imm(i, IFMT_B, 32'h0FFE, "B BEQ +4094");

            // BEQ x0, x0, -4
            // -4 as 13-bit signed (bit[0] always 0): 13'b1_1111_1111_1100 = 0x1FFC
            i = make_b_type(13'b1_1111_1111_1100, 5'd0, 5'd0, FUNCT3_BEQ, OPCODE_BRANCH);
            check_imm(i, IFMT_B, 32'hFFFF_FFFC, "B BEQ -4");

            // BLT x1, x2, -4096 — min negative B-immediate
            i = make_b_type(13'h1000, 5'd2, 5'd1, FUNCT3_BLT, OPCODE_BRANCH);
            check_imm(i, IFMT_B, 32'hFFFF_F000, "B BLT -4096");

            // BEQ x0, x0, -2
            i = make_b_type(13'b1_1111_1111_111_0, 5'd0, 5'd0, FUNCT3_BEQ, OPCODE_BRANCH);
            check_imm(i, IFMT_B, 32'hFFFF_FFFE, "B BEQ -2");

            // Structural invariant: B-format imm[0] must always be 0
            i = make_b_type(13'd8, 5'd0, 5'd0, FUNCT3_BEQ, OPCODE_BRANCH);
            check_imm(i, IFMT_B, 32'h8, "B invariant [0]=0 pos");
            if (imm_w[0] !== 1'b0)
                $fatal(1, "[IMMGEN-TEST] FAIL B-format: result[0] not 0 (positive imm)");

            i = make_b_type(13'b1_1111_1111_1100, 5'd0, 5'd0, FUNCT3_BEQ, OPCODE_BRANCH);
            check_imm(i, IFMT_B, 32'hFFFF_FFFC, "B invariant [0]=0 neg");
            if (imm_w[0] !== 1'b0)
                $fatal(1, "[IMMGEN-TEST] FAIL B-format: result[0] not 0 (negative imm)");
        end

        // ================================================================
        // IFMT_U — upper 20 bits; lower 12 are always 0
        // ================================================================
        begin : test_u
            automatic instr_t i;

            // LUI x1, 0 — zero upper bits
            i = make_u_type(20'h0, 5'd1, OPCODE_LUI);
            check_imm(i, IFMT_U, 32'h0, "U LUI 0");

            // LUI x1, 1 → 0x00001000
            i = make_u_type(20'h1, 5'd1, OPCODE_LUI);
            check_imm(i, IFMT_U, 32'h0000_1000, "U LUI 0x1");

            // LUI x1, 0x12345 → 0x12345000
            i = make_u_type(20'h12345, 5'd1, OPCODE_LUI);
            check_imm(i, IFMT_U, 32'h1234_5000, "U LUI 0x12345");

            // LUI x1, 0xFFFFF → 0xFFFFF000 (all upper bits set)
            i = make_u_type(20'hFFFFF, 5'd1, OPCODE_LUI);
            check_imm(i, IFMT_U, 32'hFFFF_F000, "U LUI 0xFFFFF");

            // AUIPC x2, 0xABCDE
            i = make_u_type(20'hABCDE, 5'd2, OPCODE_AUIPC);
            check_imm(i, IFMT_U, 32'hABCDE000, "U AUIPC 0xABCDE");

            // Structural invariant: lower 12 bits of U-format imm must be 0
            i = make_u_type(20'h12345, 5'd1, OPCODE_LUI);
            check_imm(i, IFMT_U, 32'h1234_5000, "U invariant [11:0]=0");
            if (imm_w[11:0] !== 12'h0)
                $fatal(1, "[IMMGEN-TEST] FAIL U-format: result[11:0] not 0");
        end

        // ================================================================
        // IFMT_J — 21-bit signed offset (bit 0 always 0); scrambled in instr
        // ================================================================
        begin : test_j
            automatic instr_t i;

            // JAL x0, 0 — zero jump
            i = make_j_type(21'd0, 5'd0, OPCODE_JAL);
            check_imm(i, IFMT_J, 32'h0, "J JAL +0");

            // JAL x0, 4
            i = make_j_type(21'd4, 5'd0, OPCODE_JAL);
            check_imm(i, IFMT_J, 32'h4, "J JAL +4");

            // JAL x1, 2 — link to x1, offset 2
            i = make_j_type(21'd2, 5'd1, OPCODE_JAL);
            check_imm(i, IFMT_J, 32'h2, "J JAL x1 +2");

            // JAL x0, 1048574 — max positive J-immediate (2^20 - 2)
            i = make_j_type(21'h0FFFFE, 5'd0, OPCODE_JAL);
            check_imm(i, IFMT_J, 32'h000F_FFFE, "J JAL +1048574");

            // JAL x0, -4
            // -4 as 21-bit: 1_1111_1111_1111_1111_100_0 → bit[0]=0
            // 21'b1_11111_11111_11111_11100 → hmm, let's compute:
            // -4 two's complement in 21 bits: 20-bit magnitude of 4 = 100
            // negated: 1_11111_11111_11111_11100 → 21'h1FFFFC
            i = make_j_type(21'h1FFFFC, 5'd0, OPCODE_JAL);
            check_imm(i, IFMT_J, 32'hFFFF_FFFC, "J JAL -4");

            // JAL x0, -2 — smallest negative step
            i = make_j_type(21'h1FFFFE, 5'd0, OPCODE_JAL);
            check_imm(i, IFMT_J, 32'hFFFF_FFFE, "J JAL -2");

            // JAL x0, -1048576 — min negative J-immediate (bit 20 = 1, rest 0)
            i = make_j_type(21'h100000, 5'd0, OPCODE_JAL);
            check_imm(i, IFMT_J, 32'hFFF0_0000, "J JAL -1048576");

            // Structural invariant: J-format imm[0] must always be 0
            i = make_j_type(21'd4, 5'd0, OPCODE_JAL);
            check_imm(i, IFMT_J, 32'h4, "J invariant [0]=0 pos");
            if (imm_w[0] !== 1'b0)
                $fatal(1, "[IMMGEN-TEST] FAIL J-format: result[0] not 0 (positive imm)");

            i = make_j_type(21'h1FFFFC, 5'd0, OPCODE_JAL);
            check_imm(i, IFMT_J, 32'hFFFF_FFFC, "J invariant [0]=0 neg");
            if (imm_w[0] !== 1'b0)
                $fatal(1, "[IMMGEN-TEST] FAIL J-format: result[0] not 0 (negative imm)");
        end

        // ================================================================
        // Cross-format: same instr bits, different fmt → different result
        // ================================================================
        begin : test_cross
            automatic instr_t i;
            // Build an I-type instruction and verify that asking for B-format
            // gives a different (scrambled) result.
            // ADDI x1, x0, 5 re-interpreted as B-format must NOT give 5.
            i = make_i_type(12'd5, 5'd0, FUNCT3_ADD_SUB, 5'd1, OPCODE_OP_IMM);
            check_imm(i, IFMT_I, 32'h5, "cross I→B original I");
            instr_w = i;
            fmt_w   = IFMT_B;
            #1;
            if (imm_w === 32'h5)
                $fatal(1, "[IMMGEN-TEST] FAIL cross-format: B-fmt gave same result as I-fmt for non-trivial instr");
        end

        // ================================================================
        // Done
        // ================================================================
        $display("[IMMGEN-TEST] PASS: all immediate formats verified.");
        $display("[IMMGEN-TEST]   I/S/B/U/J formats + structural invariants.");
        $finish;

    end : test_body

endmodule : tb_imm_gen

`default_nettype wire
