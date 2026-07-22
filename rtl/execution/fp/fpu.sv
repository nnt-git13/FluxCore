// rtl/execution/fp/fpu.sv
//
// Top-level FPU: routes an fpu_op to the appropriate execution unit and returns
// the result plus IEEE flags.
//
//   Single-cycle combinational : short ops (sgnj/minmax/cmp/class/cvt/fmv),
//                                multiply, add/sub, fused multiply-add.
//   Iterative (multi-cycle)     : divide and square root — these use the
//                                start_i/busy_o/idle_o handshake and freeze the
//                                pipeline (fpu_stall) while running, exactly like
//                                the integer mul_div_unit's divider.
//
// Operand routing (all pre-forwarded by the pipeline):
//   fs1_i / fs2_i / fs3_i  FP register sources (fs3 only for the FMADD family)
//   xrs1_i                 integer rs1 (FCVT.S.W[U], FMV.W.X)
//   rm_i                   resolved rounding mode (dynamic already resolved)

`default_nettype none

module fpu
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
    import fp_pkg::*;
(
    input  wire logic       clk,
    input  wire logic       rst,
    input  wire word_t      fs1_i,
    input  wire word_t      fs2_i,
    input  wire word_t      fs3_i,
    input  wire word_t      xrs1_i,
    input  wire fpu_op_e    op_i,
    input  wire logic [2:0] rm_i,
    // Multi-cycle (divide/sqrt) handshake
    input  wire logic       start_i,     // pulse when a DIV/SQRT enters EX and unit idle
    output logic            busy_o,       // 1 while divide/sqrt iterating (→ fpu_stall)
    output logic            idle_o,       // ~busy (registered), for start generation
    output word_t           result_o,
    output fflags_t         fflags_o
);
    // ---- combinational units ----
    word_t   short_r, mul_r, add_r, fma_r;
    fflags_t short_f, mul_f, add_f, fma_f;

    fp_short u_short (
        .fa_i(fs1_i), .fb_i(fs2_i), .xrs1_i(xrs1_i), .op_i(op_i), .rm_i(rm_i),
        .result_o(short_r), .fflags_o(short_f)
    );
    fp_mul u_mul (
        .a_i(fs1_i), .b_i(fs2_i), .rm_i(rm_i), .result_o(mul_r), .fflags_o(mul_f)
    );
    fp_addsub u_addsub (
        .a_i(fs1_i), .b_i(fs2_i), .op_i(op_i), .rm_i(rm_i),
        .result_o(add_r), .fflags_o(add_f)
    );
    fp_fma u_fma (
        .a_i(fs1_i), .b_i(fs2_i), .c_i(fs3_i), .op_i(op_i), .rm_i(rm_i),
        .result_o(fma_r), .fflags_o(fma_f)
    );

    // ---- iterative divide / square root ----
    logic    is_divsqrt;
    word_t   ds_r;
    fflags_t ds_f;
    assign is_divsqrt = (op_i == FPU_DIV) || (op_i == FPU_SQRT);

    fp_divsqrt u_divsqrt (
        .clk(clk), .rst(rst),
        .a_i(fs1_i), .b_i(fs2_i), .op_i(op_i), .rm_i(rm_i),
        .start_i(start_i & is_divsqrt),
        .result_o(ds_r), .fflags_o(ds_f),
        .busy_o(busy_o), .idle_o(idle_o)
    );

    // ---- result select ----
    always_comb begin
        unique case (op_i)
            FPU_ADD, FPU_SUB:  begin result_o = add_r; fflags_o = add_f; end
            FPU_MUL:           begin result_o = mul_r; fflags_o = mul_f; end
            FPU_MADD, FPU_MSUB, FPU_NMSUB, FPU_NMADD:
                               begin result_o = fma_r; fflags_o = fma_f; end
            FPU_DIV, FPU_SQRT: begin result_o = ds_r;  fflags_o = ds_f;  end
            default:           begin result_o = short_r; fflags_o = short_f; end
        endcase
    end

endmodule : fpu

`default_nettype wire
