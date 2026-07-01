#!/usr/bin/env bash
# Local Vivado 2023.1 launcher for Ubuntu 24.04.
#
# Vivado 2023.1 expects libtinfo.so.5. Ubuntu 24.04 ships libtinfo.so.6.
# Keep the compatibility symlink in build/ so no system files are modified.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPAT_DIR="$REPO_ROOT/build/vivado-compat"
VIVADO_BIN="/home/lnx-141209/Vivado/2023.1/bin/vivado"
LIBTINFO6="/usr/lib/x86_64-linux-gnu/libtinfo.so.6"

mkdir -p "$COMPAT_DIR"
ln -sfn "$LIBTINFO6" "$COMPAT_DIR/libtinfo.so.5"

export LD_LIBRARY_PATH="$COMPAT_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$VIVADO_BIN" "$@"
