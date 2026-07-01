# FluxCore Development Workflow

Every new feature or module follows this workflow. Do not skip steps or
compress multiple steps into a single commit.

---

## Feature Workflow

1. **Write or update the specification.**
   Document the module's interface, behavior, and edge cases in `docs/`.
   For architectural changes, write or update an ADR in `docs/decisions/`.

2. **Define module interfaces.**
   Specify the SystemVerilog port list and any package types the module
   uses. Review the interface with the existing pipeline stages before
   writing implementation code.

3. **Identify hazards and corner cases.**
   List all conditions that require special handling: forwarding paths,
   stall conditions, flush conditions, timing exceptions. Write these down
   before writing RTL.

4. **Write a model or expected behavior.**
   Add the expected behavior to the Python reference model in
   `models/fluxcore/`, or write a directed test program that exercises
   the new feature.

5. **Implement one module.**
   Write the handwritten SystemVerilog in the appropriate `rtl/` subdirectory.
   One module per file. Follow the existing naming and style conventions.

6. **Add directed tests.**
   Write a self-checking Questa testbench in `verification/unit/<stage>/`.
   Run it with `make questa-smoke` (or the appropriate test target).
   The testbench must use `$fatal` on failure and print PASS on success.

7. **Add randomized tests when appropriate.**
   For modules with complex state (register files, caches, scoreboards),
   add a randomized test sequence. Compare against the Python model.

8. **Run Questa.**
   All existing testbenches must continue to pass after the new module is
   added. Do not merge code that breaks previously passing tests.

9. **Integrate.**
   Connect the new module into the pipeline and run integration-level tests
   that exercise the module in context.

10. **Run synthesis when meaningful.**
    For non-trivial RTL additions, run Vivado synthesis (once the board model
    is confirmed). Record area and timing results.

11. **Record measured results.**
    Copy curated summaries to `reports/` following the policy in
    `reports/README.md`. Include the Git commit hash, tool version, target,
    and command used.

12. **Commit the completed milestone.**
    Commit with a clear message. Include the commit prefix appropriate
    to the change type (see below).

---

## Commit Prefix Conventions

| Prefix          | Use for                                           |
|-----------------|---------------------------------------------------|
| `docs:`         | Documentation only                                |
| `rtl:`          | SystemVerilog source changes                      |
| `verification:` | Testbenches, filelists, verification scripts      |
| `model:`        | Python architectural model or test changes        |
| `software:`     | Bare-metal programs, linker scripts, runtime      |
| `fpga:`         | Vivado scripts, constraints, board configuration  |
| `build:`        | Makefile, configuration files, build scripts      |

## Commit Message Format

```
<prefix>: short imperative description (≤72 chars)

Optional body explaining WHY this change was made. Reference the relevant
ADR or specification section. Do not describe WHAT the code does — the
code itself does that.
```

## CI Policy

Cloud CI is not configured because Vivado and Questa licensing environments
vary across development machines. The expected checks before any commit are:

```bash
make check          # Python tests, lint, type check
make questa-smoke   # RTL toolchain check (when Questa is available)
```

Run `make vivado-check` before any FPGA-related commit.
