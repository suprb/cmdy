# CMDY performance parity gate

Current implementation, candidate qualification and collection order are tracked
in the active plan (`CURRENT-PLAN.md` in the private performance notes) and
campaign registry (`CURRENT-CAMPAIGN.json` in the private performance notes). This document and
`parity-policy.json` define the evidence contract; updating a plan does not
change the policy or qualify an older executable's samples for a newer build.

`parity_gate.py` reads raw results from the input, four-pane, PTY drain, memory and scroll harnesses.
It exits successfully only when every required metric in every scenario passes.
It never launches apps, changes power settings, deletes evidence, or accepts a
summary in place of the raw samples. The comparator and candidate executable
SHA-256 values must be supplied explicitly.

```sh
python3 -B Tests/parity_gate.py \
  --cmdy-sha256 <frozen-cmdy-executable-sha256> \
  --ghostty-sha256 <frozen-ghostty-executable-sha256> \
  --evidence /path/to/continuous \
  --evidence /path/to/lines \
  --evidence /path/to/local-response \
  --output /path/to/new-parity-report.json
```

The checked-in [policy](parity-policy.json) fixes the target at a CMDY/Ghostty
duration or resource ratio of **1.0 or lower**. There is no percentage allowance
for regressions and no aggregate score that cancels a losing workload with a
winning one. Four scenarios are required: battery and AC, each with the minimal
matched profile and the separately documented CMDY-defaults profile. That
defaults profile still has the isolation/font exceptions described in the
[drain harness documentation](TERMINAL-BENCHMARKS.md); it does not mean untouched
user configurations.

## Evidence and decisions

For the implemented input/drain adapters, the gate checks frozen tooling and
payload hashes, actual launch profiles, focus, display, final measured grid,
power consistency, complete paired blocks, key receipts or exact DSR replies,
sample counts, and binary identities. Input runs also require per-key grid
records and nominal native thermal state. Drain runs require native thermal and
low-power observations before and after every app run, as well as `pmset`
records. Older evidence without these checks remains descriptive.
Font, machine, display and power configuration must remain identical within a
scenario. Trace runs cannot qualify.

Input observations additionally require native observer schema 3: the explicit
Mach timebase, raw event/display/callback ticks, and per-key validation endpoint.
The reader recomputes each duration and signed callback offset, rejects clocks
outside that interval and overlapping key observations, and never substitutes
summary timings. A negative callback offset is permitted; the first matched
WindowServer timestamp remains the endpoint. Legacy observer reports without
these fields remain descriptive. This native report version is separate from
the surrounding schema-2 input-run metadata.

Each run supplies a nearest-rank p50 and p95. CMDY and Ghostty runs are paired
within counterbalanced blocks. A deterministic percentile bootstrap resamples
whole paired blocks to estimate the interval of the median paired ratio. The
default minimum is six blocks, with 40 keys or 20 measured drains per app per
block. Warmups remain in evidence and are excluded from these statistics.

- `pass`: the interval's upper endpoint is at or below 1.0.
- `behind`: the interval's lower endpoint exceeds 1.0.
- `inconclusive`: the interval crosses 1.0; repeat or improve before qualifying.
- `insufficient-samples`: the required independent blocks or samples are absent.
- `not-measured`: no accepted evidence exists for this case/scenario.
- Invalid evidence is reported separately and always prevents an overall pass.

These are per-metric 95% bootstrap intervals, with finite-sample limitations.
They are not a simultaneous statistical guarantee across the entire matrix,
and cannot prove superiority on every machine or future workload. Large numbers
of samples from one process cannot replace independent paired blocks. Historical
two-block measurements remain descriptive; older input records that lack the
new grid/font evidence are not silently upgraded to qualification.

## Coverage still required

The gate has adapters for input markers, instrumented Vim edits, five drain
workloads, native three-row scrolling, normalized process memory and settled idle CPU. Memory reports RSS and physical
footprint independently, at idle and after verified equal retained contents.
Every fresh-process idle baseline from the preregistered cases is included;
the gate cannot choose the most favorable one. Memory uses per-block
nearest-rank medians and the same paired-block bootstrap, with at least six
blocks. See [the memory protocol](TERMINAL-MEMORY-BENCHMARKS.md) for scope and
the separate raw-evidence validator.

Schema-3 memory runs add a separate five-second CPU interval after the initial
five-second settle. Cumulative native user/system CPU deltas are normalized by
the actual native sample interval, which must be between five and six seconds.
All three preregistered fresh-process intervals enter each block. CPU uses a
paired-block bootstrap of absolute CPU-rate differences, with an exact maximum
of zero; this handles valid zero counters without division by zero or invented
pseudocounts. A positive lower bound is behind, a nonpositive upper bound passes,
and a crossing interval is inconclusive. CPU is the terminal app process only;
the worker and WindowServer are excluded. Historical schema-2 memory records
cannot qualify idle CPU because their first interval includes settling.

The [scroll adapter](TERMINAL-SCROLL-BENCHMARKS.md) reconstructs each native
wheel-to-first-complete-viewport duration from raw Mach clocks. It requires
unpooled bidirectional calibration, six paired blocks of 40 events, all 36
generated row identities, exact three-row motion, and the original complete
frame/stability/ownership checks. A valid synthetic fixture only tests the
reader; it is not a native measurement. Scroll has no accepted current-app
comparison yet and remains `not-measured` until one is supplied.

The [four-pane adapter](TERMINAL-FOUR-PANE-BENCHMARKS.md) requires four exact
60 × 18 panes, a schema-3 first-frame clock report, real key receipts and
verified sustained service in three paced ASCII panes. It reconstructs the
load and timing from raw records, checks profile/process isolation and cleanup,
and fills only the two `input/four-pane` metrics in one scenario. Its native
layout pilot and current-app comparison remain pending.

The [paste adapter](TERMINAL-PASTE-BENCHMARKS.md) measures the public
clipboard-free insertion command with an exact 65,536-byte Unicode payload.
It requires a separate paired transport pilot, actual off/on bracket framing,
six process pairs with forty measured insertions each, and pixel-derived
acknowledgement of all 4,320 generated response cells. The reader reconstructs
the first complete frame from native clocks and rejects pilot-only output.
This metric includes public command dispatch; it does not measure Command-V or
clipboard retrieval. Its native pilot and current-app comparison are pending.

The [resize recorder](TERMINAL-RESIZE-BENCHMARKS.md) and diagnostic validator
exist, but whole-comparison admission remains blocked on verified public history
export and native calibration. First-visible startup still needs its dedicated
admitted adapter. All entries remain `not-measured` until accepted comparative
evidence exists. A CMDY-only pane stress run,
launch-to-fixture-ready proxy, or unmatched-history RSS value cannot satisfy
those entries.

Do not remove cases or lower sampling to obtain a green report. Add a case's
raw-data validator and correctness/normalization checks before accepting its
results. Larger grids and additional hardware should be added as explicit
scenarios/cases, with their own retained evidence.

`python3 -B Tests/test_parity_gate.py` checks decision and evidence failure modes
without a GUI or timed workload. CI runs these tests; repeatable comparative
performance qualification still requires a controlled native machine.
