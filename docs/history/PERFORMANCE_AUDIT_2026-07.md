# Termite Performance and Robustness Audit

Last updated: 2026-07-11

## Objective

Build a native macOS terminal whose interactive latency, sustained output,
scrolling, rendering, and multi-pane behavior are competitive with or better
than other GPU terminals without sacrificing correctness or idle efficiency.

## Reproduced Issue

At a maximized window size, holding Return or scrolling through scrollback was
slow and jumpy. The primary causes were CPU-side rather than GPU throughput:

- Viewport-wide invalidation rebuilt every visible row after small scrolls.
- Prompt mode toggles and partial erases caused unnecessary full redraws.
- Printable output was parsed and committed scalar by scalar.
- Scrollback trimming shifted retained references and repeatedly allocated rows.
- PTY callbacks could queue more main-thread work than the UI could drain.
- Cursor and shader clocks could independently request the same frame.

## Completed Work

Commits `d4b03be` and `d695fb7` implemented:

- Stable row-cache coordinates and incremental edge-row reconstruction.
- Exact dirty-row handling for prompt redraws, Return, and wheel scrolling.
- Batched ASCII and CRLF parsing with a scalar semantic oracle.
- Recycled row storage, deferred blank fills, and bounded scrollback storage.
- One in-flight PTY read with 4 MB/2 MB high/low-water backpressure.
- O(N) reflow mapping, dropped-block rebasing, and process lifecycle fixes.
- Default-background geometry elimination and bounded row-cache retention.
- Correct UTF-16-to-cell shaping maps for combining, Indic, Jamo, and ZWJ text.
- Focus, occlusion, idle, cursor-blink, and shader frame power gating.
- Main-loop coalescing for preferences, window chrome, block state, and plugins.
- Concurrent plugin HTTP connections and deterministic plugin replacement.

## Verified Baseline

Machine: Apple M1 Max, macOS 26.3.1.

Comparison: Ghostty 1.3.1, ReleaseFast, CoreText, Metal.

- Maximized regression gate: 16/16 checks passed.
- Twenty Return events advanced exactly twenty rows.
- Twenty one-line scrolls rebuilt 3 rows upward and 0 downward.
- Idle rendering: 0 frames after settling.
- Animated shader: 136 frames in 5 seconds, within the 30 fps budget.
- Core line parser: approximately 95 MB/s.
- Core continuous ASCII parser: approximately 155 MB/s.
- Matched 3 MB continuous drain: Termite 0.031 s, Ghostty 0.041 s.
- Matched 3 MB 76-column line drain: Termite 0.038 s, Ghostty 0.043 s.
- Release verification: 25 Core tests, 3 renderer tests, and 7 headless suites.

These results establish a lead for the tested single-pane workloads. They do
not establish universal superiority across every terminal workload.

## 2026-07-11 Completion Ledger

### 1. PTY and Model Ownership

Completed. Every pane owns a serial, user-interactive model queue. PTY reads,
terminal parsing, writes, and process lifecycle now stay on that queue. AppKit
receives coalesced immutable snapshots, so sustained output in one pane cannot
run terminal mutation work on the main thread or another pane's queue.

### 2. Metal Submission

Completed for the Termite render path. Dirty rows are aggregated into one frame
submission, geometry comes from a persistent triple-buffered grow-only ring,
and material batches use buffer offsets instead of allocating one `MTLBuffer`
per row. The renderer test suite verifies that allocations stop after warm-up.

### 3. Glyph Atlas

Completed. The atlas is a four-page `texture2d_array` with page generations and
LRU page eviction. Glyph pressure invalidates only entries on the evicted page;
it no longer clears the entire atlas and every retained row cache.

### 4. Event-Driven UI

Completed for steady-state UI. Pane/block overlays update from viewport and
block events, and docking listens to mouse events only while dragging. Bridge
refreshes from Termite pane/workspace events. Timers remain only for active
animation/geometry tracking and the registry's infrequent stale-session sweep.

### 5. Kitty Virtual Placements

Completed. Core decodes the Kitty Unicode placeholder protocol, including the
official diacritic metadata and inheritance rules, and shaping emits virtual
placement cells while preserving the terminal cell background.

### 6. Concurrency and CI

Completed for the performance-critical Core, PTY, and renderer ownership paths.
Strict complete-concurrency Core and renderer release tests pass. A macOS CI
workflow now builds and tests Core, renderer, Bridge, the app, all headless
suites, packaging, and the maximized performance gate.

### 7. Bridge

Completed. Bridge registers only Termite panes, rejects forged/non-Termite
registrations and injection targets, and launches only `com.termite.app`.
Connection controls are deduplicated per exact AppKit window number and remain
anchored at the right-edge midpoint; focused split panes are preferred.

### 8. Failed Rows

Completed. The marker-dot view, hit targets, renderer markers, and permanent
left gutter are removed. A failed command prompt uses the configured failure
foreground and a row-wide failure background without changing terminal margins.

### 9. Smooth Block Scrolling

Completed. Block overlays and separators consume the renderer's held/glide
pixel offset, so they remain attached to their terminal rows during smooth
scrolling instead of stepping one logical row at a time.

### 10. Scroll Boundaries

Completed. Outward wheel input at the top or bottom cancels held/glide state
and clears fractional accumulation immediately. Precise-pixel wheel tests cover
partial movement and hard clamping at both boundaries.

## 2026-07-11 Bridge and Hotkey Follow-Up

- Removed the legacy BraincellBridge/term64 shell hooks from the local shell
  profile, Bridge package resources, setup UI, and registration flow. Termite
  panes now have exactly one owner: the public Termite plugin API.
