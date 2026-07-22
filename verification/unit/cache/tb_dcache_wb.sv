// verification/unit/cache/tb_dcache_wb.sv
//
// Unit test for dcache.sv write policies: write-allocate + write-back.
//
// DUT A (WB+WA): NSETS=4, LINE_WORDS=2, WAYS=1, WRITE_ALLOCATE=1, WRITE_BACK=1.
//   Geometry: byte off [1:0], word off [2], index [4:3], tag [31:5].
//   W1. Store miss allocates: 2 stall cycles (clean victim), then the line
//       hits — and memory was NOT written (write-back absorbs the store).
//   W2. Store hit dirties the line, still no memory write.
//   W3. Conflicting read evicts the dirty line: 4 stalls (evict 2 + req 1 +
//       fill 1), memory now holds BOTH stored words; re-reading the original
//       line misses and returns the stored values from memory.
//   W4. Clean eviction writes nothing: fill by read, evict by conflict,
//       memory write count unchanged.
//
// DUT B (WT+WA): NSETS=4, LINE_WORDS=1, WAYS=1, WRITE_ALLOCATE=1.
//   T1. Store miss: 2 stalls (write-through cycle + FILLREQ), line then
//       hits with the stored value — and memory ALSO has it immediately.
//
// Memory writes are counted via mem_wen pulses to pin down exactly when the
// backing store is touched — the essence of the write-back contract.
//
// Pass/fail: accumulates failures, $fatal at end if any.

`timescale 1ns/1ps
`default_nettype none

