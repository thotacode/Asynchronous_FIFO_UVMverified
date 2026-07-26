# Asynchronous FIFO — UVM Verification Project

A complete UVM testbench for a Gray-code-synchronized asynchronous (dual-clock) FIFO, built and run on **Siemens Questa 2025.2** via **EDA Playground**, using **UVM 1.2**.

This project demonstrates a full constrained-random / coverage-driven verification (CRV/CDV) methodology applied to a classic CDC (clock-domain-crossing) design: directed corner-case tests, constrained-random stress sequences, functional coverage with a real closure bar, bound-in protocol/CDC assertions, and — critically — a real assertion failure that was found, root-caused from waveform evidence, and correctly resolved.

---

## 1. Design Under Test

`design.sv` implements a 2-clock asynchronous FIFO:

- Configurable data width (`DW`, default 8) and depth (`DEPTH`, default 16, must be a power of 2)
- Independent write (`wr_clk`) and read (`rd_clk`) clock domains, each with its own active-low reset
- Binary write/read pointers converted to **Gray code** before crossing clock domains
- **2-flip-flop synchronizers** in each direction (write pointer → read domain, read pointer → write domain)
- `full` and `empty` flags are **registered outputs**, derived from comparing the local pointer against the synchronized remote pointer

### Why registered `full`/`empty`?

