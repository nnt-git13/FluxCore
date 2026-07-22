// verification/unit/cache/tb_dcache_assoc.sv
//
// Unit test for rtl/cache/dcache.sv with WAYS=2 and WAYS=4 (LRU replacement).
//
// Two DUT instances share one test module; each has its own BRAM model and
// driver signals. LINE_WORDS=1 throughout so miss cost is 1 stall cycle and
// the checks stay about ASSOCIATIVITY, not line fill.
//
// 2-way plan (NSETS=4; addresses with identical index bits [3:2]):
//   A1. Two conflicting tags coexist — the anti-thrash property a
//       direct-mapped cache cannot have: fill A, fill B, then BOTH hit.
//   A2. Third tag evicts the LRU (A, the older), not the MRU (B):
//       fill C → B still hits, A misses.
//   A3. A hit refreshes LRU order: fill A (evicting B, which became LRU
//       after its A2 hit... sequence recomputed below), verify by touch.
//       Concretely: after A2 the set holds {C (MRU), B}. Touch B (hit),
//       then fill D → victim must be C: B still hits, C misses.
//   A4. A STORE hit also refreshes LRU: set holds {D, B}; store to B, fill E
//       → victim is D: B still hits (with stored data), D misses.
//   A5. Counters: exact totals for the sequence.
//
// 4-way plan (NSETS=2):
//   B1. Four conflicting tags all coexist (4 fills, then 4 hits).
//   B2. Fifth tag evicts the least-recently-used (the first-filled),
//       and the other three still hit.
//
// Pass/fail: accumulates failures, $fatal at end if any.

`timescale 1ns/1ps
`default_nettype none

