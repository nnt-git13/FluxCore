// rtl/cache/dcache.sv
//
// Direct-mapped write-through data cache — BRAM-compatible stall interface.
//
// This module is the integration shim between fluxcore_top's dmem_* ports and
// a backing bram_dmem. It presents the same 1-cycle latency as a bare BRAM on
// hits, and adds exactly 1 stall cycle on read misses (one BRAM round-trip).
//
// Timing (matches existing BRAM pipeline contract):
//
//   Hit path (no stall added):
//     Cycle N (MEM): cpu_ren_i=1, hit_s=1 — cache data registered at posedge N.
//     Cycle N+1 (WB): cpu_rdata_o = cache data ← wb_stage reads this live. ✓
//
//   Miss path (1 stall cycle):
//     Cycle N (MEM): cpu_ren_i=1, hit_s=0 — dmem_stall_o=1; BRAM read issued.
//       posedge N: state → FILL; BRAM registers miss address.
//     Cycle N+1 (FILL): BRAM presents miss data on mem_rdata_i; dmem_stall_o=0.
//       posedge N+1: cpu_rdata_q ← mem_rdata_i; cache line refilled; state → IDLE.
//     Cycle N+2 (WB): cpu_rdata_o = cpu_rdata_q = miss data ← wb_stage reads live. ✓
//
//   In FILL the module drives mem_addr_o = miss_addr_q (the saved miss address)
//   so the backing BRAM re-registers the same address at posedge N+1. This keeps
//   mem_rdata_i stable with miss data in cycle N+2 — harmless since wb_stage
//   reads cpu_rdata_o (the registered capture), not mem_rdata_i directly.
//
// Write policy:
//   Write-through, no-write-allocate.
//   Stores always forward to backing memory via mem_wen_o/mem_wstrb_o/mem_wdata_o.
//   On a store hit the cache line is also updated. Store misses skip cache fill.
//   Stores never assert dmem_stall_o.
//
// Hit/miss counters:
//   hit_count_o and miss_count_o accumulate on every read request; overflow wraps.
//   Connect these to mcycle-class CSRs or ILA for CPI measurement.
//
// Parameters:
//   NSETS — number of direct-mapped cache lines. Must be a power of two.
//           Each line holds one 32-bit word (no spatial locality in this baseline).
//           Default 64 → 256 B capacity.

