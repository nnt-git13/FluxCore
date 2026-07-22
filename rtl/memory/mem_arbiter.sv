// rtl/memory/mem_arbiter.sv
//
// Two-requester mem_if arbiter — SYNTHESIZABLE.
//
// Muxes two mem_if requesters (port 0 = D-cache, port 1 = I-cache when P5
// lands) onto one responder (the L2). Grant is TRANSACTION-granular: once a
// requester's first transfer is accepted, the arbiter routes its request
// beats (a write burst is several transfers) and its response beats until
// the response's `last`, then re-arbitrates round-robin. Transaction
// granularity is required, not a nicety — interleaving two write bursts
// downstream would corrupt both (the responder tracks one header).
//
// The non-granted port sees req_ready=0 and no rsp_valid. IDs pass through
// untouched: requesters already use disjoint id spaces (the L1 uses 0/1,
// the L2's own downstream traffic 8/9), and with one transaction in flight
// per port there is no aliasing to resolve.

`default_nettype none

module mem_arbiter
    import mem_if_pkg::*;
(
    input  wire logic     clk,
    input  wire logic     rst,

    // Requester port 0 (D-cache — wins ties from reset)
    input  wire logic     r0_req_valid_i,
    output logic          r0_req_ready_o,
    input  wire mem_req_t r0_req_i,
    output logic          r0_rsp_valid_o,
    input  wire logic     r0_rsp_ready_i,
    output mem_rsp_t      r0_rsp_o,

    // Requester port 1 (I-cache)
    input  wire logic     r1_req_valid_i,
    output logic          r1_req_ready_o,
    input  wire mem_req_t r1_req_i,
    output logic          r1_rsp_valid_o,
    input  wire logic     r1_rsp_ready_i,
    output mem_rsp_t      r1_rsp_o,

    // Responder side (the L2 / backing store)
    output logic          m_req_valid_o,
    input  wire logic     m_req_ready_i,
    output mem_req_t      m_req_o,
    input  wire logic     m_rsp_valid_i,
    output logic          m_rsp_ready_o,
    input  wire mem_rsp_t m_rsp_i
);

    logic        busy_q;      // a transaction is in flight
    logic        grant_q;     // which port owns it (0/1)
    logic        rr_q;        // round-robin pointer: who wins the next tie
    int unsigned req_left_q;  // request transfers still to route
    logic        sel_s;       // selected port this cycle
    logic        start_s;     // a new transaction starts this cycle

    // Selection: hold the grant while busy; otherwise pick a requester,
    // rr_q breaking ties.
    always_comb begin
        sel_s   = grant_q;
        start_s = 1'b0;
        if (!busy_q) begin
            if (r0_req_valid_i && r1_req_valid_i)      sel_s = rr_q;
            else if (r1_req_valid_i)                   sel_s = 1'b1;
            else                                       sel_s = 1'b0;
            start_s = (r0_req_valid_i || r1_req_valid_i);
        end
    end

    // Request-channel routing. The request phase is open while transfers
    // remain (req_left tracks them: reads have 1, writes beats(len)).
    logic req_phase_s;
    assign req_phase_s = start_s || (busy_q && req_left_q > 0);

    always_comb begin
        m_req_valid_o  = 1'b0;
        m_req_o        = r0_req_i;
        r0_req_ready_o = 1'b0;
        r1_req_ready_o = 1'b0;
        if (req_phase_s) begin
            if (sel_s == 1'b0) begin
                m_req_valid_o  = r0_req_valid_i;
                m_req_o        = r0_req_i;
                r0_req_ready_o = m_req_ready_i;
            end else begin
                m_req_valid_o  = r1_req_valid_i;
                m_req_o        = r1_req_i;
                r1_req_ready_o = m_req_ready_i;
            end
        end
    end

    // Response-channel routing to the granted port.
    always_comb begin
        r0_rsp_valid_o = 1'b0;
        r1_rsp_valid_o = 1'b0;
        r0_rsp_o       = m_rsp_i;
        r1_rsp_o       = m_rsp_i;
        m_rsp_ready_o  = 1'b0;
        if (busy_q) begin
            if (grant_q == 1'b0) begin
                r0_rsp_valid_o = m_rsp_valid_i;
                m_rsp_ready_o  = r0_rsp_ready_i;
            end else begin
                r1_rsp_valid_o = m_rsp_valid_i;
                m_rsp_ready_o  = r1_rsp_ready_i;
            end
        end
    end

    logic req_fire_s, rsp_done_s;
    assign req_fire_s = m_req_valid_o && m_req_ready_i;
    assign rsp_done_s = m_rsp_valid_i && m_rsp_ready_o && m_rsp_i.last;

    always_ff @(posedge clk) begin
        if (rst) begin
            busy_q     <= 1'b0;
            grant_q    <= 1'b0;
            rr_q       <= 1'b0;
            req_left_q <= 0;
        end else begin
            if (!busy_q) begin
                if (start_s && req_fire_s) begin
                    busy_q  <= 1'b1;
                    grant_q <= sel_s;
                    // Remaining request transfers after this first one.
                    req_left_q <= (m_req_o.op == MEM_WRITE)
                                ? mem_beats(m_req_o.len) - 1
                                : 0;
                end
            end else begin
                if (req_fire_s && req_left_q > 0)
                    req_left_q <= req_left_q - 1;
                if (rsp_done_s) begin
                    busy_q <= 1'b0;
                    rr_q   <= ~grant_q;   // loser gets the next tie
                end
            end
        end
    end

endmodule : mem_arbiter

`default_nettype wire
