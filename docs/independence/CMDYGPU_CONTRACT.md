# CmdyGPU behavioral contract

Status: compatibility specification for an independent renderer implementation

Reference behavior: cmdy workspace on 2026-08-19, before replacement of the renderer lineage

Scope: observable API, pixels, lifecycle, energy use, and performance; no implementation is prescribed

## 1. Purpose and conformance rule

This document is the black-box contract between cmdy's terminal engine, AppKit surface, and GPU renderer. A replacement may use any original architecture. It conforms when the same inputs produce equivalent terminal pixels and public behavior, satisfies the resource and scheduling limits below, and passes the referenced tests.

Exact byte-for-byte pixels are required for deterministic fixtures captured with the same macOS version, display scale, font file, font size, theme, and renderer preset. Across different OS font rasterizers or GPUs, conformance means the same cells, glyph identities, colors, clipping, image placement, decoration geometry, and cursor geometry, allowing only normal platform antialiasing variance.

This is not a provenance certificate. It intentionally records behavior without carrying forward an implementation.

## 2. Actor, ownership, and frame coherence

- Rendering and all `MetalRenderSource` access occur on the main actor.
- `MetalTerminalRenderer` holds the source weakly. Source deallocation must stop future draws safely and must not extend a pane's lifetime.
- The renderer pulls state; the source never owns or drives renderer internals.
- Each draw begins with one `GridSnapshot`. All row, cursor, image, style, and metric reads used for that draw must describe a coherent capture. PTY output arriving during the draw may appear in the next frame, never as a torn mixture within the current frame.
- At most one command-buffer build for a renderer may be outstanding. A request arriving while a frame is in flight must coalesce into a later redraw rather than block AppKit or enter a second build concurrently.
- A missing source, missing drawable, missing render-pass descriptor, or fully occluded window is a safe no-op. A transiently unavailable drawable schedules recovery; it must not busy-loop.
- Destroying a terminal surface must release its renderer and Metal view without waiting for a future frame or timer.

## 3. Public boundary

The replacement keeps source compatibility for the following cmdy-facing API unless a separately reviewed migration changes all callers and tests in the same change.

### 3.1 `MetalRenderSource`

The class-bound source supplies:

- a captured `GridSnapshot`;
- per-absolute-row `ViewLineInfo`, `RenderLineMode`, and monotonically changing content version;
- the attributed cursor-cell text;
- Kitty cache stamp, virtual placements, payload lookup, and live image identifiers;
- view bounds, backing scale, cell size, font and underline metrics;
- content origin, top/bottom/left inset, scroll offset, and image scale;
- native foreground/background, cursor foreground/background, focus state, block-glyph antialias preference, and buffering mode;
- a consumable absolute dirty-row range; and
- keypress age/typing activity inputs used by reactive shaders.

`lineVersion(forRow:)` is zero outside the captured buffer and changes whenever visible content or attributes for that retained row change. `consumeDirtyRows()` transfers ownership of the pending range and clears it; `nil` means no explicitly marked damage. A changed line version still invalidates a cached row if a producer misses a damage mark.

### 3.2 Render input values

`ViewLineSegment` describes a run beginning at a terminal column. `columnWidth` is the width of each engine cell in terminal columns and `characterCount` is the number of engine cells represented. `columnSpan` is never negative.

An optional `cellUTF16Boundaries` array is accepted only when all of these are true:

- it has one more element than `characterCount`;
- it begins at zero and ends at the attributed string's UTF-16 length; and
- values never decrease.

Invalid metadata is treated as absent. Valid boundaries remain authoritative for
terminal addressing even when adjacent terminal cells combine into one Unicode
grapheme after concatenation. In that case the composed glyph belongs to, is
clipped by, and is tinted by the first covered cell; continuation cells do not
emit a second glyph.

`ViewLineInfo` carries ordinary attributed segments, class-bound cell images, Kitty placeholder cells, block elements, and box-drawing items for one absolute row.

