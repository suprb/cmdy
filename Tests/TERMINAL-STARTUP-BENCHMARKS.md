# Native startup first-visible diagnostic

`startup_build.py` builds a real ScreenCaptureKit recorder and runs only generated
pixel, chronology, independent raw-evidence, and owned-PTY tests. It does not run
the recorder, inspect a display, request permission, launch a terminal app, or
send native events. Existing startup records and `parity-policy.json` stay
unchanged. A standalone record emits **diagnostic evidence only**. `--qualify`
fails before a launch. Only a complete prospective paired campaign can admit
its raw records through `startup_parity_evidence.py`.

The measured endpoint is
`native-spawn-to-first-complete-generated-viewport`: the earliest delivered
complete ScreenCaptureKit frame containing every cell of the fresh generated
viewport. The primary difference uses that frame's native `displayTime` and the
Mach tick immediately before the single owned `posix_spawn`. Arguments,
environment, C strings, working-directory actions, and signal dispositions are
prepared before this boundary. Launch return and capture callback lag are
separate signed diagnostics; a frame may precede the spawn call's return, and a
negative callback lag is preserved.

This is a warm-files startup workload: executable/input verification occurs
before launch. App startup, the configured `/bin/zsh -l`, isolated `.zshenv`,
Python startup, and generation of the fixture are included in the interval.
It is not a bare-window, interactive-shell-prompt, or cold-cache measurement.
Both terminals must use this identical workload in a separately declared
campaign before comparison. Historical prompt/perimeter records cannot be
pooled with this version.

## What the recorder observes

The full native-resolution display stream starts before the app. A complete
frame whose presentation and inspection clocks both precede spawn proves
prearming. At most eight early samples and their sanitized window geometry are
held while the spawned PID is bound; none are attached after the launch or
discarded to choose a later matching frame. Every delivered status and complete
frame stays in ordered chronology, with an exact one-to-one join.

The protocol-v5 fixture records the first kernel-observed foreground PTY grid
without replacing it with the configured target. If that grid already matches
the frozen target, it paints immediately. Otherwise it waits for a SIGWINCH wake
or bounded size recheck, then paints at the **first observed target size**. It
never restarts the native spawn clock, asks the parent or display for permission,
resizes the window, or accepts a DSR/readiness acknowledgment. Both apps generate
exactly one identical target viewport for a paired nonce. A size change after
the first target observation fails; repainting is forbidden.

Ready metadata is written once for both paths. There is no extra waiting-state
file write before painting. The target wait, worker startup, payload generation
and all offered bytes remain inside the original launch-to-frame interval.
The worker retains every ioctl observation and delivered SIGWINCH timestamp;
kernel signal coalescing is not represented as evidence of undelivered signals.
Write counters are derived at observation, write-start and completion timestamps,
so a notification during a blocked write cannot change an earlier counter.
The full final trace is captured after owned worker cleanup, separately from the
live trace joined to the displayed frame. The independent reader requires that
the live trace is an exact prefix and proves no later observed grid change.

The viewport paints every cell, including the last row and column, using
truecolor background spaces with autowrap disabled. The unchanged version-3,
42-cell pixel header encodes the launch nonce, target PTY columns/rows, and sole
generation 1. Independently reproducible nonce/grid/cell colors fill the interior;
a perimeter or final ioctl alone cannot pass.

The matcher infers all row and column boundaries in the same captured frame.
It checks every cell's interior pixels, with a fixed two-pixel boundary inset,
RGB tolerance of three, and opacity of at least 250. Cell pitches must be
5–100 pixels, their rounding variation at most two pixels, and the complete
outer perimeter must lie strictly inside the owned window crop. Only these
validated generated pixels are retained as lossless BGRA runs; unrelated
display pixels and window titles are never written. Limits are 10 million
checked pixels and 100,000 runs per proof, eight distinct proofs, 2,000 frame
or status records. V5 permits one worker generation, at most 64 delivered signals
and 512 recorded ioctl observations; overflow fails and remains recorded.

Protocol v5 requires the first complete viewport to equal the `targetGrid` frozen
in its launch spec. Preparation defaults to 98 × 29; `--columns` and `--rows`
declare a different bounded target before launch. Each comparative app pair must
use the same declared grid. Earlier protocol-v1/v2/v3/v4 records remain separate and
are never relabeled or inherited into a v5 cohort. The historical v4 gate and
reader are preserved at Git commit `42a88d8`; v5 requires fresh startup data in
all four power/profile scenarios. An earlier complete viewport with
another grid, a complete background viewport, or a later changing grid cannot
be silently replaced by a convenient final frame. Logical grid, generation, and
visibility must remain stable for one second after the later of the first
frame's display/callback clocks. Opening-window translation or scaling may change
the physical raster while retaining that first complete frame. Every later
delivered complete frame must still validate every generated cell, strictly
inside both bracketing owned window bounds. A failed cached raster is rediscovered
on that same sample; a failed full decode is never skipped. The bounded proof
inventory and pixel tolerances do not change.

