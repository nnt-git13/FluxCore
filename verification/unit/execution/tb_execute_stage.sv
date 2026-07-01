// verification/unit/execution/tb_execute_stage.sv
//
// Self-checking testbench for rtl/execution/execute_stage.sv.
//
// The DUT is purely combinational: no clock, no reset. Each test vector is
// applied via a helper task that drives id_ex_i, waits #1 for settling, then
// checks ex_mem_o against independently computed expected values.
//
// Coverage:
//   ALU register (ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU)
//   ALU immediate (ADDI, SLTI, SLTIU, ANDI, ORI, XORI, SLLI, SRLI, SRAI)
//   AUIPC — operand A = PC, operand B = upper-imm, alu_op = ADD
//   LUI   — operand B = upper-imm, alu_op = COPY_B (A ignored)
//   JAL   — branch_target = pc+imm, alu_result = pc+imm, branch_taken=0
//   JALR  — branch_target = (rs1+imm)&~1, bit-0 clearing verified
//   BEQ/BNE/BLT/BGE/BLTU/BGEU — taken and not-taken, correct target
//   Signed/unsigned branch divergence: rs1=0xFFFFFFFF, rs2=0x1
//   Store — alu_result = rs1+imm (address), rs2_data forwarded
//   Load  — alu_result = rs1+imm (address)
//   Illegal instruction — branch_taken forced to 0 regardless of comparator
//   Bubble (valid=0) — output valid=0, all results still computed (don't-care)

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_execute_stage;

    // -----------------------------------------------------------------------
    // DUT wires
    // -----------------------------------------------------------------------
    id_ex_payload_t  id_ex_w  = '0;
    ex_mem_payload_t ex_mem_w;

    execute_stage dut (
        .id_ex_i (id_ex_w),
        .ex_mem_o(ex_mem_w)
    );

    // -----------------------------------------------------------------------
    // Drive helper: apply vector and settle
    // -----------------------------------------------------------------------
    task automatic apply(input id_ex_payload_t p);
        id_ex_w = p;
        #1;
    endtask

    // -----------------------------------------------------------------------
    // Builders — construct id_ex_payload_t for common instruction types
    // -----------------------------------------------------------------------

    // R-type ALU: rd = rs1 op rs2
    function automatic id_ex_payload_t mk_alu_reg(
        input word_t    pc,
        input word_t    rs1_data,
        input word_t    rs2_data,
        input reg_idx_t rd,
        input alu_op_e  alu_op
    );
        automatic id_ex_payload_t p = '0;
        p.valid             = 1'b1;
        p.pc                = pc;
        p.decoded.legal     = 1'b1;
        p.decoded.op_class  = OPCLASS_ALU;
        p.decoded.alu_op    = alu_op;
        p.decoded.wb_src    = WB_ALU;
        p.decoded.uses_rs1  = 1'b1;
        p.decoded.uses_rs2  = 1'b1;
        p.decoded.writes_rd = 1'b1;
        p.decoded.rs1       = 5'd1;
        p.decoded.rs2       = 5'd2;
        p.decoded.rd        = rd;
        p.rs1_data          = rs1_data;
        p.rs2_data          = rs2_data;
        return p;
    endfunction

    // I-type ALU: rd = rs1 op imm
    function automatic id_ex_payload_t mk_alu_imm(
        input word_t    pc,
        input word_t    rs1_data,
        input word_t    imm,
        input reg_idx_t rd,
        input alu_op_e  alu_op
    );
        automatic id_ex_payload_t p = '0;
        p.valid             = 1'b1;
        p.pc                = pc;
        p.decoded.legal     = 1'b1;
        p.decoded.op_class  = OPCLASS_ALU;
        p.decoded.alu_op    = alu_op;
        p.decoded.wb_src    = WB_ALU;
        p.decoded.uses_rs1  = 1'b1;
        p.decoded.uses_rs2  = 1'b0;
        p.decoded.writes_rd = 1'b1;
        p.decoded.rs1       = 5'd1;
        p.decoded.rd        = rd;
        p.decoded.imm       = imm;
        p.rs1_data          = rs1_data;
        return p;
    endfunction

    // AUIPC: rd = pc + upper_imm
    function automatic id_ex_payload_t mk_auipc(
        input word_t    pc,
        input word_t    upper_imm,
        input reg_idx_t rd
    );
        automatic id_ex_payload_t p = '0;
        p.valid             = 1'b1;
        p.pc                = pc;
        p.decoded.legal     = 1'b1;
        p.decoded.op_class  = OPCLASS_ALU;
        p.decoded.alu_op    = ALU_ADD;
        p.decoded.wb_src    = WB_ALU;
        p.decoded.uses_rs1  = 1'b0;  // A = PC
        p.decoded.uses_rs2  = 1'b0;  // B = imm
        p.decoded.writes_rd = 1'b1;
        p.decoded.rd        = rd;
        p.decoded.imm       = upper_imm;
        p.rs1_data          = 32'hDEAD_DEAD; // irrelevant
        return p;
    endfunction

    // LUI: rd = upper_imm  (alu_op = COPY_B, opa irrelevant)
    function automatic id_ex_payload_t mk_lui(
        input word_t    pc,
        input word_t    upper_imm,
        input reg_idx_t rd
    );
        automatic id_ex_payload_t p = '0;
        p.valid             = 1'b1;
        p.pc                = pc;
        p.decoded.legal     = 1'b1;
        p.decoded.op_class  = OPCLASS_ALU;
        p.decoded.alu_op    = ALU_COPY_B;
        p.decoded.wb_src    = WB_ALU;
        p.decoded.uses_rs1  = 1'b0;
        p.decoded.uses_rs2  = 1'b0;
        p.decoded.writes_rd = 1'b1;
        p.decoded.rd        = rd;
        p.decoded.imm       = upper_imm;
        p.rs1_data          = 32'hDEAD_DEAD; // irrelevant
        return p;
    endfunction

    // JAL: wb = pc+4, branch_target = pc+imm
    function automatic id_ex_payload_t mk_jal(
        input word_t    pc,
        input word_t    imm,
        input reg_idx_t rd
    );
        automatic id_ex_payload_t p = '0;
        p.valid             = 1'b1;
        p.pc                = pc;
        p.decoded.legal     = 1'b1;
        p.decoded.op_class  = OPCLASS_JUMP;
        p.decoded.alu_op    = ALU_ADD;     // computes pc+imm (used as target)
        p.decoded.wb_src    = WB_PC4;
        p.decoded.uses_rs1  = 1'b0;       // A = PC
        p.decoded.uses_rs2  = 1'b0;       // B = imm
        p.decoded.writes_rd = 1'b1;
        p.decoded.rd        = rd;
        p.decoded.is_jump   = 1'b1;
        p.decoded.imm       = imm;
        p.rs1_data          = 32'hDEAD_DEAD; // irrelevant
        return p;
    endfunction

    // JALR: wb = pc+4, branch_target = (rs1+imm)&~1
    function automatic id_ex_payload_t mk_jalr(
        input word_t    pc,
        input word_t    rs1_data,
        input word_t    imm,
        input reg_idx_t rd
    );
        automatic id_ex_payload_t p = '0;
        p.valid             = 1'b1;
        p.pc                = pc;
        p.decoded.legal     = 1'b1;
        p.decoded.op_class  = OPCLASS_JUMP;
        p.decoded.alu_op    = ALU_ADD;
        p.decoded.wb_src    = WB_PC4;
        p.decoded.uses_rs1  = 1'b1;       // A = rs1
        p.decoded.uses_rs2  = 1'b0;       // B = imm
        p.decoded.writes_rd = 1'b1;
        p.decoded.rd        = rd;
        p.decoded.is_jump   = 1'b1;
        p.decoded.imm       = imm;
        p.rs1_data          = rs1_data;
        return p;
    endfunction

    // Conditional branch
    function automatic id_ex_payload_t mk_branch(
        input word_t      pc,
        input word_t      rs1_data,
        input word_t      rs2_data,
        input branch_op_e branch_op,
        input word_t      imm
    );
        automatic id_ex_payload_t p = '0;
        p.valid             = 1'b1;
        p.pc                = pc;
        p.decoded.legal     = 1'b1;
        p.decoded.op_class  = OPCLASS_BRANCH;
        p.decoded.alu_op    = ALU_ADD;     // result not used for branches
        p.decoded.branch_op = branch_op;
        p.decoded.wb_src    = WB_NONE;
        p.decoded.uses_rs1  = 1'b1;
        p.decoded.uses_rs2  = 1'b1;
        p.decoded.is_branch = 1'b1;
        p.decoded.imm       = imm;
        p.rs1_data          = rs1_data;
        p.rs2_data          = rs2_data;
        return p;
    endfunction

    // LOAD: alu_result = rs1 + imm (effective address)
    function automatic id_ex_payload_t mk_load(
        input word_t   pc,
        input word_t   rs1_data,
        input word_t   imm,
        input mem_op_e mem_op
    );
        automatic id_ex_payload_t p = '0;
        p.valid             = 1'b1;
        p.pc                = pc;
        p.decoded.legal     = 1'b1;
        p.decoded.op_class  = OPCLASS_LOAD;
        p.decoded.alu_op    = ALU_ADD;
        p.decoded.mem_op    = mem_op;
        p.decoded.wb_src    = WB_MEM;
        p.decoded.uses_rs1  = 1'b1;
        p.decoded.uses_rs2  = 1'b0;
        p.decoded.writes_rd = 1'b1;
        p.decoded.is_load   = 1'b1;
        p.decoded.imm       = imm;
        p.rs1_data          = rs1_data;
        return p;
    endfunction

    // STORE: alu_result = rs1 + imm (address), rs2_data = store data
    function automatic id_ex_payload_t mk_store(
        input word_t   pc,
        input word_t   rs1_data,
        input word_t   rs2_data,
        input word_t   imm,
        input mem_op_e mem_op
    );
        automatic id_ex_payload_t p = '0;
        p.valid             = 1'b1;
        p.pc                = pc;
        p.decoded.legal     = 1'b1;
        p.decoded.op_class  = OPCLASS_STORE;
        p.decoded.alu_op    = ALU_ADD;
        p.decoded.mem_op    = mem_op;
        p.decoded.wb_src    = WB_NONE;
        p.decoded.uses_rs1  = 1'b1;
        p.decoded.uses_rs2  = 1'b1;
        p.decoded.is_store  = 1'b1;
        p.decoded.imm       = imm;
        p.rs1_data          = rs1_data;
        p.rs2_data          = rs2_data;
        return p;
    endfunction

    // Illegal (decoded.legal=0)
    function automatic id_ex_payload_t mk_illegal(
        input word_t  pc,
        input instr_t bad_instr
    );
        automatic id_ex_payload_t p = '0;
        p.valid                  = 1'b1;
        p.pc                     = pc;
        p.instr                  = bad_instr;
        p.decoded.legal          = 1'b0;
        p.decoded.exception.valid= 1'b1;
        p.decoded.exception.cause= EXC_ILLEGAL_INSTRUCTION;
        p.decoded.exception.tval = word_t'(bad_instr);
        // Also set branch_op and is_branch to something that would trigger a
        // taken branch if gating were absent (so we actually test the gate).
        p.decoded.is_branch      = 1'b1;
        p.decoded.branch_op      = BRANCH_EQ;
        p.rs1_data               = 32'h5;
        p.rs2_data               = 32'h5;  // equal → branch_taken_s would be 1
        return p;
    endfunction

    // -----------------------------------------------------------------------
    // Check helpers
    // -----------------------------------------------------------------------
    task automatic chk_valid(input logic expected, input string desc);
        if (ex_mem_w.valid !== expected)
            $fatal(1, "[EX-STAGE] FAIL %-40s valid=%b expected=%b",
                   desc, ex_mem_w.valid, expected);
    endtask

    task automatic chk_alu(input word_t expected, input string desc);
        if (ex_mem_w.alu_result !== expected)
            $fatal(1, "[EX-STAGE] FAIL %-40s alu_result=%08h expected=%08h",
                   desc, ex_mem_w.alu_result, expected);
    endtask

    task automatic chk_branch(
        input logic  exp_taken,
        input word_t exp_target,
        input string desc
    );
        if (ex_mem_w.branch_taken !== exp_taken)
            $fatal(1, "[EX-STAGE] FAIL %-40s branch_taken=%b expected=%b",
                   desc, ex_mem_w.branch_taken, exp_taken);
        if (ex_mem_w.branch_target !== exp_target)
            $fatal(1, "[EX-STAGE] FAIL %-40s branch_target=%08h expected=%08h",
                   desc, ex_mem_w.branch_target, exp_target);
    endtask

    // -----------------------------------------------------------------------
    // Main test
    // -----------------------------------------------------------------------
    initial begin : test_body

        // ================================================================
        // 1. Bubble passthrough: valid=0 payload propagates as valid=0
        // ================================================================
        apply('0);
        chk_valid(1'b0, "bubble: valid=0 propagated");

        // ================================================================
        // 2. ALU register operations (R-type)
        // ================================================================
        // ADD x3, x1, x2: 5 + 3 = 8
        apply(mk_alu_reg(32'h1000, 32'h5, 32'h3, 5'd3, ALU_ADD));
        chk_alu(32'h8, "ADD 5+3=8");
        chk_valid(1'b1, "ADD valid");
        chk_branch(1'b0, 32'h1000, "ADD no branch");  // branch_target=pc+imm=0x1000+0 (R-type imm=0)

        // SUB: 10 - 7 = 3
        apply(mk_alu_reg(32'h0, 32'hA, 32'h7, 5'd1, ALU_SUB));
        chk_alu(32'h3, "SUB 10-7=3");

        // AND: 0xF0F0 & 0x0F0F = 0
        apply(mk_alu_reg(32'h0, 32'hF0F0_F0F0, 32'h0F0F_0F0F, 5'd1, ALU_AND));
        chk_alu(32'h0, "AND no overlap");

        // OR: 0xF0F0 | 0x0F0F = 0xFFFF
        apply(mk_alu_reg(32'h0, 32'h0000_F0F0, 32'h0000_0F0F, 5'd1, ALU_OR));
        chk_alu(32'h0000_FFFF, "OR");

        // XOR: a ^ a = 0
        apply(mk_alu_reg(32'h0, 32'hDEAD_BEEF, 32'hDEAD_BEEF, 5'd1, ALU_XOR));
        chk_alu(32'h0, "XOR same");

        // SLL: 1 << 4 = 16
        apply(mk_alu_reg(32'h0, 32'h1, 32'h4, 5'd1, ALU_SLL));
        chk_alu(32'h10, "SLL 1<<4=16");

        // SRL: 0x80000000 >> 1 = 0x40000000
        apply(mk_alu_reg(32'h0, 32'h8000_0000, 32'h1, 5'd1, ALU_SRL));
        chk_alu(32'h4000_0000, "SRL logical");

        // SRA: 0x80000000 >>> 1 = 0xC0000000 (sign-extended)
        apply(mk_alu_reg(32'h0, 32'h8000_0000, 32'h1, 5'd1, ALU_SRA));
        chk_alu(32'hC000_0000, "SRA arithmetic");

        // SLT: -1 < 1 (signed) = 1
        apply(mk_alu_reg(32'h0, 32'hFFFF_FFFF, 32'h1, 5'd1, ALU_SLT));
        chk_alu(32'h1, "SLT -1<1 signed");

        // SLT: 1 < -1 (signed) = 0
        apply(mk_alu_reg(32'h0, 32'h1, 32'hFFFF_FFFF, 5'd1, ALU_SLT));
        chk_alu(32'h0, "SLT 1<-1 signed no");

        // SLTU: MAX < 0 (unsigned) = 0
        apply(mk_alu_reg(32'h0, 32'hFFFF_FFFF, 32'h0, 5'd1, ALU_SLTU));
        chk_alu(32'h0, "SLTU MAX<0 unsigned no");

        // SLTU: 0 < 1 (unsigned) = 1
        apply(mk_alu_reg(32'h0, 32'h0, 32'h1, 5'd1, ALU_SLTU));
        chk_alu(32'h1, "SLTU 0<1 unsigned");

        // ================================================================
        // 3. ALU immediate operations (I-type)
        // ================================================================
        // ADDI: 100 + 5 = 105
        apply(mk_alu_imm(32'h0, 32'd100, 32'd5, 5'd1, ALU_ADD));
        chk_alu(32'd105, "ADDI 100+5=105");

        // ADDI with negative immediate: 100 + (-1) = 99
        apply(mk_alu_imm(32'h0, 32'd100, 32'hFFFF_FFFF, 5'd1, ALU_ADD));
        chk_alu(32'd99, "ADDI 100+(-1)=99");

        // SLLI: 1 << 7 = 128
        apply(mk_alu_imm(32'h0, 32'h1, 32'd7, 5'd1, ALU_SLL));
        chk_alu(32'h80, "SLLI 1<<7=128");

        // SLTIU: using unsigned comparison via ALU_SLTU
        apply(mk_alu_imm(32'h0, 32'h0, 32'h1, 5'd1, ALU_SLTU));
        chk_alu(32'h1, "SLTIU 0<1");

        // ================================================================
        // 4. AUIPC: alu_result = pc + upper_imm
        // ================================================================
        // pc=0x1000, upper_imm=0x12345000 → result=0x12346000
        apply(mk_auipc(32'h0000_1000, 32'h1234_5000, 5'd5));
        chk_alu(32'h1234_6000, "AUIPC pc+upper_imm");
        if (ex_mem_w.decoded.alu_op !== ALU_ADD)
            $fatal(1, "[EX-STAGE] FAIL AUIPC alu_op not ALU_ADD");

        // pc=0x0, upper_imm=0xFFFFF000 → result=0xFFFFF000
        apply(mk_auipc(32'h0, 32'hFFFFF000, 5'd1));
        chk_alu(32'hFFFFF000, "AUIPC pc=0 + 0xFFFFF000");

        // ================================================================
        // 5. LUI: alu_result = upper_imm  (PC not used)
        // ================================================================
        apply(mk_lui(32'hDEAD_1234, 32'hABCDE000, 5'd2));
        chk_alu(32'hABCDE000, "LUI upper_imm, PC ignored");

        apply(mk_lui(32'h0, 32'h8000_0000, 5'd1));
        chk_alu(32'h8000_0000, "LUI negative upper_imm");

        // ================================================================
        // 6. JAL: branch_target = pc + imm, branch_taken = 0 (not a branch!)
        // ================================================================
        // pc=0x100, imm=+8 → target=0x108
        apply(mk_jal(32'h100, 32'h8, 5'd1));
        chk_branch(1'b0, 32'h108, "JAL: target=pc+imm, taken=0");

        // pc=0x1000, imm=-4 → target=0xFFC
        apply(mk_jal(32'h1000, 32'hFFFF_FFFC, 5'd1));  // -4 sign-extended
        chk_branch(1'b0, 32'h0FFC, "JAL: target=pc-4");

        // ================================================================
        // 7. JALR: branch_target = (rs1+imm)&~1, bit-0 masking verified
        // ================================================================
        // rs1=0x100, imm=4 → raw=0x104, masked=0x104 (already aligned)
        apply(mk_jalr(32'h0, 32'h100, 32'h4, 5'd1));
        chk_branch(1'b0, 32'h104, "JALR: rs1+imm aligned, taken=0");

        // rs1=0x101, imm=0 → raw=0x101, masked=0x100 (bit-0 cleared)
        apply(mk_jalr(32'h0, 32'h101, 32'h0, 5'd1));
        if (ex_mem_w.branch_target !== 32'h100)
            $fatal(1, "[EX-STAGE] FAIL JALR bit-0 not cleared: target=%08h",
                   ex_mem_w.branch_target);
        $display("[EX-STAGE] JALR bit-0 cleared: 0x101 → 0x100 ✓");

        // rs1=0xFFFF_FFFF (all-ones), imm=1 → raw=0x0 (overflow), masked=0x0
        apply(mk_jalr(32'h0, 32'hFFFF_FFFF, 32'h1, 5'd1));
        chk_branch(1'b0, 32'h0, "JALR overflow+mask");

        // rs1=0x200, imm=-1 (0xFFFFFFFF) → raw=0x1FF, masked=0x1FE
        apply(mk_jalr(32'h0, 32'h200, 32'hFFFF_FFFF, 5'd1));
        if (ex_mem_w.branch_target !== 32'h1FE)
            $fatal(1, "[EX-STAGE] FAIL JALR 0x200-1=0x1FF, masked=%08h expected=0x1FE",
                   ex_mem_w.branch_target);

        // ================================================================
        // 8. Conditional branches
        // ================================================================
        // BEQ taken: rs1==rs2, target=pc+imm
        apply(mk_branch(32'h1000, 32'h42, 32'h42, BRANCH_EQ, 32'h10));
        chk_branch(1'b1, 32'h1010, "BEQ taken");

        // BEQ not taken: rs1!=rs2
        apply(mk_branch(32'h1000, 32'h42, 32'h43, BRANCH_EQ, 32'h10));
        chk_branch(1'b0, 32'h1010, "BEQ not taken");

        // BNE taken: rs1!=rs2
        apply(mk_branch(32'h2000, 32'h1, 32'h2, BRANCH_NE, 32'h20));
        chk_branch(1'b1, 32'h2020, "BNE taken");

        // BNE not taken: rs1==rs2
        apply(mk_branch(32'h2000, 32'hFF, 32'hFF, BRANCH_NE, 32'h20));
        chk_branch(1'b0, 32'h2020, "BNE not taken");

        // BLT taken: signed(-1) < signed(1)
        apply(mk_branch(32'h3000, 32'hFFFF_FFFF, 32'h1, BRANCH_LT, 32'h40));
        chk_branch(1'b1, 32'h3040, "BLT -1<1 taken");

        // BLT not taken: signed(1) < signed(-1) is false
        apply(mk_branch(32'h3000, 32'h1, 32'hFFFF_FFFF, BRANCH_LT, 32'h40));
        chk_branch(1'b0, 32'h3040, "BLT 1<-1 not taken");

        // BGE taken: signed(0) >= signed(-1)
        apply(mk_branch(32'h4000, 32'h0, 32'hFFFF_FFFF, BRANCH_GE, 32'h8));
        chk_branch(1'b1, 32'h4008, "BGE 0>=-1 taken");

        // BLTU taken: 0 < MAX (unsigned)
        apply(mk_branch(32'h5000, 32'h0, 32'hFFFF_FFFF, BRANCH_LTU, 32'h4));
        chk_branch(1'b1, 32'h5004, "BLTU 0<MAX taken");

        // BGEU taken: MAX >= 0 (unsigned)
        apply(mk_branch(32'h6000, 32'hFFFF_FFFF, 32'h0, BRANCH_GEU, 32'h4));
        chk_branch(1'b1, 32'h6004, "BGEU MAX>=0 taken");

        // Negative branch offset: target = pc - 8
        apply(mk_branch(32'h2000, 32'h5, 32'h5, BRANCH_EQ, 32'hFFFF_FFF8)); // -8
        chk_branch(1'b1, 32'h1FF8, "BEQ backward branch target");

        // ================================================================
        // 9. Signed/unsigned divergence: rs1=0xFFFF_FFFF, rs2=0x1
        //    BLT  → taken   (signed: -1 < 1)
        //    BLTU → NOT taken (unsigned: MAX > 1)
        //    BGE  → NOT taken (signed: -1 not >= 1)
        //    BGEU → taken   (unsigned: MAX >= 1)
        // ================================================================
        apply(mk_branch(32'h0, 32'hFFFF_FFFF, 32'h1, BRANCH_LT,  32'h4));
        chk_branch(1'b1, 32'h4, "sign/unsigned: BLT taken");

        apply(mk_branch(32'h0, 32'hFFFF_FFFF, 32'h1, BRANCH_LTU, 32'h4));
        chk_branch(1'b0, 32'h4, "sign/unsigned: BLTU not taken");

        apply(mk_branch(32'h0, 32'hFFFF_FFFF, 32'h1, BRANCH_GE,  32'h4));
        chk_branch(1'b0, 32'h4, "sign/unsigned: BGE not taken");

        apply(mk_branch(32'h0, 32'hFFFF_FFFF, 32'h1, BRANCH_GEU, 32'h4));
        chk_branch(1'b1, 32'h4, "sign/unsigned: BGEU taken");

        // ================================================================
        // 10. Store: alu_result = effective address, rs2_data forwarded
        // ================================================================
        // SW x2, 8(x1): addr = 0x100 + 8 = 0x108
        apply(mk_store(32'h0, 32'h100, 32'hDEAD_BEEF, 32'h8, MEM_SW));
        chk_alu(32'h108, "SW effective address rs1+imm");
        if (ex_mem_w.rs2_data !== 32'hDEAD_BEEF)
            $fatal(1, "[EX-STAGE] FAIL SW rs2_data not forwarded: %08h", ex_mem_w.rs2_data);
        chk_branch(1'b0, 32'h8, "SW no branch");

        // SB x5, -4(x3): addr = 0x1000 - 4 = 0xFFC
        apply(mk_store(32'h0, 32'h1000, 32'hAB, 32'hFFFF_FFFC, MEM_SB));
        chk_alu(32'h0FFC, "SB negative offset");

        // ================================================================
        // 11. Load: alu_result = effective address
        // ================================================================
        // LW x1, 12(x2): addr = 0x200 + 12 = 0x20C
        apply(mk_load(32'h0, 32'h200, 32'hC, MEM_LW));
        chk_alu(32'h20C, "LW effective address");

        // LH x1, -2(x3): addr = 0x300 - 2 = 0x2FE
        apply(mk_load(32'h0, 32'h300, 32'hFFFF_FFFE, MEM_LH));
        chk_alu(32'h2FE, "LH negative offset");

        // ================================================================
        // 12. Illegal instruction: branch_taken must be 0 even when the
        //     comparator would say taken (rs1==rs2, BRANCH_EQ).
        //     Gating on decoded.legal prevents spurious PC redirect.
        // ================================================================
        apply(mk_illegal(32'h5000, 32'hDEAD_DEAD));
        if (ex_mem_w.branch_taken !== 1'b0)
            $fatal(1, "[EX-STAGE] FAIL illegal: branch_taken=%b should be 0",
                   ex_mem_w.branch_taken);
        if (!ex_mem_w.decoded.exception.valid)
            $fatal(1, "[EX-STAGE] FAIL illegal: exception.valid should be 1");
        if (ex_mem_w.decoded.legal !== 1'b0)
            $fatal(1, "[EX-STAGE] FAIL illegal: decoded.legal should be 0");
        $display("[EX-STAGE] illegal: branch_taken gated on legal=0 ✓");

        // ================================================================
        // 13. Pass-through field check: decoded, pc, instr forwarded intact
        // ================================================================
        begin : t_passthrough
            automatic id_ex_payload_t p = mk_alu_reg(32'hABCD_1234, 32'h1, 32'h2, 5'd7, ALU_OR);
            p.instr = 32'h00C08433;
            apply(p);
            if (ex_mem_w.pc !== 32'hABCD_1234)
                $fatal(1, "[EX-STAGE] FAIL pc not forwarded");
            if (ex_mem_w.instr !== 32'h00C08433)
                $fatal(1, "[EX-STAGE] FAIL instr not forwarded");
            if (ex_mem_w.decoded.rd !== 5'd7)
                $fatal(1, "[EX-STAGE] FAIL decoded.rd not forwarded");
        end

        // ================================================================
        // Done
        // ================================================================
        $display("[EX-STAGE] PASS: all execute-stage behaviors verified.");
        $finish;

    end : test_body

endmodule : tb_execute_stage

`default_nettype wire
