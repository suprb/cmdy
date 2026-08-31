# CmdyCore shaping and surface behavioral contract

Status: compatibility specification for an independent App integration seam

Reference behavior: cmdy's CmdyCore/AppKit/CmdyGPU integration immediately before lineage replacement

Scope: engine snapshot shaping, AppKit terminal-surface behavior, input routing, geometry, lifecycle, and host callbacks

Active implementation: `App/CmdySnapshotShaper.swift`,
`App/CmdyTerminalSurface.swift`, and `App/CmdyCellImageHarness.swift`. The
replacement is selected by `TerminalEngineFactory`; final release
qualification remains tracked in `INDEPENDENT_TERMINAL_STACK.md`.

## 1. Purpose and boundaries

This contract covers two related seams:

1. converting immutable CmdyCore snapshots into the renderer-neutral values defined by `MetalRenderSource`; and
2. hosting one engine and one renderer as an AppKit `TerminalSurface` and `TerminalSession`.

It specifies observable behavior, not an algorithm. A replacement may be organized differently and need not retain the existing source-file split. It must not consult or reproduce the prior seam implementation.

CmdyCore remains platform-free. AppKit, colors, fonts, events, pasteboard access, links, and GPU ownership remain on the App side. CmdyGPU receives immutable render values and never reaches into mutable engine state.

## 2. Snapshot and damage coherence

- Engine/model publication installs one immutable `CoreTerminalSnapshot` on the main actor.
- `captureGrid()` freezes the snapshot used by every subsequent row, cursor, Kitty, and line-mode query for that renderer pass. A model publication during shaping appears in a later pass, never halfway through the current one.
- Grid rows, columns, retained-line count/origin, display and live-screen origins, absolute cursor row/column, cursor visibility/style, and alternate-buffer identity map without reinterpretation.
- An absent absolute row produces an empty `ViewLineInfo`, line version zero, and single-width line mode.
- A published dirty range is unioned with any unconsumed dirty range. Consuming returns the union once and clears it.
- Row content versions remain authoritative. Appearance changes that alter shaped rows explicitly invalidate render caches. Selection changes only request dynamic composition and never invalidate immutable row textures.
- Output that advances a viewport already following the live tail clears any held fractional scroll offset so new rows remain aligned to chrome.

## 3. Row-to-render shaping

### 3.1 Cell traversal and runs

- Terminal columns are traversed left to right.
- A width-zero cell is the continuation of an earlier wide cell and does not create a second glyph or segment cell.
- Every leading cell consumes at least one terminal column. Its positive engine width is retained.
- A scalar value of zero renders as a space when the cell must be represented.
- Adjacent cells may share a `ViewLineSegment` only when resolved cell attributes and column width are equal.
- Every segment begins at the first represented column, counts engine cells rather than grapheme clusters, and carries a UTF-16 boundary after each engine cell. This boundary map remains correct for empty/default cells, surrogate pairs, combining sequences, and ZWJ clusters.
- Trailing cells whose scalar is zero and attributes are the buffer default may be omitted because the renderer already clears the row to the native background. Dynamic selection does not require shaped blank cells; failed-command styling does.

### 3.2 Procedural and private graphics cells

- Unicode box-drawing and block-element cells are emitted as procedural render items rather than font glyphs.
- Those cells also contribute a space segment so explicit, inverse, or failed-command backgrounds are still painted. Dynamic selection is independent of shaped segments.
- The private Kitty placeholder encoding is decoded into `KittyPlaceholderCell` metadata and is never sent to CoreText as a visible private-use glyph. Its cell background remains represented by a space.
- Placeholder decoder state resets when a non-placeholder cell interrupts a sequence.
- Line-attached images are wrapped as class-bound `RenderableCellImage` values. A stable engine render identity yields a stable wrapper identity. Wrapper caching is bounded to 512 entries or less.
- Invalid PNG/RGBA image data yields a harmless empty image of the declared dimensions, not a crash.

### 3.3 Line and cursor mapping

