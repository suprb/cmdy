# Native input and visible response checks

`input-latency-bench.py` measures synthetic key posting to the first matching
WindowServer frame from an isolated raw terminal fixture. It records individual
samples and the fixture's received-key sequence. An optional installed Vim
fixture measures its instrumented editing response. Neither fixture measures
a physical keyboard or monitor scanout.

## Build the observers before measuring

```sh
xcrun swiftc Tests/TerminalBenchWindow.swift -o /private/tmp/terminal-bench-window
xcrun swiftc -O -parse-as-library Tests/TerminalInputObserver.swift \
  -o /private/tmp/terminal-input-observer
/private/tmp/terminal-input-observer --self-test-clock
```

The last command runs 14 generated clock checks without initializing AppKit,
starting capture, posting input or inspecting an application. CI also passes
that transcript to the Python gate to verify signed offsets and large UInt64
tick values across the Swift/JSON/Python boundary.

The GUI checks require existing Accessibility, Screen Recording, and event-posting
access. They never open a permission prompt. Keep the test window foreground and
avoid builds or other deliberate load during a comparison. The helper controls
only the harness's own applications. Personal configuration, shell startup files,
sessions, extensions, and credentials are not copied into the test profile.

## Keep response workloads separate

The default `--marker-mode local-row` overwrites **eight cells on one row** with a
unique color for each key. This exercises a small terminal response. It is still
a synthetic raw-PTY workload, not ordinary text entry in a real application.

`--marker-mode full-screen` changes the background of the entire grid. This is a
full-grid redraw workload. A result from this mode must not be described as
ordinary typing latency or pooled with local-row results.

Both modes wait for sequence zero to be visible before posting keys. Each key
has a unique expected color; only one key is in flight. The observer checks only
the declared probe-pane interior. Local mode requires a solid matching patch
across at least three scanlines and 64 pixels. Full-screen mode requires at least
170 of 225 sampled pixels. Unrelated busy panes contain neutral text, not marker
colors. Each response has a five-second deadline.

```sh
python3 -B Tests/input-latency-bench.py \
  --cmdy-bin /path/to/frozen/cmdy.app/Contents/MacOS/cmdy \
  --ghostty-bin /Applications/Ghostty.app/Contents/MacOS/ghostty \
  --helper /private/tmp/terminal-bench-window \
  --observer /private/tmp/terminal-input-observer \
  --output /private/tmp/cmdy-input-baseline \
  --grid 120x36 --blocks 4 --samples 40 --marker-mode local-row
```

The apps use the same Menlo Regular 14-point font and measured PTY grid. Their
native chrome and cell rounding can produce different outer window sizes. The
harness places both windows on the same display and records geometry, scale,
display mode, power, thermal policy, binary hashes, and frozen tooling. It
alternates terminal order between blocks. An even number of blocks balances
which terminal starts first. Summaries use the median of block medians and the
median of block p95 values; individual observations remain available.

`--profile cmdy-defaults` separately uses CMDY's default appearance/UI features,
with the same explicit font/isolation exceptions as the drain harness. The
default remains `matched`. Each run now retains `grid-before.json` and
`grid-after.json`, and the fixture records the actual grid for every received
key. These are measured after resizing and pane setup; fixture readiness is not
evidence of the final grid. Font-file hashes and requested sample/block counts
are retained for the [parity gate](PERFORMANCE-PARITY.md).

`--diagnostic-frame-trace` enables bounded CMDY phase logging and marks the
entire result diagnostic. Keep it off for comparative timings.

Use a new directory for every run. `--conditions-reference /path/to/prior-output`
requires the same power and observer low-power/thermal conditions for a later
build or workload. Invalid runs retain evidence with `valid: false`; their
partial observations are diagnostic only. Existing output directories are never
modified. Do not pool results across changed power, thermal, display, font, grid,
fixture, or observer conditions.

The capture uses a scaled 640-pixel-wide ScreenCaptureKit stream requesting up to
120 fps. A request does not prove that cadence was achieved. The metric compares
`CGEvent.postToPid` timestamps with `SCStreamFrameInfo.displayTime` on the Mach
absolute clock. Capture callback delay is reported separately. Observer overhead,
WindowServer scheduling, display cadence, and other machine activity remain part
of the experimental limitations.