`default_nettype none

module dcache
#(
    parameter int NSETS = 64
) (
    input  wire logic        clk,
    input  wire logic        rst,

    // CPU-side (connects to fluxcore_top dmem_* ports)
    input  wire logic [31:0] cpu_addr_i,
    input  wire logic        cpu_ren_i,     // load in MEM stage
    input  wire logic        cpu_wen_i,     // store in MEM stage
    input  wire logic [3:0]  cpu_wstrb_i,
    input  wire logic [31:0] cpu_wdata_i,
    output logic [31:0]      cpu_rdata_o,   // load data, valid in WB cycle
    output logic             dmem_stall_o,  // read miss: stall pipeline this cycle

    // Backing BRAM-side
    output logic [31:0]      mem_addr_o,
    output logic             mem_ren_o,     // ignored by bram_dmem but useful for debug
    output logic             mem_wen_o,
    output logic [3:0]       mem_wstrb_o,
    output logic [31:0]      mem_wdata_o,
    input  wire  logic [31:0] mem_rdata_i,

    // Hit/miss counters (32-bit wrapping)
    output logic [31:0]      hit_count_o,
    output logic [31:0]      miss_count_o
);
    localparam int INDEX_W = $clog2(NSETS);
    localparam int TAG_W   = 32 - INDEX_W - 2;  // 2 byte-offset bits

    // Use localparam instead of enum for broader tool compatibility
    localparam logic ST_IDLE = 1'b0;
    localparam logic ST_FILL = 1'b1;

    logic                  state_q;
    logic [31:0]           cpu_rdata_q;    // registered load data presented to WB
    logic [INDEX_W-1:0]    miss_index_q;   // saved index for FILL state
    logic [TAG_W-1:0]      miss_tag_q;     // saved tag for FILL state
    logic [31:0]           miss_addr_q;    // saved byte address for FILL state

    logic                  valid_q  [0:NSETS-1];
    logic [TAG_W-1:0]      tag_q    [0:NSETS-1];
    logic [31:0]           data_q   [0:NSETS-1];

    logic [31:0]           hit_count_q;
    logic [31:0]           miss_count_q;

    // Intermediate combinatorial signals
    logic [INDEX_W-1:0]  index_s;
    logic [TAG_W-1:0]    tag_s;
    logic                hit_s;
    logic [31:0]         store_merged_s;

    // -----------------------------------------------------------------------
    // All combinatorial logic in one block for tool compatibility.
    // Use arithmetic to derive index/tag — avoids parameterized bit-selects.
    // -----------------------------------------------------------------------
    always @(*) begin : comb
        integer idx_int;
        // Index: word address mod NSETS (NSETS must be power of two)
        idx_int = (cpu_addr_i >> 2) & (NSETS - 1);
        index_s = idx_int[INDEX_W-1:0];
        // Tag: upper bits above index and byte-offset
        tag_s   = cpu_addr_i >> (INDEX_W + 2);
        // Hit detection
        hit_s   = (state_q == ST_IDLE) && valid_q[index_s] && (tag_q[index_s] == tag_s);

        // Byte-enable merge for store-hit cache update
        store_merged_s = data_q[index_s];
        if (cpu_wstrb_i[0]) store_merged_s[ 7: 0] = cpu_wdata_i[ 7: 0];
        if (cpu_wstrb_i[1]) store_merged_s[15: 8] = cpu_wdata_i[15: 8];
        if (cpu_wstrb_i[2]) store_merged_s[23:16] = cpu_wdata_i[23:16];
        if (cpu_wstrb_i[3]) store_merged_s[31:24] = cpu_wdata_i[31:24];

        // Output defaults
        dmem_stall_o = 1'b0;
        mem_addr_o   = cpu_addr_i;
        mem_ren_o    = 1'b0;
        mem_wen_o    = 1'b0;
        mem_wstrb_o  = cpu_wstrb_i;
        mem_wdata_o  = cpu_wdata_i;

        case (state_q)
            ST_IDLE: begin
                if (cpu_ren_i && !hit_s) begin
                    dmem_stall_o = 1'b1;  // read miss: stall pipeline
                    mem_ren_o    = 1'b1;  // start BRAM fill
                end
                if (cpu_wen_i) begin
                    mem_wen_o   = 1'b1;   // write-through: always to backing mem
                    mem_wstrb_o = cpu_wstrb_i;
                    mem_wdata_o = cpu_wdata_i;
                end
            end
            ST_FILL: begin
                // Hold BRAM at miss addr so mem_rdata_i stays valid in WB cycle
                mem_addr_o = miss_addr_q;
                mem_ren_o  = 1'b1;
            end
            default: ;
        endcase
    end

    // -----------------------------------------------------------------------
    // Sequential: FSM, cache storage, counters
    // -----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q      <= ST_IDLE;
            cpu_rdata_q  <= '0;
            hit_count_q  <= '0;
            miss_count_q <= '0;
            for (int i = 0; i < NSETS; i++) valid_q[i] <= 1'b0;
        end else begin
            case (state_q)
                ST_IDLE: begin
                    if (cpu_ren_i) begin
                        if (hit_s) begin
                            cpu_rdata_q <= data_q[index_s];
                            hit_count_q <= hit_count_q + 1;
                        end else begin
                            miss_index_q <= index_s;
                            miss_tag_q   <= tag_s;
                            miss_addr_q  <= cpu_addr_i;
                            miss_count_q <= miss_count_q + 1;
                            state_q      <= ST_FILL;
                        end
                    end
                    if (cpu_wen_i && hit_s)
                        data_q[index_s] <= store_merged_s;
                end
                ST_FILL: begin
                    valid_q[miss_index_q] <= 1'b1;
                    tag_q[miss_index_q]   <= miss_tag_q;
                    data_q[miss_index_q]  <= mem_rdata_i;
                    cpu_rdata_q           <= mem_rdata_i;
                    state_q               <= ST_IDLE;
                end
                default: state_q <= ST_IDLE;
            endcase
        end
    end

    assign cpu_rdata_o  = cpu_rdata_q;
    assign hit_count_o  = hit_count_q;
    assign miss_count_o = miss_count_q;

endmodule : dcache

`default_nettype wire
