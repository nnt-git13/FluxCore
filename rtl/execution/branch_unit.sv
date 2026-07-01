// rtl/execution/branch_unit.sv
//
// FluxCore conditional branch comparator.
//
// Purpose:
//   Evaluates the branch condition for BRANCH-class instructions and produces
//   a single taken/not-taken signal. This module is purely combinational and
//   has no knowledge of the program counter, branch target, or pipeline state.
//
// Separation of concerns:
//   - branch_unit computes the boolean condition (this module).
//   - The execute stage computes the branch target address (PC + imm) using
//     the ALU with ALU_ADD.
//   - The pipeline control logic decides whether to redirect the fetch unit
//     based on taken_o and whether the instruction is a branch.
//
// Inputs:
//   rs1_i  — value of source register 1 (from register file or forwarding)
//   rs2_i  — value of source register 2 (from register file or forwarding)
//   op_i   — comparison type, from branch_op_e in rv32_isa_pkg
//
// Output:
//   taken_o — 1 if the branch condition is satisfied, 0 otherwise.
//             Also 0 for BRANCH_NONE (non-branch instructions must pass
//             BRANCH_NONE so the execute stage does not redirect).
//
// Signed comparisons:
//   BLT and BGE use $signed() casts, matching RISC-V spec behaviour.
//   Without the cast, the comparison would be unsigned and BLT/BGE would
//   give wrong results for operands with differing sign bits.
//
// LT / GE duality:
//   Each LT test has a complementary GE test (taken iff NOT LT for equal
//   operands is GE, not GT). This holds for both signed and unsigned pairs.

`default_nettype none

module branch_unit
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
(
    input  wire word_t      rs1_i,    // operand A (rs1 from regfile or forwarded)
    input  wire word_t      rs2_i,    // operand B (rs2 from regfile or forwarded)
    input  wire branch_op_e op_i,     // comparison type
    output logic       taken_o   // 1 = branch taken
);

    always_comb begin
        case (op_i)
            BRANCH_EQ:  taken_o = (rs1_i == rs2_i);
            BRANCH_NE:  taken_o = (rs1_i != rs2_i);
            BRANCH_LT:  taken_o = ($signed(rs1_i) <  $signed(rs2_i));
            BRANCH_GE:  taken_o = ($signed(rs1_i) >= $signed(rs2_i));
            BRANCH_LTU: taken_o = (rs1_i <  rs2_i);
            BRANCH_GEU: taken_o = (rs1_i >= rs2_i);
            default:    taken_o = 1'b0;  // BRANCH_NONE and any reserved encoding
        endcase
    end

endmodule : branch_unit

`default_nettype wire
