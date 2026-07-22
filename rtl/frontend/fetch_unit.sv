`default_nettype none

// fetch_unit — IF stage PC register and next-PC select.
//
// Role in the pipeline:
//   This is the entire IF stage. It drives the instruction memory address
//   and produces the IF/ID payload for the if_id_reg to latch.
//
// Instruction memory interface:
//   fetch_addr_o is the CURRENT PC (combinatorial from registered pc_q).
//   fetch_addr_next_o is the NEXT PC (fully combinatorial, before the next
//   posedge). BRAM instruction memory should use fetch_addr_next_o as its
//   address input so that its registered output is ready in the same cycle
//   that the pipeline expects the instruction (= the cycle when pc_q is the
//   current PC). Simulation testbenches use the combinatorial imem model and
//   can ignore fetch_addr_next_o.
//
//   It expects instr_i to settle combinatorially in the same cycle as
//   fetch_addr_o (either combinatorial ROM for simulation, or BRAM output
//   registered one cycle earlier via fetch_addr_next_o for synthesis).
//   The if_id_o payload is formed combinatorially and latched by if_id_reg.
//
// Next-PC priority:
//   1. rst=1              → RESET_VECTOR  (synchronous, highest priority)
//   2. redirect_valid_i=1 → redirect_target_i  (overrides stall and miss)
//   3. stall_i=1 or instr_valid_i=0 → hold PC  (no change)
//   4. else               → PC + 4
//
// Redirect overrides stall because a branch/jump resolved in EX needs the
// front-of-pipe to restart regardless of any load-use stall in flight.
//
// JALR bit-0 clearing:
//   The EX stage is responsible for masking bit 0 of the JALR target before
//   asserting redirect_valid_i. This module does not modify redirect_target_i.
//
// Valid signal:
//   if_id_o.valid = instr_valid_i. With the pin at its default (1) the fetch
//   unit never produces bubbles itself — the pipeline control unit flushes
//   the if_id_reg to insert them. An instruction-side cache drives
//   instr_valid_i LOW during a miss: fetch then holds the PC and emits
//   bubbles until the line arrives — the entire I-cache integration is this
//   one pin. Redirect still overrides the hold (a resolved branch restarts
//   the front end regardless of a fetch miss in flight; the missed line
//   fills in the background and simply is not consumed).

module fetch_unit
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
    import pipeline_pkg::*;
#(
    // Reset vector: byte address of the first instruction to fetch.
    // Override at integration time to match the memory map.
    parameter word_t RESET_VECTOR = 32'h0000_0000
)
(
    input  wire logic           clk,
    input  wire logic           rst,

    // Stall from pipeline control: hold PC and re-present the same fetch.
    input  wire logic           stall_i,

    // Redirect from EX stage: a branch taken or JAL/JALR resolved target.
    // Asserted for exactly one cycle; the target is already aligned and final.
    input  wire logic           redirect_valid_i,
    input  wire word_t          redirect_target_i,

    // Instruction memory read port.
    // fetch_addr_o: current PC (combinatorial from pc_q); drives imem address
    //   for simulation (combinatorial ROM model) and the if_id payload PC.
    // fetch_addr_next_o: next PC (combinatorial); for BRAM synthesis — feed
    //   this to the BRAM address so the registered output is ready when the
    //   pipeline needs it (one cycle later, when fetch_addr_o = this address).
    // instr_i must be valid combinatorially in the same cycle as fetch_addr_o.
    output word_t          fetch_addr_o,
    output word_t          fetch_addr_next_o,
    input  wire instr_t         instr_i,

    // Instruction-fetch handshake: 0 = the instruction for fetch_addr_o is
    // not available this cycle (I-cache miss) — hold the PC and emit a
    // bubble. Default 1 preserves the original always-valid behavior for
    // every existing instantiation.
    input  wire logic           instr_valid_i = 1'b1,

    // Branch-prediction update from EX resolution + FENCE.I flush. All
    // default-inert: with no updates the internal BTB never hits and the
    // fetch behavior is exactly the original static not-taken.
    input  wire logic           btb_upd_valid_i  = 1'b0,
    input  wire word_t          btb_upd_pc_i     = '0,
    input  wire logic           btb_upd_taken_i  = 1'b0,
    input  wire word_t          btb_upd_target_i = '0,
    input  wire logic           btb_flush_i      = 1'b0,

    // Output to if_id_reg (latched by if_id_reg on the next rising edge).
    output if_id_payload_t if_id_o
);

    word_t pc_q;
    word_t next_pc_s;

    // -----------------------------------------------------------------------
    // Branch target buffer: predicts, for the instruction at pc_q, whether
    // fetch should steer to a cached target instead of pc+4. EX verifies the
    // prediction (payload pred_* bits) and redirects on a mispredict.
    // -----------------------------------------------------------------------
    logic  pred_taken_s;
    word_t pred_target_s;

    btb u_btb (
        .clk           (clk),
        .rst           (rst),
        .flush_i       (btb_flush_i),
        .lookup_pc_i   (pc_q),
        .pred_taken_o  (pred_taken_s),
        .pred_target_o (pred_target_s),
        .upd_valid_i   (btb_upd_valid_i),
        .upd_pc_i      (btb_upd_pc_i),
        .upd_taken_i   (btb_upd_taken_i),
        .upd_target_i  (btb_upd_target_i)
    );

    // -----------------------------------------------------------------------
    // Next-PC combinatorial select
    // -----------------------------------------------------------------------
    always_comb begin
        if (rst)
            next_pc_s = RESET_VECTOR;
        else if (redirect_valid_i)
            next_pc_s = redirect_target_i;
        else if (!stall_i && instr_valid_i)
            next_pc_s = pred_taken_s ? pred_target_s : (pc_q + 32'd4);
        else
            next_pc_s = pc_q;
    end

    // -----------------------------------------------------------------------
    // PC register
    // -----------------------------------------------------------------------
    always_ff @(posedge clk)
        pc_q <= next_pc_s;

    // -----------------------------------------------------------------------
    // Fetch addresses
    // -----------------------------------------------------------------------
    assign fetch_addr_o      = pc_q;       // current PC (combinatorial)
    assign fetch_addr_next_o = next_pc_s;  // next PC (for BRAM prefetch)

    // -----------------------------------------------------------------------
    // IF/ID payload (combinational, latched by if_id_reg on the next edge)
    // -----------------------------------------------------------------------
    always_comb begin
        if_id_o.valid       = instr_valid_i;
        if_id_o.pc          = pc_q;
        if_id_o.instr       = instr_i;
        if_id_o.pred_taken  = pred_taken_s & instr_valid_i & ~stall_i;
        if_id_o.pred_target = pred_target_s;
    end

endmodule : fetch_unit

`default_nettype wire
