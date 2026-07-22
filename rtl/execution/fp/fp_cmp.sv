// rtl/execution/fp/fp_cmp.sv
//
// FP compare: FEQ.S / FLT.S / FLE.S. Purely combinational.
// Produces a 1-bit boolean (zero-extended to 32) written to an integer
// register, plus the IEEE invalid (NV) flag.
//
// Signalling behaviour (RISC-V unprivileged spec):
//   FEQ  is a *quiet* compare: it sets NV only if an operand is a signaling
//        NaN. A quiet NaN operand yields result 0 with no flag.
//   FLT/FLE are *signalling* compares: any NaN operand (quiet or signaling)
//        yields result 0 and sets NV.
// +0 and -0 compare equal.

`default_nettype none

module fp_cmp
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
    import fp_pkg::*;
(
    input  wire word_t   a_i,
    input  wire word_t   b_i,
    input  wire fpu_op_e op_i,     // FPU_EQ / FPU_LT / FPU_LE
    output word_t        result_o,
    output fflags_t      fflags_o
);
    logic a_nan_s, b_nan_s, any_nan_s, any_snan_s;
    logic res_s;
    logic nv_s;

    assign a_nan_s    = fp_is_nan(a_i);
    assign b_nan_s    = fp_is_nan(b_i);
    assign any_nan_s  = a_nan_s | b_nan_s;
    assign any_snan_s = fp_is_snan(a_i) | fp_is_snan(b_i);

    always_comb begin
        res_s = 1'b0;
        nv_s  = 1'b0;
        unique case (op_i)
            FPU_EQ: begin
                // quiet compare: NV only on signaling NaN
                nv_s  = any_snan_s;
                res_s = any_nan_s ? 1'b0 : fp_eq(a_i, b_i);
            end
            FPU_LT: begin
                nv_s  = any_nan_s;   // signalling compare
                res_s = any_nan_s ? 1'b0 : fp_lt(a_i, b_i);
            end
            default: begin  // FPU_LE
                nv_s  = any_nan_s;
                res_s = any_nan_s ? 1'b0 : (fp_lt(a_i, b_i) | fp_eq(a_i, b_i));
            end
        endcase
    end

    assign result_o = {31'b0, res_s};
    // fflags layout: [4]=NV [3]=DZ [2]=OF [1]=UF [0]=NX; only NV can be set here.
    assign fflags_o = {nv_s, 4'b0000};

endmodule : fp_cmp

`default_nettype wire
