// rtl/common/fluxcore_pkg.sv
//
// FluxCore shared architectural package.
//
// Purpose:
//   Defines all stable, shared types that cross module boundaries throughout
//   the FluxCore pipeline. Every module in the design imports this package.
//   This is the authoritative source of architectural constants and types.
//
// Scope discipline:
//   This package contains only types that are genuinely shared and stable.
//   Stage-payload structs, ISA enums, and cache types are defined elsewhere
//   once their dependencies are established.
//   Do not add types here that belong to a single module or a future feature.
//
// Naming conventions:
//   Types:  *_t (e.g. word_t, addr_t)
//   Enums:  *_e (e.g. exc_cause_e)
//   Parameters: UPPER_CASE
//
// Compilation:
//   This package must compile independently. No other package is imported.
//
// Reset convention:
//   Synchronous, active-high, named rst. This is the convention across all
//   FluxCore RTL; do not use asynchronous or active-low resets in core logic.
//
// Endianness:
//   Little-endian. Byte offset 0 is bits [7:0] of a 32-bit word.

`default_nettype none

package fluxcore_pkg;

// ---------------------------------------------------------------------------
// 1. Architectural constants
// ---------------------------------------------------------------------------
// These values are fixed for the lifetime of the project.
// Changing them would alter the ISA contract and require full re-verification.

// Data-path width. Fixes the ISA as RV32.
localparam int unsigned XLEN             = 32;

// Instruction word width. All FluxCore instructions are 32 bits (no compressed).
localparam int unsigned INSTR_W          = 32;

// Integer architectural register count. The RISC-V GPR file: x0 through x31.
localparam int unsigned REG_COUNT        = 32;

// Bits required to index REG_COUNT registers. $clog2(32) = 5.
localparam int unsigned REG_IDX_W        = 5;

// Thread contexts in the initial single-threaded implementation.
localparam int unsigned BASELINE_THREADS = 1;

// Thread contexts in the planned fine-grained multithreaded design.
// Hardware threading adds four interleaved contexts to hide memory latency.
localparam int unsigned PLANNED_THREADS  = 4;

// Bits required to represent a thread ID for PLANNED_THREADS contexts.
// $clog2(4) = 2. Must satisfy (2**THREAD_ID_W) >= PLANNED_THREADS.
localparam int unsigned THREAD_ID_W      = 2;

// Per-thread redirect epoch counter width.
// Each thread maintains an epoch counter incremented on every branch redirect.
// Fetched instructions carry the epoch at issue time; responses or pipeline
// payloads whose epoch does not match the current epoch are stale and discarded.
// 4 bits gives 16 distinct epochs per thread before wrapping, which is more
// than enough to distinguish stale responses under any realistic outstanding-
// request depth.
localparam int unsigned EPOCH_W          = 4;

// Memory transaction identifier width.
// Used to tag memory requests so responses can be matched when they return
// out-of-order in later nonblocking memory milestones.
// 4 bits supports 16 simultaneously outstanding transactions per thread.
localparam int unsigned TXID_W           = 4;

// Exception cause field width (see exc_cause_e below).
localparam int unsigned EXC_CAUSE_W      = 4;

// ---------------------------------------------------------------------------
// 2. Base scalar types
// ---------------------------------------------------------------------------
// All widths are expressed in terms of the constants above so they track
// cleanly if any constant changes during early design iteration.

// 32-bit data word. Used for ALU operands, register values, and memory data.
typedef logic [XLEN-1:0]        word_t;

// 32-bit byte address. Same width as word_t for RV32 but semantically distinct.
typedef logic [XLEN-1:0]        addr_t;

// 32-bit instruction encoding. Holds a raw 32-bit instruction word.
typedef logic [INSTR_W-1:0]     instr_t;

// 5-bit register index. Selects one of the 32 architectural integer registers.
// x0 is index 0 and always reads as zero; writes to index 0 are ignored.
typedef logic [REG_IDX_W-1:0]   reg_idx_t;

// Thread context identifier. In the single-thread baseline this is always 0.
// Carried through every pipeline payload so multithreading can be added
// without changing the payload wire types.
typedef logic [THREAD_ID_W-1:0] thread_id_t;

// Per-thread redirect epoch. Incremented each time a thread's fetch PC is
// redirected (branch taken, JAL, JALR). Payloads and responses whose epoch
// differs from the thread's current epoch are discarded as wrong-path.
typedef logic [EPOCH_W-1:0]     epoch_t;

// Memory transaction identifier. Tags an issued memory request; the
// corresponding response carries the same ID. Used to match responses when
// multiple transactions may be outstanding in nonblocking memory milestones.
typedef logic [TXID_W-1:0]      txid_t;

// ---------------------------------------------------------------------------
// 3. Exception cause encoding
// ---------------------------------------------------------------------------
// Values match RISC-V privileged specification Table 3.6 (synchronous
// exception causes for mcause[30:0]). Using standard values here means the
// exception cause can be written directly to mcause when a trap is taken,
// without any remapping.
//
// Only causes relevant to the initial integer pipeline are defined.
// Additional causes (environment calls, page faults) will be added when
// the privileged architecture milestone begins.

typedef enum logic [EXC_CAUSE_W-1:0] {
    EXC_INSTR_ADDR_MISALIGNED  = 4'd0,   // fetch PC not 4-byte aligned
    EXC_INSTR_ACCESS_FAULT     = 4'd1,   // instruction memory access error
    EXC_ILLEGAL_INSTRUCTION    = 4'd2,   // unrecognized or reserved encoding
    EXC_BREAKPOINT             = 4'd3,   // EBREAK instruction
    EXC_LOAD_ADDR_MISALIGNED   = 4'd4,   // load effective address misaligned
    EXC_LOAD_ACCESS_FAULT      = 4'd5,   // load memory access error
    EXC_STORE_ADDR_MISALIGNED  = 4'd6,   // store effective address misaligned
    EXC_STORE_ACCESS_FAULT     = 4'd7,   // store memory access error
    EXC_ECALL_U                = 4'd8,   // ECALL from U-mode
    EXC_ECALL_M                = 4'd11   // ECALL from M-mode
} exc_cause_e;

// ---------------------------------------------------------------------------
// 4. Compound types
// ---------------------------------------------------------------------------

// Exception metadata carried through every pipeline stage.
// When valid is 0, the cause and tval fields are undefined.
// A stage that detects an exception sets valid=1 and propagates the metadata;
// later stages do not overwrite an already-valid exception.
// No architectural side effect occurs for a faulting instruction:
//   - register writeback is suppressed
//   - memory stores are suppressed
//   - retirement is not signalled as successful
typedef struct packed {
    logic       valid;   // 1 = exception is pending for this instruction
    logic       is_irq;  // 1 = asynchronous interrupt (mcause[31]); 0 = synchronous
    exc_cause_e cause;   // RISC-V exception cause (maps directly to mcause[30:0])
    word_t      tval;    // trap value: faulting address or illegal instruction word
} exception_meta_t;

// Interrupt cause codes (valid when exception_meta_t.is_irq = 1).
// Numerically these reuse the exc_cause_e encoding space; the is_irq bit
// (mcause[31]) disambiguates, exactly as in the RISC-V privileged spec.
localparam logic [EXC_CAUSE_W-1:0] IRQ_M_SOFT_CODE  = 4'd3;   // machine software interrupt
localparam logic [EXC_CAUSE_W-1:0] IRQ_M_TIMER_CODE = 4'd7;   // machine timer interrupt

// Retirement event record.
// Emitted by the WB stage for every architecturally committed instruction.
// Only instructions that complete without a pipeline flush, and without a
// pending exception that prevents commitment, generate a retirement event.
// Bubbles (valid=0 payloads) and flushed wrong-path instructions do not retire.
//
// This record is used for:
//   - Differential comparison against the Python architectural reference model.
//   - Performance counter inputs (instruction-retired counter).
//   - Debug and waveform annotation.
//
// Note: a cycle-counter field is not included in this baseline definition.
// Performance counters are a separate milestone; the field will be added then.
typedef struct packed {
    logic              valid;        // 1 = this is a valid retirement event
    word_t             pc;           // program counter of the retired instruction
    instr_t            instr;        // raw 32-bit instruction word (for trace/debug)
    logic              rd_wen;       // 1 = destination register was written
    reg_idx_t          rd_addr;      // destination register index (meaningful when rd_wen)
    word_t             rd_data;      // value written to destination (meaningful when rd_wen)
    logic              mem_valid;    // 1 = a memory operation was performed
    addr_t             mem_addr;     // effective byte address (meaningful when mem_valid)
    word_t             mem_wr_data;  // aligned store data (meaningful when mem_valid && mem_is_write)
    logic [XLEN/8-1:0] mem_wr_strb; // byte enables for store (meaningful when mem_valid && mem_is_write)
    logic              mem_is_write; // 1 = store, 0 = load
    thread_id_t        thread_id;    // issuing thread context (0 in single-thread baseline)
    exception_meta_t   exception;    // exception that terminated this instruction, if any
} retirement_event_t;

endpackage : fluxcore_pkg

`default_nettype wire
