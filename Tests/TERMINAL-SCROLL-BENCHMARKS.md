# Native three-row scroll benchmark

The runner and raw reader are available in the repository. Native calibration
and comparative results for the current app are still missing. Headless tests
exercise the protocol and invented archives; they are never performance evidence.

`scroll_bench.py` measures one discrete line-unit wheel event to the
WindowServer timestamp of the first complete generated viewport after exactly
three rows of movement. It uses fresh CMDY/Ghostty processes, a 120×36 grid,
system Menlo Regular 14 pt, and 1,000 generated primary-buffer rows. Each row
contains 42 solid-color barcode cells plus deterministic ASCII glyph work.
The matcher checks all 36 row identities and their full vertical bands. It does
not claim OCR verification of arbitrary text or physical wheel-to-photon latency.

Two excluded upward warmups move away from the live bottom. Each measured block
then has 20 upward and 20 downward events, three rows each, without reaching a
scrollback edge. Six paired blocks alternate which app runs first. The first
correct frame remains the endpoint; a changed viewport afterward invalidates
the sample. Validation requires at least two later distinct complete frames
spanning 250 ms. Idle capture statuses cannot substitute for those frames.

The matched profile adds `scroll-speed = 1` for CMDY and
`mouse-scroll-multiplier = discrete:1` for Ghostty. Both must use identical
calibrated event magnitudes. The documented CMDY-defaults profile retains each
app's scroll settings; calibration can select different magnitudes only if
one event performs the same three-row work. The runner validates Ghostty's exact
isolated configuration and queries its installed defaults using public CLI
actions. It does not infer live settings from the written file alone:
bidirectional native calibration remains mandatory and is excluded from timing.

Every event checks the real TTY grid, owned app/worker identities, repeated
kernel ancestry, foreground, window geometry and display. Capture is restricted
to the owned main window. The geometry guard permits same-owner ancillary chrome
only when it fits wholly above the viewport boundary reconstructed from all
36 generated rows; an unrelated overlapping window remains invalid. The raw
fixture stays silent while scrolling, rejects unexpected PTY input, and records
restoration of its terminal mode and file flags before exiting. The benchmark
does not use the clipboard. Existing isolation, font and defaults exceptions
remain those in [TERMINAL-BENCHMARKS.md](TERMINAL-BENCHMARKS.md).

## Build and headless checks

Run the pure contracts and owned PTY lifetime tests without opening apps:

```sh
python3 -B -W error::ResourceWarning -m unittest discover -s Tests -p 'test_scroll*.py'
python3 -B Tests/test_bench_ancestry.py
python3 -B Tests/test-scroll-native.py --output /path/to/new-scroll-build
```

The final command runs synthetic Swift matcher, raster/clock, capture-status,
geometry and CGRect wire-format checks and compiles `scroll-observer`. It does
not execute the observer. Its output directory must be new. CI runs the same
checks without preserving a benchmark result.

Build the shared window helper separately:

```sh
swiftc -O Tests/TerminalBenchWindow.swift -o /path/to/window-helper
```

## Native calibration and comparison

The following command requires an uninterrupted foreground interval on the
selected power source. It launches the supplied apps, captures the owned windows
and posts synthetic wheel events. Use a separately qualified app, its exact
source manifest/root, and explicit executable hashes. Keep compilation and
other CPU-heavy work outside the comparison.

```sh
python3 -B Tests/scroll_bench.py \
  --output /path/to/new-scroll-evidence \
  --cmdy-bin /path/to/cmdy.app/Contents/MacOS/cmdy \
  --ghostty-bin /Applications/Ghostty.app/Contents/MacOS/ghostty \
  --cmdy-sha256 <cmdy-executable-sha256> \
  --ghostty-sha256 <ghostty-executable-sha256> \
  --cmdy-source-manifest /path/to/app-build-source-manifest.json \
  --cmdy-source-root /path/to/matching-source-root \
  --observer /path/to/new-scroll-build/scroll-observer \
  --window-helper /path/to/window-helper \
  --display-id <display-id> --power-source 'AC Power' --profile matched \
  --calibration-only
```

Start with the unpooled capability check above. A full comparison uses a new
output directory and omits `--calibration-only`; it repeats calibration before
collecting the fixed paired blocks. Preserve every failed attempt. If no
one-event three-row mapping or complete stable raster can be established, the
case remains unqualified. Do not relax the pixel, event or stability contract.

## Raw evidence and the common gate

Pass the completed evidence directory to `Tests/parity_gate.py --evidence` with
the same executable pins. `scroll_parity_evidence.py` validates manifest schema
1, native scroll report schema 2 and public-configuration proof schema 2. These
are distinct from the keyboard observer's schema. It reconstructs durations
using bounded UInt64 clocks and UInt32 Mach timebase components, preserves
signed callback offsets, and rejects incomplete, changed, diagnostic or
calibration-only records. It reads trusted repository code; it does not execute
code from an evidence directory or trust a summary's claimed duration.

Only the [common policy](parity-policy.json) decides p50/p95 parity. All four
power/profile scenarios remain required; a passing scroll case cannot fill or
offset another missing or losing metric. Private raw directories contain
isolated launch/environment records and should not be copied wholesale into
public reports.
