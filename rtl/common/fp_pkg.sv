// rtl/common/fp_pkg.sv
//
// IEEE-754 single-precision helper package for the FluxCore RV32F unit.
//
// Provides field extractors, class predicates, the canonical quiet NaN, and
// the shared rounding primitive fp_round_up() used by every rounded FP path
// (conversions in Phase B; add/mul/fma/div/sqrt in later phases).  Keeping this
// logic in one package guarantees the rounding decision is bit-identical across
// all FPU sub-units, which is essential for IEEE conformance.
//
// Format (binary32):
//   [31]    sign
//   [30:23] biased exponent (bias 127); 0 = zero/subnormal, 255 = inf/NaN
//   [22:0]  trailing significand (mantissa)
//
// Depends on fluxcore_pkg (word_t) and rv32_isa_pkg (frm_e / FRM_* constants).

`default_nettype none

package fp_pkg;

    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;

    localparam int unsigned FP_EXP_W  = 8;
    localparam int unsigned FP_MAN_W  = 23;
    localparam logic [7:0]   FP_EXP_MAX = 8'hFF;   // inf / NaN exponent
    localparam logic [7:0]   FP_BIAS    = 8'd127;

    // Canonical quiet NaN emitted by any invalid-producing operation.
    localparam word_t FP_QNAN = 32'h7FC0_0000;
    // Positive / negative infinity.
    localparam word_t FP_POS_INF = 32'h7F80_0000;
    localparam word_t FP_NEG_INF = 32'hFF80_0000;

    // -----------------------------------------------------------------------
    // Field extractors
    // -----------------------------------------------------------------------
    function automatic logic        fp_sign(input word_t x); return x[31];        endfunction
    function automatic logic [7:0]  fp_exp (input word_t x); return x[30:23];      endfunction
    function automatic logic [22:0] fp_man (input word_t x); return x[22:0];       endfunction

    // -----------------------------------------------------------------------
    // Class predicates
    // -----------------------------------------------------------------------
    function automatic logic fp_is_inf (input word_t x);
        return (x[30:23] == FP_EXP_MAX) && (x[22:0] == '0);
    endfunction
    function automatic logic fp_is_nan (input word_t x);
        return (x[30:23] == FP_EXP_MAX) && (x[22:0] != '0);
    endfunction
    function automatic logic fp_is_snan(input word_t x);
        // signaling NaN: NaN with the MSB of the mantissa clear
        return fp_is_nan(x) && (x[22] == 1'b0);
    endfunction
    function automatic logic fp_is_qnan(input word_t x);
        return fp_is_nan(x) && (x[22] == 1'b1);
    endfunction
    function automatic logic fp_is_zero(input word_t x);
        return (x[30:23] == '0) && (x[22:0] == '0);
    endfunction
    function automatic logic fp_is_subnormal(input word_t x);
        return (x[30:23] == '0) && (x[22:0] != '0);
    endfunction

    // -----------------------------------------------------------------------
    // Ordered numeric comparison (callers must handle NaN separately).
    // fp_eq treats +0 and -0 as equal; fp_lt gives the true numeric ordering.
    // -----------------------------------------------------------------------
    function automatic logic fp_eq(input word_t a, input word_t b);
        if (fp_is_zero(a) && fp_is_zero(b)) return 1'b1;   // +0 == -0
        return (a == b);
    endfunction

    function automatic logic fp_lt(input word_t a, input word_t b);
        logic sa, sb;
        sa = a[31];
        sb = b[31];
        if (fp_is_zero(a) && fp_is_zero(b)) return 1'b0;   // ±0 are equal, not <
        if (sa != sb)      return sa;                       // negative < positive
        if (sa == 1'b0)    return (a[30:0] <  b[30:0]);     // both +: compare magnitude
        else               return (a[30:0] >  b[30:0]);     // both -: larger mag is smaller
    endfunction

    // -----------------------------------------------------------------------
    // Shared rounding primitive.
    //
    // Given the rounding mode, the result sign, the LSB of the value being
    // kept, and the guard bit (first discarded bit) + sticky (OR of all bits
    // below the guard), return 1 if the magnitude must be incremented.
    //
    //   RNE  round to nearest, ties to even : g & (s | lsb)
    //   RTZ  toward zero                    : never
    //   RDN  toward -inf                    : round up magnitude iff negative & (g|s)
    //   RUP  toward +inf                    : round up magnitude iff positive & (g|s)
    //   RMM  to nearest, ties to max mag    : g  (halfway always rounds away from 0)
    //
    // inexact = (g | s) is computed by the caller.
    // -----------------------------------------------------------------------
    function automatic logic fp_round_up(
        input logic [2:0] rm,
        input logic       sign,
        input logic       lsb,
        input logic       guard,
        input logic       sticky
    );
        case (rm)
            FRM_RNE: return guard & (sticky | lsb);
            FRM_RTZ: return 1'b0;
            FRM_RDN: return sign  & (guard | sticky);
            FRM_RUP: return ~sign & (guard | sticky);
            FRM_RMM: return guard;
            default: return 1'b0;   // reserved modes handled as illegal at decode
        endcase
    endfunction

endpackage : fp_pkg

`default_nettype wire
