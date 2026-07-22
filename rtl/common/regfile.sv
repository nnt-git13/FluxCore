// rtl/common/regfile.sv
//
// FluxCore architectural register file — RV32I, 32 × 32-bit registers.
//
// Ports:
//   Two asynchronous read ports  (rs1, rs2)
//   One synchronous write port   (rd)
//   Synchronous active-high reset
//
// x0 semantics:
//   Reads: rs1_data_o and rs2_data_o are forced to 0 when the address is 0,
//          regardless of what is stored in regs[0]. No special case is needed
//          on the write side; writes to address 0 are silently suppressed.
//   Writes: rd_wen_i is qualified by (rd_addr_i != 0) inside the always_ff.
//           This keeps regs[0] = 0 at all times after reset.
//
// Read behaviour:
//   Purely combinational. Reads reflect the register contents immediately
//   (no pipeline latency). This is required for the ID stage to forward
//   operands into the EX stage via a single pipeline register.
//   On Xilinx 7-series targets, the tool infers distributed RAM (LUT-based)
//   from this pattern. Do not constrain these outputs to BRAM.
//
// Write behaviour:
//   Synchronous to posedge clk. A write takes effect at the rising edge;
//   the updated value is visible on the read ports in the same delta after
//   the clock edge (because reads are combinational). Hazard detection in
//   the pipeline must account for the one-cycle write latency.
//
// Reset:
//   When rst = 1 on a rising clock edge, all 32 registers are cleared to 0.
//   This uses a generate-style for-loop in always_ff, which Xilinx Vivado
//   synthesises correctly for distributed RAM.

`default_nettype none

module regfile
    import fluxcore_pkg::*;
(
    input  wire logic      clk,
    input  wire logic      rst,        // synchronous, active-high

    // --- Read port A (rs1) ---
    input  wire reg_idx_t  rs1_addr_i,
    output word_t     rs1_data_o,

    // --- Read port B (rs2) ---
    input  wire reg_idx_t  rs2_addr_i,
    output word_t     rs2_data_o,

    // --- Write port (rd) ---
    input  wire logic      rd_wen_i,
    input  wire reg_idx_t  rd_addr_i,
    input  wire word_t     rd_data_i,

    // --- Fill write port (deferred-load return; see fluxcore_top) ---
    // Never active for the same register as the WB port in the same cycle:
    // the scoreboard stalls every writer of a pending rd, so the two ports
    // cannot collide by construction. Tied off (wen=0) when the core runs
    // with a blocking cache.
    input  wire logic      fill_wen_i  = 1'b0,
    input  wire reg_idx_t  fill_addr_i = '0,
    input  wire word_t     fill_data_i = '0
);

    // -----------------------------------------------------------------------
    // Register array
    // -----------------------------------------------------------------------
    word_t regs [0:REG_COUNT-1];

    // -----------------------------------------------------------------------
    // Synchronous write with active-high reset
    // -----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned i = 0; i < REG_COUNT; i++) begin
                regs[i] <= '0;
            end
        end else begin
            if (rd_wen_i && (rd_addr_i != '0))
                regs[rd_addr_i] <= rd_data_i;
            if (fill_wen_i && (fill_addr_i != '0))
                regs[fill_addr_i] <= fill_data_i;
        end
    end

    // -----------------------------------------------------------------------
    // Asynchronous read (combinational) with write-first bypass.
    // x0 is hardwired to zero.
    // When WB writes to the same register that ID is reading in the same clock
    // cycle, NBA scheduling would otherwise expose the stale pre-write value to
    // the ID stage.  The bypass mux returns rd_data_i directly so that
    // id_ex_reg captures the architecturally correct value, matching the
    // behaviour of a half-clocked or write-first distributed RAM.
    // -----------------------------------------------------------------------
    logic rs1_bypass_s, rs2_bypass_s;
    assign rs1_bypass_s = rd_wen_i & (rd_addr_i != '0) & (rd_addr_i == rs1_addr_i);
    assign rs2_bypass_s = rd_wen_i & (rd_addr_i != '0) & (rd_addr_i == rs2_addr_i);

    assign rs1_data_o = (rs1_addr_i == '0) ? '0 :
                        rs1_bypass_s        ? rd_data_i :
                                              regs[rs1_addr_i];
    assign rs2_data_o = (rs2_addr_i == '0) ? '0 :
                        rs2_bypass_s        ? rd_data_i :
                                              regs[rs2_addr_i];

endmodule : regfile

`default_nettype wire
