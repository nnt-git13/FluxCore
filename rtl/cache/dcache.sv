// rtl/cache/dcache.sv
//
// Set-associative data cache — BRAM-compatible stall interface.
// Write policy selectable: write-through/no-allocate (default, the original
// behavior) through write-back/write-allocate.
//
// This module is the integration shim between fluxcore_top's dmem_* ports and
// a backing bram_dmem. It presents the same 1-cycle latency as a bare BRAM on
// hits, and stalls the pipeline on misses while it talks to the backing store.
//
// Timing (matches existing BRAM pipeline contract; W = LINE_WORDS):
//
//   Hit path (no stall added):
//     Cycle N (MEM): cpu_ren_i=1, hit_s=1 — cache data registered at posedge N.
//     Cycle N+1 (WB): cpu_rdata_o = cache data ← wb_stage reads this live. ✓
//
//   Read miss, clean victim (W stall cycles — the legacy path):
//     Cycle N (MEM): stall; fill word 0 read issued. posedge: state → FILL.
//     Cycle N+1+b (FILL, b = 0..W-1): word b arrives; word b+1 issued.
//       posedge: word b captured (requested word also into cpu_rdata_q).
//       stall deasserts in the final fill cycle. For W=1, WAYS=1, defaults
//       this is cycle-identical to the original single-word design.
//
//   Miss, dirty victim (write-back mode only; W + W + 1 stall cycles):
//     Cycle N (IDLE): stall; EVICT write of victim word 0 issued.
//     EVICT beats 1..W-1: victim words written back to memory.
//     FILLREQ (1 cycle): fill word 0 read issued (the address port was
//       occupied by writes until now — one BRAM port, reads cannot overlap).
//     FILL as above.
//
//   Store miss with write-allocate: same miss flow, stalling the store in
//     MEM (the pipeline holds cpu_* stable, exactly as for loads). The store
//     bytes are merged into the line as the fill beat for its word arrives;
//     no cpu_rdata capture. In write-through mode the store also goes to
//     memory in the IDLE cycle (so the fill reads back the already-updated
//     word — the merge is then idempotent), and FILLREQ is used since the
//     IDLE cycle's address slot carried the write.
//
// Write policies (WRITE_ALLOCATE, WRITE_BACK):
//   0,0  write-through, no-allocate — the original behavior. Store hits
//        update cache + memory; store misses go to memory only; stores
//        never stall.
//   1,0  write-through + allocate: store misses additionally fill the line
//        (stall W+1 cycles); every store still writes memory through.
//   0,1  write-back + no-allocate ("write-around"): store hits dirty the
//        line without touching memory; store misses write memory directly.
//   1,1  write-back + allocate: store hits dirty the line; store misses
//        fill then merge, marking the line dirty. Memory is written ONLY
//        on dirty eviction.
//   Dirty lines exist only when WRITE_BACK=1; eviction write-back never
//   triggers otherwise.
//
// NOTE on eviction buffering: an eviction/write buffer (overlap fill with
//   victim drain, forward loads from buffered stores) is deliberately NOT
//   implemented at this layer — evict writes and fill reads share the one
//   BRAM address port, so they cannot overlap regardless of buffering. The
//   buffer arrives with the ready/valid memory interface (P3), where the
//   backing store can actually accept queued writes.
//
// Associativity and replacement:
//   WAYS ways per set, true LRU via a per-set age permutation: age 0 = MRU,
//   age WAYS-1 = LRU victim. On any touch (read hit, store hit, fill
//   complete) the touched way goes to age 0 and every way younger than it
//   ages by one — ages within a set always remain a permutation of
//   {0..WAYS-1} (established at reset by age = way index). Victim choice:
//   first invalid way, else the age WAYS-1 way.
//
// Hit/miss counters:
//   Accumulate on READ requests only (the original definition — store
//   traffic is not counted, keeping legacy counter expectations intact).
//
// Non-blocking mode (NONBLOCKING=1) — the 1-entry MSHR / hit-under-miss:
//   The miss FSM itself is the MSHR: one outstanding miss. A read or
//   allocating-store miss in IDLE with defer_ok_i=1 is ACCEPTED instead of
//   stalling: miss_defer_o pulses for that cycle, the pipeline moves on, and
//   the fill (evict + refill) runs in the background. While busy:
//     - read hits and (write-back) store hits to OTHER lines are served
//       normally — hit-under-miss;
//     - any access to the line being replaced (old tag still matching during
//       EVICT) stalls: its data is in flux;
//     - further misses, and store hits that need the memory port
//       (write-through), stall until the MSHR frees — miss-under-miss is
//       structural.
//   A deferred READ's word is captured into a dedicated register and
//   announced with a 1-cycle fill_done_o pulse + fill_data_o (the cpu_rdata_o
//   register keeps serving hits-under-miss untouched). Deferred STORES are
//   fire-and-forget: the store data is merged during the fill; no pulse.
//   defer_ok_i is sampled at accept time: 0 forces the legacy blocking
//   behavior for that miss (the core uses this for FP loads and anything
//   else it cannot scoreboard).
//
//   ERROR POLICY (P2.4, forward-looking): the current BRAM backend cannot
//   fault, so a deferred access never errors. When the mem_if backend (P3)
//   introduces MEM_SLVERR/MEM_DECERR responses, an error on a DEFERRED
//   access is architecturally IMPRECISE — the load has already retired and
//   younger instructions may have committed. Policy: such errors raise a
//   non-recoverable machine error (fatal), never a precise load access
//   fault. Precise load faults remain possible only on the blocking path
//   (defer_ok_i=0). Misalignment is unaffected: mem_stage traps it before
//   any request reaches this module.
//   The CORE is responsible for: scoreboarding the deferred load's rd,
//   stalling readers AND writers of it (RAW + WAW), suppressing the WB-stage
//   write of the deferred load, and writing fill_data_o to the register file
//   when fill_done_o pulses. See fluxcore_top.
//
// Parameters:
//   NSETS          — number of SETS. Power of two. Capacity in words is
//                    NSETS * WAYS * LINE_WORDS. Default 64.
//   LINE_WORDS     — words per line, power of two 1..16 (16 = largest burst
//                    mem_if_pkg can express). Default 1.
//   WAYS           — associativity, power of two 1..8. Default 1.
//   WRITE_ALLOCATE — allocate a line on store miss. Default 0.
//   WRITE_BACK     — dirty-line write-back instead of write-through.
//                    Default 0.
//   NONBLOCKING    — hit-under-miss with a 1-entry MSHR. Default 0 (all
//                    misses stall the pipeline, the original behavior).

