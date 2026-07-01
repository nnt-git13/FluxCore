// verification/unit/execution/tb_alu.sv
//
// Self-checking testbench for rtl/execution/alu.sv.
//
// Verification strategy:
//   1. Directed tests — known input/output pairs that cover:
//        - All 11 ALU operations
//        - Zero operands, identity values
//        - Arithmetic overflow (wraps in unsigned 32-bit arithmetic)
//        - Maximum and minimum signed/unsigned values
//        - Shift edge cases (amount 0, amount 31, upper bits ignored)
//        - Signed vs unsigned comparison correctness
//        - ALU_COPY_B input independence from a_i
//   2. Randomized tests — N random (a, b) pairs per operation, expected
//        result computed independently using the same SV semantics so that
//        both sides agree on signedness and bit width.
//
// Simulation timeout:
//   An initial block kills the simulation after a safe upper bound so a hung
//   test does not run indefinitely.
//
// Pass/fail:
//   Uses $fatal(1, ...) for any mismatch.
//   Prints "[ALU-TEST] PASS" and calls $finish on success.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;

module tb_alu;

    // -----------------------------------------------------------------------
    // DUT wires
    // -----------------------------------------------------------------------
    word_t   a_w;
    word_t   b_w;
    alu_op_e op_w;
    word_t   result_w;

    // -----------------------------------------------------------------------
    // DUT instantiation
    // -----------------------------------------------------------------------
    alu dut (
        .a_i     (a_w),
        .b_i     (b_w),
        .op_i    (op_w),
        .result_o(result_w)
    );

    // -----------------------------------------------------------------------
    // Simulation timeout guard
    // -----------------------------------------------------------------------
    initial begin : timeout_guard
        #500_000; // 500 us — far longer than any expected test run
        $fatal(1, "[ALU-TEST] TIMEOUT: simulation did not complete");
    end

    // -----------------------------------------------------------------------
    // Helper: apply inputs, settle combinational logic, check result
    // -----------------------------------------------------------------------
    task automatic check_alu(
        input word_t   a,
        input word_t   b,
        input alu_op_e op,
        input word_t   expected,
        input string   desc
    );
        a_w  = a;
        b_w  = b;
        op_w = op;
        #1; // combinational settling time
        if (result_w !== expected)
            $fatal(1, "[ALU-TEST] FAIL %-12s a=%08h b=%08h op=%0d result=%08h expected=%08h",
                   desc, a, b, int'(op), result_w, expected);
    endtask

    // -----------------------------------------------------------------------
    // Helper: compute expected result for an operation in the testbench
    // The arithmetic here is independent of the DUT, using explicit SV semantics.
    // -----------------------------------------------------------------------
    function automatic word_t compute_expected(
        input word_t   a,
        input word_t   b,
        input alu_op_e op
    );
        case (op)
            ALU_ADD:    return a + b;
            ALU_SUB:    return a - b;
            ALU_AND:    return a & b;
            ALU_OR:     return a | b;
            ALU_XOR:    return a ^ b;
            ALU_SLL:    return a << b[4:0];
            ALU_SRL:    return a >> b[4:0];
            ALU_SRA:    return word_t'($signed(a) >>> b[4:0]);
            ALU_SLT:    return {31'd0, $signed(a) < $signed(b)};
            ALU_SLTU:   return {31'd0, a < b};
            ALU_COPY_B: return b;
            default:    return '0;
        endcase
    endfunction

    // -----------------------------------------------------------------------
    // Randomized test: N random (a, b) pairs for one operation
    // -----------------------------------------------------------------------
    task automatic random_test(input alu_op_e op, input int n);
        automatic word_t ra, rb, expected;
        for (int i = 0; i < n; i++) begin
            ra       = word_t'($urandom());
            rb       = word_t'($urandom());
            expected = compute_expected(ra, rb, op);
            check_alu(ra, rb, op, expected, $sformatf("rnd%0d", i));
        end
    endtask

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    initial begin : test_body

        a_w = '0; b_w = '0; op_w = ALU_ADD;
        #1;

        // ================================================================
        // ADD
        // ================================================================
        check_alu(32'h0, 32'h0,         ALU_ADD, 32'h0,          "add 0+0");
        check_alu(32'h1, 32'h1,         ALU_ADD, 32'h2,          "add 1+1");
        check_alu(32'h5, 32'h3,         ALU_ADD, 32'h8,          "add 5+3");
        // Unsigned wraparound: 0xFFFFFFFF + 1 = 0x00000000
        check_alu(32'hFFFF_FFFF, 32'h1, ALU_ADD, 32'h0,          "add wrap");
        // Signed overflow: 0x7FFFFFFF + 1 = 0x80000000 (bit pattern, no fault)
        check_alu(32'h7FFF_FFFF, 32'h1, ALU_ADD, 32'h8000_0000,  "add signed overflow");
        // Commutativity
        check_alu(32'hABCD, 32'h1234,   ALU_ADD, 32'hBE01,       "add comm a");
        check_alu(32'h1234, 32'hABCD,   ALU_ADD, 32'hBE01,       "add comm b");
        random_test(ALU_ADD, 200);

        // ================================================================
        // SUB
        // ================================================================
        check_alu(32'h8, 32'h3,         ALU_SUB, 32'h5,          "sub 8-3");
        check_alu(32'h0, 32'h0,         ALU_SUB, 32'h0,          "sub 0-0");
        // Unsigned borrow: 0 - 1 = 0xFFFFFFFF
        check_alu(32'h0, 32'h1,         ALU_SUB, 32'hFFFF_FFFF,  "sub borrow");
        check_alu(32'h8000_0000, 32'h1, ALU_SUB, 32'h7FFF_FFFF,  "sub INT_MIN-1");
        // a - a = 0 for any a
        check_alu(32'hDEAD_BEEF, 32'hDEAD_BEEF, ALU_SUB, 32'h0, "sub self");
        random_test(ALU_SUB, 200);

        // ================================================================
        // AND
        // ================================================================
        check_alu(32'hFF,       32'h0F,       ALU_AND, 32'h0F,          "and mask");
        check_alu(32'hFFFF_FFFF,32'h0,        ALU_AND, 32'h0,           "and zero");
        check_alu(32'hFFFF_FFFF,32'hFFFF_FFFF,ALU_AND, 32'hFFFF_FFFF,  "and all1");
        check_alu(32'hAAAA_AAAA,32'h5555_5555,ALU_AND, 32'h0,           "and nooverlap");
        check_alu(32'hAAAA_AAAA,32'hFFFF_FFFF,ALU_AND, 32'hAAAA_AAAA,  "and identity");
        random_test(ALU_AND, 200);

        // ================================================================
        // OR
        // ================================================================
        check_alu(32'hF0, 32'h0F,        ALU_OR, 32'hFF,          "or disjoint");
        check_alu(32'h0,  32'h0,         ALU_OR, 32'h0,           "or zeros");
        check_alu(32'hAAAA_AAAA,32'h5555_5555,ALU_OR, 32'hFFFF_FFFF, "or complement");
        check_alu(32'hDEAD_BEEF,32'h0,   ALU_OR, 32'hDEAD_BEEF,  "or identity");
        random_test(ALU_OR, 200);

        // ================================================================
        // XOR
        // ================================================================
        check_alu(32'hFFFF_FFFF,32'hFFFF_FFFF,ALU_XOR, 32'h0,          "xor self");
        check_alu(32'hAAAA_AAAA,32'h5555_5555,ALU_XOR, 32'hFFFF_FFFF,  "xor complement");
        check_alu(32'hDEAD_BEEF,32'h0,   ALU_XOR, 32'hDEAD_BEEF,  "xor zero");
        check_alu(32'h0,        32'h0,   ALU_XOR, 32'h0,           "xor zeros");
        // Involution: a XOR b XOR b = a
        check_alu(32'h1234_5678,32'hABCD_EF01,ALU_XOR,
            32'h1234_5678 ^ 32'hABCD_EF01, "xor sample");
        random_test(ALU_XOR, 200);

        // ================================================================
        // SLL — shift left logical (shift by b_i[4:0])
        // ================================================================
        check_alu(32'h1, 32'h0,  ALU_SLL, 32'h1,         "sll by 0");
        check_alu(32'h1, 32'h1,  ALU_SLL, 32'h2,         "sll by 1");
        check_alu(32'h1, 32'd31, ALU_SLL, 32'h8000_0000, "sll to MSB");
        check_alu(32'hFF, 32'd8, ALU_SLL, 32'hFF00,      "sll byte");
        // Shift by 32: b[4:0] = 0, result = a (RISC-V shamt is always [4:0])
        check_alu(32'hABCD, 32'd32, ALU_SLL, 32'hABCD,   "sll by 32=0");
        // High bit shifts out
        check_alu(32'hFFFF_FFFF, 32'd1, ALU_SLL, 32'hFFFF_FFFE, "sll shift out MSB");
        random_test(ALU_SLL, 200);

        // ================================================================
        // SRL — shift right logical (zero-fill)
        // ================================================================
        check_alu(32'h8000_0000, 32'd31, ALU_SRL, 32'h1,           "srl MSB");
        check_alu(32'hFF00, 32'd8,       ALU_SRL, 32'hFF,           "srl byte");
        check_alu(32'h1, 32'h0,          ALU_SRL, 32'h1,            "srl by 0");
        // Logical: MSB is NOT propagated
        check_alu(32'hFFFF_FFFF, 32'd1,  ALU_SRL, 32'h7FFF_FFFF,   "srl msb zero");
        check_alu(32'hFFFF_FFFF, 32'd31, ALU_SRL, 32'h1,            "srl all");
        check_alu(32'hABCD, 32'd32,      ALU_SRL, 32'hABCD,         "srl by 32=0");
        random_test(ALU_SRL, 200);

        // ================================================================
        // SRA — shift right arithmetic (sign-extend)
        // ================================================================
        // Positive number: behaves like SRL
        check_alu(32'h7FFF_FFFF, 32'd1,  ALU_SRA, 32'h3FFF_FFFF,  "sra pos");
        // Negative number: sign bit propagates
        check_alu(32'h8000_0000, 32'd1,  ALU_SRA, 32'hC000_0000,  "sra neg 1");
        check_alu(32'h8000_0000, 32'd31, ALU_SRA, 32'hFFFF_FFFF,  "sra neg all");
        check_alu(32'hFFFF_FFFF, 32'd1,  ALU_SRA, 32'hFFFF_FFFF,  "sra -1 by 1");
        check_alu(32'hFFFF_FFFF, 32'd31, ALU_SRA, 32'hFFFF_FFFF,  "sra -1 by 31");
        // By zero: no change
        check_alu(32'h8000_0000, 32'h0,  ALU_SRA, 32'h8000_0000,  "sra neg by 0");
        check_alu(32'h0, 32'd31,          ALU_SRA, 32'h0,           "sra zero");
        random_test(ALU_SRA, 200);

        // ================================================================
        // SLT — set-less-than, signed comparison
        // ================================================================
        // Basic: 1 < 2 → 1
        check_alu(32'h1, 32'h2,          ALU_SLT, 32'h1, "slt 1<2");
        // Basic: 2 < 1 → 0
        check_alu(32'h2, 32'h1,          ALU_SLT, 32'h0, "slt 2<1");
        // Equal: 1 < 1 → 0
        check_alu(32'h1, 32'h1,          ALU_SLT, 32'h0, "slt equal");
        // Signed: -1 (0xFFFF_FFFF) < 0 → 1
        check_alu(32'hFFFF_FFFF, 32'h0,  ALU_SLT, 32'h1, "slt -1<0");
        // Signed: 0 < -1 → 0
        check_alu(32'h0, 32'hFFFF_FFFF,  ALU_SLT, 32'h0, "slt 0<-1");
        // INT_MIN < INT_MAX → 1
        check_alu(32'h8000_0000, 32'h7FFF_FFFF, ALU_SLT, 32'h1, "slt min<max");
        // INT_MAX < INT_MIN → 0
        check_alu(32'h7FFF_FFFF, 32'h8000_0000, ALU_SLT, 32'h0, "slt max<min");
        // Both negative: -2 < -1 → 1
        check_alu(32'hFFFF_FFFE, 32'hFFFF_FFFF, ALU_SLT, 32'h1, "slt -2<-1");
        random_test(ALU_SLT, 200);

        // ================================================================
        // SLTU — set-less-than, unsigned comparison
        // ================================================================
        check_alu(32'h0, 32'h1,          ALU_SLTU, 32'h1, "sltu 0<1");
        check_alu(32'h1, 32'h0,          ALU_SLTU, 32'h0, "sltu 1<0");
        check_alu(32'h0, 32'h0,          ALU_SLTU, 32'h0, "sltu equal");
        // 0xFFFF_FFFF is the largest unsigned; nothing is larger
        check_alu(32'hFFFF_FFFF, 32'h0,  ALU_SLTU, 32'h0, "sltu max<0");
        // 0 < 0xFFFF_FFFF → 1 (unsigned, unlike signed where -1 < 0)
        check_alu(32'h0, 32'hFFFF_FFFF,  ALU_SLTU, 32'h1, "sltu 0<max");
        // 1 < 0xFFFF_FFFF → 1
        check_alu(32'h1, 32'hFFFF_FFFF,  ALU_SLTU, 32'h1, "sltu 1<max");
        // Key signed/unsigned difference: 0xFFFF_FFFF vs 0x1
        // Unsigned: 0xFFFF_FFFF > 1  → SLTU gives 0
        // Signed:   0xFFFF_FFFF < 1  → SLT  gives 1 (previous group)
        check_alu(32'hFFFF_FFFF, 32'h1,  ALU_SLTU, 32'h0, "sltu max<1 unsigned");
        random_test(ALU_SLTU, 200);

        // ================================================================
        // COPY_B — result = b, a is ignored
        // ================================================================
        check_alu(32'h0,         32'hDEAD_BEEF, ALU_COPY_B, 32'hDEAD_BEEF, "copyb basic");
        check_alu(32'hFFFF_FFFF, 32'h0,         ALU_COPY_B, 32'h0,         "copyb zero");
        check_alu(32'hAAAA_AAAA, 32'h5555_5555, ALU_COPY_B, 32'h5555_5555, "copyb ignore a");
        check_alu(32'h1234_5678, 32'h8765_4321, ALU_COPY_B, 32'h8765_4321, "copyb sample");
        // a is truly ignored — vary a, hold b
        check_alu(32'h0,         32'hC0DE, ALU_COPY_B, 32'hC0DE, "copyb a=0");
        check_alu(32'h1,         32'hC0DE, ALU_COPY_B, 32'hC0DE, "copyb a=1");
        check_alu(32'hFFFF_FFFF, 32'hC0DE, ALU_COPY_B, 32'hC0DE, "copyb a=ff");
        random_test(ALU_COPY_B, 50);

        // ================================================================
        // Cross-check: SLT and SLTU produce different results for the same
        // inputs when the MSB of one operand differs.
        // ================================================================
        // a = 0xFFFF_FFFF (-1 signed, max unsigned), b = 0x1 (1 signed/unsigned)
        // SLT:  signed(-1) < signed(1) → 1
        // SLTU: unsigned(MAX) < unsigned(1) → 0
        check_alu(32'hFFFF_FFFF, 32'h1, ALU_SLT,  32'h1, "signed vs unsigned SLT");
        check_alu(32'hFFFF_FFFF, 32'h1, ALU_SLTU, 32'h0, "signed vs unsigned SLTU");

        // ================================================================
        // Shift amount: only b_i[4:0] is used
        // ================================================================
        // b = 0x20 = 32 decimal, b[4:0] = 0, so SLL by 0
        check_alu(32'h7, 32'h20, ALU_SLL, 32'h7, "sll b=0x20 uses [4:0]=0");
        check_alu(32'h7, 32'h20, ALU_SRL, 32'h7, "srl b=0x20 uses [4:0]=0");
        check_alu(32'h7, 32'h20, ALU_SRA, 32'h7, "sra b=0x20 uses [4:0]=0");
        // b = 0x21 = 33 decimal, b[4:0] = 1, so shift by 1
        check_alu(32'h2, 32'h21, ALU_SLL, 32'h4, "sll b=0x21 uses [4:0]=1");
        // b = 0xFFFF_FFFF, b[4:0] = 31
        check_alu(32'h1, 32'hFFFF_FFFF, ALU_SLL, 32'h8000_0000, "sll b=all1 uses [4:0]=31");

        // ================================================================
        // Done
        // ================================================================
        $display("[ALU-TEST] PASS: all ALU operations verified.");
        $display("[ALU-TEST]   Directed tests + 200 random vectors per operation.");
        $finish;

    end : test_body

endmodule : tb_alu

`default_nettype wire
