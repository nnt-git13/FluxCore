// rtl/execution/fp/fp_pack.sv
//
// Shared normalize / round / pack back-end for the arithmetic FP units
// (fp_mul, fp_addsub, and later fp_fma). Given a finite, nonzero result that has
// already been normalized so its leading 1 sits at bit 25 of frac_i, together
// with the unbiased exponent of that leading 1, this module rounds to
// single precision and packs the IEEE bit pattern, handling overflow (→ inf or
// max-finite per rounding mode) and gradual underflow (→ subnormal or zero).
//
// frac_i layout (26 bits): { 1 (implicit), m[22:0], G, R }
//   bit25 = leading one
//   bits[24:2] = 23-bit significand
//   bit1 = guard, bit0 = round; sticky_i = OR of everything below `round`.
//
// Special operands (NaN / inf / exact zero) are handled by the caller, which
// muxes its own result in and bypasses this module.
//
// Flags produced: OF (overflow), UF (underflow), NX (inexact). NV/DZ are the
// caller's responsibility.

`default_nettype none

module fp_pack
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
    import fp_pkg::*;
(
    input  wire logic         sign_i,
    input  wire logic signed [11:0] exp_i,   // unbiased exponent of frac_i[25]
    input  wire logic [25:0]  frac_i,        // {1, m[22:0], G, R}
    input  wire logic         sticky_i,      // OR of bits below R
    input  wire logic [2:0]   rm_i,
    output word_t             result_o,
    output fflags_t           fflags_o
);
    // Convenience constants
    localparam word_t INF_MAG = 32'h7F80_0000;   // magnitude of +inf (exp=255,man=0)
    localparam word_t MAX_MAG = 32'h7F7F_FFFF;   // magnitude of largest finite

    logic signed [11:0] biased_s;               // exp field value (signed for range checks)
    assign biased_s = exp_i + 12'sd127;

    // -----------------------------------------------------------------------
    // Normal-range rounding (1 <= biased <= 254)
    // -----------------------------------------------------------------------
    logic [22:0] n_mant;
    logic        n_guard, n_sticky, n_round_up;
    logic [23:0] n_mant_r;         // 24-bit to catch carry-out
    logic [8:0]  n_biased_r;       // may become 255 on carry
    logic        n_inexact;

    assign n_mant   = frac_i[24:2];
    assign n_guard  = frac_i[1];
    assign n_sticky = frac_i[0] | sticky_i;
    assign n_round_up = fp_round_up(rm_i, sign_i, n_mant[0], n_guard, n_sticky);
    assign n_mant_r   = {1'b0, n_mant} + {23'b0, n_round_up};
    assign n_inexact  = n_guard | n_sticky;
    // carry-out of the mantissa bumps the exponent by one
    assign n_biased_r = n_mant_r[23] ? (biased_s[8:0] + 9'd1) : biased_s[8:0];

    // -----------------------------------------------------------------------
    // Underflow denormalisation (biased <= 0): shift right to the subnormal grid
    // -----------------------------------------------------------------------
    logic signed [11:0] rsh_s;          // right-shift to reach exponent -149 mantissa
    logic [5:0]         rshc_s;         // clamped shift amount
    logic [31:0]        fw_s;
    logic [31:0]        u_shifted;
    logic               u_guard, u_sticky;
    logic [31:0]        u_mask;
    logic [23:0]        u_mant_r;
    logic               u_inexact;
    logic               u_round_up;

    assign rsh_s = -(exp_i + 12'sd124);            // >= 3 when biased <= 0
    assign rshc_s = (rsh_s > 12'sd31) ? 6'd31 : rsh_s[5:0];
    assign fw_s   = {6'b0, frac_i};
    assign u_shifted = fw_s >> rshc_s;
    assign u_mask = (rshc_s == 0) ? 32'h0 : ((32'h1 << (rshc_s - 6'd1)) - 32'h1);
    always_comb begin
        u_guard  = (rshc_s == 0) ? 1'b0 : fw_s[rshc_s - 6'd1];
        u_sticky = sticky_i | (|(fw_s & u_mask));
        if (rsh_s > 12'sd31)                       // deep underflow: all bits are sticky
            u_sticky = sticky_i | (|frac_i);
    end
    assign u_round_up = fp_round_up(rm_i, sign_i, u_shifted[0], u_guard, u_sticky);
    assign u_mant_r   = u_shifted[23:0] + {23'b0, u_round_up};
    assign u_inexact  = u_guard | u_sticky;

    // -----------------------------------------------------------------------
    // Overflow result selection per rounding mode
    // -----------------------------------------------------------------------
    function automatic word_t overflow_val(input logic s, input logic [2:0] rm);
        case (rm)
            FRM_RTZ: return {s, MAX_MAG[30:0]};                 // toward zero → max finite
            FRM_RDN: return s ? {1'b1, INF_MAG[30:0]} : {1'b0, MAX_MAG[30:0]};
            FRM_RUP: return s ? {1'b1, MAX_MAG[30:0]} : {1'b0, INF_MAG[30:0]};
            default: return {s, INF_MAG[30:0]};                 // RNE / RMM → inf
        endcase
    endfunction

    // -----------------------------------------------------------------------
    // Result select
    // -----------------------------------------------------------------------
    always_comb begin
        result_o = '0;
        fflags_o = '0;
        if (biased_s >= 12'sd255) begin
            // gross overflow
            result_o = overflow_val(sign_i, rm_i);
            fflags_o = {1'b0, 1'b0, 1'b1, 1'b0, 1'b1};   // OF | NX
        end else if (biased_s <= 12'sd0) begin
            // underflow / subnormal
            if (u_mant_r[23]) begin
                // rounded up to the smallest normal
                result_o = {sign_i, 8'd1, 23'd0};
                fflags_o = {4'b0, u_inexact};            // NX only (no longer tiny)
            end else begin
                result_o = {sign_i, 8'd0, u_mant_r[22:0]};
                // UF signalled when the result is tiny AND inexact
                fflags_o = {1'b0, 1'b0, 1'b0, u_inexact, u_inexact};  // UF | NX
            end
        end else begin
            // normal range; a mantissa carry may still push into overflow
            if (n_biased_r >= 9'd255) begin
                result_o = overflow_val(sign_i, rm_i);
                fflags_o = {1'b0, 1'b0, 1'b1, 1'b0, 1'b1};   // OF | NX
            end else begin
                result_o = {sign_i, n_biased_r[7:0], n_mant_r[22:0]};
                fflags_o = {4'b0, n_inexact};                 // NX
            end
        end
    end

endmodule : fp_pack

`default_nettype wire
