# Same-machine terminal benchmarks

`competitive-bench.sh` measures **raw PTY write through a validated DSR response**.
The terminal must process the payload and the subsequent cursor-position query
before the timer stops. This includes PTY backpressure, terminal parsing/model
work and the reply path. It does **not** show when a rendered frame became
visible, and must not be described as input latency or rendering FPS.

## Run and retain the evidence

Build or choose both app binaries separately. Keep other work quiet during the
timed run; keep the benchmark's single window frontmost. The harness never
builds CMDY or Ghostty and never changes power settings or installs fonts.

```sh
Tests/competitive-bench.sh \
  --cmdy-bin /path/to/frozen/cmdy.app/Contents/MacOS/cmdy \
  --ghostty-bin /Applications/Ghostty.app/Contents/MacOS/ghostty \
  --output /private/tmp/cmdy-comparison-20260907-continuous \
  --note 'On battery, Low Power Mode; no global power settings changed'
```

The output path must be new. Nothing removes it on success or failure. `--help`
lists options. `--prepare-only` writes metadata, the exact payload and example
configs without compiling a helper or launching a GUI. Normal runs compile the
small standalone `TerminalBenchWindow.swift` helper before sampling; use
`--window-helper /path/to/helper` to reuse a compiled copy.
Recompile older helpers before a qualifying run: the `conditions` command must
report native low-power mode and nominal thermal state before and after every
app run. These observations supplement the recorded `pmset` state and must
remain unchanged throughout the comparison.

Default sampling is four blocks. Each block launches one fresh process per
terminal, alternates which terminal runs first, waits 15 seconds to settle,
samples three seconds of idle CPU/RSS, performs one excluded warmup and three
measured drains, with an equal untimed 250 ms pause between drains. Both terminals
run the same fixture under `/bin/zsh -l` with
an isolated `.zshenv` that immediately execs Python. No user shell rc/history or
inherited API keys enter that fixture. The system `/etc/zshenv`, if present, is
still a system-owned part of shell startup.

For the line workload, use `--workload lines` and a different output directory.
It repeats 76 ASCII `A` bytes plus CRLF, truncated to the exact byte count.
`continuous` repeats `A`. Raw mode disables ONLCR, so both emulators receive the
same bytes. This definition intentionally differs from the older harness's
LF payload with terminal-driver translation. Do not pool results from both
harness versions.

`styled`, `unicode`, and `source` add synthetic build-log, mixed-script text,
and highlighted source workloads. They include true-color SGR, combining
characters, wide characters, emoji sequences and box/block characters. Each
repeats the exact pattern retained as `workload.patternHex` in the manifest.
These patterns always finish before the final ASCII padding, so no partial
UTF-8 character or escape sequence can consume the DSR footer. These are
processing workloads; they do not substitute for a live editor response test.

`--diagnostic-frame-trace` explicitly enables bounded phase logging in CMDY.
It is off by default and is never inherited from the caller environment.
Diagnostic results are labeled and cannot qualify performance parity.

## Profiles and geometry

`--profile matched` is a **minimal matched profile**, not CMDY's shipping
defaults. It disables CMDY ghost text, smooth cursor/scroll animation, shader,
sounds, shell integration and workspace sidebars. Both terminals use the
system-installed Menlo Regular at 14 points, an opaque window and a steady
cursor. The fixture hides the cursor while measuring. No bundled-only font or
font installation is needed, and no unexplained Ghostty cell-size adjustment
is applied. The helper verifies the resolved Menlo PostScript name, records
its system font file and SHA-256, and records active display modes.

`--profile cmdy-defaults` separately exercises CMDY's default appearance/UI
features. It still overrides the font for comparison and turns off session
restore, automatic error help and Marketplace checks. It uses the same raw
fixture, so it does not exercise a shell prompt, command assistance or shell
integration hooks. The effective config and isolated defaults export are
retained; describe these explicit exceptions when presenting that profile.

Without an explicit grid, an unmeasured CMDY calibration launch supplies its
ordinary window's actual row/column count. Ghostty receives that cell count as
its requested initial size. Both measured terminals must then report exactly
the same `TIOCGWINSZ` row/column count, before and after every drain. Alternatively
pass `--columns 100 --rows 30`; the helper can resize only the owned window with
public Accessibility APIs if the calling process already has that permission.
An explicit grid also places each measured window at screen coordinates
`120,120` before fitting it. Use `--display-id 1` to require that display on the
current machine; display IDs are machine/session-specific.
There are no permission prompts. A mismatch fails the comparison and retains
all evidence. The harness never changes `stty rows/cols` to fake a match.
Untimed `fit_grid` setup may make up to three activation attempts in total to
recover focus lost during a resize. Regular `window()` checks before and after
timing remain strict and never reactivate silently. Every check is retained in
`window-checks/`, including the actual response on failure; `geometry.json`
also retains failed attempts and subsequent setup recovery.
Explicit `window(activate=True)` setup activates once, then waits up to two
seconds for exactly one native window to appear while that app is frontmost.
Each polling response is retained; fixture-ready alone is not window-ready.
Both windows must also use the same display. When Accessibility is already
authorized, their top-left positions are aligned to the calibration window;
otherwise a display mismatch fails. Window metadata includes the display ID.

Outer window points, window IDs and reported PTY pixel dimensions are retained
separately. Native chrome and each renderer's cell rounding/line-height can
produce different outer pixel sizes for the same font and cell grid. Therefore
the drain comparison matches terminal rows/columns and font points, **not equal
total window pixels**. Frame-latency comparisons must also inspect the captured
content rectangle, display scale and refresh interval.

