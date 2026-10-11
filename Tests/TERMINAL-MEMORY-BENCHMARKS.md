# Matched-history terminal memory evidence

`memory_bench.py` records fresh-process app RSS and physical footprint with identical generated history. `memory_parity_evidence.py` validates retained raw evidence and exposes both metrics to the separate parity decision policy. It does not declare performance parity or measure first-visible startup.

The checkout runner defaults to schema 4; `--post-sample-history` selects schema
5. The September 16 comparison (`2026-09-16-input-activity-memory.md` in the private performance notes)
uses the separately frozen, qualified schema-5 harness, including its recorded
runtime/cache/path and owned-window-origin corrections. That exact harness
passed a current-app two-terminal pilot and the full 36-launch collection.
The older direct-checkout scripts do not yet contain all of those corrections.
Untimed pilots supply no comparative samples. Full window/visual ownership and
complete retained-content checks remain required; file-only proofs are rejected.

## Build and check before measuring

From the repository root, prepare native helpers outside the source tree. Keep compilation and tests separate from timed measurements:

```sh
mkdir -p /private/tmp/cmdy-memory-tools
clang -O2 -Wall -Wextra Tests/TerminalMemorySnapshot.c -o /private/tmp/cmdy-memory-tools/terminal-memory-snapshot
python3 Tests/history_export_build.py --output /private/tmp/cmdy-memory-tools/public-history
swiftc -O Tests/TerminalBenchWindow.swift -o /private/tmp/cmdy-memory-tools/terminal-bench-window
python3 Tests/test_memory_bench.py
```

The C helper uses public `proc_pid_rusage(RUSAGE_INFO_V4)` and stable same-user process-start identities. It reports RSS, physical footprint and CPU counters independently. Its sample timestamps explicitly use converted `mach_absolute_time`, matching macOS Python `perf_counter_ns`.

September 17 correction: `ri_user_time` and `ri_system_time` must also be converted
from Mach absolute ticks using the recorded timebase. Earlier helper builds
incorrectly labeled those raw counters as nanoseconds (a 125/3 factor on this
Apple Silicon host). Historical byte-based memory results are unaffected, but
their absolute CPU rates must not be reused. The updated helper retains raw ticks,
exports `cpuTimeUnit: nanoseconds`, and is independently checked against
`process_time_ns` by `Tests/CMDYFinishing/resource_units.py`. CPU admission now
rejects legacy samples without the explicit unit declaration; regenerate them
with the corrected helper instead of relabeling old receipts.

The public Swift helper's `conditions` subcommand reads ProcessInfo power,
thermal, memory and processor metadata. Its native actions verify the owned
app, worker, real PTY, grid and foreground window. After every memory sample,
the public `write_scrollback_file:paste` binding sends the created file path
directly to that PTY. CMDY uses its normal `keybindings.json` store; Ghostty
uses its public configuration binding. The generated worker accepts only
bounded input within its registered private directory and validates the
complete generated file before retaining it. A posted key is intent, not proof
that an export succeeded. This transport does not access the OS clipboard.
`TerminalHistoryProbe.swift` and its legacy binary are unsupported and must
not be executed, including their other subcommands.

An already compiled window helper can be reused. Nothing compiles automatically. Every run retains the complete Python/Swift/C tooling set and copies all three native helper binaries into its own `helpers/` directory. The raw worker executes the retained source, and the runner executes the retained native binaries. The flat `tooling/` copy is runnable with a fresh `--output`, including after the original checkout moves. Source/helper/application hashes are rechecked at completion.

## Functional smoke, then counterbalanced samples

Use new output directories for every attempt; an existing directory is rejected before probing or writing. A one-block, one-case run is a plumbing smoke, not the final comparison:

```sh
python3 Tests/memory_bench.py \
  --cmdy-bin /path/to/frozen/cmdy.app/Contents/MacOS/cmdy \
  --window-helper /private/tmp/cmdy-memory-tools/terminal-bench-window \
  --memory-helper /private/tmp/cmdy-memory-tools/terminal-memory-snapshot \
  --history-helper /private/tmp/cmdy-memory-tools/public-history/history-export-native \
  --blocks 1 --cases primary-1000 \
  --output /private/tmp/cmdy-parity-20260908/memory-smoke-01
```

After both native retention adapters pass, omit `--cases` and use `--blocks 6` for all cases. `--profile matched` is the default; run `--profile cmdy-defaults` separately. Supply `--conditions-reference PREVIOUS_RUN/conditions-reference.json` from the same schema for another package/profile that must match the same power, thermal and machine state. `--diagnostic-frame-trace` explicitly marks results diagnostic and enables the app's startup/model/renderer trace. Diagnostic runs are rejected by the raw parity adapter.

The launcher uses both terminals' isolated profiles and a controlled `.zshenv` that execs the identical raw worker before user rc/history. Menlo Regular 14 pt, final 120×36, display 1, position 120,120 and strict foreground/window checks are shared. Only setup may activate or resize. Both profiles disable CMDY session restoration, automatic error help and Marketplace checks, and use empty Extensions directories. The `matched` profile additionally disables shaders, shell integration, ghost text and appearance effects. `cmdy-defaults` retains CMDY's other built-in settings while preserving these explicit isolation/font overrides; it does not mean the user's existing configuration. Ghostty receives the same isolated configuration in both profiles, including documented [`scrollback-limit = 100000000`](https://ghostty.org/docs/config/reference#scrollback-limit); both row cases stay below CMDY's existing 10,000-row limit. Neither user's settings nor system power/font configuration are changed.

Each terminal/case/block starts a fresh owned process. Terminal order alternates by block; three cases rotate and reverse across six blocks:

