// verification/unit/common/tb_fluxcore_pkg.sv
//
// Self-checking testbench for fluxcore_pkg.sv.
//
// Purpose:
//   Verify that the FluxCore architectural package defines the correct
//   constants, type widths, capacity invariants, and struct field layout.
//   This test also proves that the package compiles and imports cleanly
//   in Questa.
//
// Pass/fail:
//   Uses $fatal(1, ...) for any mismatch.
//   Prints "[PKG-TEST] PASS" and calls $finish on success.
//   No manual waveform inspection is required.
//
// What is tested:
//   1. Architectural constants (XLEN, INSTR_W, REG_COUNT, etc.)
//   2. Type widths via $bits()
//   3. Thread-ID capacity: THREAD_ID_W can represent PLANNED_THREADS IDs
//   4. Register-index capacity: REG_IDX_W can represent REG_COUNT registers
//   5. exception_meta_t struct field accessibility and packed width
//   6. retirement_event_t struct field accessibility and packed width
//   7. exc_cause_e values match RISC-V standard mcause codes

`timescale 1ns / 1ps
`default_nettype none

// Import the package under test with a wildcard import so constant names
// and type names are directly visible without qualification.
import fluxcore_pkg::*;

module tb_fluxcore_pkg;

    // -----------------------------------------------------------------------
    // Helper task: compare two integer values and fatal on mismatch.
    // -----------------------------------------------------------------------
    task automatic check_eq(
        input string name,
        input int    actual,
        input int    expected
    );
        if (actual !== expected) begin
            $fatal(1, "[PKG-TEST] FAIL: %s = %0d, expected %0d",
                   name, actual, expected);
        end
    endtask

    // -----------------------------------------------------------------------
    // Helper task: verify a condition is true.
    // -----------------------------------------------------------------------
    task automatic check_true(
        input string name,
        input logic  condition
    );
        if (!condition) begin
            $fatal(1, "[PKG-TEST] FAIL: invariant violated: %s", name);
        end
    endtask

    // -----------------------------------------------------------------------
    // Compute expected struct widths from first principles.
    // If any constant changes, these will catch the inconsistency.
    // -----------------------------------------------------------------------

    // exception_meta_t: valid(1) + cause(EXC_CAUSE_W) + tval(XLEN)
    localparam int EXPECTED_EXCEPTION_META_W =
        1 + fluxcore_pkg::EXC_CAUSE_W + fluxcore_pkg::XLEN;

    // retirement_event_t: field-by-field sum
    localparam int EXPECTED_RETIREMENT_EVENT_W =
        1 +                              // valid
        fluxcore_pkg::XLEN +             // pc
        fluxcore_pkg::INSTR_W +          // instr
        1 +                              // rd_wen
        fluxcore_pkg::REG_IDX_W +        // rd_addr
        fluxcore_pkg::XLEN +             // rd_data
        1 +                              // mem_valid
        fluxcore_pkg::XLEN +             // mem_addr
        fluxcore_pkg::XLEN +             // mem_wr_data
        (fluxcore_pkg::XLEN / 8) +       // mem_wr_strb  (4 bits for XLEN=32)
        1 +                              // mem_is_write
        fluxcore_pkg::THREAD_ID_W +      // thread_id
        EXPECTED_EXCEPTION_META_W;       // exception (nested struct)

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    initial begin : test_body

        // ----------------------------------------------------------------
        // 1. Architectural constants
        // ----------------------------------------------------------------
        check_eq("XLEN",             fluxcore_pkg::XLEN,             32);
        check_eq("INSTR_W",          fluxcore_pkg::INSTR_W,          32);
        check_eq("REG_COUNT",        fluxcore_pkg::REG_COUNT,        32);
        check_eq("REG_IDX_W",        fluxcore_pkg::REG_IDX_W,         5);
        check_eq("BASELINE_THREADS", fluxcore_pkg::BASELINE_THREADS,  1);
        check_eq("PLANNED_THREADS",  fluxcore_pkg::PLANNED_THREADS,   4);
        check_eq("THREAD_ID_W",      fluxcore_pkg::THREAD_ID_W,       2);
        check_eq("EPOCH_W",          fluxcore_pkg::EPOCH_W,           4);
        check_eq("TXID_W",           fluxcore_pkg::TXID_W,            4);
        check_eq("EXC_CAUSE_W",      fluxcore_pkg::EXC_CAUSE_W,       4);

        // ----------------------------------------------------------------
        // 2. Base type widths
        // ----------------------------------------------------------------
        check_eq("$bits(word_t)",      $bits(word_t),      XLEN);
        check_eq("$bits(addr_t)",      $bits(addr_t),      XLEN);
        check_eq("$bits(instr_t)",     $bits(instr_t),     INSTR_W);
        check_eq("$bits(reg_idx_t)",   $bits(reg_idx_t),   REG_IDX_W);
        check_eq("$bits(thread_id_t)", $bits(thread_id_t), THREAD_ID_W);
        check_eq("$bits(epoch_t)",     $bits(epoch_t),     EPOCH_W);
        check_eq("$bits(txid_t)",      $bits(txid_t),      TXID_W);

        // ----------------------------------------------------------------
        // 3. Capacity invariants
        // ----------------------------------------------------------------
        // THREAD_ID_W must be wide enough to address PLANNED_THREADS contexts.
        check_true(
            "(2**THREAD_ID_W) >= PLANNED_THREADS",
            logic'((2 ** THREAD_ID_W) >= PLANNED_THREADS)
        );

        // REG_IDX_W must be wide enough to address REG_COUNT registers (0..31).
        check_true(
            "(2**REG_IDX_W) >= REG_COUNT",
            logic'((2 ** REG_IDX_W) >= REG_COUNT)
        );

        // ----------------------------------------------------------------
        // 4. exc_cause_e: enum values match RISC-V standard mcause codes
        // ----------------------------------------------------------------
        // These must never be renumbered because they map directly to mcause.
        check_eq("EXC_INSTR_ADDR_MISALIGNED",
            int'(EXC_INSTR_ADDR_MISALIGNED),  0);
        check_eq("EXC_INSTR_ACCESS_FAULT",
            int'(EXC_INSTR_ACCESS_FAULT),     1);
        check_eq("EXC_ILLEGAL_INSTRUCTION",
            int'(EXC_ILLEGAL_INSTRUCTION),    2);
        check_eq("EXC_BREAKPOINT",
            int'(EXC_BREAKPOINT),             3);
        check_eq("EXC_LOAD_ADDR_MISALIGNED",
            int'(EXC_LOAD_ADDR_MISALIGNED),   4);
        check_eq("EXC_LOAD_ACCESS_FAULT",
            int'(EXC_LOAD_ACCESS_FAULT),      5);
        check_eq("EXC_STORE_ADDR_MISALIGNED",
            int'(EXC_STORE_ADDR_MISALIGNED),  6);
        check_eq("EXC_STORE_ACCESS_FAULT",
            int'(EXC_STORE_ACCESS_FAULT),     7);
        check_eq("EXC_ECALL_M",
            int'(EXC_ECALL_M),               11);

        // ----------------------------------------------------------------
        // 5. exception_meta_t: field accessibility and packed width
        // ----------------------------------------------------------------
        begin : check_exception_meta
            automatic exception_meta_t exc;

            // Assign each field to confirm the struct layout is accessible.
            exc.valid = 1'b0;
            exc.cause = EXC_ILLEGAL_INSTRUCTION;
            exc.tval  = 32'hDEAD_C0DE;

            // Confirm the packed struct carries the values correctly.
            if (exc.valid !== 1'b0)
                $fatal(1, "[PKG-TEST] FAIL: exception_meta_t.valid readback");
            if (exc.cause !== EXC_ILLEGAL_INSTRUCTION)
                $fatal(1, "[PKG-TEST] FAIL: exception_meta_t.cause readback");
            if (exc.tval !== 32'hDEAD_C0DE)
                $fatal(1, "[PKG-TEST] FAIL: exception_meta_t.tval readback");

            // A zero-exception record: valid=0, cause=0, tval=0.
            exc = '0;
            if (exc.valid !== 1'b0)
                $fatal(1, "[PKG-TEST] FAIL: exception_meta_t zero-clear valid");

            // Total packed width.
            check_eq("$bits(exception_meta_t)",
                $bits(exception_meta_t), EXPECTED_EXCEPTION_META_W);
        end

        // ----------------------------------------------------------------
        // 6. retirement_event_t: field accessibility and packed width
        // ----------------------------------------------------------------
        begin : check_retirement_event
            automatic retirement_event_t ev;

            // Assign each field to confirm the struct layout is accessible.
            ev.valid        = 1'b1;
            ev.pc           = 32'h0000_1000;
            ev.instr        = 32'h0030_0093; // ADDI x1, x0, 3
            ev.rd_wen       = 1'b1;
            ev.rd_addr      = 5'd1;
            ev.rd_data      = 32'h0000_0003;
            ev.mem_valid    = 1'b0;
            ev.mem_addr     = '0;
            ev.mem_wr_data  = '0;
            ev.mem_wr_strb  = 4'b0000;
            ev.mem_is_write = 1'b0;
            ev.thread_id    = '0;
            ev.exception    = '0;

            // Spot-check readback of a few fields.
            if (ev.valid !== 1'b1)
                $fatal(1, "[PKG-TEST] FAIL: retirement_event_t.valid readback");
            if (ev.pc !== 32'h0000_1000)
                $fatal(1, "[PKG-TEST] FAIL: retirement_event_t.pc readback");
            if (ev.rd_data !== 32'h0000_0003)
                $fatal(1, "[PKG-TEST] FAIL: retirement_event_t.rd_data readback");
            if (ev.rd_addr !== 5'd1)
                $fatal(1, "[PKG-TEST] FAIL: retirement_event_t.rd_addr readback");
            if (ev.exception.valid !== 1'b0)
                $fatal(1, "[PKG-TEST] FAIL: retirement_event_t.exception.valid readback");

            // Assign a retirement event with an exception.
            ev.exception.valid = 1'b1;
            ev.exception.cause = EXC_ILLEGAL_INSTRUCTION;
            ev.exception.tval  = 32'hFFFF_FFFF;
            if (ev.exception.cause !== EXC_ILLEGAL_INSTRUCTION)
                $fatal(1, "[PKG-TEST] FAIL: retirement_event_t nested exception.cause");

            // Zero-clear the entire struct.
            ev = '0;
            if (ev.valid !== 1'b0)
                $fatal(1, "[PKG-TEST] FAIL: retirement_event_t zero-clear");

            // Total packed width.
            check_eq("$bits(retirement_event_t)",
                $bits(retirement_event_t), EXPECTED_RETIREMENT_EVENT_W);
        end

        // ----------------------------------------------------------------
        // 7. thread_id_t: single-thread baseline value fits in zero
        // ----------------------------------------------------------------
        begin : check_thread_id
            automatic thread_id_t tid;
            tid = '0;
            check_eq("thread_id_t zero", int'(tid), 0);

            // Maximum representable thread ID must accommodate PLANNED_THREADS-1.
            tid = thread_id_t'(PLANNED_THREADS - 1);
            check_eq("thread_id_t max",
                int'(tid), int'(PLANNED_THREADS - 1));
        end

        // ----------------------------------------------------------------
        // Done
        // ----------------------------------------------------------------
        $display("[PKG-TEST] PASS: fluxcore_pkg verified.");
        $display("[PKG-TEST]   XLEN=%0d INSTR_W=%0d REG_COUNT=%0d REG_IDX_W=%0d",
                 XLEN, INSTR_W, REG_COUNT, REG_IDX_W);
        $display("[PKG-TEST]   BASELINE_THREADS=%0d PLANNED_THREADS=%0d THREAD_ID_W=%0d",
                 BASELINE_THREADS, PLANNED_THREADS, THREAD_ID_W);
        $display("[PKG-TEST]   exception_meta_t = %0d bits",
                 $bits(exception_meta_t));
        $display("[PKG-TEST]   retirement_event_t = %0d bits",
                 $bits(retirement_event_t));
        $finish;

    end : test_body

endmodule : tb_fluxcore_pkg

`default_nettype wire
