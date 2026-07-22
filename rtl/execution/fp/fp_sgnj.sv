// rtl/execution/fp/fp_sgnj.sv
//
// FP sign-injection: FSGNJ.S / FSGNJN.S / FSGNJX.S.
//
// Purely combinational. Copies the magnitude bits [30:0] of operand a and
// replaces the sign per the operation:
//   FSGNJ  : sign = sign(b)
//   FSGNJN : sign = ~sign(b)
//   FSGNJX : sign = sign(a) ^ sign(b)
//
// Sign injection is a bit-manipulation, not an arithmetic op: it never raises
// an exception flag, and it treats NaN operands purely by their bit pattern
// (it does NOT canonicalise a NaN result). fflags_o is always 0.

`default_nettype none

module fp_sgnj
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
(
    input  wire word_t   a_i,
    input  wire word_t   b_i,
    input  wire fpu_op_e op_i,     // FPU_SGNJ / FPU_SGNJN / FPU_SGNJX
    output word_t        result_o,
    output fflags_t      fflags_o
);
    logic sign_s;

    always_comb begin
        unique case (op_i)
            FPU_SGNJN: sign_s = ~b_i[31];
            FPU_SGNJX: sign_s = a_i[31] ^ b_i[31];
            default:   sign_s = b_i[31];   // FPU_SGNJ
        endcase
    end

    assign result_o = {sign_s, a_i[30:0]};
    assign fflags_o = '0;   // sign injection never signals

endmodule : fp_sgnj

`default_nettype wire
