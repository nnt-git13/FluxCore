// rtl/cache/icache.sv
//
// Instruction cache — combinational hit path, mem_if fill path.
//
// Unlike the D-cache (which lives behind the MEM stage's registered timing),
// the fetch unit needs its instruction IN THE SAME CYCLE as fetch_addr_o.
// The I-cache therefore serves hits combinationally: tag compare + word mux
// straight from the arrays (LUTRAM-friendly at these sizes; 50 MHz has
// slack for the addr→tag→mux cone). On a miss it simply drives
// instr_valid_o low — the fetch unit holds its PC and emits bubbles (the
// P5.1 pin) — and fills the line over mem_if in the background.
//
// Redirect-friendliness: the PC may change mid-fill (a branch resolved).
// The fill cannot be aborted (mem_if transactions are indivisible) but it
// does not hold the front end hostage either: lookups continue every cycle,
// and if the new PC hits a resident line, fetch proceeds immediately while
// the stale fill completes in the background and installs normally (it is
// a valid line; it was just no longer urgent). Only a lookup of the line
// being REPLACED reads as a miss until installation completes.
//
// FENCE.I support: flush_i clears every valid bit in one cycle. A fill in
// flight when flush_i pulses is completed on the wire but NOT installed —
// its data was read before the fence and may be stale.
//
// Read-only by construction: no store path, no dirty bits, evictions are
// silent.
//
// Parameters mirror the D-cache: NSETS × WAYS × LINE_WORDS words, age-
// matrix true LRU.