`RenderableCellImage` remains class-bound because identity distinguishes independently cached image objects. It exposes its image and pixel size, anchor column, Kitty identity, z-index, and pixel offsets.

`GridSnapshot` contains visible rows/columns, retained buffer length and origin, viewport and live-screen origins, absolute cursor row/column, cursor visibility/style, and alternate-buffer state. Absolute retained coordinates are stable across front trims: local row zero plus `retainedRowOrigin` identifies its retained position.

`RenderLineMode` supports single width, double width, upper half of double height, and lower half of double height. `RenderCursorStyle` supports blinking and steady block, underline, and bar variants.

Kitty input supports PNG bytes and unpacked RGBA bytes, virtual placement dimensions and offsets, placement identifiers, and placeholder-cell coordinates. Invalid or undecodable payloads fail locally without crashing or unbounded retry.

### 3.3 Procedural glyph input

- `BlockElementMapping` covers Unicode U+2580 through U+259F. Its rectangles use eighth-cell coordinates and the four terminal block coverage levels: full, dark, medium, and light.
- `BoxDrawingRenderer` covers Unicode U+2500 through U+257F, including light/heavy, single/double, dashed, diagonal, and rounded forms.
- Render items retain terminal column, column width, code point, and foreground color.
- Procedural output follows device pixels and fills the intended cell without hairline gaps at shared edges.
- Rounded forms use device-aligned stems joined to an antialiased even-odd
  quarter annulus. Diagonals extend by half an aspect-normalized device pixel
  at their cell-edge endpoints. These geometries are exact raster behavior,
  including their 8-bit boundary coverage at 1x and 2x.

### 3.4 Renderer controls

`MetalTerminalRenderer` remains constructible from an `MTKView` and a `MetalRenderSource` and remains the view's `MTKViewDelegate`. It exposes:

- cumulative frames presented, rows rebuilt, and rows reused counters;
- built-in or custom shader selection;
- smooth cursor enablement, host-cursor suppression, glide speed, and maximum glide distance;
- smooth scrolling enablement and snapped-offset callback;
- `TextRenderingMode` selection;
- custom-shader loading, returning a user-readable compile error or `nil` on success/clear;
- scroll impulse, held-scroll, scroll-activity, animation-cancel, general-activity, and row-cache invalidation entry points.

The public custom-shader preamble remains a stable source contract. It supplies resolution, elapsed time, curvature, resolved background color, cursor position, time since keypress, typing rate, and an entry point named `cmdy_main`. Loading `nil` clears the custom program. A failed compile disables that custom program, reports the failure, and leaves the terminal usable.

`MetalError` distinguishes missing Metal support/device/queue/atlas/library/source/function/sampler, shader compilation failure, and pipeline creation failure. Initialization failure is reported as an error rather than a crash or partially active renderer.

### 3.5 Compatibility names

The final independent API exposes `CmdyUnderlineStyleKey`, not a public attribute-key symbol bearing the old upstream product name. Its type and raw attribute behavior remain compatible. The API gate treats this as one reviewed name-only replacement.

The `TTColor`, `TTFont`, and `TTImage` typealiases may remain as deprecated source-compatibility declarations; renderer internals use native AppKit types. Aliases carry no implementation lineage. Removing them is a separate source-breaking API decision, not a clean-room requirement.

`RenderUnderlineStyle` preserves raw values for none, single, double, curly, dotted, and dashed so the shaping and rendering packages agree.

## 4. Coordinate and pixel contract

