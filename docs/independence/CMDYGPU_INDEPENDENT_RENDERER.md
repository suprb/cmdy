# CmdyGPU independent renderer

Status: replacement implementation active; tests, performance gates, and the
locked 40-fixture renderer corpus are exact. Clean committed-source release
qualification and independent human provenance approval remain pending.

## Clean-room boundary

`Renderer/Sources/CmdyGPU` is a new implementation built from the
neutral renderer contract, the frozen public declaration manifest, black-box
tests and artifacts, public App call sites, and Apple framework APIs. It does
not depend on the retired renderer source tree. The built-in effect formulas
have their own provenance record and integration contract in
`CMDY_SHADER_GALLERY.md`.

The Swift package keeps the module and product name `CmdyGPU`; only the target
path changes. The public symbol graph remains equal to the frozen module after
the reviewed underline-key identifier rename. Its raw attributed-string value,
the selection key's raw value, and the declaration-only `TTColor`, `TTFont`,
and `TTImage` aliases remain source compatible.

## Rendering design

The renderer is organized around retained absolute terminal rows rather than a
glyph atlas and cell batch:

1. A draw captures one `GridSnapshot` and all row identities use its retained
   coordinate epoch.
2. CoreText and CoreGraphics rasterize each changed row into an R8 coverage
   texture. Per-run tint spans color that coverage at composition time.
3. Backgrounds, selection, underlines, strikes, blocks, and cursors remain
   lightweight solid geometry. Color glyphs allocate only sparse BGRA tiles.
4. Composition order matches the frozen compositor: backgrounds, row text and
   color glyphs, decorations, Kitty placeholders, all ordinary images in source
   order regardless of z-index, then cursor.
5. Modes 1 through 67 consume an optional completed scene texture. Mode 68
   consumes glyph coverage directly and never allocates an offscreen scene.

Row keys include retained origin, version, line mode, dimensions, scale, font,
buffer identity, graphics stamp, colors, rendering preset, block-antialias
choice, and buffering mode. Geometry-only movement translates cached textures
without rebuilding them.

## Residency and lifetime

- Row residency is limited to three viewports and an exact 20 MiB sum of Metal
  texture `allocatedSize` values. Visible rows are protected while older rows
  are evicted least-recently-used.
- ASCII rows allocate R8 only. BGRA storage is lazy and restricted to color
  glyph tiles.
- Pipeline state, samplers, shader libraries, and the command queue are shared
  for a device/pixel-format/sample-count tuple. Command buffers remain local to
  a renderer and at most one frame build is in flight per pane.
- Ordinary image decoding and Kitty PNG decoding run off the main actor and
  coalesce duplicate requests. Image owners are weak, and stale identities are
  pruned.
- A dormant shader releases its scene texture. Missing, occluded, and detached
  views do not start recovery or animation loops.

## Scheduling

Static built-ins 2, 5, and 6 settle after their requested frame. Modes 9 and 68
run only while their scroll envelope has energy. The other scene modes animate
continuously at the documented focus, power, and thermal rates. User shaders
animate only when their source uses `u.time`. Cursor animation requires an
on-screen, focused, blinking cursor within the recent-activity interval.

## Verification

From the repository root:

```sh
swift test --package-path Renderer -c release
python3 -B scripts/check-renderer-pixel-parity.py --self-test
python3 -B scripts/check-renderer-pixel-parity.py
./scripts/check-independent-api.sh
python3 -B scripts/check-working-tree-provenance.py --mode check
swift build -c release
CMDY_CONFIG_DIR="$(mktemp -d /tmp/cmdy-renderer-selftest.XXXXXX)" \
  .build/release/cmdy --selftest
```

Focused tests additionally exercise R8/BGRA allocation, exact cache residency,
shared resources and queue identity, asynchronous image decode, deterministic
row-layer planning, clipping, cursor scheduling, shader scope and scheduling,
shaping boundaries, and the built-in Metal pipelines.

### Frozen-reference pixel audit and discrepancy history (2026-08-21)

