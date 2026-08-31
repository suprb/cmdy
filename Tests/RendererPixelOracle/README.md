# CmdyGPU black-box pixel oracle

This oracle is the deterministic 1x/2x gate required by
`docs/independence/CMDYGPU_CONTRACT.md` section 13. Its canonical mode compares
the current candidate with a locked historical capture corpus. No historical
implementation is loaded into the candidate process.

## Authority boundary

`RendererPixelFixture.swift` uses only the public `CmdyGPU` API and Apple
frameworks. The canonical orchestrator compiles it into one executable that
statically links only the candidate module and object set. It validates the
vendored corpus lock and validator vector, canonical gzip/tar bytes and
metadata, complete 40-fixture inventory, manifest and index hashes, and every
referenced raw RGBA, PNG, and canonical public-input hash before comparison.
The historical manifest hash is fixed at
`868ffcb241e050c570278e5d6aa7fef2adfb6b15b938bee13e8917b7bd42d7b6`.
Any missing, additional, reordered, linked, noncanonical, or altered corpus
payload fails closed.

The runner presents a real visible `MTKView`, retains the exact
`CAMetalDrawable` that the public renderer delegate presents, waits for Metal
completion, and blits that drawable into shared memory. BGRA bytes are
normalized to top-left RGBA before any comparison. The view uses an explicit
sRGB color space, BGRA8-unorm drawable, one sample, fixed point dimensions, and
explicit 1x or 2x source/drawable scale.

Blinking cursors have implementation-local epochs: the historical renderer
uses a wall-clock phase, while the candidate starts its pulse at public
activity. The durable reference corpus stores the historical fully-visible
phase. At each scale the runner captures the corresponding steady style first;
before every blinking candidate sample it resets the public static-content
pacing control and reports public activity, producing that same fully-visible
phase deterministically. The renderer's `CursorPulse` tests separately verify
the 1.2-second temporal curve, activity-relative epoch, trough behavior, and
final settled frame. This two-part contract keeps the exact pixel gate
spatial/color strict without comparing unrelated scheduler phases; it adds no
tolerance or exception. A complete-cycle nearest-frame search remains useful
only in forensic build-vs-build runs.

Every capture also records a canonical public-input descriptor. It includes
font identity and metrics, attributed runs, UTF-16 cell boundaries, grid and
line state, source colors and geometry, drawable/color-space state, cursor,
images and their bytes, Kitty payloads, procedural items, renderer controls,
and scale. The comparison reports field-level differences instead of silently
assuming the two compiled modules resolved public values identically.

## Matrix

The runner defines 20 fixtures and captures each at 1x and 2x, for 40 exact
comparisons:

- ASCII, font traits, strike-through, dim/inverse color, selection, default and
  explicit backgrounds;
- combining text, emoji ZWJ, color emoji, CJK wide cells, adjacent Jamo cells,
  and explicit UTF-16 boundaries;
- all six cursor styles and all six underline styles;
- the complete U+2500...U+257F box-drawing grid and complete
  U+2580...U+259F block-element grid;
- single width, double width, and both double-height halves;
- ordinary negative-, zero-, and positive-z images plus an RGBA Kitty
  placeholder;
- top, bottom, and left insets with 1.26-point fractional scroll; and
- all six `TextRenderingMode` presets with `shaderMode == 0`.

## Running the gate

The vendored locked corpus under `ReferenceCorpus/` is the default and the
release authority:

```sh
python3 -B scripts/check-renderer-pixel-parity.py --self-test

python3 -B scripts/check-renderer-pixel-parity.py
```

`--reference-captures` may explicitly name the corpus directory, its lock, or
its archive. `--reference-build /path/to/build` instead enables the retained
forensic build-vs-build mode. That mode requires exactly one matching release
module/object set and rejects self-comparison, but independently scheduled
animation clocks mean it is not the release oracle.

Without `--candidate-build`, the script builds `Renderer` in release mode. An
explicit `--output` must name a new or empty directory outside the repository;
when omitted, the script creates a unique `/tmp` directory. The test machine
must be arm64 macOS with Metal, Menlo-Regular 14 pt, and a visible WindowServer
session. Only the candidate is rendered in canonical corpus mode.

Exit status is `0` only when all public-input descriptors are byte-identical
and every normalized pixel is byte-identical. Pixel or input mismatch returns
`1`; invalid build artifacts, malformed outputs, or unavailable infrastructure
returns `2`. The accepted exception list is empty, and the gate has no
threshold or exception path: any mismatch fails.

## Result artifacts

The external result directory contains:

- `RendererPixelFixture.swift`, the immutable neutral source snapshot compiled
  into the candidate executable during that run;
- `environment.json`, including the corpus lock/vector/archive/payload hashes
  and candidate module, object-set, and fixture-source hashes;
- `candidate-runner/link-inputs.json`; forensic build-vs-build runs additionally
  include `reference-runner/link-inputs.json`;
- `reference/` and `candidate/`, each with `fixture-index.json`, `manifest.json`,
  normalized `.rgba`, and presentation `.png` files;
- `diff/*.delta.rgba`, containing the exact absolute per-channel byte delta;
- `diff/*.diff.png`, a deterministic visualization of that same delta; and
- `comparison.json`, containing strict pass/fail, hashes, exact differing pixel
  and channel counts, bounding boxes, and field-level public-input mismatches.

PNG files are evidence and viewing aids. The normalized RGBA hashes and exact
RGBA delta are the acceptance authority.
