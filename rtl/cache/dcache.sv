// rtl/cache/dcache.sv
//
// Set-associative write-through data cache — BRAM-compatible stall interface.
//
// This module is the integration shim between fluxcore_top's dmem_* ports and
// a backing bram_dmem. It presents the same 1-cycle latency as a bare BRAM on
// hits, and adds LINE_WORDS stall cycles on read misses (one BRAM round-trip
// per word of the line).
//
// Timing (matches existing BRAM pipeline contract; W = LINE_WORDS):
//
//   Hit path (no stall added):
//     Cycle N (MEM): cpu_ren_i=1, hit_s=1 — cache data registered at posedge N.
//     Cycle N+1 (WB): cpu_rdata_o = cache data ← wb_stage reads this live. ✓
//
//   Miss path (W stall cycles):
//     Cycle N (MEM): cpu_ren_i=1, hit_s=0 — dmem_stall_o=1; BRAM read of line
//       word 0 issued. posedge N: state → FILL; BRAM registers base+0.
//     Cycle N+1+b (FILL, b = 0..W-1): BRAM presents word b on mem_rdata_i;
//       word b+1's address is issued. posedge: word b captured into the line;
//       if b is the requested word, it is also captured into cpu_rdata_q.
//       dmem_stall_o = 1 except in the final fill cycle (b = W-1).
//     Cycle N+W+1 (WB): cpu_rdata_o = cpu_rdata_q = miss data ← wb_stage. ✓
//
//   For W = 1, WAYS = 1 this reduces exactly to the original single-word
//   direct-mapped behavior: one stall cycle, fill captured at posedge N+1.
//
//   In the last FILL cycle the module keeps mem_addr_o at the final beat
//   address so the backing BRAM re-registers it — harmless, since wb_stage
//   reads cpu_rdata_o (the registered capture), not mem_rdata_i directly.
//
//   Fill order is word 0 upward (no critical-word-first): the pipeline is
//   frozen for the whole fill anyway, so early restart would buy nothing.
//
// Associativity and replacement:
//   WAYS ways per set, true LRU via a per-set age permutation: age 0 = MRU,
//   age WAYS-1 = LRU victim. On any touch (read hit, store hit, fill
//   complete) the touched way goes to age 0 and every way younger than it
//   ages by one — ages within a set always remain a permutation of
//   {0..WAYS-1} (established at reset by age = way index). Victim choice:
//   first invalid way, else the age WAYS-1 way. True LRU is used at every
//   WAYS (no tree-PLRU variant): at this design's size the age matrix is
//   noise next to the data array, and one replacement algorithm beats two.
//
// Write policy:
//   Write-through, no-write-allocate.
//   Stores always forward to backing memory via mem_wen_o/mem_wstrb_o/mem_wdata_o.
//   On a store hit the cached word is also updated (and the way touched for
//   LRU). Store misses skip cache fill. Stores never assert dmem_stall_o.
//
// Hit/miss counters:
//   hit_count_o and miss_count_o accumulate on every read request; overflow wraps.
//
// Parameters:
//   NSETS      — number of SETS (not lines). Power of two. Capacity in words
//                is NSETS * WAYS * LINE_WORDS. Default 64.
//   LINE_WORDS — 32-bit words per line. Power of two, 1..16 (16 = largest
//                burst mem_if_pkg can express). Default 1.
//   WAYS       — associativity. Power of two, 1..8. Default 1 (direct-mapped),
//                which preserves the original geometry and cycle behavior.