`default_nettype none

module icache
    import mem_if_pkg::*;
#(
    parameter int NSETS      = 64,
    parameter int LINE_WORDS = 4,
    parameter int WAYS       = 2
) (
    input  wire logic        clk,
    input  wire logic        rst,

    // Fetch side (combinational)
    input  wire logic [31:0] pc_i,           // current fetch address
    output logic [31:0]      instr_o,        // valid when instr_valid_o
    output logic             instr_valid_o,  // 0 = miss in progress

    // FENCE.I: invalidate everything
    input  wire logic        flush_i = 1'b0,

    // Backing store — mem_if requester
    output logic             mem_req_valid_o,
    input  wire logic        mem_req_ready_i,
    output mem_req_t         mem_req_o,
    input  wire logic        mem_rsp_valid_i,
    output logic             mem_rsp_ready_o,
    input  wire mem_rsp_t    mem_rsp_i,

    // Statistics (32-bit wrapping; lookup-cycles, not unique fetches)
    output logic [31:0]      hit_count_o,
    output logic [31:0]      miss_count_o
);
    localparam int INDEX_W = $clog2(NSETS);
    localparam int OFF_W   = (LINE_WORDS == 1) ? 0 : $clog2(LINE_WORDS);
    localparam int TAG_W   = 32 - INDEX_W - OFF_W - 2;
    localparam int AGE_W   = (WAYS == 1) ? 1 : $clog2(WAYS);

    localparam mem_id_t ID_IFILL = 4'd2;

    localparam logic [1:0] S_IDLE  = 2'd0;
    localparam logic [1:0] S_REQ   = 2'd1;
    localparam logic [1:0] S_FILL  = 2'd2;

    logic [1:0]  state_q;
    int unsigned fbeat_q;
    int unsigned miss_way_q;
    logic [INDEX_W-1:0] miss_index_q;
    logic [TAG_W-1:0]   miss_tag_q;
    logic [31:0]        miss_base_q;
    logic               kill_fill_q;   // flushed mid-fill: do not install

    logic                  valid_q [0:WAYS-1][0:NSETS-1];
    logic [TAG_W-1:0]      tag_q   [0:WAYS-1][0:NSETS-1];
    logic [31:0]           data_q  [0:WAYS-1][0:NSETS-1][0:LINE_WORDS-1];
    logic [AGE_W-1:0]      age_q   [0:WAYS-1][0:NSETS-1];

    logic [31:0] hit_count_q, miss_count_q;

    // ---- combinational lookup ----
    logic [INDEX_W-1:0] index_s;
    logic [TAG_W-1:0]   tag_s;
    int unsigned        woff_s;
    logic [31:0]        line_base_s;
    logic               hit_s;
    int unsigned        hit_way_s, victim_way_s;
    logic               busy_s;

    assign busy_s = (state_q != S_IDLE);

    always @(*) begin : comb_lookup
        integer idx_int;
        logic   victim_found;
        woff_s      = (pc_i >> 2) & (LINE_WORDS - 1);
        idx_int     = (pc_i >> (2 + OFF_W)) & (NSETS - 1);
        index_s     = idx_int[INDEX_W-1:0];
        tag_s       = pc_i >> (INDEX_W + OFF_W + 2);
        line_base_s = pc_i & ~32'((LINE_WORDS * 4) - 1);

        hit_s = 1'b0; hit_way_s = 0;
        for (int w = 0; w < WAYS; w++) begin
            if (valid_q[w][index_s] && (tag_q[w][index_s] == tag_s)
                // the line being replaced is unreadable until installed
                && !(busy_s && (w == int'(miss_way_q))
                     && (index_s == miss_index_q))) begin
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
    end

    assign instr_o       = data_q[hit_way_s][index_s][woff_s];
    assign instr_valid_o = hit_s;

    // ---- mem_if drive ----
    logic fill_beat_s;
    assign fill_beat_s = mem_rsp_valid_i && (mem_rsp_i.id == ID_IFILL);

    always_comb begin
        mem_req_valid_o = 1'b0;
        mem_req_o       = mem_read_req(ID_IFILL, miss_base_q);
        mem_req_o.len   = mem_len_for(LINE_WORDS);
        mem_rsp_ready_o = 1'b1;
        if (state_q == S_REQ)
            mem_req_valid_o = 1'b1;
    end

    task automatic lru_touch(input int unsigned way, input logic [INDEX_W-1:0] set);
        for (int v = 0; v < WAYS; v++) begin
            if (v == int'(way))
                age_q[v][set] <= '0;
            else if (age_q[v][set] < age_q[way][set])
                age_q[v][set] <= age_q[v][set] + 1;
        end
    endtask

    // ---- FSM ----
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q      <= S_IDLE;
            fbeat_q      <= 0;
            miss_way_q   <= 0;
            kill_fill_q  <= 1'b0;
            hit_count_q  <= '0;
            miss_count_q <= '0;
            for (int w = 0; w < WAYS; w++)
                for (int i = 0; i < NSETS; i++) begin
                    valid_q[w][i] <= 1'b0;
                    age_q[w][i]   <= AGE_W'(w);
                end
        end else begin
            // FENCE.I: wipe everything; poison any fill in flight.
            if (flush_i) begin
                for (int w = 0; w < WAYS; w++)
                    for (int i = 0; i < NSETS; i++)
                        valid_q[w][i] <= 1'b0;
                if (state_q != S_IDLE)
                    kill_fill_q <= 1'b1;
            end

            if (hit_s)
                hit_count_q <= hit_count_q + 1;

            case (state_q)
                S_IDLE: begin
                    if (!hit_s && !flush_i) begin
                        // Launch the fill for the current PC's line.
                        miss_index_q <= index_s;
                        miss_tag_q   <= tag_s;
                        miss_base_q  <= line_base_s;
                        miss_way_q   <= victim_way_s;
                        fbeat_q      <= 0;
                        kill_fill_q  <= 1'b0;
                        miss_count_q <= miss_count_q + 1;
                        state_q      <= S_REQ;
                    end
                    if (hit_s)
                        lru_touch(hit_way_s, index_s);
                end
                S_REQ: begin
                    if (mem_req_ready_i)
                        state_q <= S_FILL;
                end
                S_FILL: begin
                    if (fill_beat_s) begin
                        data_q[miss_way_q][miss_index_q][fbeat_q]
                            <= mem_rsp_i.rdata;
                        if (mem_rsp_i.err != MEM_OK)
                            kill_fill_q <= 1'b1;   // any errored beat poisons
                        if (fbeat_q + 1 == LINE_WORDS) begin
                            if (!kill_fill_q && mem_rsp_i.err == MEM_OK) begin
                                valid_q[miss_way_q][miss_index_q] <= 1'b1;
                                tag_q[miss_way_q][miss_index_q]   <= miss_tag_q;
                                if (!(hit_s && index_s == miss_index_q))
                                    lru_touch(miss_way_q, miss_index_q);
                            end
                            state_q <= S_IDLE;
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

endmodule : icache

`default_nettype wire