The first strict public-API run against
`/private/tmp/cmdy-independent-old-renderer-build` exposed 3 exact captures out
of 40 and 66,167 differing pixels, with byte-identical public inputs. That
checkpoint was retained as diagnosis only. The frozen observable result was
selected as the parity authority, no tolerance or exception was accepted, and
the conflicting prose in the [behavioral contract](CMDYGPU_CONTRACT.md) was
amended to the measured semantics below.

| Fixture and exact input | Measured frozen pixels or geometry | Earlier prose conflict | Adopted exact behavior |
| --- | --- | --- | --- |
| `insets-fractional-scroll`, scale 2, scroll y = 1.26 | Content ends at device y = 397: an effective -1 px translation and 0.5-point callback value. | Section 4 had specified -3 px and 1.5 points. | Round the public value first, translate by that device-pixel result, and divide by scale for the callback. |
| `ascii-styles-backgrounds`, row 4, foreground alpha = 0.45 | A solid glyph interior is `(229,238,252,255)`. | Section 5 implied ordinary source-alpha compositing. | Premultiply RGB by glyph coverage, not attributed foreground alpha; alpha reduces destination contribution. |
| `unicode-clusters`, Jamo boundaries `[0,1,2,3]` | The Jamo compose in column 14 and column 15 emits no glyph. | Sections 3.2 and 5 had said boundaries prevent composition. | Boundaries retain cell addressing while CoreText may shape across them; the first cell owns and clips the composed glyph. |
| `image-z-layers-kitty`, ordinary image z = -2 | At 1x the image covers text through x = 91; foreground resumes at x = 94. | Section 6 had put negative-z images below text. | Every ordinary image composites over row content and Kitty placeholders in source-array order, independent of z-index. |
| Ordinary image `84x20`, y offset = 2 | It is `84x20` at y = 36 at 1x and `168x40` at y = 72 at 2x; the offset has no visible effect. | Section 7 had required the offset to affect placement and left dimension units ambiguous. | Multiply dimensions by backing scale and image scale; ignore Kitty-named offsets for ordinary images. |
| Kitty placement, 3 columns x 1 row, offsets `(1,2)` | Payload colors occupy x = 171...175, y = 156...177 at 1x and x = 342...350, y = 312...355 at 2x. | Section 7 did not define aspect-fit, direction, or per-cell clipping precisely. | Aspect-fit in the placement container, move positive x right and positive y up in device pixels, then clip each placeholder cell and preserve bottom-up payload orientation. |

The remaining failures were systematic rather than exceptions: a common
three-device-pixel text baseline shift, frozen line-mode atlas allocation and
sampling order, and exact rounded-annulus/diagonal endpoint quantization. They
were corrected at their source-level geometry and sampling boundaries. The
[oracle](../../Tests/RendererPixelOracle/README.md) now passes all complete box
and block grids, every line mode, and all text presets at both scales.

The historical reference binaries were neither recovered nor reproduced
bit-for-bit. Rebuilding the retained baseline recipe produced different
CmdyGPU module and object-set hashes, so that reconstructed build is not
represented as the original binary. It did reproduce the complete 40-capture
normalized RGBA/PNG corpus with a manifest and fixture index byte-identical to
the hashes retained from the historical reference run.

Those observed bytes are now frozen in
`Tests/RendererPixelOracle/ReferenceCorpus/`. The canonical archive SHA-256 is
`5507d54ebe8e453edc9f38d3dbf84ac01ef132ae8370a3a7de39a1624d46188a`;
its reference manifest is
`868ffcb241e050c570278e5d6aa7fef2adfb6b15b938bee13e8917b7bd42d7b6`.
The canonical gate hash-validates the lock, archive, metadata, complete
inventory, raw/PNG bytes, and public-input descriptors before rendering only
the current candidate. The final recorded run passes 40/40 exactly, with zero
pixel failures, zero public-input failures, zero differing pixels, and no
exceptions; its `comparison.json` SHA-256 is
`c6de090c7605fea74481beed8b68c4fdd9d27c736713798b5099f578c95ed239`.

This establishes behavioral parity for the documented fixture matrix. It does
not by itself establish source authorship or legal clean-room status. An
independent human provenance review bound to the exact committed source remains
required before an unqualified independence claim.