- Engine single-, double-width, upper double-height, and lower double-height modes map one-for-one to renderer line modes.
- All six engine cursor shapes map one-for-one to renderer cursor styles.
- Cursor cell shaping reads the cell at the captured absolute cursor row and column. An absent/out-of-range cell yields `nil`.
- Cursor cell text uses the cell's normal font/style, the configured cursor background, and `caretTextColor` when non-`nil`, otherwise native foreground. A scalar-zero cell contributes a space.

## 4. Color and attribute contract

### 4.1 Palette

- The surface owns 256 colors. `installColors` replaces at most the first 16 entries and leaves the 6x6x6 cube and 24-step gray ramp intact.
- The default first 16 entries match xterm-like ANSI normal/bright colors. Entries 16...231 use component steps 0, 95, 135, 175, 215, and 255. Entries 232...255 use grayscale values 8 through 238 in steps of 10.
- Truecolor bytes map to sRGB channels divided by 255.
- ANSI indices 0...6 become their bright partner at index +8 for bold foreground text. Index 7 and indices 8...255 do not shift merely because text is bold. Background colors never brighten from bold.

### 4.2 Default, inverse, and dim

- Default foreground/background resolve to the surface's native pair.
- Inverse video first exchanges the logical foreground/background. A default value that becomes the opposite side resolves to the per-channel RGB complement of that side's native color while preserving alpha.
- Dim foreground is the 50/50 per-channel midpoint between the resolved foreground and resolved background. Background is unchanged.
- The default background is omitted from row attributes because the frame clear already supplies it. Nondefault or inverse backgrounds are explicit.
- The live surface supplies a selected-column range per visible row and a separate selection color. Metal composes that plane behind glyphs without changing or rerasterizing the underlying cell foreground/style.

### 4.3 Fonts and decorations

- Normal, bold, italic, and bold-italic terminal font variants are selected from the configured font using native font traits.
- Cell-merging ligatures and contextual substitutions are disabled for terminal text.
- A uniform printable, single-width ASCII segment may cache one prepared
  CoreText line per distinct code unit, but drawing remains cell-addressed and
  must match the uncached coverage, glyph geometry, colors, backgrounds, and
  decorations exactly. Complex Unicode and mixed-style segments are not
  reduced to this path.
- Underline style defaults to single when the underline bit is set but the engine's underline kind is `none`.
- Single, double, curly, dotted, and dashed kinds cross the package seam using cmdy-named raw values. The old upstream-named attributed key must not survive in the independent implementation.
- An explicit underline color is resolved like a foreground color, including bold ANSI behavior; otherwise underline uses resolved foreground.
- Strike-through is single and uses resolved foreground.
- A row identified in `failedBlockRows` overrides shaped foreground and background, including procedural glyph foreground, without mutating engine cells.

## 5. Kitty and graphics snapshots

- The renderer-facing Kitty stamp reflects image count, placement count, next image identifier, and next placement identifier from the captured snapshot.
- Virtual placements are filtered by requested primary/alternate buffer and retain image/placement identifiers, cell dimensions, and pixel offsets.
- Image payload lookup is by image identifier and exposes PNG bytes or RGBA bytes plus dimensions without alteration.
- The live-ID set equals the captured Kitty image-store keys.
- Ordinary line images retain pixel size, column, Kitty identity, z-index, and pixel offsets.

## 6. Metrics, insets, and resize

- The surface is an `NSView`, accepts first responder, and hosts one `TerminalModel` plus one GPU renderer.
- Default font is the 13-point monospaced system font; initial grid is at least 2 columns by 1 row.
- Cell height is the ceiling of font ascent + descent + leading, multiplied by `lineHeightMultiplier`.
- Cell width is the advance of the font's zero glyph, falling back to W when zero is unavailable.
- Width and height are rounded upward to the current backing-scale pixel grid. Both are at least one point; height is capped at 8192 points.
- `textBaselineFromRowTop` equals cell height minus the ceiling of font descent plus leading. AppKit overlays use this baseline rather than visually centering font bounds.
- Changing font or line-height recomputes metrics, brackets engine reflow with `willReflowBuffer`/`didReflowBuffer`, resizes the PTY, and redraws.
- Available columns use view width minus left and right insets. Available rows use height minus top and bottom insets. Partial cells are excluded.
- Column zero begins at the left inset rounded to a device pixel. Spare sub-cell width is not centered; resizing cannot make the grid drift horizontally.
- Top/bottom insets reserve rows from terminal content. Left/right insets reserve columns from available width. Insets cause reflow rather than overlaying active cells.
- A size change atomically updates engine grid dimensions/snapshot, then PTY `winsize`, then `onSizeChanged`, then viewport notification. The minimum is 2x1.
- Pixel width/height metadata still updates when the point-size change does not cross a row/column boundary.
- The GPU view fills surface bounds, but rendering and hit-testing honor the content insets.

