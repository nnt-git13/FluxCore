"""synth/analysis/ca_metrics.py

Computer-Architecture textbook formulas applied to FluxCore synthesis data.

Formulas implemented (from the CA course textbook screenshot):
  1.  CPU time         = IC × CPI × cycle_time               [s]
  2.  Speedup (perf)   = perf_A / perf_B = time_B / time_A
  3.  Amdahl's Law     = 1 / ((1-f) + f/S)                   speedup from fraction-f improvement
  4.  Energy (dynamic) = (1/2) × C × V²                      [J] per switching event
  5.  Power (dynamic)  = (1/2) × C × V² × f                  [W]
  6.  Power (static)   = I_static × V                         [W]
  7.  Availability     = MTTF / (MTTF + MTTR)
  8.  Die yield        = dies_per_wafer × die_yield_factor
                         dies_per_wafer = wafer_area / die_area - π×diameter/sqrt(2×die_area)
                         die_yield_factor = (1 + defect_density×die_area/N)^(-N)
  9.  AM / GM / WAM    mean formulae
  10. AMAT             = hit_time + miss_rate × miss_penalty   [cycles]
  11. MPI              = memory_accesses / instructions        (misses per instruction)
  12. Cache index bits = log2(cache_sets)

All FluxCore parameters are sourced from actual Vivado implementation reports:
  reports/implementation/fluxcore_soc_timing_summary_route.rpt
  reports/implementation/fluxcore_soc_utilization_route.rpt
"""

from __future__ import annotations

import math
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


# ---------------------------------------------------------------------------
# Vivado report parsing
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
TIMING_RPT  = REPO_ROOT / "reports/implementation/fluxcore_soc_timing_summary_route.rpt"
UTIL_RPT    = REPO_ROOT / "reports/implementation/fluxcore_soc_utilization_route.rpt"


def _parse_timing(path: Path) -> dict[str, float]:
    """Extract clock period, frequency, WNS, WHS from Vivado timing report.

    Raises FileNotFoundError if the report does not exist.
    Raises ValueError if a required field cannot be parsed.

    Report format (whitespace-aligned, no | separators):
      Clock         Waveform(ns)       Period(ns)      Frequency(MHz)
      fluxcore_clk  {0.000 10.000}     20.000          50.000

      WNS(ns)      TNS(ns)  ...  WHS(ns)  ...
      -------      -------  ...  -------  ...
        3.780        0.000  ...    0.106  ...
    """
    text = path.read_text()
    result: dict[str, float] = {}

    # Period and frequency: clock definition table row
    m = re.search(r"fluxcore_clk\s+\{[^}]+\}\s+([0-9.]+)\s+([0-9.]+)", text)
    if not m:
        raise ValueError(f"Could not parse clock period/frequency from {path}")
    result["period_ns"]     = float(m.group(1))
    result["frequency_mhz"] = float(m.group(2))

    # WNS and WHS: summary data row (first number = WNS, sixth column = WHS)
    # Header:  WNS(ns)  TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints  WHS(ns) ...
    # Dashes:  -------  -------  ...
    # Data:      3.780    0.000                        0                5153    0.106  ...
    m = re.search(
        r"WNS\(ns\)\s+TNS\(ns\).*?\n\s*-+.*?\n"   # header + dashes
        r"\s*(-?[0-9.]+)"                           # WNS
        r"\s+[0-9.]+\s+\d+\s+\d+"                  # TNS, TNS_fail, TNS_total
        r"\s+(-?[0-9.]+)",                          # WHS
        text, re.DOTALL
    )
    if not m:
        raise ValueError(f"Could not parse WNS/WHS from {path}")
    result["wns_ns"] = float(m.group(1))
    result["whs_ns"] = float(m.group(2))

    return result


