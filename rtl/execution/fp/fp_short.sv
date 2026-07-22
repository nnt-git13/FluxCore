// rtl/execution/fp/fp_short.sv
//
// Combinational ("short-latency") FPU: every RV32F operation that completes in
// a single cycle. The multi-cycle arithmetic (add/sub/mul/div/sqrt/fma) is a
// separate unit combined with this one in fpu.sv (Phase C/D).
//
// Handles: FSGNJ[N/X], FMIN/FMAX, FEQ/FLT/FLE, FCLASS, FMV.X.W, FMV.W.X,
//          FCVT.W.S / FCVT.WU.S / FCVT.S.W / FCVT.S.WU.
//
// Operand routing:
//   fa_i   fs1 (float) — used by sgnj/minmax/cmp/class/fmv.x.w/fcvt.*.s
//   fb_i   fs2 (float) — used by sgnj/minmax/cmp
//   xrs1_i rs1 (integer) — used by fmv.w.x and fcvt.s.w[u]
//
// result_o goes to the FP register file for FP-producing ops and to the integer
// register file for FP→int ops (the decoder's writes_frd / writes_rd + WB_FPU
// select the destination downstream). fflags_o carries the IEEE flags to accrue.

`default_nettype none

module fp_short
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
    import fp_pkg::*;
(
    input  wire word_t      fa_i,     // fs1 (float)
    input  wire word_t      fb_i,     // fs2 (float)
    input  wire word_t      xrs1_i,   // rs1 (integer)
    input  wire fpu_op_e    op_i,
    input  wire logic [2:0] rm_i,     // resolved rounding mode
    output word_t           result_o,
    output fflags_t         fflags_o
);
    // Sub-unit outputs
    word_t   sgnj_r,  minmax_r, cmp_r,  class_r, cvt_r;
    fflags_t sgnj_f,  minmax_f, cmp_f,  class_f, cvt_f;

    fp_sgnj u_sgnj (
        .a_i(fa_i), .b_i(fb_i), .op_i(op_i), .result_o(sgnj_r), .fflags_o(sgnj_f)
    );
    fp_minmax u_minmax (
        .a_i(fa_i), .b_i(fb_i), .op_i(op_i), .result_o(minmax_r), .fflags_o(minmax_f)
    );
    fp_cmp u_cmp (
        .a_i(fa_i), .b_i(fb_i), .op_i(op_i), .result_o(cmp_r), .fflags_o(cmp_f)
    );
    fp_classify u_class (
        .a_i(fa_i), .result_o(class_r), .fflags_o(class_f)
    );
    fp_cvt u_cvt (
        .a_i(fa_i), .int_i(xrs1_i), .op_i(op_i), .rm_i(rm_i),
        .result_o(cvt_r), .fflags_o(cvt_f)
    );

    always_comb begin
        unique case (op_i)
            FPU_SGNJ, FPU_SGNJN, FPU_SGNJX: begin
                result_o = sgnj_r;   fflags_o = sgnj_f;
            end
            FPU_MIN, FPU_MAX: begin
                result_o = minmax_r; fflags_o = minmax_f;
            end
            FPU_EQ, FPU_LT, FPU_LE: begin
                result_o = cmp_r;    fflags_o = cmp_f;
            end
            FPU_CLASS: begin
                result_o = class_r;  fflags_o = class_f;
            end
            FPU_CVT_W_S, FPU_CVT_WU_S, FPU_CVT_S_W, FPU_CVT_S_WU: begin
                result_o = cvt_r;    fflags_o = cvt_f;
            end
            FPU_MV_X_W: begin        // float bits → integer reg
                result_o = fa_i;     fflags_o = '0;
            end
            FPU_MV_W_X: begin        // integer bits → fp reg
                result_o = xrs1_i;   fflags_o = '0;
            end
            default: begin
                result_o = '0;       fflags_o = '0;
            end
        endcase
    end

endmodule : fp_short

`default_nettype wire
