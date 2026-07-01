// verification/unit/pipeline/tb_mem_wb_reg.sv
//
// Self-checking testbench for rtl/pipeline/mem_wb_reg.sv.
//
// Key additional checks:
//   - rd_wen, rd_addr, rd_data survive round-trip
//   - rd_from_mem and mem_byte_off survive round-trip
//   - exception.valid and exception.cause survive round-trip
//   - A flushed bubble must have rd_wen=0 (no spurious register write)
//   - A flushed bubble must have exception.valid=0 (no spurious exception)

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_mem_wb_reg;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic            rst_w   = 1'b1;
    logic            stall_w = 1'b0;
    logic            flush_w = 1'b0;
    mem_wb_payload_t d_w     = '0;
    mem_wb_payload_t q_w;

    mem_wb_reg dut (
        .clk    (clk),
        .rst    (rst_w),
        .stall_i(stall_w),
        .flush_i(flush_w),
        .d_i    (d_w),
        .q_o    (q_w)
    );

    task automatic tick_check(
        input mem_wb_payload_t expected,
        input string           desc
    );
        @(posedge clk); #1;
        if (q_w !== expected)
            $fatal(1, "[MEM-WB-REG] FAIL %-35s", desc);
    endtask

    // Normal writeback result: ALU/load data → rd
    function automatic mem_wb_payload_t make_wb_payload(
        input word_t    pc,
        input reg_idx_t rd,
        input word_t    data
    );
        automatic mem_wb_payload_t p = '0;
        p.valid     = 1'b1;
        p.pc        = pc;
        p.instr     = 32'h00208133;
        p.rd_wen    = 1'b1;
        p.rd_addr   = rd;
        p.rd_data   = data;
        p.rd_from_mem  = 1'b0;
        p.mem_byte_off = 2'b00;
        p.exception = '0;
        return p;
    endfunction

    // Exception payload (rd_wen must be 0 for all exceptions)
    function automatic mem_wb_payload_t make_exc_payload(
        input word_t       pc,
        input exc_cause_e  cause,
        input word_t       tval
    );
        automatic mem_wb_payload_t p = '0;
        p.valid              = 1'b1;
        p.pc                 = pc;
        p.rd_wen             = 1'b0;
        p.rd_addr            = 5'd0;
        p.rd_data            = 32'h0;
        p.exception.valid    = 1'b1;
        p.exception.cause    = cause;
        p.exception.tval     = tval;
        return p;
    endfunction

    localparam mem_wb_payload_t BUBBLE = '0;

    initial begin : test_body

        // 1. Reset
        rst_w = 1'b1;
        d_w   = make_wb_payload(32'h1000, 5'd15, 32'hDEAD_BEEF);
        tick_check(BUBBLE, "rst: output zeroed");
        // Verify bubble invariants
        if (q_w.rd_wen !== 1'b0)
            $fatal(1, "[MEM-WB-REG] FAIL rst bubble has rd_wen=1");
        if (q_w.exception.valid !== 1'b0)
            $fatal(1, "[MEM-WB-REG] FAIL rst bubble has exception.valid=1");

        // 2. Normal writeback capture
        rst_w = 1'b0;
        d_w   = make_wb_payload(32'h0000_1000, 5'd7, 32'hCAFE_BABE);
        tick_check(d_w, "capture: writeback payload");
        if (q_w.rd_wen !== 1'b1)
            $fatal(1, "[MEM-WB-REG] FAIL rd_wen corrupted");
        if (q_w.rd_addr !== 5'd7)
            $fatal(1, "[MEM-WB-REG] FAIL rd_addr corrupted");
        if (q_w.rd_data !== 32'hCAFE_BABE)
            $fatal(1, "[MEM-WB-REG] FAIL rd_data corrupted");

        // 3. Load metadata capture
        d_w = make_wb_payload(32'h0000_1002, 5'd8, 32'hDEAD_BEEF);
        d_w.rd_from_mem  = 1'b1;
        d_w.mem_byte_off = 2'd2;
        tick_check(d_w, "capture: load metadata");
        if (q_w.rd_from_mem !== 1'b1)
            $fatal(1, "[MEM-WB-REG] FAIL rd_from_mem corrupted");
        if (q_w.mem_byte_off !== 2'd2)
            $fatal(1, "[MEM-WB-REG] FAIL mem_byte_off corrupted");

        // 4. Different destination register
        d_w = make_wb_payload(32'h0000_1004, 5'd31, 32'hFFFF_FFFF);
        tick_check(d_w, "capture: rd=x31 with all-ones data");
        if (q_w.rd_addr !== 5'd31)
            $fatal(1, "[MEM-WB-REG] FAIL rd_addr x31 corrupted");
        if (q_w.rd_data !== 32'hFFFF_FFFF)
            $fatal(1, "[MEM-WB-REG] FAIL rd_data all-ones corrupted");

        // 5. Exception payload: ECALL
        d_w = make_exc_payload(32'h0000_1008, EXC_ECALL_M, 32'h0);
        tick_check(d_w, "capture: ECALL exception");
        if (q_w.exception.valid !== 1'b1)
            $fatal(1, "[MEM-WB-REG] FAIL ECALL exception.valid corrupted");
        if (q_w.exception.cause !== EXC_ECALL_M)
            $fatal(1, "[MEM-WB-REG] FAIL ECALL exception.cause corrupted");
        if (q_w.rd_wen !== 1'b0)
            $fatal(1, "[MEM-WB-REG] FAIL ECALL must not write register");

        // 6. Exception payload: misaligned load
        d_w = make_exc_payload(32'h0000_100C, EXC_LOAD_ADDR_MISALIGNED, 32'h0000_0003);
        tick_check(d_w, "capture: misaligned load exception");
        if (q_w.exception.cause !== EXC_LOAD_ADDR_MISALIGNED)
            $fatal(1, "[MEM-WB-REG] FAIL misaligned load cause corrupted");
        if (q_w.exception.tval !== 32'h0000_0003)
            $fatal(1, "[MEM-WB-REG] FAIL misaligned load tval corrupted");

        // 7. Stall hold
        begin : t_stall
            automatic mem_wb_payload_t held = d_w;
            stall_w = 1'b1;
            d_w     = make_wb_payload(32'h0000_2000, 5'd1, 32'h1234_5678);
            tick_check(held, "stall: hold cycle 1");
            tick_check(held, "stall: hold cycle 2");
            stall_w = 1'b0;
            tick_check(d_w, "stall release: captures d_i");
        end

        // 8. Flush: bubble must have rd_wen=0 and exception.valid=0
        d_w     = make_wb_payload(32'h0000_3000, 5'd5, 32'hABCD_EF01);
        flush_w = 1'b1;
        tick_check(BUBBLE, "flush: bubble inserted");
        if (q_w.rd_wen !== 1'b0)
            $fatal(1, "[MEM-WB-REG] FAIL flush bubble has rd_wen=1 — spurious register write");
        if (q_w.exception.valid !== 1'b0)
            $fatal(1, "[MEM-WB-REG] FAIL flush bubble has exception.valid=1 — spurious exception");

        flush_w = 1'b0;
        d_w     = make_wb_payload(32'h0000_3004, 5'd6, 32'h7654_3210);
        tick_check(d_w, "post-flush: capture resumes");

        // 9. Flush beats stall
        begin : t_flush_beats_stall
            stall_w = 1'b1;
            flush_w = 1'b1;
            d_w     = make_wb_payload(32'hDEAD_0000, 5'd10, 32'hDEAD_BEEF);
            tick_check(BUBBLE, "flush beats stall");
            if (q_w.rd_wen !== 1'b0)
                $fatal(1, "[MEM-WB-REG] FAIL flush-beats-stall bubble has rd_wen=1");
            stall_w = 1'b0;
            flush_w = 1'b0;
        end

        // 10. x0 writeback (rd_addr=0): rd_wen may be 1 here — regfile guards x0
        //    pipeline register must pass this through faithfully
        d_w = make_wb_payload(32'h0000_4000, 5'd0, 32'h0);
        d_w.rd_wen = 1'b1;   // decoder sets writes_rd by semantics; regfile blocks x0
        tick_check(d_w, "x0 writeback: passes through reg (regfile guards x0)");

        $display("[MEM-WB-REG] PASS: all behavioral contracts verified.");
        $finish;

    end : test_body

endmodule : tb_mem_wb_reg

`default_nettype wire
