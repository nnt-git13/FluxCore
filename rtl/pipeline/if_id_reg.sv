`default_nettype none

module if_id_reg
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
    import pipeline_pkg::*;
(
    input  wire logic           clk,
    input  wire logic           rst,
    input  wire logic           stall_i,
    input  wire logic           flush_i,
    input  wire if_id_payload_t d_i,
    output if_id_payload_t q_o
);
    always_ff @(posedge clk) begin
        if (rst || flush_i)
            q_o <= '0;
        else if (!stall_i)
            q_o <= d_i;
    end
endmodule : if_id_reg

`default_nettype wire