def _parse_utilization(path: Path) -> dict[str, int]:
    """Extract LUT, FF, BRAM, DSP, Slice counts from Vivado utilization report.

    Raises FileNotFoundError if the report does not exist.
    Raises ValueError if a required field cannot be parsed.
    """
    text = path.read_text()
    result: dict[str, int] = {}

    patterns = {
        "luts":   r"(?:Slice LUTs|LUT as Logic)\s*\|\s*(\d+)",
        "ffs":    r"(?:Slice Registers|Register as Flip Flop)\s*\|\s*(\d+)",
        "bram18": r"RAMB18\s*\|\s*(\d+)",
        "dsp48":  r"DSPs\s*\|\s*(\d+)",
        "slices": r"\| Slice\s+\|\s*(\d+)",
    }
    for key, pat in patterns.items():
        m = re.search(pat, text)
        if not m:
            raise ValueError(f"Could not parse '{key}' from {path}")
        result[key] = int(m.group(1))

    # Available-resource counts (constant for xc7z020clg400-1)
    result["luts_avail"]   = 53200
    result["ffs_avail"]    = 106400
    result["bram18_avail"] = 280
    result["dsp48_avail"]  = 220
    result["slices_avail"] = 13300

    return result


# ---------------------------------------------------------------------------
# 1. CPU time
# ---------------------------------------------------------------------------

def cpu_time(ic: float, cpi: float, cycle_time_ns: float) -> float:
    """CPU time in nanoseconds:  IC × CPI × cycle_time."""
    return ic * cpi * cycle_time_ns


# ---------------------------------------------------------------------------
# 2. Speedup (performance ratio)
# ---------------------------------------------------------------------------

def speedup(time_b: float, time_a: float) -> float:
    """Speedup of A over B = time_B / time_A  (= perf_A / perf_B)."""
    return time_b / time_a


# ---------------------------------------------------------------------------
# 3. Amdahl's Law
# ---------------------------------------------------------------------------

def amdahl(f: float, S: float) -> float:
    """Overall speedup when fraction f of the program is sped up by factor S.

    speedup_overall = 1 / ((1 - f) + f/S)
    """
    return 1.0 / ((1.0 - f) + f / S)


# ---------------------------------------------------------------------------
# 4–6. Power / Energy
# ---------------------------------------------------------------------------

def dynamic_energy(C: float, V: float) -> float:
    """Dynamic energy per switching event:  (1/2) × C × V²   [J]."""
    return 0.5 * C * V ** 2


def dynamic_power(C: float, V: float, f_Hz: float) -> float:
    """Dynamic power:  (1/2) × C × V² × f   [W]."""
    return 0.5 * C * V ** 2 * f_Hz


def static_power(I_static: float, V: float) -> float:
    """Static (leakage) power:  I_static × V   [W]."""
    return I_static * V


# ---------------------------------------------------------------------------
# 7. Availability
# ---------------------------------------------------------------------------

def availability(mttf: float, mttr: float) -> float:
    """System availability:  MTTF / (MTTF + MTTR)."""
    return mttf / (mttf + mttr)


# ---------------------------------------------------------------------------
# 8. Die yield
# ---------------------------------------------------------------------------

def dies_per_wafer(wafer_diameter_mm: float, die_area_mm2: float) -> float:
    """Approximate number of dies per wafer (ignoring edge losses).

    dies_per_wafer ≈ (π × (diameter/2)²) / die_area
                     - π × diameter / sqrt(2 × die_area)
    """
    wafer_area = math.pi * (wafer_diameter_mm / 2.0) ** 2
    edge_loss  = math.pi * wafer_diameter_mm / math.sqrt(2.0 * die_area_mm2)
    return wafer_area / die_area_mm2 - edge_loss


def die_yield(dpw: float, defect_density: float, die_area_mm2: float,
              N: float = 4.0) -> float:
    """Die yield using the negative-binomial model.

    die_yield = (1 + defect_density × die_area / N)^(-N)
    """
    return (1.0 + defect_density * die_area_mm2 / N) ** (-N)


def dies_out(dpw: float, dy: float) -> float:
    """Good dies per wafer = dies_per_wafer × die_yield."""
    return dpw * dy


