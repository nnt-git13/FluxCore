// rtl/cache/l2_cache.sv
//
// Unified L2 cache — mem_if responder above, mem_if requester below.
//
// Sits between the L1(s) (via mem_arbiter once the I-cache exists) and the
// backing memory (mem_if_bram today, mem_if_axi → DDR later). Both faces
// speak the frozen mem_if_pkg protocol, so the L2 is a drop-in shim: any
// L1 that ran against mem_if_bram runs against the L2 unchanged.
//
// Geometry and policy:
//   NSETS × WAYS lines of LINE_WORDS 32-bit words. LINE_WORDS must equal
//   the L1 line size: every request burst then touches exactly one L2 line
//   (single-word transactions from a WT/W=1 L1 are 1-beat bursts, also
//   within-line by construction).
//   Write-allocate + write-back always (an L2 under a write-back L1 sees
//   mostly eviction bursts; anything else would just burn memory bandwidth).
//   True LRU via the same per-set age-permutation as the L1.
//
// Inclusion policy: NON-INCLUSIVE, NON-EXCLUSIVE (NINE).
//   A line may live in L1, L2, both, or neither. Chosen because it needs
//   NO back-invalidation path into the L1 (inclusive would have to evict
//   L1 copies whenever an L2 victim is chosen — a whole invalidation port
//   this single-core design has no other use for). The cost — an L2 victim
//   may still be dirty in L1 and its later writeback hit a line the L2 no
//   longer holds — is handled naturally: that writeback is a write miss,
//   which allocates. Cache-maintenance ops (P7) must visit BOTH levels
//   regardless of inclusion, so nothing is lost there either.
//
// Transaction flows (one at a time; s_req_ready low while busy):
//   read hit    : IDLE → RSERVE (stream line beats) → IDLE
//   read miss   : IDLE → [EVICT] → FILL0 → FILL → RSERVE → IDLE
//   write hit   : IDLE (beat 0 merged at the accept edge) → [WBEATS] →
//                 WACK → IDLE
//   write miss  : IDLE (beat 0 into the burst buffer) → [WBUF] → [EVICT] →
//                 FILL0 → FILL (buffer merged over arriving beats) → WACK
//   The write-miss burst buffer exists because beat 0's transfer completes
//   in the IDLE cycle (ready was high) — the line it belongs in does not
//   exist yet, so the whole burst is captured first, then the fill merges
//   it word-by-word exactly like the L1's allocating-store fill.
//
// Errors: backing-store error beats surface on the upstream response
// (read: per-beat err; write: SLVERR on the ack) and an errored fill is
// NOT installed.

