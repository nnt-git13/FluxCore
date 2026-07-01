#!/usr/bin/env bash
# verification/scripts/run_questa_smoke.sh
#
# Run the Questa infrastructure smoke test.
#
# Expects the following environment variables (set by the Makefile):
#   VLOG        — vlog executable
#   VSIM        — vsim executable
#   SMOKE_BUILD — output directory (repository-relative)
#   SMOKE_FLIST — file list (repository-relative)
#   SMOKE_DO    — do script (repository-relative)
#
# Returns 0 on success, nonzero on failure.

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve the repository root from this script's location.
# All subsequent paths are relative to REPO_ROOT.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ---------------------------------------------------------------------------
# Apply defaults for variables not set by the caller
# ---------------------------------------------------------------------------
VLOG="${VLOG:-vlog}"
VSIM="${VSIM:-vsim}"
SMOKE_BUILD="${SMOKE_BUILD:-build/questa/smoke}"
SMOKE_FLIST="${SMOKE_FLIST:-verification/filelists/questa_smoke.f}"
SMOKE_DO="${SMOKE_DO:-sim/questa/run_smoke.do}"

WORK_DIR="${REPO_ROOT}/${SMOKE_BUILD}/work"
TRANSCRIPT="${REPO_ROOT}/${SMOKE_BUILD}/transcript"
FLIST="${REPO_ROOT}/${SMOKE_FLIST}"
DO_SCRIPT="${REPO_ROOT}/${SMOKE_DO}"

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
if ! command -v "${VLOG}" > /dev/null 2>&1; then
    echo "ERROR: vlog not found: ${VLOG}" >&2
    exit 1
fi
if ! command -v "${VSIM}" > /dev/null 2>&1; then
    echo "ERROR: vsim not found: ${VSIM}" >&2
    exit 1
fi
if [ ! -f "${FLIST}" ]; then
    echo "ERROR: File list not found: ${FLIST}" >&2
    exit 1
fi
if [ ! -f "${DO_SCRIPT}" ]; then
    echo "ERROR: Do script not found: ${DO_SCRIPT}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Create work library
# ---------------------------------------------------------------------------
echo "--- Creating work library at ${SMOKE_BUILD}/work ---"
mkdir -p "${REPO_ROOT}/${SMOKE_BUILD}"

cd "${REPO_ROOT}"

"${VLOG}" -work "${WORK_DIR}" -sv -f "${FLIST}" 2>&1 | tee "${TRANSCRIPT}.compile"
VLOG_STATUS=${PIPESTATUS[0]}

if [ "${VLOG_STATUS}" -ne 0 ]; then
    echo ""
    echo "ERROR: vlog compilation failed (exit ${VLOG_STATUS})."
    echo "       Transcript: ${TRANSCRIPT}.compile"
    exit "${VLOG_STATUS}"
fi

echo "--- Compilation successful ---"

# ---------------------------------------------------------------------------
# Run simulation
# ---------------------------------------------------------------------------
echo "--- Running simulation ---"

"${VSIM}" -work "${WORK_DIR}" \
    -c \
    -do "${DO_SCRIPT}" \
    tb_smoke_dut \
    2>&1 | tee "${TRANSCRIPT}.sim"
VSIM_STATUS=${PIPESTATUS[0]}

if [ "${VSIM_STATUS}" -ne 0 ]; then
    echo ""
    echo "ERROR: vsim simulation failed (exit ${VSIM_STATUS})."
    echo "       Transcript: ${TRANSCRIPT}.sim"
    exit "${VSIM_STATUS}"
fi

echo ""
echo "--- Questa smoke test PASSED ---"
echo "    Transcript: ${TRANSCRIPT}.sim"