- Model geometry is expressed in points. Raster, scissor, viewport translation, glyph placement, cursor placement, and procedural line geometry resolve on physical pixels using the source's backing scale.
- The first terminal column starts at pixel-snapped `contentXOrigin`; spare width is not used to center the grid.
- The drawable is clipped to the content area after top and bottom insets. At scale 2, a 1000-by-800-pixel drawable with a 24-point top inset and a 40-point bottom inset produces scissor `(x: 0, y: 48, width: 1000, height: 672)`.
- View-origin translation is pixel snapped. Moving otherwise unchanged content by one device pixel moves the rendered origin by exactly one pixel and does not invalidate row content.
- The public smooth-scroll value is expressed in view points. It is multiplied
  by backing scale and rounded once at the drawable boundary; the snapped
  point value is reported back for AppKit overlays. Positive movement shifts
  the grid downward while the model moves toward older rows. A value of 1.26
  at scale 2 therefore reports 1.5 points and applies a positive three-device-
  pixel translation.
- Insets are hard clipping boundaries: glyphs, backgrounds, images, decorations, selection, and cursor do not leak into window chrome.
- Fractional top insets round outward to the next device pixel; left and bottom
  insets round to the nearest device pixel.
- Zero or invalid geometry produces no draw rather than negative rectangles, integer overflow, or out-of-bounds access.
- A single-width row maps one terminal column to one cell width. Double-width rows scale the row horizontally by two. Double-height upper/lower rows show the corresponding half of the same doubled glyph geometry while retaining terminal cell addressing.

## 5. Text, clusters, and color

- Terminal shaping disables contextual and standard/discretionary ligatures that would merge independent cells. Visible sequences such as repeated punctuation remain addressable by cell.
- CoreText clusters that correctly belong to one terminal cell, including combining sequences and emoji ZWJ sequences, remain intact.
- Explicit UTF-16 boundaries preserve the engine's cell-to-column addressing,
  but do not disable normal Unicode shaping across adjacent boundaries. Hangul
  Jamo may therefore compose into the first covered cell while the continuation
  cell remains addressable and emits no separate glyph.
- Missing glyphs, zero-area glyphs, malformed attributes, and oversized raster requests fail safely and do not corrupt adjacent atlas entries. A single rasterized glyph is bounded to 2048 pixels per dimension.
- Grayscale glyph coverage and color glyph pixels are distinct paths. Drawing the first color glyph may allocate color storage; ASCII-only panes must not pay that allocation.
- Atlas padding, when enabled, is transparent around the glyph and cannot bleed a neighbor's texels.
- Uniform printable, single-width ASCII may reuse an immutable prepared
  CoreText line for repeated code units. Reuse must retain the original
  per-cell origin, frozen-glyph clip, coverage, tint, background, and
  decoration behavior; cached and uncached raster output is byte-identical at
  both 1x and 2x. Unicode clusters and mixed attribute runs stay on the full
  shaping path.
- `TextRenderingMode` behavior is:

  | Mode | Y placement | Atlas padding | Sampling | Coverage |
  | --- | --- | --- | --- | --- |
  | `current` | common device-pixel baseline | none | linear | normal |
  | `y-snap` | common device-pixel baseline | none | linear | normal |
  | `atlas-padding` | common device-pixel baseline | transparent gutter | linear | normal |
  | `nearest` | common device-pixel baseline | none | nearest | normal |
  | `high-contrast` | common device-pixel baseline | none | linear | stronger |
  | `crisp` | common device-pixel baseline | transparent gutter | linear | stronger |

- Attributed foreground/background, compatibility selection background, underline kind/color, strike-through, font traits, dimming, inverse video, and cursor-cell colors are honored exactly as delivered by the shaping seam. A live source may instead provide dynamic selected-column spans and a selection color without changing row versions.
- Grayscale text preserves the frozen foreground-alpha blend: glyph RGB is
  premultiplied by glyph coverage but not by attributed foreground alpha;
  foreground alpha instead reduces the destination contribution. This can
  leave a solid glyph interior at the delivered RGB intensity even when its
  attributed alpha is below one.
- An omitted run background means the native terminal background; an explicit background is painted for the run.
- Underline position/thickness are derived from the source metrics and stay visible at small scales. Curly, dotted, dashed, double, and single underlines remain visually distinct.

## 6. Composition and draw order