## 7. Renderer ownership

- Enabling Metal creates one display-on-demand `MTKView` in BGRA8 format and one renderer. Repeated enable calls are idempotent.
- There is no CPU terminal renderer. Disabling Metal reports an unavailable-renderer error rather than silently showing a second implementation.
- Existing theme, built-in/custom shader, text-rendering mode, cursor, glide, and smooth-scroll settings are applied when the renderer is created.
- The Metal child is render-only and never intercepts AppKit mouse hit testing from the surface.
- Theme and failed-row changes invalidate retained row caches and request a display. Selection changes request display-aligned dynamic composition while retaining every row cache entry.
- Content updates wake recent-activity cursor behavior but settled static content returns to display-on-demand idle.
- `terminate()` terminates the model process and immediately detaches the renderer callback, view delegate, GPU view, and renderer. Detached AppKit hierarchies must not retain per-pane atlases, display timers, or callbacks.
- Moving a pane between windows removes old occlusion/focus observers before registering the new window. Repeated window-to-pane/pane-to-window operations cannot accumulate observers or redraws.
- The window's backing-scale change recomputes cell metrics and rendering scale.

## 8. TerminalSurface and host callbacks

The implementation continues to satisfy every member of `TerminalSurface` and `TerminalSession` in `CmdyKit/TerminalCoreProtocols.swift`.

- `view` is the surface itself; `engine` is its `TerminalModel` as `TerminalEngine`.
- `feed(text:)` feeds parser input and schedules display.
- Bytes generated by typing, paste, mouse, terminal replies, or alternate-screen wheel routing reach `onSendToProcess` exactly once and in order.
- `onPasteRequest` may transform paste text or return `nil` to cancel.
- `onTerminalMouseDown` fires for a primary click before selection/reporting routing.
- `onOpenLink` receives activated URLs; in its absence native workspace opening is used.
- Title, OSC current-directory, bell, notification, clipboard-copy, and process-exit model events map to their corresponding host callbacks. BEL is audible before/in addition to `onBell`.
- Renderer/engine content, viewport, focus, or visual scroll-offset changes call `onViewportChanged` without a polling timer.
- Completed mouse selection, search reveal/clear, and keyboard selection adjustment call `onSelectionChanged`.
- `shellPid`, process start parameters, and process termination pass through without reinterpretation.

## 9. Keyboard encoding

All emitted sequences are UTF-8 bytes. Any user input first returns a locally scrolled primary buffer to the live tail and clears fractional scroll motion.

| Input | No relevant modifier | Modified behavior |
| --- | --- | --- |
| arrows | CSI A/B/C/D, or SS3 A/B/C/D in application-cursor mode | CSI `1;<m>A/B/C/D` |
| Home / End | CSI H / CSI F, or SS3 H/F in application-cursor mode | CSI `1;<m>H/F` |
| Page Up / Page Down | CSI `5~` / `6~` | CSI `5;<m>~` / `6;<m>~` |
| Forward Delete | CSI `3~` | CSI `3;<m>~` |
| Escape | ESC | CSI `27u` when Kitty disambiguate-escape flag is active |
| Tab | HT | Shift-Tab is CSI Z |
| Return / keypad Enter | CR | see below |
| Backspace | DEL | Option-Backspace is ESC DEL |
| F1...F4 | SS3 P/Q/R/S | CSI `1;<m>P/Q/R/S` |
| F5...F12 | CSI `15,17,18,19,20,21,23,24~` | corresponding CSI tilde with `<m>` |

Modifier parameter `<m>` starts at 1 and adds 1 for Shift, 2 for Option, and 4 for Control.

