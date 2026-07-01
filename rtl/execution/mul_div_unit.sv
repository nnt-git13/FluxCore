`default_nettype none

// mul_div_unit — RV32M multiply and divide execution unit.
//
// Multiply (MUL/MULH/MULHU/MULHSU): single-cycle combinational. No stall.
//   MUL     rd = (signed(rs1) * signed(rs2))[31:0]
//   MULH    rd = (signed(rs1) * signed(rs2))[63:32]
//   MULHU   rd = (unsigned(rs1) * unsigned(rs2))[63:32]
//   MULHSU  rd = (signed(rs1) * unsigned(rs2))[63:32]
//
// Divide (DIV/DIVU/REM/REMU): 33-cycle iterative restoring divider.
//   busy_o is asserted for 33 cycles; pipeline_ctrl treats it as a full-freeze
//   stall identical to a cache miss.
//
//   Cycle 1 (start_i=1, !busy_q): load operands; busy_o = 1 (via start_i).
//   Cycles 2-33 (busy_q=1, count_q>0): one restoring step per cycle.
//   Cycle 33 (busy_q=1, count_q=0): final step; busy_q ← 0.
//   Cycle 34: busy_o = 0; result valid in result_o.
//
// Special cases (RV32M spec):
//   Divide by zero:        DIV/DIVU result = 0xFFFFFFFF; REM/REMU = rs1.
//   INT_MIN / -1 overflow: DIV result = 0x80000000;      REM = 0.
//
// Interface:
//   rs1_i / rs2_i   Forwarded operands (from id_ex_fwd_s in fluxcore_top).
//   op_i            ALU op for current EX instruction.  For MUL ops, drives
//                   the combinational path continuously.  For DIV ops,
//                   registered at start and used to select the final output.
//   start_i         One-cycle pulse: asserted when a DIV instruction first
//                   enters EX and the unit is idle (!busy_o).
//   result_o        Selected result: MUL path for MUL ops, registered quotient/
//                   remainder for DIV ops (valid once busy_o deasserts).
//   busy_o          1 = DIV stall active; 0 = idle or result ready.

module mul_div_unit
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
(
    input  wire logic     clk,
    input  wire logic     rst,
    input  wire word_t    rs1_i,
    input  wire word_t    rs2_i,
    input  wire alu_op_e  op_i,
    input  wire logic     start_i,
    output word_t         result_o,
    // busy_o = busy_q | start_i: asserted from the same cycle start_i fires.
    //   Drives the pipeline_ctrl muldiv_stall_i (stall starts in cycle 1).
    // idle_o = ~busy_q: pure registered output, no combinational loop.
    //   Used by fluxcore_top to generate start_i without feedback.
    output logic          busy_o,
    output logic          idle_o
);

    // =========================================================================
    // Multiply — purely combinational
    // =========================================================================

    // signed × signed (64-bit)
    logic signed [63:0] prod_ss;
    assign prod_ss = $signed(rs1_i) * $signed(rs2_i);

    // unsigned × unsigned (64-bit): zero-extend to 33 bits so the tool
    // can infer a 32×32 unsigned multiplier (Xilinx DSP48E1 friendly).
    logic [63:0] prod_uu;
    assign prod_uu = ({1'b0, rs1_i}) * ({1'b0, rs2_i});

    // signed × unsigned (66-bit): rs1 sign-extended, rs2 zero-extended,
    // both to 33 bits, then multiplied as signed × signed.
    logic signed [65:0] prod_su;
    assign prod_su = $signed({rs1_i[31], rs1_i}) *
                     $signed({1'b0,      rs2_i});

    word_t mul_result;
    always_comb begin
        case (op_i)
            ALU_MUL:    mul_result = prod_ss[31:0];
            ALU_MULH:   mul_result = prod_ss[63:32];
            ALU_MULHU:  mul_result = prod_uu[63:32];
            ALU_MULHSU: mul_result = prod_su[63:32];
            default:    mul_result = '0;
        endcase
    end

    // =========================================================================
    // Divide — 33-cycle iterative restoring divider
    // =========================================================================

    logic        busy_q;
    logic [4:0]  count_q;        // 5-bit: 31 downto 0
    logic [31:0] dividend_q;     // remaining bits, shifted out MSB-first
    logic [31:0] divisor_q;      // |divisor|, constant per division
    logic [31:0] remainder_q;    // accumulated partial remainder
    logic [31:0] quot_q;         // accumulated quotient
    // Metadata registered at load time
    logic        neg_quot_q;
    logic        neg_rem_q;
    logic        div_by_zero_q;
    logic        div_overflow_q;
    alu_op_e     op_q;
    logic [31:0] rs1_orig_q;     // original rs1 for divide-by-zero REM

    assign busy_o = busy_q | start_i;  // stall fires in cycle 1
    assign idle_o = ~busy_q;           // combinational-loop-free; drives start generation

    // Absolute value helpers (combinational from inputs, evaluated at start)
    wire [31:0] rs1_abs = rs1_i[31] ? word_t'(-$signed(rs1_i)) : rs1_i;
    wire [31:0] rs2_abs = rs2_i[31] ? word_t'(-$signed(rs2_i)) : rs2_i;

    // One restoring-division step (combinational from registered partial state)
    wire [32:0] partial_r = {remainder_q[30:0], dividend_q[31]};
    wire [32:0] trial_r   = partial_r - {1'b0, divisor_q};

    always_ff @(posedge clk) begin
        if (rst) begin
            busy_q         <= 1'b0;
            count_q        <= '0;
            dividend_q     <= '0;
            divisor_q      <= '0;
            remainder_q    <= '0;
            quot_q         <= '0;
            neg_quot_q     <= 1'b0;
            neg_rem_q      <= 1'b0;
            div_by_zero_q  <= 1'b0;
            div_overflow_q <= 1'b0;
            op_q           <= ALU_DIVU;
            rs1_orig_q     <= '0;
        end else if (start_i && !busy_q) begin
            // --- Load cycle ---
            busy_q        <= 1'b1;
            count_q       <= 5'd31;
            op_q          <= op_i;
            rs1_orig_q    <= rs1_i;
            remainder_q   <= '0;
            quot_q        <= '0;

            if (op_i == ALU_DIV || op_i == ALU_REM) begin
                dividend_q    <= rs1_abs;
                divisor_q     <= rs2_abs;
                neg_quot_q    <= rs1_i[31] ^ rs2_i[31];
                neg_rem_q     <= rs1_i[31];
            end else begin
                dividend_q    <= rs1_i;
                divisor_q     <= rs2_i;
                neg_quot_q    <= 1'b0;
                neg_rem_q     <= 1'b0;
            end

            div_by_zero_q  <= (rs2_i == '0);
            div_overflow_q <= ((op_i == ALU_DIV || op_i == ALU_REM) &&
                               (rs1_i == 32'h8000_0000) &&
                               (rs2_i == 32'hFFFF_FFFF));

        end else if (busy_q) begin
            // --- Iteration ---
            if (!trial_r[32]) begin   // trial non-negative: quotient bit = 1
                remainder_q <= trial_r[31:0];
                quot_q      <= {quot_q[30:0], 1'b1};
            end else begin            // trial negative: restore
                remainder_q <= partial_r[31:0];
                quot_q      <= {quot_q[30:0], 1'b0};
            end
            dividend_q <= {dividend_q[30:0], 1'b0};

            if (count_q == 0)
                busy_q  <= 1'b0;      // last iteration: done after this posedge
            else
                count_q <= count_q - 1;
        end
    end

    // --- Divide result (combinational from registered final state) ---
    word_t div_result;
    always_comb begin
        div_result = '0;
        if (div_by_zero_q) begin
            if (op_q == ALU_REM || op_q == ALU_REMU)
                div_result = rs1_orig_q;
            else
                div_result = '1;           // 0xFFFF_FFFF
        end else if (div_overflow_q) begin
            if (op_q == ALU_DIV)
                div_result = 32'h8000_0000;
            // ALU_REM overflow: div_result stays 0
        end else if (op_q == ALU_DIV) begin
            div_result = neg_quot_q ? word_t'(-$signed(quot_q)) : quot_q;
        end else if (op_q == ALU_REM) begin
            div_result = neg_rem_q  ? word_t'(-$signed(remainder_q)) : remainder_q;
        end else if (op_q == ALU_DIVU) begin
            div_result = quot_q;
        end else begin  // ALU_REMU
            div_result = remainder_q;
        end
    end

    // =========================================================================
    // Output select
    // =========================================================================
    // For MUL ops: combinational result, valid every cycle.
    // For DIV ops: registered result, valid after busy_o deasserts.
    // op_i reflects the current EX-stage instruction (pipeline stalled during
    // DIV, so op_i holds the same DIV op for all 33 stall cycles).
    function automatic logic is_div_op(input alu_op_e op);
        return (op == ALU_DIV || op == ALU_DIVU || op == ALU_REM || op == ALU_REMU);
    endfunction

    assign result_o = is_div_op(op_i) ? div_result : mul_result;

endmodule : mul_div_unit

`default_nettype wire
