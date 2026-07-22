// rtl/common/mem_if_pkg.sv
//
// FluxCore memory transaction interface — FROZEN CONTRACT.
//
// Purpose:
//   Defines the single request/response protocol that every memory-path module
//   speaks: caches, the SoC bus, the AXI adapter, the memory controller, and
//   every simulation memory model. Freezing this contract is what allows the
//   backend to be swapped (ideal model / configurable-latency model / BRAM /
//   AXI+DDR) without touching the modules above it.
//
//   This realizes the abstraction hierarchy in docs/interfaces/memory-interface-plan.md:
//
//       requester (L1 cache, memory controller client, ...)
//               |   mem_req_t  + valid/ready
//               v
//       responder (L2, BRAM adapter, AXI adapter, sim model, ...)
//               |   mem_rsp_t  + valid/ready
//               v
//
// Scope discipline:
//   This is deliberately the MINIMAL interface sufficient for a single-issue,
//   in-order core. It intentionally OMITS:
//     - thread_id      : FluxCore is single-threaded. fluxcore_pkg still declares
//                        thread_id_t / PLANNED_THREADS from an earlier design
//                        direction, but nothing in the RTL drives them. Adding a
//                        field no module can populate would be dead wire.
//     - gather/scatter : address-generation hooks anticipated by the plan doc for
//                        a machine FluxCore's architectural identity has ruled out.
//     - snoop/probe    : no coherence between masters. PS/PL coherence, when it
//                        lands, is handled by explicit maintenance ops or by the
//                        ACP port, not by a snoop channel here.
//   Do not add fields speculatively. Re-freezing this package means touching
//   every module in the memory path.
//
// Handshake:
//   Standard ready/valid. A transfer occurs on a rising edge where both valid
//   and ready are high. valid must not be withdrawn once asserted until the
//   transfer completes (no valid-before-ready retraction), and ready may be
//   asserted combinationally or registered. A responder must NOT wait for
//   valid before asserting ready (that deadlocks); a requester MAY wait for
//   ready before asserting valid only if it never depends on ready to compute
//   valid.
//
// Ordering guarantee:
//   Responses may return OUT OF ORDER with respect to requests. The id field is
//   the only thing that links a response to its request. A requester that cannot
//   tolerate reordering must issue at most one outstanding transaction.
//
//   Requests to the SAME address are NOT automatically ordered by the fabric.
//   A requester that needs write-then-read ordering to one address must either
//   wait for the write response or handle the hazard itself. The L1 caches do
//   the latter (store buffer forwarding, see P1.6).
//
// Burst encoding:
//   len follows the AXI AxLEN convention: len = (number of beats) - 1.
//   A single-word access is len = 0, which makes the common case the zero value.
//   Bursts are incrementing-address only (AXI INCR); no wrap, no fixed.
//   All beats of a burst share one id and are returned in ascending address
//   order; the final beat asserts rsp.last. Bursts exist so a cache line fill is
//   one transaction rather than N, which is what lets the AXI adapter (P3.2) emit
//   a true burst instead of reconstructing one from independent requests.
//
// Write responses:
//   A write transaction produces exactly ONE response beat (last = 1) after all
//   write data has been accepted, carrying only id and err. rdata is undefined
//   for write responses and must not be sampled.
//
// Naming conventions (inherited from fluxcore_pkg):
//   Types: *_t    Enums: *_e    Parameters: UPPER_CASE
//
// Compilation:
//   Imports fluxcore_pkg only. Must compile before every memory-path module.
//   Nothing in this package may import pipeline_pkg (avoid circular dependency).

