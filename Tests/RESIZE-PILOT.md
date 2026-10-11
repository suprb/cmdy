# Untimed public resize pilot

`NativePerformance/compare_resize.py` reuses the qualified v2 resize observer,
worker, recorder and independent reader. It adds one supervised pair for the
exact frozen CMDY candidate and installed Ghostty binary. Preparation is
headless; only the explicit `run` command may launch apps or capture a display.
The plan pins its power source, binaries, Python runtime, compiled helpers,
source files and the reviewed activity supervisor.

Each owned process follows this fixed sequence:

1. Start the existing generated resize worker with a private control socket and
   isolated app configuration. Public window setup may fit the actual PTY to
   120×36 before the worker is prepared.
2. Write the unchanged 147,000-byte, 1,000-row generated history, separators and
   initial colored viewport. Discover all cells at 120×36 using the existing
   native display observer.
3. Derive one larger window request from that discovered cell pitch and actual
   display scale. Arm generation 1 and make one public resize to 132×40. A wrong
   actual PTY grid or outer bounds is fatal; fitting and retries are unavailable
   after preparation. Discover the resulting 132×40 viewport and close the
   calibration observer.
4. Use those same-process, same-window calibrations in the unchanged diagnostic
   recorder. Generation 2 requests one public resize back to 120×36. The reader
   validates all 4,320 observed cell classes, the actual final PTY dimensions,
   first-match chronology, 50 ms stability, display mode, native process/window
   ownership and worker signal/write causality.
   A source-frame verification waits for the new observer's actual pixels before
   arming; stream startup alone does not establish that pixels have arrived.
5. Finish the worker and reap the two owned observers, app and worker. Retain
   cleanup receipts and remove only the launcher's private temporary directory,
   control directory and generated CMDY defaults suite. Generated evidence is
   retained in the pilot directory.

Calibration happens only during the reserved native slot. No historical or
synthetic calibration can replace the current live discoveries. A failed
calibration leaves raw requests, native output and cleanup records for review.

Window admission protects the complete outer rectangle. A failed native check
now retains the same query's public window IDs, owner PIDs, layers, bounds and
front-to-back indices in `windowGeometry`, including the blocking indices.
It records no titles or unrelated pixels and grants no overlap exception.
Earlier error-only failures cannot identify their blockers retrospectively.
Changed native helpers require fresh source-bound build receipts.

The cleanup reader distinguishes a successful defaults deletion from an
already absent generated suite. The latter requires both a parsed empty plist
from export and the exact owned-domain `not found` deletion diagnostic; other
deletion errors remain failures.

The shared supervisor requires both hardware and combined-session input idle
clocks to reach 300 seconds before launch. It stops the owned controller if
session input resumes and restores the previous foreground app only while the
session remains quiet. The adapter checks again before setup, calibration and
the diagnostic event. Existing Accessibility and screen-capture grants are
required; neither helper requests permission. No clipboard or Apple Events
operation is used.

Prepare a new private output with the current binary and qualification pins:

```sh
python3 -B Tests/NativePerformance/compare_resize.py prepare \
  --candidate /absolute/verified-candidate \
  --resize-qualification /absolute/resize-qualification.json \
  --recorder-qualification /absolute/recorder-delta-qualification.json \
  --window-qualification /absolute/window-qualification.json \
  --activity-review /absolute/activity-review.json \
  --ghostty-sha256 EXPECTED_SHA256 --power-source 'AC Power' \
  --display-id 1 --output /absolute/new-resize-pilot
```

Run the frozen `tooling/Tests/NativePerformance/compare_resize.py` with the
plan's Python executable, action `run` and the same `--output` only during the
reserved native slot. Existing execution records cannot be overwritten.
`audit-cleanup --output …` is read-only and rejects missing cleanup receipts,
remaining owned PIDs, private directories or unproved defaults cleanup. It
does not discover unrelated processes, signal anything or delete files.

This pilot validates a generated-cell resize path. It does **not** prove that
the full history remains retained, text glyphs are correct, or CMDY is faster.
The [standalone admission boundary](TERMINAL-RESIZE-BENCHMARKS.md) remains
blocked. A separate complete-campaign reader now exists; it does not admit this
pilot. Both statistical sample counts are zero. The existing
event schema marks the diagnostic `warmup:true` so it cannot become a measured
event later; it is not part of a statistical warmup batch. Raw Mach/SCK clock
differences remain diagnostic-only. The untimed finalizer cannot enter the
performance gate.