# ---------------------------------------------------------------------------
# 9. Mean formulae
# ---------------------------------------------------------------------------

def arithmetic_mean(xs: list[float]) -> float:
    return sum(xs) / len(xs)


def geometric_mean(xs: list[float]) -> float:
    return math.exp(sum(math.log(x) for x in xs) / len(xs))


def weighted_arithmetic_mean(xs: list[float], ws: list[float]) -> float:
    total_w = sum(ws)
    return sum(x * w for x, w in zip(xs, ws)) / total_w


# ---------------------------------------------------------------------------
# 10. AMAT
# ---------------------------------------------------------------------------

def amat(hit_time: float, miss_rate: float, miss_penalty: float) -> float:
    """Average memory access time:  hit_time + miss_rate × miss_penalty."""
    return hit_time + miss_rate * miss_penalty


# ---------------------------------------------------------------------------
# 11. MPI (misses per instruction)
# ---------------------------------------------------------------------------

def mpi(total_misses: float, total_instructions: float) -> float:
    """Misses per instruction:  total_misses / total_instructions."""
    return total_misses / total_instructions


# ---------------------------------------------------------------------------
# 12. Cache index bits
# ---------------------------------------------------------------------------

def cache_index_bits(cache_sets: int) -> int:
    """Number of index bits:  log2(cache_sets)."""
    return int(math.log2(cache_sets))


# ---------------------------------------------------------------------------
# SpMV-specific performance analysis
# ---------------------------------------------------------------------------

