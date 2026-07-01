# software/benchmarks — Sparse Computing Benchmarks

This directory will contain the primary scientific workloads that FluxCore
is designed to accelerate.

## Planned Benchmarks

| Benchmark              | Purpose                                               |
|------------------------|-------------------------------------------------------|
| `spmv_csr.c`           | Sparse Matrix-Vector Multiply in CSR format           |
| `pcg_solver.c`         | Preconditioned Conjugate Gradient solver              |
| `spmv_verify.py`       | Python reference for correctness checking             |
| `matrices/`            | Small sparse test matrices in CSR format              |

## Expected Measurement Points

Each benchmark run will record:

- Cycle count (from FluxCore performance counter).
- Instruction retirement count.
- IPC (retired instructions / cycles).
- Memory access count (reads and writes).
- Wall-clock time on the Zybo Z7.

These measurements must be saved in `reports/benchmarks/` with the
associated Git commit hash, Vivado version, and board configuration.

## Status: Not Yet Created

Benchmark programs require:

1. A functional, verified FluxCore pipeline (not yet implemented).
2. A working memory system (BRAM-backed, Milestone 2).
3. Performance counter CSRs (future milestone).
4. ARM PS host control for DDR data transfer (future milestone).

No benchmark code will be written until the baseline processor is verified.
