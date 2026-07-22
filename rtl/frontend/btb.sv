// rtl/frontend/btb.sv
//
// Branch target buffer + 2-bit bimodal counters — the fetch-side half of
// branch prediction.
//
// Direct-mapped, full-tag (no aliasing between different PCs: a hit means
// THIS pc was resolved taken at least once before). Lookup is combinational
// on the current fetch PC; taken_o = hit AND counter MSB, so entries decay
// toward not-taken and stop predicting after two consecutive not-takens.
//
// Update (from EX resolution, one branch/jump per cycle at most):
//   - resolved taken, entry present : counter saturating-up, target refreshed
//   - resolved taken, no entry      : allocate at weakly-taken (2'b10)
//   - resolved not-taken, present   : counter saturating-down
//   - resolved not-taken, absent    : no allocation (never predicts what has
//                                     never been taken)
// JAL and JALR update like branches (JAL is always-taken; JALR benefits when
// its target is stable — a mispredicted JALR target is caught by the EX
// verify like any other wrong prediction).
//
// flush_i clears every valid bit (FENCE.I: targets may name stale code).

`default_nettype none

module btb
    import fluxcore_pkg::*;
#(
    parameter int ENTRIES = 64
) (
    input  wire logic  clk,
    input  wire logic  rst,
    input  wire logic  flush_i,

    // Lookup (combinational, current fetch PC)
    input  wire word_t lookup_pc_i,
    output logic       pred_taken_o,
    output word_t      pred_target_o,

    // Update from EX resolution
    input  wire logic  upd_valid_i,
    input  wire word_t upd_pc_i,
    input  wire logic  upd_taken_i,
    input  wire word_t upd_target_i
);
    localparam int IDX_W = $clog2(ENTRIES);
    localparam int TAG_W = 32 - IDX_W - 2;

    logic             valid_q  [0:ENTRIES-1];
    logic [TAG_W-1:0] tag_q    [0:ENTRIES-1];
    word_t            target_q [0:ENTRIES-1];
    logic [1:0]       ctr_q    [0:ENTRIES-1];

    // ---- lookup ----
    logic [IDX_W-1:0] l_idx_s;
    logic [TAG_W-1:0] l_tag_s;
    logic             l_hit_s;
    assign l_idx_s = lookup_pc_i[IDX_W+1:2];
    assign l_tag_s = lookup_pc_i[31:IDX_W+2];
    assign l_hit_s = valid_q[l_idx_s] && (tag_q[l_idx_s] == l_tag_s);

    assign pred_taken_o  = l_hit_s && ctr_q[l_idx_s][1];
    assign pred_target_o = target_q[l_idx_s];

    // ---- update ----
    logic [IDX_W-1:0] u_idx_s;
    logic [TAG_W-1:0] u_tag_s;
    logic             u_hit_s;
    assign u_idx_s = upd_pc_i[IDX_W+1:2];
    assign u_tag_s = upd_pc_i[31:IDX_W+2];
    assign u_hit_s = valid_q[u_idx_s] && (tag_q[u_idx_s] == u_tag_s);

    always_ff @(posedge clk) begin
        if (rst || flush_i) begin
            for (int i = 0; i < ENTRIES; i++) valid_q[i] <= 1'b0;
        end else if (upd_valid_i) begin
            if (u_hit_s) begin
                if (upd_taken_i) begin
                    if (ctr_q[u_idx_s] != 2'b11)
                        ctr_q[u_idx_s] <= ctr_q[u_idx_s] + 2'd1;
                    target_q[u_idx_s] <= upd_target_i;   // keep target fresh
                end else begin
                    if (ctr_q[u_idx_s] != 2'b00)
                        ctr_q[u_idx_s] <= ctr_q[u_idx_s] - 2'd1;
                end
            end else if (upd_taken_i) begin
                valid_q[u_idx_s]  <= 1'b1;
                tag_q[u_idx_s]    <= u_tag_s;
                target_q[u_idx_s] <= upd_target_i;
                ctr_q[u_idx_s]    <= 2'b10;              // weakly taken
            end
        end
    end

endmodule : btb

`default_nettype wire