module tb_dcache_assoc;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst;

    int pass_count = 0;
    int fail_count = 0;

    task check(input string name, input logic cond);
        if (!cond) begin
            $display("FAIL  %0t  %s", $time, name);
            fail_count++;
        end else begin
            $display("PASS  %0t  %s", $time, name);
            pass_count++;
        end
    endtask

    // =======================================================================
    // 2-way DUT (NSETS=4, LINE_WORDS=1): index bits [3:2], tag [31:4].
    // =======================================================================
    logic [31:0] a2_addr, a2_wdata, a2_rdata, a2_maddr, a2_mwdata, a2_mrdata;
    logic        a2_ren, a2_wen, a2_stall, a2_mren, a2_mwen;
    logic [3:0]  a2_wstrb, a2_mwstrb;
    logic [31:0] a2_hits, a2_misses;

    logic [31:0] bram2 [0:1023];
    always_ff @(posedge clk) begin
        if (a2_mwen) begin
            if (a2_mwstrb[0]) bram2[a2_maddr[11:2]][7:0]   <= a2_mwdata[7:0];
            if (a2_mwstrb[1]) bram2[a2_maddr[11:2]][15:8]  <= a2_mwdata[15:8];
            if (a2_mwstrb[2]) bram2[a2_maddr[11:2]][23:16] <= a2_mwdata[23:16];
            if (a2_mwstrb[3]) bram2[a2_maddr[11:2]][31:24] <= a2_mwdata[31:24];
        end
        a2_mrdata <= bram2[a2_maddr[11:2]];
    end

    dcache #(.NSETS(4), .LINE_WORDS(1), .WAYS(2)) dut2 (
        .clk(clk), .rst(rst),
        .cpu_addr_i(a2_addr), .cpu_ren_i(a2_ren), .cpu_wen_i(a2_wen),
        .cpu_wstrb_i(a2_wstrb), .cpu_wdata_i(a2_wdata),
        .cpu_rdata_o(a2_rdata), .dmem_stall_o(a2_stall),
        .mem_addr_o(a2_maddr), .mem_ren_o(a2_mren), .mem_wen_o(a2_mwen),
        .mem_wstrb_o(a2_mwstrb), .mem_wdata_o(a2_mwdata), .mem_rdata_i(a2_mrdata),
        .hit_count_o(a2_hits), .miss_count_o(a2_misses)
    );

    // Pipeline-faithful read: hold while stalled, 1 cycle to complete, sample.
    task automatic rd2(input logic [31:0] addr, output logic [31:0] data,
                       output int stalls);
        a2_addr = addr; a2_ren = 1;
        #1;
        stalls = 0;
        while (a2_stall === 1'b1) begin @(posedge clk); #1; stalls++; end
        @(posedge clk); #1;
        a2_ren = 0; a2_addr = '0;
        data = a2_rdata;
        @(posedge clk); #1;   // idle gap
    endtask

    task automatic wr2(input logic [31:0] addr, input logic [31:0] wdata);
        a2_addr = addr; a2_wen = 1; a2_wstrb = 4'hF; a2_wdata = wdata;
        #1;
        @(posedge clk); #1;
        a2_wen = 0; a2_wstrb = '0; a2_addr = '0; a2_wdata = '0;
        @(posedge clk); #1;   // idle gap
    endtask

    // =======================================================================
    // 4-way DUT (NSETS=2, LINE_WORDS=1): index bit [2], tag [31:3].
    // =======================================================================
    logic [31:0] a4_addr, a4_wdata, a4_rdata, a4_maddr, a4_mwdata, a4_mrdata;
    logic        a4_ren, a4_wen, a4_stall, a4_mren, a4_mwen;
    logic [3:0]  a4_wstrb, a4_mwstrb;
    logic [31:0] a4_hits, a4_misses;

    logic [31:0] bram4 [0:1023];
    always_ff @(posedge clk) begin
        if (a4_mwen) begin
            if (a4_mwstrb[0]) bram4[a4_maddr[11:2]][7:0]   <= a4_mwdata[7:0];
            if (a4_mwstrb[1]) bram4[a4_maddr[11:2]][15:8]  <= a4_mwdata[15:8];
            if (a4_mwstrb[2]) bram4[a4_maddr[11:2]][23:16] <= a4_mwdata[23:16];
            if (a4_mwstrb[3]) bram4[a4_maddr[11:2]][31:24] <= a4_mwdata[31:24];
        end
        a4_mrdata <= bram4[a4_maddr[11:2]];
    end

    dcache #(.NSETS(2), .LINE_WORDS(1), .WAYS(4)) dut4 (
        .clk(clk), .rst(rst),
        .cpu_addr_i(a4_addr), .cpu_ren_i(a4_ren), .cpu_wen_i(a4_wen),
        .cpu_wstrb_i(a4_wstrb), .cpu_wdata_i(a4_wdata),
        .cpu_rdata_o(a4_rdata), .dmem_stall_o(a4_stall),
        .mem_addr_o(a4_maddr), .mem_ren_o(a4_mren), .mem_wen_o(a4_mwen),
        .mem_wstrb_o(a4_mwstrb), .mem_wdata_o(a4_mwdata), .mem_rdata_i(a4_mrdata),
        .hit_count_o(a4_hits), .miss_count_o(a4_misses)
    );

    task automatic rd4(input logic [31:0] addr, output logic [31:0] data,
                       output int stalls);
        a4_addr = addr; a4_ren = 1;
        #1;
        stalls = 0;
        while (a4_stall === 1'b1) begin @(posedge clk); #1; stalls++; end
        @(posedge clk); #1;
        a4_ren = 0; a4_addr = '0;
        data = a4_rdata;
        @(posedge clk); #1;
    endtask

    // =======================================================================
    // Test body
    // =======================================================================
    logic [31:0] rd;
    int          st;

    // Conflicting addresses for the 2-way DUT, all index 1 (bits [3:2]=01):
    localparam logic [31:0] A = 32'h0000_0004;  // tag 0
    localparam logic [31:0] B = 32'h0000_0014;  // tag 1
    localparam logic [31:0] C = 32'h0000_0024;  // tag 2
    localparam logic [31:0] D = 32'h0000_0034;  // tag 3
    localparam logic [31:0] E = 32'h0000_0044;  // tag 4

    initial begin
        for (int i = 0; i < 1024; i++) begin
            bram2[i] = 32'hB200_0000 | i;
            bram4[i] = 32'hB400_0000 | i;
        end
        a2_addr='0; a2_ren=0; a2_wen=0; a2_wstrb='0; a2_wdata='0;
        a4_addr='0; a4_ren=0; a4_wen=0; a4_wstrb='0; a4_wdata='0;
        rst = 1;
        repeat (3) @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // ===================================================================
        // A1: two conflicting tags coexist.
        // ===================================================================
        $display("\n--- A1: 2-way holds two conflicting tags ---");
        rd2(A, rd, st); check("A1.A_miss", st == 1);
        rd2(B, rd, st); check("A1.B_miss", st == 1);
        rd2(A, rd, st); check("A1.A_hits", st == 0);
        check("A1.A_data", rd === (32'hB200_0000 | (A >> 2)));
        rd2(B, rd, st); check("A1.B_hits", st == 0);
        check("A1.B_data", rd === (32'hB200_0000 | (B >> 2)));
        // LRU state now: B = MRU, A = LRU.

        // ===================================================================
        // A2: third tag evicts the LRU (A), not the MRU (B).
        // ===================================================================
        $display("\n--- A2: LRU victim selection ---");
        rd2(C, rd, st); check("A2.C_miss", st == 1);
        rd2(B, rd, st); check("A2.B_survives", st == 0);
        rd2(A, rd, st); check("A2.A_evicted", st == 1);
        // Set now holds {A (MRU), B (LRU)} — C was evicted by A's refill?
        // No: A's refill victimized the LRU at that moment, which was C?
        // Order: after C fill: {C MRU, B LRU}. B hit → {B MRU, C LRU}.
        // A miss → victim C → set {A MRU, B}.

        // ===================================================================
        // A3: hit refreshes LRU order.
        // ===================================================================
        $display("\n--- A3: hit refreshes recency ---");
        // Set: {A (MRU), B (LRU)}. Touch B, then fill D → victim must be A.
        rd2(B, rd, st); check("A3.B_hit", st == 0);
        rd2(D, rd, st); check("A3.D_miss", st == 1);
        rd2(B, rd, st); check("A3.B_still_resident", st == 0);
        rd2(A, rd, st); check("A3.A_was_victim", st == 1);
        // Order now: after D fill: {D, B} → B hit → {B MRU, D} → A miss →
        // victim D → set {A (MRU), B}.

        // ===================================================================
        // A4: STORE hit refreshes LRU too.
        // ===================================================================
        $display("\n--- A4: store hit refreshes recency ---");
        // Set: {A (MRU), B (LRU)}. Store to B (hit) → B becomes MRU.
        wr2(B, 32'hFEED_C0DE);
        rd2(E, rd, st); check("A4.E_miss", st == 1);       // victim must be A
        rd2(B, rd, st); check("A4.B_survives_store_touch", st == 0);
        check("A4.B_stored_data", rd === 32'hFEED_C0DE);
        rd2(A, rd, st); check("A4.A_was_victim", st == 1);

        // ===================================================================
        // A5: exact counters for the 2-way sequence.
        //     Misses: A,B,C,A(A2),D,A(A3),E,A(A4) = 8
        //     Hits:   A,B(A1) B(A2) B,B(A3) B(A4) = 6
        // ===================================================================
        $display("\n--- A5: counters ---");
        check("A5.misses", a2_misses === 32'd8);
        check("A5.hits",   a2_hits   === 32'd6);

        // ===================================================================
        // B1: 4-way holds four conflicting tags (index 0: bit[2]=0).
        // ===================================================================
        $display("\n--- B1: 4-way holds four conflicting tags ---");
        rd4(32'h0000_0000, rd, st); check("B1.t0_miss", st == 1);
        rd4(32'h0000_0008, rd, st); check("B1.t1_miss", st == 1);
        rd4(32'h0000_0010, rd, st); check("B1.t2_miss", st == 1);
        rd4(32'h0000_0018, rd, st); check("B1.t3_miss", st == 1);
        rd4(32'h0000_0000, rd, st); check("B1.t0_hit", st == 0);
        rd4(32'h0000_0008, rd, st); check("B1.t1_hit", st == 0);
        rd4(32'h0000_0010, rd, st); check("B1.t2_hit", st == 0);
        rd4(32'h0000_0018, rd, st); check("B1.t3_hit", st == 0);

        // ===================================================================
        // B2: fifth tag evicts the LRU = t0 (t0 was refreshed... recompute:
        // after the four hits, recency (MRU→LRU) is t3,t2,t1,t0. So the
        // victim is t0; t1..t3 survive.
        // ===================================================================
        $display("\n--- B2: 4-way LRU victim ---");
        rd4(32'h0000_0020, rd, st); check("B2.t4_miss", st == 1);
        rd4(32'h0000_0008, rd, st); check("B2.t1_survives", st == 0);
        rd4(32'h0000_0010, rd, st); check("B2.t2_survives", st == 0);
        rd4(32'h0000_0018, rd, st); check("B2.t3_survives", st == 0);
        rd4(32'h0000_0000, rd, st); check("B2.t0_was_victim", st == 1);

        repeat (2) @(posedge clk);
        $display("\n===== tb_dcache_assoc: %0d passed, %0d failed =====",
                 pass_count, fail_count);
        if (fail_count != 0) $fatal(1, "tb_dcache_assoc: FAILURES detected");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "tb_dcache_assoc: timeout");
    end

endmodule : tb_dcache_assoc

`default_nettype wire