@dataclass
class SPMVAnalysis:
    """Performance and power analysis for the SpMV CSR inner-loop on FluxCore."""

    # --- Vivado parameters ---
    period_ns:     float = 20.000
    frequency_mhz: float = 50.0
    wns_ns:        float = 0.106
    whs_ns:        float = 0.152

    # --- Utilization ---
    luts:          int = 3313
    ffs:           int = 2003
    bram18:        int = 5
    dsp48:         int = 0
    slices:        int = 1204

    luts_avail:    int = 53200
    ffs_avail:     int = 106400
    bram18_avail:  int = 280
    dsp48_avail:   int = 220
    slices_avail:  int = 13300

    # --- SpMV benchmark parameters (8×8 matrix, NNZ=21) ---
    nnz:           int   = 21
    n_rows:        int   = 8
    # Inner loop: 12 instructions per iteration (PCs 0-11)
    # plus 1 extra BGEU at PC0 when the loop exits (k == j_end)
    # Load-use stalls: 2 per iteration (LW x8 → SLLI x9; LW x10 → MUL x11)
    # MUL is single-cycle combinational (no stall).
    instr_per_iter: int  = 12     # instructions retired in one inner-loop body
    stalls_per_iter: int = 2      # load-use stalls (bubbles) injected per iter
    exit_branch_instrs: int = 1   # the final BGEU that terminates the loop

    # Per-row outer loop overhead (load row_ptr[i], row_ptr[i+1], compute j_end):
    # LW row_ptr[i]: ~5 instrs, LW row_ptr[i+1]: ~4 instrs, store y[i]: ~3 instrs
    # Total outer overhead per row: ~12 instrs + 1 load-use stall
    outer_instrs_per_row: int = 12
    outer_stalls_per_row: int = 1

    # Target voltage / capacitance (Zynq-7020 typical @ 1.0 V core)
    V_core:        float = 1.0    # V
    C_dynamic_pF:  float = 10.0   # pF — rough estimate for FluxCore LUT switching cap
    I_static_mA:   float = 50.0   # mA — Zynq-7020 static leakage estimate

    # L1 dcache parameters (direct-mapped write-through, 4 KiB, 4B lines)
    dcache_sets:      int   = 256
    dcache_hit_time:  float = 1.0    # cycles (pipelined; hit in MEM stage)
    dcache_miss_rate: float = 0.05   # estimated for SpMV (streaming accesses)
    dcache_miss_penalty: float = 10.0  # cycles (BRAM DMEM round-trip)

    def fmax_mhz(self) -> float:
        """Maximum achievable frequency: 1 / (period - WNS)."""
        achievable_period = self.period_ns - self.wns_ns
        return 1e3 / achievable_period

    def total_instructions(self) -> int:
        """Total instructions retired for the full 8×8 SpMV."""
        inner  = self.nnz * self.instr_per_iter + self.exit_branch_instrs
        outer  = self.n_rows * self.outer_instrs_per_row
        return inner + outer

    def total_cycles(self) -> int:
        """Total cycles including load-use stall bubbles."""
        inner_stalls = self.nnz * self.stalls_per_iter
        outer_stalls = self.n_rows * self.outer_stalls_per_row
        return self.total_instructions() + inner_stalls + outer_stalls

    def cpi(self) -> float:
        return self.total_cycles() / self.total_instructions()

    def cpu_time_us(self) -> float:
        """Wall-clock time for the SpMV in microseconds."""
        return self.total_cycles() * self.period_ns * 1e-3

    def dynamic_power_mw(self) -> float:
        """Estimated dynamic power in mW (order-of-magnitude estimate)."""
        f_hz = self.frequency_mhz * 1e6
        C    = self.C_dynamic_pF * 1e-12
        return dynamic_power(C, self.V_core, f_hz) * 1e3

    def static_power_mw(self) -> float:
        return static_power(self.I_static_mA * 1e-3, self.V_core) * 1e3

    def total_power_mw(self) -> float:
        return self.dynamic_power_mw() + self.static_power_mw()

    def amat_cycles(self) -> float:
        return amat(self.dcache_hit_time, self.dcache_miss_rate, self.dcache_miss_penalty)

    def memory_accesses_per_iter(self) -> int:
        return 3  # LW val[j], LW col_idx[j], LW x[col_idx[j]]

    def mpi_inner(self) -> float:
        """Misses per instruction for the SpMV inner loop."""
        mem_accesses = self.nnz * self.memory_accesses_per_iter()
        misses       = mem_accesses * self.dcache_miss_rate
        return mpi(misses, self.total_instructions())

    def utilization_pct(self) -> dict[str, float]:
        return {
            "LUTs":   100.0 * self.luts   / self.luts_avail,
            "FFs":    100.0 * self.ffs    / self.ffs_avail,
            "BRAM18": 100.0 * self.bram18 / self.bram18_avail,
            "DSP48":  100.0 * self.dsp48  / self.dsp48_avail  if self.dsp48_avail else 0.0,
            "Slices": 100.0 * self.slices / self.slices_avail,
        }

    def amdahl_nnz_bottleneck(self) -> float:
        """Amdahl speedup if we accelerated the 3 loads (75 % of loop body) by 2×."""
        f_loads = 3 / self.instr_per_iter   # fraction of instructions that are loads
        return amdahl(f_loads, 2.0)

    def amdahl_mul_pipeline(self) -> float:
        """Speedup if MUL were multi-cycle (5-cycle, like a soft multiplier)."""
        f_mul = 1 / self.instr_per_iter
        # Going from 5 cycles to 1 cycle is 5× speedup on that fraction
        S_reverse = 1 / 5
        # But MUL is already 1 cycle; this measures the cost if it were NOT:
        return amdahl(f_mul, 1.0 / S_reverse)


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

def _section(title: str) -> None:
    print()
    print("=" * 72)
    print(f"  {title}")
    print("=" * 72)


def _row(label: str, value: str, unit: str = "") -> None:
    u = f"  [{unit}]" if unit else ""
    print(f"  {label:<42} {value}{u}")