`default_nettype none

module l2_cache
    import mem_if_pkg::*;
#(
    parameter int NSETS      = 256,
    parameter int LINE_WORDS = 4,
    parameter int WAYS       = 4
) (
    input  wire logic     clk,
    input  wire logic     rst,

    // Upstream — responder (faces L1 / arbiter)
    input  wire logic     s_req_valid_i,
    output logic          s_req_ready_o,
    input  wire mem_req_t s_req_i,
    output logic          s_rsp_valid_o,
    input  wire logic     s_rsp_ready_i,
    output mem_rsp_t      s_rsp_o,

    // Downstream — requester (faces backing memory)
    output logic          m_req_valid_o,
    input  wire logic     m_req_ready_i,
    output mem_req_t      m_req_o,
    input  wire logic     m_rsp_valid_i,
    output logic          m_rsp_ready_o,
    input  wire mem_rsp_t m_rsp_i,

    // Statistics (32-bit wrapping; transactions, not beats)
    output logic [31:0]   hit_count_o,
    output logic [31:0]   miss_count_o
);
    localparam int INDEX_W = $clog2(NSETS);
    localparam int OFF_W   = (LINE_WORDS == 1) ? 0 : $clog2(LINE_WORDS);
    localparam int TAG_W   = 32 - INDEX_W - OFF_W - 2;
    localparam int AGE_W   = (WAYS == 1) ? 1 : $clog2(WAYS);

    localparam mem_id_t ID_WB   = 4'd8;  // our writeback transactions
    localparam mem_id_t ID_FILL = 4'd9;  // our fill transactions

    localparam logic [2:0] S_IDLE   = 3'd0;
    localparam logic [2:0] S_RSERVE = 3'd1;
    localparam logic [2:0] S_WBEATS = 3'd2;
    localparam logic [2:0] S_WBUF   = 3'd3;
    localparam logic [2:0] S_WACK   = 3'd4;
    localparam logic [2:0] S_EVICT  = 3'd5;
    localparam logic [2:0] S_FILL0  = 3'd6;
    localparam logic [2:0] S_FILL   = 3'd7;

    logic [2:0]  state_q;
    mem_req_t    txn_q;
    int unsigned beat_q;         // upstream beat cursor (serve/absorb/buffer)
    int unsigned fbeat_q;        // downstream fill beat cursor
    int unsigned ebeat_q;        // downstream evict beat cursor
    int unsigned way_q;
    logic        fill_err_q;
    logic        pend_wr_q;      // fill belongs to a write miss

    // Write-miss burst buffer (strb=0 words merge nothing)
    logic [3:0]  wbuf_strb_q [0:15];
    logic [31:0] wbuf_data_q [0:15];

    logic                  valid_q [0:WAYS-1][0:NSETS-1];
    logic                  dirty_q [0:WAYS-1][0:NSETS-1];
    logic [TAG_W-1:0]      tag_q   [0:WAYS-1][0:NSETS-1];
    logic [31:0]           data_q  [0:WAYS-1][0:NSETS-1][0:LINE_WORDS-1];
    logic [AGE_W-1:0]      age_q   [0:WAYS-1][0:NSETS-1];

    logic [31:0] hit_count_q, miss_count_q;

    // ---- lookup of the incoming request ----
    logic [INDEX_W-1:0] index_s;
    logic [TAG_W-1:0]   tag_s;
    int unsigned        woff_s;
    logic [31:0]        line_base_s;
    logic               hit_s;
    int unsigned        hit_way_s, victim_way_s;
    logic               victim_dirty_s;
    logic [31:0]        victim_base_s;
    logic               single_s;       // 1-beat transaction

    always @(*) begin : comb_lookup
        integer idx_int;
        logic   victim_found;
        woff_s      = (s_req_i.addr >> 2) & (LINE_WORDS - 1);
        idx_int     = (s_req_i.addr >> (2 + OFF_W)) & (NSETS - 1);
        index_s     = idx_int[INDEX_W-1:0];
        tag_s       = s_req_i.addr >> (INDEX_W + OFF_W + 2);
        line_base_s = s_req_i.addr & ~32'((LINE_WORDS * 4) - 1);
        single_s    = (mem_beats(s_req_i.len) == 1);

        hit_s = 1'b0; hit_way_s = 0;
        for (int w = 0; w < WAYS; w++) begin
            if (valid_q[w][index_s] && (tag_q[w][index_s] == tag_s)) begin
                hit_s = 1'b1; hit_way_s = w;
            end
        end
        victim_way_s = 0; victim_found = 1'b0;
        for (int w = 0; w < WAYS; w++) begin
            if (!victim_found && !valid_q[w][index_s]) begin
                victim_way_s = w; victim_found = 1'b1;
            end
        end
        if (!victim_found)
            for (int w = 0; w < WAYS; w++)
                if (age_q[w][index_s] == AGE_W'(WAYS - 1))
                    victim_way_s = w;
        victim_dirty_s = valid_q[victim_way_s][index_s]
                       && dirty_q[victim_way_s][index_s];
        victim_base_s  = (32'(tag_q[victim_way_s][index_s]) << (INDEX_W + OFF_W + 2))
                       | (32'(index_s) << (OFF_W + 2));
    end

    // Registered views for the transaction in flight
    logic [INDEX_W-1:0] tindex_q;
    logic [TAG_W-1:0]   ttag_q;
    logic [31:0]        tline_base_q, evict_base_q;
    int unsigned        twoff_q;
    logic               tsingle_q;

    logic fill_beat_s;
    assign fill_beat_s = m_rsp_valid_i && (m_rsp_i.id == ID_FILL);

    // ---- handshakes / channel drive ----
    always_comb begin
        s_req_ready_o = (state_q == S_IDLE) || (state_q == S_WBEATS)
                      || (state_q == S_WBUF);
        s_rsp_valid_o = 1'b0;
        s_rsp_o       = '0;
        m_req_valid_o = 1'b0;
        m_req_o       = mem_read_req(ID_FILL, tline_base_q);
        m_rsp_ready_o = 1'b1;

        case (state_q)
            S_RSERVE: begin
                s_rsp_valid_o = 1'b1;
                s_rsp_o.id    = txn_q.id;
                s_rsp_o.rdata = data_q[way_q][tindex_q][beat_q];
                // A fill that errored was not installed; the served words
                // are garbage and every beat says so.
                s_rsp_o.err   = fill_err_q ? MEM_SLVERR : MEM_OK;
                s_rsp_o.last  = (beat_q + 1 == mem_beats(txn_q.len))
                              || tsingle_q;
            end
            S_WACK: begin
                s_rsp_valid_o = 1'b1;
                s_rsp_o.id    = txn_q.id;
                s_rsp_o.err   = fill_err_q ? MEM_SLVERR : MEM_OK;
                s_rsp_o.last  = 1'b1;
            end
            S_EVICT: begin
                m_req_valid_o = 1'b1;
                m_req_o = mem_write_req(ID_WB, evict_base_q, 4'hF,
                                        data_q[way_q][tindex_q][ebeat_q]);
                m_req_o.len = mem_len_for(LINE_WORDS);
            end
            S_FILL0: begin
                m_req_valid_o = 1'b1;
                m_req_o       = mem_read_req(ID_FILL, tline_base_q);
                m_req_o.len   = mem_len_for(LINE_WORDS);
            end
            default: ;
        endcase
    end

    task automatic lru_touch(input int unsigned way, input logic [INDEX_W-1:0] set);
        for (int v = 0; v < WAYS; v++) begin
            if (v == int'(way))
                age_q[v][set] <= '0;
            else if (age_q[v][set] < age_q[way][set])
                age_q[v][set] <= age_q[v][set] + 1;
        end
    endtask

    function automatic logic [31:0] merge_beat(input logic [31:0] old,
                                               input logic [3:0]  strb,
                                               input logic [31:0] nw);
        logic [31:0] r;
        r = old;
        if (strb[0]) r[ 7: 0] = nw[ 7: 0];
        if (strb[1]) r[15: 8] = nw[15: 8];
        if (strb[2]) r[23:16] = nw[23:16];
        if (strb[3]) r[31:24] = nw[31:24];
        return r;
    endfunction

    // ---- FSM ----
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q      <= S_IDLE;
            beat_q       <= 0; fbeat_q <= 0; ebeat_q <= 0;
            way_q        <= 0;
            fill_err_q   <= 1'b0;
            pend_wr_q    <= 1'b0;
            hit_count_q  <= '0;
            miss_count_q <= '0;
            for (int w = 0; w < WAYS; w++)
                for (int i = 0; i < NSETS; i++) begin
                    valid_q[w][i] <= 1'b0;
                    dirty_q[w][i] <= 1'b0;
                    age_q[w][i]   <= AGE_W'(w);
                end
        end else begin
            case (state_q)
                S_IDLE: begin
                    if (s_req_valid_i) begin
                        txn_q        <= s_req_i;
                        tindex_q     <= index_s;
                        ttag_q       <= tag_s;
                        tline_base_q <= line_base_s;
                        twoff_q      <= woff_s;
                        tsingle_q    <= single_s;
                        evict_base_q <= victim_base_s;
                        beat_q       <= 0;
                        fbeat_q      <= 0;
                        ebeat_q      <= 0;
                        fill_err_q   <= 1'b0;
                        if (hit_s) begin
                            way_q       <= hit_way_s;
                            hit_count_q <= hit_count_q + 1;
                            lru_touch(hit_way_s, index_s);
                            if (s_req_i.op == MEM_READ) begin
                                beat_q  <= single_s ? woff_s : 0;
                                state_q <= S_RSERVE;
                            end else begin
                                // beat 0 transferred this edge: merge it.
                                data_q[hit_way_s][index_s]
                                      [single_s ? woff_s : 0]
                                    <= merge_beat(
                                         data_q[hit_way_s][index_s]
                                               [single_s ? woff_s : 0],
                                         s_req_i.strb, s_req_i.wdata);
                                dirty_q[hit_way_s][index_s] <= 1'b1;
                                beat_q  <= 1;
                                state_q <= single_s ? S_WACK : S_WBEATS;
                            end
                        end else begin
                            way_q        <= victim_way_s;
                            miss_count_q <= miss_count_q + 1;
                            pend_wr_q    <= (s_req_i.op == MEM_WRITE);
                            if (s_req_i.op == MEM_WRITE) begin
                                // beat 0 into the burst buffer.
                                for (int b = 0; b < 16; b++)
                                    wbuf_strb_q[b] <= '0;
                                wbuf_strb_q[single_s ? woff_s : 0]
                                    <= s_req_i.strb;
                                wbuf_data_q[single_s ? woff_s : 0]
                                    <= s_req_i.wdata;
                                beat_q  <= 1;
                                state_q <= single_s
                                         ? (victim_dirty_s ? S_EVICT : S_FILL0)
                                         : S_WBUF;
                            end else begin
                                state_q <= victim_dirty_s ? S_EVICT : S_FILL0;
                            end
                        end
                    end
                end

                S_WBUF: begin
                    // Buffer remaining write-miss beats (word b = beat b:
                    // multi-beat bursts start at the line base).
                    if (s_req_valid_i) begin
                        wbuf_strb_q[beat_q] <= s_req_i.strb;
                        wbuf_data_q[beat_q] <= s_req_i.wdata;
                        if (beat_q + 1 == mem_beats(txn_q.len)) begin
                            // victim_dirty must be re-derived from the
                            // REGISTERED victim (arrays unchanged since
                            // IDLE — no fills happened in between).
                            state_q <= (valid_q[way_q][tindex_q]
                                        && dirty_q[way_q][tindex_q])
                                     ? S_EVICT : S_FILL0;
                        end else begin
                            beat_q <= beat_q + 1;
                        end
                    end
                end

                S_WBEATS: begin
                    // Write-hit: absorb remaining beats into the line.
                    if (s_req_valid_i) begin
                        data_q[way_q][tindex_q][beat_q]
                            <= merge_beat(data_q[way_q][tindex_q][beat_q],
                                          s_req_i.strb, s_req_i.wdata);
                        if (beat_q + 1 == mem_beats(txn_q.len))
                            state_q <= S_WACK;
                        else
                            beat_q <= beat_q + 1;
                    end
                end

                S_WACK: begin
                    if (s_rsp_ready_i)
                        state_q <= S_IDLE;
                end

                S_RSERVE: begin
                    if (s_rsp_ready_i) begin
                        if (beat_q + 1 == mem_beats(txn_q.len) || tsingle_q)
                            state_q <= S_IDLE;
                        else
                            beat_q <= beat_q + 1;
                    end
                end

                S_EVICT: begin
                    if (m_req_ready_i) begin
                        if (ebeat_q + 1 == LINE_WORDS) begin
                            dirty_q[way_q][tindex_q] <= 1'b0;
                            state_q <= S_FILL0;
                        end else begin
                            ebeat_q <= ebeat_q + 1;
                        end
                    end
                end

                S_FILL0: begin
                    if (m_req_ready_i)
                        state_q <= S_FILL;
                end

                S_FILL: begin
                    if (fill_beat_s) begin
                        // Write-miss: merge the buffered burst over the
                        // arriving beat, exactly like the L1's allocating
                        // store (wbuf_strb=0 words pass through untouched).
                        data_q[way_q][tindex_q][fbeat_q]
                            <= pend_wr_q
                             ? merge_beat(m_rsp_i.rdata,
                                          wbuf_strb_q[fbeat_q],
                                          wbuf_data_q[fbeat_q])
                             : m_rsp_i.rdata;
                        if (m_rsp_i.err != MEM_OK)
                            fill_err_q <= 1'b1;
                        if (fbeat_q + 1 == LINE_WORDS) begin
                            if (!fill_err_q && m_rsp_i.err == MEM_OK) begin
                                valid_q[way_q][tindex_q] <= 1'b1;
                                tag_q[way_q][tindex_q]   <= ttag_q;
                                dirty_q[way_q][tindex_q] <= pend_wr_q;
                                lru_touch(way_q, tindex_q);
                            end
                            if (txn_q.op == MEM_READ) begin
                                beat_q  <= tsingle_q ? twoff_q : 0;
                                state_q <= S_RSERVE;
                            end else begin
                                state_q <= S_WACK;
                            end
                        end else begin
                            fbeat_q <= fbeat_q + 1;
                        end
                    end
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

    assign hit_count_o  = hit_count_q;
    assign miss_count_o = miss_count_q;

endmodule : l2_cache

`default_nettype wire
