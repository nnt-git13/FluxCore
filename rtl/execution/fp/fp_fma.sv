// rtl/execution/fp/fp_fma.sv
//
// IEEE-754 single-precision fused multiply-add: FMADD/FMSUB/FNMSUB/FNMADD.
// Computes (+/-a*b) +/- c with a SINGLE rounding (the defining property of a
// fused MAC — the product a*b is kept to full 48-bit precision and added to c
// before the one and only rounding).
//
//   FMADD.S   (a*b) + c
//   FMSUB.S   (a*b) - c
//   FNMSUB.S  -(a*b) + c
//   FNMADD.S  -(a*b) - c
//
// Method: exact 24x24 product; both product and addend are placed into a wide
// 128-bit accumulator anchored at the larger operand's exponent (smaller shifted
// right, sticky-preserving); add or subtract; leading-zero normalise; round once
// through the shared fp_pack back-end. Combinational (single EX cycle).

`default_nettype none

module fp_fma
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
    import fp_pkg::*;
(
    input  wire word_t      a_i,
    input  wire word_t      b_i,
    input  wire word_t      c_i,
    input  wire fpu_op_e    op_i,
    input  wire logic [2:0] rm_i,
    output word_t           result_o,
    output fflags_t         fflags_o
);
    localparam int ACC_W = 128;
    localparam int BASE  = 100;   // anchor operand's leading 1 sits here

    // ---- unpack ----
    logic        sa, sb, sc;
    logic [7:0]  ea, eb, ec;
    logic [22:0] ma, mb, mc;
    logic        a_nan,b_nan,c_nan, a_inf,b_inf,c_inf, a_zero,b_zero,c_zero;
    logic        a_sub,b_sub,c_sub, a_snan,b_snan,c_snan;

    assign sa=a_i[31]; assign ea=a_i[30:23]; assign ma=a_i[22:0];
    assign sb=b_i[31]; assign eb=b_i[30:23]; assign mb=b_i[22:0];
    assign sc=c_i[31]; assign ec=c_i[30:23]; assign mc=c_i[22:0];
    assign a_nan=fp_is_nan(a_i); assign b_nan=fp_is_nan(b_i); assign c_nan=fp_is_nan(c_i);
    assign a_inf=fp_is_inf(a_i); assign b_inf=fp_is_inf(b_i); assign c_inf=fp_is_inf(c_i);
    assign a_zero=fp_is_zero(a_i);assign b_zero=fp_is_zero(b_i);assign c_zero=fp_is_zero(c_i);
    assign a_sub=fp_is_subnormal(a_i);assign b_sub=fp_is_subnormal(b_i);assign c_sub=fp_is_subnormal(c_i);
    assign a_snan=fp_is_snan(a_i);assign b_snan=fp_is_snan(b_i);assign c_snan=fp_is_snan(c_i);

    function automatic logic [4:0] msb23(input logic [22:0] m);
        logic [4:0] idx; integer i; idx=5'd0;
        for (i=0;i<23;i=i+1) if (m[i]) idx=i[4:0];
        return idx;
    endfunction

    // ---- normalise operands to 24-bit significand + unbiased leading exponent
    logic [23:0]        sig_a, sig_b, sig_c;
    logic signed [11:0] exp_a, exp_b, exp_c;
    always_comb begin
        if (a_sub) begin sig_a=24'(ma)<<(5'd23-msb23(ma)); exp_a=-12'sd149+$signed({7'b0,msb23(ma)}); end
        else       begin sig_a={1'b1,ma}; exp_a=$signed({4'b0,ea})-12'sd127; end
        if (b_sub) begin sig_b=24'(mb)<<(5'd23-msb23(mb)); exp_b=-12'sd149+$signed({7'b0,msb23(mb)}); end
        else       begin sig_b={1'b1,mb}; exp_b=$signed({4'b0,eb})-12'sd127; end
        if (c_sub) begin sig_c=24'(mc)<<(5'd23-msb23(mc)); exp_c=-12'sd149+$signed({7'b0,msb23(mc)}); end
        else       begin sig_c={1'b1,mc}; exp_c=$signed({4'b0,ec})-12'sd127; end
    end

    // ---- effective signs ----
    logic neg_prod, sub_c, p_sign, c_sign;
    assign neg_prod = (op_i==FPU_NMSUB) || (op_i==FPU_NMADD);
    assign sub_c    = (op_i==FPU_MSUB)  || (op_i==FPU_NMADD);
    assign p_sign   = sa ^ sb ^ neg_prod;
    assign c_sign   = sc ^ sub_c;

    // ---- product (exact 48-bit), normalised so the leading 1 is at bit 47 ----
    logic [47:0]        PS, PSn;
    logic signed [11:0] pe, ce_s;
    logic               p_is_zero;
    assign PS  = sig_a * sig_b;
    assign PSn = PS[47] ? PS : {PS[46:0], 1'b0};
    assign pe  = exp_a + exp_b + (PS[47] ? 12'sd1 : 12'sd0);   // exp of PSn[47]
    assign ce_s = exp_c;                                        // exp of sig_c[23]
    assign p_is_zero = a_zero | b_zero;

    // ---- anchor at the larger leading exponent ----
    logic signed [11:0] anchor, psh, csh;
    always_comb begin
        if (p_is_zero)      anchor = ce_s;
        else if (c_zero)    anchor = pe;
        else                anchor = (pe >= ce_s) ? pe : ce_s;
    end
    assign psh = anchor - pe;      // >= 0
    assign csh = anchor - ce_s;    // >= 0

    // ---- place product and addend into the 128-bit accumulator ----
    // product leading 1 (PSn[47]) target bit = BASE - psh  → left-shift by (BASE-47-psh)
    // addend  leading 1 (sig_c[23]) target bit = BASE - csh → left-shift by (BASE-23-csh)
    logic signed [11:0] p_lsh, c_lsh;
    assign p_lsh = BASE - 12'sd47 - psh;
    assign c_lsh = BASE - 12'sd23 - csh;

    logic [ACC_W-1:0] acc_p, acc_c;
    logic             stk_p, stk_c;
    always_comb begin
        // product
        if (p_is_zero) begin acc_p='0; stk_p=1'b0; end
        else if (p_lsh >= 0) begin
            acc_p = (p_lsh > 12'sd80) ? '0 : (ACC_W'(PSn) << p_lsh[6:0]);
            stk_p = 1'b0;
        end else begin
            logic [11:0] rsh; rsh = -p_lsh;
            if (rsh >= 12'sd48) begin acc_p='0; stk_p=|PSn; end
            else begin
                acc_p = ACC_W'(PSn >> rsh[5:0]);
                stk_p = |(PSn & ((48'd1 << rsh[5:0]) - 48'd1));
            end
        end
        // addend
        if (c_zero) begin acc_c='0; stk_c=1'b0; end
        else if (c_lsh >= 0) begin
            acc_c = (c_lsh > 12'sd100) ? '0 : (ACC_W'(sig_c) << c_lsh[6:0]);
            stk_c = 1'b0;
        end else begin
            logic [11:0] rshc; rshc = -c_lsh;
            if (rshc >= 12'sd24) begin acc_c='0; stk_c=|sig_c; end
            else begin
                acc_c = ACC_W'(sig_c >> rshc[4:0]);
                stk_c = |(sig_c & ((24'd1 << rshc[4:0]) - 24'd1));
            end
        end
    end

    // ---- add / subtract ----
    logic              eff_sub, res_sign, sum_zero;
    logic [ACC_W:0]    sum;                 // one extra bit for carry
    logic              sticky_shift;
    assign eff_sub      = (p_sign != c_sign) & ~p_is_zero & ~c_zero;
    assign sticky_shift = stk_p | stk_c;
    always_comb begin
        sum_zero = 1'b0;
        if (p_is_zero && c_zero) begin
            sum = '0; res_sign = 1'b0; sum_zero = 1'b1;
        end else if (!eff_sub) begin
            sum = {1'b0, acc_p} + {1'b0, acc_c};
            res_sign = p_is_zero ? c_sign : p_sign;
        end else begin
            if (acc_p >= acc_c) begin sum = {1'b0, acc_p} - {1'b0, acc_c}; res_sign = p_sign; end
            else                begin sum = {1'b0, acc_c} - {1'b0, acc_p}; res_sign = c_sign; end
            if (acc_p == acc_c && !sticky_shift) sum_zero = 1'b1;
        end
    end

    // ---- leading-1 position of the 129-bit sum ----
    function automatic logic [7:0] msb_sum(input logic [ACC_W:0] v);
        logic [7:0] idx; integer i; idx=8'd0;
        for (i=0;i<=ACC_W;i=i+1) if (v[i]) idx=i[7:0];
        return idx;
    endfunction

    logic [7:0]         lead;
    logic [7:0]         norm_sh;
    logic [ACC_W:0]     nsum;              // sum left-normalised: leading 1 at bit ACC_W
    logic signed [11:0] rlead_exp;
    logic [25:0]        frac_s;
    logic               pack_sticky;
    always_comb begin
        lead      = msb_sum(sum);
        norm_sh   = 8'(ACC_W) - lead;              // shift leading 1 up to bit ACC_W (=128)
        nsum      = sum << norm_sh;
        // value = sum * 2^(anchor - BASE); leading 1 now at bit ACC_W
        rlead_exp = anchor - BASE + $signed({4'b0, lead});
        // frac26 = { leading 1, m[22:0], G, R } = nsum[128:103]
        frac_s      = nsum[ACC_W -: 26];
        pack_sticky = sticky_shift | (|nsum[ACC_W-26 : 0]);
    end

    word_t   pack_result;
    fflags_t pack_flags;
    fp_pack u_pack (
        .sign_i(res_sign), .exp_i(rlead_exp), .frac_i(frac_s), .sticky_i(pack_sticky),
        .rm_i(rm_i), .result_o(pack_result), .fflags_o(pack_flags)
    );

    // ---- special-case handling ----
    logic any_snan, prod_inf, invalid_prod, invalid_infsum;
    assign any_snan       = a_snan | b_snan | c_snan;
    assign prod_inf       = (a_inf | b_inf) & ~(a_zero | b_zero);      // a*b is inf
    assign invalid_prod   = (a_inf & b_zero) | (a_zero & b_inf);       // inf*0
    // (a*b = inf) + (c = inf of opposite sign)  → inf - inf
    assign invalid_infsum = prod_inf & c_inf & (p_sign != c_sign);

    always_comb begin
        if (a_nan || b_nan || c_nan) begin
            result_o = FP_QNAN;
            fflags_o = any_snan ? 5'b10000 : 5'b00000;
        end else if (invalid_prod || invalid_infsum) begin
            result_o = FP_QNAN;
            fflags_o = 5'b10000;                         // NV
        end else if (prod_inf) begin
            result_o = {p_sign, 8'hFF, 23'd0};           // product infinity dominates
            fflags_o = 5'b00000;
        end else if (c_inf) begin
            result_o = {c_sign, 8'hFF, 23'd0};
            fflags_o = 5'b00000;
        end else if (sum_zero) begin
            // exact zero result: +0 except round-down → -0
            result_o = {(rm_i == FRM_RDN), 31'd0};
            fflags_o = 5'b00000;
        end else begin
            result_o = pack_result;
            fflags_o = pack_flags;
        end
    end

endmodule : fp_fma

`default_nettype wire