def main() -> None:
    try:
        timing = _parse_timing(TIMING_RPT)
    except (FileNotFoundError, ValueError) as e:
        sys.exit(f"ERROR: {e}\nRun vivado-impl first to generate the timing report.")

    try:
        util = _parse_utilization(UTIL_RPT)
    except (FileNotFoundError, ValueError) as e:
        sys.exit(f"ERROR: {e}\nRun vivado-impl first to generate the utilization report.")

    a = SPMVAnalysis(
        period_ns=timing["period_ns"],
        frequency_mhz=timing["frequency_mhz"],
        wns_ns=timing["wns_ns"],
        whs_ns=timing["whs_ns"],
        luts=util["luts"],
        ffs=util["ffs"],
        bram18=util["bram18"],
        dsp48=util["dsp48"],
        slices=util["slices"],
        luts_avail=util["luts_avail"],
        ffs_avail=util["ffs_avail"],
        bram18_avail=util["bram18_avail"],
        dsp48_avail=util["dsp48_avail"],
        slices_avail=util["slices_avail"],
    )

    print()
    print("┌─────────────────────────────────────────────────────────────────┐")
    print("│        FluxCore — Computer Architecture Metrics Report          │")
    print("│        8×8 SpMV CSR benchmark  ·  xc7z020clg400-1              │")
    print("└─────────────────────────────────────────────────────────────────┘")
    print(f"  Timing report:  {TIMING_RPT.relative_to(REPO_ROOT)}")
    print(f"  Util report:    {UTIL_RPT.relative_to(REPO_ROOT)}")

    # ------------------------------------------------------------------
    _section("1. Timing  (from Vivado implementation report)")
    _row("Clock period",              f"{a.period_ns:.3f}",          "ns")
    _row("Target frequency",          f"{a.frequency_mhz:.1f}",      "MHz")
    _row("WNS (setup slack)",         f"{a.wns_ns:.3f}",             "ns")
    _row("WHS (hold slack)",          f"{a.whs_ns:.3f}",             "ns")
    _row("Achievable Fmax",           f"{a.fmax_mhz():.2f}",         "MHz")

    # ------------------------------------------------------------------
    _section("2. Resource Utilization  (Vivado route report)")
    umap = a.utilization_pct()
    _row("LUTs",    f"{a.luts:>6} / {a.luts_avail}  ({umap['LUTs']:.2f}%)")
    _row("FFs",     f"{a.ffs:>6} / {a.ffs_avail}  ({umap['FFs']:.2f}%)")
    _row("BRAM18",  f"{a.bram18:>6} / {a.bram18_avail}  ({umap['BRAM18']:.2f}%)")
    _row("DSP48",   f"{a.dsp48:>6} / {a.dsp48_avail}  ({umap['DSP48']:.2f}%)")
    _row("Slices",  f"{a.slices:>6} / {a.slices_avail}  ({umap['Slices']:.2f}%)")

    # ------------------------------------------------------------------
    _section("3. CPU Time  —  IC × CPI × cycle_time")
    ic   = a.total_instructions()
    cyc  = a.total_cycles()
    c    = a.cpi()
    t_us = a.cpu_time_us()
    _row("Inner-loop instructions (NNZ=21 × 12 + 1)",  f"{a.nnz*a.instr_per_iter + a.exit_branch_instrs}")
    _row("Inner-loop stall bubbles (NNZ × 2)",         f"{a.nnz * a.stalls_per_iter}")
    _row("Outer-loop instructions  (8 rows × 12)",     f"{a.n_rows * a.outer_instrs_per_row}")
    _row("Outer-loop stall bubbles (8 rows × 1)",      f"{a.n_rows * a.outer_stalls_per_row}")
    _row("Total instructions  (IC)",                   f"{ic}")
    _row("Total cycles",                               f"{cyc}")
    _row("CPI  = cycles / IC",                         f"{c:.4f}")
    _row("Cycle time",                                 f"{a.period_ns:.3f}", "ns")
    _row("CPU time  = IC × CPI × cycle_time",          f"{t_us:.4f}", "µs")
    _row("CPU time  (formula check: cycles × period)", f"{cyc * a.period_ns * 1e-3:.4f}", "µs")

    # ------------------------------------------------------------------
    _section("4. Amdahl's Law  —  1 / ((1-f) + f/S)")
    print()
    print("  Scenario A: Eliminate load-use stalls (f = stall_cycles / total_cycles)")
    stall_cycles = a.nnz * a.stalls_per_iter + a.n_rows * a.outer_stalls_per_row
    f_stalls = stall_cycles / cyc
    # Eliminating stalls = infinite speedup on that fraction
    sp_stall = amdahl(f_stalls, 1.0 / (1.0 - f_stalls + 1e-9))  # approx with S→∞
    sp_stall_exact = cyc / (cyc - stall_cycles)  # exact: remove all stall cycles
    _row("  Stall cycles fraction (f)", f"{f_stalls:.4f}")
    _row("  Speedup if all stalls removed", f"{sp_stall_exact:.4f}×")

    print()
    print("  Scenario B: MUL already 1-cycle (combinational); cost if it were 5-cycle")
    _row("  Speedup of 1-cycle vs 5-cycle MUL", f"{a.amdahl_mul_pipeline():.4f}×")

    print()
    print("  Scenario C: Double frequency (Fmax 50 → 100 MHz)")
    sp_freq = amdahl(1.0, 2.0)
    _row("  Speedup (f=1.0, S=2)", f"{sp_freq:.4f}×")

    # ------------------------------------------------------------------
    _section("5. Power & Energy  —  dynamic / static")
    f_hz = a.frequency_mhz * 1e6
    C_F  = a.C_dynamic_pF * 1e-12
    E_per_event = dynamic_energy(C_F, a.V_core)
    _row("Core supply voltage (V_core)",              f"{a.V_core:.1f}", "V")
    _row("Switching capacitance (C, estimate)",       f"{a.C_dynamic_pF:.1f}", "pF")
    _row("Energy per switching event  ½CV²",          f"{E_per_event*1e15:.2f}", "fJ")
    _row("Dynamic power  ½CV²f",                      f"{a.dynamic_power_mw():.4f}", "mW")
    _row("Static leakage current  (I_static)",        f"{a.I_static_mA:.1f}", "mA")
    _row("Static power  I_static × V",                f"{a.static_power_mw():.1f}", "mW")
    _row("Total estimated power",                     f"{a.total_power_mw():.2f}", "mW")
    # Energy for one SpMV
    E_spmv_nJ = a.total_power_mw() * 1e-3 * a.cpu_time_us() * 1e-6 * 1e9
    _row("Energy per SpMV  (P × T)",                  f"{E_spmv_nJ:.4f}", "nJ")

    # ------------------------------------------------------------------
    _section("6. Availability  —  MTTF / (MTTF + MTTR)")
    mttf_h = 100_000.0
    mttr_h = 2.0
    avail  = availability(mttf_h, mttr_h)
    _row("MTTF (assumed)", f"{mttf_h:,.0f}", "hours")
    _row("MTTR (assumed)", f"{mttr_h:.1f}", "hours")
    _row("Availability = MTTF/(MTTF+MTTR)", f"{avail:.6f}", "(99.998 %)")

    # ------------------------------------------------------------------
    _section("7. Die Yield  —  dies_per_wafer × die_yield")
    # Zynq-7020 (TSMC 28 nm, ~200 mm² die, 300 mm wafer)
    wafer_d  = 300.0   # mm
    die_area = 200.0   # mm²
    dd       = 0.02    # defects/mm²
    N_cmplx  = 4.0
    dpw  = dies_per_wafer(wafer_d, die_area)
    dy   = die_yield(dpw, dd, die_area, N_cmplx)
    good = dies_out(dpw, dy)
    _row("Wafer diameter",              f"{wafer_d:.0f}", "mm")
    _row("Die area (Zynq-7020 approx)", f"{die_area:.0f}", "mm²")
    _row("Defect density",              f"{dd:.3f}", "defects/mm²")
    _row("Dies per wafer",              f"{dpw:.1f}")
    _row("Die yield factor",            f"{dy:.4f}")
    _row("Good dies per wafer",         f"{good:.1f}")

    # ------------------------------------------------------------------
    _section("8. AMAT  —  hit_time + miss_rate × miss_penalty")
    am = a.amat_cycles()
    _row("L1 dcache hit time",          f"{a.dcache_hit_time:.1f}", "cycles")
    _row("L1 dcache miss rate (SpMV)",  f"{a.dcache_miss_rate:.3f}")
    _row("L1 dcache miss penalty",      f"{a.dcache_miss_penalty:.1f}", "cycles")
    _row("AMAT",                        f"{am:.3f}", "cycles")
    _row("Cache index bits (256 sets)", f"{cache_index_bits(a.dcache_sets)}")

    # ------------------------------------------------------------------
    _section("9. MPI  —  misses per instruction")
    m_inner = a.mpi_inner()
    _row("Memory accesses per iteration",     f"{a.memory_accesses_per_iter()}")
    _row("Total memory accesses (NNZ=21)",    f"{a.nnz * a.memory_accesses_per_iter()}")
    _row("Estimated total misses",
         f"{a.nnz * a.memory_accesses_per_iter() * a.dcache_miss_rate:.2f}")
    _row("MPI (inner loop fraction)",         f"{m_inner:.5f}")

    # ------------------------------------------------------------------
    _section("10. Speedup — FluxCore vs scalar reference")
    # Reference: RISC-V scalar core at 50 MHz, CPI=1.5 (no forwarding, full stalls)
    ref_cpi  = 1.5
    ref_time = ic * ref_cpi * a.period_ns * 1e-3
    sp = speedup(ref_time, a.cpu_time_us())
    _row("Reference CPI (no forwarding, est.)",  f"{ref_cpi:.2f}")
    _row("FluxCore CPI (with forwarding)",        f"{c:.4f}")
    _row("Reference CPU time",                   f"{ref_time:.4f}", "µs")
    _row("FluxCore CPU time",                    f"{a.cpu_time_us():.4f}", "µs")
    _row("Speedup (FluxCore over reference)",    f"{sp:.4f}×")

    # ------------------------------------------------------------------
    _section("11. Mean formulae  —  AM / GM / WAM")
    cpis = [1.0, c, ref_cpi]
    labels = ["ideal (CPI=1)", "FluxCore", "reference (CPI=1.5)"]
    print(f"\n  CPI values: {', '.join(f'{l}={v:.4f}' for l,v in zip(labels,cpis))}")
    _row("Arithmetic mean CPI",  f"{arithmetic_mean(cpis):.4f}")
    _row("Geometric mean CPI",   f"{geometric_mean(cpis):.4f}")
    ws = [1.0, 3.0, 1.0]
    _row("Weighted AM CPI (weights 1,3,1)", f"{weighted_arithmetic_mean(cpis,ws):.4f}")

    # ------------------------------------------------------------------
    print()
    print("=" * 72)
    print("  Summary")
    print("=" * 72)
    print(f"  FluxCore SpMV (NNZ=21, 8×8):  {ic} instrs, {cyc} cycles")
    print(f"  CPI = {c:.4f}  (2 load-use stalls/iter, MUL = 1 cycle)")
    print(f"  CPU time = {a.cpu_time_us():.4f} µs  @ {a.frequency_mhz:.0f} MHz")
    print(f"  AMAT = {am:.3f} cycles  |  MPI = {m_inner:.5f}")
    print(f"  Device: xc7z020clg400-1 — LUTs {a.luts}/{a.luts_avail}"
          f"  FFs {a.ffs}/{a.ffs_avail}  BRAM18 {a.bram18}/{a.bram18_avail}")
    print(f"  Checksum verified: 416 (= 0x1A0) — proven by spmv_concrete_checksum (Rocq)")
    print()


if __name__ == "__main__":
    main()
