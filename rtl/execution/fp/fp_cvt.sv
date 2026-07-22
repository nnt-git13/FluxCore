// rtl/execution/fp/fp_cvt.sv
//
// FP <-> integer conversions (purely combinational, with IEEE rounding):
//   FPU_CVT_W_S   float  -> signed   int32   (result to integer reg)
//   FPU_CVT_WU_S  float  -> unsigned int32   (result to integer reg)
//   FPU_CVT_S_W   signed   int32 -> float    (result to fp reg)
//   FPU_CVT_S_WU  unsigned int32 -> float     (result to fp reg)
//
// Rounding uses the shared fp_round_up() primitive so the tie-breaking is
// identical to every other rounded FP path.
//
// Flags (RISC-V F extension):
//   float->int : NV on NaN, +/-inf, or out-of-range magnitude (result saturates
//                to the nearest representable integer); otherwise NX if the
//                fraction was discarded. NV suppresses NX.
//   int->float : NX only, when the integer has more than 24 significant bits and
//                rounding drops bits. No NV/OF/UF (every int32 is finite and in
//                range; the largest, 2^32, has exponent 159 << 255).

`default_nettype none

module fp_cvt
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
    import fp_pkg::*;
(
    input  wire word_t     a_i,       // float source (float->int) — bits
    input  wire word_t     int_i,     // integer source (int->float)
    input  wire fpu_op_e   op_i,
    input  wire logic [2:0] rm_i,     // resolved rounding mode
    output word_t          result_o,
    output fflags_t        fflags_o
);
    // Signed/unsigned integer bounds
    localparam logic [33:0] INT_MAX_S  = 34'h0_7FFF_FFFF;   //  2^31 - 1
    localparam logic [33:0] INT_MIN_MAG = 34'h0_8000_0000;  //  2^31 (magnitude of INT_MIN)
    localparam logic [33:0] UINT_MAX   = 34'h0_FFFF_FFFF;   //  2^32 - 1

    // =======================================================================
    // Float -> integer
    // =======================================================================
    logic        f_sign;
    logic [7:0]  f_exp;
    logic [22:0] f_man;
    logic        f_nan, f_inf, f_zero;
    logic [23:0] f_M;              // significand with implicit bit
    logic [8:0]  f_E;              // effective biased exponent (subnormal → 1)
    logic [33:0] intpart_s;        // integer magnitude before rounding (34-bit)
    logic        guard_s, sticky_s;
    logic [33:0] rounded_mag_s;
    logic        round_up_s;
    logic        f2i_inexact_s;
    logic        signed_op_s;

    assign f_sign = fp_sign(a_i);
    assign f_exp  = fp_exp(a_i);
    assign f_man  = fp_man(a_i);
    assign f_nan  = fp_is_nan(a_i);
    assign f_inf  = fp_is_inf(a_i);
    assign f_zero = fp_is_zero(a_i);
    assign f_M    = {(f_exp != 8'd0), f_man};
    assign f_E    = (f_exp == 8'd0) ? 9'd1 : {1'b0, f_exp};
    assign signed_op_s = (op_i == FPU_CVT_W_S);

    // Integer part and guard/sticky of the fraction.
    // Bit i of f_M has weight 2^(f_E-150+i). Integer bits are those with
    // weight >= 0; the guard bit has weight 2^-1; sticky ORs weights <= 2^-2.
    integer bi;
    integer we;   // weight exponent of bit bi
    always_comb begin
        guard_s  = 1'b0;
        sticky_s = 1'b0;
        // integer part.  value >= 2^32 (f_E >= 159) always overflows the widest
        // (unsigned) destination, so clamp to a saturating sentinel rather than
        // letting a large left-shift truncate and wrap in the 34-bit register.
        if (f_E >= 9'd159)
            intpart_s = 34'h3_FFFF_FFFF;              // force all range checks to overflow
        else if (f_E >= 9'd150)
            intpart_s = {10'b0, f_M} << (f_E - 9'd150);
        else
            intpart_s = {10'b0, f_M} >> (9'd150 - f_E);
        // fraction bits → guard / sticky
        for (bi = 0; bi < 24; bi = bi + 1) begin
            we = $signed({1'b0, f_E}) - 150 + bi;
            if (we == -1)       guard_s  = f_M[bi];
            else if (we <= -2)  sticky_s = sticky_s | f_M[bi];
        end
    end

    assign round_up_s     = fp_round_up(rm_i, f_sign, intpart_s[0], guard_s, sticky_s);
    assign rounded_mag_s  = intpart_s + {33'b0, round_up_s};
    assign f2i_inexact_s  = guard_s | sticky_s;

    word_t   f2i_result_s;
    fflags_t f2i_flags_s;
    always_comb begin
        f2i_result_s = '0;
        f2i_flags_s  = '0;
        if (f_nan) begin
            f2i_result_s = signed_op_s ? 32'h7FFF_FFFF : 32'hFFFF_FFFF;
            f2i_flags_s  = {1'b1, 4'b0};   // NV
        end else if (f_inf) begin
            if (signed_op_s) f2i_result_s = f_sign ? 32'h8000_0000 : 32'h7FFF_FFFF;
            else             f2i_result_s = f_sign ? 32'h0000_0000 : 32'hFFFF_FFFF;
            f2i_flags_s = {1'b1, 4'b0};    // NV
        end else if (signed_op_s) begin
            if (!f_sign) begin                       // positive
                if (rounded_mag_s > INT_MAX_S) begin
                    f2i_result_s = 32'h7FFF_FFFF; f2i_flags_s = {1'b1, 4'b0};
                end else begin
                    f2i_result_s = rounded_mag_s[31:0];
                    f2i_flags_s  = {4'b0, f2i_inexact_s};   // NX
                end
            end else begin                            // negative
                if (rounded_mag_s > INT_MIN_MAG) begin
                    f2i_result_s = 32'h8000_0000; f2i_flags_s = {1'b1, 4'b0};
                end else begin
                    f2i_result_s = (~rounded_mag_s[31:0]) + 32'd1;   // -mag
                    f2i_flags_s  = {4'b0, f2i_inexact_s};
                end
            end
        end else begin                               // unsigned
            if (f_sign) begin                         // negative input
                if (rounded_mag_s == 34'd0) begin
                    f2i_result_s = 32'h0; f2i_flags_s = {4'b0, f2i_inexact_s};
                end else begin
                    f2i_result_s = 32'h0; f2i_flags_s = {1'b1, 4'b0};   // NV
                end
            end else begin
                if (rounded_mag_s > UINT_MAX) begin
                    f2i_result_s = 32'hFFFF_FFFF; f2i_flags_s = {1'b1, 4'b0};
                end else begin
                    f2i_result_s = rounded_mag_s[31:0];
                    f2i_flags_s  = {4'b0, f2i_inexact_s};
                end
            end
        end
    end

    // =======================================================================
    // Integer -> float
    // =======================================================================
    logic        i_sign;
    logic [31:0] i_mag;
    logic        i_zero;
    integer      i_msb;             // index of the most-significant set bit
    logic [31:0] i_norm;            // magnitude with MSB shifted to bit 31
    logic [22:0] i_mant;
    logic        i_guard, i_sticky, i_round_up;
    logic [23:0] i_mant_ext;        // 24-bit for carry-out on round
    logic [7:0]  i_exp;
    word_t       i2f_result_s;
    fflags_t     i2f_flags_s;

    assign i_sign = (op_i == FPU_CVT_S_W) ? int_i[31] : 1'b0;
    assign i_mag  = ((op_i == FPU_CVT_S_W) && int_i[31]) ? ((~int_i) + 32'd1) : int_i;
    assign i_zero = (i_mag == 32'd0);

    // Priority encode the MSB position (0..31).
    integer mi;
    always_comb begin
        i_msb = 0;
        for (mi = 0; mi < 32; mi = mi + 1)
            if (i_mag[mi]) i_msb = mi;
    end

    // Normalize so the leading 1 sits at bit 31.
    assign i_norm  = i_mag << (5'd31 - i_msb[4:0]);
    assign i_mant  = i_norm[30:8];
    assign i_guard = i_norm[7];
    assign i_sticky = |i_norm[6:0];
    assign i_round_up = fp_round_up(rm_i, i_sign, i_mant[0], i_guard, i_sticky);
    assign i_mant_ext = {1'b0, i_mant} + {23'b0, i_round_up};
    // exponent = msb + bias; a mantissa carry-out bumps the exponent by 1.
    assign i_exp = (i_msb[7:0] + 8'd127) + {7'b0, i_mant_ext[23]};

    always_comb begin
        if (i_zero)
            i2f_result_s = 32'h0000_0000;             // +0
        else
            i2f_result_s = {i_sign, i_exp, i_mant_ext[22:0]};
        i2f_flags_s = {4'b0, (i_guard | i_sticky)};   // NX only
    end

    // =======================================================================
    // Output select
    // =======================================================================
    always_comb begin
        unique case (op_i)
            FPU_CVT_W_S, FPU_CVT_WU_S: begin
                result_o = f2i_result_s;
                fflags_o = f2i_flags_s;
            end
            default: begin   // FPU_CVT_S_W, FPU_CVT_S_WU
                result_o = i2f_result_s;
                fflags_o = i2f_flags_s;
            end
        endcase
    end

endmodule : fp_cvt

`default_nettype wire