- The window-edge plus now opens Bridge's connection picker with the clicked
  Termite pane preselected instead of immediately launching a default target.
- Other terminal applications are excluded from native binding targets.
- Quiet Termite sessions no longer expire after 90 seconds; cleanup uses pane
  close events and dead-process checks.
- Replaced plugin hotkey hex literals with typed Carbon modifier values. Sim's
  advertised Control-Option-S had used `0x180`, which Carbon reduced to
  Command-S; it now uses the correct `controlKey | optionKey` value. SDK tests
  cover both Control-Option and Command-Shift combinations.
- Migrated the disconnected user MCP entry from `braincell-bridge` to `bridge`
  and pointed it at the installed Termite Bridge resource bundle.

## 2026-07-11 Sim and Browser Sidecar Follow-Up

- Termite now emits a throttled `window-frame` event for only its key window.
  The event carries the stable WindowServer id; sidecars use it to wake an
  exact-window local follower instead of applying delayed SSE coordinates or
  guessing the first window owned by the process.
- Browser tracks at 240 Hz only while the host is moving, then returns to 10 Hz.
  Sim tracks at 120 Hz while moving, then returns to 6.7 Hz. Sim caches its
  device size and process identity so its hot path performs no redundant AX
  size reads.
- Sim uses a proportional split that follows host resizing, a 20-point divider
  hit target, position-only AX updates, equal exposed-edge insets, and exact
  horizontal/vertical centering. It no longer grows the Termite window.
- Because the real Simulator rejects arbitrary window sizes, resize completion
  walks its native Physical/Point/Fit/Pixel presets, verifies the resulting
  size, and reverts a failed upscale. Live divider verification changed the
  card `761 -> 431 -> 801` points and the real Simulator
  `452x950 -> 376x801 -> 452x950` while preserving center alignment.
- At an artificial 480 pt/s host move sampled every 8.3 ms, Browser's relative
  WindowServer offset varied by at most 8 points horizontally/4 vertically.
  Sim's card varied by 8/4 and its device-to-card center by 4/2 at 120 Hz.
  Separate-process windows cannot share one compositor transaction; truly
  atomic movement requires an in-process Browser view and a streamed/IOSurface
  Simulator surface. Polling remains a bounded recovery/follow mechanism.

### Exact ownership and resize settling

- Dock insets are now scoped to one WindowServer id. Once visible, Sim and
  Browser reject frame events from other Termite windows instead of migrating
  to whichever window was most recently focused.
- Termite emits foreground/background, hidden/visible, closed, and live-resize
  state. A sidecar hides when its exact host backgrounds, minimizes, or the app
  hides; focusing a different Termite window also hides it. Clicking the
  Browser or Simulator itself remains interactive.
- Closing the attached host orders out Browser and force-terminates the owned
  Simulator process. Live verification left no Simulator or sidecar window in
  WindowServer after host closure.
- Native Simulator preset fitting is suspended during live resize and runs
  after resize completion. Physical Size is reapplied and measured before it
  is treated as the minimum, because Simulator's AX checkmark can precede its
  actual window resize. An undersized `452x950` Point Accurate window stepped
  down once to `376x801` Physical Size, Termite stayed frontmost, and no further
  attempts occurred during a five-second observation.
- Simulator uses application hide/unhide rather than off-screen positioning;
  WindowServer had clamped the old position and left a toolbar sliver visible.
- Browser now uses equal exposed-edge geometry. Live frames measured exactly
  10 points at its top, bottom, right, and split edge. Its first page is a
  local `termite-start.html`, not a vendor URL; requested navigation still
  replaces it immediately.

## Final Release Verification

Packaged binary: `termite.app/Contents/MacOS/termite`.

- Maximized regression gate: 18/18 checks passed.
- Twenty Return events advanced exactly twenty rows and rebuilt 40 rows.
- Twenty one-line scrolls rebuilt 3 rows upward and 0 downward.
- Idle and static-shader rendering: 0 frames after settling.
- Animated shader: 136 frames in 5 seconds, within the 20-30 fps band.
- Maximized 3 MB dump: 326 ms wall time.
- Two concurrent 1 MB pane drains: both markers in 1,298 ms.
- Live Bridge check: the plus rendered at the exact right-edge midpoint; a
  second Termite window registered a distinct exact window identity.
- Release verification: 28 Core tests, 6 renderer tests, 5 Bridge tests,
  8 TermiteSDK tests, 6 Sim tests, and 7 app headless suites.

## Residual Risks and Follow-Up

- Complete Swift concurrency checking still reports warnings in AppKit UI code
  and Bridge's legacy CDP/JSON layer. The performance-critical model boundaries
  are isolated, but adopting Swift 6 language mode across those UI/integration
  layers remains separate work and is intentionally recorded here.
- Thread Sanitizer could not run on this machine because macOS rejected the
  sanitizer runtime's code signature. CI and immutable snapshot tests cover the
  ownership contract, but they are not a substitute for a working TSan run.
- The retained 30 Hz Bridge geometry tracker runs only while connection targets
  are visible; removing it requires a reliable cross-process window-move event.
- These measurements establish the recorded workloads on this machine. They do
  not prove universal superiority over every workload, GPU, shell, or terminal.

## Verification Requirements

- Preserve all Core, renderer, and headless test results.
- Add focused tests for every new ownership and rendering contract.
- Run the maximized Return/scroll gate on the packaged release binary.
- Exercise at least two simultaneously busy panes.
- Verify idle CPU/frame behavior with all optional UI features enabled.
- Verify Bridge connection controls against Termite and reject other terminals.
- Package and validate `termite.app` before the final commit.
