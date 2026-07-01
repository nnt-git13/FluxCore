# Reports

This directory contains curated, source-controlled summaries of simulation and
synthesis results.

## Policy

### What belongs here

Concise, human-readable summaries that represent stable, reproducible milestones.
Examples:
- Synthesis resource utilization after a meaningful RTL milestone.
- Timing closure summary from a Vivado implementation run.
- Questa simulation pass/fail summary for a verification milestone.
- Benchmark performance results from a measured FPGA run.

### What does NOT belong here

- Raw generated files: these stay under `build/` and are git-ignored.
- Intermediate or incomplete results.
- Results you cannot reproduce from a specific commit.

### Required metadata

Every file saved in `reports/` must identify:

1. **Git commit hash** — the exact state of the repository that produced this result.
2. **Tool version** — the exact Vivado, Questa, or GCC version used.
3. **Target configuration** — board model, FPGA part, clock frequency.
4. **Command** — the exact `make` target or command that produced this result.

A result without these four items cannot be trusted or reproduced.

### Performance claim policy

**No performance number, resource utilization figure, or timing result is
valid for any purpose — including a resume, paper, or portfolio — unless it
is backed by a file in this directory that satisfies the metadata requirement
above.**

Never present estimated, extrapolated, or invented numbers as measured results.

## Subdirectories

| Directory          | Contents                                               |
|--------------------|--------------------------------------------------------|
| `simulation/`      | Questa simulation pass/fail and coverage summaries     |
| `synthesis/`       | Vivado synthesis resource and timing summaries         |
| `implementation/`  | Vivado place-and-route and timing closure summaries    |
| `benchmarks/`      | Benchmark performance results from FPGA runs           |
