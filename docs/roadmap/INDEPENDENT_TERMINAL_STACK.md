# Independent terminal stack

Status: the replacement implementation and reproducible Core/source/renderer
engineering gates are complete on the `independant` branch. A clean
committed-source qualification run, Apple notarization, and the final
independent human provenance review remain pending.

The behavioral contracts are frozen. The generated Unicode-width tables have
exact full-scalar parity; the replacement CmdyPTY, CmdyGPU, and App
shaping/surface implementations are active; the frozen public API is exact;
and a fail-closed current-tree provenance gate covers tracked, modified, and
untracked active source. The final 17-seed Core C-ABI oracle is exact across
53,992 public states. The many-window resource plateau, both performance gates,
live TUI zoo, lean and Browser package matrices, and local Developer-ID signing
checks pass. The recovered historical renderer pixels are retained as a locked,
canonical corpus, and the current candidate passes all 40 fixtures with exact
public inputs, zero differing pixels, and no exceptions. Do not publish an
unqualified independence or production-release claim until every pending item
above is complete.

cmdy has no runtime or package dependency on SwiftTerm. The replacement's
frozen pre-migration inventory is maintained in
[`SWIFTTERM_PROVENANCE_AUDIT.md`](SWIFTTERM_PROVENANCE_AUDIT.md) and
[`PROVENANCE_INVENTORY.md`](../independence/PROVENANCE_INVENTORY.md). At the
start of this branch, the
following historical boundaries contained SwiftTerm-derived implementation
covered by its MIT notice:

1. `Core/Sources/TermitePTY/Pty.swift` and `LocalProcess.swift`:
   pseudo-terminal, child-process, I/O, resize, signal, and reaping behavior.
2. `Core/Sources/TermiteCore/UnicodeWidth.swift`: Unicode column-width data
   and lookup logic.
3. Parts of `Renderer/Sources/TermiteGPU/`: the Metal renderer foundation,
   including glyph-atlas, cell-rendering, shader, and compatibility code.
4. `App/TermiteCoreShaping.swift` and `App/TermiteCoreSurface.swift`:
   view-to-renderer shaping and surface behavior adapted from the historical
   SwiftTerm view and renderer adapter.

The corresponding active replacement boundaries are
`Core/Sources/CmdyPTY/`, generated width policy under
`Core/Sources/CmdyCore/`, `Renderer/Sources/CmdyGPU/`, and
`App/CmdySnapshotShaper.swift` plus `App/CmdyTerminalSurface.swift`.

The goal is to replace those implementations without changing cmdy's visible
terminal behavior, performance contract, or public APIs. SwiftTerm may remain
mentioned in historical documentation, old releases, Git history, and the
parked differential-oracle records.

## Replacement order

### 0. Freeze the contract — implemented

- Record the exact derived-file inventory before making replacements.
- Preserve the existing MIT notice throughout the work.
- Treat the regression corpus, recorded sessions, TUI zoo, screenshots, and
  performance gates as behavioral specifications—not source templates.
- Establish correctness, memory, latency, and lifecycle baselines for each
  component before replacing it.

### 1. Unicode width — implemented and exact

- Generate pinned width tables from official Unicode data files.
- Implement cmdy-owned lookup and ambiguous-width policy.
- Prove parity across the full Unicode range and the existing terminal corpus.
- Record the Unicode version and reproducible generation command.

This is the smallest and most isolated replacement.

### 2. PTY and child-process transport — implemented and stress-qualified

- Implement the backend directly against documented macOS/POSIX primitives:
  `forkpty`, `exec`, `ioctl`, nonblocking I/O, signals, and `waitpid`.
- Preserve CmdyPTY's existing public API while replacing its internals.
- Cover shell startup, resize storms, flow control, process groups, rapid
  close/reopen, ignored termination signals, PID reuse, and zombie prevention.
- Stress opening and closing many busy panes and verify that process, memory,
  file-descriptor, and observer counts return to baseline.

### 3. Metal renderer foundation — implemented and exact

- Keep the narrow `MetalRenderSource` boundary and cmdy's original shaders and
  appearance system.
- Independently implement the remaining derived atlas, rasterization,
  cell-batching, cache-invalidation, selection, cursor, and compatibility
  behavior from platform documentation and cmdy's behavioral tests.
- Compare rendered output using deterministic fixtures and image diffs.
- Meet or improve the existing idle, typing, scrolling, resize, shader, and
  many-window performance budgets.

This was the largest and highest-risk replacement. The current row-raster
renderer retains the public `MetalRenderSource` seam. Its tests and performance
budgets are green, and its candidate-only locked-corpus gate is 40/40 strict
exact at both recorded scales.

### 3b. Shaping and surface integration — implemented and active

- Replace the adapted attribute shaping, cursor mapping, graphics-payload, cell
  metric, inset, input, and wheel-routing behavior at the App/renderer seam.
- Specify the behavior from cmdy's engine and UI contracts rather than the old
  SwiftTerm view implementation.
- Verify pixel geometry, selection, mouse reporting, resize, scrolling, and
  graphics behavior using black-box fixtures and live TUI tests.

### 4. Provenance and release audit — engineering gates green; release approval pending

- Review every active source file for copied or derived SwiftTerm code. The
  fail-closed engineering scan is complete; independent human review remains.
- Confirm the app still has no SwiftTerm import, linked product, vendored
  runtime, or package dependency.
- Run all Core, Renderer, Kit, app, TUI-zoo, performance, packaging, signing,
  and lifecycle tests. The reproducible local matrix and strict renderer replay
  are green; clean-tree qualification and notarization remain open.
- Update current-source attribution only after the inventory is independently
  verified. Never remove required notices from old releases or history.

The exact commands and evidence expectations are in
[`BUILDING.md`](../../BUILDING.md#independent-terminal-stack-verification).
The locked black-box pixel corpus is behavioral test data, not an implementation
dependency. Its candidate-only exact gate and the other reproducible
source/API/dependency gates run in CI.

## Definition of done

The current cmdy source may be described as independently implemented only when:

- no active implementation is copied or derived from SwiftTerm;
- Unicode tables are reproducibly generated from identified upstream data;
- PTY lifecycle and renderer behavior pass their complete regression and stress
  suites;
- performance and memory remain within the existing defended budgets; and
- a final provenance review confirms the claim.

Record that review against the exact committed tree using
[`PROVENANCE_REVIEW_TEMPLATE.md`](../independence/PROVENANCE_REVIEW_TEMPLATE.md).
An incomplete or `pending` record is not approval.

Renaming symbols or reorganizing files does not satisfy this roadmap. For a
strict legal clean-room claim, the replacement process also needs documented
separation between the existing implementation and the people writing the new
one; that claim should be reviewed separately before publication.
