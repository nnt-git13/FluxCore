// sim/memory/axi_slave_model.sv
//
// Behavioral AXI4 slave — SIMULATION ONLY, not synthesizable.
//
// Memory-backed AXI4 slave with configurable read latency, standing in for
// the Zynq PS HP-port DDR3 path so the whole cache→AXI chain runs in xsim
// with no hardware. Supports exactly what mem_if_axi emits:
//   - one outstanding transaction per direction (AR held off while a read
//     is in flight; AW/W accepted beat-by-beat, single B response);
//   - INCR bursts, 4-byte beats, up to 16 beats;
//   - RLAST/BRESP generated; DECERR returned for out-of-range addresses
//     (whole transaction, both directions) — the error path P2.4's policy
//     talks about, testable in sim for the first time.
//
// Latency model: LATENCY cycles from AR acceptance to the first R beat,
// GAP extra cycles between R beats. Writes ack immediately after WLAST.

`timescale 1ns / 1ps
`default_nettype none

module axi_slave_model
    import fluxcore_pkg::*;
#(
    parameter int unsigned MEM_WORDS = 16384,
    parameter int unsigned LATENCY   = 20,
    parameter int unsigned GAP       = 0
)
(
    input  wire logic        clk,
    input  wire logic        rst,

    // Write address
    input  wire logic        s_awvalid_i,
    output logic             s_awready_o,
    input  wire word_t       s_awaddr_i,
    input  wire logic [7:0]  s_awlen_i,
    input  wire logic [2:0]  s_awsize_i,
    input  wire logic [1:0]  s_awburst_i,
    input  wire logic [3:0]  s_awid_i,
    // Write data
    input  wire logic        s_wvalid_i,
    output logic             s_wready_o,
    input  wire word_t       s_wdata_i,
    input  wire logic [3:0]  s_wstrb_i,
    input  wire logic        s_wlast_i,
    // Write response
    output logic             s_bvalid_o,
    input  wire logic        s_bready_i,
    output logic [1:0]       s_bresp_o,
    output logic [3:0]       s_bid_o,
    // Read address
    input  wire logic        s_arvalid_i,
    output logic             s_arready_o,
    input  wire word_t       s_araddr_i,
    input  wire logic [7:0]  s_arlen_i,
    input  wire logic [2:0]  s_arsize_i,
    input  wire logic [1:0]  s_arburst_i,
    input  wire logic [3:0]  s_arid_i,
    // Read data
    output logic             s_rvalid_o,
    input  wire logic        s_rready_i,
    output word_t            s_rdata_o,
    output logic [1:0]       s_rresp_o,
    output logic             s_rlast_o,
    output logic [3:0]       s_rid_o
);

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_DECERR = 2'b11;

    word_t mem [0:MEM_WORDS-1];
    initial for (int i = 0; i < MEM_WORDS; i++) mem[i] = '0;

    function automatic int unsigned word_of(input word_t base,
                                            input int unsigned beat);
        return (int'(base) >> 2) + beat;
    endfunction

    // -----------------------------------------------------------------------
    // Read side
    // -----------------------------------------------------------------------
    localparam logic [1:0] R_IDLE = 2'd0;
    localparam logic [1:0] R_WAIT = 2'd1;
    localparam logic [1:0] R_DATA = 2'd2;

    logic [1:0]  rstate_q;
    word_t       raddr_q;
    logic [3:0]  rid_q;
    int unsigned rbeats_q, rbeat_q, rwait_q, rgap_q;

    assign s_arready_o = (rstate_q == R_IDLE);

    always_comb begin
        s_rvalid_o = 1'b0;
        s_rdata_o  = '0;
        s_rresp_o  = RESP_OKAY;
        s_rlast_o  = 1'b0;
        s_rid_o    = rid_q;
        if (rstate_q == R_DATA && rgap_q == 0) begin
            s_rvalid_o = 1'b1;
            if (word_of(raddr_q, rbeat_q) < MEM_WORDS) begin
                s_rdata_o = mem[word_of(raddr_q, rbeat_q)];
                s_rresp_o = RESP_OKAY;
            end else begin
                s_rdata_o = '0;
                s_rresp_o = RESP_DECERR;
            end
            s_rlast_o = (rbeat_q == rbeats_q - 1);
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            rstate_q <= R_IDLE;
            rbeat_q  <= 0; rbeats_q <= 0; rwait_q <= 0; rgap_q <= 0;
        end else begin
            case (rstate_q)
                R_IDLE: begin
                    if (s_arvalid_i) begin
                        raddr_q  <= s_araddr_i;
                        rid_q    <= s_arid_i;
                        rbeats_q <= int'(s_arlen_i) + 1;
                        rbeat_q  <= 0;
                        rgap_q   <= 0;
                        if (LATENCY <= 1) begin
                            rstate_q <= R_DATA;
                        end else begin
                            rwait_q  <= LATENCY - 1;
                            rstate_q <= R_WAIT;
                        end
                    end
                end
                R_WAIT: begin
                    if (rwait_q <= 1) rstate_q <= R_DATA;
                    else              rwait_q  <= rwait_q - 1;
                end
                R_DATA: begin
                    if (rgap_q != 0) begin
                        rgap_q <= rgap_q - 1;
                    end else if (s_rready_i) begin
                        if (rbeat_q == rbeats_q - 1) begin
                            rstate_q <= R_IDLE;
                        end else begin
                            rbeat_q <= rbeat_q + 1;
                            rgap_q  <= GAP;
                        end
                    end
                end
                default: rstate_q <= R_IDLE;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Write side — AW and W accepted independently; B after WLAST (and AW).
    // -----------------------------------------------------------------------
    logic        aw_got_q;
    word_t       waddr_q;
    logic [3:0]  wid_q;
    int unsigned wbeat_q;
    logic        wlast_got_q;
    logic        wr_oob_q;

    assign s_awready_o = !aw_got_q;
    assign s_wready_o  = !wlast_got_q;   // accept beats until WLAST taken
    assign s_bvalid_o  = aw_got_q && wlast_got_q;
    assign s_bresp_o   = wr_oob_q ? RESP_DECERR : RESP_OKAY;
    assign s_bid_o     = wid_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            aw_got_q    <= 1'b0;
            wlast_got_q <= 1'b0;
            wbeat_q     <= 0;
            wr_oob_q    <= 1'b0;
        end else begin
            if (s_awvalid_i && s_awready_o) begin
                waddr_q  <= s_awaddr_i;
                wid_q    <= s_awid_i;
                aw_got_q <= 1'b1;
                wbeat_q  <= 0;
                wr_oob_q <= 1'b0;
            end
            if (s_wvalid_i && s_wready_o) begin
                // NOTE: assumes AW arrives with or before the first W beat
                // (true for mem_if_axi, which offers them together).
                if (word_of(waddr_q_next(), wbeat_q) < MEM_WORDS) begin
                    if (s_wstrb_i[0]) mem[word_of(waddr_q_next(), wbeat_q)][ 7: 0] <= s_wdata_i[ 7: 0];
                    if (s_wstrb_i[1]) mem[word_of(waddr_q_next(), wbeat_q)][15: 8] <= s_wdata_i[15: 8];
                    if (s_wstrb_i[2]) mem[word_of(waddr_q_next(), wbeat_q)][23:16] <= s_wdata_i[23:16];
                    if (s_wstrb_i[3]) mem[word_of(waddr_q_next(), wbeat_q)][31:24] <= s_wdata_i[31:24];
                end else begin
                    wr_oob_q <= 1'b1;
                end
                wbeat_q <= wbeat_q + 1;
                if (s_wlast_i) wlast_got_q <= 1'b1;
            end
            if (s_bvalid_o && s_bready_i) begin
                aw_got_q    <= 1'b0;
                wlast_got_q <= 1'b0;
                wr_oob_q    <= 1'b0;
            end
        end
    end

    // AW and W beat 0 can land on the same edge; use the live AW address then.
    function automatic word_t waddr_q_next();
        return (s_awvalid_i && s_awready_o) ? s_awaddr_i : waddr_q;
    endfunction

endmodule : axi_slave_model

`default_nettype wire