Within the clipped content region, the semantic order is:

1. native terminal clear/background, per-cell backgrounds, and dynamic selection spans (selection replaces covered explicit backgrounds);
2. grayscale and color glyphs;
3. underline, strike-through, block, and box-drawing decoration geometry;
4. Kitty placeholder images;
5. every ordinary image in source-array order, regardless of z-index; and
6. the terminal cursor and, when selected, a full-scene post-process.

Consequences that are part of the contract:

- ordinary images, including negative-z images, can cover foreground text and
  Kitty placeholders; the frozen compositor does not split them into under-
  and over-content passes;
- selection and explicit cell backgrounds stay behind glyph coverage, and changing a dynamic selection span does not rebuild row textures;
- Databloom alters grayscale text only, not cell backgrounds, color emoji, images, decorations, or the cursor;
- a full-scene shader sees the completed terminal scene, including cursor, unless that shader's documented mode is text-only; and
- turning shaders off returns the ordinary scene without residual state.

## 7. Images and Kitty graphics

- Ordinary image textures are cached by object identity, not only by pixel equality. Cache ownership must not retain dead source image objects indefinitely.
- Kitty textures are keyed by image identifier plus payload signature. Reusing an identifier with changed bytes replaces the texture.
- `kittyLiveImageIds` prunes deleted images promptly. Repeated invalid data has bounded failure bookkeeping and does not trigger allocation or decode work every frame.
- Ordinary image width and height are `pixelWidth`/`pixelHeight` multiplied by
  both backing scale and `getImageScale()`. Placement starts at the image's row
  and anchor column. Its Kitty-named pixel offsets and z-index do not alter the
  frozen ordinary-image rectangle or compositing pass.
- Kitty virtual placement dimensions form a terminal-cell container. Payloads
  aspect-fit within that container, then each placeholder cell clips its own
  portion. Pixel offsets are scaled to device pixels; positive x moves right
  and positive y moves upward. Unpacked RGBA payloads use the frozen bottom-up
  image orientation.
- Alternate and primary buffers never share placements accidentally.
- Image edges are clipped to terminal content and retain stable placement during scroll, resize, and row-cache reuse.

## 8. Cursor contract

- A hidden cursor is not drawn. A cursor outside the visible rows is not drawn.
- A focused cursor is solid; an unfocused block cursor is hollow. Steady styles never blink. Blink styles use a smooth 1.2-second cosine opacity pulse only while focused, visible, and recently active, then settle without a periodic idle timer. A pulse trough is not structural hiding: cursor glide continues through it, while engine- or host-hidden cursors synchronize directly to the newest target.
- Block, underline, and bar shapes are distinct and device-pixel aligned. A block cursor redraws the attributed cell under it with cursor foreground/background colors.
- The cursor's glyph-height region uses the font's natural height, even when line-height expansion makes the cell taller.
- With glide disabled, the drawn cursor follows the engine cell immediately. With glide enabled, motion uses exponential pursuit at `40 * clamp(cursorGlideSpeed, 0.1...8)` with elapsed time clamped to `0.001...0.05` seconds and settles within 0.5 device pixel. A positive maximum distance snaps jumps beyond that Euclidean cell distance; zero means no distance limit.
- Live resize pins the glide state directly to the newest cursor target so geometry changes cannot leave a delayed chase after release. While a focused block cursor is gliding, its block moves but the glyph-under-cursor inversion waits until the glide settles.
- Hiding the host cursor suppresses renderer cursor output without changing engine cursor state.

## 9. Damage, cache, and memory contract

