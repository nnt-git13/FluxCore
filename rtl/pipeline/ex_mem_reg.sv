`default_nettype none

module ex_mem_reg
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
    import pipeline_pkg::*;
(
    input  wire logic            clk,
    input  wire logic            rst,
    input  wire logic            stall_i,
    input  wire logic            flush_i,
    input  wire ex_mem_payload_t d_i,
    output ex_mem_payload_t q_o
);
    always_ff @(posedge clk) begin
        if (rst || flush_i)
            q_o <= '0;
        else if (!stall_i)
            q_o <= d_i;
    end
endmodule : ex_mem_reg

`default_nettype wire
