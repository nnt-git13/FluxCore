// rtl/common/fp_regfile.sv
//
// FluxCore floating-point register file — RV32F, 32 × 32-bit registers.
//
// Ports:
//   Three asynchronous read ports (fs1, fs2, fs3)
//   One synchronous write port    (frd)
//   Synchronous active-high reset
//
// Difference from the integer regfile (rtl/common/regfile.sv):
//   - THREE read ports, because the fused multiply-add family (FMADD/FMSUB/
//     FNMADD/FNMSUB) reads three FP source operands (fs1, fs2, fs3) at once.
//   - NO x0 special-casing. In the FP register file, f0 is an ordinary
//     register that holds whatever was last written; there is no hardwired
//     zero. Read and write f0 like any other register.
//
// Read behaviour:
//   Purely combinational, with the same write-first bypass as the integer
//   regfile so that a value written by WB in the current cycle is visible to
//   the ID-stage read in the same cycle (matching a write-first distributed
//   RAM). This keeps FP operand read latency at zero, as the integer path.
//
// Write behaviour:
//   Synchronous to posedge clk. On reset all 32 registers clear to 0.
//   Single-precision RV32F uses the full 32 bits with no NaN-boxing (boxing
//   only applies when a narrower type is stored in a wider FLEN register,
//   which does not occur in a pure RV32F, FLEN=32 configuration).

`default_nettype none

module fp_regfile
    import fluxcore_pkg::*;
(
    input  wire logic      clk,
    input  wire logic      rst,        // synchronous, active-high

    // --- Read port A (fs1) ---
    input  wire reg_idx_t  fs1_addr_i,
    output word_t          fs1_data_o,

    // --- Read port B (fs2) ---
    input  wire reg_idx_t  fs2_addr_i,
    output word_t          fs2_data_o,

    // --- Read port C (fs3) ---
    input  wire reg_idx_t  fs3_addr_i,
    output word_t          fs3_data_o,

    // --- Write port (frd) ---
    input  wire logic      frd_wen_i,
    input  wire reg_idx_t  frd_addr_i,
    input  wire word_t     frd_data_i
);

    // -----------------------------------------------------------------------
    // Register array
    // -----------------------------------------------------------------------
    word_t fregs [0:REG_COUNT-1];

    // -----------------------------------------------------------------------
    // Synchronous write with active-high reset.
    // No x0 guard: f0 is a normal register in RV32F.
    // -----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned i = 0; i < REG_COUNT; i++) begin
                fregs[i] <= '0;
            end
        end else if (frd_wen_i) begin
            fregs[frd_addr_i] <= frd_data_i;
        end
    end

    // -----------------------------------------------------------------------
    // Asynchronous read (combinational) with write-first bypass.
    // When WB writes the same register being read this cycle, return the new
    // value directly so the ID-stage read captures the architecturally correct
    // value (mirrors the integer regfile bypass and a write-first RAM).
    // -----------------------------------------------------------------------
    logic fs1_bypass_s, fs2_bypass_s, fs3_bypass_s;
    assign fs1_bypass_s = frd_wen_i & (frd_addr_i == fs1_addr_i);
    assign fs2_bypass_s = frd_wen_i & (frd_addr_i == fs2_addr_i);
    assign fs3_bypass_s = frd_wen_i & (frd_addr_i == fs3_addr_i);

    assign fs1_data_o = fs1_bypass_s ? frd_data_i : fregs[fs1_addr_i];
    assign fs2_data_o = fs2_bypass_s ? frd_data_i : fregs[fs2_addr_i];
    assign fs3_data_o = fs3_bypass_s ? frd_data_i : fregs[fs3_addr_i];

endmodule : fp_regfile

`default_nettype wire
