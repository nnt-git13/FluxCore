#!/usr/bin/env bash
# verification/scripts/regress.sh
#
# Umbrella regression driver: runs every self-checking simulation target
# with the selected backend and writes a dated summary report.
#
# Usage:
#   verification/scripts/regress.sh              # all targets, xsim backend
#   SIM_RUN=verification/scripts/questa_run.sh \
#   verification/scripts/regress.sh              # Questa backend
#   verification/scripts/regress.sh alu-test ... # subset of targets
#
# Exit code: 0 if every target passed, 1 otherwise.
#
# The report is written to reports/simulation/regress-<date>.txt so a
# passing regression is a committed, reproducible artifact rather than a
# claim in a README.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# Backend selection: honor SIM_RUN, but fall back to xsim when the Makefile's
# Questa default is requested and vsim is not actually installed.
SIM_RUN="${SIM_RUN:-verification/scripts/questa_run.sh}"
if [[ "$SIM_RUN" == *questa_run.sh ]] && ! command -v "${VSIM:-vsim}" > /dev/null 2>&1; then
    echo "note: vsim not found — using the xsim backend instead"
    SIM_RUN="verification/scripts/xsim_run.sh"
fi

# ---------------------------------------------------------------------------
# Target list — every self-checking sim target in dependency-free order.
# questa-smoke and pkg-test are excluded: they use Questa-specific runner
# scripts and duplicate coverage of isa-pkg-test / the unit tests below.
# ---------------------------------------------------------------------------
DEFAULT_TARGETS=(
    # Packages and combinational units
    isa-pkg-test
    mem-if-pkg-test
    mem-model-test
    alu-test
    imm-gen-test
    decoder-test
    regfile-test
    fp-regfile-test
    fp-cvt-test
    fp-short-test
    fp-mul-test
    fp-addsub-test
    fp-fma-test
    fp-divsqrt-test
    fp-sweep-test
    branch-unit-test
    pipeline-pkg-test
    # Pipeline stage registers
    if-id-reg-test
    id-ex-reg-test
    ex-mem-reg-test
    mem-wb-reg-test
    # Stage datapaths and control
    fetch-unit-test
    execute-stage-test
    mem-stage-test
    wb-stage-test
    pipeline-ctrl-test
    forwarding-unit-test
    csr-unit-test
    # Memories and cache
    bram-imem-test
    bram-dmem-test
    dcache-sim
    dcache-multiword-test
    dcache-assoc-test
    dcache-wb-test
    dcache-mshr-test
    dcache-latency-test
    dcache-axi-test
    l2-cache-test
    l2-chain-test
    icache-test
    fencei-test
    dcache-e2e-test
    # Core integration
    integration-test
    lw-sw-test
    branch-integ-test
    jal-jalr-test
    lui-auipc-test
    byte-halfword-test
    branch-compare-test
    rv32i-alu-test
    rv32m-test
    fp-arith-test
    fp-loadstore-test
    fp-muldiv-test
    fp-csr-test
    ecall-mret-test
    # Full-SoC benchmark programs (need the RISC-V toolchain)
    sim-hello-cpi
    sim-spmv-csr
    sim-csr-probe
    sim-hello-uart
    sim-timer-irq
    sim-misalign-trap
    sim-xflux
    sim-fp-kernel
    sim-hello-cpi-dcache
    sim-spmv-csr-dcache
    sim-hello-cpi-caches
    sim-spmv-csr-caches
)

if [[ $# -gt 0 ]]; then
    TARGETS=("$@")
else
    TARGETS=("${DEFAULT_TARGETS[@]}")
fi

REPORT_DIR="reports/simulation"
mkdir -p "$REPORT_DIR"
STAMP="$(date +%Y-%m-%d)"
REPORT="$REPORT_DIR/regress-$STAMP.txt"
LOG_DIR="build/regress"
mkdir -p "$LOG_DIR"

n_pass=0
n_fail=0
failed_targets=()

{
    echo "FluxCore regression — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "backend: $SIM_RUN"
    echo "commit:  $(git rev-parse --short HEAD 2>/dev/null || echo 'n/a')$(git diff --quiet 2>/dev/null || echo ' (+ uncommitted changes)')"
    echo "host:    $(uname -sr)"
    echo "----------------------------------------------------------------------"
} > "$REPORT"

start_all=$SECONDS
for t in "${TARGETS[@]}"; do
    log="$LOG_DIR/$t.log"
    start=$SECONDS
    if make "$t" SIM_RUN="$SIM_RUN" > "$log" 2>&1; then
        dur=$(( SECONDS - start ))
        printf "PASS  %-24s %4ds\n" "$t" "$dur" | tee -a "$REPORT"
        n_pass=$(( n_pass + 1 ))
    else
        dur=$(( SECONDS - start ))
        printf "FAIL  %-24s %4ds   (log: %s)\n" "$t" "$dur" "$log" | tee -a "$REPORT"
        n_fail=$(( n_fail + 1 ))
        failed_targets+=("$t")
    fi
done
total_dur=$(( SECONDS - start_all ))

{
    echo "----------------------------------------------------------------------"
    echo "TOTAL: $n_pass/$(( n_pass + n_fail )) passed in ${total_dur}s"
    if [[ $n_fail -gt 0 ]]; then
        echo "FAILED: ${failed_targets[*]}"
    fi
} | tee -a "$REPORT"

echo "report: $REPORT"
[[ $n_fail -eq 0 ]]
