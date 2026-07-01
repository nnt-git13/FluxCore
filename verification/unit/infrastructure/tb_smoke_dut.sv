// verification/unit/infrastructure/tb_smoke_dut.sv
//
// Self-checking testbench for the toolchain infrastructure smoke test.
//
// Runs directed vectors against smoke_dut. Uses $fatal on any mismatch.
// Prints a single PASS message and terminates cleanly on success.
//
// This is NOT a FluxCore processor testbench.

`timescale 1ns / 1ps

module tb_smoke_dut;

    // DUT parameters
    localparam int unsigned WIDTH = 8;

    // DUT ports
    logic [WIDTH-1:0] a;
    logic [WIDTH-1:0] b;
    logic [WIDTH:0]   sum;
    logic [WIDTH-1:0] xor_out;

    // DUT instantiation
    smoke_dut #(.WIDTH(WIDTH)) dut (
        .a_i  (a),
        .b_i  (b),
        .sum_o(sum),
        .xor_o(xor_out)
    );

    // ---------------------------------------------------------------------------
    // Directed test vectors
    // ---------------------------------------------------------------------------
    // Each entry: {a, b, expected_sum, expected_xor}
    // expected_sum is WIDTH+1 bits to capture the carry.

    typedef struct {
        logic [WIDTH-1:0] a;
        logic [WIDTH-1:0] b;
        logic [WIDTH:0]   expected_sum;
        logic [WIDTH-1:0] expected_xor;
    } test_vector_t;

    task automatic apply_and_check(
        input logic [WIDTH-1:0] tv_a,
        input logic [WIDTH-1:0] tv_b,
        input logic [WIDTH:0]   tv_sum,
        input logic [WIDTH-1:0] tv_xor
    );
        a = tv_a;
        b = tv_b;
        #1; // let combinational logic settle

        if (sum !== tv_sum) begin
            $fatal(1, "FAIL: a=%0d b=%0d => sum=%0d (expected %0d)",
                   tv_a, tv_b, sum, tv_sum);
        end
        if (xor_out !== tv_xor) begin
            $fatal(1, "FAIL: a=0x%0h b=0x%0h => xor=0x%0h (expected 0x%0h)",
                   tv_a, tv_b, xor_out, tv_xor);
        end
    endtask

    initial begin
        // Zero inputs
        apply_and_check(8'h00, 8'h00, 9'h000, 8'h00);

        // Simple additions without carry
        apply_and_check(8'h01, 8'h01, 9'h002, 8'h00);
        apply_and_check(8'h0F, 8'h01, 9'h010, 8'h0E);
        apply_and_check(8'hA5, 8'h5A, 9'h0FF, 8'hFF);

        // Addition with carry-out (result wider than WIDTH)
        apply_and_check(8'hFF, 8'h01, 9'h100, 8'hFE);
        apply_and_check(8'hFF, 8'hFF, 9'h1FE, 8'h00);

        // Identity: a + 0 == a
        apply_and_check(8'hC3, 8'h00, 9'h0C3, 8'hC3);

        // Commutativity: a + b == b + a (different XOR patterns)
        apply_and_check(8'h12, 8'h34, 9'h046, 8'h26);
        apply_and_check(8'h34, 8'h12, 9'h046, 8'h26);

        $display("[SMOKE] PASS: smoke_dut verified with %0d directed vectors.", 9);
        $finish;
    end

endmodule
