`default_nettype none

// wb_stage — purely combinational writeback stage.
//
// Routes mem_wb_payload_t fields to three destinations:
//
//   1. Register file write port (rd_addr_o, rd_data_o, rd_wen_o).
//      rd_wen_o is gated on both mem_wb_i.rd_wen AND mem_wb_i.valid.
//      A bubble (valid=0) never asserts rd_wen_o even if rd_wen=1.
//      The regfile module independently guards x0 on its write side.
//      For load writebacks, rd_data_o is recomputed from the live data-memory
//      read word. This preserves zero-latency simulation behavior while fixing
//      the synthesis BRAM path, where dmem_rdata_i arrives in the WB cycle.
//
//   2. Retirement event (retire_o): asserted for every valid, non-exception
//      instruction that reaches WB. ECALL, EBREAK, illegal instructions,
//      and memory misalignment exceptions do NOT retire — they trap instead.
//      retire_o.mem_valid and related fields are left at 0 in this vertical
//      slice; they will be populated when the memory trace milestone lands.
//
//   3. Exception output (exception_o, exception_pc_o): passes the pending
//      exception to the future CSR / trap handler. The pipeline control unit
//      uses exception_o.valid to trigger a flush and redirect to the trap
//      vector. exception_pc_o is the faulting instruction's PC (→ mepc).

module wb_stage
    import fluxcore_pkg::*;
    import rv32_isa_pkg::*;
    import pipeline_pkg::*;
(
    input  wire mem_wb_payload_t   mem_wb_i,
    input  wire word_t             dmem_rdata_i,
    input  wire logic              stall_i,       // pipeline-wide stall (cache miss)

    // Register file write port
    output reg_idx_t          rd_addr_o,
    output word_t             rd_data_o,
    output logic              rd_wen_o,

    // Retirement event (one per architecturally committed instruction)
    output retirement_event_t retire_o,

    // Exception to future CSR / trap handler
    output exception_meta_t   exception_o,
    output word_t             exception_pc_o
);

    // -----------------------------------------------------------------------
    // Load result selection
    // -----------------------------------------------------------------------
    function automatic word_t select_load_data(
        input instr_t      instr,
        input logic [1:0]  byte_off,
        input word_t       rdata,
        input word_t       fallback
    );
        logic [7:0]  byte_v;
        logic [15:0] half_v;

        begin
            case (byte_off)
                2'd0: byte_v = rdata[ 7: 0];
                2'd1: byte_v = rdata[15: 8];
                2'd2: byte_v = rdata[23:16];
                2'd3: byte_v = rdata[31:24];
            endcase

            case (byte_off[1])
                1'b0: half_v = rdata[15: 0];
                1'b1: half_v = rdata[31:16];
            endcase

            case (instr[INSTR_FUNCT3_MSB:INSTR_FUNCT3_LSB])
                FUNCT3_LB:  select_load_data = {{24{byte_v[7]}}, byte_v};
                FUNCT3_LBU: select_load_data = {24'h0,            byte_v};
                FUNCT3_LH:  select_load_data = {{16{half_v[15]}}, half_v};
                FUNCT3_LHU: select_load_data = {16'h0,             half_v};
                FUNCT3_LW:  select_load_data = rdata;
                default:    select_load_data = fallback;
            endcase
        end
    endfunction

    word_t rd_data_s;

    always_comb begin
        rd_data_s = mem_wb_i.rd_data;
        if (mem_wb_i.valid && mem_wb_i.rd_wen && mem_wb_i.rd_from_mem)
            rd_data_s = select_load_data(
                mem_wb_i.instr,
                mem_wb_i.mem_byte_off,
                dmem_rdata_i,
                mem_wb_i.rd_data
            );
    end

    // -----------------------------------------------------------------------
    // Register file write port
    // -----------------------------------------------------------------------
    assign rd_addr_o = mem_wb_i.rd_addr;
    assign rd_data_o = rd_data_s;
    assign rd_wen_o  = mem_wb_i.valid & mem_wb_i.rd_wen & ~stall_i;

    // -----------------------------------------------------------------------
    // Retirement event
    // -----------------------------------------------------------------------
    always_comb begin
        retire_o.valid        = mem_wb_i.valid & ~mem_wb_i.exception.valid & ~stall_i;
        retire_o.pc           = mem_wb_i.pc;
        retire_o.instr        = mem_wb_i.instr;
        retire_o.rd_wen       = mem_wb_i.rd_wen & (mem_wb_i.rd_addr != '0);
        retire_o.rd_addr      = mem_wb_i.rd_addr;
        retire_o.rd_data      = rd_data_s;
        retire_o.mem_valid    = 1'b0;  // not tracked in this vertical slice
        retire_o.mem_addr     = '0;
        retire_o.mem_wr_data  = '0;
        retire_o.mem_wr_strb  = '0;
        retire_o.mem_is_write = 1'b0;
        retire_o.thread_id    = '0;   // single-thread baseline
        retire_o.exception    = mem_wb_i.exception;
    end

    // -----------------------------------------------------------------------
    // Exception output — gated on valid so bubbles never trigger a trap
    // -----------------------------------------------------------------------
    always_comb begin
        exception_o       = mem_wb_i.exception;
        exception_o.valid = mem_wb_i.exception.valid & mem_wb_i.valid;
        exception_pc_o    = mem_wb_i.pc;
    end

endmodule : wb_stage

`default_nettype wire
