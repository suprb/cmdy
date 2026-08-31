# Cmdy built-in shader gallery provenance

Status: engineering provenance note; not legal certification

The active replacement gallery, classified as Cmdy-authored by the engineering
inventory and still subject to final human provenance review, is
`Renderer/Sources/CmdyGPU/BuiltInEffectShaders.swift`.
It contains Cmdy-authored effect formulas transplanted from only these approved
regions of the frozen renderer source:

- Databloom additions: `Shaders.metal` lines 111–159.
- Scene post-process helpers, uniforms, entry points, and modes 1–67:
  `Shaders.metal` lines 205–1264.

Repository evidence in `PROVENANCE_INVENTORY.md` attributes those additions to
Andreas Pihlström commits `d2ce06f1b093`, `382b973bb9ed`, `c077add57fe1`,
`98c75cf88994`, `c03c5a8b5d84`, `79a940347564`, and `a652a3c0afe1`.

The transplant explicitly excludes imported base-renderer lines 1–110 and
160–204. It does not use the inherited glyph/text/color structs, inherited
scene entry-point bodies, `Vendor/SwiftTerm`, or an old renderer Swift
implementation. Historical attribution remains in the repository notices.

## Independent boundary and mode contract

All former `t64_*` helpers, CRT wrapper declarations, and legacy shader entry
points were renamed into the `Cmdy*` / `cmdy_*` namespace. The fullscreen scene
vertex boundary and glyph-coverage vertex boundary are independently defined.
The Databloom wrapper samples the independent renderer's two-dimensional glyph
coverage texture; its Cmdy-authored color, alpha, slice, and palette formulas
are otherwise retained.

- Modes 1–67 run in `cmdy_scene_effect_fragment` against the completed scene.
- Mode 68 runs only in `cmdy_databloom_glyph_fragment` while drawing grayscale
  glyph coverage. It must not be used for cell backgrounds, color glyphs,
  images, decorations, or the cursor.
- The mode table in Swift enumerates 1 through 68 exactly once and records that
  scope distinction.

## Renderer integration contract

Compile `CmdyBuiltInEffectShaders.metalSource` with
`MTLDevice.makeLibrary(source:options:)`, or call its `makePipelines` helper.

Scene post-process pipeline:

- vertex: `cmdy_scene_effect_vertex`; draw a three-vertex fullscreen triangle;
- fragment: `cmdy_scene_effect_fragment`;
- fragment texture 0 / sampler 0: completed scene / linear clamp sampler;
- fragment buffer 0: resolution (`float2`), time, curvature, background
  (`float4`), cursor (`float2`), keypress age, and typing rate;
- fragment buffer 1: signed 32-bit mode in 1...67.

The scene buffer is the first 48 bytes of the independent renderer's current
`IndependentCmdyUniforms`, so that Swift struct can be bound directly. Mode is
kept separate to preserve the approved formula interface.

Databloom glyph pipeline:

- vertex: `cmdy_databloom_glyph_vertex`;
- vertex buffer 0: interleaved position (`float2`), UV (`float2`), color
  (`float4`) quads; vertex buffer 1 begins with resolution (`float2`);
- fragment: `cmdy_databloom_glyph_fragment`;
- fragment texture 0 / sampler 0: grayscale glyph coverage / linear sampler;
- fragment buffer 0: coverage power (`float`);
- fragment buffer 1: energy, velocity, opacity, and pass index (four `float`s).

Bind each Databloom pass explicitly and draw only the eligible glyph quads.
The fragment returns premultiplied color, so use source-one /
one-minus-source-alpha blending. Mode 68 never requires an offscreen scene.

`BuiltInEffectShadersTests` compiles the Metal library and both render
pipelines, verifies all four entry points, rejects legacy symbols, and proves
the exact 1...68 mode partition.
