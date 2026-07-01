#!/usr/bin/env python3
"""FluxCore tool-availability checker.

Detects tools required for the FluxCore build and simulation flows.
Uses only the Python standard library.

Exit codes:
  0 — all required tools found (optional tools may still be missing)
  1 — one or more required tools are unavailable

Usage (standalone):
  python scripts/check_tools.py [options]

Usage (via Makefile):
  make check-tools
"""

import argparse
import shutil
import sys
from dataclasses import dataclass

# Column widths for the output table
_COL_NAME   = 28
_COL_STATUS = 10
_COL_PATH   = 48


@dataclass
class ToolSpec:
    name: str
    executable: str
    required: bool
    description: str


def _check(executable: str) -> str | None:
    """Return the resolved path, or None if not found."""
    return shutil.which(executable)


def _print_header() -> None:
    print()
    print(f"{'Tool':<{_COL_NAME}} {'Status':<{_COL_STATUS}} {'Resolved path / note'}")
    print("-" * (_COL_NAME + _COL_STATUS + _COL_PATH))


def _print_row(spec: ToolSpec, path: str | None) -> None:
    if path is not None:
        status = "FOUND"
        note   = path
    elif spec.required:
        status = "MISSING*"
        note   = f"required — {spec.description}"
    else:
        status = "not found"
        note   = f"optional — {spec.description}"

    print(f"{spec.name:<{_COL_NAME}} {status:<{_COL_STATUS}} {note}")


def _print_footer(missing_required: list[ToolSpec]) -> None:
    print()
    if missing_required:
        print("(*) Required tools are missing:")
        for spec in missing_required:
            print(f"    {spec.name}: {spec.description}")
        print()
        print("Install the missing tools or set their paths in config/tools.local.mk.")
    else:
        print("All required tools are available.")
    print()


def build_tool_list(
    *,
    vlog: str,
    vsim: str,
    vivado: str,
    yosys: str,
    riscv_prefix: str,
    python: str,
) -> list[ToolSpec]:
    """Build the list of tools to check with their requirement levels."""
    return [
        # --- Required for Python scaffold ---
        ToolSpec(
            name="python (scaffold)",
            executable=python,
            required=True,
            description="Python >=3.11; needed for models, tests, and scripts",
        ),
        # --- Required for RTL simulation ---
        ToolSpec(
            name=f"vlog ({vlog})",
            executable=vlog,
            required=False,
            description="Questa SystemVerilog compiler; needed for RTL simulation",
        ),
        ToolSpec(
            name=f"vsim ({vsim})",
            executable=vsim,
            required=False,
            description="Questa simulator; needed for RTL simulation",
        ),
        # --- Required for FPGA implementation ---
        ToolSpec(
            name=f"vivado ({vivado})",
            executable=vivado,
            required=False,
            description="Xilinx Vivado; needed for FPGA synthesis and implementation",
        ),
        # --- Optional generic synthesis ---
        ToolSpec(
            name=f"yosys ({yosys})",
            executable=yosys,
            required=False,
            description="Yosys; optional generic synthesis and structural checks",
        ),
        # --- RISC-V cross-compiler ---
        ToolSpec(
            name=f"{riscv_prefix}gcc",
            executable=f"{riscv_prefix}gcc",
            required=False,
            description="RISC-V cross-compiler; needed to build bare-metal programs",
        ),
        ToolSpec(
            name=f"{riscv_prefix}objcopy",
            executable=f"{riscv_prefix}objcopy",
            required=False,
            description="RISC-V binary conversion tool",
        ),
        ToolSpec(
            name=f"{riscv_prefix}objdump",
            executable=f"{riscv_prefix}objdump",
            required=False,
            description="RISC-V disassembler",
        ),
    ]


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Detect tools available in the FluxCore build environment.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--vlog",         default="vlog",                 help="vlog executable")
    parser.add_argument("--vsim",         default="vsim",                 help="vsim executable")
    parser.add_argument("--vivado",       default="vivado",               help="vivado executable")
    parser.add_argument("--yosys",        default="yosys",                help="yosys executable")
    parser.add_argument(
        "--riscv-prefix", default="riscv32-unknown-elf-", help="RISC-V toolchain prefix"
    )
    parser.add_argument("--python",       default=sys.executable,         help="python executable")
    args = parser.parse_args()

    tools = build_tool_list(
        vlog=args.vlog,
        vsim=args.vsim,
        vivado=args.vivado,
        yosys=args.yosys,
        riscv_prefix=args.riscv_prefix,
        python=args.python,
    )

    print("FluxCore — tool availability check")
    _print_header()

    missing_required: list[ToolSpec] = []
    for spec in tools:
        path = _check(spec.executable)
        _print_row(spec, path)
        if path is None and spec.required:
            missing_required.append(spec)

    _print_footer(missing_required)

    return 1 if missing_required else 0


if __name__ == "__main__":
    sys.exit(main())
