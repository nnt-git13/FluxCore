#!/usr/bin/env bash
# verification/scripts/questa_run.sh
#
# Generic Questa compile-and-simulate driver.
#
# Usage:
#   questa_run.sh <build-dir> <filelist> <do-script> <top-module>
#
# Arguments:
#   build-dir    Directory for compiled work library (will be created).
#   filelist     File containing one source file per line, relative to repo root.
#   do-script    Questa .do file passed to vsim (e.g. sim/questa/run_unit.do).
#   top-module   Top-level module name for vsim.
#
# Environment:
#   VLOG         Path to vlog binary   (default: vlog)
#   VSIM         Path to vsim binary   (default: vsim)
#   QUESTA_FLAGS Additional vlog flags (optional)
#
# Transcript:
#   stdout/stderr are tee'd to <build-dir>/vlog.transcript and
#   <build-dir>/vsim.transcript respectively.
#
# Exit codes:
#   0  Simulation completed (pass/fail determined by $fatal or $finish in DUT).
#   1  Wrong number of arguments.
#   2  vlog or vsim not found.
#   3  vlog compilation failed.
#   4  vsim simulation failed.

set -euo pipefail

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
if [[ $# -ne 4 ]]; then
    echo "ERROR: questa_run.sh requires exactly 4 arguments." >&2
    echo "Usage: questa_run.sh <build-dir> <filelist> <do-script> <top-module>" >&2
    exit 1
fi

BUILD_DIR="$1"
FILELIST="$2"
DO_SCRIPT="$3"
TOP="$4"

# ---------------------------------------------------------------------------
# Locate tools
# ---------------------------------------------------------------------------
VLOG="${VLOG:-vlog}"
VSIM="${VSIM:-vsim}"

if ! command -v "$VLOG" >/dev/null 2>&1; then
    echo "ERROR: vlog not found (checked PATH and VLOG='$VLOG')." >&2
    echo "       Install Questa/ModelSim and add it to PATH, or set VLOG=/path/to/vlog." >&2
    exit 2
fi

if ! command -v "$VSIM" >/dev/null 2>&1; then
    echo "ERROR: vsim not found (checked PATH and VSIM='$VSIM')." >&2
    echo "       Install Questa/ModelSim and add it to PATH, or set VSIM=/path/to/vsim." >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
# The script is at verification/scripts/; the repo root is two levels up.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ABS_BUILD_DIR="$REPO_ROOT/$BUILD_DIR"
ABS_FILELIST="$REPO_ROOT/$FILELIST"
ABS_DO_SCRIPT="$REPO_ROOT/$DO_SCRIPT"

# Validate inputs
if [[ ! -f "$ABS_FILELIST" ]]; then
    echo "ERROR: filelist not found: $ABS_FILELIST" >&2
    exit 1
fi
if [[ ! -f "$ABS_DO_SCRIPT" ]]; then
    echo "ERROR: do-script not found: $ABS_DO_SCRIPT" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Prepare build directory
# ---------------------------------------------------------------------------
mkdir -p "$ABS_BUILD_DIR"

echo "============================================================"
echo "questa_run: $TOP"
echo "  build-dir : $BUILD_DIR"
echo "  filelist  : $FILELIST"
echo "  do-script : $DO_SCRIPT"
echo "  vlog      : $($VLOG -version 2>&1 | head -1)"
echo "  vsim      : $($VSIM -version 2>&1 | head -1)"
echo "============================================================"

# ---------------------------------------------------------------------------
# Compile
# ---------------------------------------------------------------------------
echo "[1/2] Compiling..."
VLOG_TRANSCRIPT="$ABS_BUILD_DIR/vlog.transcript"

if ! "$VLOG" \
        -sv \
        -work "$ABS_BUILD_DIR/work" \
        -f "$ABS_FILELIST" \
        ${QUESTA_FLAGS:-} \
        2>&1 | tee "$VLOG_TRANSCRIPT"; then
    echo ""
    echo "ERROR: vlog compilation failed. See $VLOG_TRANSCRIPT." >&2
    exit 3
fi

# ---------------------------------------------------------------------------
# Simulate
# ---------------------------------------------------------------------------
echo ""
echo "[2/2] Simulating $TOP..."
VSIM_TRANSCRIPT="$ABS_BUILD_DIR/vsim.transcript"

if ! "$VSIM" \
        -c \
        -lib "$ABS_BUILD_DIR/work" \
        "$TOP" \
        -do "$ABS_DO_SCRIPT" \
        2>&1 | tee "$VSIM_TRANSCRIPT"; then
    echo ""
    echo "ERROR: vsim simulation failed. See $VSIM_TRANSCRIPT." >&2
    exit 4
fi

echo ""
echo "============================================================"
echo "questa_run: DONE  ($TOP)"
echo "============================================================"