| Case | Output | Required retained content |
| --- | --- | --- |
| Primary 1,000 | 1,000 numbered 76-column CRLF rows | All 1,000 rows, exact normalized SHA256 |
| Primary 5,000 | 5,000 numbered 76-column CRLF rows | All 5,000 rows, exact normalized SHA256 |
| Alternate continuous | Enter alternate screen, 3,000,000 `A` bytes, clear visible alternate viewport, then 35 numbered rows | Exact 35 known rows in the active alternate screen; fresh primary was empty |

Memory is sampled after geometry setup, after a five-second idle settle, after a separate five-second settled CPU interval, then at requested offsets 0/1/5 seconds after the exact DSR completion. Actual offsets are retained: native guards and helper execution mean the first sample is not literally simultaneous with the response. There is one output drain per fresh process. DSR proves processing through a changing cursor destination, not display presentation. Raw `OPOST=0` is required; a retained `ONLCR` flag is inactive and does not transform bytes. Exact payload hashes/byte counts, DSR response, grid, source/binary/helper/font hashes, process identities, power/thermal states and load averages are retained. Samples stop on any validity failure.

Schema 3 identifies the extra `settled-idle-cpu-end` sample. Idle CPU uses the app's native cumulative user and system nanoseconds between `settled-idle-baseline` and that endpoint, divided by the actual native wall interval and expressed as CPU nanoseconds per wall second. The interval must be 5–6 seconds, allowing bounded guard overhead while normalizing elapsed time. The initial five-second settling interval is excluded. Nonnegative monotonic counters, stable process identity and the same phase guards are required; an exact zero is valid. This is app-process CPU only, with the worker separate and WindowServer unaccounted.

The public full-history export runs last, after every memory sample. Canonical
comparison changes CRLF to LF, strips per-row trailing spaces and leading/trailing
empty rows, then requires exact numbered rows and count. Original screen padding
is not claimed equal; actual nonempty generated content is. The alternate audit
also validates the complete generated payload and exactly 35 retained rows;
an additional all-`A` predecessor fails verification. Export-related allocations
occur after measurement. No clear/release memory case is included.

`summary.json` reports the app PID's RSS and physical footprint separately, with per-block ratios. Worker memory remains separately recorded and is never added to an overlapping parent counter. This does not attribute WindowServer/shared GPU memory or prove a leak. Equal content below both limits does not mean equal configured capacity. A retained-memory conclusion is unavailable until the public export adapter and the complete memory evidence pass for both terminals.

`launchProxyNS` is launch-to-raw-worker readiness. The PTY can run before native window presentation, and the runner fits final geometry afterward. It is not first-visible prompt or first-usable shell latency. First-visible startup remains a separate, unmeasured case until a screen-observed shell adapter is available.

## Raw validator and parity integration

```sh
python3 Tests/memory_parity_evidence.py \
  --evidence /path/to/completed/memory-run \
  --cmdy-sha256 PINNED_CMDY_SHA256 --ghostty-sha256 PINNED_GHOSTTY_SHA256 \
  --output /path/to/new-memory-adapter.json
```

The read-only `load_memory_evidence(directory, expected_binaries)` API returns one item for each available case/metric: `memory/idle/rss`, `memory/idle/physical-footprint`, `memory/1000-lines/rss`, `memory/1000-lines/physical-footprint`, `memory/5000-lines/rss`, `memory/5000-lines/physical-footprint`, and both corresponding `memory/alternate-continuous/...` cases. Every memory item has `kind: memory`, `metric: bytes` and `blocks[block][terminal]` arrays of raw app bytes. Each idle block includes every fresh-process baseline across every preregistered case. No favorable memory metric or idle case is selected.

Common metadata matches the input/drain adapters: `path`, `profile`, `power`, `binaries`, `grid`, `display`, `font`, `fontSHA256`, `displays`, `hardware` and `observerEnvironment`. The caller applies its minimum paired-block count, per-block median and bootstrap policy; successful raw validation is not a parity decision.

Schema-3 or schema-4 evidence containing all three preregistered cases additionally returns `idle-cpu`, with `kind: cpu`, `metric: cpuTime`, and three normalized CPU rates per app per block. The gate compares the per-block medians using paired absolute CPU-rate differences with a zero maximum, so zero counters need no pseudocount. It requires six paired blocks. Subset smokes cannot qualify idle CPU. Legacy schema-2 records remain memory-only and are never reinterpreted as settled CPU evidence.

The adapter supports historical schema 2/3 and current schema 4 with `benchmarkKind: memory`, complete requested pairs and actual counterbalanced launch order, pinned app SHA256 values, exact config/profile/font/display/grid, frozen tooling/helper hashes, exact generated payload/row hashes, stable process-start identities and retained parent chains, exact DSR bytes, successful cleanup, stable power and nominal thermal state, and native/host timestamps proving the history audit followed every memory sample. Schema 4 additionally joins the public export, owned file, worker arm/drain and cleanup records. Window retries during untimed setup may be retained; invalid/activating guards after setup are rejected. Missing/extra/invalid cases, partial pairs, diagnostics and legacy schema-1 pilot data fail closed. The qualifying schedule is fixed at a five-second baseline settle, a further five-second idle CPU interval for schema 3/4, and post-output 0/1/5-second samples; custom schedules remain descriptive.

Raw private session directories include isolated environment/config/discovery files and must not be copied into a public report. Export only allowlisted numerical samples, generated workload hashes, native verification booleans/hashes, conditions, versions and tooling hashes; never copy `cmdy-config/`, XDG/defaults exports, clipboard data or plugin discovery credentials.

Fresh-process launch measurements do not flush filesystem, dyld, shader or font caches. Window/focus guards bracket sampled phases; they are not a continuous screen observation. Public history export creates allocations only after measurement.
