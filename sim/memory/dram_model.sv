// sim/memory/dram_model.sv
//
// DRAM-timing mem_if responder — SIMULATION ONLY, not synthesizable.
//
// The top rung of the sim-memory ladder (mem_model = flat latency; this =
// bank/row-aware latency), standing in for the Zynq PS DDR3 path so that
// simulated CPI is representative of hardware. Note the architectural
// reality this models: on Zynq the DRAM controller proper is the PS hard
// block — FluxCore's side of that contract is mem_if_axi (P3.2). What a
// core-side "memory controller" actually contributes is scheduling against
// open rows, and that policy lives HERE, in the timing model the whole
// hierarchy is tuned against.
//
// Timing model (cycles, all parameterizable):
//   Bank/row mapping: bank = addr[BANK_LSB +: BANK_BITS] (line-interleaved
//   by default so consecutive lines hit different banks), row = the bits
//   above the column within the bank.
//   Latency to first beat of a read/write burst:
//     row HIT   (bank open on this row): tCAS
//     row EMPTY (bank closed)          : tRCD + tCAS
//     row MISS  (other row open)       : tRP + tRCD + tCAS
//   Open-page policy: the accessed row stays open (best case for streaming,
//   matches the PS controller's default behavior closely enough for CPI
//   work). Subsequent beats stream 1/cycle.
//   Refresh: every REFI cycles all banks are closed and the device is busy
//   for tRFC cycles; a request arriving mid-refresh waits.
//
// Defaults approximate DDR3-1066 timings scaled to a 50 MHz fabric clock
// crossing the PS HP port (round numbers chosen for readable tests, same
// order of magnitude as measured Zynq HP-port latencies: ~20-30 fabric
// cycles to first data).
//
// Concurrency: one transaction at a time (matches every other backend).

`timescale 1ns / 1ps
`default_nettype none

module dram_model
    import fluxcore_pkg::*;
    import mem_if_pkg::*;
