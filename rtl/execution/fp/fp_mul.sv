// rtl/execution/fp/fp_mul.sv
//
// IEEE-754 single-precision multiply, FMUL.S. Combinational (single EX cycle,
// like the integer MUL). Full support for subnormal inputs and results, NaN /
// infinity handling, all five rounding modes, and the OF/UF/NX/NV flags.
//
// Pipeline: 24x24 significand product feeds the shared fp_pack normalise/round
// back-end. Special operands (NaN/inf/zero) bypass the arithmetic path.

`default_nettype none

module fp_mul
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
    import fp_pkg::*;
(
    input  wire word_t      a_i,
    input  wire word_t      b_i,
    input  wire logic [2:0] rm_i,
    output word_t           result_o,
    output fflags_t         fflags_o
);
    // ---- unpack ----
    logic        sa, sb, sign_r;
    logic [7:0]  ea, eb;
    logic [22:0] ma, mb;
    logic        a_nan, a_inf, a_zero, a_sub, a_snan;
    logic        b_nan, b_inf, b_zero, b_sub, b_snan;

    assign sa = a_i[31]; assign ea = a_i[30:23]; assign ma = a_i[22:0];
    assign sb = b_i[31]; assign eb = b_i[30:23]; assign mb = b_i[22:0];
    assign sign_r = sa ^ sb;
    assign a_nan  = fp_is_nan(a_i);  assign b_nan  = fp_is_nan(b_i);
    assign a_inf  = fp_is_inf(a_i);  assign b_inf  = fp_is_inf(b_i);
    assign a_zero = fp_is_zero(a_i); assign b_zero = fp_is_zero(b_i);
    assign a_sub  = fp_is_subnormal(a_i); assign b_sub = fp_is_subnormal(b_i);
    assign a_snan = fp_is_snan(a_i); assign b_snan = fp_is_snan(b_i);

    // ---- most-significant set bit of a 23-bit mantissa (for subnormal norm) ----
    function automatic logic [4:0] msb23(input logic [22:0] m);
        logic [4:0] idx; integer i;
        idx = 5'd0;
        for (i = 0; i < 23; i = i + 1) if (m[i]) idx = i[4:0];
        return idx;
    endfunction

    // ---- normalise operands into 24-bit significand + unbiased exponent ----
    logic [23:0]        sig_a, sig_b;
    logic signed [11:0] exp_a, exp_b;
    logic [4:0]         sha, shb;

    assign sha = 5'd23 - msb23(ma);
    assign shb = 5'd23 - msb23(mb);
    always_comb begin
        if (a_sub) begin sig_a = 24'(ma) << sha; exp_a = -12'sd149 + $signed({7'b0, msb23(ma)}); end
        else       begin sig_a = {1'b1, ma};     exp_a = $signed({4'b0, ea}) - 12'sd127;          end
        if (b_sub) begin sig_b = 24'(mb) << shb; exp_b = -12'sd149 + $signed({7'b0, msb23(mb)}); end
        else       begin sig_b = {1'b1, mb};     exp_b = $signed({4'b0, eb}) - 12'sd127;          end
    end

    // ---- 24x24 product and normalisation to frac_i for fp_pack ----
    logic [47:0]        prod;
    logic signed [11:0] exp_p;
    logic [25:0]        frac_s;
    logic               sticky_s;
    logic signed [11:0] exp_lead_s;

    assign prod  = sig_a * sig_b;
    assign exp_p = exp_a + exp_b;
    always_comb begin
        if (prod[47]) begin
            frac_s     = prod[47:22];
            sticky_s   = |prod[21:0];
            exp_lead_s = exp_p + 12'sd1;
        end else begin
            frac_s     = prod[46:21];
            sticky_s   = |prod[20:0];
            exp_lead_s = exp_p;
        end
    end

    // ---- normal (finite, nonzero) path via shared packer ----
    word_t   pack_result;
    fflags_t pack_flags;
    fp_pack u_pack (
        .sign_i (sign_r),
        .exp_i  (exp_lead_s),
        .frac_i (frac_s),
        .sticky_i(sticky_s),
        .rm_i   (rm_i),
        .result_o(pack_result),
        .fflags_o(pack_flags)
    );

    // ---- special-case mux ----
    always_comb begin
        if (a_nan || b_nan) begin
            result_o = FP_QNAN;
            fflags_o = (a_snan || b_snan) ? 5'b10000 : 5'b00000;   // NV on sNaN
        end else if ((a_inf && b_zero) || (b_inf && a_zero)) begin
            result_o = FP_QNAN;                                     // inf * 0 = invalid
            fflags_o = 5'b10000;                                    // NV
        end else if (a_inf || b_inf) begin
            result_o = {sign_r, 8'hFF, 23'd0};                      // signed infinity
            fflags_o = 5'b00000;
        end else if (a_zero || b_zero) begin
            result_o = {sign_r, 31'd0};                             // signed zero
            fflags_o = 5'b00000;
        end else begin
            result_o = pack_result;
            fflags_o = pack_flags;
        end
    end

endmodule : fp_mul

`default_nettype wire