`default_nettype none

package mem_if_pkg;

    import fluxcore_pkg::*;

    // -----------------------------------------------------------------------
    // 1. Widths
    // -----------------------------------------------------------------------

    // Byte-enable width. One strobe bit per byte lane of a data word.
    localparam int unsigned MEM_STRB_W = XLEN / 8;              // 4

    // Transaction id width. Reuses fluxcore_pkg::TXID_W, which exists for
    // precisely this purpose ("so responses can be matched when they return
    // out-of-order in later nonblocking memory milestones"). 4 bits = 16
    // outstanding transactions, far beyond the 1-MSHR design point of P2.
    localparam int unsigned MEM_ID_W   = TXID_W;                // 4

    // Burst length field width. 4 bits encodes 1..16 beats (len = beats-1),
    // which bounds the largest supported cache line at 16 words = 64 bytes.
    localparam int unsigned MEM_LEN_W  = 4;

    // Largest burst this interface can express, in beats.
    localparam int unsigned MEM_MAX_BEATS = (1 << MEM_LEN_W);   // 16

    // -----------------------------------------------------------------------
    // 2. Scalar types
    // -----------------------------------------------------------------------

    // Transaction identifier. Links a response to its originating request.
    typedef logic [MEM_ID_W-1:0]   mem_id_t;

    // Per-byte write strobe. Bit i enables byte lane i (little-endian:
    // bit 0 is bits [7:0]). Ignored for reads.
    typedef logic [MEM_STRB_W-1:0] mem_strb_t;

    // Burst length, AXI AxLEN encoding: beats = len + 1.
    typedef logic [MEM_LEN_W-1:0]  mem_len_t;

    // -----------------------------------------------------------------------
    // 3. Operation and error enums
    // -----------------------------------------------------------------------

    // Transaction direction. Kept to two values: read-modify-write and atomics
    // are built ABOVE this interface (P8.1 puts the AMO ALU at the cache port),
    // so the fabric never needs to understand them.
    typedef enum logic {
        MEM_READ  = 1'b0,
        MEM_WRITE = 1'b1
    } mem_op_e;

    // Response status. Encoding is chosen to map 1:1 onto AXI RRESP/BRESP so the
    // adapter in P3.2 is a rename, not a translation table.
    //   MEM_OK      transaction completed normally               (AXI OKAY)
    //   MEM_SLVERR  target accepted but failed the access        (AXI SLVERR)
    //   MEM_DECERR  no target decoded for this address           (AXI DECERR)
    // AXI's EXOKAY (exclusive access ok) is deliberately absent: LR/SC
    // reservations are tracked in the D-cache, not on the fabric.
    typedef enum logic [1:0] {
        MEM_OK     = 2'b00,
        MEM_SLVERR = 2'b10,
        MEM_DECERR = 2'b11
    } mem_err_e;

    // -----------------------------------------------------------------------
    // 4. Request payload
    // -----------------------------------------------------------------------
    // Accompanied by a separate valid/ready pair; the struct carries payload
    // only, never handshake signals.
    //
    // Fields:
    //   id    — transaction tag; returned unmodified in the response.
    //   addr  — byte address of the FIRST beat. Must be word-aligned; sub-word
    //           access is expressed with strb, not with low address bits.
    //           Misalignment is trapped in mem_stage before reaching here.
    //   op    — MEM_READ or MEM_WRITE.
    //   len   — beats - 1 (AXI AxLEN). Address increments by XLEN/8 per beat.
    //   strb  — byte enables for this beat. Ignored when op = MEM_READ.
    //   wdata — write data for this beat. Ignored when op = MEM_READ.
    //
    // For a multi-beat write, one request transfer occurs per beat: id, addr,
    // op and len stay constant across the burst while strb and wdata advance.
    // The responder derives each beat's address from addr + beat_index*4.

    typedef struct packed {
        mem_id_t   id;
        addr_t     addr;
        mem_op_e   op;
        mem_len_t  len;
        mem_strb_t strb;
        word_t     wdata;
    } mem_req_t;  // 4 + 32 + 1 + 4 + 4 + 32 = 77 bits

    // -----------------------------------------------------------------------
    // 5. Response payload
    // -----------------------------------------------------------------------
    // Fields:
    //   id    — echoes the request id. The ONLY link back to the request.
    //   rdata — read data for this beat. Undefined for write responses.
    //   err   — per-beat status. A burst may report an error on any beat; the
    //           requester must treat the whole transaction as failed.
    //   last  — 1 on the final beat of the transaction. A write transaction has
    //           exactly one response beat, so last is always 1 for writes.

    typedef struct packed {
        mem_id_t  id;
        word_t    rdata;
        mem_err_e err;
        logic     last;
    } mem_rsp_t;  // 4 + 32 + 2 + 1 = 39 bits

    // -----------------------------------------------------------------------
    // 6. Helpers
    // -----------------------------------------------------------------------

    // Beats in a burst, from the AxLEN-encoded len field.
    function automatic int unsigned mem_beats(input mem_len_t len);
        return int'(len) + 1;
    endfunction

    // AxLEN encoding for a burst of `beats` transfers. beats must be 1..16.
    function automatic mem_len_t mem_len_for(input int unsigned beats);
        return mem_len_t'(beats - 1);
    endfunction

    // Byte address of beat `idx` within a burst starting at `base`.
    function automatic addr_t mem_beat_addr(input addr_t base, input int unsigned idx);
        return base + addr_t'(idx * MEM_STRB_W);
    endfunction

    // A request that reads one word. Convenience for single-beat requesters.
    function automatic mem_req_t mem_read_req(input mem_id_t id, input addr_t addr);
        mem_req_t r;
        r.id    = id;
        r.addr  = addr;
        r.op    = MEM_READ;
        r.len   = '0;
        r.strb  = '0;
        r.wdata = '0;
        return r;
    endfunction

    // A request that writes one word under the given byte strobes.
    function automatic mem_req_t mem_write_req(input mem_id_t   id,
                                               input addr_t     addr,
                                               input mem_strb_t strb,
                                               input word_t     wdata);
        mem_req_t r;
        r.id    = id;
        r.addr  = addr;
        r.op    = MEM_WRITE;
        r.len   = '0;
        r.strb  = strb;
        r.wdata = wdata;
        return r;
    endfunction

endpackage : mem_if_pkg

`default_nettype wire
