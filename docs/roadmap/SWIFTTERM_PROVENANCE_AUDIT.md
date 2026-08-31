# SwiftTerm provenance audit

Status: replacement source is present. The exhaustive Unicode gate, 17-seed
Core public-ABI matrix, source/API checks, locked renderer corpus, app
performance/resource suites, TUI zoo, and local package rehearsals pass. Clean
committed-source qualification, notarization, and the independent human
reviewer verdict remain pending. This is engineering evidence, not legal
clean-room certification.

cmdy has no runtime, linked-product, vendored-framework, import, or Swift
package dependency on SwiftTerm. Source provenance is evaluated in two separate
layers:

1. The immutable pre-replacement history inventory in
   [`PROVENANCE_INVENTORY.md`](../independence/PROVENANCE_INVENTORY.md) and
   [`LINEAGE_REGIONS.generated.md`](../independence/LINEAGE_REGIONS.generated.md).
2. The fail-closed active-tree scan in
   [`scripts/check-working-tree-provenance.py`](../../scripts/check-working-tree-provenance.py),
   which includes tracked, modified, and untracked terminal-stack source.

The history report answers where the old boundary came from. It does not scan
uncommitted replacement files. The active-tree gate compares those files with
both the initial vendor import and the retired implementation, rejects retired
source roots/imports/package references, and requires each expected declaration
or standard-mechanic match to have a narrow reviewed classification. Neither
tool alone proves independent authorship.

## Frozen pre-replacement lineage

At baseline ref `584624985809f6000a82d3b3b97e43ef885af572`, Git history
records direct or conservative adapted lineage in these historical paths:

- `Core/Sources/TermitePTY/Pty.swift`
- `Core/Sources/TermitePTY/LocalProcess.swift`
- `Core/Sources/TermiteCore/UnicodeWidth.swift`
- `Renderer/Sources/TermiteGPU/BlockElementRenderer.swift`
- `Renderer/Sources/TermiteGPU/BoxDrawingRenderer.swift`
- `Renderer/Sources/TermiteGPU/CoreTextGlyphRasterizer.swift`
- `Renderer/Sources/TermiteGPU/GlyphAtlas.swift`
- `Renderer/Sources/TermiteGPU/MetalBufferingMode.swift`
- `Renderer/Sources/TermiteGPU/MetalError.swift`
- `Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift`
- `Renderer/Sources/TermiteGPU/Shaders.metal`
- `App/TermiteCoreShaping.swift`
- `App/TermiteCoreSurface.swift`

Several historical renderer files contained later cmdy-authored additions.
That does not erase the older regions' provenance. The exact per-region report
and the narrowly approved built-in shader-gallery transplant are documented in
the frozen inventory and
[`CMDY_SHADER_GALLERY.md`](../independence/CMDY_SHADER_GALLERY.md).

## Active replacement boundary

The replacement tree uses these source boundaries instead:

- `Core/Sources/CmdyPTY/` and `Core/Sources/CmdyPTYShim/` for PTY transport;
- official Unicode 17 inputs plus generated tables under
  `Core/Sources/CmdyCore/Generated/` for width policy;
- `Renderer/Sources/CmdyGPU/` for the renderer; and
- `App/CmdySnapshotShaper.swift`, `App/CmdyTerminalSurface.swift`, and
  `App/CmdyCoreAdapter.swift` for the App seam.

The rest of `Core/Sources/CmdyCore/` originated as cmdy's replacement engine,
not as a move from the initial vendored SwiftTerm tree. Because that engine was
developed while SwiftTerm was available as a behavioral oracle, it remains in
the current-tree similarity review. Large retained CmdyCore files are accepted
only by exact reviewed file hashes; changing one invalidates the classification
and makes the gate fail closed until the final diff is reviewed.

Compatibility declarations, official Kitty protocol data, raw attributed-key
values, ordinary platform mechanics, and demonstrably cmdy-authored shader
formulas can produce expected matches without carrying an implementation.
Every such match is enumerated in
`docs/independence/WORKING_TREE_PROVENANCE_ALLOWLIST.json`; there is no wildcard
path or generic "known source" exemption.

## Reproduce the active-tree review

Run from the repository root with full Git history available:

```sh
python3 -B Tests/test-working-tree-provenance.py
python3 -B scripts/check-working-tree-provenance.py --mode check
./scripts/check-independent-api.sh

for cmdy_package in Core Renderer; do
  swift package --package-path "$cmdy_package" \
    show-dependencies --format json \
    | jq -e --arg package "$cmdy_package" \
      '.name == $package and (.dependencies | length == 0)' >/dev/null
done

swift package show-dependencies --format json \
  | jq -e \
    '[recurse(.dependencies[]?)
      | ((.name // "") + " " + (.url // "") + " " + (.path // ""))
      | test("SwiftTerm"; "i")] | any | not' >/dev/null
```

Use `--mode report --format json` only for review/triage; report mode returns
success even when findings are unresolved. Release evidence must use the
default/check mode. In CI, `actions/checkout` uses full history because the
scanner resolves the two frozen comparison commits.

To reproduce only the historical baseline report, use the command recorded in
`PROVENANCE_INVENTORY.md`. Running the history tool with `--ref HEAD` is not a
substitute for the working-tree scan when files are modified or untracked.

## Remaining release decision

Before saying "100% independently implemented":

1. Commit the exact source under review and rerun the complete matrix from a
   clean checkout, including active-tree provenance and exact public API.
2. Produce a notarized, stapled distribution and pass Gatekeeper checks rather
   than relying on a signed local rehearsal.
3. Have an independent reviewer validate the inventory, classifications,
   process, and proposed public wording.
4. Preserve SwiftTerm's complete MIT notice for historical distributions and
   Git history. Never rewrite prior-release attribution.

Until those steps finish, the accurate statement is:

> cmdy's replacement terminal stack is active and has no SwiftTerm runtime or
> package dependency. Core/source/renderer engineering gates and local app
> qualification are green; clean-tree release qualification, Apple notarization,
> and independent provenance review remain pending.
