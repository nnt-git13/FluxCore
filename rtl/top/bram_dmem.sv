// rtl/top/bram_dmem.sv
//
// Data BRAM wrapper — synthesis target for Xilinx 7-series.
//
// Interface:
//   addr_i    : byte address of the access (word-aligned for word accesses;
//               byte/halfword alignment enforced by mem_stage misalign check).
//   wen_i     : write enable; byte enables in wstrb_i select which bytes write.
//   wstrb_i   : per-byte write strobe [3:0]; each bit enables one byte lane.
//   wdata_i   : 32-bit write data (byte lanes selected by wstrb_i).
//   rdata_o   : 32-bit read data, registered — valid one cycle after addr_i.
//
// Timing model (BRAM DO_REG=0, 1-cycle read latency):
//   addr_i is driven combinatorially from ex_mem_q.alu_result (a registered
//   signal, stable for the entire MEM clock cycle). The BRAM registers addr_i
//   at the posedge ending the MEM stage and presents rdata_o in the WB stage.
//
//   mem_stage also captures dmem_rdata_i into mem_wb_q at the posedge ending
//   MEM stage, but that value is stale for BRAM reads. wb_stage therefore uses
//   the live dmem_rdata_i word in the WB cycle for load writeback.
//
//   Stores are unaffected: the BRAM writes at the posedge that ends MEM stage,
//   which is architecturally the correct commit point.
//
// Byte enables:
//   Four byte-wide sub-arrays allow independent byte-lane writes. This maps
//   directly to the RAMB36E1 byte-enable inputs (WEA[3:0]) that Vivado infers
//   when it sees four separate always_ff blocks with per-bit wstrb conditions.
//
// Initialization:
//   INIT_FILE controls $readmemh initialization (byte 0 array only, as a
//   word-addressed hex file). Leave INIT_FILE = "" for zero-initialized memory.

`default_nettype none

module bram_dmem #(
    parameter int DEPTH     = 2048,  // number of 32-bit words; must be a power of 2
    parameter     INIT_FILE = ""     // hex file for $readmemh; "" → zeroed
)
(
    input  wire logic        clk,
    input  wire logic [31:0] addr_i,    // effective byte address (word-aligned)
    input  wire logic        wen_i,     // write enable
    input  wire logic [3:0]  wstrb_i,   // byte enables
    input  wire logic [31:0] wdata_i,   // write data
    output logic [31:0] rdata_o    // read data, registered (1-cycle latency)
);
    localparam int ADDR_W = $clog2(DEPTH);

    // Four byte-wide sub-arrays: Vivado infers RAMB36E1 with byte enables.
    (* ram_style = "block" *) logic [7:0] mem0 [0:DEPTH-1];
    (* ram_style = "block" *) logic [7:0] mem1 [0:DEPTH-1];
    (* ram_style = "block" *) logic [7:0] mem2 [0:DEPTH-1];
    (* ram_style = "block" *) logic [7:0] mem3 [0:DEPTH-1];

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem0);
        end else begin
            for (int i = 0; i < DEPTH; i++) begin
                mem0[i] = '0; mem1[i] = '0; mem2[i] = '0; mem3[i] = '0;
            end
        end
    end

    logic [ADDR_W-1:0] word_addr;
    assign word_addr = addr_i[ADDR_W+1:2];

    always_ff @(posedge clk) begin
        if (wen_i) begin
            if (wstrb_i[0]) mem0[word_addr] <= wdata_i[7:0];
            if (wstrb_i[1]) mem1[word_addr] <= wdata_i[15:8];
            if (wstrb_i[2]) mem2[word_addr] <= wdata_i[23:16];
            if (wstrb_i[3]) mem3[word_addr] <= wdata_i[31:24];
        end
        rdata_o <= {mem3[word_addr], mem2[word_addr], mem1[word_addr], mem0[word_addr]};
    end

endmodule : bram_dmem

`default_nettype wire
