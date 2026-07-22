// rtl/memory/mem_if_axi.sv
//
// mem_if requester-to-AXI4-master adapter — SYNTHESIZABLE.
//
// Bridges the frozen mem_if_pkg protocol to an AXI4 master port (the shape
// of a Zynq PS HP slave port). The mapping is deliberately 1:1:
//   req.op=READ   → AR (ARLEN = req.len, ARSIZE = 4 bytes, INCR)
//                 ← R  beats become rsp beats verbatim (RRESP = rsp.err,
//                      RLAST = rsp.last, RID = rsp.id)
//   req.op=WRITE  → AW (once per transaction) + one W beat per req beat
//                 ← B  becomes the single write-ack rsp beat
// mem_err_e was chosen to equal AXI RRESP/BRESP encodings (mem_if_pkg), so
// error mapping is a wire, not a table.
//
// Concurrency: ONE outstanding transaction. req_ready_o drops from the
// first accepted beat until the response completes (B delivered / last R
// consumed). This serializes the shared rsp channel so B-acks and R-beats
// can never collide, and matches the single-outstanding behavior of every
// other backend (mem_if_bram, mem_model) — the L1's FSM is built on it.
// Multiple outstanding transactions arrive with the L2 (P4), which owns
// reordering.

`default_nettype none

module mem_if_axi
    import fluxcore_pkg::*;
    import mem_if_pkg::*;
(
    input  wire logic        clk,
    input  wire logic        rst,

    // mem_if responder side (faces the cache)
    input  wire logic        req_valid_i,
    output logic             req_ready_o,
    input  wire mem_req_t    req_i,
    output logic             rsp_valid_o,
    input  wire logic        rsp_ready_i,
    output mem_rsp_t         rsp_o,

    // AXI4 master side
    // Write address
    output logic             m_awvalid_o,
    input  wire logic        m_awready_i,
    output word_t            m_awaddr_o,
    output logic [7:0]       m_awlen_o,
    output logic [2:0]       m_awsize_o,
    output logic [1:0]       m_awburst_o,
    output logic [3:0]       m_awid_o,
    // Write data
    output logic             m_wvalid_o,
    input  wire logic        m_wready_i,
    output word_t            m_wdata_o,
    output logic [3:0]       m_wstrb_o,
    output logic             m_wlast_o,
    // Write response
    input  wire logic        m_bvalid_i,
    output logic             m_bready_o,
    input  wire logic [1:0]  m_bresp_i,
    input  wire logic [3:0]  m_bid_i,
    // Read address
    output logic             m_arvalid_o,
    input  wire logic        m_arready_i,
    output word_t            m_araddr_o,
    output logic [7:0]       m_arlen_o,
    output logic [2:0]       m_arsize_o,
    output logic [1:0]       m_arburst_o,
    output logic [3:0]       m_arid_o,
    // Read data
    input  wire logic        m_rvalid_i,
    output logic             m_rready_o,
    input  wire word_t       m_rdata_i,
    input  wire logic [1:0]  m_rresp_i,
    input  wire logic        m_rlast_i,
    input  wire logic [3:0]  m_rid_i
);

    localparam logic [1:0] AXI_INCR = 2'b01;
    localparam logic [2:0] SIZE_4B  = 3'b010;

    // FSM
    localparam logic [1:0] S_IDLE  = 2'd0;
    localparam logic [1:0] S_WRITE = 2'd1;  // streaming W beats (AW may lag)
    localparam logic [1:0] S_BWAIT = 2'd2;  // W done; deliver B as the ack
    localparam logic [1:0] S_READ  = 2'd3;  // R beats stream to rsp

    logic [1:0]  state_q;
    mem_req_t    txn_q;
    logic        aw_done_q;    // AW handshake completed
    int unsigned wbeat_q;      // beats accepted from the requester so far

    logic aw_fire_s, w_fire_s, wlast_s;
    assign aw_fire_s = m_awvalid_o && m_awready_i;
    assign w_fire_s  = m_wvalid_o  && m_wready_i;

    always_comb begin
        req_ready_o = 1'b0;
        rsp_valid_o = 1'b0;
        rsp_o       = '0;

        m_awvalid_o = 1'b0;
        m_awaddr_o  = txn_q.addr;
        m_awlen_o   = {4'b0, txn_q.len};
        m_awsize_o  = SIZE_4B;
        m_awburst_o = AXI_INCR;
        m_awid_o    = txn_q.id;

        m_wvalid_o  = 1'b0;
        m_wdata_o   = req_i.wdata;
        m_wstrb_o   = req_i.strb;
        m_wlast_o   = 1'b0;
        m_bready_o  = 1'b0;

        m_arvalid_o = 1'b0;
        m_araddr_o  = req_i.addr;
        m_arlen_o   = {4'b0, req_i.len};
        m_arsize_o  = SIZE_4B;
        m_arburst_o = AXI_INCR;
        m_arid_o    = req_i.id;

        wlast_s = 1'b0;

        case (state_q)
            S_IDLE: begin
                if (req_valid_i) begin
                    if (req_i.op == MEM_READ) begin
                        // AR carries the whole burst; accept the (single)
                        // request transfer when AR is accepted.
                        m_arvalid_o = 1'b1;
                        req_ready_o = m_arready_i;
                    end else begin
                        // AW + first W beat issued together; the requester's
                        // beat is consumed when the W transfer completes.
                        // (AW uses live req fields here: txn_q not yet set.)
                        m_awvalid_o = 1'b1;
                        m_awaddr_o  = req_i.addr;
                        m_awlen_o   = {4'b0, req_i.len};
                        m_awid_o    = req_i.id;
                        m_wvalid_o  = 1'b1;
                        m_wlast_o   = (mem_beats(req_i.len) == 1);
                        wlast_s     = m_wlast_o;
                        // Beat 0 needs W accepted; AW may complete now or
                        // later (aw_done_q tracks it).
                        req_ready_o = m_wready_i;
                    end
                end
            end
            S_WRITE: begin
                m_awvalid_o = !aw_done_q;   // keep offering AW until taken
                if (req_valid_i) begin
                    m_wvalid_o  = 1'b1;
                    m_wlast_o   = (wbeat_q == mem_beats(txn_q.len) - 1);
                    wlast_s     = m_wlast_o;
                    req_ready_o = m_wready_i;
                end
            end
            S_BWAIT: begin
                m_awvalid_o = !aw_done_q;
                // Forward B as the transaction's single ack beat only once
                // AW has completed (a B cannot legally precede it anyway).
                if (aw_done_q && m_bvalid_i) begin
                    rsp_valid_o = 1'b1;
                    rsp_o.id    = m_bid_i;
                    rsp_o.rdata = '0;
                    rsp_o.err   = mem_err_e'(m_bresp_i);
                    rsp_o.last  = 1'b1;
                    m_bready_o  = rsp_ready_i;
                end
            end
            S_READ: begin
                // R beats stream straight through.
                rsp_valid_o = m_rvalid_i;
                rsp_o.id    = m_rid_i;
                rsp_o.rdata = m_rdata_i;
                rsp_o.err   = mem_err_e'(m_rresp_i);
                rsp_o.last  = m_rlast_i;
                m_rready_o  = rsp_ready_i;
            end
            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q   <= S_IDLE;
            aw_done_q <= 1'b0;
            wbeat_q   <= 0;
        end else begin
            case (state_q)
                S_IDLE: begin
                    if (req_valid_i) begin
                        txn_q <= req_i;
                        if (req_i.op == MEM_READ) begin
                            if (m_arready_i)
                                state_q <= S_READ;
                        end else begin
                            aw_done_q <= aw_fire_s;
                            if (w_fire_s) begin
                                wbeat_q <= 1;
                                state_q <= wlast_s ? S_BWAIT : S_WRITE;
                            end
                        end
                    end
                end
                S_WRITE: begin
                    if (aw_fire_s) aw_done_q <= 1'b1;
                    if (w_fire_s) begin
                        wbeat_q <= wbeat_q + 1;
                        if (wlast_s) state_q <= S_BWAIT;
                    end
                end
                S_BWAIT: begin
                    if (aw_fire_s) aw_done_q <= 1'b1;
                    if (aw_done_q && m_bvalid_i && rsp_ready_i) begin
                        state_q   <= S_IDLE;
                        aw_done_q <= 1'b0;
                    end
                end
                S_READ: begin
                    if (m_rvalid_i && rsp_ready_i && m_rlast_i)
                        state_q <= S_IDLE;
                end
                default: state_q <= S_IDLE;
            endcase
        end
    end

endmodule : mem_if_axi

`default_nettype wire