`default_nettype none

module dcache
    import mem_if_pkg::*;
#(
    parameter int NSETS          = 64,
    parameter int LINE_WORDS     = 1,
    parameter int WAYS           = 1,
    parameter bit WRITE_ALLOCATE = 1'b0,
    parameter bit WRITE_BACK     = 1'b0,
    parameter bit NONBLOCKING    = 1'b0
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
    output logic             dmem_stall_o,  // miss handling: stall pipeline

    // Cache maintenance: pulse flush_req_i to write back every dirty line
    // and invalidate the whole cache. The pipeline is stalled for the walk
    // (dmem_stall_o high; flush is rare, simplicity wins). flush_busy_o
    // stays high until the walk completes.
    input  wire logic        flush_req_i = 1'b0,
    output logic             flush_busy_o,

    // Non-blocking (MSHR) interface — inert when NONBLOCKING=0.
    input  wire logic        defer_ok_i = 1'b0,  // core allows deferring THIS miss
    output logic             miss_defer_o,  // this cycle's miss was accepted
    output logic             fill_done_o,   // deferred READ completed (1 cycle)
    output logic [31:0]      fill_data_o,   // its data, valid with fill_done_o

    // Backing store — mem_if requester (wire to mem_if_bram, mem_model,
    // or the AXI adapter). Evictions are one burst write transaction,
    // fills one burst read; write acks are discarded on arrival.
    output logic             mem_req_valid_o,
    input  wire logic        mem_req_ready_i,
    output mem_req_t         mem_req_o,
    input  wire logic        mem_rsp_valid_i,
    output logic             mem_rsp_ready_o,
    input  wire mem_rsp_t    mem_rsp_i,

    // Hit/miss counters (32-bit wrapping, read traffic only)
    output logic [31:0]      hit_count_o,
    output logic [31:0]      miss_count_o
);
    localparam int INDEX_W = $clog2(NSETS);
    // Word-offset bits within a line (0 for LINE_WORDS = 1).
    localparam int OFF_W   = (LINE_WORDS == 1) ? 0 : $clog2(LINE_WORDS);
    localparam int TAG_W   = 32 - INDEX_W - OFF_W - 2;  // 2 byte-offset bits
    // Age field width (1 bit at WAYS = 1 so the arrays stay legal).
    localparam int AGE_W   = (WAYS == 1) ? 1 : $clog2(WAYS);

    // mem_if transaction ids: fills are the only responses the FSM waits on;
    // everything else (write acks) is discarded by id on arrival.
    localparam mem_id_t ID_WRITE = 4'd0;
    localparam mem_id_t ID_FILL  = 4'd1;

    // Use localparams instead of an enum for broader tool compatibility
    localparam logic [2:0] ST_IDLE    = 3'd0;
    localparam logic [2:0] ST_FILL    = 3'd1;
    localparam logic [2:0] ST_EVICT   = 3'd2;
    localparam logic [2:0] ST_FILLREQ = 3'd3;
    localparam logic [2:0] ST_FWALK   = 3'd4;  // flush: find next dirty line
    localparam logic [2:0] ST_FEVICT  = 3'd5;  // flush: write one line back

    logic [2:0]            state_q;
    logic [31:0]           cpu_rdata_q;    // registered load data presented to WB
    logic [INDEX_W-1:0]    miss_index_q;   // saved index for the miss flow
    logic [TAG_W-1:0]      miss_tag_q;     // saved tag for the miss flow
    logic [31:0]           miss_base_q;    // byte address of line word 0 to fill
    logic [31:0]           evict_base_q;   // byte address of victim line word 0
    int unsigned           miss_woff_q;    // requested word-in-line
    int unsigned           miss_way_q;     // victim way chosen at miss time
    int unsigned           beat_q;         // fill beat whose data arrives this cycle
    int unsigned           ebeat_q;        // next eviction write beat to issue
    logic                  miss_is_store_q;
    logic [3:0]            miss_wstrb_q;   // store bytes to merge after fill
    logic [31:0]           miss_wdata_q;
    logic                  miss_deferred_q; // this miss was accepted non-blocking
    int unsigned           fw_way_q, fw_set_q;  // flush-walk cursor
    logic                  flush_pend_q;        // request seen while busy
    logic [31:0]           fill_rdata_q;   // deferred read's word (own register:
                                           // cpu_rdata_q keeps serving hits)
    logic                  fill_done_q;    // 1-cycle completion pulse

    logic                  valid_q [0:WAYS-1][0:NSETS-1];
    logic                  dirty_q [0:WAYS-1][0:NSETS-1];
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
    logic                defer_now_s;     // an IDLE miss would defer, not stall
    logic                nb_busy_stall_s; // busy-MSHR stall for this access
    logic                fill_rsp_s;      // a fill beat is on the rsp channel
    int unsigned         victim_way_s;    // way to fill on a miss
    logic                victim_dirty_s;  // victim line needs write-back
    logic [31:0]         victim_base_s;   // byte address of victim word 0
    logic                alloc_miss_s;    // this cycle starts a line fill
    logic [31:0]         store_merged_s;
    logic [31:0]         fill_word_s;     // fill beat, store bytes merged in
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

        // Hit detection across ways (tags are unique per set, at most one hit).
        // Blocking mode: hits exist only in IDLE (the pipeline is frozen
        // during a miss anyway). Non-blocking: hits are also served while the
        // MSHR is busy — EXCEPT on the line being replaced, whose old tag
        // still matches during EVICT but whose data is in flux.
        hit_s     = 1'b0;
        hit_way_s = 0;
        for (int w = 0; w < WAYS; w++) begin
            if (valid_q[w][index_s] && (tag_q[w][index_s] == tag_s)
                && ((state_q == ST_IDLE)
                    || (NONBLOCKING && !((w == int'(miss_way_q))
                                         && (index_s == miss_index_q))))) begin
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
        victim_dirty_s = WRITE_BACK && valid_q[victim_way_s][index_s]
                         && dirty_q[victim_way_s][index_s];
        victim_base_s  = (32'(tag_q[victim_way_s][index_s]) << (INDEX_W + OFF_W + 2))
                       | (32'(index_s) << (OFF_W + 2));

        // Does this cycle start a line fill?
        alloc_miss_s = (state_q == ST_IDLE) && !hit_s
                       && (cpu_ren_i || (cpu_wen_i && WRITE_ALLOCATE));

        // Byte-enable merge for store-hit cache update
        store_merged_s = data_q[hit_way_s][index_s][woff_s];
        if (cpu_wstrb_i[0]) store_merged_s[ 7: 0] = cpu_wdata_i[ 7: 0];
        if (cpu_wstrb_i[1]) store_merged_s[15: 8] = cpu_wdata_i[15: 8];
        if (cpu_wstrb_i[2]) store_merged_s[23:16] = cpu_wdata_i[23:16];
        if (cpu_wstrb_i[3]) store_merged_s[31:24] = cpu_wdata_i[31:24];

        // Fill beat with the allocating store's bytes merged in (idempotent
        // in write-through mode, where memory was already updated).
        fill_word_s = mem_rsp_i.rdata;
        if (miss_is_store_q && beat_q == miss_woff_q) begin
            if (miss_wstrb_q[0]) fill_word_s[ 7: 0] = miss_wdata_q[ 7: 0];
            if (miss_wstrb_q[1]) fill_word_s[15: 8] = miss_wdata_q[15: 8];
            if (miss_wstrb_q[2]) fill_word_s[23:16] = miss_wdata_q[23:16];
            if (miss_wstrb_q[3]) fill_word_s[31:24] = miss_wdata_q[31:24];
        end

        // Would THIS miss be accepted non-blocking?
        defer_now_s = NONBLOCKING && defer_ok_i;

        // While the MSHR is busy (non-blocking transaction), a CPU access
        // stalls unless it is a servable hit: read hits always; store hits
        // only under write-back (a write-through store hit needs the memory
        // port, which the fill owns).
        nb_busy_stall_s = (cpu_ren_i && !hit_s)
                        | (cpu_wen_i && !(hit_s && WRITE_BACK));

        // A fill beat is available on the response channel this cycle.
        // Write acks (ID_WRITE) are absorbed by the always-high rsp_ready.
        fill_rsp_s = mem_rsp_valid_i && (mem_rsp_i.id == ID_FILL);

        // Output defaults
        dmem_stall_o    = 1'b0;
        miss_defer_o    = 1'b0;
        mem_req_valid_o = 1'b0;
        mem_req_o       = mem_read_req(ID_FILL, line_base_s);
        mem_rsp_ready_o = 1'b1;   // never backpressure: acks are discarded,
                                  // fill beats are always consumable

        case (state_q)
            ST_IDLE: begin
                if (alloc_miss_s) begin
                    // The miss's first transaction goes out this cycle; if
                    // the backend is not ready the miss (and any would-be
                    // deferral) simply retries next cycle under stall.
                    mem_req_valid_o = 1'b1;
                    dmem_stall_o    = !(defer_now_s && mem_req_ready_i);
                    miss_defer_o    = defer_now_s && mem_req_ready_i;
                    if (victim_dirty_s) begin
                        // Eviction: burst write, beat 0 now.
                        mem_req_o = mem_write_req(ID_WRITE, victim_base_s,
                                                  4'hF,
                                                  data_q[victim_way_s][index_s][0]);
                        mem_req_o.len = mem_len_for(LINE_WORDS);
                    end else if (cpu_wen_i && !WRITE_BACK) begin
                        // Allocating store, write-through: memory write first
                        // (owns the request channel → fill starts in FILLREQ).
                        mem_req_o = mem_write_req(ID_WRITE, cpu_addr_i,
                                                  cpu_wstrb_i, cpu_wdata_i);
                    end else begin
                        // Clean-victim read miss (the legacy fast path) or
                        // write-back allocating store: burst read now.
                        mem_req_o     = mem_read_req(ID_FILL, line_base_s);
                        mem_req_o.len = mem_len_for(LINE_WORDS);
                    end
                end else if (cpu_wen_i) begin
                    // Store hit, or store miss without allocation.
                    // Memory is written unless a write-back HIT absorbs it.
                    if (!(WRITE_BACK && hit_s)) begin
                        mem_req_valid_o = 1'b1;
                        mem_req_o = mem_write_req(ID_WRITE, cpu_addr_i,
                                                  cpu_wstrb_i, cpu_wdata_i);
                        // The store commits only when accepted; hold it in
                        // MEM otherwise (a 1-cycle backend is always ready
                        // here except in a write-ack shadow).
                        dmem_stall_o = !mem_req_ready_i;
                    end
                end
            end
            ST_EVICT: begin
                // Remaining beats of the eviction burst (beat 0 went out in
                // IDLE). Header fields repeat the accepted transaction; only
                // strb/wdata advance per the burst-write contract.
                mem_req_valid_o = 1'b1;
                mem_req_o = mem_write_req(ID_WRITE, evict_base_q, 4'hF,
                                          data_q[miss_way_q][miss_index_q][ebeat_q]);
                mem_req_o.len = mem_len_for(LINE_WORDS);
                dmem_stall_o = miss_deferred_q ? nb_busy_stall_s : 1'b1;
            end
            ST_FWALK: begin
                dmem_stall_o = 1'b1;
            end
            ST_FEVICT: begin
                // Same burst-write shape as ST_EVICT, walker-addressed.
                mem_req_valid_o = 1'b1;
                mem_req_o = mem_write_req(ID_WRITE, evict_base_q, 4'hF,
                                          data_q[fw_way_q][fw_set_q[INDEX_W-1:0]][ebeat_q]);
                mem_req_o.len = mem_len_for(LINE_WORDS);
                dmem_stall_o  = 1'b1;
            end
            ST_FILLREQ: begin
                // The request channel was carrying writes until now; issue
                // the fill burst read (retrying until the backend accepts —
                // with mem_if_bram that is one write-ack shadow cycle).
                mem_req_valid_o = 1'b1;
                mem_req_o       = mem_read_req(ID_FILL, miss_base_q);
                mem_req_o.len   = mem_len_for(LINE_WORDS);
                dmem_stall_o = miss_deferred_q ? nb_busy_stall_s : 1'b1;
            end
            ST_FILL: begin
                // Consume fill beats as the backend produces them. Blocking:
                // the frozen MEM stage completes in the cycle the final beat
                // arrives — stall drops exactly then, preserving the legacy
                // count against a 1-cycle backend. Non-blocking: nothing
                // waits on this fill; stall only unservable CPU accesses.
                dmem_stall_o = miss_deferred_q
                             ? nb_busy_stall_s
                             : !(fill_rsp_s && (beat_q + 1 == LINE_WORDS));
            end
            default: ;
        endcase
    end

    assign flush_busy_o = (state_q == ST_FWALK) || (state_q == ST_FEVICT)
                        || flush_pend_q;

    assign fill_done_o = fill_done_q;
    assign fill_data_o = fill_rdata_q;

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
            ebeat_q      <= 0;
            miss_woff_q  <= 0;
            miss_way_q   <= 0;
            miss_is_store_q <= 1'b0;
            miss_deferred_q <= 1'b0;
            flush_pend_q    <= 1'b0;
            fw_way_q        <= 0;
            fw_set_q        <= 0;
            fill_rdata_q    <= '0;
            fill_done_q     <= 1'b0;
            for (int w = 0; w < WAYS; w++) begin
                for (int i = 0; i < NSETS; i++) begin
                    valid_q[w][i] <= 1'b0;
                    dirty_q[w][i] <= 1'b0;
                    age_q[w][i]   <= AGE_W'(w);  // permutation {0..WAYS-1}
                end
            end
        end else begin
            fill_done_q <= 1'b0;   // 1-cycle pulse

            // Hit servicing — state-independent: always in IDLE, and under a
            // busy MSHR in non-blocking mode (there hit_s already excludes
            // the in-flux line; in blocking mode hit_s is 0 outside IDLE).
            // A write-through store hit is only serviceable in IDLE: its
            // memory write needs the port the fill owns.
            if (cpu_ren_i && hit_s) begin
                cpu_rdata_q <= data_q[hit_way_s][index_s][woff_s];
                hit_count_q <= hit_count_q + 1;
                lru_touch(hit_way_s, index_s);
            end
            if (cpu_wen_i && hit_s && ((state_q == ST_IDLE) || WRITE_BACK)) begin
                data_q[hit_way_s][index_s][woff_s] <= store_merged_s;
                if (WRITE_BACK)
                    dirty_q[hit_way_s][index_s] <= 1'b1;
                lru_touch(hit_way_s, index_s);
            end

            if (flush_req_i)
                flush_pend_q <= 1'b1;

            case (state_q)
                ST_IDLE: begin
                    if (flush_pend_q || flush_req_i) begin
                        // Start the maintenance walk (takes priority over a
                        // new CPU access; the pipeline is stalled anyway).
                        flush_pend_q <= 1'b0;
                        fw_way_q     <= 0;
                        fw_set_q     <= 0;
                        state_q      <= ST_FWALK;
                    end else begin
                    // Count a read miss when its transaction is ACCEPTED —
                    // a miss retrying against a not-ready backend (write-ack
                    // shadow, slow memory) must not count once per retry.
                    if (cpu_ren_i && !hit_s && mem_req_ready_i)
                        miss_count_q <= miss_count_q + 1;

                    if (alloc_miss_s && mem_req_ready_i) begin
                        miss_index_q    <= index_s;
                        miss_tag_q      <= tag_s;
                        miss_base_q     <= line_base_s;
                        evict_base_q    <= victim_base_s;
                        miss_woff_q     <= woff_s;
                        miss_way_q      <= victim_way_s;
                        miss_is_store_q <= cpu_wen_i;
                        miss_wstrb_q    <= cpu_wstrb_i;
                        miss_wdata_q    <= cpu_wdata_i;
                        miss_deferred_q <= defer_now_s;
                        beat_q          <= 0;
                        ebeat_q         <= 1;
                        if (victim_dirty_s)
                            state_q <= (LINE_WORDS > 1) ? ST_EVICT : ST_FILLREQ;
                        else if (cpu_wen_i && !WRITE_BACK)
                            state_q <= ST_FILLREQ;   // IDLE cycle carried the
                                                     // write-through store
                        else
                            state_q <= ST_FILL;      // fill beat 0 in flight
                    end
                    end  // !flush
                end
                ST_FWALK: begin
                    if (WRITE_BACK && valid_q[fw_way_q][fw_set_q[INDEX_W-1:0]]
                        && dirty_q[fw_way_q][fw_set_q[INDEX_W-1:0]]) begin
                        evict_base_q <= (32'(tag_q[fw_way_q][fw_set_q[INDEX_W-1:0]])
                                          << (INDEX_W + OFF_W + 2))
                                      | (32'(fw_set_q) << (OFF_W + 2));
                        ebeat_q <= 0;
                        state_q <= ST_FEVICT;
                    end else if (fw_set_q + 1 == NSETS) begin
                        if (fw_way_q + 1 == WAYS) begin
                            // Walk complete: invalidate everything.
                            for (int w = 0; w < WAYS; w++)
                                for (int i = 0; i < NSETS; i++) begin
                                    valid_q[w][i] <= 1'b0;
                                    dirty_q[w][i] <= 1'b0;
                                end
                            state_q <= ST_IDLE;
                        end else begin
                            fw_way_q <= fw_way_q + 1;
                            fw_set_q <= 0;
                        end
                    end else begin
                        fw_set_q <= fw_set_q + 1;
                    end
                end
                ST_FEVICT: begin
                    if (mem_req_ready_i) begin
                        if (ebeat_q + 1 == LINE_WORDS) begin
                            dirty_q[fw_way_q][fw_set_q[INDEX_W-1:0]] <= 1'b0;
                            // Cursor stays put: FWALK re-examines the (now
                            // clean) line and advances — keeps the wrap /
                            // completion logic in exactly one place.
                            state_q <= ST_FWALK;
                        end else begin
                            ebeat_q <= ebeat_q + 1;
                        end
                    end
                end
                ST_EVICT: begin
                    if (mem_req_ready_i) begin
                        if (ebeat_q + 1 == LINE_WORDS)
                            state_q <= ST_FILLREQ;
                        else
                            ebeat_q <= ebeat_q + 1;
                    end
                end
                ST_FILLREQ: begin
                    if (mem_req_ready_i)
                        state_q <= ST_FILL;   // fill burst accepted
                end
                ST_FILL: begin
                    if (fill_rsp_s) begin
                    // Capture the beat on the channel (store bytes merged in
                    // for an allocating store). A deferred read's word goes
                    // to its own register — cpu_rdata_q belongs to whatever
                    // hit is being served under the miss.
                    data_q[miss_way_q][miss_index_q][beat_q] <= fill_word_s;
                    if (!miss_is_store_q && beat_q == miss_woff_q) begin
                        if (miss_deferred_q) fill_rdata_q <= mem_rsp_i.rdata;
                        else                 cpu_rdata_q  <= mem_rsp_i.rdata;
                    end
                    if (beat_q + 1 == LINE_WORDS) begin
                        // Line complete: publish tag/valid/dirty, touch.
                        valid_q[miss_way_q][miss_index_q] <= 1'b1;
                        dirty_q[miss_way_q][miss_index_q] <=
                            WRITE_BACK && miss_is_store_q;
                        tag_q[miss_way_q][miss_index_q]   <= miss_tag_q;
                        fill_done_q <= miss_deferred_q && !miss_is_store_q;
                        // LRU: skip the completion touch when a same-set hit
                        // touched this cycle — two touches in one edge would
                        // break the age permutation; leaving the filled way
                        // as LRU is merely suboptimal, never incorrect.
                        if (!(hit_s && (index_s == miss_index_q)
                              && (cpu_ren_i || (cpu_wen_i && WRITE_BACK))))
                            lru_touch(miss_way_q, miss_index_q);
                        state_q <= ST_IDLE;
                    end else begin
                        beat_q <= beat_q + 1;
                    end
                    end  // fill_rsp_s
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