Completion also requires at least 200 milliseconds of settled geometry. Unequal
bracketing bounds clear the settling clock; changed bounds or raster disagreement
beyond one pixel from the settling anchor reset it to the later of that frame's
display and checked clocks. Final ownership must match the latest complete
frame's bounds. The independent reader reconstructs both crop containments and
the settling clock from raw chronology; settling never replaces the first-frame
metric. Later incomplete, blank, restarted, suspended,
or stopped capture invalidates the record. The final ownership query, clock
validation, and capture freeze share one serial queue transaction.
If a retained capture status names a display instant ahead of the current final
query, capture continues within the existing 15-second deadline. Finalization
waits for that clock, retaining all frames and statuses; it neither clamps the
timestamp nor substitutes a later first frame. The strict final clock check
still applies, and a pending capture failure cannot be bypassed by finalization.
Prearming likewise checks the latest complete frame's display/check clocks and
sets launch preparation in one capture-queue transaction. A newer prelaunch
callback cannot replace a checked frame between readiness and arming. Future
prelaunch clocks wait within the five-second prearm bound, before any app spawn.

App PID, UID, executable path, and process start time are pinned and reread.
The owned window must be opaque, within the pinned display, unoccluded by any
front window intersecting its bounds, and foreground for the endpoint.
Ownership is observed around decoding and at the final guard. Kernel ancestry
is corroborated separately from foreground state. Each ownership query obtains
the system-wide `AXFocusedApplication` PID twice, around a diagnostic Cocoa read.
Both AX reads must be trusted, successful, positive and identical to authorize
foreground. API errors or changing PIDs yield unknown foreground, which cannot
admit a complete viewport. Native query clocks bind each frame's two ownership
proofs and the final guard to their exact AX receipts. The independent reader
reconstructs these joins. Cocoa's run-loop-dependent PID is retained only as a
diagnostic: repeated native tests found stale values even while both AX reads
identified the owned app. AX uses the existing grant with a 100 ms query timeout;
no permission prompt, focus change, element content or input event is requested.
The query inventory is bounded at 8,000. Kernel ancestry
is walked twice with full app/worker endpoint rereads. The ready nonce, Python
binary hash, controlling terminal device, foreground process group, generated
write bytes, and final PTY size corroborate the frame. An invalid initial size
is retained in the worker's `ready.json` even if generation 1 cannot be painted.
Failed live trials retain that raw size and any completed generations; an
already-exited worker's self-report is explicitly marked unverified. They never select its
timestamp. Display ID, mode ID/flags, logical and physical dimensions, refresh
rate, rotation, low-power state, and nominal thermal state are fixed; changes
fail. Cleanup targets only the created child and verified owned worker, restores
worker termios/flags, and records exact child reaping. SIGTERM to the wrapper
requests cooperative recorder cleanup before a bounded kill fallback; abrupt
failure cannot yield an eligible diagnostic. After native app/worker cleanup is
proved, the wrapper exports and deletes only its exact random
`com.cmdy.startup.<32 hex digits>` defaults suite, then verifies its absence.
No user suite is read or changed. Unproved process cleanup defers suite deletion
and invalidates the diagnostic, preserving the owned domain for investigation.
Owned process cleanup finishes before final diagnostic encoding and writing.
Bounded decoder-stage counters and nonce-verified header geometry explain where
an incomplete viewport stopped matching. When generated pixels match but window
ownership or geometry fails, the invalid receipt retains that pixel proof too.
These diagnostics neither select a later frame nor alter admission checks.
The capture configuration explicitly excludes the system cursor. The visibility
query uses the existing scroll observer's narrow exception for a cursor-level
window whose kernel-resolved owner is WindowServer; arbitrary overlays and apps
imitating that level still fail. Bounded cursor identity/query receipts corroborate
this exception. No other window is excluded from the capture or visibility check.
Absent first/prelaunch frames remain JSON `null`; an encoder failure preserves
the original observation error and actual cleanup result in an invalid receipt.
A refused output write still occurs after cleanup and cannot create a successful
receipt. The wrapper labels missing or invalid raw output explicitly and keeps
defaults cleanup deferred when that output cannot prove process cleanup.

