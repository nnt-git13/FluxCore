// rtl/execution/fp/fp_divsqrt.sv
//
// IEEE-754 single-precision divide (FDIV.S) and square root (FSQRT.S).
// Iterative, sharing the mul_div_unit start/busy/idle handshake: start_i pulses
// for one cycle when the op enters EX and the unit is idle; busy_o freezes the
// whole pipeline (a new fpu_stall) for the ~27 iteration cycles; result_o /
// fflags_o are valid once busy_o deasserts.
//
//   Divide : restoring recurrence, 27 quotient bits, then round via fp_pack.
//   Sqrt   : restoring integer square root, 2 radicand bits per cycle.
//
// Both normalise subnormal operands, handle NaN/inf/zero (and negative sqrt),
// set NV/DZ where required, and round the significand through fp_pack.

`default_nettype none

module fp_divsqrt
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
    import fp_pkg::*;
(
    input  wire logic     clk,
    input  wire logic     rst,
    input  wire word_t    a_i,
    input  wire word_t    b_i,
    input  wire fpu_op_e  op_i,      // FPU_DIV or FPU_SQRT
    input  wire logic [2:0] rm_i,
    input  wire logic     start_i,
    output word_t         result_o,
    output fflags_t       fflags_o,
    output logic          busy_o,
    output logic          idle_o
);
    // -----------------------------------------------------------------------
    // Operand unpack + subnormal normalisation (combinational, sampled at load)
    // -----------------------------------------------------------------------
    function automatic logic [4:0] msb23(input logic [22:0] m);
        logic [4:0] idx; integer i; idx=5'd0;
        for (i=0;i<23;i=i+1) if (m[i]) idx=i[4:0];
        return idx;
    endfunction

    logic        sa, sb;
    logic [7:0]  ea, eb;
    logic [22:0] ma, mb;
    logic        a_nan,b_nan,a_inf,b_inf,a_zero,b_zero,a_sub,b_sub,a_snan,b_snan;
    assign sa=a_i[31]; assign ea=a_i[30:23]; assign ma=a_i[22:0];
    assign sb=b_i[31]; assign eb=b_i[30:23]; assign mb=b_i[22:0];
    assign a_nan=fp_is_nan(a_i); assign b_nan=fp_is_nan(b_i);
    assign a_inf=fp_is_inf(a_i); assign b_inf=fp_is_inf(b_i);
    assign a_zero=fp_is_zero(a_i); assign b_zero=fp_is_zero(b_i);
    assign a_sub=fp_is_subnormal(a_i); assign b_sub=fp_is_subnormal(b_i);
    assign a_snan=fp_is_snan(a_i); assign b_snan=fp_is_snan(b_i);

    logic [23:0]        sig_a, sig_b;
    logic signed [11:0] exp_a, exp_b;
    always_comb begin
        if (a_sub) begin sig_a=24'(ma)<<(5'd23-msb23(ma)); exp_a=-12'sd149+$signed({7'b0,msb23(ma)}); end
        else       begin sig_a={1'b1,ma}; exp_a=$signed({4'b0,ea})-12'sd127; end
        if (b_sub) begin sig_b=24'(mb)<<(5'd23-msb23(mb)); exp_b=-12'sd149+$signed({7'b0,msb23(mb)}); end
        else       begin sig_b={1'b1,mb}; exp_b=$signed({4'b0,eb})-12'sd127; end
    end

    logic is_sqrt;
    assign is_sqrt = (op_i == FPU_SQRT);

    // -----------------------------------------------------------------------
    // Sequential iterative state
    // -----------------------------------------------------------------------
    logic        busy_q;
    logic [5:0]  count_q;            // counts iterations remaining
    // divide state
    logic [24:0] div_rem_q;          // running remainder (kept < divisor)
    logic [26:0] div_q_q;            // accumulated fractional quotient bits
    logic [23:0] div_divisor_q;
    logic        div_qint_q;         // integer quotient bit (1 when sig_a >= sig_b)
    // sqrt state
    logic [55:0] sqrt_x_q;           // radicand, top-aligned; 2 bits consumed per cycle
    logic [31:0] sqrt_rem_q;
    logic [27:0] sqrt_root_q;        // 28 result bits (leading 1 at bit 27)
    // metadata registered at load
    logic        op_sqrt_q;
    logic        res_sign_q;
    logic signed [11:0] res_exp_q;   // result leading-1 exponent (pre-normalisation adj)
    logic        special_q;
    word_t       special_res_q;
    fflags_t     special_flags_q;

    assign busy_o = busy_q | start_i;
    assign idle_o = ~busy_q;

    // Load-time computed values
    logic signed [11:0] load_exp_s;
    logic               even_s;
    logic [55:0]        sqrt_x_s;
    always_comb begin
        // divide: result lead exp handled after the loop (needs quotient MSB);
        //         we register eA-eB as the base.
        // sqrt : result lead exp = floor(exp_a/2); radicand scaled by parity.
        even_s     = ~exp_a[0];
        load_exp_s = is_sqrt ? (exp_a >>> 1) : (exp_a - exp_b);
        // radicand top-aligned so its MSB sits in the top bit-pair [55:54]:
        //   even exp → sqrt(1.f)   (mant_in ∈ [1,2)), X = sig_a << 31
        //   odd  exp → sqrt(2·1.f) (mant_in ∈ [2,4)), X = sig_a << 32
        // root = floor(sqrt(X)) = sqrt(mant_in)·2^27 → leading 1 at bit 27.
        sqrt_x_s   = even_s ? (56'(sig_a) << 31) : (56'(sig_a) << 32);
    end

    // Special-case detection at load
    logic        sp_valid_s;
    word_t       sp_res_s;
    fflags_t     sp_flags_s;
    logic        div_sign_s;
    assign div_sign_s = sa ^ sb;
    always_comb begin
        sp_valid_s = 1'b1;
        sp_res_s   = FP_QNAN;
        sp_flags_s = 5'b00000;
        if (is_sqrt) begin
            if (a_nan)                 begin sp_res_s=FP_QNAN; sp_flags_s=a_snan?5'b10000:5'b0; end
            else if (a_zero)           begin sp_res_s={sa,31'd0}; sp_flags_s=5'b0; end  // sqrt(±0)=±0
            else if (sa)               begin sp_res_s=FP_QNAN; sp_flags_s=5'b10000; end // sqrt(<0)=NV
            else if (a_inf)            begin sp_res_s=FP_POS_INF; sp_flags_s=5'b0; end
            else                        sp_valid_s = 1'b0;                              // normal
        end else begin
            if (a_nan || b_nan)        begin sp_res_s=FP_QNAN; sp_flags_s=(a_snan|b_snan)?5'b10000:5'b0; end
            else if (a_inf && b_inf)   begin sp_res_s=FP_QNAN; sp_flags_s=5'b10000; end // inf/inf
            else if (a_zero && b_zero) begin sp_res_s=FP_QNAN; sp_flags_s=5'b10000; end // 0/0
            else if (a_inf)            begin sp_res_s={div_sign_s,8'hFF,23'd0}; sp_flags_s=5'b0; end // inf/x
            else if (b_zero)           begin sp_res_s={div_sign_s,8'hFF,23'd0}; sp_flags_s=5'b01000; end // x/0 DZ
            else if (b_inf)            begin sp_res_s={div_sign_s,31'd0}; sp_flags_s=5'b0; end // x/inf=0
            else if (a_zero)           begin sp_res_s={div_sign_s,31'd0}; sp_flags_s=5'b0; end // 0/x=0
            else                        sp_valid_s = 1'b0;                              // normal
        end
    end

    // Divide combinational step (restoring). The remainder is kept < divisor by
    // the load-time seeding below, so div_trial[24] is a clean borrow bit.
    logic [24:0] div_rem_shl;
    logic [24:0] div_trial;
    assign div_rem_shl = {div_rem_q[23:0], 1'b0};
    assign div_trial   = div_rem_shl - {1'b0, div_divisor_q};
    // Load-time seed: integer bit and initial remainder (< divisor).
    logic        div_qint_s;
    logic [24:0] div_rem_init_s;
    assign div_qint_s     = (sig_a >= sig_b);
    assign div_rem_init_s = div_qint_s ? {1'b0, (sig_a - sig_b)} : {1'b0, sig_a};

    // Sqrt combinational step (restoring, 2 bits/iter), explicit magnitude compare.
    logic [31:0] sqrt_rem_shl;
    logic [31:0] sqrt_op;
    logic        sqrt_ge;
    assign sqrt_rem_shl = {sqrt_rem_q[29:0], sqrt_x_q[55:54]};
    assign sqrt_op      = {2'b0, sqrt_root_q[27:0], 2'b01};   // 4*root + 1
    assign sqrt_ge      = (sqrt_rem_shl >= sqrt_op);

    always_ff @(posedge clk) begin
        if (rst) begin
            busy_q <= 1'b0; count_q <= '0;
            div_rem_q <= '0; div_q_q <= '0; div_divisor_q <= '0; div_qint_q <= 1'b0;
            sqrt_x_q <= '0; sqrt_rem_q <= '0; sqrt_root_q <= '0;
            op_sqrt_q <= 1'b0; res_sign_q <= 1'b0; res_exp_q <= '0;
            special_q <= 1'b0; special_res_q <= '0; special_flags_q <= '0;
        end else if (start_i && !busy_q) begin
            busy_q      <= 1'b1;
            // divide: 27 iterations (27 quotient bits); sqrt: 28 (28 root bits).
            count_q     <= is_sqrt ? 6'd27 : 6'd26;
            op_sqrt_q   <= is_sqrt;
            res_sign_q  <= is_sqrt ? 1'b0 : div_sign_s;
            res_exp_q   <= load_exp_s;
            special_q   <= sp_valid_s;
            special_res_q   <= sp_res_s;
            special_flags_q <= sp_flags_s;
            // divide init: seed integer bit, rem < divisor, quotient = 0
            div_rem_q   <= div_rem_init_s;
            div_divisor_q <= sig_b;
            div_q_q     <= '0;
            div_qint_q  <= div_qint_s;
            // sqrt init
            sqrt_x_q    <= sqrt_x_s;
            sqrt_rem_q  <= '0;
            sqrt_root_q <= '0;
        end else if (busy_q) begin
            if (!op_sqrt_q) begin
                // ---- divide iteration ----
                if (!div_trial[24]) begin      // rem_shl >= divisor
                    div_rem_q <= div_trial;
                    div_q_q   <= {div_q_q[25:0], 1'b1};
                end else begin
                    div_rem_q <= div_rem_shl;
                    div_q_q   <= {div_q_q[25:0], 1'b0};
                end
            end else begin
                // ---- sqrt iteration (2 radicand bits per cycle) ----
                if (sqrt_ge) begin
                    sqrt_rem_q  <= sqrt_rem_shl - sqrt_op;
                    sqrt_root_q <= {sqrt_root_q[26:0], 1'b1};
                end else begin
                    sqrt_rem_q  <= sqrt_rem_shl;
                    sqrt_root_q <= {sqrt_root_q[26:0], 1'b0};
                end
                sqrt_x_q <= {sqrt_x_q[53:0], 2'b00};
            end
            if (count_q == 0) busy_q <= 1'b0;
            else              count_q <= count_q - 6'd1;
        end
    end

    // -----------------------------------------------------------------------
    // Result assembly (combinational from the registered final state)
    // -----------------------------------------------------------------------
    // Full quotient = { integer bit, 27 fractional bits }; leading 1 at bit 27
    // when sig_a >= sig_b, else at bit 26 (quotient in [0.5,1)).
    logic [27:0]        div_full;
    logic               d_lead27;
    logic [25:0]        d_frac;
    logic               d_sticky;
    logic signed [11:0] d_exp;
    assign div_full = {div_qint_q, div_q_q[26:0]};
    assign d_lead27 = div_qint_q;
    assign d_frac   = d_lead27 ? div_full[27:2] : div_full[26:1];
    assign d_sticky = (d_lead27 ? |div_full[1:0] : |div_full[0]) | (div_rem_q != 25'd0);
    assign d_exp    = res_exp_q + (d_lead27 ? 12'sd0 : -12'sd1);

    // Sqrt: root = floor(sqrt(X)); leading 1 at bit 27 (top-aligned radicand).
    logic [25:0]        s_frac;
    logic               s_sticky;
    logic signed [11:0] s_exp;
    assign s_frac   = sqrt_root_q[27:2];
    assign s_sticky = |sqrt_root_q[1:0] | (sqrt_rem_q != 32'd0);
    assign s_exp    = res_exp_q;

    logic [25:0]        pack_frac;
    logic               pack_sticky;
    logic signed [11:0] pack_exp;
    assign pack_frac   = op_sqrt_q ? s_frac   : d_frac;
    assign pack_sticky = op_sqrt_q ? s_sticky : d_sticky;
    assign pack_exp    = op_sqrt_q ? s_exp    : d_exp;

    word_t   pack_result;
    fflags_t pack_flags;
    fp_pack u_pack (
        .sign_i(res_sign_q), .exp_i(pack_exp), .frac_i(pack_frac), .sticky_i(pack_sticky),
        .rm_i(rm_i), .result_o(pack_result), .fflags_o(pack_flags)
    );

    assign result_o = special_q ? special_res_q   : pack_result;
    assign fflags_o = special_q ? special_flags_q : pack_flags;

endmodule : fp_divsqrt

`default_nettype wire
