// rtl/common/imm_gen.sv
//
// FluxCore immediate generator.
//
// Purpose:
//   Extracts and sign-extends the immediate value from a raw 32-bit RISC-V
//   instruction, given its encoding format. The result is always XLEN bits.
//
// Inputs:
//   instr_i  — the raw 32-bit instruction word
//   fmt_i    — the instruction format enum (IFMT_R through IFMT_J)
//
// Output:
//   imm_o    — the fully sign-extended immediate, XLEN bits wide
//
// Timing:
//   Purely combinational. No clock or reset ports.
//
// Format encoding rules (RISC-V unprivileged specification, Ch.2):
//
//   IFMT_R  — no immediate; result is 0
//   IFMT_I  — imm[11:0]  = instr[31:20], sign-extended
//   IFMT_S  — imm[11:5]  = instr[31:25], imm[4:0] = instr[11:7], sign-extended
//   IFMT_B  — imm[12]    = instr[31]
//              imm[10:5]  = instr[30:25]
//              imm[4:1]   = instr[11:8]
//              imm[11]    = instr[7]
//              imm[0]     = 0 (always; branches are 2-byte aligned)
//              sign-extended from bit 12
//   IFMT_U  — imm[31:12] = instr[31:12], imm[11:0] = 0 (no sign extension needed)
//   IFMT_J  — imm[20]    = instr[31]
//              imm[10:1]  = instr[30:21]
//              imm[11]    = instr[20]
//              imm[19:12] = instr[19:12]
//              imm[0]     = 0 (always; jumps are 2-byte aligned)
//              sign-extended from bit 20
//
// The decoder calls this module and stores imm_o directly in decoded_instr_t.
// The register file read data and ALU operands are selected separately.

`default_nettype none

module imm_gen
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
(
    input  wire instr_t      instr_i,  // raw 32-bit instruction
    input  wire instr_fmt_e  fmt_i,    // instruction format
    output word_t       imm_o     // sign-extended immediate
);

    always_comb begin
        case (fmt_i)

            // ---- I-type ----
            // imm[11:0] lives in instr[31:20]; sign bit is instr[31].
            IFMT_I: imm_o = {{20{instr_i[31]}}, instr_i[31:20]};

            // ---- S-type ----
            // Upper 7 bits in instr[31:25], lower 5 bits in instr[11:7].
            IFMT_S: imm_o = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};

            // ---- B-type ----
            // Scrambled bits reassembled in natural order; bit 0 is always 0.
            IFMT_B: imm_o = {{19{instr_i[31]}},
                              instr_i[31],     // imm[12] = sign
                              instr_i[7],      // imm[11]
                              instr_i[30:25],  // imm[10:5]
                              instr_i[11:8],   // imm[4:1]
                              1'b0};           // imm[0]

            // ---- U-type ----
            // Upper 20 bits go to instr[31:12] verbatim; lower 12 are forced 0.
            // No sign extension is needed: the full 32-bit value is provided
            // by the instruction encoding itself.
            IFMT_U: imm_o = {instr_i[31:12], 12'b0};

            // ---- J-type ----
            // Scrambled bits reassembled; bit 0 is always 0.
            IFMT_J: imm_o = {{11{instr_i[31]}},
                              instr_i[31],      // imm[20] = sign
                              instr_i[19:12],   // imm[19:12]
                              instr_i[20],      // imm[11]
                              instr_i[30:21],   // imm[10:1]
                              1'b0};            // imm[0]

            // ---- R-type and default ----
            // R-type instructions have no immediate field.
            default: imm_o = '0;

        endcase
    end

endmodule : imm_gen

`default_nettype wire