## Headless qualification

Run this from the repository. Use a new output directory each time:

```sh
python3 -B Tests/startup_build.py \
  --output /private/tmp/cmdy-startup-headless-01
```

`results.json` binds the frozen tooling, existing shared helpers, policy,
compiler command/version, native executable, generated proof, tests, and
process cleanup receipts. The native executable is compiled but never invoked.
The generated Swift BGRA proof is independently decoded in Python, including
through a complete synthetic raw startup record. The seven owned-PTY tests launch
only the generated Python fixture on private pseudo terminals. They check
unprompted initial output, real resize generations, unexpected input, a blocked
partial first write, invalid geometry, exact bytes, and terminal restoration.
The raw negative suite covers missing prearming, skipped earlier frames,
corrupt interior pixels despite recomputed hashes, status gaps, lifetime/window
changes, visibility, clocks, false ancestry, PTY joins, and cleanup failures.
Generated finalization checks also cover absent frames, an injected encoder
failure, and a refused overwrite, with cleanup-before-output ordering. These
use synthetic cleanup callbacks; they do not establish native cleanup behavior.

## Explicit native pilot, after an isolated measurement slot is available

The following commands **are native operations**, unlike the qualification
command. Do not run them during development/builds or while the machine is in
use. They require an already granted screen-capture permission; the recorder
does not request one. Use a source-qualified isolated app bundle supplied by
the campaign, never an installed/user app. The surrounding campaign must pin
the complete app bundle and source/native archive qualification; this recorder
additionally pins the exact executable and generated launch inputs before and
after the trial. No application/window is activated by a helper: normal launch
must establish the terminal's own foreground window.

Set these values explicitly for one fresh pilot. The display ID comes from the
campaign's existing read-only display inventory. The probe reads mode/condition
metadata only, with no capture or permission request.

```sh
STARTUP_BUILD=/private/tmp/cmdy-startup-headless-01
STARTUP_PILOT=/private/tmp/cmdy-startup-pilot-01
STARTUP_DISPLAY_ID=1
STARTUP_APP=/absolute/path/to/frozen/CMDY.app/Contents/MacOS/cmdy
mkdir -m 700 "$STARTUP_PILOT"
"$STARTUP_BUILD/startup-observer" --probe-display "$STARTUP_DISPLAY_ID" \
  > "$STARTUP_PILOT/display.json"
python3 -B "$STARTUP_BUILD/tooling/startup_recorder.py" \
  --prepare "$STARTUP_PILOT/cmdy-input" --terminal cmdy \
  --executable "$STARTUP_APP" --display "$STARTUP_PILOT/display.json" \
  --profile matched
python3 -B "$STARTUP_BUILD/tooling/startup_recorder.py" \
  --record-diagnostic "$STARTUP_PILOT/cmdy-input/prepared.json" \
  --observer "$STARTUP_BUILD/startup-observer" \
  --observer-build "$STARTUP_BUILD/startup-observer-build.json" \
  --output "$STARTUP_PILOT/cmdy-observation"
python3 -B "$STARTUP_BUILD/tooling/startup_evidence.py" \
  "$STARTUP_PILOT/cmdy-observation/raw.json" \
  --spec "$STARTUP_PILOT/cmdy-input/spec.json"
```

For Ghostty, use a different new preparation/output directory, its campaign-pinned
executable, and `--terminal ghostty`. The preserved public configuration request
subtracts two columns and one row from the declared actual target, with padding
10: a 98 × 29 target requests 96 × 28. Every new target mapping is explicitly
**unqualified until a fresh pilot succeeds**. No corrective AX resize or
subsequent generation may hide a wrong first grid. `cmdy-defaults` is another
explicit profile; results across profiles/power conditions never pool.

The pilot must establish actual launch activation, initial PTY geometry,
opening-window stability, capture cadence/backpressure, and platform process
cleanup on both binaries. ScreenCaptureKit timestamps establish the earliest
matching *delivered* frame; headless tests cannot prove physical scanout timing
or rule out a frame never delivered by the platform. The one-second check
corroborates stability and does not repair missed first-frame evidence. Window
visibility queries bracket decoding; they are not an atomic WindowServer
snapshot at `displayTime`. These limitations need observed pilot receipts and
a declared sampling/visibility perimeter before metric admission.

A production comparison also needs the campaign's idle/hardware-activity
guards, exact bundle/source provenance, randomized paired blocks, sample counts,
four profile/power scenarios, and the unchanged strict confidence gate. None
of those are invented by a successful diagnostic receipt. The startup case
remains blocked in the parity campaign until those requirements are met.