- When Kitty enhanced-keyboard disambiguation is active, modified Return emits CSI `13;<m>u`.
- Without it, Shift-Return and Option-Return emit ESC CR so interactive agent TUIs can distinguish insert-line from submit. Unmodified and Control-only legacy Return emit CR.
- Control A...Z/a...z map to bytes 1...26. Control-Space is NUL; Control-[, backslash, ], ^, and _/minus map to ESC and bytes 28...31.
- With `optionAsMetaKey`, Option prefixes the unmodified character bytes with ESC.
- Otherwise the event's typed characters are forwarded exactly as UTF-8.
- An event with no encodable characters is a no-op.

## 10. Paste and copy

- Paste reads plain text from the general pasteboard, then invokes `onPasteRequest` once.
- If bracketed-paste mode is active, accepted text is enclosed in CSI 200~ and CSI 201~. Otherwise it is sent unchanged.
- Paste is user input and returns the viewport to the live tail.
- Copy writes nonempty selected text to the general pasteboard. An empty selection does not clear the pasteboard.

## 11. Mouse hit testing, selection, and reporting

- Grid coordinates are y-down below the top inset and x-right from `contentXOrigin`; event coordinates are clamped to valid cells only after verifying the point is inside the actual grid.
- A click above the grid in reserved top chrome does not select row zero. A plain click there remains available for native window dragging.
- A grid click makes the terminal first responder.
- Command-click on a recognized link opens it instead of selecting/reporting.
- With mouse tracking off, a single primary drag creates native selection; double-click selects the contiguous non-whitespace run; triple-click selects the full terminal row.
- Shift or Option, and any multiple click, force native selection even when a TUI enabled mouse reporting.
- With mouse tracking on, a plain primary down is held. If released without dragging, the surface sends primary press at the original cell followed by release at the final cell. If dragged, no press reaches the TUI and the gesture becomes native selection from the original absolute cell.
- Shift, Control, and Option map to terminal mouse shift, control, and meta modifiers. Command is reserved for host links and does not become a terminal mouse modifier.
- A primary gesture state ends on mouse-up. A persistent old selection cannot be accidentally extended by a later window drag.

## 12. Wheel and scroll policy

Wheel input is routed in this priority order:

1. If terminal mouse reporting is active, quantized wheel movement becomes terminal wheel buttons 64 (up) or 65 (down) at the pointer cell.
2. Else, in the alternate buffer, quantized up/down movement becomes CSI Up/Down bytes for the application.
3. Else, it moves local primary-buffer scrollback.

For TUI routing, a single event emits no more than 31 repeated steps. Precise device deltas are converted through cell height; discrete wheel deltas are treated as line units. Both apply the configured scroll-speed multiplier.

In local scrollback:

- discrete movement changes whole rows and may give the renderer a short glide impulse;
- precise movement with smooth scrolling accumulates view points, changes engine rows only when whole cell heights are crossed, and holds the signed remainder as a once-device-snapped renderer translation;
- viewport-only row crossings reuse an already-published immutable row window while it covers the visible grid and renderer fringe; parser damage, geometry changes, buffer changes, or an exhausted fringe require a coherent fresh capture;
- the displayed fractional offset is device-pixel snapped;
- hitting either scroll boundary cancels remainder and animation;
- switching from precise motion to a wheel resets the held remainder;
- explicit `scrollTo`, user input, disabling smooth scroll, and tail-following output clear fractional motion; and
- autonomous PTY output does not pull a user from older scrollback unless they were already tail-following.

`scrollPosition` is 1.0 with no scrollback and otherwise current top divided by live-screen top. `scrollUp`/`scrollDown`/`scrollTo` clamp through the engine and notify/redraw only the resulting state.

## 13. Selection and search

