# FluxCore Development Principles

These principles govern all implementation decisions. Violating them produces a
processor that is harder to verify, harder to synthesize, and harder to trust.

---

## 1. Workload-Driven Development

Every architectural feature must be justified by a real workload requirement.
Add features that CSR SpMV, PCG, or their supporting software actually need —
not features that seem useful in the abstract.

## 2. Correctness Before Optimization

A processor that executes programs incorrectly at high frequency is worthless.
Make it correct first. Measure it. Then optimize.

## 3. One Feature at a Time

Implement one module, verify it thoroughly, integrate it, and commit before
starting the next feature. Parallel incomplete implementations create
verification debt that compounds.

## 4. Unit Test Before Integration

Every module must have directed unit tests before it enters the integration
build. Do not rely on integration tests to catch module-level bugs.

## 5. Retirement-Trace Differential Testing

The Python architectural reference model is the ground truth. For every
non-trivial RTL change, compare the RTL retirement trace against the Python
model's expected trace. A mismatch is a bug in the RTL.

## 6. Synthesize and Measure After Meaningful Milestones

Run Vivado synthesis and implementation at every stable milestone — not just
at the end. Record the results in `reports/`. Early resource and timing data
prevents surprises at tapeout.

## 7. Never Invent Performance Numbers

Do not estimate, extrapolate, or invent performance, utilization, or timing
figures. Every number presented about FluxCore must be derived from a saved,
reproducible report. See `reports/README.md`.

## 8. Keep Generated Files Out of Source Directories

All synthesis outputs, simulation logs, compiled binaries, and generated
waveforms go under `build/`. The `rtl/`, `verification/`, `models/`, and
`software/` directories contain only handwritten source files.

## 9. Commit Stable Milestones Before Proceeding

A milestone is stable when:
- All unit tests pass.
- The retirement trace matches the Python model.
- `make check` passes cleanly.
- Vivado synthesis completes without critical warnings (when applicable).

Commit that state with a clear message before starting the next milestone.
Working on top of an unstable base amplifies debugging cost.

## 10. Document Decisions at the Time They Are Made

When you make a non-obvious architectural or implementation choice, write a
decision record in `docs/decisions/` at the time of the decision — not later.
Decision context decays rapidly; write it down while you understand the
trade-offs.