#(
    parameter int unsigned MEM_WORDS = 65536,   // 256 KiB
    parameter int unsigned BANK_BITS = 3,       // 8 banks
    parameter int unsigned BANK_LSB  = 4,       // line-interleaved (16 B lines)
    parameter int unsigned ROW_BITS  = 10,
    parameter int unsigned T_CAS     = 6,
    parameter int unsigned T_RCD     = 6,
    parameter int unsigned T_RP      = 6,
    parameter int unsigned T_REFI    = 780,     // refresh interval
    parameter int unsigned T_RFC     = 16       // refresh busy time
)
(
    input  wire logic     clk,
    input  wire logic     rst,

    input  wire logic     req_valid_i,
    output logic          req_ready_o,
    input  wire mem_req_t req_i,
    output logic          rsp_valid_o,
    input  wire logic     rsp_ready_i,
    output mem_rsp_t      rsp_o,

    // Observability for tests / tuning
    output logic [31:0]   row_hits_o,
    output logic [31:0]   row_misses_o,
    output logic [31:0]   refreshes_o
);
    localparam int unsigned NBANKS = 1 << BANK_BITS;

    word_t mem [0:MEM_WORDS-1];
    initial for (int i = 0; i < MEM_WORDS; i++) mem[i] = '0;

    // Per-bank open row
    logic [ROW_BITS-1:0] open_row_q [0:NBANKS-1];
    logic                row_open_q [0:NBANKS-1];

    function automatic int unsigned bank_of(input word_t a);
        return (int'(a) >> BANK_LSB) & (NBANKS - 1);
    endfunction
    function automatic logic [ROW_BITS-1:0] row_of(input word_t a);
        // row bits sit above the bank field
        return (int'(a) >> (BANK_LSB + BANK_BITS)) & ((1 << ROW_BITS) - 1);
    endfunction
    function automatic int unsigned word_of(input word_t base, input int unsigned b);
        return (int'(base) >> 2) + b;
    endfunction

    localparam logic [1:0] S_IDLE = 2'd0;
    localparam logic [1:0] S_WAIT = 2'd1;
    localparam logic [1:0] S_RESP = 2'd2;

    logic [1:0]  state_q;
    mem_req_t    txn_q;
    int unsigned beat_q;      // response beat (read) / expected beat (write)
    int unsigned wait_q;
    int unsigned refi_q;      // countdown to next refresh
    int unsigned rfc_q;       // refresh busy countdown
    logic        wr_collect_q;  // still collecting write beats

    logic [31:0] row_hits_q, row_misses_q, refreshes_q;

    // Latency for the transaction now being accepted
    function automatic int unsigned open_latency(input word_t a);
        int unsigned b = bank_of(a);
        if (row_open_q[b] && open_row_q[b] == row_of(a)) return T_CAS;
        else if (!row_open_q[b])                         return T_RCD + T_CAS;
        else                                             return T_RP + T_RCD + T_CAS;
    endfunction

    assign req_ready_o = (rfc_q == 0)
                       && ((state_q == S_IDLE) || wr_collect_q);

    always_comb begin
        rsp_valid_o = 1'b0;
        rsp_o       = '0;
        if (state_q == S_RESP) begin
            rsp_valid_o = 1'b1;
            rsp_o.id    = txn_q.id;
            if (txn_q.op == MEM_READ) begin
                rsp_o.rdata = (word_of(txn_q.addr, beat_q) < MEM_WORDS)
                            ? mem[word_of(txn_q.addr, beat_q)] : '0;
                rsp_o.err   = (word_of(txn_q.addr, beat_q) < MEM_WORDS)
                            ? MEM_OK : MEM_DECERR;
                rsp_o.last  = (beat_q == mem_beats(txn_q.len) - 1);
            end else begin
                rsp_o.err  = MEM_OK;
                rsp_o.last = 1'b1;
            end
        end
    end

    // base passed explicitly: at beat 0 the header is still in req_i
    // (txn_q updates on the same edge — the same NBA trap mem_model hit).
    task automatic write_beat(input word_t base, input int unsigned b,
                              input logic [3:0] strb, input word_t d);
        if (word_of(base, b) < MEM_WORDS) begin
            if (strb[0]) mem[word_of(base, b)][ 7: 0] <= d[ 7: 0];
            if (strb[1]) mem[word_of(base, b)][15: 8] <= d[15: 8];
            if (strb[2]) mem[word_of(base, b)][23:16] <= d[23:16];
            if (strb[3]) mem[word_of(base, b)][31:24] <= d[31:24];
        end
    endtask

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= S_IDLE;
            beat_q  <= 0; wait_q <= 0;
            refi_q  <= T_REFI; rfc_q <= 0;
            wr_collect_q <= 1'b0;
            row_hits_q <= '0; row_misses_q <= '0; refreshes_q <= '0;
            for (int b = 0; b < NBANKS; b++) row_open_q[b] <= 1'b0;
        end else begin
            // ---- refresh engine (blocks new accepts, then closes banks) ----
            if (rfc_q > 0) begin
                rfc_q <= rfc_q - 1;
            end else if (refi_q == 0 && state_q == S_IDLE && !wr_collect_q) begin
                rfc_q  <= T_RFC;
                refi_q <= T_REFI;
                refreshes_q <= refreshes_q + 1;
                for (int b = 0; b < NBANKS; b++) row_open_q[b] <= 1'b0;
            end else if (refi_q > 0) begin
                refi_q <= refi_q - 1;
            end

            case (state_q)
                S_IDLE: begin
                    if (req_valid_i && req_ready_o && !wr_collect_q) begin
                        int unsigned lat;
                        txn_q <= req_i;
                        lat = open_latency(req_i.addr);
                        if (row_open_q[bank_of(req_i.addr)]
                            && open_row_q[bank_of(req_i.addr)] == row_of(req_i.addr))
                            row_hits_q <= row_hits_q + 1;
                        else
                            row_misses_q <= row_misses_q + 1;
                        // open the row (open-page policy)
                        row_open_q[bank_of(req_i.addr)] <= 1'b1;
                        open_row_q[bank_of(req_i.addr)] <= row_of(req_i.addr);

                        if (req_i.op == MEM_WRITE) begin
                            write_beat(req_i.addr, 0, req_i.strb, req_i.wdata);
                            beat_q       <= 1;
                            wr_collect_q <= (mem_beats(req_i.len) > 1);
                            if (mem_beats(req_i.len) == 1) begin
                                wait_q  <= lat;
                                state_q <= S_WAIT;
                            end
                            // else stay in IDLE-shape collecting (ready holds)
                        end else begin
                            beat_q  <= 0;
                            wait_q  <= lat;
                            state_q <= S_WAIT;
                        end
                    end else if (wr_collect_q && req_valid_i) begin
                        write_beat(txn_q.addr, beat_q, req_i.strb, req_i.wdata);
                        if (beat_q + 1 == mem_beats(txn_q.len)) begin
                            wr_collect_q <= 1'b0;
                            wait_q  <= open_latency(txn_q.addr);
                            state_q <= S_WAIT;
                        end else begin
                            beat_q <= beat_q + 1;
                        end
                    end
                end
                S_WAIT: begin
                    if (wait_q <= 1) begin
                        beat_q  <= (txn_q.op == MEM_READ) ? 0 : beat_q;
                        state_q <= S_RESP;
                    end else begin
                        wait_q <= wait_q - 1;
                    end
                end
                S_RESP: begin
                    if (rsp_ready_i) begin
                        if (txn_q.op == MEM_WRITE
                            || beat_q == mem_beats(txn_q.len) - 1)
                            state_q <= S_IDLE;
                        else
                            beat_q <= beat_q + 1;
                    end
                end
                default: state_q <= S_IDLE;
            endcase
        end
    end

    assign row_hits_o   = row_hits_q;
    assign row_misses_o = row_misses_q;
    assign refreshes_o  = refreshes_q;

endmodule : dram_model

`default_nettype wire
