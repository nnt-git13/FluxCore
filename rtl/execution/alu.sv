// rtl/execution/alu.sv
//
// FluxCore integer ALU.
//
// Purpose:
//   Pure combinational arithmetic and logic unit for the RV32I integer
//   instruction set. Accepts two 32-bit operands and an operation selector;
//   produces a 32-bit result with no internal state.
//
// Timing:
//   Combinational only. No clock, no reset, no registers.
//   The pipeline register at the ID/EX or EX/MEM boundary captures the result.
//
// Latency:
//   0 pipeline cycles. Result is valid after combinational propagation delay.
//
// Handshake:
//   None. Inputs drive outputs directly. The pipeline stall/flush logic
//   operates on the pipeline registers that surround this module.
//
// Assumptions:
//   - Shift amount is taken from b_i[4:0] only, per RISC-V specification.
//     The upper bits of b_i are ignored for all shift operations.
//   - Signed operations (ALU_SRA, ALU_SLT) use explicit $signed() casts.
//     Do not assume implicit signedness of logic types.
//   - ALU_COPY_B is used for LUI: the immediate value arrives on b_i and is
//     passed directly to the result. The a_i input is ignored.
//   - The ALU does not perform branch comparison; that is the branch unit's
//     responsibility.
//   - The ALU does not know about register numbers, thread IDs, memory
//     state, or writeback destinations.

`default_nettype none

module alu
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
(
    input  wire word_t    a_i,      // operand A: typically rs1 value or PC
    input  wire word_t    b_i,      // operand B: typically rs2 value or immediate
    input  wire alu_op_e  op_i,     // operation select
    output word_t    result_o  // combinational result
);

    always_comb begin
        // Default assignment satisfies all tools even if the case is extended.
        result_o = '0;

        case (op_i)
            ALU_ADD:    result_o = a_i + b_i;
            ALU_SUB:    result_o = a_i - b_i;
            ALU_AND:    result_o = a_i & b_i;
            ALU_OR:     result_o = a_i | b_i;
            ALU_XOR:    result_o = a_i ^ b_i;

            // Shift amount is always b_i[4:0]; upper bits are architecturally ignored.
            ALU_SLL:    result_o = a_i << b_i[4:0];
            ALU_SRL:    result_o = a_i >> b_i[4:0];

            // Arithmetic right shift: sign bit propagates. Requires $signed cast
            // because the logic type is unsigned by default.
            ALU_SRA:    result_o = word_t'($signed(a_i) >>> b_i[4:0]);

            // Signed comparison: result is 0 or 1, zero-extended to XLEN.
            // $signed cast is mandatory here; without it the comparison is unsigned.
            ALU_SLT:    result_o = {31'd0, $signed(a_i) < $signed(b_i)};

            // Unsigned comparison.
            ALU_SLTU:   result_o = {31'd0, a_i < b_i};

            // Pass operand B directly. Used for LUI where the upper immediate
            // arrives pre-shifted from the immediate generator.
            ALU_COPY_B: result_o = b_i;

            // ------------------------------------------------------------------
            // XFlux custom operations
            // ------------------------------------------------------------------

            // Indexed-load address: rs1 + (rs2 << 2). Eliminates SLLI+ADD for
            // accessing word arrays by index (SpMV column-index gather pattern).
            ALU_XLIDX_ADDR: result_o = a_i + (b_i << 2);

            // Absolute value of signed input.
            ALU_XABS: result_o = a_i[31] ? word_t'(-$signed(a_i)) : a_i;

            // Signed minimum and maximum. Direct data-path comparators; avoids
            // a branch instruction in the inner SpMV loop for value clamping.
            ALU_XMIN: result_o = ($signed(a_i) < $signed(b_i)) ? a_i : b_i;
            ALU_XMAX: result_o = ($signed(a_i) > $signed(b_i)) ? a_i : b_i;

            // Count leading zeros. Loop ascending so the highest set bit wins.
            ALU_XCLZ: begin
                result_o = 32'd32;
                for (int k = 0; k < 32; k++)
                    if (a_i[k]) result_o = 32'(31 - k);
            end

            // RV32M ops (ALU_MUL..ALU_REMU) are handled by mul_div_unit in
            // fluxcore_top and routed around the ALU in execute_stage.
            default: ; // result_o already defaulted to '0 above
        endcase
    end

endmodule : alu

`default_nettype wire
