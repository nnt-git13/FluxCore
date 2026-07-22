// rtl/execution/fp/fp_minmax.sv
//
// FMIN.S / FMAX.S. Purely combinational; produces an FP result plus the NV flag.
//
// RISC-V semantics (unprivileged spec, F extension):
//   - If both operands are NaN, the result is the canonical quiet NaN.
//   - If exactly one operand is NaN, the result is the non-NaN operand
//     (NaN is "passed over").
//   - A signaling-NaN operand sets the NV flag (quiet NaN alone does not).
//   - For equal-magnitude signed zeros, FMIN returns -0 and FMAX returns +0
//     (sign is significant even though -0 == +0 numerically).
//
// Only NV can be raised here; no rounding occurs (the result is one of the
// inputs or the canonical NaN), so no OF/UF/NX.

`default_nettype none

module fp_minmax
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
    import fp_pkg::*;
(
    input  wire word_t   a_i,
    input  wire word_t   b_i,
    input  wire fpu_op_e op_i,     // FPU_MIN / FPU_MAX
    output word_t        result_o,
    output fflags_t      fflags_o
);
    logic a_nan_s, b_nan_s;
    logic is_min_s;
    logic pick_a_s;         // 1 → result is a, 0 → result is b (non-NaN case)
    logic both_zero_s;
    word_t result_s;
    logic  nv_s;

    assign a_nan_s     = fp_is_nan(a_i);
    assign b_nan_s     = fp_is_nan(b_i);
    assign is_min_s    = (op_i == FPU_MIN);
    assign both_zero_s = fp_is_zero(a_i) & fp_is_zero(b_i);

    // Which operand wins when neither is NaN.
    always_comb begin
        if (both_zero_s) begin
            // Signed-zero tie-break: MIN → the -0, MAX → the +0.
            // a wins for MIN if a is negative; for MAX if a is positive.
            pick_a_s = is_min_s ? a_i[31] : ~a_i[31];
        end else if (fp_lt(a_i, b_i)) begin
            pick_a_s = is_min_s;    // a < b: a is the min
        end else begin
            pick_a_s = ~is_min_s;   // a >= b: b is the min
        end
    end

    always_comb begin
        // NV only on a signaling NaN operand.
        nv_s = fp_is_snan(a_i) | fp_is_snan(b_i);
        if (a_nan_s && b_nan_s)
            result_s = FP_QNAN;             // both NaN → canonical qNaN
        else if (a_nan_s)
            result_s = b_i;                 // pass over NaN a
        else if (b_nan_s)
            result_s = a_i;                 // pass over NaN b
        else
            result_s = pick_a_s ? a_i : b_i;
    end

    assign result_o = result_s;
    assign fflags_o = {nv_s, 4'b0000};

endmodule : fp_minmax

`default_nettype wire