Both workloads use the primary screen and reset its history/screen outside
each timed span (`ED 3`, `ED 2`, home, then an untimed validated DSR). Terminal
scrollback capacity remains each implementation's native policy: CMDY uses a
line count; Ghostty expresses its limit in bytes. This comparison is not a
memory-capacity-normalized parser microbenchmark.

## Isolation, validity and artifacts

Each app gets a new config/XDG tree, a controlled working directory outside
the repository, and a unique CMDY defaults domain. Ghostty is launched with
`--config-default-files=false` and only the retained explicit config; its
auto-update is off. CMDY uses an empty Extensions directory, no Marketplace
receipts, disabled automatic error help, and an isolated update-state timestamp
to keep its existing 12-hour app-update cooldown from doing network work.
No model or network request is part of the workload. This is configuration
isolation, not a sandbox/network interception guarantee. No user preferences,
credentials or sessions are copied into evidence.

Only the exact `Popen` processes created by the harness and their verified
fixture descendants are terminated. A custom fixture's original start identity
and ancestry are checked before sending it a graceful termination signal. There
is no `killall`, global process-name diff, or app quit AppleScript. The original
frontmost app is reactivated afterward when it is still available. The helper
records only owned-window metadata; it does not capture unrelated window titles
or pixels. Caller apps and their windows are preserved. OS-level activation and
test windows can temporarily change foreground focus.

Every DSR reply must match the expected complete bytes, including ESC and the
final `R`. Each timed footer moves to a changing known cursor position before
requesting a report, so partial replies, echoed queries, extra bytes and stale
cursor reports fail. Payload generation/hash, screen reset, geometry checks,
file I/O and JSON serialization happen outside the measured span. The timer
uses `time.perf_counter_ns`, not wall-clock time. Host request time is retained
as separate diagnostic overhead.

Artifacts include:

- `manifest.json`: options, source commit/dirty status, binary/plist hashes and
  versions, harness hashes, Python/macOS/hardware, workload definition, notes,
  power/thermal/load state and completion/failure status. A source commit does
  not substitute for the hash of an independently packaged binary.
- `display-font-permissions.json`: font resolution, display modes and passive
  permission preflight. A zero display refresh rate means unavailable/variable;
  do not silently call it 60 Hz.
- `runs/<block>-<terminal>/`: actual configs, `launch.json` with exact app PID,
  fixture `ready.json`, geometry/window records, every raw `sample-*.json`,
  app log, idle CPU/RSS and cleanup records. Warmups are retained but excluded.
- `tooling/`: copies of the harness, fixture and helper source used for the run,
  including any uncommitted harness changes. Drain processes execute that
  frozen worker copy, and `launch.json` records its path and SHA-256. Reusable
  sessions without an explicit `BenchOptions.tooling_dir` first snapshot the
  worker inside their own run directory.
- `summary.json`: per-terminal medians/range, each paired block ratio and their
  median. It exists only after all runs pass. A changed power source or power
  configuration invalidates the comparison. Small samples remain descriptive;
  a favorable ratio alone is not a general claim about responsiveness.

`processLaunchToFixtureReadyNS` is a startup proxy, **not first visible frame**.
It includes process launch, shell/fixture startup and payload loading; it is not
a cold-boot measurement. Idle CPU uses the app PID's `ps` cumulative CPU-time
delta (10 ms resolution); RSS is that PID's resident set at each snapshot. These
exclude child processes and WindowServer, and are not GPU/physical-footprint
measurements. Inspect the raw records before interpreting a small difference.

## Separate visual-latency measurement

A fair external method uses the same owned launch/config/grid, a raw TTY
fixture that paints a sequence-specific high-contrast marker after a known
key, and identical `CGEvent.postToPid` injection for both terminals. Capture only
the owned window with ScreenCaptureKit. Compare the event-post interval on the
mach absolute clock with `SCStreamFrameInfo.displayTime` of the first complete
frame containing the expected marker; retain callback delivery time separately.
Apple defines that attachment as when WindowServer displayed the frame.

Call the result **synthetic-key-to-WindowServer-frame latency**. It excludes the
physical keyboard path and panel scanout/pixel response; it is not keyboard to
photon. Screen Recording and event-posting authorization, capture overhead,
display refresh/variable refresh, dropped frames and capture sampling limit
the measurement. Do not claim sub-frame resolution from frame polling or use
capture callback arrival as the display timestamp. Physical latency requires
external hardware/high-speed camera validation.

The shared Python API is `BenchOptions` and `TerminalSession`. An independent
fixture may supply `fixture_command` and `ready_path`; its ready JSON must
include `pid`, `ttyPath`, `rows`, `columns`, and optionally
`startedMonotonicNs`. The session leaves the fixture output directory absent
until the fixture creates it, then exposes `app_pid`, `grid()`,
`window(activate=True)`, and `fit_grid((columns, rows), allow_resize=True)`.
Window IDs/bounds and grid attempts are available before an observer starts.

Relevant primary documentation: [Ghostty configuration](https://ghostty.org/docs/config/reference),
[ScreenCaptureKit display time](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/displaytime),
[ScreenCaptureKit frame interval](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/minimumframeinterval),
[Apple's capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos),
and [CGEvent PID posting](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:)).

## Lightweight checks

```sh
python3 -m unittest discover -s Tests -p 'test_competitive_bench.py' -v
xcrun swiftc Tests/TerminalBenchWindow.swift -o /private/tmp/terminal-bench-window
/private/tmp/terminal-bench-window probe 14
bash -n Tests/competitive-bench.sh
```

The unit tests use pipes and fake processes. They do not launch terminal apps,
run a benchmark, mutate real credentials, or touch a user's defaults domain.
