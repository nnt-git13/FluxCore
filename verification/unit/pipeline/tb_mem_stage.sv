// verification/unit/pipeline/tb_mem_stage.sv
//
// Self-checking testbench for rtl/memory/mem_stage.sv.
//
// The DUT is purely combinational. Each test vector drives ex_mem_i and
// mem_rdata_i, waits #1 for settling, then checks all relevant outputs.
//
// Coverage:
//   Bubble (valid=0): valid passes through as 0, rd_wen=0, mem_wen_o=0
//   WB_ALU: rd_data = alu_result (integer ALU ops, AUIPC, LUI)
//   WB_PC4: rd_data = pc + 4 (JAL, JALR)
//   WB_NONE: rd_data = 0, rd_wen=0 (branches, stores)
//   LB:  sign-extend from all 4 byte positions
//   LBU: zero-extend from all 4 byte positions
//   LH:  sign-extend from lower and upper halfword
//   LHU: zero-extend from lower and upper halfword
//   LW:  full word passthrough
//   SB:  correct byte lane, replicated write data, mem_wen_o=1
//   SH:  correct halfword lanes, replicated write data, mem_wen_o=1
//   SW:  all byte lanes, mem_wen_o=1
//   LH  misaligned (addr[0]=1): EXC_LOAD_ADDR_MISALIGNED, rd_wen=0
//   LHU misaligned:             same cause
//   LW  misaligned (addr[1:0]!=00): same cause
//   SH  misaligned (addr[0]=1): EXC_STORE_ADDR_MISALIGNED, mem_wen_o=0
//   SW  misaligned (addr[1:0]!=00): same cause
//   Decode exception forwarded: no misalignment check attempted
//   Illegal instruction:        exc forwarded, rd_wen=0, mem_wen_o=0
//   Store with valid=0 (bubble): mem_wen_o=0 (no spurious write)

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_mem_stage;

    // -----------------------------------------------------------------------
    // DUT wires
    // -----------------------------------------------------------------------
    ex_mem_payload_t ex_mem_w  = '0;
    word_t           rdata_w   = '0;
    word_t           mem_addr_w;
    logic            mem_wen_w;
    logic [3:0]      mem_wstrb_w;
    word_t           mem_wdata_w;
    mem_wb_payload_t mem_wb_w;

    mem_stage dut (
        .ex_mem_i   (ex_mem_w),
        .mem_addr_o (mem_addr_w),
        .mem_wen_o  (mem_wen_w),
        .mem_wstrb_o(mem_wstrb_w),
        .mem_wdata_o(mem_wdata_w),
        .mem_rdata_i(rdata_w),
        .mem_wb_o   (mem_wb_w)
    );

    // -----------------------------------------------------------------------
    // Drive helper
    // -----------------------------------------------------------------------
    task automatic apply(
        input ex_mem_payload_t p,
        input word_t           rdata
    );
        ex_mem_w = p;
        rdata_w  = rdata;
        #1;
    endtask

    // -----------------------------------------------------------------------
    // ex_mem_payload_t builders
    // -----------------------------------------------------------------------

    // ALU result writeback (ADD, AUIPC, LUI, ...)
    function automatic ex_mem_payload_t mk_alu(
        input word_t    pc,
        input word_t    alu_result,
        input reg_idx_t rd,
        input wb_src_e  wb_src
    );
        automatic ex_mem_payload_t p = '0;
        p.valid             = 1'b1;
        p.pc                = pc;
        p.decoded.legal     = 1'b1;
        p.decoded.op_class  = OPCLASS_ALU;
        p.decoded.wb_src    = wb_src;
        p.decoded.writes_rd = 1'b1;
        p.decoded.rd        = rd;
        p.alu_result        = alu_result;
        return p;
    endfunction

    // Load
    function automatic ex_mem_payload_t mk_load(
        input word_t   pc,
        input word_t   addr,
        input mem_op_e mem_op,
        input reg_idx_t rd
    );
        automatic ex_mem_payload_t p = '0;
        p.valid             = 1'b1;
        p.pc                = pc;
        p.decoded.legal     = 1'b1;
        p.decoded.op_class  = OPCLASS_LOAD;
        p.decoded.mem_op    = mem_op;
        p.decoded.wb_src    = WB_MEM;
        p.decoded.writes_rd = 1'b1;
        p.decoded.is_load   = 1'b1;
        p.decoded.rd        = rd;
        p.alu_result        = addr;
        return p;
    endfunction

    // Store
    function automatic ex_mem_payload_t mk_store(
        input word_t   pc,
        input word_t   addr,
        input word_t   rs2_data,
        input mem_op_e mem_op
    );
        automatic ex_mem_payload_t p = '0;
        p.valid             = 1'b1;
        p.pc                = pc;
        p.decoded.legal     = 1'b1;
        p.decoded.op_class  = OPCLASS_STORE;
        p.decoded.mem_op    = mem_op;
        p.decoded.wb_src    = WB_NONE;
        p.decoded.writes_rd = 1'b0;
        p.decoded.is_store  = 1'b1;
        p.alu_result        = addr;
        p.rs2_data          = rs2_data;
        return p;
    endfunction

    // JAL/JALR (WB_PC4)
    function automatic ex_mem_payload_t mk_jump(
        input word_t    pc,
        input reg_idx_t rd
    );
        automatic ex_mem_payload_t p = '0;
        p.valid             = 1'b1;
        p.pc                = pc;
        p.decoded.legal     = 1'b1;
        p.decoded.op_class  = OPCLASS_JUMP;
        p.decoded.wb_src    = WB_PC4;
        p.decoded.writes_rd = 1'b1;
        p.decoded.is_jump   = 1'b1;
        p.decoded.rd        = rd;
        p.alu_result        = 32'h0; // link addr not used in this stage
        return p;
    endfunction

    // Illegal instruction
    function automatic ex_mem_payload_t mk_illegal(
        input word_t  pc,
        input instr_t bad_instr
    );
        automatic ex_mem_payload_t p = '0;
        p.valid                  = 1'b1;
        p.pc                     = pc;
        p.instr                  = bad_instr;
        p.decoded.legal          = 1'b0;
        p.decoded.exception.valid= 1'b1;
        p.decoded.exception.cause= EXC_ILLEGAL_INSTRUCTION;
        p.decoded.exception.tval = word_t'(bad_instr);
        // is_store=1 would cause a spurious mem_wen if not gated on legal
        p.decoded.is_store       = 1'b1;
        p.decoded.mem_op         = MEM_SW;
        p.alu_result             = 32'h1000;
        p.rs2_data               = 32'hDEAD_BEEF;
        return p;
    endfunction

    // -----------------------------------------------------------------------
    // Check helpers
    // -----------------------------------------------------------------------
    task automatic chk_rd(
        input logic   exp_wen,
        input word_t  exp_data,
        input string  desc
    );
        if (mem_wb_w.rd_wen !== exp_wen)
            $fatal(1, "[MEM-STAGE] FAIL %-40s rd_wen=%b expected=%b",
                   desc, mem_wb_w.rd_wen, exp_wen);
        if (exp_wen && mem_wb_w.rd_data !== exp_data)
            $fatal(1, "[MEM-STAGE] FAIL %-40s rd_data=%08h expected=%08h",
                   desc, mem_wb_w.rd_data, exp_data);
    endtask

    task automatic chk_store(
        input logic  exp_wen,
        input logic [3:0] exp_wstrb,
        input word_t exp_wdata,
        input string desc
    );
        if (mem_wen_w !== exp_wen)
            $fatal(1, "[MEM-STAGE] FAIL %-40s mem_wen=%b expected=%b",
                   desc, mem_wen_w, exp_wen);
        if (exp_wen) begin
            if (mem_wstrb_w !== exp_wstrb)
                $fatal(1, "[MEM-STAGE] FAIL %-40s wstrb=%04b expected=%04b",
                       desc, mem_wstrb_w, exp_wstrb);
            if (mem_wdata_w !== exp_wdata)
                $fatal(1, "[MEM-STAGE] FAIL %-40s wdata=%08h expected=%08h",
                       desc, mem_wdata_w, exp_wdata);
        end
    endtask

    task automatic chk_no_exc(input string desc);
        if (mem_wb_w.exception.valid !== 1'b0)
            $fatal(1, "[MEM-STAGE] FAIL %-40s unexpected exception (cause=%0d tval=%08h)",
                   desc, int'(mem_wb_w.exception.cause), mem_wb_w.exception.tval);
    endtask

    task automatic chk_exc(
        input exc_cause_e exp_cause,
        input word_t      exp_tval,
        input string      desc
    );
        if (!mem_wb_w.exception.valid)
            $fatal(1, "[MEM-STAGE] FAIL %-40s exception.valid=0", desc);
        if (mem_wb_w.exception.cause !== exp_cause)
            $fatal(1, "[MEM-STAGE] FAIL %-40s cause=%0d expected=%0d",
                   desc, int'(mem_wb_w.exception.cause), int'(exp_cause));
        if (mem_wb_w.exception.tval !== exp_tval)
            $fatal(1, "[MEM-STAGE] FAIL %-40s tval=%08h expected=%08h",
                   desc, mem_wb_w.exception.tval, exp_tval);
    endtask

    // -----------------------------------------------------------------------
    // Memory read data used across load tests: 0xAABBCCDD
    //   Byte 0 [7:0]   = 0xDD
    //   Byte 1 [15:8]  = 0xCC
    //   Byte 2 [23:16] = 0xBB
    //   Byte 3 [31:24] = 0xAA
    // -----------------------------------------------------------------------
    localparam word_t MEM_WORD = 32'hAABB_CCDD;

    // -----------------------------------------------------------------------
    // Main test
    // -----------------------------------------------------------------------
    initial begin : test_body

        // ================================================================
        // 1. Bubble passthrough: valid=0 → all side effects suppressed
        // ================================================================
        apply('0, '0);
        if (mem_wb_w.valid !== 1'b0)
            $fatal(1, "[MEM-STAGE] FAIL bubble: valid should be 0");
        if (mem_wb_w.rd_wen !== 1'b0)
            $fatal(1, "[MEM-STAGE] FAIL bubble: rd_wen should be 0");
        if (mem_wen_w !== 1'b0)
            $fatal(1, "[MEM-STAGE] FAIL bubble: mem_wen should be 0");

        // ================================================================
        // 2. WB_ALU: rd_data = alu_result
        // ================================================================
        apply(mk_alu(32'h1000, 32'hCAFE_BABE, 5'd7, WB_ALU), '0);
        chk_rd(1'b1, 32'hCAFE_BABE, "WB_ALU: rd_data=alu_result");
        chk_no_exc("WB_ALU: no exception");
        if (mem_wen_w !== 1'b0)
            $fatal(1, "[MEM-STAGE] FAIL WB_ALU: mem_wen should be 0");

        apply(mk_alu(32'h0, 32'hFFFF_FFFF, 5'd1, WB_ALU), '0);
        chk_rd(1'b1, 32'hFFFF_FFFF, "WB_ALU: all-ones");

        // ================================================================
        // 3. WB_PC4: rd_data = pc + 4 (JAL/JALR link register)
        // ================================================================
        apply(mk_jump(32'h0000_1000, 5'd1), '0);
        chk_rd(1'b1, 32'h0000_1004, "WB_PC4: pc=0x1000, rd=pc+4=0x1004");

        apply(mk_jump(32'hFFFF_FFFC, 5'd1), '0);
        chk_rd(1'b1, 32'h0000_0000, "WB_PC4: pc=0xFFFFFFFC, rd=0 (wrap)");

        // ================================================================
        // 4. LB — sign-extend byte from all 4 offsets
        // ================================================================
        // offset 0: byte=0xDD (bit7=1) → 0xFFFF_FFDD
        apply(mk_load(32'h0, 32'h100, MEM_LB, 5'd1), MEM_WORD);
        chk_rd(1'b1, 32'hFFFF_FFDD, "LB offset 0: sign-ext 0xDD");

        // offset 1: byte=0xCC (bit7=1) → 0xFFFF_FFCC
        apply(mk_load(32'h0, 32'h101, MEM_LB, 5'd1), MEM_WORD);
        chk_rd(1'b1, 32'hFFFF_FFCC, "LB offset 1: sign-ext 0xCC");

        // offset 2: byte=0xBB (bit7=1) → 0xFFFF_FFBB
        apply(mk_load(32'h0, 32'h102, MEM_LB, 5'd1), MEM_WORD);
        chk_rd(1'b1, 32'hFFFF_FFBB, "LB offset 2: sign-ext 0xBB");

        // offset 3: byte=0xAA (bit7=1) → 0xFFFF_FFAA
        apply(mk_load(32'h0, 32'h103, MEM_LB, 5'd1), MEM_WORD);
        chk_rd(1'b1, 32'hFFFF_FFAA, "LB offset 3: sign-ext 0xAA");

        // Positive byte: 0x7F → 0x0000_007F
        apply(mk_load(32'h0, 32'h200, MEM_LB, 5'd1), 32'h0000_007F);
        chk_rd(1'b1, 32'h0000_007F, "LB positive byte no sign-ext");

        // ================================================================
        // 5. LBU — zero-extend byte from all 4 offsets
        // ================================================================
        apply(mk_load(32'h0, 32'h100, MEM_LBU, 5'd1), MEM_WORD);
        chk_rd(1'b1, 32'h0000_00DD, "LBU offset 0: zero-ext 0xDD");

        apply(mk_load(32'h0, 32'h101, MEM_LBU, 5'd1), MEM_WORD);
        chk_rd(1'b1, 32'h0000_00CC, "LBU offset 1: zero-ext 0xCC");

        apply(mk_load(32'h0, 32'h102, MEM_LBU, 5'd1), MEM_WORD);
        chk_rd(1'b1, 32'h0000_00BB, "LBU offset 2: zero-ext 0xBB");

        apply(mk_load(32'h0, 32'h103, MEM_LBU, 5'd1), MEM_WORD);
        chk_rd(1'b1, 32'h0000_00AA, "LBU offset 3: zero-ext 0xAA");

        // ================================================================
        // 6. LH — sign-extend halfword (offset 0 and 2 only; 1/3 = misaligned)
        // ================================================================
        // offset 0: half[15:0] = 0xCCDD (bit15=1) → 0xFFFF_CCDD
        apply(mk_load(32'h0, 32'h100, MEM_LH, 5'd1), MEM_WORD);
        chk_rd(1'b1, 32'hFFFF_CCDD, "LH offset 0: sign-ext 0xCCDD");

        // offset 2: half[31:16] = 0xAABB (bit15=1) → 0xFFFF_AABB
        apply(mk_load(32'h0, 32'h102, MEM_LH, 5'd1), MEM_WORD);
        chk_rd(1'b1, 32'hFFFF_AABB, "LH offset 2: sign-ext 0xAABB");

        // Positive halfword: 0x1234 → 0x0000_1234
        apply(mk_load(32'h0, 32'h200, MEM_LH, 5'd1), 32'h0000_1234);
        chk_rd(1'b1, 32'h0000_1234, "LH positive half no sign-ext");

        // ================================================================
        // 7. LHU — zero-extend halfword
        // ================================================================
        apply(mk_load(32'h0, 32'h100, MEM_LHU, 5'd1), MEM_WORD);
        chk_rd(1'b1, 32'h0000_CCDD, "LHU offset 0: zero-ext 0xCCDD");

        apply(mk_load(32'h0, 32'h102, MEM_LHU, 5'd1), MEM_WORD);
        chk_rd(1'b1, 32'h0000_AABB, "LHU offset 2: zero-ext 0xAABB");

        // ================================================================
        // 8. LW — full 32-bit word
        // ================================================================
        apply(mk_load(32'h0, 32'h100, MEM_LW, 5'd1), MEM_WORD);
        chk_rd(1'b1, MEM_WORD, "LW: full word passthrough");

        apply(mk_load(32'h0, 32'h200, MEM_LW, 5'd1), 32'hDEAD_BEEF);
        chk_rd(1'b1, 32'hDEAD_BEEF, "LW: full word 0xDEADBEEF");

        // ================================================================
        // 9. SB — store byte at all 4 offsets
        // ================================================================
        // rs2_data[7:0] = 0xEF, replicated to all lanes; wstrb selects lane
        begin : t_sb
            automatic word_t rs2 = 32'hDEAD_BEEF;   // [7:0] = 0xEF
            automatic word_t rep = {4{rs2[7:0]}};    // 0xEFEFEFEF

            apply(mk_store(32'h0, 32'h100, rs2, MEM_SB), '0);  // offset 0
            chk_store(1'b1, 4'b0001, rep, "SB offset 0");
            if (mem_addr_w !== 32'h100)
                $fatal(1, "[MEM-STAGE] FAIL SB offset 0: addr=%08h", mem_addr_w);

            apply(mk_store(32'h0, 32'h101, rs2, MEM_SB), '0);  // offset 1
            chk_store(1'b1, 4'b0010, rep, "SB offset 1");

            apply(mk_store(32'h0, 32'h102, rs2, MEM_SB), '0);  // offset 2
            chk_store(1'b1, 4'b0100, rep, "SB offset 2");

            apply(mk_store(32'h0, 32'h103, rs2, MEM_SB), '0);  // offset 3
            chk_store(1'b1, 4'b1000, rep, "SB offset 3");
        end

        // ================================================================
        // 10. SH — store halfword at offset 0 and 2
        // ================================================================
        begin : t_sh
            automatic word_t rs2 = 32'hDEAD_BEEF;  // [15:0] = 0xBEEF
            automatic word_t rep = {2{rs2[15:0]}};  // 0xBEEFBEEF

            apply(mk_store(32'h0, 32'h100, rs2, MEM_SH), '0);  // half_off=0
            chk_store(1'b1, 4'b0011, rep, "SH offset 0");

            apply(mk_store(32'h0, 32'h102, rs2, MEM_SH), '0);  // half_off=1
            chk_store(1'b1, 4'b1100, rep, "SH offset 2");
        end

        // ================================================================
        // 11. SW — store full word
        // ================================================================
        apply(mk_store(32'h0, 32'h200, 32'hCAFE_BABE, MEM_SW), '0);
        chk_store(1'b1, 4'b1111, 32'hCAFE_BABE, "SW: all bytes");

        // ================================================================
        // 12. Load misalignment: LH at odd address → EXC_LOAD_ADDR_MISALIGNED
        // ================================================================
        apply(mk_load(32'h0, 32'h101, MEM_LH, 5'd1), MEM_WORD);   // addr[0]=1
        chk_exc(EXC_LOAD_ADDR_MISALIGNED, 32'h101, "LH misaligned odd addr");
        if (mem_wb_w.rd_wen !== 1'b0)
            $fatal(1, "[MEM-STAGE] FAIL LH misaligned: rd_wen should be 0");
        if (mem_wen_w !== 1'b0)
            $fatal(1, "[MEM-STAGE] FAIL LH misaligned: mem_wen should be 0");

        apply(mk_load(32'h0, 32'h103, MEM_LHU, 5'd1), MEM_WORD);  // LHU addr[0]=1
        chk_exc(EXC_LOAD_ADDR_MISALIGNED, 32'h103, "LHU misaligned odd addr");
        if (mem_wb_w.rd_wen !== 1'b0)
            $fatal(1, "[MEM-STAGE] FAIL LHU misaligned: rd_wen should be 0");

        // ================================================================
        // 13. Load misalignment: LW at non-4-byte-aligned address
        // ================================================================
        apply(mk_load(32'h0, 32'h101, MEM_LW, 5'd1), MEM_WORD);  // addr[1:0]=01
        chk_exc(EXC_LOAD_ADDR_MISALIGNED, 32'h101, "LW misaligned addr+1");

        apply(mk_load(32'h0, 32'h102, MEM_LW, 5'd1), MEM_WORD);  // addr[1:0]=10
        chk_exc(EXC_LOAD_ADDR_MISALIGNED, 32'h102, "LW misaligned addr+2");

        apply(mk_load(32'h0, 32'h103, MEM_LW, 5'd1), MEM_WORD);  // addr[1:0]=11
        chk_exc(EXC_LOAD_ADDR_MISALIGNED, 32'h103, "LW misaligned addr+3");

        // Aligned LW should NOT raise an exception
        apply(mk_load(32'h0, 32'h100, MEM_LW, 5'd1), MEM_WORD);  // addr[1:0]=00
        chk_no_exc("LW aligned: no exception");
        chk_rd(1'b1, MEM_WORD, "LW aligned: rd_data correct");

        // ================================================================
        // 14. Store misalignment: SH at odd address → EXC_STORE_ADDR_MISALIGNED
        // ================================================================
        apply(mk_store(32'h0, 32'h101, 32'hBEEF, MEM_SH), '0);  // addr[0]=1
        chk_exc(EXC_STORE_ADDR_MISALIGNED, 32'h101, "SH misaligned: exception");
        if (mem_wen_w !== 1'b0)
            $fatal(1, "[MEM-STAGE] FAIL SH misaligned: mem_wen should be 0");

        // ================================================================
        // 15. Store misalignment: SW at non-4-byte-aligned
        // ================================================================
        apply(mk_store(32'h0, 32'h202, 32'hDEAD, MEM_SW), '0);  // addr[1:0]=10
        chk_exc(EXC_STORE_ADDR_MISALIGNED, 32'h202, "SW misaligned: exception");
        if (mem_wen_w !== 1'b0)
            $fatal(1, "[MEM-STAGE] FAIL SW misaligned: mem_wen should be 0");

        // Aligned SW should write
        apply(mk_store(32'h0, 32'h200, 32'hDEAD_BEEF, MEM_SW), '0);
        chk_no_exc("SW aligned: no exception");
        chk_store(1'b1, 4'b1111, 32'hDEAD_BEEF, "SW aligned: writes correctly");

        // ================================================================
        // 16. Illegal instruction: decode exception forwarded; mem_wen=0
        //     even though is_store=1 (gated on legal=0)
        // ================================================================
        apply(mk_illegal(32'h5000, 32'hFFFF_FFFF), '0);
        if (mem_wb_w.rd_wen !== 1'b0)
            $fatal(1, "[MEM-STAGE] FAIL illegal: rd_wen should be 0");
        if (mem_wen_w !== 1'b0)
            $fatal(1, "[MEM-STAGE] FAIL illegal: mem_wen should be 0 (gated on legal)");
        if (!mem_wb_w.exception.valid)
            $fatal(1, "[MEM-STAGE] FAIL illegal: exception.valid should be 1");
        if (mem_wb_w.exception.cause !== EXC_ILLEGAL_INSTRUCTION)
            $fatal(1, "[MEM-STAGE] FAIL illegal: cause=%0d expected=%0d",
                   int'(mem_wb_w.exception.cause), int'(EXC_ILLEGAL_INSTRUCTION));
        $display("[MEM-STAGE] illegal: decode exception forwarded, mem_wen=0 ✓");

        // ================================================================
        // 17. Bubble with is_store=1: mem_wen must be 0 (gated on valid)
        // ================================================================
        begin : t_bubble_store
            automatic ex_mem_payload_t p = mk_store(32'h0, 32'h100, 32'hFF, MEM_SW);
            p.valid = 1'b0;  // mark as bubble
            apply(p, '0);
            if (mem_wen_w !== 1'b0)
                $fatal(1, "[MEM-STAGE] FAIL bubble store: mem_wen should be 0");
            if (mem_wb_w.valid !== 1'b0)
                $fatal(1, "[MEM-STAGE] FAIL bubble store: valid should be 0");
        end

        // ================================================================
        // 18. Pass-through field check: pc and instr survive
        // ================================================================
        begin : t_passthrough
            automatic ex_mem_payload_t p = mk_alu(32'hDEAD_1234, 32'h42, 5'd3, WB_ALU);
            p.instr = 32'h00C18233;
            apply(p, '0);
            if (mem_wb_w.pc !== 32'hDEAD_1234)
                $fatal(1, "[MEM-STAGE] FAIL pc not forwarded");
            if (mem_wb_w.instr !== 32'h00C18233)
                $fatal(1, "[MEM-STAGE] FAIL instr not forwarded");
            if (mem_wb_w.rd_addr !== 5'd3)
                $fatal(1, "[MEM-STAGE] FAIL rd_addr not forwarded");
        end

        // ================================================================
        // Done
        // ================================================================
        $display("[MEM-STAGE] PASS: all memory stage behaviors verified.");
        $finish;

    end : test_body

endmodule : tb_mem_stage

`default_nettype wire
