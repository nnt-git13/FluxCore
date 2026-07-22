// rtl/memory/mem_if_bram.sv
//
// mem_if responder over a bram_dmem-style synchronous RAM — SYNTHESIZABLE.
//
// Bridges the frozen mem_if_pkg protocol to the raw BRAM pins (addr/wen/
// wstrb/wdata in, registered rdata out) with bare-BRAM response timing:
// a read request accepted at posedge N presents its first beat during cycle
// N+1 — exactly the latency the pipeline's MEM/WB contract was built on, so
// a dcache moved onto this adapter keeps its legacy cycle counts against a
// 1-cycle backing store.
//
// Capabilities (deliberately minimal — this is the bottom rung of the
// abstraction ladder in docs/interfaces/memory-interface-plan.md):
//   - one transaction at a time (req_ready_o low while busy);
//   - read bursts up to MEM_MAX_BEATS: one beat per cycle, back-to-back,
//     rsp beats stall (and re-present) when rsp_ready_i is low;
//   - write transactions: one req transfer per beat, committed to the BRAM
//     as they arrive, then a single MEM_OK response beat;
//   - no error responses: a bare BRAM cannot fault, and address decode is
//     the soc_bus's job. (MEM_DECERR/MEM_SLVERR arrive with the AXI path.)
//
// The BRAM side matches bram_dmem's ports 1:1 — instantiate this next to a
// bram_dmem and wire straight across.

`default_nettype none

module mem_if_bram
    import fluxcore_pkg::*;
    import mem_if_pkg::*;
(
    input  wire logic     clk,
    input  wire logic     rst,

    // mem_if responder side
    input  wire logic     req_valid_i,
    output logic          req_ready_o,
    input  wire mem_req_t req_i,
    output logic          rsp_valid_o,
    input  wire logic     rsp_ready_i,
    output mem_rsp_t      rsp_o,

    // BRAM side (wire to bram_dmem)
    output word_t         bram_addr_o,
    output logic          bram_wen_o,
    output logic [3:0]    bram_wstrb_o,
    output word_t         bram_wdata_o,
    input  wire word_t    bram_rdata_i
);

    // FSM: IDLE accepts a request. Reads issue beat addresses back-to-back
    // (RDBEATS) and present each returned word (data for the address issued
    // at posedge k is on bram_rdata_i during cycle k+1). Writes collect
    // beats (WRBEATS) then emit one ack beat (WRACK).
    localparam logic [1:0] S_IDLE    = 2'd0;
    localparam logic [1:0] S_RDBEATS = 2'd1;
    localparam logic [1:0] S_WRBEATS = 2'd2;
    localparam logic [1:0] S_WRACK   = 2'd3;

    logic [1:0]  state_q;
    mem_req_t    txn_q;         // request head
    int unsigned issue_q;       // next read beat index to put on the address bus
    int unsigned serve_q;       // read beat index currently on bram_rdata_i
    int unsigned wbeat_q;       // next write beat index expected

    logic last_serve_s;
    assign last_serve_s = (serve_q == mem_beats(txn_q.len) - 1);

    // -----------------------------------------------------------------------
    // Combinational: handshake + BRAM drive
    // -----------------------------------------------------------------------
    always_comb begin
        req_ready_o  = (state_q == S_IDLE) || (state_q == S_WRBEATS);
        rsp_valid_o  = 1'b0;
        rsp_o        = '0;
        bram_addr_o  = req_i.addr;
        bram_wen_o   = 1'b0;
        bram_wstrb_o = req_i.strb;
        bram_wdata_o = req_i.wdata;

        case (state_q)
            S_IDLE: begin
                if (req_valid_i) begin
                    if (req_i.op == MEM_WRITE) begin
                        // Beat 0 commits right now.
                        bram_addr_o = req_i.addr;
                        bram_wen_o  = 1'b1;
                    end else begin
                        // Register beat-0 address this edge; data next cycle.
                        bram_addr_o = req_i.addr;
                    end
                end
            end
            S_RDBEATS: begin
                // Serve beat serve_q (on bram_rdata_i now); keep the address
                // bus one beat ahead unless the consumer is stalling us, in
                // which case re-register the CURRENT beat's address so its
                // data is still there next cycle.
                rsp_valid_o = 1'b1;
                rsp_o.id    = txn_q.id;
                rsp_o.rdata = bram_rdata_i;
                rsp_o.err   = MEM_OK;
                rsp_o.last  = last_serve_s;
                if (rsp_ready_i)
                    bram_addr_o = mem_beat_addr(txn_q.addr,
                                                (issue_q < mem_beats(txn_q.len))
                                                ? issue_q
                                                : mem_beats(txn_q.len) - 1);
                else
                    bram_addr_o = mem_beat_addr(txn_q.addr, serve_q);
            end
            S_WRBEATS: begin
                // Subsequent write beats commit as they arrive.
                if (req_valid_i) begin
                    bram_addr_o = mem_beat_addr(txn_q.addr, wbeat_q);
                    bram_wen_o  = 1'b1;
                end
            end
            S_WRACK: begin
                rsp_valid_o = 1'b1;
                rsp_o.id    = txn_q.id;
                rsp_o.rdata = '0;
                rsp_o.err   = MEM_OK;
                rsp_o.last  = 1'b1;
            end
            default: ;
        endcase
    end

    // -----------------------------------------------------------------------
    // Sequential
    // -----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= S_IDLE;
            issue_q <= 0;
            serve_q <= 0;
            wbeat_q <= 0;
        end else begin
            case (state_q)
                S_IDLE: begin
                    if (req_valid_i) begin
                        txn_q <= req_i;
                        if (req_i.op == MEM_WRITE) begin
                            wbeat_q <= 1;
                            state_q <= (mem_beats(req_i.len) > 1) ? S_WRBEATS
                                                                  : S_WRACK;
                        end else begin
                            issue_q <= 1;   // beat 0 address registered now
                            serve_q <= 0;
                            state_q <= S_RDBEATS;
                        end
                    end
                end
                S_RDBEATS: begin
                    if (rsp_ready_i) begin
                        if (last_serve_s) begin
                            state_q <= S_IDLE;
                        end else begin
                            serve_q <= serve_q + 1;
                            if (issue_q < mem_beats(txn_q.len))
                                issue_q <= issue_q + 1;
                        end
                    end
                end
                S_WRBEATS: begin
                    if (req_valid_i) begin
                        if (wbeat_q == mem_beats(txn_q.len) - 1)
                            state_q <= S_WRACK;
                        else
                            wbeat_q <= wbeat_q + 1;
                    end
                end
                S_WRACK: begin
                    if (rsp_ready_i)
                        state_q <= S_IDLE;
                end
                default: state_q <= S_IDLE;
            endcase
        end
    end

endmodule : mem_if_bram

`default_nettype wire
