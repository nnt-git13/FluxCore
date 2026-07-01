"""FluxCore infrastructure-level project configuration.

This module captures fixed architectural invariants established at project
inception. These values describe the baseline design target; they are not
runtime-configurable and should not change without a deliberate architectural
decision.

This is NOT the architectural reference model. The reference model will be
implemented in a separate module once the baseline ISA contract is frozen.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class FluxCoreConfig:
    """Immutable baseline configuration for the FluxCore processor."""

    # Data path width in bits. RV32I baseline.
    xlen: int = 32

    # Number of pipeline stages (Fetch, Decode, Execute, Memory, Writeback).
    pipeline_stages: int = 5

    # Number of instructions issued per cycle. Single-issue in-order baseline.
    issue_width: int = 1

    # Number of hardware thread contexts in the initial implementation.
    baseline_threads: int = 1

    # Number of hardware thread contexts in the planned multithreaded design.
    planned_threads: int = 4


# Module-level singleton for import convenience.
# All project code should import this instance rather than constructing
# new FluxCoreConfig objects, to ensure a single authoritative source.
PROJECT_CONFIG = FluxCoreConfig()
