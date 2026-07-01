// verification/unit/execution/tb_branch_unit.sv
//
// Self-checking testbench for rtl/execution/branch_unit.sv.
//
// Strategy:
//   Directed tests covering:
//     - BRANCH_NONE: always 0 regardless of operands
//     - BEQ / BNE: equality/inequality
//     - BLT / BGE: signed comparisons, including the sign-bit boundary
//     - BLTU / BGEU: unsigned comparisons
//     - Critical signed-vs-unsigned divergence:
//         rs1 = 0xFFFFFFFF (-1 signed, max unsigned), rs2 = 0x1
//         BLT  → taken  (signed -1 < 1)
//         BLTU → NOT taken (unsigned MAX > 1)
//         BGE  → NOT taken (signed -1 not >= 1)
//         BGEU → taken  (unsigned MAX >= 1)
//   Randomized tests: 200 random (rs1, rs2) pairs per operation;
//     expected result computed independently with explicit $signed().
//
// Pass/fail:
//   $fatal(1, ...) on any mismatch.
//   Prints "[BRANCH-TEST] PASS" and $finish on success.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;

module tb_branch_unit;

    // -----------------------------------------------------------------------
    // DUT wires
    // -----------------------------------------------------------------------
    word_t      rs1_w, rs2_w;
    branch_op_e op_w;
    logic       taken_w;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    branch_unit dut (
        .rs1_i  (rs1_w),
        .rs2_i  (rs2_w),
        .op_i   (op_w),
        .taken_o(taken_w)
    );

    // -----------------------------------------------------------------------
    // Helper: apply, settle, check
    // -----------------------------------------------------------------------
    task automatic check_branch(
        input word_t      rs1,
        input word_t      rs2,
        input branch_op_e op,
        input logic       expected,
        input string      desc
    );
        rs1_w = rs1; rs2_w = rs2; op_w = op;
        #1;
        if (taken_w !== expected)
            $fatal(1, "[BRANCH-TEST] FAIL %-20s rs1=%08h rs2=%08h op=%0d taken=%b expected=%b",
                   desc, rs1, rs2, int'(op), taken_w, expected);
    endtask

    // -----------------------------------------------------------------------
    // Compute expected result independently (matches DUT semantics exactly)
    // -----------------------------------------------------------------------
    function automatic logic compute_taken(
        input word_t rs1, input word_t rs2, input branch_op_e op
    );
        case (op)
            BRANCH_EQ:  return logic'(rs1 == rs2);
            BRANCH_NE:  return logic'(rs1 != rs2);
            BRANCH_LT:  return logic'($signed(rs1) <  $signed(rs2));
            BRANCH_GE:  return logic'($signed(rs1) >= $signed(rs2));
            BRANCH_LTU: return logic'(rs1 <  rs2);
            BRANCH_GEU: return logic'(rs1 >= rs2);
            default:    return 1'b0;
        endcase
    endfunction

    // -----------------------------------------------------------------------
    // Randomized test: 200 random pairs per op
    // -----------------------------------------------------------------------
    task automatic random_test(input branch_op_e op, input int n);
        automatic word_t ra, rb;
        for (int i = 0; i < n; i++) begin
            ra = word_t'($urandom());
            rb = word_t'($urandom());
            check_branch(ra, rb, op, compute_taken(ra, rb, op),
                         $sformatf("rnd%0d", i));
        end
    endtask

    // -----------------------------------------------------------------------
    // Main test
    // -----------------------------------------------------------------------
    initial begin : test_body

        rs1_w = '0; rs2_w = '0; op_w = BRANCH_NONE;
        #1;

        // ================================================================
        // BRANCH_NONE — must always be 0
        // ================================================================
        check_branch('0,          '0,          BRANCH_NONE, 1'b0, "none 0,0");
        check_branch('1,          '1,          BRANCH_NONE, 1'b0, "none 1,1");
        check_branch(32'hFFFF_FFFF,32'hFFFF_FFFF,BRANCH_NONE,1'b0,"none -1,-1");
        check_branch('0,          32'h1,       BRANCH_NONE, 1'b0, "none 0,1");

        // ================================================================
        // BEQ — taken iff rs1 == rs2
        // ================================================================
        check_branch('0,           '0,          BRANCH_EQ, 1'b1, "beq 0==0");
        check_branch(32'hDEAD_BEEF,32'hDEAD_BEEF,BRANCH_EQ,1'b1,"beq same");
        check_branch(32'hFFFF_FFFF,32'hFFFF_FFFF,BRANCH_EQ,1'b1,"beq -1==-1");
        check_branch(32'h1,        32'h2,       BRANCH_EQ, 1'b0, "beq 1!=2");
        check_branch(32'h0,        32'hFFFF_FFFF,BRANCH_EQ,1'b0,"beq 0!=-1");
        random_test(BRANCH_EQ, 200);

        // ================================================================
        // BNE — taken iff rs1 != rs2
        // ================================================================
        check_branch(32'h1, 32'h2,         BRANCH_NE, 1'b1, "bne 1!=2");
        check_branch(32'h0, 32'hFFFF_FFFF, BRANCH_NE, 1'b1, "bne 0!=-1");
        check_branch('0,    '0,            BRANCH_NE, 1'b0, "bne 0==0");
        check_branch(32'hABCD, 32'hABCD,  BRANCH_NE, 1'b0, "bne same");
        random_test(BRANCH_NE, 200);

        // ================================================================
        // BLT — taken iff signed(rs1) < signed(rs2)
        // ================================================================
        // Positive cases
        check_branch(32'h0, 32'h1,           BRANCH_LT, 1'b1, "blt 0<1");
        check_branch(32'h1, 32'h2,           BRANCH_LT, 1'b1, "blt 1<2");
        // Negative < positive
        check_branch(32'hFFFF_FFFF, 32'h0,  BRANCH_LT, 1'b1, "blt -1<0");
        check_branch(32'h8000_0000, 32'h7FFF_FFFF, BRANCH_LT, 1'b1, "blt INT_MIN<INT_MAX");
        // Not taken
        check_branch(32'h1, 32'h0,           BRANCH_LT, 1'b0, "blt 1<0 no");
        check_branch(32'h0, 32'hFFFF_FFFF,  BRANCH_LT, 1'b0, "blt 0<-1 no");
        check_branch(32'h5, 32'h5,           BRANCH_LT, 1'b0, "blt equal no");
        // Both negative
        check_branch(32'hFFFF_FFFE, 32'hFFFF_FFFF, BRANCH_LT, 1'b1, "blt -2<-1");
        random_test(BRANCH_LT, 200);

        // ================================================================
        // BGE — taken iff signed(rs1) >= signed(rs2)
        // ================================================================
        check_branch(32'h1, 32'h0,          BRANCH_GE, 1'b1, "bge 1>=0");
        check_branch(32'h0, 32'hFFFF_FFFF, BRANCH_GE, 1'b1, "bge 0>=-1");
        check_branch(32'h5, 32'h5,          BRANCH_GE, 1'b1, "bge equal");
        check_branch(32'hFFFF_FFFF,32'hFFFF_FFFF,BRANCH_GE,1'b1,"bge -1>=-1");
        // Not taken: smaller < larger (signed)
        check_branch(32'h0, 32'h1,          BRANCH_GE, 1'b0, "bge 0>=1 no");
        check_branch(32'hFFFF_FFFF, 32'h0, BRANCH_GE, 1'b0, "bge -1>=0 no");
        // LT and GE are complements for all inputs
        begin : t_lt_ge_complement
            automatic word_t a = 32'hDEAD_BEEF;
            automatic word_t b = 32'h1234_5678;
            automatic logic lt_res, ge_res;
            rs1_w = a; rs2_w = b;
            op_w  = BRANCH_LT;  #1; lt_res = taken_w;
            op_w  = BRANCH_GE;  #1; ge_res = taken_w;
            if (lt_res === ge_res)
                $fatal(1, "[BRANCH-TEST] FAIL LT/GE complement: both same for %08h, %08h", a, b);
        end
        random_test(BRANCH_GE, 200);

        // ================================================================
        // BLTU — taken iff unsigned(rs1) < unsigned(rs2)
        // ================================================================
        check_branch(32'h0, 32'h1,           BRANCH_LTU, 1'b1, "bltu 0<1");
        check_branch(32'h0, 32'hFFFF_FFFF,  BRANCH_LTU, 1'b1, "bltu 0<MAX");
        check_branch(32'h1, 32'hFFFF_FFFF,  BRANCH_LTU, 1'b1, "bltu 1<MAX");
        // Not taken
        check_branch(32'hFFFF_FFFF, 32'h0,  BRANCH_LTU, 1'b0, "bltu MAX<0 no");
        check_branch(32'h5, 32'h5,           BRANCH_LTU, 1'b0, "bltu equal no");
        check_branch(32'h2, 32'h1,           BRANCH_LTU, 1'b0, "bltu 2<1 no");
        random_test(BRANCH_LTU, 200);

        // ================================================================
        // BGEU — taken iff unsigned(rs1) >= unsigned(rs2)
        // ================================================================
        check_branch(32'hFFFF_FFFF, 32'h0,  BRANCH_GEU, 1'b1, "bgeu MAX>=0");
        check_branch(32'h5, 32'h5,           BRANCH_GEU, 1'b1, "bgeu equal");
        check_branch(32'h2, 32'h1,           BRANCH_GEU, 1'b1, "bgeu 2>=1");
        // Not taken
        check_branch(32'h0, 32'h1,           BRANCH_GEU, 1'b0, "bgeu 0>=1 no");
        check_branch(32'h0, 32'hFFFF_FFFF,  BRANCH_GEU, 1'b0, "bgeu 0>=MAX no");
        // LTU and BGEU are complements
        begin : t_ltu_bgeu_complement
            automatic word_t a = 32'hABCD_1234;
            automatic word_t b = 32'h5678_CDEF;
            automatic logic ltu_res, bgeu_res;
            rs1_w = a; rs2_w = b;
            op_w  = BRANCH_LTU;  #1; ltu_res  = taken_w;
            op_w  = BRANCH_GEU;  #1; bgeu_res = taken_w;
            if (ltu_res === bgeu_res)
                $fatal(1, "[BRANCH-TEST] FAIL LTU/BGEU complement: both same for %08h, %08h", a, b);
        end
        random_test(BRANCH_GEU, 200);

        // ================================================================
        // Signed vs unsigned divergence — the critical correctness boundary
        //
        // rs1 = 0xFFFFFFFF (-1 signed, MAX unsigned)
        // rs2 = 0x00000001 (+1 signed, 1 unsigned)
        //
        //   BLT:  signed(-1) < signed(1)  → taken    (correct: -1 < 1)
        //   BLTU: unsigned(MAX) < unsigned(1) → NOT taken  (correct: MAX > 1)
        //   BGE:  signed(-1) >= signed(1) → NOT taken (correct: -1 < 1)
        //   BGEU: unsigned(MAX) >= unsigned(1) → taken (correct: MAX >= 1)
        // ================================================================
        check_branch(32'hFFFF_FFFF, 32'h1, BRANCH_LT,  1'b1, "signed/unsigned BLT");
        check_branch(32'hFFFF_FFFF, 32'h1, BRANCH_LTU, 1'b0, "signed/unsigned BLTU");
        check_branch(32'hFFFF_FFFF, 32'h1, BRANCH_GE,  1'b0, "signed/unsigned BGE");
        check_branch(32'hFFFF_FFFF, 32'h1, BRANCH_GEU, 1'b1, "signed/unsigned BGEU");

        // ================================================================
        // Done
        // ================================================================
        $display("[BRANCH-TEST] PASS: all branch conditions verified.");
        $display("[BRANCH-TEST]   6 ops × directed + 200 random vectors each.");
        $display("[BRANCH-TEST]   Signed/unsigned divergence confirmed.");
        $finish;

    end : test_body

endmodule : tb_branch_unit

`default_nettype wire
