// rtl/top/bram_imem.sv
//
// Instruction BRAM wrapper — synthesis target for Xilinx 7-series.
//
// Timing model (BRAM DO_REG=0, 1-cycle read latency):
//   This module uses addr_next_i (= fetch_unit.fetch_addr_next_o = next PC)
//   rather than the current PC as the BRAM address. The BRAM registers
//   addr_next_i at each posedge, so its output appears in the FOLLOWING cycle
//   when pc_q = old addr_next_i. The CPU sees rdata_o as a zero-latency read
//   from its perspective: the instruction for PC X is valid in the same cycle
//   that fetch_addr_o = X.
//
//   Requirement: reset must be held for at least one clock cycle before the
//   first active fetch so the BRAM can register RESET_VECTOR during reset and
//   present mem[RESET_VECTOR] on the first active cycle. All FluxCore
//   testbenches hold reset for three cycles, satisfying this constraint.
//
// Initialization:
//   Set INIT_FILE to a $readmemh-compatible hex file path to pre-load the ROM.
//   Leave INIT_FILE = "" for a zero-initialized memory (for synthesis without
//   an embedded program — Vivado will optimize away reads of zero).
//
// Synthesis attributes:
//   (* rom_style = "block" *) causes Vivado to infer RAMB36E1 primitives.
//   For 16 KB (DEPTH=4096), 4 × RAMB36E1 are used. For 4 KB (DEPTH=1024),
//   1 × RAMB36E1. Any power-of-2 DEPTH ≤ 16384 synthesizes without cascading.

`default_nettype none

module bram_imem #(
    parameter int DEPTH     = 4096,  // number of 32-bit words; must be a power of 2
    parameter     INIT_FILE = ""     // hex file for $readmemh; "" → zeroed
)
(
    input  wire logic        clk,
    input  wire logic [31:0] addr_next_i,  // next PC from fetch_unit (for 1-cycle prefetch)
    output logic [31:0] rdata_o       // instruction word, valid 1 cycle after address
);
    localparam int ADDR_W = $clog2(DEPTH);

    (* rom_style = "block" *)
    logic [31:0] mem [0:DEPTH-1];

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end else begin
            for (int i = 0; i < DEPTH; i++) mem[i] = '0;
        end
    end

    always_ff @(posedge clk)
        rdata_o <= mem[addr_next_i[ADDR_W+1:2]];

endmodule : bram_imem

`default_nettype wire