An earlier version computed `full`/`empty` combinationally, which fed back into the write-pointer logic and created a zero-delay combinational loop (Questa reported `Iteration limit reached`). Registering both outputs breaks the loop and matches the standard reference implementation (Cliff Cummings' async FIFO paper).

---

## 2. Verification Environment

`testbench.sv`, organized as a single `fifo_pkg` package plus two interfaces and a top-level module.

```
tb_top
 ├── wr_if / rd_if           (per-domain interfaces, driven directly, no clocking blocks)
 ├── async_fifo (DUT)
 ├── fifo_checker (bound into async_fifo — assertions, see §4)
 └── UVM environment (fifo_env)
      ├── wr_agent  → wr_driver, uvm_sequencer#(wr_item), wr_monitor
      ├── rd_agent  → rd_driver, uvm_sequencer#(rd_item), rd_monitor
      └── fifo_scoreboard (order-preserving check + occupancy/simultaneous-access coverage)
```

### Key design decisions

- **Two independent, unrelated clock periods**, runtime-configurable via `+WR_PERIOD=` / `+RD_PERIOD=` plusargs, so the same testbench can be swept across clock ratios without code changes.
- **Order-preserving scoreboard, not time-correlated** — the only correct model for an async FIFO, since there is no fixed latency relationship between the two domains to check against.
- **Non-blocking read monitor** — samples a `pending` flag every clock edge instead of parking on an extra edge, so back-to-back reads with zero delay are never missed.
- **`soft` base delay constraints** on sequence items, so stress sequences with their own hard inline constraints (e.g. `delay inside {[4:8]}`) can cleanly override the baseline without a solver conflict.
- **Scoreboard drives coverage sampling directly**, on every clock edge in either domain (via its own `virtual wr_if`/`virtual rd_if` handles), rather than only on transaction events — this is what makes a real `option.at_least` closure bar meaningful (see §5).

---

## 3. Test Suite (CDV + CRV)

| Test | Type | Purpose | Stimulus profile |
|---|---|---|---|
| `async_fifo_basic_test` | Baseline / smoke | General correctness | Uniform random delay `[0:3]` both sides, 50 items each |
| `fifo_full_pressure_test` | Directed (CDV) | Drive FIFO to **full** repeatedly | Writer bursty (`dist`-weighted toward `delay=0`), reader throttled `[4:8]` |
| `fifo_empty_pressure_test` | Directed (CDV) | Drive FIFO to **empty** repeatedly | Reader bursty, writer throttled `[4:8]` |
| `fifo_random_stress_test` | Constrained-random (CRV) | Long regression, sweepable clock ratio | Both sides bursty (`dist`-weighted), 1000 items each |
| `fifo_regression_test` | Combined CDV+CRV | Runs all four profiles above back-to-back in one env instance | Accumulates coverage across the full stimulus mix |
| `fifo_simul_boundary_test` | Directed, adversarial (CDV) | Force simultaneous read+write at occupancy extremes | Fully deterministic **zero-delay** sequences (`wr_zero_seq`/`rd_zero_seq`) on both sides, run at a steep clock skew (`+WR_PERIOD=3 +RD_PERIOD=17`) — this is the test that found the assertion bug in §4 |

Clock ratio is always a runtime plusarg, never hardcoded, so any of the above can be re-run at different write/read clock ratios to specifically stress the pointer-synchronization logic under different skews — this is the CDC-specific equivalent of a coverage-closure sweep, and it's how the bug in §4 was actually found (an equal-ratio run first suppressed occupancy excursions entirely, teaching that *rate mismatch*, not clock alignment, is what drives boundary behavior; the subsequent skewed + zero-delay run is what exposed the race).

---

## 4. A Real Bug Found, Diagnosed, and Resolved

This is the centerpiece finding of the project and worth documenting in full, because the process — not just the result — is the point.

### 4.1 The symptom

Under `fifo_simul_boundary_test` with `+WR_PERIOD=3 +RD_PERIOD=17` (steep clock skew, fully aggressive zero-delay traffic on both sides), the bound assertion `a_full_empty_mutex` (`!(full && empty)`) fired once, at t=117ns — the first and only assertion violation across the entire project, out of thousands of transactions and tens of thousands of sampled clock edges in every other test.

### 4.2 Root-causing it from the waveform

Direct inspection of `dump.vcd` around the failure showed exactly what happened:

```
t=85ns  (rd_clk edge): wr_ptr_gray_sync2 updates; empty_next (combinational) correctly goes to 0
t=105ns (wr_clk edge): full_next goes to 1 (writer has filled all 16 slots; reader hasn't read anything yet)
t=111ns (wr_clk edge): full (registered) updates to 1 — genuinely, correctly full
t=117ns:               ASSERTION FIRES — full=1, but empty (registered) is still 1
t=119ns (rd_clk edge): empty (registered) finally updates to 0
```

`full` becoming 1 at t=111ns was **completely correct** — the writer, running a zero-delay sequence, filled the FIFO before the much-slower reader (34ns clock period) ever issued a single read. The problem was `empty`: its combinational next-state flipped correctly at t=85ns, but the **registered** output only updates on the next `rd_clk` edge — which, at a 34ns period, didn't land until t=119ns. For that entire 34ns window, `empty` was stale, and the assertion sampled squarely inside it.

### 4.3 The real conclusion: it was the checker, not the DUT

`a_full_empty_mutex` compared `full` (native to `wr_clk`) and `empty` (native to `rd_clk`) directly in a single `@(posedge wr_clk)`-clocked assertion — an unsynchronized cross-domain comparison with no basis for expecting the two to agree at any given instant, since they are independently registered in two unrelated clock domains.

### 4.4 The fix attempt that made it worse

The first fix attempted was to add a dedicated two-flop synchronizer bringing `empty` into the `wr_clk` domain before comparing, mirroring the same discipline the DUT itself uses for its pointers. Re-running the identical test produced **three** violations instead of one. Waveform inspection confirmed why: the synchronizer added two more `wr_clk` cycles of lag on top of the lag that already existed, which **widened** the stale window from 8ns (t=111→119) to 18ns (t=111→129), rather than eliminating it. This is the key lesson: a synchronizer relocates a race, it does not remove one — there is no instant at which two independently-clocked registered signals can be safely compared without synchronizing the entire *comparison*, not just one operand.

### 4.5 The correct resolution

`a_full_empty_mutex` was removed entirely, with the reasoning documented in-line in `design.sv`. This property is not meaningfully checkable via a simulation-time SVA on two independently-clocked registered signals; it would require a dedicated static CDC tool (e.g. Questa CDC) rather than a testbench assertion. The remaining four assertions (`a_no_wr_when_full`, `a_no_rd_when_empty`, `a_wr_gray_onehot`, `a_rd_gray_onehot`) are each checked entirely within their own clock domain and remain valid. Re-running `fifo_simul_boundary_test` after the fix: **zero errors, zero warnings, all 7 remaining assertion checks pass.**

---

## 5. Functional Coverage

Implemented in `fifo_scoreboard` as `occ_cg`, sampled on **every clock edge in either domain** (not just on transaction events):

```systemverilog
covergroup occ_cg;
  option.per_instance = 1;
  option.at_least = 10;   // a bin needs 10+ hits to count as covered — a real bar,
                          // not the trivial default of 1.

  cp_occ: coverpoint occ {
    bins empty_b     = {0};
    bins near_empty  = {[1:2]};
    bins mid         = {[3:DEPTH-4]};
    bins near_full   = {[DEPTH-3:DEPTH-1]};
    bins full_b      = {DEPTH};
  }

  cp_simul: coverpoint simul_access {
    bins no_simul = {0};
    bins simul    = {1};
  }

  cross_occ_simul: cross cp_occ, cp_simul;  // occupancy state x simultaneous read+write
endgroup
```

### Why the original coverage claim needed tightening

The initial version used the default bin goal (a single hit marks a bin "covered"), and measured occupancy alone. That let a bin like `full_b` claim "100% covered" off of just 1–2 hits during a 50-transaction smoke test — a number that says almost nothing about whether a rare, timing-dependent CDC bug at that boundary would actually be caught. Two changes fixed this:

1. **`option.at_least = 10`** — every bin now needs real sample density, not a single lucky hit.
2. **`cross_occ_simul`** — crosses occupancy against "was a write and a read both accepted this cycle," directly measuring whether the design was ever stressed at its two hardest corners: simultaneous access while completely full, and while completely empty.

### What the cross coverage found

Across the full test suite, `<full_b, simul>` was eventually covered (814 hits, under the skewed zero-delay boundary test), but `<empty_b, simul>`, `<near_empty, simul>`, `<mid, simul>`, and `<near_full, simul>` remained at zero in every configuration tried, including the most aggressive one. This is a legitimate, reportable finding rather than a gap to be quietly closed: it's plausible these specific combinations are rarer than `<full_b, simul>` given how a fast writer dominates occupancy time under mismatched clock rates, and further targeted stimulus (or acceptance that some corners require formal analysis rather than simulation) would be the next step in a production environment.

---

## 6. Assertions (bound checker, `fifo_checker`)

Bound into `async_fifo` via `bind async_fifo fifo_checker #(.AW(AW)) fifo_checker_i (.*);` — no modification to the DUT's port list or internals required.

- `a_no_wr_when_full` — `full |-> !wr_en`, checked in the write domain
- `a_no_rd_when_empty` — `empty |-> !rd_en`, checked in the read domain
- `a_wr_gray_onehot` / `a_rd_gray_onehot` — the CDC-specific check: the Gray-coded pointer may only ever change by one bit per clock (`$onehot0(ptr ^ $past(ptr))`), checked entirely within each pointer's own clock domain
- ~~`a_full_empty_mutex`~~ — **removed** (see §4); an unsynchronized cross-domain comparison that cannot be meaningfully checked via simulation-time SVA

---

## 7. Results Summary

| Test | Matches | Errors | Notes |
|---|---|---|---|
| `async_fifo_basic_test` | 48 | 0 | Baseline pass |
| `fifo_full_pressure_test` | 85 | 0 | Reaches full repeatedly |
| `fifo_empty_pressure_test` | 135 | 0 | Reaches empty repeatedly |
| `fifo_random_stress_test` (WR=3ns, RD=17ns) | 197 | 0 | Long CRV regression |
| `fifo_regression_test` | 983 | 0 | Combined CDV+CRV, occupancy coverage 100% (5/5 bins, `at_least=10`) |
| `fifo_simul_boundary_test` (equal clocks, WR=RD=5ns) | 1997 | 0 | Occupancy plateaus mid-range; taught that equal rates suppress boundary excursions |
| `fifo_simul_boundary_test` (skewed, WR=3ns RD=17ns) | 365 | **1 (pre-fix) → 0 (post-fix)** | Found, root-caused, and resolved the `a_full_empty_mutex` cross-domain race (§4) |

**Note on the 1000-vs-197 match count in `fifo_random_stress_test`:** the write driver does not retry a write when the FIFO reports full — that sequence item's write attempt simply lapses and the sequence moves on. Under a fast bursty writer against a much slower reader, the FIFO is full a large fraction of the time, so most of the 1000 items never became real bus transactions. `Remaining=0` confirms every write that did happen was matched correctly in order — this is a driver characteristic (no backpressure retry), not data loss.

---

## 8. Known Limitations / Possible Extensions

- No `uvm_reg` register model (not applicable — this DUT has no register interface).
- No formal CDC tool run (Questa CDC/RDC) — simulation, even with clock-ratio sweeps and aggressive directed stimulus, can only expose pointer-crossing *timing/ordering* bugs; it cannot prove true metastability behavior, which is a physical rather than logical property. The removed `a_full_empty_mutex` assertion is a direct example of a property that needs a formal tool rather than a simulation-time SVA.
- Driver does not retry on `full`/`empty` backpressure — a one-line fix (`wait (!vif.full)` before driving) if full driver-level saturation is the goal of a given test.
- Four of the ten `cp_occ x cp_simul` cross bins remain uncovered even under the most aggressive stimulus tried (`<empty_b,simul>`, `<near_empty,simul>`, `<mid,simul>`, `<near_full,simul>`) — a legitimate open item for further targeted stimulus or acceptance as out-of-scope for simulation-based verification.

---

## 9. How to Run (EDA Playground)

1. Paste `design.sv` and `testbench.sv` into their respective EDA Playground panes.
2. Tools & Simulators: **Siemens Questa 2025.2**
3. Tick the **`uvm-1.2`** library checkbox.
4. Compile Options: `+UVM_TESTNAME=<test_name>` (add `+WR_PERIOD=<int> +RD_PERIOD=<int>` for clock-ratio sweeps).
5. Tick **"Use run.do Tcl file"** and use:
   ```tcl
   onfinish stop
   run -all
   coverage report -summary -recursive
   coverage report -detail -all
   coverage save <name>.ucdb
   exit
   ```
   (`onfinish stop` is required — without it, UVM's automatic `$finish` exits the tool before the coverage commands run.)
6. Check the transcript for the `[SB]` line and the coverage report; confirm no `$error` lines from `fifo_checker`.
