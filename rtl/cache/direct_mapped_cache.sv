// rtl/cache/direct_mapped_cache.sv
//
// Direct-mapped write-through cache for future FluxCore memory front-ends.
//
// This module is intentionally not wired into the current BRAM-only SoC. It is
// a compact cache primitive for the later request/response memory interface:
//
//   * One-cycle registered response for hits.
//   * Read-allocate on load misses.
//   * Write-through with no-write-allocate on store misses.
//   * One-entry write buffer so cacheable store hits can update the cache and
//     retire locally while the external write drains afterward.
//   * One outstanding refill request at a time; line fills stream one 32-bit
//     word per backend response.
//
// Backend contract:
//   * mem_req_* is a ready/valid request channel.
//   * Reads return exactly one mem_resp_valid_i pulse with mem_resp_rdata_i.
//   * Writes are accepted when mem_req_valid_o && mem_req_ready_i; no write
//     response is required.
//
// Design limits:
//   * SETS must be a power of two.
//   * LINE_WORDS is fixed at 4 for this inference-friendly implementation.
//   * Addresses are byte addresses. Backend read/write requests are word
//     aligned; stores carry byte strobes.

`default_nettype none

module direct_mapped_cache
    import fluxcore_pkg::*;
#(
    parameter int unsigned SETS       = 64,
    parameter int unsigned LINE_WORDS = 4
) (
    input  wire logic clk,
    input  wire logic rst,

    // CPU-side request
    input  wire logic  req_valid_i,
    output logic       req_ready_o,
    input  wire logic  req_write_i,
    input  wire addr_t req_addr_i,
    input  wire word_t req_wdata_i,
    input  wire logic [XLEN/8-1:0] req_wstrb_i,

    // CPU-side response. Stores produce a response when accepted locally.
    output logic resp_valid_o,
    output word_t resp_rdata_o,
    output logic resp_hit_o,

    // Backend request
    output logic  mem_req_valid_o,
    input  wire logic  mem_req_ready_i,
    output logic  mem_req_write_o,
    output addr_t mem_req_addr_o,
    output word_t mem_req_wdata_o,
    output logic [XLEN/8-1:0] mem_req_wstrb_o,

    // Backend read response
    input  wire logic  mem_resp_valid_i,
    input  wire word_t mem_resp_rdata_i
);

    localparam int unsigned BYTE_OFF_W = 2;
    localparam int unsigned WORD_OFF_W = $clog2(LINE_WORDS);
    localparam int unsigned INDEX_W    = $clog2(SETS);
    localparam int unsigned INDEX_LSB  = BYTE_OFF_W + WORD_OFF_W;
    localparam int unsigned TAG_LSB    = INDEX_LSB + INDEX_W;
    localparam int unsigned TAG_W      = XLEN - TAG_LSB;

    typedef logic [TAG_W-1:0]      tag_t;
    typedef logic [INDEX_W-1:0]    index_t;
    typedef logic [WORD_OFF_W-1:0] word_off_t;

    typedef enum logic [1:0] {
        STATE_IDLE,
        STATE_MISS_REQ,
        STATE_MISS_WAIT
    } state_e;

    state_e state_q;

    (* ram_style = "distributed" *) word_t data_word0_q [0:SETS-1];
    (* ram_style = "distributed" *) word_t data_word1_q [0:SETS-1];
    (* ram_style = "distributed" *) word_t data_word2_q [0:SETS-1];
    (* ram_style = "distributed" *) word_t data_word3_q [0:SETS-1];
    (* ram_style = "distributed" *) tag_t  tag_q        [0:SETS-1];
    logic  valid_q [0:SETS-1];

    addr_t     miss_addr_q;
    tag_t      miss_tag_q;
    index_t    miss_index_q;
    word_off_t miss_word_q;
    word_off_t fill_word_q;

    logic  wb_valid_q;
    addr_t wb_addr_q;
    word_t wb_data_q;
    logic [XLEN/8-1:0] wb_wstrb_q;

    tag_t      req_tag_s;
    index_t    req_index_s;
    word_off_t req_word_s;
    logic      req_hit_s;
    word_t     req_cached_word_s;
    word_t     req_store_word_s;
    logic      req_read_miss_s;
    logic      req_accept_s;
    addr_t     refill_base_addr_s;
    addr_t     refill_addr_s;
    word_t     miss_cached_word_s;

    always_comb begin
        unique case (req_word_s)
            2'd0:    req_cached_word_s = data_word0_q[req_index_s];
            2'd1:    req_cached_word_s = data_word1_q[req_index_s];
            2'd2:    req_cached_word_s = data_word2_q[req_index_s];
            default: req_cached_word_s = data_word3_q[req_index_s];
        endcase
    end

    always_comb begin
        unique case (miss_word_q)
            2'd0:    miss_cached_word_s = data_word0_q[miss_index_q];
            2'd1:    miss_cached_word_s = data_word1_q[miss_index_q];
            2'd2:    miss_cached_word_s = data_word2_q[miss_index_q];
            default: miss_cached_word_s = data_word3_q[miss_index_q];
        endcase
    end

    assign req_tag_s         = req_addr_i[XLEN-1:TAG_LSB];
    assign req_index_s       = req_addr_i[INDEX_LSB +: INDEX_W];
    assign req_word_s        = req_addr_i[BYTE_OFF_W +: WORD_OFF_W];
    assign req_hit_s         = valid_q[req_index_s] && (tag_q[req_index_s] == req_tag_s);
    assign req_read_miss_s   = req_valid_i && !req_write_i && !req_hit_s;

    assign refill_base_addr_s = {miss_addr_q[XLEN-1:TAG_LSB], miss_index_q, {WORD_OFF_W{1'b0}}, 2'b00};
    assign refill_addr_s      = refill_base_addr_s + (addr_t'(fill_word_q) << BYTE_OFF_W);

    function automatic word_t merge_store_word(
        input word_t old_word,
        input word_t store_word,
        input logic [XLEN/8-1:0] store_strobe
    );
        word_t merged;
        begin
            merged = old_word;
            for (int unsigned i = 0; i < XLEN/8; i++) begin
                if (store_strobe[i])
                    merged[i*8 +: 8] = store_word[i*8 +: 8];
            end
            return merged;
        end
    endfunction

    assign req_store_word_s = merge_store_word(req_cached_word_s, req_wdata_i, req_wstrb_i);

    always_comb begin
        req_ready_o = 1'b0;

        if (state_q == STATE_IDLE) begin
            if (!req_valid_i) begin
                req_ready_o = 1'b1;
            end else if (req_write_i) begin
                req_ready_o = !wb_valid_q;
            end else if (req_hit_s) begin
                req_ready_o = 1'b1;
            end else begin
                req_ready_o = !wb_valid_q;
            end
        end
    end

    assign req_accept_s = req_valid_i && req_ready_o;

    always_comb begin
        mem_req_valid_o = 1'b0;
        mem_req_write_o = 1'b0;
        mem_req_addr_o  = '0;
        mem_req_wdata_o = '0;
        mem_req_wstrb_o = '0;

        unique case (state_q)
            STATE_IDLE: begin
                if (wb_valid_q && !(req_valid_i && req_ready_o)) begin
                    mem_req_valid_o = 1'b1;
                    mem_req_write_o = 1'b1;
                    mem_req_addr_o  = {wb_addr_q[XLEN-1:2], 2'b00};
                    mem_req_wdata_o = wb_data_q;
                    mem_req_wstrb_o = wb_wstrb_q;
                end
            end

            STATE_MISS_REQ: begin
                mem_req_valid_o = 1'b1;
                mem_req_write_o = 1'b0;
                mem_req_addr_o  = refill_addr_s;
            end

            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q       <= STATE_IDLE;
            resp_valid_o  <= 1'b0;
            resp_rdata_o  <= '0;
            resp_hit_o    <= 1'b0;
            miss_addr_q   <= '0;
            miss_tag_q    <= '0;
            miss_index_q  <= '0;
            miss_word_q   <= '0;
            fill_word_q   <= '0;
            wb_valid_q    <= 1'b0;
            wb_addr_q     <= '0;
            wb_data_q     <= '0;
            wb_wstrb_q    <= '0;
            for (int unsigned set_i = 0; set_i < SETS; set_i++) begin
                valid_q[set_i] <= 1'b0;
            end
        end else begin
            resp_valid_o <= 1'b0;
            resp_hit_o   <= 1'b0;

            unique case (state_q)
                STATE_IDLE: begin
                    if (req_accept_s) begin
                        if (req_write_i) begin
                            if (req_hit_s) begin
                                unique case (req_word_s)
                                    2'd0:    data_word0_q[req_index_s] <= req_store_word_s;
                                    2'd1:    data_word1_q[req_index_s] <= req_store_word_s;
                                    2'd2:    data_word2_q[req_index_s] <= req_store_word_s;
                                    default: data_word3_q[req_index_s] <= req_store_word_s;
                                endcase
                            end

                            wb_valid_q   <= 1'b1;
                            wb_addr_q    <= req_addr_i;
                            wb_data_q    <= req_wdata_i;
                            wb_wstrb_q   <= req_wstrb_i;
                            resp_valid_o <= 1'b1;
                            resp_rdata_o <= '0;
                            resp_hit_o   <= req_hit_s;

                        end else if (req_hit_s) begin
                            resp_valid_o <= 1'b1;
                            resp_rdata_o <= req_cached_word_s;
                            resp_hit_o   <= 1'b1;

                        end else begin
                            miss_addr_q  <= req_addr_i;
                            miss_tag_q   <= req_tag_s;
                            miss_index_q <= req_index_s;
                            miss_word_q  <= req_word_s;
                            fill_word_q  <= '0;
                            state_q      <= STATE_MISS_REQ;
                        end
                    end else if (wb_valid_q && mem_req_ready_i) begin
                        wb_valid_q <= 1'b0;
                    end
                end

                STATE_MISS_REQ: begin
                    if (mem_req_ready_i)
                        state_q <= STATE_MISS_WAIT;
                end

                STATE_MISS_WAIT: begin
                    if (mem_resp_valid_i) begin
                        unique case (fill_word_q)
                            2'd0:    data_word0_q[miss_index_q] <= mem_resp_rdata_i;
                            2'd1:    data_word1_q[miss_index_q] <= mem_resp_rdata_i;
                            2'd2:    data_word2_q[miss_index_q] <= mem_resp_rdata_i;
                            default: data_word3_q[miss_index_q] <= mem_resp_rdata_i;
                        endcase

                        if (fill_word_q == LINE_WORDS - 1) begin
                            valid_q[miss_index_q] <= 1'b1;
                            tag_q[miss_index_q]   <= miss_tag_q;
                            state_q               <= STATE_IDLE;
                            resp_valid_o          <= 1'b1;
                            resp_hit_o            <= 1'b0;
                            if (miss_word_q == fill_word_q)
                                resp_rdata_o <= mem_resp_rdata_i;
                            else
                                resp_rdata_o <= miss_cached_word_s;
                        end else begin
                            fill_word_q <= fill_word_q + 1'b1;
                            state_q     <= STATE_MISS_REQ;
                        end
                    end
                end

                default: state_q <= STATE_IDLE;
            endcase
        end
    end

endmodule : direct_mapped_cache

`default_nettype wire
