`default_nettype none

// execute_stage — purely combinational EX datapath.
//
// Takes an id_ex_payload_t (from the ID/EX stage register) and produces an
// ex_mem_payload_t (for the EX/MEM stage register to latch). No clock or
// reset; all side effects are gated externally by the stage registers.
//
// ALU operand selection:
//   Operand A: uses_rs1=1 → rs1_data   uses_rs1=0 → pc
//              (AUIPC, JAL use PC as A; all register and immediate ops use rs1)
//   Operand B: uses_rs2=1 → rs2_data   uses_rs2=0 → decoded.imm
//              (R-type uses rs2; I/S/B/U/J-type uses the immediate)
//
// Branch/jump target:
//   JALR (is_jump=1, uses_rs1=1): target = (rs1_data + imm) with bit 0 masked.
//     Bit-0 masking is mandated by RV32I §2.5 to allow LSB as a hint.
//   JAL  (is_jump=1, uses_rs1=0): target = pc + imm
//   Branch (is_branch=1):          target = pc + imm
//   All others:                    target = pc + imm (don't-care, not consumed)
//
// branch_taken gating:
//   ex_mem_o.branch_taken is only asserted when decoded.is_branch=1 AND
//   decoded.legal=1. Gating on legal prevents spurious PC redirects for
//   instructions that raised a decode exception.
//
// Forwarding:
//   rs1_data and rs2_data in id_ex_i carry register-file values from the ID
//   stage. A forwarding unit (future milestone) will mux these with EX/MEM or
//   MEM/WB writeback data before the ID/EX stage register latches them.
//   This module is unaware of forwarding; it consumes whatever is in id_ex_i.

module execute_stage
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
    import pipeline_pkg::*;
(
    input  wire id_ex_payload_t  id_ex_i,
    // CSR old value from the combinatorial read port of csr_unit.
    // Driven by fluxcore_top: csr_unit.raddr_i = id_ex_i.decoded.csr_addr;
    // csr_rdata_i = csr_unit.rdata_o.  Only meaningful when decoded.is_csr=1.
    input  wire word_t           csr_rdata_i,
    // RV32M result from mul_div_unit (instantiated in fluxcore_top).
    // Selected instead of alu_result_s when decoded.alu_op is a MUL/DIV op.
    // For MUL ops: combinationally valid every cycle.
    // For DIV ops: valid after busy_o deasserts (pipeline stalled until then).
    input  wire word_t           muldiv_result_i,
    output ex_mem_payload_t ex_mem_o
);

    // -----------------------------------------------------------------------
    // Internal signals
    // -----------------------------------------------------------------------
    word_t opa_s;          // ALU operand A
    word_t opb_s;          // ALU operand B
    word_t alu_result_s;   // ALU result
    logic  branch_taken_s; // raw branch comparator output (before legal gate)
    word_t branch_target_s;

    // -----------------------------------------------------------------------
    // ALU operand A: register rs1, or PC for AUIPC / JAL
    // -----------------------------------------------------------------------
    assign opa_s = id_ex_i.decoded.uses_rs1 ? id_ex_i.rs1_data : id_ex_i.pc;

    // -----------------------------------------------------------------------
    // ALU operand B: register rs2, or sign-extended immediate.
    // Stores (is_store=1) set uses_rs2=1 (for forwarding detection) but the
    // ALU must compute the address using the immediate, not rs2 (store data).
    // -----------------------------------------------------------------------
    assign opb_s = (id_ex_i.decoded.uses_rs2 && !id_ex_i.decoded.is_store)
                   ? id_ex_i.rs2_data : id_ex_i.decoded.imm;

    // -----------------------------------------------------------------------
    // ALU
    // -----------------------------------------------------------------------
    alu u_alu (
        .a_i     (opa_s),
        .b_i     (opb_s),
        .op_i    (id_ex_i.decoded.alu_op),
        .result_o(alu_result_s)
    );

    // -----------------------------------------------------------------------
    // Branch comparator
    // -----------------------------------------------------------------------
    branch_unit u_branch_unit (
        .rs1_i  (id_ex_i.rs1_data),
        .rs2_i  (id_ex_i.rs2_data),
        .op_i   (id_ex_i.decoded.branch_op),
        .taken_o(branch_taken_s)
    );

    // -----------------------------------------------------------------------
    // Branch/jump target
    // -----------------------------------------------------------------------
    always_comb begin
        if (id_ex_i.decoded.is_jump && id_ex_i.decoded.uses_rs1)
            // JALR: mask bit 0 per RV32I §2.5
            branch_target_s = (id_ex_i.rs1_data + id_ex_i.decoded.imm) & ~32'h1;
        else
            // JAL, conditional branches: PC + immediate
            branch_target_s = id_ex_i.pc + id_ex_i.decoded.imm;
    end

    // -----------------------------------------------------------------------
    // Result select: ALU or MUL/DIV unit
    // MUL/DIV ops (ALU_MUL..ALU_REMU) bypass alu_result_s; the mul_div_unit
    // in fluxcore_top computes and returns the result via muldiv_result_i.
    // -----------------------------------------------------------------------
    function automatic logic is_muldiv_op(input alu_op_e op);
        return (op >= ALU_MUL) && (op <= ALU_REMU);
    endfunction

    // -----------------------------------------------------------------------
    // Assemble EX/MEM payload
    // -----------------------------------------------------------------------
    always_comb begin
        ex_mem_o.valid        = id_ex_i.valid;
        ex_mem_o.pc           = id_ex_i.pc;
        ex_mem_o.instr        = id_ex_i.instr;
        ex_mem_o.decoded      = id_ex_i.decoded;
        ex_mem_o.alu_result   = is_muldiv_op(id_ex_i.decoded.alu_op)
                                ? muldiv_result_i : alu_result_s;
        ex_mem_o.branch_target = branch_target_s;
        ex_mem_o.csr_rdata    = csr_rdata_i;

        // Gate on is_branch AND legal: no spurious redirect for illegal instrs
        ex_mem_o.branch_taken = id_ex_i.decoded.is_branch
                              & id_ex_i.decoded.legal
                              & branch_taken_s;

        // rs2_data dual-purpose:
        // - For stores (is_store=1): forwarded rs2 value (store write data).
        // - For CSR register forms (is_csr=1, uses_rs1=1): forwarded rs1 value
        //   (CSR write source operand — what to WRITE/SET/CLR into the CSR).
        // - For CSR immediate forms (is_csr=1, uses_rs1=0): zero-extended 5-bit
        //   zimm from decoded.imm[4:0].
        // mem_stage reads ex_mem_q.rs2_data as csr_wdata when is_csr=1.
        if (id_ex_i.decoded.is_csr) begin
            ex_mem_o.rs2_data = id_ex_i.decoded.uses_rs1
                              ? id_ex_i.rs1_data
                              : {27'b0, id_ex_i.decoded.imm[4:0]};
        end else begin
            ex_mem_o.rs2_data = id_ex_i.rs2_data;
        end
    end

endmodule : execute_stage

`default_nettype wire
