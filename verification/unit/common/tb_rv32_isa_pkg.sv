// verification/unit/common/tb_rv32_isa_pkg.sv
//
// Self-checking testbench for rv32_isa_pkg.sv.
//
// Verifies:
//   1. Opcode constants match the RISC-V specification bit patterns.
//   2. funct3 constants are correctly encoded.
//   3. funct7 constants are correctly encoded.
//   4. Instruction-field bit positions are correct.
//   5. All enum values are accessible and have expected ordinals.
//   6. decoded_instr_t field accessibility and packed width (129 bits).
//   7. CSR-related types: csr_op_e values, WB_CSR, CSR address constants.
//
// Pass/fail:
//   Uses $fatal(1, ...) on any mismatch.
//   Prints "[ISA-TEST] PASS" and calls $finish on success.

`timescale 1ns / 1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;

module tb_rv32_isa_pkg;

    // -----------------------------------------------------------------------
    // Helper tasks
    // -----------------------------------------------------------------------
    task automatic check_eq(input string name, input int actual, input int expected);
        if (actual !== expected)
            $fatal(1, "[ISA-TEST] FAIL: %s = 'b%b (%0d), expected 'b%b (%0d)",
                   name, actual, actual, expected, expected);
    endtask

    task automatic check_true(input string name, input logic condition);
        if (!condition)
            $fatal(1, "[ISA-TEST] FAIL: invariant violated: %s", name);
    endtask

    // -----------------------------------------------------------------------
    // Expected sizes
    // -----------------------------------------------------------------------
    // decoded_instr_t field-by-field sum (see package comment):
    //   legal(1) + op_class(3) + alu_op(5) + branch_op(3) + mem_op(4) + wb_src(3)
    //   + rs1(5) + rs2(5) + rd(5)
    //   + uses_rs1(1) + uses_rs2(1) + writes_rd(1)
    //   + imm(32)
    //   + is_branch(1) + is_jump(1) + is_load(1) + is_store(1)
    //   + is_csr(1) + is_mret(1) + is_long_latency(1) + is_custom(1)
    //   + csr_addr(12) + csr_op(2)
    //   + exception_meta_t(1+1+EXC_CAUSE_W+XLEN = 1+1+4+32 = 38)
    //   = 1+3+5+3+4+3+5+5+5+1+1+1+32+1+1+1+1+1+1+1+1+12+2+38 = 129  (exception_meta_t gained is_irq)
    localparam int EXPECTED_DECODED_INSTR_W =
        1 +  // legal
        3 +  // op_class (op_class_e, 3-bit)
        5 +  // alu_op (alu_op_e, 5-bit — 24 values ALU_ADD..ALU_XCLZ)
        3 +  // branch_op (branch_op_e, 3-bit)
        4 +  // mem_op (mem_op_e, 4-bit)
        3 +  // wb_src (wb_src_e, 3-bit with WB_CSR)
        5 +  // rs1
        5 +  // rs2
        5 +  // rd
        1 +  // uses_rs1
        1 +  // uses_rs2
        1 +  // writes_rd
        32 + // imm
        1 +  // is_branch
        1 +  // is_jump
        1 +  // is_load
        1 +  // is_store
        1 +  // is_csr
        1 +  // is_mret
        1 +  // is_long_latency
        1 +  // is_custom
        12 + // csr_addr
        2 +  // csr_op (csr_op_e, 2-bit)
        (1 + 1 + fluxcore_pkg::EXC_CAUSE_W + fluxcore_pkg::XLEN); // exception_meta_t (valid, is_irq, cause, tval)

    initial begin : test_body

        // ----------------------------------------------------------------
        // 1. Instruction field positions (sanity check against RISC-V spec)
        // ----------------------------------------------------------------
        check_eq("INSTR_OPCODE_LSB",  rv32_isa_pkg::INSTR_OPCODE_LSB,  0);
        check_eq("INSTR_OPCODE_MSB",  rv32_isa_pkg::INSTR_OPCODE_MSB,  6);
        check_eq("INSTR_RD_LSB",      rv32_isa_pkg::INSTR_RD_LSB,      7);
        check_eq("INSTR_RD_MSB",      rv32_isa_pkg::INSTR_RD_MSB,     11);
        check_eq("INSTR_FUNCT3_LSB",  rv32_isa_pkg::INSTR_FUNCT3_LSB, 12);
        check_eq("INSTR_FUNCT3_MSB",  rv32_isa_pkg::INSTR_FUNCT3_MSB, 14);
        check_eq("INSTR_RS1_LSB",     rv32_isa_pkg::INSTR_RS1_LSB,    15);
        check_eq("INSTR_RS1_MSB",     rv32_isa_pkg::INSTR_RS1_MSB,    19);
        check_eq("INSTR_RS2_LSB",     rv32_isa_pkg::INSTR_RS2_LSB,    20);
        check_eq("INSTR_RS2_MSB",     rv32_isa_pkg::INSTR_RS2_MSB,    24);
        check_eq("INSTR_FUNCT7_LSB",  rv32_isa_pkg::INSTR_FUNCT7_LSB, 25);
        check_eq("INSTR_FUNCT7_MSB",  rv32_isa_pkg::INSTR_FUNCT7_MSB, 31);

        // ----------------------------------------------------------------
        // 2. Opcodes (RISC-V spec Table 24.1)
        // ----------------------------------------------------------------
        // All opcodes have bits [1:0] = 2'b11 — this is required for a
        // 32-bit RISC-V instruction.
        check_eq("OPCODE_LOAD",    int'(OPCODE_LOAD),     7'b000_0011);
        check_eq("OPCODE_STORE",   int'(OPCODE_STORE),    7'b010_0011);
        check_eq("OPCODE_OP_IMM",  int'(OPCODE_OP_IMM),   7'b001_0011);
        check_eq("OPCODE_OP",      int'(OPCODE_OP),        7'b011_0011);
        check_eq("OPCODE_LUI",     int'(OPCODE_LUI),       7'b011_0111);
        check_eq("OPCODE_AUIPC",   int'(OPCODE_AUIPC),     7'b001_0111);
        check_eq("OPCODE_JAL",     int'(OPCODE_JAL),       7'b110_1111);
        check_eq("OPCODE_JALR",    int'(OPCODE_JALR),      7'b110_0111);
        check_eq("OPCODE_BRANCH",  int'(OPCODE_BRANCH),    7'b110_0011);
        check_eq("OPCODE_SYSTEM",  int'(OPCODE_SYSTEM),    7'b111_0011);
        check_eq("OPCODE_MISC_MEM",int'(OPCODE_MISC_MEM),  7'b000_1111);

        // All opcodes must have bits [1:0] = 2'b11
        check_true("OPCODE_LOAD[1:0]==11",    logic'(OPCODE_LOAD[1:0]    == 2'b11));
        check_true("OPCODE_STORE[1:0]==11",   logic'(OPCODE_STORE[1:0]   == 2'b11));
        check_true("OPCODE_OP_IMM[1:0]==11",  logic'(OPCODE_OP_IMM[1:0]  == 2'b11));
        check_true("OPCODE_OP[1:0]==11",      logic'(OPCODE_OP[1:0]      == 2'b11));
        check_true("OPCODE_LUI[1:0]==11",     logic'(OPCODE_LUI[1:0]     == 2'b11));
        check_true("OPCODE_AUIPC[1:0]==11",   logic'(OPCODE_AUIPC[1:0]   == 2'b11));
        check_true("OPCODE_JAL[1:0]==11",     logic'(OPCODE_JAL[1:0]     == 2'b11));
        check_true("OPCODE_JALR[1:0]==11",    logic'(OPCODE_JALR[1:0]    == 2'b11));
        check_true("OPCODE_BRANCH[1:0]==11",  logic'(OPCODE_BRANCH[1:0]  == 2'b11));
        check_true("OPCODE_SYSTEM[1:0]==11",  logic'(OPCODE_SYSTEM[1:0]  == 2'b11));

        // ----------------------------------------------------------------
        // 3. funct3 constants (OP / OP-IMM group)
        // ----------------------------------------------------------------
        check_eq("FUNCT3_ADD_SUB", int'(FUNCT3_ADD_SUB), 3'b000);
        check_eq("FUNCT3_SLL",     int'(FUNCT3_SLL),     3'b001);
        check_eq("FUNCT3_SLT",     int'(FUNCT3_SLT),     3'b010);
        check_eq("FUNCT3_SLTU",    int'(FUNCT3_SLTU),    3'b011);
        check_eq("FUNCT3_XOR",     int'(FUNCT3_XOR),     3'b100);
        check_eq("FUNCT3_SRL_SRA", int'(FUNCT3_SRL_SRA), 3'b101);
        check_eq("FUNCT3_OR",      int'(FUNCT3_OR),      3'b110);
        check_eq("FUNCT3_AND",     int'(FUNCT3_AND),     3'b111);

        // BRANCH funct3
        check_eq("FUNCT3_BEQ",    int'(FUNCT3_BEQ),  3'b000);
        check_eq("FUNCT3_BNE",    int'(FUNCT3_BNE),  3'b001);
        check_eq("FUNCT3_BLT",    int'(FUNCT3_BLT),  3'b100);
        check_eq("FUNCT3_BGE",    int'(FUNCT3_BGE),  3'b101);
        check_eq("FUNCT3_BLTU",   int'(FUNCT3_BLTU), 3'b110);
        check_eq("FUNCT3_BGEU",   int'(FUNCT3_BGEU), 3'b111);

        // LOAD funct3
        check_eq("FUNCT3_LB",   int'(FUNCT3_LB),  3'b000);
        check_eq("FUNCT3_LH",   int'(FUNCT3_LH),  3'b001);
        check_eq("FUNCT3_LW",   int'(FUNCT3_LW),  3'b010);
        check_eq("FUNCT3_LBU",  int'(FUNCT3_LBU), 3'b100);
        check_eq("FUNCT3_LHU",  int'(FUNCT3_LHU), 3'b101);

        // STORE funct3
        check_eq("FUNCT3_SB",   int'(FUNCT3_SB),  3'b000);
        check_eq("FUNCT3_SH",   int'(FUNCT3_SH),  3'b001);
        check_eq("FUNCT3_SW",   int'(FUNCT3_SW),  3'b010);

        // ----------------------------------------------------------------
        // 4. funct7 constants
        // ----------------------------------------------------------------
        check_eq("FUNCT7_NORMAL", int'(FUNCT7_NORMAL), 7'b000_0000);
        check_eq("FUNCT7_ALT",    int'(FUNCT7_ALT),    7'b010_0000);
        check_eq("FUNCT7_MEXT",   int'(FUNCT7_MEXT),   7'b000_0001);

        // SUB and SRA are distinguished from ADD/SRL by bit 5 of funct7.
        check_true("FUNCT7_ALT bit 5 set",    logic'(FUNCT7_ALT[5]    == 1'b1));
        check_true("FUNCT7_NORMAL bit 5 zero", logic'(FUNCT7_NORMAL[5] == 1'b0));

        // ----------------------------------------------------------------
        // 5. ALU op enum values
        // ----------------------------------------------------------------
        check_eq("ALU_ADD",    int'(ALU_ADD),     0);
        check_eq("ALU_SUB",    int'(ALU_SUB),     1);
        check_eq("ALU_AND",    int'(ALU_AND),     2);
        check_eq("ALU_OR",     int'(ALU_OR),      3);
        check_eq("ALU_XOR",    int'(ALU_XOR),     4);
        check_eq("ALU_SLL",    int'(ALU_SLL),     5);
        check_eq("ALU_SRL",    int'(ALU_SRL),     6);
        check_eq("ALU_SRA",    int'(ALU_SRA),     7);
        check_eq("ALU_SLT",    int'(ALU_SLT),     8);
        check_eq("ALU_SLTU",   int'(ALU_SLTU),    9);
        check_eq("ALU_COPY_B", int'(ALU_COPY_B), 10);
        // Must fit in 4 bits
        check_true("ALU_COPY_B fits in 4 bits", logic'(int'(ALU_COPY_B) < 16));

        // ----------------------------------------------------------------
        // 6. Branch op enum values
        // ----------------------------------------------------------------
        check_eq("BRANCH_NONE", int'(BRANCH_NONE), 0);
        check_eq("BRANCH_EQ",   int'(BRANCH_EQ),   1);
        check_eq("BRANCH_NE",   int'(BRANCH_NE),   2);
        check_eq("BRANCH_LT",   int'(BRANCH_LT),   3);
        check_eq("BRANCH_GE",   int'(BRANCH_GE),   4);
        check_eq("BRANCH_LTU",  int'(BRANCH_LTU),  5);
        check_eq("BRANCH_GEU",  int'(BRANCH_GEU),  6);
        check_true("BRANCH_GEU fits in 3 bits", logic'(int'(BRANCH_GEU) < 8));

        // ----------------------------------------------------------------
        // 7. Memory op enum values
        // ----------------------------------------------------------------
        check_eq("MEM_NONE", int'(MEM_NONE), 0);
        check_eq("MEM_LB",   int'(MEM_LB),   1);
        check_eq("MEM_LBU",  int'(MEM_LBU),  2);
        check_eq("MEM_LH",   int'(MEM_LH),   3);
        check_eq("MEM_LHU",  int'(MEM_LHU),  4);
        check_eq("MEM_LW",   int'(MEM_LW),   5);
        check_eq("MEM_SB",   int'(MEM_SB),   6);
        check_eq("MEM_SH",   int'(MEM_SH),   7);
        check_eq("MEM_SW",   int'(MEM_SW),   8);
        check_true("MEM_SW fits in 4 bits", logic'(int'(MEM_SW) < 16));

        // ----------------------------------------------------------------
        // 8. Writeback source enum values
        // ----------------------------------------------------------------
        check_eq("WB_NONE", int'(WB_NONE), 0);
        check_eq("WB_ALU",  int'(WB_ALU),  1);
        check_eq("WB_MEM",  int'(WB_MEM),  2);
        check_eq("WB_PC4",  int'(WB_PC4),  3);
        check_true("WB_PC4 fits in 2 bits", logic'(int'(WB_PC4) < 4));

        // ----------------------------------------------------------------
        // 9. Operation class enum values
        // ----------------------------------------------------------------
        check_eq("OPCLASS_ALU",      int'(OPCLASS_ALU),      0);
        check_eq("OPCLASS_BRANCH",   int'(OPCLASS_BRANCH),   1);
        check_eq("OPCLASS_JUMP",     int'(OPCLASS_JUMP),     2);
        check_eq("OPCLASS_LOAD",     int'(OPCLASS_LOAD),     3);
        check_eq("OPCLASS_STORE",    int'(OPCLASS_STORE),    4);
        check_eq("OPCLASS_SYSTEM",   int'(OPCLASS_SYSTEM),   5);
        check_eq("OPCLASS_LONG_LAT", int'(OPCLASS_LONG_LAT), 6);
        check_eq("OPCLASS_CUSTOM",   int'(OPCLASS_CUSTOM),   7);
        check_true("OPCLASS_CUSTOM fits in 3 bits", logic'(int'(OPCLASS_CUSTOM) < 8));

        // ----------------------------------------------------------------
        // 10. decoded_instr_t: field accessibility and packed width
        // ----------------------------------------------------------------
        begin : check_decoded_instr
            automatic decoded_instr_t d;

            // Assign every field to confirm the layout is correct.
            d = '0;
            d.legal          = 1'b1;
            d.op_class       = OPCLASS_ALU;
            d.alu_op         = ALU_ADD;
            d.branch_op      = BRANCH_NONE;
            d.mem_op         = MEM_NONE;
            d.wb_src         = WB_ALU;
            d.rs1            = 5'd1;
            d.rs2            = 5'd2;
            d.rd             = 5'd3;
            d.uses_rs1       = 1'b1;
            d.uses_rs2       = 1'b1;
            d.writes_rd      = 1'b1;
            d.imm            = 32'h0000_0005;
            d.is_branch      = 1'b0;
            d.is_jump        = 1'b0;
            d.is_load        = 1'b0;
            d.is_store       = 1'b0;
            d.is_csr         = 1'b0;
            d.is_mret        = 1'b0;
            d.is_long_latency= 1'b0;
            d.is_custom      = 1'b0;
            d.csr_addr       = 12'h305;
            d.csr_op         = CSR_WRITE;
            d.exception      = '0;

            // Spot-check readback
            if (d.legal    !== 1'b1)        $fatal(1, "[ISA-TEST] FAIL: d.legal readback");
            if (d.op_class !== OPCLASS_ALU) $fatal(1, "[ISA-TEST] FAIL: d.op_class readback");
            if (d.alu_op   !== ALU_ADD)     $fatal(1, "[ISA-TEST] FAIL: d.alu_op readback");
            if (d.wb_src   !== WB_ALU)      $fatal(1, "[ISA-TEST] FAIL: d.wb_src readback");
            if (d.rs1      !== 5'd1)        $fatal(1, "[ISA-TEST] FAIL: d.rs1 readback");
            if (d.rd       !== 5'd3)        $fatal(1, "[ISA-TEST] FAIL: d.rd readback");
            if (d.imm      !== 32'h5)       $fatal(1, "[ISA-TEST] FAIL: d.imm readback");

            // Encode an illegal instruction
            d = '0;
            d.legal              = 1'b0;
            d.exception.valid    = 1'b1;
            d.exception.cause    = EXC_ILLEGAL_INSTRUCTION;
            d.exception.tval     = 32'hFFFF_FFFF;

            if (d.legal !== 1'b0)
                $fatal(1, "[ISA-TEST] FAIL: illegal d.legal");
            if (d.exception.valid !== 1'b1)
                $fatal(1, "[ISA-TEST] FAIL: illegal exception.valid");
            if (d.exception.cause !== EXC_ILLEGAL_INSTRUCTION)
                $fatal(1, "[ISA-TEST] FAIL: illegal exception.cause");

            // Packed width
            if ($bits(decoded_instr_t) !== EXPECTED_DECODED_INSTR_W)
                $fatal(1, "[ISA-TEST] FAIL: $bits(decoded_instr_t)=%0d expected=%0d",
                       $bits(decoded_instr_t), EXPECTED_DECODED_INSTR_W);
        end

        // ----------------------------------------------------------------
        // 11. CSR types: csr_op_e, WB_CSR, CSR address constants
        // ----------------------------------------------------------------
        check_eq("CSR_NOP",   int'(CSR_NOP),   2'b00);
        check_eq("CSR_WRITE", int'(CSR_WRITE), 2'b01);
        check_eq("CSR_SET",   int'(CSR_SET),   2'b10);
        check_eq("CSR_CLR",   int'(CSR_CLR),   2'b11);
        check_eq("WB_CSR",    int'(WB_CSR),    3'd4);
        check_eq("CSR_MSTATUS",  int'(CSR_MSTATUS),  12'h300);
        check_eq("CSR_MTVEC",    int'(CSR_MTVEC),    12'h305);
        check_eq("CSR_MSCRATCH", int'(CSR_MSCRATCH), 12'h340);
        check_eq("CSR_MEPC",     int'(CSR_MEPC),     12'h341);
        check_eq("CSR_MCAUSE",   int'(CSR_MCAUSE),   12'h342);
        check_eq("CSR_MTVAL",    int'(CSR_MTVAL),    12'h343);
        check_eq("CSR_MIP",      int'(CSR_MIP),      12'h344);
        check_eq("CSR_MCYCLE",   int'(CSR_MCYCLE),   12'hB00);
        check_eq("CSR_MINSTRET", int'(CSR_MINSTRET), 12'hB02);
        check_eq("CSR_MCYCLEH",  int'(CSR_MCYCLEH),  12'hB80);
        check_eq("CSR_MINSTRETH", int'(CSR_MINSTRETH), 12'hB82);
        check_eq("CSR_MHARTID",  int'(CSR_MHARTID),  12'hF14);
        check_eq("FUNCT12_MRET", int'(FUNCT12_MRET), 12'h302);

        // Confirm decoded_instr_t CSR fields round-trip
        begin : csr_field_check
            automatic decoded_instr_t dc;
            dc = '0;
            dc.is_csr  = 1'b1;
            dc.csr_addr = CSR_MTVEC;
            dc.csr_op  = CSR_SET;
            dc.wb_src  = WB_CSR;
            if (dc.is_csr  !== 1'b1)         $fatal(1, "[ISA-TEST] FAIL: is_csr readback");
            if (dc.csr_addr !== CSR_MTVEC)   $fatal(1, "[ISA-TEST] FAIL: csr_addr readback");
            if (dc.csr_op  !== CSR_SET)       $fatal(1, "[ISA-TEST] FAIL: csr_op readback");
            if (dc.wb_src  !== WB_CSR)        $fatal(1, "[ISA-TEST] FAIL: wb_src=WB_CSR readback");
            dc = '0;
            dc.is_mret = 1'b1;
            if (dc.is_mret !== 1'b1)          $fatal(1, "[ISA-TEST] FAIL: is_mret readback");
        end

        // ----------------------------------------------------------------
        // Done
        // ----------------------------------------------------------------
        $display("[ISA-TEST] PASS: rv32_isa_pkg verified.");
        $display("[ISA-TEST]   decoded_instr_t = %0d bits", $bits(decoded_instr_t));
        $display("[ISA-TEST]   ALU ops: %0d  Branch ops: %0d  Mem ops: %0d",
                 int'(ALU_COPY_B)+1, int'(BRANCH_GEU)+1, int'(MEM_SW)+1);
        $finish;

    end : test_body

endmodule : tb_rv32_isa_pkg

`default_nettype wire
