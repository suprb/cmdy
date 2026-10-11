# Four-pane input under concurrent output

`four_pane_bench.py` compares synthetic key response in one pane while three
other panes each consume a paced 4,000,000-byte/second ASCII stream. Both apps
must have a visible 2 × 2 layout, with **60 columns × 18 rows in every pane**,
Menlo Regular at 14 points, identical power settings and the same display.
It uses the canonical isolated `matched` or `cmdy-defaults` launch profile;
the latter retains the documented font and isolation exceptions. Setup uses
public split/focus/equalize shortcuts and a raw PTY fixture.

The controller and reader are integrated, with headless tests in CI. Native
layout calibration and a current-app comparative run are still required.
Synthetic fixtures test the reader and never establish application speed.

## Build and run

Build these tools before reserving an exclusive foreground measurement interval:

```sh
swiftc -O Tests/TerminalBenchWindow.swift -o /path/to/terminal-bench-window
swiftc -O -parse-as-library Tests/ScrollWindowGeometry.swift Tests/FourPaneSetup.swift -o /path/to/four-pane-setup
swiftc -O -parse-as-library Tests/TerminalInputObserver.swift -o /path/to/input-observer
/path/to/input-observer --self-test-clock
shasum -a 256 /path/to/input-observer
```

Use explicit, qualified app executables and the recorded observer hash:

```sh
python3 -B Tests/four_pane_bench.py \
  --cmdy-bin /path/to/cmdy.app/Contents/MacOS/cmdy \
  --ghostty-bin /Applications/Ghostty.app/Contents/MacOS/ghostty \
  --window-helper /path/to/terminal-bench-window \
  --setup-helper /path/to/four-pane-setup \
  --observer /path/to/input-observer \
  --observer-sha256 <recorded-observer-sha256> \
  --profile matched --blocks 6 --samples 40 \
  --output /path/to/new-four-pane-run
```

The output directory must be new. No permission prompt is opened. The native
helpers require existing Accessibility, event-posting and screen-capture access.
The run switches foreground windows; reserve the desktop before executing it.
Keep keyboard/mouse activity paused and all four panes unobscured. Run a
separate one-block pilot first to verify the public bindings, captured landmark
orientation, exact pane geometry, marker visibility and sustainable load.
Pilot records cannot meet the paired-block gate and must not be pooled into the
full run. Repeat the full protocol separately for each required profile/power
scenario. The harness records actual power; it does not change power settings.

## Raw evidence contract

Each busy pane offers one 40,000-byte chunk every 10 milliseconds. At most one
chunk may be pending, and delayed service cannot create catch-up bursts.
Busy producers use a one-shot Darwin `kqueue` timer with minimal coalescing;
the timer changes producer wakeups only and is closed during cleanup. The
controller confirms actual output before starting the five-second settling wait.
All offer and write receipts are retained. Five seconds of settling are
required after each stream's first actual offer. During the entire observer
interval, conservative completed-byte bounds must stay within 98–102% of the
registered rate; each complete one-second bucket must stay within 90–110%.
The maximum uncertainty from writes crossing the interval boundaries is
80,000 bytes. Offered bytes alone do not prove service or justify a valid run.

The shared schema-3 `TerminalInputObserver` records the first matching frame for
each key. The reader uses the common gate's UInt32 timebase and UInt64 tick
checks, recomputes durations and signed callback offsets, and requires each
key receipt and native clock to fall inside the measured busy-load interval.
A callback before the frame's display timestamp is valid. The endpoint remains
the first matched display timestamp, and percentiles are rebuilt from raw keys.
Private schema-2 observer records remain descriptive.

Retained evidence includes source/helper/executable hashes, canonical launch
configurations and isolated environments, the layout PNG and derived capture
region, power/focus/geometry records, four distinct worker/TTY identities,
complete stream and key receipts, and exact terminal/descriptor restoration.
All workers save their final geometry and restore their TTY before any worker
exits. A token-bound release file binds all four final-record hashes; each worker
retains its release/exit receipt. This prevents closing one split from resizing
another before its final record. Missing, premature or timed-out releases are
rejected. Original worker processes must exit before app cleanup. Layout rectangles must
be finite, disjoint, equal, correctly ordered and inside the captured image.
The reader hashes the PNG and validates recorded rectangles; native pilot
inspection is still needed to verify the raster interpretation. Setup rejects
occluding windows, and the observer checks focus during key sampling. There is
no continuous desktop-occlusion monitor in this adapter.

Supply the directory to [the common gate](PERFORMANCE-PARITY.md) with pinned
CMDY and Ghostty executable hashes. It can fill only `input/four-pane` p50 and
p95 for that one scenario. The unchanged minimum is six counterbalanced pairs
and 40 keys per app/block. Missing, malformed, duplicate, slower or unresolved
evidence cannot produce an overall pass.

This measures synthetic key-to-WindowServer-frame latency under a specific
ASCII load. It does not measure physical keyboard-to-photon latency, paste,
Vim, Unicode throughput or terminal raster correctness in general.

```sh
python3 -B -W error::ResourceWarning -m unittest discover -s Tests -p 'test_four_pane*.py'
```