`default_nettype none

module dcache
#(
    parameter int NSETS      = 64,
    parameter int LINE_WORDS = 1,
    parameter int WAYS       = 1
) (
    input  wire logic        clk,
    input  wire logic        rst,

    // CPU-side (connects to fluxcore_top dmem_* ports)
    input  wire logic [31:0] cpu_addr_i,
    input  wire logic        cpu_ren_i,     // load in MEM stage
    input  wire logic        cpu_wen_i,     // store in MEM stage
    input  wire logic [3:0]  cpu_wstrb_i,
    input  wire logic [31:0] cpu_wdata_i,
    output logic [31:0]      cpu_rdata_o,   // load data, valid in WB cycle
    output logic             dmem_stall_o,  // read miss: stall pipeline this cycle

    // Backing BRAM-side
    output logic [31:0]      mem_addr_o,
    output logic             mem_ren_o,     // ignored by bram_dmem but useful for debug
    output logic             mem_wen_o,
    output logic [3:0]       mem_wstrb_o,
    output logic [31:0]      mem_wdata_o,
    input  wire  logic [31:0] mem_rdata_i,

    // Hit/miss counters (32-bit wrapping)
    output logic [31:0]      hit_count_o,
    output logic [31:0]      miss_count_o
);
    localparam int INDEX_W = $clog2(NSETS);
    // Word-offset bits within a line (0 for LINE_WORDS = 1).
    localparam int OFF_W   = (LINE_WORDS == 1) ? 0 : $clog2(LINE_WORDS);
    localparam int TAG_W   = 32 - INDEX_W - OFF_W - 2;  // 2 byte-offset bits
    // Age field width (1 bit at WAYS = 1 so the arrays stay legal).
    localparam int AGE_W   = (WAYS == 1) ? 1 : $clog2(WAYS);

    // Use localparam instead of enum for broader tool compatibility
    localparam logic ST_IDLE = 1'b0;
    localparam logic ST_FILL = 1'b1;

    logic                  state_q;
    logic [31:0]           cpu_rdata_q;    // registered load data presented to WB
    logic [INDEX_W-1:0]    miss_index_q;   // saved index for FILL state
    logic [TAG_W-1:0]      miss_tag_q;     // saved tag for FILL state
    logic [31:0]           miss_base_q;    // byte address of line word 0 for FILL
    int unsigned           miss_woff_q;    // requested word-in-line for FILL
    int unsigned           miss_way_q;     // victim way chosen at miss time
    int unsigned           beat_q;         // fill beat whose data arrives this cycle

    logic                  valid_q [0:WAYS-1][0:NSETS-1];
    logic [TAG_W-1:0]      tag_q   [0:WAYS-1][0:NSETS-1];
    logic [31:0]           data_q  [0:WAYS-1][0:NSETS-1][0:LINE_WORDS-1];
    logic [AGE_W-1:0]      age_q   [0:WAYS-1][0:NSETS-1];  // 0 = MRU

    logic [31:0]           hit_count_q;
    logic [31:0]           miss_count_q;

    // Intermediate combinatorial signals
    logic [INDEX_W-1:0]  index_s;
    logic [TAG_W-1:0]    tag_s;
    logic                hit_s;
    int unsigned         hit_way_s;       // way that hit (valid when hit_s)
    int unsigned         victim_way_s;    // way to fill on a miss
    logic [31:0]         store_merged_s;
    int unsigned         woff_s;          // word-in-line of the CPU access
    logic [31:0]         line_base_s;     // byte address of word 0 of the line

    // -----------------------------------------------------------------------
    // All combinatorial logic in one block for tool compatibility.
    // Use arithmetic to derive offset/index/tag — avoids parameterized
    // bit-selects.
    // -----------------------------------------------------------------------
    always @(*) begin : comb
        integer idx_int;
        logic   victim_found;
        // Word offset within the line: word address mod LINE_WORDS
        woff_s  = (cpu_addr_i >> 2) & (LINE_WORDS - 1);
        // Index: line address mod NSETS (NSETS must be power of two)
        idx_int = (cpu_addr_i >> (2 + OFF_W)) & (NSETS - 1);
        index_s = idx_int[INDEX_W-1:0];
        // Tag: upper bits above index, word-offset and byte-offset
        tag_s   = cpu_addr_i >> (INDEX_W + OFF_W + 2);
        // Byte address of word 0 of the addressed line
        line_base_s = cpu_addr_i & ~32'((LINE_WORDS * 4) - 1);

        // Hit detection across ways (tags are unique per set, at most one hit)
        hit_s     = 1'b0;
        hit_way_s = 0;
        for (int w = 0; w < WAYS; w++) begin
            if ((state_q == ST_IDLE) && valid_q[w][index_s]
                && (tag_q[w][index_s] == tag_s)) begin
                hit_s     = 1'b1;
                hit_way_s = w;
            end
        end

        // Victim: first invalid way wins, else the LRU (age WAYS-1) way.
        victim_way_s = 0;
        victim_found = 1'b0;
        for (int w = 0; w < WAYS; w++) begin
            if (!victim_found && !valid_q[w][index_s]) begin
                victim_way_s = w;
                victim_found = 1'b1;
            end
        end
        if (!victim_found) begin
            for (int w = 0; w < WAYS; w++) begin
                if (age_q[w][index_s] == AGE_W'(WAYS - 1))
                    victim_way_s = w;
            end
        end

        // Byte-enable merge for store-hit cache update
        store_merged_s = data_q[hit_way_s][index_s][woff_s];
        if (cpu_wstrb_i[0]) store_merged_s[ 7: 0] = cpu_wdata_i[ 7: 0];
        if (cpu_wstrb_i[1]) store_merged_s[15: 8] = cpu_wdata_i[15: 8];
        if (cpu_wstrb_i[2]) store_merged_s[23:16] = cpu_wdata_i[23:16];
        if (cpu_wstrb_i[3]) store_merged_s[31:24] = cpu_wdata_i[31:24];

        // Output defaults
        dmem_stall_o = 1'b0;
        mem_addr_o   = cpu_addr_i;
        mem_ren_o    = 1'b0;
        mem_wen_o    = 1'b0;
        mem_wstrb_o  = cpu_wstrb_i;
        mem_wdata_o  = cpu_wdata_i;

        case (state_q)
            ST_IDLE: begin
                if (cpu_ren_i && !hit_s) begin
                    dmem_stall_o = 1'b1;         // read miss: stall pipeline
                    mem_addr_o   = line_base_s;  // issue line word 0
                    mem_ren_o    = 1'b1;         // start BRAM fill
                end
                if (cpu_wen_i) begin
                    mem_wen_o   = 1'b1;   // write-through: always to backing mem
                    mem_wstrb_o = cpu_wstrb_i;
                    mem_wdata_o = cpu_wdata_i;
                end
            end
            ST_FILL: begin
                // Data for beat_q arrives this cycle; issue the next beat's
                // address (or hold the last one — the re-registration is
                // harmless, see header).
                if (beat_q + 1 < LINE_WORDS)
                    mem_addr_o = miss_base_q + 32'((beat_q + 1) * 4);
                else
                    mem_addr_o = miss_base_q + 32'((LINE_WORDS - 1) * 4);
                mem_ren_o = 1'b1;
                // Stall until the final beat's cycle: in that cycle the MEM
                // stage completes (its data is captured at the closing edge).
                dmem_stall_o = (beat_q + 1 < LINE_WORDS);
            end
            default: ;
        endcase
    end

    // -----------------------------------------------------------------------
    // LRU touch: touched way → age 0; every way younger than it ages by one.
    // Preserves the per-set permutation invariant. Reads see pre-edge values.
    // -----------------------------------------------------------------------
    task automatic lru_touch(input int unsigned way, input logic [INDEX_W-1:0] set);
        for (int v = 0; v < WAYS; v++) begin
            if (v == int'(way))
                age_q[v][set] <= '0;
            else if (age_q[v][set] < age_q[way][set])
                age_q[v][set] <= age_q[v][set] + 1;
        end
    endtask

    // -----------------------------------------------------------------------
    // Sequential: FSM, cache storage, LRU, counters
    // -----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q      <= ST_IDLE;
            cpu_rdata_q  <= '0;
            hit_count_q  <= '0;
            miss_count_q <= '0;
            beat_q       <= 0;
            miss_woff_q  <= 0;
            miss_way_q   <= 0;
            for (int w = 0; w < WAYS; w++) begin
                for (int i = 0; i < NSETS; i++) begin
                    valid_q[w][i] <= 1'b0;
                    age_q[w][i]   <= AGE_W'(w);  // permutation {0..WAYS-1}
                end
            end
        end else begin
            case (state_q)
                ST_IDLE: begin
                    if (cpu_ren_i) begin
                        if (hit_s) begin
                            cpu_rdata_q <= data_q[hit_way_s][index_s][woff_s];
                            hit_count_q <= hit_count_q + 1;
                            lru_touch(hit_way_s, index_s);
                        end else begin
                            miss_index_q <= index_s;
                            miss_tag_q   <= tag_s;
                            miss_base_q  <= line_base_s;
                            miss_woff_q  <= woff_s;
                            miss_way_q   <= victim_way_s;
                            beat_q       <= 0;
                            miss_count_q <= miss_count_q + 1;
                            state_q      <= ST_FILL;
                        end
                    end
                    if (cpu_wen_i && hit_s) begin
                        data_q[hit_way_s][index_s][woff_s] <= store_merged_s;
                        lru_touch(hit_way_s, index_s);
                    end
                end
                ST_FILL: begin
                    // Capture the beat that arrived this cycle.
                    data_q[miss_way_q][miss_index_q][beat_q] <= mem_rdata_i;
                    if (beat_q == miss_woff_q)
                        cpu_rdata_q <= mem_rdata_i;
                    if (beat_q + 1 == LINE_WORDS) begin
                        // Line complete: publish tag/valid, touch, back to IDLE.
                        valid_q[miss_way_q][miss_index_q] <= 1'b1;
                        tag_q[miss_way_q][miss_index_q]   <= miss_tag_q;
                        lru_touch(miss_way_q, miss_index_q);
                        state_q <= ST_IDLE;
                    end else begin
                        beat_q <= beat_q + 1;
                    end
                end
                default: state_q <= ST_IDLE;
            endcase
        end
    end

    assign cpu_rdata_o  = cpu_rdata_q;
    assign hit_count_o  = hit_count_q;
    assign miss_count_o = miss_count_q;

endmodule : dcache

`default_nettype wire
