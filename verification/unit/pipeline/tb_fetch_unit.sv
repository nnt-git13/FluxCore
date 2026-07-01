// verification/unit/pipeline/tb_fetch_unit.sv
//
// Self-checking testbench for rtl/frontend/fetch_unit.sv.
//
// Instruction memory model:
//   assign instr_w = fetch_addr_w   (instruction == address, unique per PC)
//   This makes it trivial to verify that if_id_o carries the correct
//   instruction for each fetch address.
//
// Timing note:
//   tick_check() calls @(posedge clk) #1 and then reads fetch_addr_o.
//   At that point pc_q has already been updated via the nonblocking assignment.
//   So after rst is released, the FIRST tick shows PC = RESET_VEC + 4, not
//   RESET_VEC — the +4 advance happens on the same edge as rst going low.
//   The instruction at RESET_VEC is correctly captured by the if_id_reg on
//   that same edge (from the combinatorial if_id_o of the prior cycle), but
//   that is a full-pipeline concern; this testbench checks only the fetch_unit.
//
// Behavioral contract under test:
//   1. rst=1  → PC = RESET_VEC on every tick
//   2. Normal advance → PC += 4 each cycle
//   3. stall_i=1 → PC holds
//   4. redirect_valid_i=1 → PC = redirect_target_i
//   5. redirect overrides stall
//   6. fetch_addr_o == current pc_q (combinatorial)
//   7. if_id_o.valid == 1 always
//   8. if_id_o.pc == fetch_addr_o
//   9. if_id_o.instr == instr_i

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_fetch_unit;

    localparam word_t RESET_VEC = 32'h0000_0000;

    // -----------------------------------------------------------------------
    // Clock
    // -----------------------------------------------------------------------
    logic clk = 1'b0;
    always #5 clk = ~clk;

    // -----------------------------------------------------------------------
    // DUT ports
    // -----------------------------------------------------------------------
    logic           rst_w         = 1'b1;
    logic           stall_w       = 1'b0;
    logic           redir_w       = 1'b0;
    word_t          redir_tgt_w   = '0;
    word_t          fetch_addr_w;
    word_t          fetch_addr_next_w;
    instr_t         instr_w;
    if_id_payload_t if_id_w;

    // -----------------------------------------------------------------------
    // Instruction memory model: instruction == fetch address
    // -----------------------------------------------------------------------
    assign instr_w = fetch_addr_w;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    fetch_unit #(.RESET_VECTOR(RESET_VEC)) dut (
        .clk              (clk),
        .rst              (rst_w),
        .stall_i          (stall_w),
        .redirect_valid_i (redir_w),
        .redirect_target_i(redir_tgt_w),
        .fetch_addr_o     (fetch_addr_w),
        .fetch_addr_next_o(fetch_addr_next_w),
        .instr_i          (instr_w),
        .if_id_o          (if_id_w)
    );

    // -----------------------------------------------------------------------
    // Helper: advance one clock, settle, then check
    //
    // expected_pc: the pc_q value expected AFTER this clock edge.
    // -----------------------------------------------------------------------
    task automatic tick_check(
        input word_t expected_pc,
        input string desc
    );
        @(posedge clk); #1;
        if (fetch_addr_w !== expected_pc)
            $fatal(1, "[FETCH-UNIT] FAIL %-40s fetch_addr=%08h expected=%08h",
                   desc, fetch_addr_w, expected_pc);
        if (if_id_w.valid !== 1'b1)
            $fatal(1, "[FETCH-UNIT] FAIL %-40s if_id.valid=0 (must always be 1)", desc);
        if (if_id_w.pc !== fetch_addr_w)
            $fatal(1, "[FETCH-UNIT] FAIL %-40s if_id.pc=%08h != fetch_addr=%08h",
                   desc, if_id_w.pc, fetch_addr_w);
        if (if_id_w.instr !== instr_w)
            $fatal(1, "[FETCH-UNIT] FAIL %-40s if_id.instr=%08h != instr_w=%08h",
                   desc, if_id_w.instr, instr_w);
    endtask

    // -----------------------------------------------------------------------
    // Main test
    // -----------------------------------------------------------------------
    initial begin : test_body

        // ================================================================
        // 1. Synchronous reset: PC stays at RESET_VEC while rst=1
        // ================================================================
        rst_w       = 1'b1;
        stall_w     = 1'b0;
        redir_w     = 1'b0;
        redir_tgt_w = 32'hDEAD_BEEF;  // must be ignored during rst

        tick_check(RESET_VEC, "rst cycle 1: PC = RESET_VEC");
        tick_check(RESET_VEC, "rst cycle 2: PC = RESET_VEC");
        tick_check(RESET_VEC, "rst cycle 3: PC = RESET_VEC");

        // ================================================================
        // 2. Normal sequential fetch: PC += 4 each cycle after rst release.
        //
        // On the first non-rst edge the PC advances from RESET_VEC to
        // RESET_VEC+4. The instruction at RESET_VEC was presented to
        // instruction memory during the last rst cycle; the downstream
        // if_id_reg latches that payload on this same edge.
        // ================================================================
        rst_w = 1'b0;

        tick_check(RESET_VEC + 32'h4,  "seq advance: PC = RESET_VEC+4");
        tick_check(RESET_VEC + 32'h8,  "seq advance: PC = RESET_VEC+8");
        tick_check(RESET_VEC + 32'hC,  "seq advance: PC = RESET_VEC+C");
        tick_check(RESET_VEC + 32'h10, "seq advance: PC = RESET_VEC+10");

        // ================================================================
        // 3. Stall: PC holds across multiple cycles; releases cleanly.
        //    PC is at RESET_VEC+0x10 entering this section.
        // ================================================================
        stall_w = 1'b1;

        tick_check(RESET_VEC + 32'h10, "stall hold cycle 1");
        tick_check(RESET_VEC + 32'h10, "stall hold cycle 2");
        tick_check(RESET_VEC + 32'h10, "stall hold cycle 3");

        stall_w = 1'b0;
        tick_check(RESET_VEC + 32'h14, "stall release: advances by 4");
        tick_check(RESET_VEC + 32'h18, "stall release+1: advances by 4");

        // ================================================================
        // 4. Redirect: PC jumps to target; normal advance resumes after.
        // ================================================================
        redir_w     = 1'b1;
        redir_tgt_w = 32'h0000_4000;
        tick_check(32'h0000_4000, "redirect: PC = 0x4000");

        redir_w = 1'b0;
        tick_check(32'h0000_4004, "post-redirect advance +4");
        tick_check(32'h0000_4008, "post-redirect advance +8");

        // ================================================================
        // 5. Redirect overrides stall: both asserted → PC jumps, not holds.
        // ================================================================
        stall_w     = 1'b1;
        redir_w     = 1'b1;
        redir_tgt_w = 32'h0000_8000;
        tick_check(32'h0000_8000, "redirect beats stall: PC = 0x8000");

        stall_w = 1'b0;
        redir_w = 1'b0;
        tick_check(32'h0000_8004, "post-redir-beats-stall advance");

        // ================================================================
        // 6. Back-to-back redirects: each takes effect immediately.
        // ================================================================
        redir_w = 1'b1;

        redir_tgt_w = 32'h0000_A000;
        tick_check(32'h0000_A000, "back-to-back redirect 1: 0xA000");

        redir_tgt_w = 32'h0000_B000;
        tick_check(32'h0000_B000, "back-to-back redirect 2: 0xB000");

        redir_tgt_w = 32'h0000_C000;
        tick_check(32'h0000_C000, "back-to-back redirect 3: 0xC000");

        redir_w = 1'b0;
        tick_check(32'h0000_C004, "post-back-to-back advance");

        // ================================================================
        // 7. Self-redirect: redirect to the current PC.
        //    PC is at 0xC004; advance once to 0xC008, then redirect there.
        // ================================================================
        begin : t_self_redirect
            automatic word_t cur_pc;

            // Unchecked advance to establish cur_pc
            @(posedge clk); #1;
            cur_pc = fetch_addr_w;   // 0xC008

            redir_w     = 1'b1;
            redir_tgt_w = cur_pc;    // redirect to the same address
            tick_check(cur_pc,       "self-redirect: PC stays same");

            redir_w = 1'b0;
            tick_check(cur_pc + 32'h4, "post-self-redirect: advance");
        end

        // ================================================================
        // 8. Reset mid-flight: rst overrides redirect AND stall.
        // ================================================================
        rst_w       = 1'b1;
        redir_w     = 1'b1;
        redir_tgt_w = 32'hDEAD_0000;
        stall_w     = 1'b1;
        tick_check(RESET_VEC, "rst mid-flight: overrides redirect+stall");

        rst_w = 1'b0; redir_w = 1'b0; stall_w = 1'b0;
        tick_check(RESET_VEC + 32'h4, "post-rst advance");

        // ================================================================
        // 9. fetch_addr_next_o: combinatorial next-PC for BRAM prefetch.
        //
        // After #1 following a posedge, fetch_addr_w = new pc_q.
        // fetch_addr_next_w reflects the combinatorial next_pc_s, which
        // depends on the CURRENT state of stall_w and redir_w.
        //
        // Reset to a known PC first.
        // ================================================================
        begin : t_next_pc
            rst_w = 1'b1; stall_w = 1'b0; redir_w = 1'b0;
            @(posedge clk); #1;
            // During rst: next_pc_s = RESET_VEC regardless of stall/redir.
            if (fetch_addr_next_w !== RESET_VEC)
                $fatal(1, "[FETCH-UNIT] FAIL next_pc during rst: 0x%08h exp 0x%08h",
                       fetch_addr_next_w, RESET_VEC);

            rst_w = 1'b0;
            @(posedge clk); #1;
            // pc_q = RESET_VEC (first post-reset advance already happened);
            // No stall, no redirect → next_pc = pc_q + 4 = fetch_addr_w + 4.
            if (fetch_addr_next_w !== (fetch_addr_w + 32'd4))
                $fatal(1, "[FETCH-UNIT] FAIL next_pc normal: 0x%08h exp 0x%08h (addr+4)",
                       fetch_addr_next_w, fetch_addr_w + 32'd4);

            // Apply stall: next_pc = pc_q (hold).
            stall_w = 1'b1;
            @(posedge clk); #1;
            if (fetch_addr_next_w !== fetch_addr_w)
                $fatal(1, "[FETCH-UNIT] FAIL next_pc stall: 0x%08h exp 0x%08h (held)",
                       fetch_addr_next_w, fetch_addr_w);
            stall_w = 1'b0;

            // Apply redirect: next_pc = redirect_target regardless of pc_q.
            redir_w     = 1'b1;
            redir_tgt_w = 32'h0001_2000;
            @(posedge clk); #1;
            if (fetch_addr_next_w !== 32'h0001_2000)
                $fatal(1, "[FETCH-UNIT] FAIL next_pc redirect: 0x%08h exp 0x00012000",
                       fetch_addr_next_w);
            redir_w = 1'b0;

            // Redirect beats stall.
            stall_w     = 1'b1;
            redir_w     = 1'b1;
            redir_tgt_w = 32'h0002_4000;
            @(posedge clk); #1;
            if (fetch_addr_next_w !== 32'h0002_4000)
                $fatal(1, "[FETCH-UNIT] FAIL next_pc redirect-beats-stall: 0x%08h exp 0x00024000",
                       fetch_addr_next_w);
            stall_w = 1'b0; redir_w = 1'b0;
        end : t_next_pc

        // ================================================================
        // Done
        // ================================================================
        $display("[FETCH-UNIT] PASS: all fetch behaviors verified.");
        $display("[FETCH-UNIT]   rst, sequential, stall, redirect, redirect>stall,");
        $display("[FETCH-UNIT]   back-to-back redirect, self-redirect, rst-override,");
        $display("[FETCH-UNIT]   fetch_addr_next_o (BRAM prefetch address).");
        $finish;

    end : test_body

endmodule : tb_fetch_unit

`default_nettype wire
