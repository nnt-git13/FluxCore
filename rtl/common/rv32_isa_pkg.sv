// rtl/common/rv32_isa_pkg.sv
//
// FluxCore RV32I ISA definitions package.
//
// Purpose:
//   Defines all RISC-V-specific constants, enums, and types used across the
//   FluxCore pipeline. Every module that touches instruction decoding, execution
//   control, or pipeline payloads imports this package alongside fluxcore_pkg.
//
// Dependency:
//   Imports fluxcore_pkg for shared base types (word_t, reg_idx_t,
//   exception_meta_t, etc.). No other package is imported.
//   Do not create a circular dependency back to rv32_isa_pkg from fluxcore_pkg.
//
// Scope discipline:
//   This package defines the RV32I + RV32M + XFlux ISA contract. Stage payloads,
//   cache types, scoreboard types, and AXI types live in separate files compiled
//   after this. FP extensions are reserved for a future milestone.
//
// Naming conventions:
//   Types:           *_t
//   Enums:           *_e
//   Opcode constants: OPCODE_*  (7-bit)
//   funct3 constants: FUNCT3_*  (3-bit, named per instruction group)
//   funct7 constants: FUNCT7_*  (7-bit)
//   Bit-field params: INSTR_*_LSB / INSTR_*_MSB