- Static retained rows are reused across frames. A one-line edit does not rebuild the viewport.
- A viewport move translates cached retained rows and builds only newly exposed or changed rows. View geometry translation alone does not rebuild row content.
- Cache identity includes all pixel-affecting row inputs: retained coordinate epoch, line version/content, line mode, font/scale/cell metrics, active buffer, style inputs, graphics stamp, and renderer preset.
- A scale, font, cell geometry, buffer epoch, graphics generation, or explicit cache invalidation cannot leave stale pixels.
- Row cache residency is bounded to roughly three visible viewports, not total scrollback.
- The two `MetalBufferingMode` cases may use different storage strategies but must produce equivalent pixels. Changing mode cannot show stale buffers.
- Immutable device/pixel-format/sample-count resources are shared between panes. Resources with a different device, color format, or sample count are not shared incorrectly.
- Stable workloads stop allocating row/frame storage after warm-up. Transient
  buffer offsets satisfy Metal's 256-byte alignment requirement and capacity
  grows safely for larger frames.
- Per-pane retained row textures are capped at an exact 20 MiB sum of Metal
  `allocatedSize` values and roughly three visible viewports. ASCII rows use R8
  coverage; BGRA storage is lazy and sparse for color glyphs.
- Eviction invalidates every cache entry that refers to evicted storage. A
  frame encountering eviction may rebuild once; it must never present a mixed
  generation. Compatibility glyph-atlas hooks are isolated from the production
  row path and remain independently bounded.

## 10. Scrolling and animation

- Precise trackpad scrolling holds the sub-cell offset supplied by AppKit and updates as events arrive. Discrete wheel input may glide, but its visual backlog is capped at 1.25 rows and settles by approximately 95% within 75 ms. Crossing whole rows updates the engine viewport while the renderer retains only a sub-cell translation.
- Active scroll presentation follows the key window's display cadence (60 Hz or 120 Hz, subject to thermal protection). The lower static-content cadence resumes after the interaction window; background windows remain power-throttled.
- `onScrollOffsetChanged` reports the snapped point offset actually shown.
- Cancelling scroll animation immediately removes residual glide. Disabling smooth scrolling renders at the engine's row position with no leftover translation.
- Reactive scroll energy preserves direction, responds visibly to a single small wheel notch, and settles to exact zero. Once zero, it does not schedule frames.

## 11. Shader and power behavior

- Shader mode zero is ordinary rendering. Built-in post-process modes require an offscreen scene only when their pipeline exists. Databloom mode 68 is text-only and does not require a full offscreen scene. Mode -1 selects a successfully compiled custom program.
- Timeless custom shaders do not create an animation loop. Time-dependent shaders animate only while visible.
- Live resize may temporarily show the ordinary single-pass scene; the selected shader returns when live resize ends.
- A fully occluded window presents at most two tail frames in five seconds. A static scene, including a static shader, presents at most two frames in six seconds after settling.
- Nominal animation targets are 60 fps for the key window and 5 fps for a visible non-key window; low-power non-key target is 2 fps. Serious thermal pressure limits key/non-key targets to 30/3 fps; critical pressure limits them to 20/2 fps.
- Cursor blink runs at the renderer's adaptive animation cadence during the recent-activity period and must settle with an explicit full-opacity frame after approximately 12 seconds of inactivity. Unfocused or occluded cursors do not sustain a blink loop.
- Compile, pipeline, texture, and shader-resource failures degrade to usable ordinary terminal rendering and surface a diagnostic; they do not crash or repeatedly block the main thread.

## 12. Performance acceptance budgets

These are regression ceilings/floors, not target architecture. A replacement may be faster or use less memory.

| Workload | Required result |
| --- | --- |
| settled idle | at most 2 presented frames in 6 seconds |
| re-settled idle | at most 2 presented frames in 5 seconds |
| 200-line burst | at most 120 frames and 500 rebuilt rows |
| one prompt-line edit | at most 8 rebuilt rows; reused rows at least rebuilt rows |
| 20 benign prompt redraw sequences | at most 80 rebuilt rows |
| 20 Return presses | exactly 20 rows advanced; at most 200 rows rebuilt |
| 20 one-line scroll steps, each direction | at most 60 rebuilt rows per direction |
| 3 MiB end-to-end PTY-to-GPU drain | tail marker visible within 6000 ms |
| static shader after settling | at most 2 frames in 6 seconds |
| animated shader, occluded | at most 2 frames in 5 seconds |
| animated shader, focused and visible | 200 through 350 frames in 5 seconds |
| animated shader, visible non-key | 25 through 120 frames in 5 seconds |
| two panes draining 1 MiB each concurrently | both tail markers within 6000 ms |

