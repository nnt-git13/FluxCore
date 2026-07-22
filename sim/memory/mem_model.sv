// sim/memory/mem_model.sv
//
// Configurable-latency behavioral memory — SIMULATION ONLY, not synthesizable.
//
// Responder side of the frozen mem_if_pkg protocol. This is the second rung of
// the abstraction ladder in docs/interfaces/memory-interface-plan.md: same
// contract as the eventual BRAM/AXI/DDR backends, but with latency as a knob,
// so cache and pipeline behavior under slow memory can be exercised in xsim
// long before any AXI or DDR RTL exists.
//
// Latency model:
//   LATENCY  — cycles from accepting the final request beat to presenting the
//              first response beat. LATENCY=1 approximates the current BRAM
//              (request in MEM, data in WB). LATENCY=20..40 approximates DDR.
//   GAP      — extra cycles inserted between consecutive response beats of a
//              read burst (0 = back-to-back streaming, N = throttled).
//   JITTER   — 0 for deterministic latency; K > 0 adds urandom(0..K) cycles per
//              transaction, seeded by SEED so every run is reproducible.
//
// Concurrency:
//   ONE outstanding transaction. req_ready_o drops while busy. In-order by
//   construction; the id is echoed but never used for matching. This is
//   deliberately the simplest legal implementation of the contract — multiple
//   outstanding transactions arrive with the MSHR work (P2), and reordering
//   stress arrives with the L2/AXI models (P3/P4).
//
// Error injection:
//   Accesses at or above MEM_WORDS*4 return MEM_DECERR with defined-zero data
//   (reads) or are dropped (writes), modeling an undecoded address hole so the
//   error path of requesters can be tested without a special build.
//
// Initialization:
//   All words reset to zero. If INIT_FILE is non-empty it is loaded with
//   $readmemh at time zero (same convention as bram_imem/bram_dmem).

`timescale 1ns / 1ps
`default_nettype none

module mem_model
    import fluxcore_pkg::*;
    import mem_if_pkg::*;
