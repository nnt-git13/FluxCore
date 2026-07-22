// rtl/execution/fp/fp_addsub.sv
//
// IEEE-754 single-precision add/subtract, FADD.S / FSUB.S. Combinational.
// Full subnormal support (inputs and results), NaN/inf handling, effective
// subtraction with leading-zero cancellation, all rounding modes, OF/UF/NX/NV.
//
// Method: negate b's sign for FSUB; normalise operands to 24-bit significands;
// align the smaller to the larger exponent with a sticky-preserving right shift;
// add or subtract; re-normalise (right on carry, left on cancellation); round
// and pack via the shared fp_pack back-end.

`default_nettype none

module fp_addsub
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
    import fp_pkg::*;
(
    input  wire word_t      a_i,
    input  wire word_t      b_i,
    input  wire fpu_op_e    op_i,      // FPU_ADD or FPU_SUB
    input  wire logic [2:0] rm_i,
    output word_t           result_o,
    output fflags_t         fflags_o
);
    // ---- unpack; FSUB flips b's sign ----
    logic        sa, sb, sb_eff;
    logic [7:0]  ea, eb;
    logic [22:0] ma, mb;
    logic        a_nan, a_inf, a_zero, a_sub, a_snan;
    logic        b_nan, b_inf, b_zero, b_sub, b_snan;

    assign sa = a_i[31]; assign ea = a_i[30:23]; assign ma = a_i[22:0];
    assign sb = b_i[31]; assign eb = b_i[30:23]; assign mb = b_i[22:0];
    assign sb_eff = (op_i == FPU_SUB) ? ~sb : sb;
    assign a_nan  = fp_is_nan(a_i);  assign b_nan  = fp_is_nan(b_i);
    assign a_inf  = fp_is_inf(a_i);  assign b_inf  = fp_is_inf(b_i);
    assign a_zero = fp_is_zero(a_i); assign b_zero = fp_is_zero(b_i);
    assign a_sub  = fp_is_subnormal(a_i); assign b_sub = fp_is_subnormal(b_i);
    assign a_snan = fp_is_snan(a_i); assign b_snan = fp_is_snan(b_i);

    function automatic logic [4:0] msb23(input logic [22:0] m);
        logic [4:0] idx; integer i;
        idx = 5'd0;
        for (i = 0; i < 23; i = i + 1) if (m[i]) idx = i[4:0];
        return idx;
    endfunction

    // ---- normalise operands ----
    logic [23:0]        sig_a, sig_b;
    logic signed [11:0] exp_a, exp_b;
    always_comb begin
        if (a_sub) begin sig_a = 24'(ma) << (5'd23 - msb23(ma));
                         exp_a = -12'sd149 + $signed({7'b0, msb23(ma)}); end
        else       begin sig_a = {1'b1, ma}; exp_a = $signed({4'b0, ea}) - 12'sd127; end
        if (b_sub) begin sig_b = 24'(mb) << (5'd23 - msb23(mb));
                         exp_b = -12'sd149 + $signed({7'b0, msb23(mb)}); end
        else       begin sig_b = {1'b1, mb}; exp_b = $signed({4'b0, eb}) - 12'sd127; end
    end

    // ---- order by magnitude: big >= small ----
    logic               a_ge;
    logic [23:0]        big_sig, small_sig;
    logic signed [11:0] big_exp, small_exp;
    logic               big_sign, small_sign;
    assign a_ge = (exp_a > exp_b) || ((exp_a == exp_b) && (sig_a >= sig_b));
    always_comb begin
        if (a_ge) begin
            big_sig=sig_a; big_exp=exp_a; big_sign=sa;
            small_sig=sig_b; small_exp=exp_b; small_sign=sb_eff;
        end else begin
            big_sig=sig_b; big_exp=exp_b; big_sign=sb_eff;
            small_sig=sig_a; small_exp=exp_a; small_sign=sa;
        end
    end

    // ---- align smaller significand (sticky-preserving right shift) ----
    logic signed [11:0] d_s;
    logic [26:0]        big27, small27, small_aligned;
    logic               align_sticky;
    assign d_s    = big_exp - small_exp;   // >= 0
    assign big27  = {big_sig, 3'b000};     // leading 1 at bit 26
    assign small27= {small_sig, 3'b000};
    always_comb begin
        if (d_s >= 12'sd27) begin
            small_aligned = 27'd0;
            align_sticky  = |small27;           // everything is sub-sticky
        end else begin
            small_aligned = small27 >> d_s[4:0];
            align_sticky  = |(small27 & ((27'd1 << d_s[4:0]) - 27'd1));
        end
    end

    // ---- effective add or subtract ----
    logic        eff_sub;
    assign eff_sub = (big_sign != small_sign);

    // Both operands are extended by one extra LSB that carries the alignment
    // sticky of the smaller operand, so the subtraction borrows it exactly.
    //   big28   = {big27, 1'b0}                 (leading 1 at bit 27)
    //   small28 = {small_aligned, align_sticky}
    logic [27:0]        big28, small28;
    logic [28:0]        sum_ext;      // 29-bit for add carry
    logic [27:0]        diff28;
    logic [27:0]        norm_sig;     // normalised 28-bit significand (leading 1 at 27)
    logic signed [11:0] norm_exp;
    logic               res_sign;
    logic               is_zero_res;
    assign big28   = {big27, 1'b0};
    assign small28 = {small_aligned, align_sticky};

    // leading-1 position for the subtract normalisation
    function automatic logic [4:0] msb28(input logic [27:0] m);
        logic [4:0] idx; integer i;
        idx = 5'd0;
        for (i = 0; i < 28; i = i + 1) if (m[i]) idx = i[4:0];
        return idx;
    endfunction

    logic [4:0]  lead_pos;
    logic [4:0]  lshift;
    always_comb begin
        sum_ext     = '0;
        diff28      = '0;
        norm_sig    = '0;
        norm_exp    = big_exp;
        is_zero_res = 1'b0;
        lead_pos    = 5'd0;
        lshift      = 5'd0;

        if (!eff_sub) begin
            // ---- addition ----
            sum_ext = {1'b0, big28} + {1'b0, small28};
            if (sum_ext[28]) begin
                // carry out: shift right 1 (LSB folds into the sticky region), exp+1
                norm_sig = sum_ext[28:1];
                norm_exp = big_exp + 12'sd1;
            end else begin
                norm_sig = sum_ext[27:0];
                norm_exp = big_exp;
            end
        end else begin
            // ---- subtraction (big28 >= small28: strict when d>0, else sig ordered) ----
            diff28 = big28 - small28;
            if (diff28 == 28'd0) begin
                is_zero_res = 1'b1;            // exact cancellation
            end else begin
                lead_pos = msb28(diff28);
                lshift   = 5'd27 - lead_pos;
                norm_sig = diff28 << lshift;
                norm_exp = big_exp - $signed({7'b0, lshift});
            end
        end
    end

    // Result sign: larger magnitude wins; exact zero uses the RDN rule.
    assign res_sign = is_zero_res ? (rm_i == FRM_RDN) : big_sign;

    // ---- assemble frac_i for the packer (leading 1 at bit 27) ----
    logic [25:0]        frac_s;
    logic               pack_sticky_s;
    assign frac_s        = norm_sig[27:2];        // {1, m[22:0], G, R}
    assign pack_sticky_s = |norm_sig[1:0];

    word_t   pack_result;
    fflags_t pack_flags;
    fp_pack u_pack (
        .sign_i (res_sign),
        .exp_i  (norm_exp),
        .frac_i (frac_s),
        .sticky_i(pack_sticky_s),
        .rm_i   (rm_i),
        .result_o(pack_result),
        .fflags_o(pack_flags)
    );

    // ---- special-case mux ----
    logic inf_inf_invalid;
    assign inf_inf_invalid = a_inf && b_inf && (sa != sb_eff);

    always_comb begin
        if (a_nan || b_nan) begin
            result_o = FP_QNAN;
            fflags_o = (a_snan || b_snan) ? 5'b10000 : 5'b00000;
        end else if (inf_inf_invalid) begin
            result_o = FP_QNAN;                    // inf + (-inf)
            fflags_o = 5'b10000;                   // NV
        end else if (a_inf) begin
            result_o = {sa, 8'hFF, 23'd0};
            fflags_o = 5'b00000;
        end else if (b_inf) begin
            result_o = {sb_eff, 8'hFF, 23'd0};
            fflags_o = 5'b00000;
        end else if (a_zero && b_zero) begin
            // +/-0 +/- +/-0 : -0 only when both effective signs are negative,
            // otherwise +0 (RDN gives -0 when signs differ).
            if (sa == sb_eff) result_o = {sa, 31'd0};
            else              result_o = {(rm_i == FRM_RDN), 31'd0};
            fflags_o = 5'b00000;
        end else if (a_zero) begin
            result_o = b_i ^ ((op_i == FPU_SUB) ? 32'h8000_0000 : 32'h0);  // ±b
            fflags_o = 5'b00000;
        end else if (b_zero) begin
            result_o = a_i;
            fflags_o = 5'b00000;
        end else if (is_zero_res) begin
            result_o = {res_sign, 31'd0};          // exact cancellation
            fflags_o = 5'b00000;
        end else begin
            result_o = pack_result;
            fflags_o = pack_flags;
        end
    end

endmodule : fp_addsub

`default_nettype wire
