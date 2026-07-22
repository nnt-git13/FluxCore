# DDR3 Bring-Up Plan (P6.3 / P6.4) — Zybo Z7-20

Status: **ready to execute at the bench.** Everything on the PL side already
exists and is regression-tested in simulation; this document is the exact
sequence for the physical integration, which requires the board and Vivado
block-design work.

## What already exists (do not rebuild)

| Piece | Where | Proven by |
|---|---|---|
| Frozen memory protocol | `rtl/common/mem_if_pkg.sv` | mem-if-pkg-test |
| L1 D$ (2-way WB, non-blocking) | `rtl/cache/dcache.sv` | 7 unit TBs + SoC benchmarks |
| L1 I$ (combinational hits) | `rtl/cache/icache.sv` | tb_icache + caches benchmarks |
| Unified L2 (NINE) + arbiter | `rtl/cache/l2_cache.sv`, `rtl/memory/mem_arbiter.sv` | tb_l2_cache, tb_l2_chain |
| **AXI4 master adapter** | `rtl/memory/mem_if_axi.sv` | tb_dcache_axi (against axi_slave_model) |
| DDR-class latency sim | `sim/memory/dram_model.sv`, `sim/memory/axi_slave_model.sv` | tb_dram_model, tb_dcache_axi |

The target topology (all PL-side RTL, wire-by-name):

```
fetch ─ icache ─┐
                ├─ mem_arbiter ─ l2_cache ─ mem_if_axi ─── PS S_AXI_HP0 ─ DDR3
 MEM ── dcache ─┘
```

## P6.3 — PS DDR3 via AXI HP, step by step

1. **Block design**: instantiate `processing_system7_0`; enable `S_AXI_HP0`
   (32-bit). UART1/SD/enet can stay disabled — the PS exists here only to
   initialize DDR and expose the HP port. FCLK_CLK0 = 50 MHz feeds the PL
   (same clock domain as the core; no CDC needed at HP0 — it has its own
   internal synchronizers).
2. Package `fluxcore_soc` (or instantiate it RTL-on-block-design) with a new
   top parameter `USE_DDR=1` that replaces the L2's downstream
   `mem_if_bram`+`bram_dmem` pair with `mem_if_axi`, port-mapped to HP0
   (AWID width 6 on HP — zero-extend our 4-bit ids; AWCACHE=4'b0011,
   AWPROT=0).
3. **Address map**: HP0 windows DDR at `0x0010_0000`+ (first MB is reserved
   by the PS boot ROM convention). Set the SoC's memory window base
   accordingly in `soc_bus` (today's `everything else → mem path` rule keeps
   working; only the programs' link base moves — update
   `software/benchmarks/linker.ld` MEMORY origin).
4. **PS init**: a minimal FSBL (or XSCT `ps7_init`) to configure DDR + HP.
   No PS application is required for P6.3 — the PL core can run from BRAM
   while DATA lives in DDR as the first milestone.
5. **Validation ladder** (each step is one bitstream):
   a. `sim-*-caches` equivalents re-run in xsim with `axi_slave_model` in
      place of HP0 — already green (tb_dcache_axi proves the adapter).
   b. On board: BRAM imem + DDR dmem; run `hello_cpi`, compare checksum on
      the LEDs/UART as today.
   c. Measure real HP read latency with the hierarchy counters (P7.3) and
      back-annotate `dram_model`/`axi_slave_model` LATENCY defaults so sim
      CPI tracks hardware (ADR 0003's revisit condition).

## P6.4 — runtime program load

With DDR mapped, the PS can write program images directly into DDR before
releasing the PL reset:

1. FSBL/bare-metal PS app copies `imem.bin` to `0x0010_0000` and asserts the
   PL-side `core_rst` GPIO (EMIO) low afterwards.
2. The I-cache fetches through the same L2→HP path (topology above), so no
   bitstream rebuild per program — retiring ADR 0001's last cost.
3. **Coherence caveat (P7.2)**: the PS writes DDR through its own path; the
   PL L2/L1s must start COLD (reset does this) or be flushed (P7.1 ops)
   before the new image runs. For load-at-reset, reset-cold is sufficient —
   full ACP-vs-HP analysis only matters for load-while-running, which is
   out of scope until a real use case appears.

## P6.2 note — why there is no FluxCore memory controller

On Zynq the DRAM controller is PS hard silicon; the PL's side of the
contract is exactly `mem_if_axi`. A hand-built DDR controller could only
ever drive simulation models — that scheduling behavior (open-page policy,
bank timing, refresh) lives in `sim/memory/dram_model.sv` where it does its
real job: making simulated CPI representative. (ADR 0003 records this.)