Native observer schema 3 records the Mach timebase and a validation-finished
timestamp for each key. The original first matched display timestamp remains
the endpoint. Callback delivery may precede that timestamp; its separately
reported offset is signed. Event posting, display and callback timestamps must
all lie within the recorded observation/validation interval, and successive
key observations must not overlap. No later frame replaces an invalid endpoint.

The runner and parity gate recompute durations and callback offsets from raw
ticks. Reported millisecond values must agree within floating-point conversion
precision; summary values cannot supply a faster duration. The gate's ratios,
sample counts and confidence requirements are unchanged. Older observer
schema-2 reports lack this clock evidence and remain descriptive; they must
not be filled in retrospectively or pooled into a qualifying new comparison.
The surrounding input-run metadata still uses schema 2.

## Installed Vim editor workload

`--fixture vim --marker-mode local-row` runs the installed `/usr/bin/vim` with
an explicit `/usr/share/vim/vim91` runtime (override both paths when necessary).
It opens a generated 1,001-line Swift buffer, enables the installed Swift syntax
rules, enters Insert mode and receives the same synthetic `a` keystrokes. User
vimrc/viminfo, packages, plugins, modelines and user source files are disabled.
The executable/version and Vim runtime script hashes are retained.

A small `TextChangedI` hook validates each edit and changes a status-line
background to its sequence color. The observer watches the lower window region;
Vim performs the editing and terminal output. This measures **Vim insertion to
its instrumented visible status response**, including the shared hook. It is
not uninstrumented Vim latency or proof about all editors. Final receipt hashes
and per-key grids must agree with every requested edit. The actual editor buffer
is generated exclusively for the fixture.

```sh
python3 -B Tests/input-latency-bench.py \
  --cmdy-bin /path/to/frozen/cmdy.app/Contents/MacOS/cmdy \
  --helper /private/tmp/terminal-bench-window \
  --observer /private/tmp/terminal-input-observer \
  --output /private/tmp/cmdy-vim-comparison \
  --fixture vim --grid 120x36 --blocks 6 --samples 40
```

`python3 -B Tests/test-editor-latency-worker.py` checks real edits, marker order,
resize receipts, unexpected input and signal cleanup on an owned PTY without a
GUI. It skips when the specified system Vim runtime is unavailable.

## Input while other panes produce output

Use `--terminals cmdy --panes 4` for a CMDY before/after stress case. The original
pane receives the marker keys; three panes run the same paced neutral-output
fixture, defaulting to 4,000,000 bytes/second each. The driver requires all three
to be ready before observing, and retains their actual accepted bytes, runtime,
stop status, and achieved rate. This is a CMDY-only stress comparison; it is not
a Ghostty comparison with a different pane layout.

```sh
python3 -B Tests/input-latency-bench.py \
  --cmdy-bin /path/to/frozen/cmdy.app/Contents/MacOS/cmdy \
  --helper /private/tmp/terminal-bench-window \
  --observer /private/tmp/terminal-input-observer \
  --output /private/tmp/cmdy-input-four-panes \
  --conditions-reference /private/tmp/cmdy-input-baseline \
  --terminals cmdy --panes 4 --blocks 2 --samples 40
```

## Native dead keys and Option-as-Meta

The repeatable smoke posts physical virtual-key events without overriding their
Unicode strings. It derives an acute-dead-key sequence from the current keyboard
layout with Carbon's `UCKeyTranslate`; it never changes the user's input source.
An isolated raw recorder verifies that the dead key emits no process bytes until
the following E, then receives exactly UTF-8 `é`. On the tested Swedish layout,
this is virtual key 24 then E (14); on US/ABC it is Option-E then E. The helper
records the layout and exact strokes rather than assuming they are universal.
It also checks ordinary ASCII, Ctrl-C, and Option-as-Meta's Escape-prefixed E.

```sh
xcrun swiftc -O -parse-as-library Tests/NativeInputSmoke.swift \
  -o /private/tmp/native-input-key
python3 -B Tests/native_input_smoke.py --app /path/to/cmdy.app \
  --window-helper /private/tmp/terminal-bench-window \
  --key-helper /private/tmp/native-input-key \
  --output /private/tmp/cmdy-native-input-smoke
```

This smoke complements the app's composition/focus self-tests. It does not
qualify every input method, candidate-selection interface, or keyboard layout.
The separate [drain harness](TERMINAL-BENCHMARKS.md) measures raw PTY output through
a validated DSR reply; those timings must not be labeled visible latency.