#(
    parameter int unsigned MEM_WORDS = 16384,   // 64 KiB
    parameter int unsigned LATENCY   = 1,       // cycles, >= 1
    parameter int unsigned GAP       = 0,       // extra cycles between read beats
    parameter int unsigned JITTER    = 0,       // 0 = deterministic
    parameter int unsigned SEED      = 32'h5EED_F10C,
    parameter string       INIT_FILE = ""
)
(
    input  wire logic     clk,
    input  wire logic     rst,

    // Request channel (responder side)
    input  wire logic     req_valid_i,
    output logic          req_ready_o,
    input  wire mem_req_t req_i,

    // Response channel (responder side)
    output logic          rsp_valid_o,
    input  wire logic     rsp_ready_i,
    output mem_rsp_t      rsp_o
);

    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------
    word_t mem [0:MEM_WORDS-1];

    initial begin
        for (int i = 0; i < MEM_WORDS; i++) mem[i] = '0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    // -----------------------------------------------------------------------
    // Transaction state
    // -----------------------------------------------------------------------
    typedef enum logic [1:0] {
        S_IDLE,     // waiting for a request
        S_WDATA,    // collecting remaining write beats of a burst
        S_WAIT,     // counting down latency
        S_RESP      // presenting response beat(s)
    } state_e;

    state_e      state_q;
    mem_req_t    txn_q;          // request head (id/addr/op/len captured at beat 0)
    int unsigned beat_q;         // next beat index to consume (write) / produce (read)
    int unsigned wait_q;         // latency countdown
    int unsigned gap_q;          // inter-beat gap countdown
    int unsigned rng_q;          // urandom stream state (seeded once)

    // Word index of beat `idx` of a burst starting at `base`; oob flag alongside.
    function automatic int unsigned beat_word(input addr_t base, input int unsigned idx);
        return int'(mem_beat_addr(base, idx)) >> 2;
    endfunction

    function automatic logic beat_oob(input addr_t base, input int unsigned idx);
        return beat_word(base, idx) >= MEM_WORDS;
    endfunction

    // Per-transaction latency, jittered when JITTER > 0.
    function automatic int unsigned pick_latency();
        int unsigned j;
        if (JITTER == 0) return LATENCY;
        j = rng_q % (JITTER + 1);
        rng_q = rng_q * 32'h0019_660D + 32'h3C6E_F35F;  // LCG step, reproducible
        return LATENCY + j;
    endfunction

    // Enter the countdown for a freshly accepted transaction. LATENCY=1 must
    // present the response on the NEXT cycle (matching bare-BRAM timing), so
    // the S_WAIT state is skipped entirely when no extra cycles remain.
    task automatic start_wait();
        int unsigned l;
        l = pick_latency();
        beat_q <= 0;
        gap_q  <= 0;
        if (l <= 1) begin
            state_q <= S_RESP;
        end else begin
            wait_q  <= l - 1;
            state_q <= S_WAIT;
        end
    endtask

    // Byte-strobe merge of a write beat into memory (skip silently when oob).
    // `base` is passed explicitly: in S_IDLE the transaction head is still in
    // req_i (txn_q updates on this same edge), so txn_q.addr would be stale.
    task automatic do_write_beat(input addr_t base, input int unsigned idx,
                                 input mem_strb_t strb, input word_t wdata);
        if (!beat_oob(base, idx)) begin
            if (strb[0]) mem[beat_word(base, idx)][ 7: 0] <= wdata[ 7: 0];
            if (strb[1]) mem[beat_word(base, idx)][15: 8] <= wdata[15: 8];
            if (strb[2]) mem[beat_word(base, idx)][23:16] <= wdata[23:16];
            if (strb[3]) mem[beat_word(base, idx)][31:24] <= wdata[31:24];
        end
    endtask

    // -----------------------------------------------------------------------
    // Handshake outputs
    // -----------------------------------------------------------------------
    // Ready in IDLE (new transaction) and in WDATA (remaining write beats).
    assign req_ready_o = (state_q == S_IDLE) || (state_q == S_WDATA);

    always_comb begin
        rsp_valid_o = 1'b0;
        rsp_o       = '0;
        if (state_q == S_RESP && gap_q == 0) begin
            rsp_valid_o = 1'b1;
            rsp_o.id    = txn_q.id;
            if (txn_q.op == MEM_READ) begin
                rsp_o.rdata = beat_oob(txn_q.addr, beat_q) ? '0
                            : mem[beat_word(txn_q.addr, beat_q)];
                rsp_o.err   = beat_oob(txn_q.addr, beat_q) ? MEM_DECERR : MEM_OK;
                rsp_o.last  = (beat_q == mem_beats(txn_q.len) - 1);
            end else begin
                // Writes: single response beat, DECERR if any beat was oob.
                // The burst is contiguous ascending and the valid region starts
                // at word 0, so any-beat-oob reduces to last-beat-oob.
                rsp_o.rdata = '0;
                rsp_o.err   = beat_oob(txn_q.addr, mem_beats(txn_q.len) - 1)
                              ? MEM_DECERR : MEM_OK;
                rsp_o.last  = 1'b1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // FSM
    // -----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= S_IDLE;
            beat_q  <= 0;
            wait_q  <= 0;
            gap_q   <= 0;
            rng_q   <= SEED;
        end else begin
            unique case (state_q)
                S_IDLE: begin
                    if (req_valid_i) begin
                        txn_q  <= req_i;
                        beat_q <= 0;
                        if (req_i.op == MEM_WRITE) begin
                            do_write_beat(req_i.addr, 0, req_i.strb, req_i.wdata);
                            if (mem_beats(req_i.len) > 1) begin
                                beat_q  <= 1;
                                state_q <= S_WDATA;
                            end else begin
                                start_wait();
                            end
                        end else begin
                            start_wait();
                        end
                    end
                end

                S_WDATA: begin
                    // Subsequent beats of a write burst: only strb/wdata advance.
                    if (req_valid_i) begin
                        do_write_beat(txn_q.addr, beat_q, req_i.strb, req_i.wdata);
                        if (beat_q == mem_beats(txn_q.len) - 1) begin
                            start_wait();
                        end else begin
                            beat_q <= beat_q + 1;
                        end
                    end
                end

                S_WAIT: begin
                    if (wait_q <= 1) begin
                        beat_q  <= 0;
                        gap_q   <= 0;
                        state_q <= S_RESP;
                    end else begin
                        wait_q <= wait_q - 1;
                    end
                end

                S_RESP: begin
                    if (gap_q != 0) begin
                        gap_q <= gap_q - 1;
                    end else if (rsp_ready_i) begin
                        if (txn_q.op == MEM_WRITE
                            || beat_q == mem_beats(txn_q.len) - 1) begin
                            state_q <= S_IDLE;
                        end else begin
                            beat_q <= beat_q + 1;
                            gap_q  <= GAP;
                        end
                    end
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

endmodule : mem_model

`default_nettype wire