`default_nettype none

package rv32_isa_pkg;

    import fluxcore_pkg::*;

// ---------------------------------------------------------------------------
// 1. Instruction field bit positions
// ---------------------------------------------------------------------------
// All 32-bit RISC-V base instructions share these field positions.
// Use these constants in the decoder instead of magic bit indices.

localparam int unsigned INSTR_OPCODE_LSB  = 0;
localparam int unsigned INSTR_OPCODE_MSB  = 6;
localparam int unsigned INSTR_RD_LSB      = 7;
localparam int unsigned INSTR_RD_MSB      = 11;
localparam int unsigned INSTR_FUNCT3_LSB  = 12;
localparam int unsigned INSTR_FUNCT3_MSB  = 14;
localparam int unsigned INSTR_RS1_LSB     = 15;
localparam int unsigned INSTR_RS1_MSB     = 19;
localparam int unsigned INSTR_RS2_LSB     = 20;
localparam int unsigned INSTR_RS2_MSB     = 24;
localparam int unsigned INSTR_SHAMT_LSB   = 20;   // shift amount (same bits as rs2)
localparam int unsigned INSTR_SHAMT_MSB   = 24;
localparam int unsigned INSTR_FUNCT7_LSB  = 25;
localparam int unsigned INSTR_FUNCT7_MSB  = 31;

// ---------------------------------------------------------------------------
// 2. Field-width constants
// ---------------------------------------------------------------------------

localparam int unsigned OPCODE_W = 7;
localparam int unsigned FUNCT3_W = 3;
localparam int unsigned FUNCT7_W = 7;

// Convenience types for the decoder
typedef logic [OPCODE_W-1:0] opcode_t;
typedef logic [FUNCT3_W-1:0] funct3_t;
typedef logic [FUNCT7_W-1:0] funct7_t;

// ---------------------------------------------------------------------------
// 3. Opcodes
// ---------------------------------------------------------------------------
// RISC-V 32-bit instruction opcodes (bits [6:0]).
// Every valid 32-bit RISC-V encoding has bits [1:0] = 2'b11.
// The encoding table is from the unprivileged specification, Table 24.1.

localparam opcode_t OPCODE_LOAD    = 7'b000_0011;  // LB LH LW LBU LHU
localparam opcode_t OPCODE_STORE   = 7'b010_0011;  // SB SH SW
localparam opcode_t OPCODE_OP_IMM  = 7'b001_0011;  // ADDI SLTI SLTIU XORI ORI ANDI SLLI SRLI SRAI
localparam opcode_t OPCODE_OP      = 7'b011_0011;  // ADD SUB SLL SLT SLTU XOR SRL SRA OR AND
localparam opcode_t OPCODE_LUI     = 7'b011_0111;  // LUI
localparam opcode_t OPCODE_AUIPC   = 7'b001_0111;  // AUIPC
localparam opcode_t OPCODE_JAL     = 7'b110_1111;  // JAL
localparam opcode_t OPCODE_JALR    = 7'b110_0111;  // JALR
localparam opcode_t OPCODE_BRANCH  = 7'b110_0011;  // BEQ BNE BLT BGE BLTU BGEU
localparam opcode_t OPCODE_SYSTEM  = 7'b111_0011;  // ECALL EBREAK (CSR ops later)
localparam opcode_t OPCODE_MISC_MEM= 7'b000_1111;  // FENCE (NOP in initial implementation)

// XFlux custom-0 opcode (RISC-V CUSTOM_0 space): indexed load and data ops.
localparam opcode_t OPCODE_CUSTOM_0 = 7'b000_1011;  // XLIDX/XABS/XMIN/XMAX/XCLZ

// RV32F single-precision floating-point opcodes.
// FLW/FSW share the LOAD/STORE address computation but target the FP register
// file. OP-FP covers all register-register FP arithmetic and the FP↔int
// conversion / move / compare / classify group (funct7 = FP_FUNCT7_* below).
// The four fused-multiply-add opcodes each carry an fs3 operand in instr[31:27].
localparam opcode_t OPCODE_LOAD_FP  = 7'b000_0111;  // FLW
localparam opcode_t OPCODE_STORE_FP = 7'b010_0111;  // FSW
localparam opcode_t OPCODE_OP_FP    = 7'b101_0011;  // FADD.S FSUB.S FMUL.S FDIV.S FSQRT.S FSGNJ FMIN FEQ FCVT FMV FCLASS …
localparam opcode_t OPCODE_MADD     = 7'b100_0011;  // FMADD.S
localparam opcode_t OPCODE_MSUB     = 7'b100_0111;  // FMSUB.S
localparam opcode_t OPCODE_NMSUB    = 7'b100_1011;  // FNMSUB.S
localparam opcode_t OPCODE_NMADD    = 7'b100_1111;  // FNMADD.S

// Reserved for future use:
// OPCODE_OP_FP fmt=01 (D extension, double precision) — future.

// ---------------------------------------------------------------------------
// 4. funct3 constants
// ---------------------------------------------------------------------------
// Named per instruction group. Where the same encoding appears in multiple
// groups (e.g. funct3=000 means ADD in OP but BEQ in BRANCH), the names
// are qualified with the group.

// --- OP / OP-IMM group ---
// funct3 selects the operation; funct7[5] distinguishes SUB from ADD and
// SRAI from SRLI within the OP encoding.
localparam funct3_t FUNCT3_ADD_SUB = 3'b000;  // ADD/ADDI (funct7=0) or SUB (funct7[5]=1)
localparam funct3_t FUNCT3_SLL     = 3'b001;  // SLL / SLLI
localparam funct3_t FUNCT3_SLT     = 3'b010;  // SLT / SLTI
localparam funct3_t FUNCT3_SLTU    = 3'b011;  // SLTU / SLTIU
localparam funct3_t FUNCT3_XOR     = 3'b100;  // XOR / XORI
localparam funct3_t FUNCT3_SRL_SRA = 3'b101;  // SRL/SRLI (funct7=0) or SRA/SRAI (funct7[5]=1)
localparam funct3_t FUNCT3_OR      = 3'b110;  // OR / ORI
localparam funct3_t FUNCT3_AND     = 3'b111;  // AND / ANDI

// --- BRANCH group ---
localparam funct3_t FUNCT3_BEQ     = 3'b000;
localparam funct3_t FUNCT3_BNE     = 3'b001;
localparam funct3_t FUNCT3_BLT     = 3'b100;
localparam funct3_t FUNCT3_BGE     = 3'b101;
localparam funct3_t FUNCT3_BLTU    = 3'b110;
localparam funct3_t FUNCT3_BGEU    = 3'b111;

// --- LOAD group ---
localparam funct3_t FUNCT3_LB      = 3'b000;
localparam funct3_t FUNCT3_LH      = 3'b001;
localparam funct3_t FUNCT3_LW      = 3'b010;
localparam funct3_t FUNCT3_LBU     = 3'b100;
localparam funct3_t FUNCT3_LHU     = 3'b101;

// --- STORE group ---
localparam funct3_t FUNCT3_SB      = 3'b000;
localparam funct3_t FUNCT3_SH      = 3'b001;
localparam funct3_t FUNCT3_SW      = 3'b010;

// --- RV32M multiply/divide group (funct7 = FUNCT7_MEXT, same opcode as OP) ---
// funct3 values differ from OP-group names, so use M_ prefix to avoid collision.
localparam funct3_t FUNCT3_M_MUL    = 3'b000;  // MUL    rd = (rs1*rs2)[31:0]
localparam funct3_t FUNCT3_M_MULH   = 3'b001;  // MULH   rd = signed(rs1)*signed(rs2) >> 32
localparam funct3_t FUNCT3_M_MULHSU = 3'b010;  // MULHSU rd = signed(rs1)*unsigned(rs2) >> 32
localparam funct3_t FUNCT3_M_MULHU  = 3'b011;  // MULHU  rd = unsigned(rs1)*unsigned(rs2) >> 32
localparam funct3_t FUNCT3_M_DIV    = 3'b100;  // DIV    rd = signed(rs1)/signed(rs2)
localparam funct3_t FUNCT3_M_DIVU   = 3'b101;  // DIVU   rd = unsigned(rs1)/unsigned(rs2)
localparam funct3_t FUNCT3_M_REM    = 3'b110;  // REM    rd = signed(rs1)%signed(rs2)
localparam funct3_t FUNCT3_M_REMU   = 3'b111;  // REMU   rd = unsigned(rs1)%unsigned(rs2)

// --- XFlux custom-0 group (OPCODE_CUSTOM_0, funct7 = FUNCT7_NORMAL) ---
localparam funct3_t FUNCT3_XLIDX = 3'b000;  // XLIDX rd,rs1,rs2  rd = MEM[rs1 + rs2<<2]
localparam funct3_t FUNCT3_XABS  = 3'b001;  // XABS  rd,rs1      rd = |rs1|
localparam funct3_t FUNCT3_XMIN  = 3'b010;  // XMIN  rd,rs1,rs2  rd = signed_min(rs1,rs2)
localparam funct3_t FUNCT3_XMAX  = 3'b011;  // XMAX  rd,rs1,rs2  rd = signed_max(rs1,rs2)
localparam funct3_t FUNCT3_XCLZ  = 3'b100;  // XCLZ  rd,rs1      rd = count_leading_zeros(rs1)
// FUNCT3_XMACC = 3'b101 reserved: rd=rd+rs1*rs2 — pending 3-operand read port

// --- JALR ---
localparam funct3_t FUNCT3_JALR    = 3'b000;

// --- SYSTEM group ---
localparam funct3_t FUNCT3_PRIV    = 3'b000;  // ECALL / EBREAK (funct7+rs2 distinguish)

// ---------------------------------------------------------------------------
// 5. funct7 constants
// ---------------------------------------------------------------------------

// Standard (non-alternate) encoding: ADD, SLL, SRL, SLT, SLTU, XOR, OR, AND.
localparam funct7_t FUNCT7_NORMAL  = 7'b000_0000;

// Alternate: SUB (funct3=000 OP), SRA / SRAI (funct3=101).
// Bit 5 is set; other bits remain zero in the base RV32I M-extension split.
localparam funct7_t FUNCT7_ALT     = 7'b010_0000;

// M-extension (multiply/divide). Reserved until RV32M milestone.
localparam funct7_t FUNCT7_MEXT    = 7'b000_0001;

// Shift-immediate encoding: only funct7 bits are used to distinguish SRLI / SRAI.
// The shift amount is in instr[24:20].
localparam funct7_t FUNCT7_SRLI    = 7'b000_0000;  // same as FUNCT7_NORMAL
localparam funct7_t FUNCT7_SRAI    = 7'b010_0000;  // same as FUNCT7_ALT

// ECALL / EBREAK distinguished by rs2 field, not funct7.
// Provided here for completeness; decoder checks instr[31:20] directly.
localparam logic [11:0] FUNCT12_ECALL  = 12'b0000_0000_0000;
localparam logic [11:0] FUNCT12_EBREAK = 12'b0000_0000_0001;
localparam logic [11:0] FUNCT12_MRET   = 12'b0011_0000_0010;
localparam logic [11:0] FUNCT12_WFI    = 12'b0001_0000_0101;

// ---------------------------------------------------------------------------
// 5b. RV32F floating-point encoding fields
// ---------------------------------------------------------------------------
// OP-FP (opcode 1010011) selects the operation from funct7 = instr[31:25].
// For single precision the low two bits (fmt) are 00; the top five bits pick
// the operation family. FCVT/FMV/FCLASS/FSGNJ/FMIN/FCMP additionally use rs2
// (instr[24:20]) as a sub-selector and funct3 (instr[14:12]) for the mode.
//
// Naming: FP7_* are the 7-bit funct7 values; FP2_* are the rs2 sub-selectors
// used by the single-operand / conversion instructions.

// funct7 values (single precision, fmt=00)
localparam funct7_t FP7_FADD    = 7'b000_0000;  // FADD.S
localparam funct7_t FP7_FSUB    = 7'b000_0100;  // FSUB.S
localparam funct7_t FP7_FMUL    = 7'b000_1000;  // FMUL.S
localparam funct7_t FP7_FDIV    = 7'b000_1100;  // FDIV.S
localparam funct7_t FP7_FSQRT   = 7'b010_1100;  // FSQRT.S   (rs2 = 00000)
localparam funct7_t FP7_FSGNJ   = 7'b001_0000;  // FSGNJ[N/X].S (funct3 selects)
localparam funct7_t FP7_FMINMAX = 7'b001_0100;  // FMIN/FMAX.S  (funct3 selects)
localparam funct7_t FP7_FCMP    = 7'b101_0000;  // FEQ/FLT/FLE.S (funct3 selects)
localparam funct7_t FP7_FCVT_W  = 7'b110_0000;  // FCVT.W.S / FCVT.WU.S (rs2 selects)
localparam funct7_t FP7_FCVT_S  = 7'b110_1000;  // FCVT.S.W / FCVT.S.WU (rs2 selects)
localparam funct7_t FP7_FMV_X_W = 7'b111_0000;  // FMV.X.W (funct3=000) / FCLASS.S (funct3=001)
localparam funct7_t FP7_FMV_W_X = 7'b111_1000;  // FMV.W.X (funct3=000)

// rs2-field sub-selectors for the conversion instructions
localparam logic [4:0] FP2_W  = 5'b00000;  // signed 32-bit int   (FCVT.W.S / FCVT.S.W)
localparam logic [4:0] FP2_WU = 5'b00001;  // unsigned 32-bit int  (FCVT.WU.S / FCVT.S.WU)

// funct3 sub-selectors for sign-inject, min/max, compare
localparam funct3_t FP3_SGNJ  = 3'b000;  // FSGNJ.S
localparam funct3_t FP3_SGNJN = 3'b001;  // FSGNJN.S
localparam funct3_t FP3_SGNJX = 3'b010;  // FSGNJX.S
localparam funct3_t FP3_MIN   = 3'b000;  // FMIN.S
localparam funct3_t FP3_MAX   = 3'b001;  // FMAX.S
localparam funct3_t FP3_FLE   = 3'b000;  // FLE.S
localparam funct3_t FP3_FLT   = 3'b001;  // FLT.S
localparam funct3_t FP3_FEQ   = 3'b010;  // FEQ.S
localparam funct3_t FP3_FMV   = 3'b000;  // FMV.X.W / FMV.W.X
localparam funct3_t FP3_FCLASS = 3'b001; // FCLASS.S

// FLW/FSW width selector (funct3 = 010, single precision word)
localparam funct3_t FP3_LSW   = 3'b010;  // FLW / FSW

// IEEE-754 rounding modes (instr[14:12] for OP-FP arithmetic; frm field of fcsr).
// DYN means "use fcsr.frm"; 101/110 are reserved (illegal-instruction).
typedef enum logic [2:0] {
    FRM_RNE = 3'b000,  // round to nearest, ties to even
    FRM_RTZ = 3'b001,  // round toward zero
    FRM_RDN = 3'b010,  // round down   (toward -inf)
    FRM_RUP = 3'b011,  // round up     (toward +inf)
    FRM_RMM = 3'b100,  // round to nearest, ties to max magnitude
    FRM_DYN = 3'b111   // use dynamic rounding mode from fcsr.frm
} frm_e;

// IEEE-754 exception flag bit positions within fflags / fcsr[4:0].
localparam int unsigned FFLAG_NX = 0;  // inexact
localparam int unsigned FFLAG_UF = 1;  // underflow
localparam int unsigned FFLAG_OF = 2;  // overflow
localparam int unsigned FFLAG_DZ = 3;  // divide by zero
localparam int unsigned FFLAG_NV = 4;  // invalid operation
typedef logic [4:0] fflags_t;

// Canonical single-precision quiet NaN produced by any invalid FP result.
localparam logic [31:0] FP_CANONICAL_QNAN = 32'h7FC0_0000;

// ---------------------------------------------------------------------------
// 6. Instruction format enum
// ---------------------------------------------------------------------------
// Used by the immediate generator and decoder to select the immediate
// extraction pattern. Not stored in decoded_instr_t (the immediate is
// already extracted before the struct is written).

typedef enum logic [2:0] {
    IFMT_R = 3'd0,   // opcode rd funct3 rs1 rs2 funct7
    IFMT_I = 3'd1,   // opcode rd funct3 rs1 imm[11:0]
    IFMT_S = 3'd2,   // opcode imm[4:0] funct3 rs1 rs2 imm[11:5]
    IFMT_B = 3'd3,   // branch offset (scrambled bits)
    IFMT_U = 3'd4,   // opcode rd imm[31:12]
    IFMT_J = 3'd5    // jump offset (scrambled bits)
} instr_fmt_e;

// ---------------------------------------------------------------------------
// 7. ALU operation enum
// ---------------------------------------------------------------------------
// All operations the ALU module (rtl/execution/alu.sv) can perform.
// The decoder selects the operation; the ALU does not know about the ISA.

typedef enum logic [4:0] {
    // --- RV32I base integer ops ---
    ALU_ADD    = 5'd0,   // a + b                (ADD, ADDI, AUIPC, JALR addr, loads, stores)
    ALU_SUB    = 5'd1,   // a - b                (SUB)
    ALU_AND    = 5'd2,   // a & b                (AND, ANDI)
    ALU_OR     = 5'd3,   // a | b                (OR, ORI)
    ALU_XOR    = 5'd4,   // a ^ b                (XOR, XORI)
    ALU_SLL    = 5'd5,   // a << b[4:0]          (SLL, SLLI)
    ALU_SRL    = 5'd6,   // a >> b[4:0]          (SRL, SRLI — zero-fill)
    ALU_SRA    = 5'd7,   // a >>> b[4:0] signed  (SRA, SRAI — sign-fill)
    ALU_SLT    = 5'd8,   // (signed a < signed b) ? 1 : 0  (SLT, SLTI)
    ALU_SLTU   = 5'd9,   // (a < b) ? 1 : 0     (SLTU, SLTIU — unsigned)
    ALU_COPY_B = 5'd10,  // result = b           (LUI: immediate passed through)
    // --- RV32M multiply/divide (handled by mul_div_unit, not alu.sv) ---
    ALU_MUL    = 5'd11,  // (signed rs1 * signed rs2)[31:0]
    ALU_MULH   = 5'd12,  // (signed rs1 * signed rs2)[63:32]
    ALU_MULHU  = 5'd13,  // (unsigned rs1 * unsigned rs2)[63:32]
    ALU_MULHSU = 5'd14,  // (signed rs1 * unsigned rs2)[63:32]
    ALU_DIV    = 5'd15,  // signed division quotient
    ALU_DIVU   = 5'd16,  // unsigned division quotient
    ALU_REM    = 5'd17,  // signed division remainder
    ALU_REMU   = 5'd18,  // unsigned division remainder
    // --- XFlux custom ops (handled by alu.sv) ---
    ALU_XLIDX_ADDR = 5'd19,  // a + (b << 2)   address for indexed load
    ALU_XABS       = 5'd20,  // |a|            absolute value
    ALU_XMIN       = 5'd21,  // signed_min(a,b)
    ALU_XMAX       = 5'd22,  // signed_max(a,b)
    ALU_XCLZ       = 5'd23   // count_leading_zeros(a)
} alu_op_e;

// ---------------------------------------------------------------------------
// 7b. Floating-point operation enum (RV32F)
// ---------------------------------------------------------------------------
// All operations the FPU (rtl/execution/fpu.sv) can perform. The decoder maps
// the OP-FP / MADD encodings onto this enum; the FPU does not parse the ISA.
//
// Latency classes (see fpu.sv):
//   Multi-cycle (freeze pipeline via fpu_stall): FADD..FNMADD, FDIV, FSQRT.
//   Single-cycle combinational:                  FSGNJ..FCLASS.
// FLW/FSW are NOT here: they reuse the integer load/store path with a
// writes_frd / uses_fs2 flag (the value simply routes to the FP register file).
//
// Result destination:
//   FP register  (writes_frd): FADD..FNMADD, FSGNJ*, FMIN/FMAX, FCVT_S_*, FMV_W_X.
//   Int register (writes_rd):  FEQ/FLT/FLE, FCVT_W_*, FMV_X_W, FCLASS.
typedef enum logic [4:0] {
    FPU_NONE    = 5'd0,   // not an FP compute op (FLW/FSW or non-FP instruction)
    // --- multi-cycle arithmetic ---
    FPU_ADD     = 5'd1,   // a + b
    FPU_SUB     = 5'd2,   // a - b
    FPU_MUL     = 5'd3,   // a * b
    FPU_DIV     = 5'd4,   // a / b
    FPU_SQRT    = 5'd5,   // sqrt(a)
    FPU_MADD    = 5'd6,   //  (a * b) + c
    FPU_MSUB    = 5'd7,   //  (a * b) - c
    FPU_NMSUB   = 5'd8,   // -(a * b) + c
    FPU_NMADD   = 5'd9,   // -(a * b) - c
    // --- single-cycle: sign-inject ---
    FPU_SGNJ    = 5'd10,  // {sign(b),     a[30:0]}
    FPU_SGNJN   = 5'd11,  // {~sign(b),    a[30:0]}
    FPU_SGNJX   = 5'd12,  // {sign(a)^sign(b), a[30:0]}
    // --- single-cycle: min / max ---
    FPU_MIN     = 5'd13,  // IEEE minNum(a,b)
    FPU_MAX     = 5'd14,  // IEEE maxNum(a,b)
    // --- single-cycle: compare (result to int reg) ---
    FPU_EQ      = 5'd15,  // (a == b) ? 1 : 0
    FPU_LT      = 5'd16,  // (a <  b) ? 1 : 0
    FPU_LE      = 5'd17,  // (a <= b) ? 1 : 0
    // --- single-cycle: conversions ---
    FPU_CVT_W_S  = 5'd18, // float -> signed int32     (to int reg)
    FPU_CVT_WU_S = 5'd19, // float -> unsigned int32    (to int reg)
    FPU_CVT_S_W  = 5'd20, // signed int32 -> float      (to fp reg)
    FPU_CVT_S_WU = 5'd21, // unsigned int32 -> float     (to fp reg)
    // --- single-cycle: bit moves ---
    FPU_MV_X_W  = 5'd22,  // raw bits float -> int reg
    FPU_MV_W_X  = 5'd23,  // raw bits int -> fp reg
    // --- single-cycle: classify ---
    FPU_CLASS   = 5'd24   // 10-bit class mask (to int reg)
} fpu_op_e;

// ---------------------------------------------------------------------------
// 8. Branch comparison enum
// ---------------------------------------------------------------------------
// The branch unit (rtl/execution/branch_unit.sv) uses this to decide whether
// a conditional branch is taken. JAL/JALR always redirect; they use BRANCH_NONE
// in this field and are identified by op_class or is_jump.

typedef enum logic [2:0] {
    BRANCH_NONE = 3'd0,   // not a conditional branch (or branch unit not needed)
    BRANCH_EQ   = 3'd1,   // BEQ:  take if rs1 == rs2
    BRANCH_NE   = 3'd2,   // BNE:  take if rs1 != rs2
    BRANCH_LT   = 3'd3,   // BLT:  take if signed(rs1) < signed(rs2)
    BRANCH_GE   = 3'd4,   // BGE:  take if signed(rs1) >= signed(rs2)
    BRANCH_LTU  = 3'd5,   // BLTU: take if rs1 < rs2  (unsigned)
    BRANCH_GEU  = 3'd6    // BGEU: take if rs1 >= rs2 (unsigned)
} branch_op_e;

// ---------------------------------------------------------------------------
// 9. Memory operation enum
// ---------------------------------------------------------------------------
// Encodes the width and signedness of a load or store.
// MEM_NONE indicates no memory operation this instruction.

typedef enum logic [3:0] {
    MEM_NONE = 4'd0,
    MEM_LB   = 4'd1,   // load byte, sign-extended
    MEM_LBU  = 4'd2,   // load byte, zero-extended
    MEM_LH   = 4'd3,   // load halfword, sign-extended
    MEM_LHU  = 4'd4,   // load halfword, zero-extended
    MEM_LW   = 4'd5,   // load word
    MEM_SB   = 4'd6,   // store byte
    MEM_SH   = 4'd7,   // store halfword
    MEM_SW   = 4'd8    // store word
} mem_op_e;

// ---------------------------------------------------------------------------
// 10. Writeback source enum
// ---------------------------------------------------------------------------
// Selects which result is written back to the architectural register file.
// 3-bit enum; WB_CSR added for CSR read result (CSRRW/CSRRS/CSRRC forms).

typedef enum logic [2:0] {
    WB_NONE = 3'd0,   // no register writeback (stores, branches, exceptions)
    WB_ALU  = 3'd1,   // ALU result (arithmetic, logic, LUI, AUIPC)
    WB_MEM  = 3'd2,   // memory load result (sign/zero extended in MEM or WB stage)
    WB_PC4  = 3'd3,   // PC+4 (link register for JAL, JALR)
    WB_CSR  = 3'd4,   // CSR read result (old CSR value before write)
    WB_FPU  = 3'd5    // FPU result for an FP→int op (FEQ/FLT/FLE, FCVT.W[U].S,
                      // FMV.X.W, FCLASS) written to the integer register file.
                      // FP→FP results reach the FP register file on a separate
                      // write port (writes_frd), not through this mux.
} wb_src_e;

// ---------------------------------------------------------------------------
// 11. Operation class enum
// ---------------------------------------------------------------------------
// High-level classification of an instruction's execution requirement.
// Used for issue dispatch and, later, scoreboard tracking.
// op_class and the is_* flags in decoded_instr_t are redundant by design:
//   op_class is used for enum-based dispatch (case statements, scheduling);
//   is_* flags are used for direct boolean hazard checks.

typedef enum logic [3:0] {
    OPCLASS_ALU      = 4'd0,   // integer arithmetic and logic (ADD, AND, LUI, AUIPC, …)
    OPCLASS_BRANCH   = 4'd1,   // conditional branches (BEQ, BNE, …)
    OPCLASS_JUMP     = 4'd2,   // unconditional jumps (JAL, JALR)
    OPCLASS_LOAD     = 4'd3,   // memory loads (LB, LH, LW, …)
    OPCLASS_STORE    = 4'd4,   // memory stores (SB, SH, SW)
    OPCLASS_SYSTEM   = 4'd5,   // privileged / system (ECALL, EBREAK, fence)
    OPCLASS_LONG_LAT = 4'd6,   // multi-cycle integer: MUL, DIV
    OPCLASS_CUSTOM   = 4'd7,   // XFlux custom operations
    OPCLASS_FP       = 4'd8    // RV32F floating-point (compute; FLW/FSW use LOAD/STORE)
} op_class_e;

// ---------------------------------------------------------------------------
// 12. CSR operation enum
// ---------------------------------------------------------------------------
// Encodes which CSR read-modify-write operation a SYSTEM instruction performs.
// Matches funct3[1:0] of the CSR instruction group directly:
//   CSRRW / CSRRWI → CSR_WRITE (2'b01)  — new value = src (imm or rs1)
//   CSRRS / CSRRSI → CSR_SET   (2'b10)  — new value = old | src
//   CSRRC / CSRRCI → CSR_CLR   (2'b11)  — new value = old & ~src
//   (no CSR operation)        → CSR_NOP  (2'b00)
// The immediate variants (CSRRWI/CSRRSI/CSRRCI) use the same operation enum;
// the source data path selects zero-extended rs1-field (4:0) as the operand.

typedef enum logic [1:0] {
    CSR_NOP   = 2'b00,
    CSR_WRITE = 2'b01,
    CSR_SET   = 2'b10,
    CSR_CLR   = 2'b11
} csr_op_e;

// ---------------------------------------------------------------------------
// 13. Decoded instruction record
// ---------------------------------------------------------------------------
// Produced by the instruction decoder in the ID stage and carried forward
// through the pipeline in the id_ex_payload_t (and partially in later stages).
//
// All fields have an explicit packed type so the struct can be used in
// pipeline payload packed structs, logged as a bit vector, and compared
// against the Python reference model.
//
// Invariants the decoder must maintain:
//   legal=1  implies all fields are valid and consistent.
//   legal=0  implies exception.valid=1 with cause=EXC_ILLEGAL_INSTRUCTION.
//   uses_rs1 and uses_rs2 must be set only when the register value is
//   actually required for correct execution (not merely encoded in the field).
//   writes_rd must be 0 for branches, stores, and illegal instructions.
//   is_branch, is_jump, is_load, is_store are mutually exclusive.
//
// See the contract (Section 10) for the full semantics of each field.

typedef struct packed {
    // ---- validity and classification ----
    logic         legal;          // 1 = instruction decoded successfully
    op_class_e    op_class;       // high-level execution category
    // ---- per-unit operation selects ----
    alu_op_e      alu_op;         // ALU operation (valid when op_class is ALU, LOAD, STORE, JUMP)
    branch_op_e   branch_op;      // branch comparison (valid when is_branch)
    mem_op_e      mem_op;         // memory width/sign (valid when is_load or is_store)
    wb_src_e      wb_src;         // writeback data source (valid when writes_rd)
    // ---- register indices ----
    reg_idx_t     rs1;            // source register 1 index (meaningful when uses_rs1)
    reg_idx_t     rs2;            // source register 2 index (meaningful when uses_rs2)
    reg_idx_t     rd;             // destination register index (meaningful when writes_rd)
    // ---- operand-use flags ----
    // Critical for hazard detection: only check forwarding when the operand is used.
    logic         uses_rs1;       // 1 = rs1 is a required source operand
    logic         uses_rs2;       // 1 = rs2 is a required source operand
    logic         writes_rd;      // 1 = rd receives a writeback this instruction
    // ---- sign-extended immediate ----
    word_t        imm;            // extracted and sign-extended immediate value
    // ---- instruction class flags ----
    // Redundant with op_class but provided for direct boolean use in hazard logic.
    logic         is_branch;      // conditional branch
    logic         is_jump;        // unconditional jump (JAL or JALR)
    logic         is_load;        // memory load
    logic         is_store;       // memory store
    logic         is_csr;         // CSR read-modify-write (CSRRW/RS/RC and immediate forms)
    logic         is_mret;        // MRET (trap return — redirects PC to mepc)
    logic         is_long_latency;// multi-cycle integer unit required (MUL/DIV → mul_div_unit)
    logic         is_custom;      // XFlux custom encoding
    // ---- RV32F floating-point metadata ----
    // Populated only when is_fp=1 (OP-FP / MADD family) or for FLW/FSW.
    //   fpu_op    selects the FPU operation (FPU_NONE for FLW/FSW).
    //   uses_fs1/2/3 mark FP register sources (indices reuse rs1/rs2 fields and
    //             the new fs3 field; fs1=instr[19:15], fs2=instr[24:20],
    //             fs3=instr[31:27]).  Kept distinct from uses_rs1/uses_rs2 so the
    //             integer and FP forwarding paths never cross-match (different
    //             register files sharing the same 5-bit index space).
    //   writes_frd  1 = result is written to the FP register file (index = rd).
    //   frm       rounding mode (instr[14:12]; FRM_DYN means use fcsr.frm).
    logic         is_fp;          // FP compute instruction (OP-FP / MADD family)
    fpu_op_e      fpu_op;         // FPU operation select
    reg_idx_t     fs3;            // third FP source (instr[31:27], FMADD family)
    logic         uses_fs1;       // 1 = fs1 (rs1 field) is an FP source operand
    logic         uses_fs2;       // 1 = fs2 (rs2 field) is an FP source operand
    logic         uses_fs3;       // 1 = fs3 is an FP source operand (FMADD family)
    logic         writes_frd;     // 1 = rd receives an FP-register writeback
    frm_e         frm;            // IEEE rounding mode (FRM_DYN → fcsr.frm)
    // ---- CSR access metadata ----
    // Populated only when is_csr=1.  The execute stage reads csr_addr, the WB
    // stage uses csr_op and either rs1_data (uses_rs1=1) or imm[4:0] (uses_rs1=0).
    logic [11:0]  csr_addr;       // 12-bit CSR address from instr[31:20]
    csr_op_e      csr_op;         // WRITE / SET / CLR / NOP
    // ---- decode-time exception ----
    // An illegal instruction sets legal=0 and exception.valid=1.
    // The pipeline must propagate this and suppress all side effects.
    exception_meta_t exception;   // exception detected at decode time
} decoded_instr_t;

// Packed width reference (for testbench verification):
//   legal(1) + op_class(4) + alu_op(5) + branch_op(3) + mem_op(4) + wb_src(3)
//   + rs1(5) + rs2(5) + rd(5)
//   + uses_rs1(1) + uses_rs2(1) + writes_rd(1)
//   + imm(32)
//   + is_branch(1) + is_jump(1) + is_load(1) + is_store(1)
//   + is_csr(1) + is_mret(1)
//   + is_long_latency(1) + is_custom(1)
//   + is_fp(1) + fpu_op(5) + fs3(5) + uses_fs1(1) + uses_fs2(1) + uses_fs3(1)
//   + writes_frd(1) + frm(3)
//   + csr_addr(12) + csr_op(2)
//   + exception(37)
//   Base integer fields (unchanged) = 127 bits with op_class now 4 bits.
//   FP fields add 1+5+5+1+1+1+1+3 = 18 bits.  Total = 146 bits.
//   Use $bits(decoded_instr_t) in testbenches rather than a hard-coded width.

// Standard M-mode CSR addresses
localparam logic [11:0] CSR_MSTATUS   = 12'h300;
localparam logic [11:0] CSR_MISA      = 12'h301;
localparam logic [11:0] CSR_MCOUNTEREN = 12'h306;
localparam logic [11:0] CSR_MCOUNTINHIBIT = 12'h320;
localparam logic [11:0] CSR_MIE       = 12'h304;
localparam logic [11:0] CSR_MTVEC     = 12'h305;
localparam logic [11:0] CSR_MSCRATCH  = 12'h340;
localparam logic [11:0] CSR_MEPC      = 12'h341;
localparam logic [11:0] CSR_MCAUSE    = 12'h342;
localparam logic [11:0] CSR_MTVAL     = 12'h343;
localparam logic [11:0] CSR_MIP       = 12'h344;
localparam logic [11:0] CSR_MCYCLE    = 12'hB00;
localparam logic [11:0] CSR_MINSTRET  = 12'hB02;
localparam logic [11:0] CSR_MCYCLEH   = 12'hB80;
localparam logic [11:0] CSR_MINSTRETH = 12'hB82;
localparam logic [11:0] CSR_MHARTID   = 12'hF14;  // read-only, returns 0
localparam logic [11:0] CSR_MVENDORID = 12'hF11;  // read-only, 0 = non-commercial
localparam logic [11:0] CSR_MARCHID   = 12'hF12;  // read-only, 0 = not registered
localparam logic [11:0] CSR_MIMPID    = 12'hF13;  // read-only, implementation date
localparam logic [11:0] CSR_MCONFIGPTR = 12'hF15; // read-only, 0 = no config structure

// Custom machine read-only CSRs (0xFC0+): cache hierarchy performance
// counters, wired from the SoC-level caches (0 in cacheless configs).
localparam logic [11:0] CSR_DCHITS   = 12'hFC0;  // D$ read hits
localparam logic [11:0] CSR_DCMISSES = 12'hFC1;  // D$ read misses
localparam logic [11:0] CSR_ICHITS   = 12'hFC2;  // I$ hit-lookups
localparam logic [11:0] CSR_ICMISSES = 12'hFC3;  // I$ misses

// Custom machine read/write CSR: cache maintenance. Writing any value
// triggers a full write-back + invalidate of the data-side hierarchy
// (D$ now; L2 chained in when it joins the SoC). Read returns bit 0 =
// maintenance walk still busy — software polls it before relying on
// memory-visible state (e.g. before signalling the PS).
localparam logic [11:0] CSR_CACHEOP = 12'h7C0;
// Zicntr user-mode read-only shadows
localparam logic [11:0] CSR_CYCLE     = 12'hC00;  // shadow of mcycle
localparam logic [11:0] CSR_TIME      = 12'hC01;  // CLINT mtime (low)
localparam logic [11:0] CSR_INSTRET   = 12'hC02;  // shadow of minstret
localparam logic [11:0] CSR_CYCLEH    = 12'hC80;  // shadow of mcycleh
localparam logic [11:0] CSR_TIMEH     = 12'hC81;  // CLINT mtime (high)
localparam logic [11:0] CSR_INSTRETH  = 12'hC82;  // shadow of minstreth
// RV32F user-mode floating-point control/status registers
localparam logic [11:0] CSR_FFLAGS    = 12'h001;  // fcsr[4:0]  accrued exception flags
localparam logic [11:0] CSR_FRM       = 12'h002;  // fcsr[7:5]  dynamic rounding mode
localparam logic [11:0] CSR_FCSR      = 12'h003;  // {frm, fflags}

// ---------------------------------------------------------------------------
// CSR existence / writability — used by the decoder to raise
// illegal-instruction on accesses to unimplemented CSRs and on writes to
// read-only CSRs (RISC-V privileged spec 2.1).
// ---------------------------------------------------------------------------
function automatic logic csr_addr_valid(input logic [11:0] a);
    case (a)
        CSR_MSTATUS, CSR_MISA, CSR_MIE, CSR_MTVEC, CSR_MCOUNTEREN,
        CSR_MCOUNTINHIBIT,
        CSR_MSCRATCH, CSR_MEPC, CSR_MCAUSE, CSR_MTVAL, CSR_MIP,
        CSR_MCYCLE, CSR_MINSTRET, CSR_MCYCLEH, CSR_MINSTRETH,
        CSR_CYCLE, CSR_TIME, CSR_INSTRET,
        CSR_CYCLEH, CSR_TIMEH, CSR_INSTRETH,
        CSR_FFLAGS, CSR_FRM, CSR_FCSR,
        CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID, CSR_MHARTID, CSR_MCONFIGPTR,
        CSR_DCHITS, CSR_DCMISSES, CSR_ICHITS, CSR_ICMISSES,
        CSR_CACHEOP:
            return 1'b1;
        default:
            return 1'b0;
    endcase
endfunction

// Read-only CSRs: address bits [11:10] = 2'b11 per the spec encoding
// (covers 0xCxx user counters and 0xFxx machine-information registers).
function automatic logic csr_addr_readonly(input logic [11:0] a);
    return (a[11:10] == 2'b11);
endfunction

endpackage : rv32_isa_pkg

`default_nettype wire
