# Verification Results — Async FIFO UVM Testbench

Six test configurations run on **Siemens Questa 2025.2 / UVM 1.2**, all against the final `design.sv` / `testbench.sv` in this repo (post-fix: `a_full_empty_mutex` removed, `option.at_least = 10` coverage bar, occupancy × simultaneous-access cross coverage). Raw transcripts and `.ucdb` coverage databases for each run are in `results/<NN_test_name>/`.

## How to reproduce any of these

Compile Options and `run.do` per test are listed below and also saved alongside each result. Every run uses the same `run.do` template:

```tcl
onfinish stop
run -all
coverage report -summary -recursive
coverage report -detail -all
coverage save <name>.ucdb
exit
```

---

## Summary table

| # | Test | Compile Options | Matches | Errors | Assertions | Covergroup | Total Coverage |
|---|---|---|---|---|---|---|---|
| 01 | `async_fifo_basic_test` | `+UVM_TESTNAME=async_fifo_basic_test` | 48 | 0 | 7/7 (100%) | 80.00% | 90.00% |
| 02 | `fifo_full_pressure_test` | `+UVM_TESTNAME=fifo_full_pressure_test` | 85 | 0 | 7/7 (100%) | 86.66% | 93.33% |
| 03 | `fifo_empty_pressure_test` | `+UVM_TESTNAME=fifo_empty_pressure_test` | 135 | 0 | 7/7 (100%) | 86.66% | 93.33% |
| 04 | `fifo_random_stress_test` | `+UVM_TESTNAME=fifo_random_stress_test +WR_PERIOD=3 +RD_PERIOD=17` | 197 | 0 | 7/7 (100%) | 90.00% | 95.00% |
| 05 | `fifo_regression_test` | `+UVM_TESTNAME=fifo_regression_test` | 983 | 0 | 11/11 (100%) | 93.33% | 96.66% |
| 06 | `fifo_simul_boundary_test` | `+UVM_TESTNAME=fifo_simul_boundary_test +WR_PERIOD=3 +RD_PERIOD=17` | 365 | 0 | 7/7 (100%) | 86.66% | 93.33% |

Assertion counts differ across runs only because `fifo_regression_test` runs multiple sequences (each contributing its own `assert(it.randomize())` self-check) in one simulation, inflating the total count — every run shows **100% assertion pass rate**, and critically, **zero occurrences of the `PROTOCOL:`/`CDC:` `$error` messages** in any of the six transcripts. No assertion violations anywhere in the final, fixed codebase.

---

## Occupancy coverage (`cp_occ`) per test

| Bin | 01 basic | 02 full-pressure | 03 empty-pressure | 04 random-stress | 05 regression | 06 boundary |
|---|---|---|---|---|---|---|
| `empty_b` | 88 | 6840 | 159 | 23326 | 10286 | 20854 |
| `near_empty` | 37 | 91 | 2831 | 36 | 3020 | 29 |
| `mid` | 262 | 387 | 239 | 314 | 1268 | 150 |
| `near_full` | 203 | 907 | 66 | 264 | 6977 | 44 |
| `full_b` | 7 (Uncovered — below `at_least=10`) | 1179 | 3401 | 4452 | 5570 | 2937 |

All bins reach the `at_least = 10` closure bar in every test except `full_b` in the basic smoke test — expected, since that test uses uniform random delay `[0:3]` on both sides and was never intended to stress the full boundary (that's what tests 02/04/05/06 are for).

---

## Simultaneous-access cross coverage (`cross_occ_simul`) — the key finding

This is the most important result across the whole suite. Ten possible bins exist (5 occupancy states × {simultaneous access, no simultaneous access}). Here's which ones were ever covered, by any test, anywhere in the six runs:

| Cross bin | Covered by | Max hits seen |
|---|---|---|
| `<empty_b, no_simul>` | all six | 23326 (random-stress) |
| `<near_empty, no_simul>` | all six | 2743 (empty-pressure) |
| `<mid, no_simul>` | all six | 380 (full-pressure) |
| `<near_full, no_simul>` | all six | 892 (full-pressure) |
| `<full_b, no_simul>` | all six | 6840→ up to 5570 (regression) |
| `<near_full, simul>` | basic, full-pressure, random-stress, regression | 917 (regression) |
| `<mid, simul>` | basic, random-stress (7, below bar) | 28 (basic) |
| `<near_empty, simul>` | empty-pressure, regression | 112 (regression) |
| `<full_b, simul>` | random-stress, boundary | 814 (boundary) |
| **`<empty_b, simul>`** | **none — zero hits in all six tests** | **0** |

**`<empty_b, simul>` — simultaneous read+write while the FIFO is completely empty — was never observed once, across every directed test, every random regression, and the test built specifically to force it.** This is a strong, repeatable, cross-validated result rather than a single-run artifact, and is discussed as a known open item in the main [README.md](README.md#8-known-limitations--possible-extensions): either this combination is rarer than its `full_b` counterpart given how occupancy dynamics played out under every stimulus profile tried, or it may be structurally unreachable given the design's conservative empty-generation logic — closing it further would need either more targeted directed stimulus or a formal CDC analysis rather than additional simulation time.

---

## The one real bug: found, root-caused, and resolved

Test 06 (`fifo_simul_boundary_test`) is the run that originally exposed a genuine assertion failure in `a_full_empty_mutex` (`!(full && empty)`), before the assertion was diagnosed as an invalid unsynchronized cross-domain comparison and removed. Full root-cause narrative, waveform evidence, and the failed first fix attempt are documented in [README.md §4](README.md#4-a-real-bug-found-diagnosed-and-resolved). The transcript in `results/06_simul_boundary/qrun.log` reflects the **final, fixed** state — zero errors, zero warnings, 7/7 assertions passing.
