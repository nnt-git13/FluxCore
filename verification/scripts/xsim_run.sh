#!/usr/bin/env bash
# verification/scripts/xsim_run.sh
#
# Vivado xsim simulation backend — API-compatible replacement for questa_run.sh.
#
# Usage (identical to questa_run.sh):
#   xsim_run.sh <build-dir> <filelist> <do-script> <top-module>
#
# Arguments:
#   build-dir    Directory for compiled outputs (will be created).
#   filelist     File listing sources (repo-relative paths, one per line).
#   do-script    Questa .do script path — accepted for API compatibility, ignored.
#                xsim uses --runall, which is equivalent to "run -all; quit -f".
#   top-module   Top-level module name.
#
# Environment overrides:
#   XVLOG    Path to xvlog binary  (default: Vivado 2023.1 install)
#   XELAB    Path to xelab binary  (default: Vivado 2023.1 install)
#   XSIM     Path to xsim  binary  (default: Vivado 2023.1 install)
#
# Differences from Questa flow:
#   questa_run.sh: vlog → vsim (elaboration + simulation in one step)
#   xsim_run.sh:   xvlog → xelab → xsim (three distinct steps)
#
#   xvlog compiles into xsim.dir/ inside the build directory.
#   xelab elaborates the compiled design and produces a named snapshot.
#   xsim runs the snapshot to completion.
#
# Pass/fail detection:
#   xsim exits 0 even when $fatal fires, so the transcript is checked for
#   $fatal / FATAL / "simulation failed" patterns, and exit 4 is returned.
#
# Exit codes (same convention as questa_run.sh):
#   0  Simulation completed (pass or finish).
#   1  Wrong number of arguments.
#   3  Compilation or elaboration error.
#   4  Simulation failed ($fatal detected or xsim exited nonzero).

set -euo pipefail

VIVADO_BIN="/home/lnx-141209/Vivado/2023.1/bin"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
if [[ $# -ne 4 ]]; then
    echo "ERROR: xsim_run.sh requires exactly 4 arguments." >&2
    echo "Usage: xsim_run.sh <build-dir> <filelist> <do-script> <top-module>" >&2
    exit 1
fi

BUILD_DIR="$1"
FILELIST="$2"
# $3 is the .do script — accepted for API compat, not used by xsim
TOP="$4"

# ---------------------------------------------------------------------------
# Locate tools
# ---------------------------------------------------------------------------
XVLOG="${XVLOG:-$VIVADO_BIN/xvlog}"
XELAB="${XELAB:-$VIVADO_BIN/xelab}"
XSIM="${XSIM:-$VIVADO_BIN/xsim}"

for tool in "$XVLOG" "$XELAB" "$XSIM"; do
    if [[ ! -x "$tool" ]]; then
        echo "ERROR: tool not found or not executable: $tool" >&2
        echo "       Set XVLOG / XELAB / XSIM environment variables or check the Vivado install." >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# libtinfo compatibility (Vivado 2023.1 on Ubuntu 24.04)
# Vivado ships binaries linked against libtinfo.so.5; Ubuntu 24.04 has .6.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPAT_DIR="$REPO_ROOT/build/vivado-compat"
LIBTINFO6="/usr/lib/x86_64-linux-gnu/libtinfo.so.6"

if [[ -f "$LIBTINFO6" && ! -L "$COMPAT_DIR/libtinfo.so.5" ]]; then
    mkdir -p "$COMPAT_DIR"
    ln -sfn "$LIBTINFO6" "$COMPAT_DIR/libtinfo.so.5"
fi
if [[ -d "$COMPAT_DIR" ]]; then
    export LD_LIBRARY_PATH="$COMPAT_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
ABS_BUILD_DIR="$REPO_ROOT/$BUILD_DIR"
ABS_FILELIST="$REPO_ROOT/$FILELIST"

if [[ ! -f "$ABS_FILELIST" ]]; then
    echo "ERROR: filelist not found: $ABS_FILELIST" >&2
    exit 1
fi

mkdir -p "$ABS_BUILD_DIR"
cd "$ABS_BUILD_DIR"

XVLOG_VER=$("$XVLOG" --version 2>&1 | head -1)
echo "============================================================"
echo "xsim_run: $TOP"
echo "  build-dir : $BUILD_DIR"
echo "  filelist  : $FILELIST"
echo "  xvlog     : $XVLOG_VER"
echo "============================================================"

# ---------------------------------------------------------------------------
# Resolve filelist paths from repo-relative to absolute.
# xvlog resolves -f paths relative to CWD (= build dir here), so paths
# like "rtl/common/fluxcore_pkg.sv" would fail.  Rewrite to absolute.
# ---------------------------------------------------------------------------
ABS_FLIST="$ABS_BUILD_DIR/sources.f"
while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip blank lines and comments
    [[ -z "$line" || "$line" == \#* ]] && continue
    echo "$REPO_ROOT/$line"
done < "$ABS_FILELIST" > "$ABS_FLIST"

# ---------------------------------------------------------------------------
# Step 1: Compile
# ---------------------------------------------------------------------------
echo "[1/3] Compiling with xvlog..."
if ! "$XVLOG" --sv -f "$ABS_FLIST" 2>&1 | tee xvlog.log; then
    echo ""
    echo "ERROR: xvlog exited nonzero. See $ABS_BUILD_DIR/xvlog.log." >&2
    exit 3
fi
if grep -qiE "^ERROR" xvlog.log; then
    echo ""
    echo "ERROR: xvlog reported errors. See $ABS_BUILD_DIR/xvlog.log." >&2
    exit 3
fi

# ---------------------------------------------------------------------------
# Step 2: Elaborate
# ---------------------------------------------------------------------------
echo ""
echo "[2/3] Elaborating with xelab..."
if ! "$XELAB" -debug typical -timescale 1ns/1ps "work.$TOP" -s "${TOP}_snap" 2>&1 | tee xelab.log; then
    echo ""
    echo "ERROR: xelab exited nonzero. See $ABS_BUILD_DIR/xelab.log." >&2
    exit 3
fi
if grep -qiE "^ERROR" xelab.log; then
    echo ""
    echo "ERROR: xelab reported errors. See $ABS_BUILD_DIR/xelab.log." >&2
    exit 3
fi

# ---------------------------------------------------------------------------
# Step 3: Simulate
# ---------------------------------------------------------------------------
echo ""
echo "[3/3] Simulating with xsim..."
"$XSIM" "${TOP}_snap" --runall 2>&1 | tee xsim.log
XSIM_EXIT=${PIPESTATUS[0]}

# xsim exits 0 even when $fatal fires; scan the transcript.
if [[ $XSIM_EXIT -ne 0 ]] || grep -qE '\$fatal|FATAL:|Fatal:|simulation failed' xsim.log; then
    echo ""
    echo "FAIL: $TOP — see $ABS_BUILD_DIR/xsim.log" >&2
    exit 4
fi

echo ""
echo "============================================================"
echo "xsim_run: DONE  ($TOP)"
echo "============================================================"