module tb_dcache_wb;

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
    // DUT A: write-back + write-allocate, 2-word lines
    // =======================================================================
    logic [31:0] a_addr, a_wdata, a_rdata, a_maddr, a_mwdata, a_mrdata;
    logic        a_ren, a_wen, a_stall, a_mren, a_mwen;
    logic [3:0]  a_wstrb, a_mwstrb;
    logic [31:0] a_hits, a_misses;
    int          a_memwrites;

    logic [31:0] brama [0:1023];
    always_ff @(posedge clk) begin
        if (a_mwen) begin
            if (a_mwstrb[0]) brama[a_maddr[11:2]][7:0]   <= a_mwdata[7:0];
            if (a_mwstrb[1]) brama[a_maddr[11:2]][15:8]  <= a_mwdata[15:8];
            if (a_mwstrb[2]) brama[a_maddr[11:2]][23:16] <= a_mwdata[23:16];
            if (a_mwstrb[3]) brama[a_maddr[11:2]][31:24] <= a_mwdata[31:24];
        end
        a_mrdata <= brama[a_maddr[11:2]];
    end

    // Memory-write pulse counter (separate block: single procedural driver)
    always_ff @(posedge clk) begin
        if (rst)         a_memwrites <= 0;
        else if (a_mwen) a_memwrites <= a_memwrites + 1;
    end

    dcache #(.NSETS(4), .LINE_WORDS(2), .WAYS(1),
             .WRITE_ALLOCATE(1'b1), .WRITE_BACK(1'b1)) dut_a (
        .clk(clk), .rst(rst),
        .cpu_addr_i(a_addr), .cpu_ren_i(a_ren), .cpu_wen_i(a_wen),
        .cpu_wstrb_i(a_wstrb), .cpu_wdata_i(a_wdata),
        .cpu_rdata_o(a_rdata), .dmem_stall_o(a_stall),
        .mem_addr_o(a_maddr), .mem_ren_o(a_mren), .mem_wen_o(a_mwen),
        .mem_wstrb_o(a_mwstrb), .mem_wdata_o(a_mwdata), .mem_rdata_i(a_mrdata),
        .hit_count_o(a_hits), .miss_count_o(a_misses)
    );

    // Pipeline-faithful read: hold while stalled, complete, sample in WB cycle.
    task automatic rda(input logic [31:0] addr, output logic [31:0] data,
                       output int stalls);
        a_addr = addr; a_ren = 1;
        #1;
        stalls = 0;
        while (a_stall === 1'b1) begin @(posedge clk); #1; stalls++; end
        @(posedge clk); #1;
        a_ren = 0; a_addr = '0;
        data = a_rdata;
        @(posedge clk); #1;
    endtask

    // Pipeline-faithful store: held in MEM while stalled (allocating misses).
    task automatic wra(input logic [31:0] addr, input logic [31:0] wdata,
                       output int stalls);
        a_addr = addr; a_wen = 1; a_wstrb = 4'hF; a_wdata = wdata;
        #1;
        stalls = 0;
        while (a_stall === 1'b1) begin @(posedge clk); #1; stalls++; end
        @(posedge clk); #1;
        a_wen = 0; a_wstrb = '0; a_addr = '0; a_wdata = '0;
        @(posedge clk); #1;
    endtask

    // =======================================================================
    // DUT B: write-through + write-allocate, 1-word lines
    // =======================================================================
    logic [31:0] b_addr, b_wdata, b_rdata, b_maddr, b_mwdata, b_mrdata;
    logic        b_ren, b_wen, b_stall, b_mren, b_mwen;
    logic [3:0]  b_wstrb, b_mwstrb;
    logic [31:0] b_hits, b_misses;

    logic [31:0] bramb [0:1023];
    always_ff @(posedge clk) begin
        if (b_mwen) begin
            if (b_mwstrb[0]) bramb[b_maddr[11:2]][7:0]   <= b_mwdata[7:0];
            if (b_mwstrb[1]) bramb[b_maddr[11:2]][15:8]  <= b_mwdata[15:8];
            if (b_mwstrb[2]) bramb[b_maddr[11:2]][23:16] <= b_mwdata[23:16];
            if (b_mwstrb[3]) bramb[b_maddr[11:2]][31:24] <= b_mwdata[31:24];
        end
        b_mrdata <= bramb[b_maddr[11:2]];
    end

    dcache #(.NSETS(4), .LINE_WORDS(1), .WAYS(1),
             .WRITE_ALLOCATE(1'b1), .WRITE_BACK(1'b0)) dut_b (
        .clk(clk), .rst(rst),
        .cpu_addr_i(b_addr), .cpu_ren_i(b_ren), .cpu_wen_i(b_wen),
        .cpu_wstrb_i(b_wstrb), .cpu_wdata_i(b_wdata),
        .cpu_rdata_o(b_rdata), .dmem_stall_o(b_stall),
        .mem_addr_o(b_maddr), .mem_ren_o(b_mren), .mem_wen_o(b_mwen),
        .mem_wstrb_o(b_mwstrb), .mem_wdata_o(b_mwdata), .mem_rdata_i(b_mrdata),
        .hit_count_o(b_hits), .miss_count_o(b_misses)
    );

    task automatic rdb(input logic [31:0] addr, output logic [31:0] data,
                       output int stalls);
        b_addr = addr; b_ren = 1;
        #1;
        stalls = 0;
        while (b_stall === 1'b1) begin @(posedge clk); #1; stalls++; end
        @(posedge clk); #1;
        b_ren = 0; b_addr = '0;
        data = b_rdata;
        @(posedge clk); #1;
    endtask

    task automatic wrb(input logic [31:0] addr, input logic [31:0] wdata,
                       output int stalls);
        b_addr = addr; b_wen = 1; b_wstrb = 4'hF; b_wdata = wdata;
        #1;
        stalls = 0;
        while (b_stall === 1'b1) begin @(posedge clk); #1; stalls++; end
        @(posedge clk); #1;
        b_wen = 0; b_wstrb = '0; b_addr = '0; b_wdata = '0;
        @(posedge clk); #1;
    endtask

    // =======================================================================
    // Test body
    // =======================================================================
    logic [31:0] rd;
    int          st, wr_before;

    // DUT A addresses, all index 0 (bits [4:3] = 00), 8-byte lines:
    localparam logic [31:0] LA  = 32'h0000_0000;  // line A word 0
    localparam logic [31:0] LA1 = 32'h0000_0004;  // line A word 1
    localparam logic [31:0] LB  = 32'h0000_0020;  // conflicting line B word 0
    localparam logic [31:0] LC  = 32'h0000_0040;  // conflicting line C word 0

    initial begin
        for (int i = 0; i < 1024; i++) begin
            brama[i] = 32'hAB00_0000 | i;
            bramb[i] = 32'hCD00_0000 | i;
        end
        a_addr='0; a_ren=0; a_wen=0; a_wstrb='0; a_wdata='0;
        b_addr='0; b_ren=0; b_wen=0; b_wstrb='0; b_wdata='0;
        rst = 1;
        repeat (3) @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // ===================================================================
        // W1: store miss allocates; memory NOT written.
        // ===================================================================
        $display("\n--- W1: write-back store-miss allocation ---");
        wr_before = a_memwrites;
        wra(LA, 32'h1111_1111, st);
        check("W1.store_stalls_for_fill", st == 2);          // clean victim, W=2
        check("W1.no_mem_write", a_memwrites == wr_before);  // absorbed
        check("W1.bram_untouched", brama[LA >> 2] === (32'hAB00_0000 | (LA >> 2)));
        rda(LA, rd, st);
        check("W1.line_hits", st == 0);
        check("W1.stored_data", rd === 32'h1111_1111);
        rda(LA1, rd, st);
        check("W1.neighbor_filled", st == 0);
        check("W1.neighbor_data", rd === (32'hAB00_0000 | (LA1 >> 2)));

        // ===================================================================
        // W2: store hit dirties without memory write.
        // ===================================================================
        $display("\n--- W2: write-back store-hit absorption ---");
        wr_before = a_memwrites;
        wra(LA1, 32'h2222_2222, st);
        check("W2.hit_no_stall", st == 0);
        check("W2.no_mem_write", a_memwrites == wr_before);
        rda(LA1, rd, st);
        check("W2.hit_new_data", rd === 32'h2222_2222);

        // ===================================================================
        // W3: dirty eviction on conflict.
        // ===================================================================
        $display("\n--- W3: dirty eviction writes the line back ---");
        wr_before = a_memwrites;
        rda(LB, rd, st);
        check("W3.evict_stalls", st == 4);   // evict 2 + fillreq 1 + fill 1
        check("W3.two_writeback_beats", a_memwrites == wr_before + 2);
        check("W3.mem_word0", brama[LA  >> 2] === 32'h1111_1111);
        check("W3.mem_word1", brama[LA1 >> 2] === 32'h2222_2222);
        check("W3.read_data_ok", rd === (32'hAB00_0000 | (LB >> 2)));
        // Original line comes back from memory with the stored values.
        rda(LA, rd, st);
        check("W3.orig_missed", st == 4 || st == 2);  // victim LB is clean → 2
        check("W3.orig_word0_roundtrip", rd === 32'h1111_1111);

        // ===================================================================
        // W4: clean eviction writes nothing.
        // ===================================================================
        $display("\n--- W4: clean eviction is silent ---");
        wr_before = a_memwrites;
        rda(LC, rd, st);                     // evicts LA (clean: only read since fill)
        check("W4.clean_evict_stalls", st == 2);
        check("W4.no_writeback", a_memwrites == wr_before);

        // ===================================================================
        // T1: write-through + allocate.
        // ===================================================================
        $display("\n--- T1: write-through store-miss allocation ---");
        wrb(32'h0000_0008, 32'h3333_3333, st);
        check("T1.store_stalls", st == 2);   // WT write cycle + FILLREQ
        check("T1.mem_has_it_now", bramb[2] === 32'h3333_3333);
        rdb(32'h0000_0008, rd, st);
        check("T1.line_hits", st == 0);
        check("T1.data", rd === 32'h3333_3333);

        repeat (2) @(posedge clk);
        $display("\n===== tb_dcache_wb: %0d passed, %0d failed =====",
                 pass_count, fail_count);
        if (fail_count != 0) $fatal(1, "tb_dcache_wb: FAILURES detected");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "tb_dcache_wb: timeout");
    end

endmodule : tb_dcache_wb

`default_nettype wire