- Selection endpoints use absolute retained rows and terminal columns and are normalized for reverse drags.
- A selected row range starts at the first endpoint column, ends at the last endpoint column, and spans all columns on intermediate rows.
- Extracted text skips width-zero continuation cells, turns scalar-zero cells into spaces, preserves cell text, and joins selected buffer rows with newline.
- `selectAllContent` selects from the oldest retained cell to the final retained row's last column.
- Adjusting the active endpoint supports left/right with row wrapping; up/down; viewport-sized page up/down; and row home/end. Values clamp to the retained grid. It returns false when there is no adjustable selection.
- Moving an endpoint outside the viewport scrolls the smallest amount that reveals it.
- Find next/previous wraps through all engine hits. Revealing a result centers its row where possible, selects the exact hit, redraws, and notifies selection/viewport observers.
- Clearing search clears hits, active index, search term, and selection.

## 14. Link behavior and cursors

- OSC 8 link identifiers resolve through the engine and span adjacent cells with the same link ID.
- Plain-text detection recognizes `http://`, `https://`, `file://`, `mailto:`, `www.` (normalized to HTTPS), and localhost/127.0.0.1/[::1] with optional port/path (normalized to HTTP).
- Leading brackets/quotes and trailing punctuation/brackets/quotes are excluded from detected URLs.
- Width-zero continuations are excluded from token text.
- The terminal text area uses the I-beam. Reserved top chrome uses the arrow cursor. Command-hover on a recognized link uses the pointing hand only over the link's cell rectangle.

## 15. Redraw, resource, and performance acceptance

- Output publications coalesce pending damage; they do not mark the entire viewport for every parser event.
- Selection/theme changes may invalidate all retained render cache entries because their pixels are outside engine line versions.
- Window occlusion produces no continuing renderer work. Becoming visible or key requests the needed recovery frame.
- A pane moved through many windows retains exactly the observers for its current window.
- Closing a pane releases process callbacks, view observers, renderer callback closures, Metal view/delegate, and GPU resources promptly.
- Image wrapper caching, search state, selection state, and snapshots remain bounded by retained terminal/product limits; none grow once panes close.
- Geometry/input handling remains responsive while many panes produce output. It may not synchronously parse PTY data or wait on a GPU command buffer on the main thread.

The full-app performance budgets in `CMDYGPU_CONTRACT.md` and PTY budgets in `CMDYPTY_CONTRACT.md` apply at this seam.

## 16. Verification

Run from repository root:

```sh
swift test --package-path Core -c release
swift test --package-path Renderer -c release
swift test --package-path Kit -c release
python3 -B scripts/check-renderer-pixel-parity.py
swift build -c release
CMDY_CONFIG_DIR="$(mktemp -d /tmp/cmdy-seam-contract.XXXXXX)" \
  .build/release/cmdy --selftest
./package.sh
Tests/perf-gate.sh
CMDY_PERF_MAXIMIZED=1 Tests/perf-gate.sh
ZOO_OUT="$(mktemp -d /tmp/cmdy-seam-zoo.XXXXXX)" Tests/zoo.sh
```

`CmdySurfaceContractHarness` and `CmdyCellImageHarness` run inside
`cmdy --selftest`. Together with the package suites, they assert:

- immutable per-frame snapshot behavior and dirty-range union/consume;
- segment boundaries for ASCII, wide, combining, emoji-ZWJ, adjacent Jamo cells, and default-tail trimming;
- exact palette, inverse, dim, selection, bold, underline, and failed-row attributes;
- procedural glyph spacer backgrounds and Kitty placeholder suppression;
- metrics/insets at 1x and 2x, minimum grid, resize callback order, and stable column-zero origin;
- every keyboard row in section 9, bracketed paste, and tail jump on input;
- the wheel-routing matrix and smooth-scroll boundary reset;
- mouse-report click versus drag-to-select behavior;
- selection extraction/adjustment/search wrap;
- OSC 8 and detected-link ranges/cursor rects;
- repeated window reparent and renderer teardown with observer/GPU memory baselines; and
- black-box screenshots matching the deterministic fixtures listed in `CMDYGPU_CONTRACT.md`.

## 17. Allowed implementation freedom

Conformance does not require attributed-string run builders, a particular snapshot wrapper, `NSCache`, the current observer mechanism, current gesture-state representation, current scroll accumulator, current palette storage, or the current source-file layout. It requires the platform boundary, pixels, coordinates, input bytes, callback order, lifecycle, bounded resources, and acceptance behavior above.
