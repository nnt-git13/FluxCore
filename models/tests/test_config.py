"""Tests for FluxCore fixed architectural invariants.

These tests assert properties that must hold throughout the life of the
project. A failure here indicates that a fundamental architectural constant
was changed without an accompanying design decision and documentation update.
"""

from fluxcore.config import PROJECT_CONFIG, FluxCoreConfig


class TestProjectInvariants:
    """Validate fixed project invariants against the baseline configuration."""

    def test_xlen_is_32(self) -> None:
        assert PROJECT_CONFIG.xlen == 32, (
            "FluxCore is a 32-bit processor (RV32I baseline). "
            "Changing XLEN requires a deliberate architectural decision."
        )

    def test_pipeline_stages_is_five(self) -> None:
        assert PROJECT_CONFIG.pipeline_stages == 5, (
            "FluxCore is a five-stage pipeline: "
            "Fetch, Decode, Execute, Memory, Writeback."
        )

    def test_issue_width_is_one(self) -> None:
        assert PROJECT_CONFIG.issue_width == 1, (
            "FluxCore is single-issue. "
            "Superscalar issue is explicitly excluded from the design."
        )

    def test_baseline_threads_is_one(self) -> None:
        assert PROJECT_CONFIG.baseline_threads == 1, (
            "The initial implementation is single-threaded. "
            "Hardware multithreading is future work."
        )

    def test_planned_threads_is_four(self) -> None:
        assert PROJECT_CONFIG.planned_threads == 4, (
            "The planned multithreaded design targets four hardware thread contexts."
        )

    def test_config_is_immutable(self) -> None:
        """FluxCoreConfig must be frozen (immutable dataclass)."""
        import dataclasses
        assert dataclasses.is_dataclass(FluxCoreConfig)
        # frozen=True dataclasses raise FrozenInstanceError on attribute assignment
        import pytest
        with pytest.raises((TypeError, AttributeError)):
            PROJECT_CONFIG.xlen = 64  # type: ignore[misc]

    def test_config_singleton_consistency(self) -> None:
        """The module-level singleton must match a freshly constructed default."""
        default = FluxCoreConfig()
        assert PROJECT_CONFIG.xlen == default.xlen
        assert PROJECT_CONFIG.pipeline_stages == default.pipeline_stages
        assert PROJECT_CONFIG.issue_width == default.issue_width
        assert PROJECT_CONFIG.baseline_threads == default.baseline_threads
        assert PROJECT_CONFIG.planned_threads == default.planned_threads