Interactive work must not synchronously wait for a drawable, image decode, shader compilation, process output, or completion of another pane's frame. Opening many panes must scale through shared immutable GPU resources and per-pane bounded caches.

## 13. Verification matrix

Run from the repository root on macOS with Metal available:

```sh
swift test --package-path Renderer
swift test --package-path Renderer -c release
python3 -B scripts/check-renderer-pixel-parity.py --self-test
python3 -B scripts/check-renderer-pixel-parity.py
./package.sh
Tests/perf-gate.sh
CMDY_PERF_MAXIMIZED=1 Tests/perf-gate.sh
Tests/zoo.sh
```

The pixel command hash-validates the vendored locked historical corpus, then
compiles and runs the neutral public-API fixture only against the candidate. It
requires byte-identical declared inputs and zero differing pixels at both
scales. Raw normalized RGBA, PNGs, exact channel deltas, hashes, and the
comparison manifest are written to a new temporary directory outside the
repository. There is no implicit tolerance or exception list. A separate
explicit `--reference-build` mode remains available for forensic reconstruction
runs but is not the release authority. See `Tests/RendererPixelOracle/README.md`
for the corpus trust boundary and artifact layout.

Blink verification is deliberately two-part. The exact pixel oracle compares
every blinking cursor style with the durable historical corpus at its recorded
fully-visible phase, covering cursor geometry, color, glyph inversion, and
scale with zero pixel tolerance. The candidate reaches that phase through its
public activity and static-content pacing controls. Deterministic renderer tests
are authoritative for the temporal behavior: the 1.2-second cosine curve,
activity-relative restart, trough/glide interaction, and final full-opacity
expiry frame. This avoids treating unrelated implementation-local clock epochs
as pixel differences without weakening either contract.

The renderer package suite is the fast contract for:

- terminal-cell shaping and UTF-16 mapping;
- row-raster residency, retained compatibility-atlas paging, transparent
  padding, lazy color allocation, buffer alignment, coordinate snapping,
  scissor geometry, and renderer presets;
- cursor glide and natural cursor glyph height;
- shared core Metal resources; and
- shader scheduling, offscreen-scene selection, and scroll-energy behavior.

`Tests/perf-gate.sh` is authoritative for frame, row-rebuild, throughput, multi-pane, and idle-energy budgets. The zoo is the visual comparison for shell prompts, Unicode, Vim, `man`, `less`, `htop`, tmux, large output, graphics, themes, selections, cursor styles, line modes, images, scrollback, resize, and shaders.

Before declaring parity, capture deterministic screenshots at 1x and 2x scale for:

- ASCII and styled text on default and explicit backgrounds;
- combining text, emoji ZWJ, color emoji, CJK wide cells, and adjacent Jamo cells;
- every cursor and underline style;
- the complete U+2500...U+257F and U+2580...U+259F grids;
- single-, double-width, and both double-height line halves;
- negative/zero/positive-z images and Kitty placeholders;
- top/bottom/left insets and fractional smooth scroll; and
- every text-rendering preset with shaders off.

## 14. Allowed implementation freedom

Conformance does not require Metal, CoreText, the current cache layout, current shader organization, current vertex formats, current atlas dimensions, or current buffer count. Those may be replaced freely when the public boundary, pixels, lifecycle, failure behavior, bounded memory, energy behavior, and performance budgets remain satisfied.

Internal ABI sizes are not public API. If Swift and shader stages share binary structures, their layouts must agree and tests must catch drift; callers must not depend on the current internal strides.
