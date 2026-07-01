#!/usr/bin/env bash
# verification/scripts/run_questa_pkg.sh
#
# Run the fluxcore_pkg unit test in Questa.
#
# Expects the following environment variables (set by the Makefile):
#   VLOG      — vlog executable
#   VSIM      — vsim executable
#   PKG_BUILD — output directory for this test (repository-relative)
#
# Returns 0 on success (PASS), nonzero on compilation or simulation failure.

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve the repository root from this script's location.
# All paths below are relative to REPO_ROOT.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ---------------------------------------------------------------------------
# Apply defaults
# ---------------------------------------------------------------------------
VLOG="${VLOG:-vlog}"
VSIM="${VSIM:-vsim}"
PKG_BUILD="${PKG_BUILD:-build/questa/pkg}"

FLIST="${REPO_ROOT}/verification/filelists/fluxcore_pkg.f"
DO_SCRIPT="${REPO_ROOT}/sim/questa/run_pkg.do"
WORK_DIR="${REPO_ROOT}/${PKG_BUILD}/work"
TRANSCRIPT="${REPO_ROOT}/${PKG_BUILD}/transcript"

# ---------------------------------------------------------------------------
# Validate prerequisites
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
# Compile
# ---------------------------------------------------------------------------
echo "--- Compiling fluxcore_pkg and testbench ---"
mkdir -p "${REPO_ROOT}/${PKG_BUILD}"
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
# Simulate
# ---------------------------------------------------------------------------
echo "--- Running tb_fluxcore_pkg ---"

"${VSIM}" -work "${WORK_DIR}" \
    -c \
    -do "${DO_SCRIPT}" \
    tb_fluxcore_pkg \
    2>&1 | tee "${TRANSCRIPT}.sim"
VSIM_STATUS=${PIPESTATUS[0]}

if [ "${VSIM_STATUS}" -ne 0 ]; then
    echo ""
    echo "ERROR: vsim simulation failed (exit ${VSIM_STATUS})."
    echo "       Transcript: ${TRANSCRIPT}.sim"
    exit "${VSIM_STATUS}"
fi

echo ""
echo "--- fluxcore_pkg unit test PASSED ---"
echo "    Transcript: ${TRANSCRIPT}.sim"
