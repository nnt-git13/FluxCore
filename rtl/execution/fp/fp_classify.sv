// rtl/execution/fp/fp_classify.sv
//
// FCLASS.S — classify a single-precision operand into a 10-bit one-hot mask
// written to an integer register. Purely combinational; raises no flags
// (FCLASS never signals, even on a signaling NaN).
//
// Result bit (RISC-V unprivileged spec, Table for FCLASS):
//   [0] a is -inf
//   [1] a is a negative normal number
//   [2] a is a negative subnormal number
//   [3] a is -0
//   [4] a is +0
//   [5] a is a positive subnormal number
//   [6] a is a positive normal number
//   [7] a is +inf
//   [8] a is a signaling NaN
//   [9] a is a quiet NaN
// Exactly one bit is set for any input. Upper 22 bits of result are 0.

`default_nettype none

module fp_classify
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
    import fp_pkg::*;
(
    input  wire word_t  a_i,
    output word_t       result_o,
    output fflags_t     fflags_o
);
    logic sign_s;
    logic [9:0] cls_s;

    assign sign_s = fp_sign(a_i);

    always_comb begin
        cls_s = '0;
        if (fp_is_nan(a_i)) begin
            cls_s[8] = fp_is_snan(a_i);
            cls_s[9] = fp_is_qnan(a_i);
        end else if (fp_is_inf(a_i)) begin
            cls_s[0] =  sign_s;   // -inf
            cls_s[7] = ~sign_s;   // +inf
        end else if (fp_is_zero(a_i)) begin
            cls_s[3] =  sign_s;   // -0
            cls_s[4] = ~sign_s;   // +0
        end else if (fp_is_subnormal(a_i)) begin
            cls_s[2] =  sign_s;   // -subnormal
            cls_s[5] = ~sign_s;   // +subnormal
        end else begin            // normal
            cls_s[1] =  sign_s;   // -normal
            cls_s[6] = ~sign_s;   // +normal
        end
    end

    assign result_o = {22'b0, cls_s};
    assign fflags_o = '0;

endmodule : fp_classify

`default_nettype wire
