# Terminal-stack provenance inventory

Status: historical inventory frozen before replacement; active-tree final review pending; not legal certification

Baseline ref: `584624985809f6000a82d3b3b97e43ef885af572`

Initial vendored-source import: `512b859268662b8e01f5923fabd7958e12e280df`

## Evidence and limits

The exact region report is `LINEAGE_REGIONS.generated.md`. It was produced with:

```sh
python3 scripts/audit-swiftterm-lineage.py \
  --ref 584624985809f6000a82d3b3b97e43ef885af572 \
  --import-ref 512b859268662b8e01f5923fabd7958e12e280df \
  --output docs/independence/LINEAGE_REGIONS.generated.md
```

The script uses move/copy-aware `git blame --line-porcelain -C -C -M`, groups contiguous lines by classification and nearest declaration, and records commits and historical paths. The frozen generated report has SHA-256 `910688101538a43440f5698aa369badc953b36a9cbb2bef1cae7ab48142b432c`.

Its baseline totals are:

| Classification | Lines | Meaning |
| --- | ---: | --- |
| `confirmed-derived` | 4,642 | Git attributes the region to the initial source import under `Vendor/SwiftTerm` |
| `vendor-era-uncertain` | 992 | changed while the implementation still lived under the vendor path; conservatively not certified original |
| `cmdy-addition` | 148 | whole helper files introduced after extraction with cmdy product purpose |
| `post-extraction-review` | 4,231 | later line history; requires review and is not automatically clean-room or original |

Git ancestry can prove some copying or movement, but it cannot prove independent authorship. A later commit, path rename, or rewritten line is not by itself an originality certificate. Conversely, a behaviorally compatible declaration or test is not necessarily derived implementation. Final public claims require an independent human review in addition to this report.

This generated inventory intentionally names the historical `Termite*` source
paths at the baseline ref. It is not a report over the current working tree.
The active replacement paths are `Core/Sources/CmdyCore/`,
`Core/Sources/CmdyPTY/`, `Core/Sources/CmdyPTYShim/`,
`Renderer/Sources/CmdyGPU/`, `App/CmdySnapshotShaper.swift`, and
`App/CmdyTerminalSurface.swift`. They are checked independently by
`scripts/check-working-tree-provenance.py`, including when modified or
untracked.

## Exact conservative replacement boundary

### PTY/process transport: direct lineage

The generated report assigns exact regions and nearest declarations for all of:

- `Core/Sources/TermitePTY/Pty.swift`, including `PseudoTerminalHelpers`, `fork`, `setWinSize`, and `availableBytes`;
- `Core/Sources/TermitePTY/LocalProcess.swift`, including `LocalProcessDelegate`, public lifecycle methods, process launch/read/write/termination paths, and mixed later flow-control additions.

The public declarations are frozen separately in `CMDYPTY_PUBLIC_API.md`;
behavior is frozen in `CMDYPTY_CONTRACT.md`. The replacement boundary was the
complete implementation, including post-extraction regions interleaved with
directly derived regions.

### Unicode width: direct lineage

`Core/Sources/TermiteCore/UnicodeWidth.swift` contains imported width data and
lookup/UTF-8 utility regions attributed to the vendor import. Independently
generated Unicode data and logic now replace this complete file boundary.
`UNICODE_WIDTH.md` records the neutral generation contract.

### Renderer: direct, adapted, and mixed lineage

Direct file lineage is recorded for:

- `BlockElementRenderer.swift`
- `BoxDrawingRenderer.swift`
- `CoreTextGlyphRasterizer.swift`
- `GlyphAtlas.swift`
- `MetalBufferingMode.swift`
- `MetalError.swift`
- `MetalTerminalRenderer.swift`
- `Shaders.metal`

`MetalRenderSource.swift`, `RenderTypes.swift`, and `PlatformCompat.swift` were extracted later but encode an adapted view/renderer boundary, public types, and attribute conventions. They belong in the conservative clean-room replacement boundary even where Git cannot attribute their creation to the initial import.

`MetalTerminalRenderer.swift` and `Shaders.metal` contain substantial later
cmdy product behavior interleaved with lineage-bearing foundations. Those
additions are behaviorally preserved through `CMDYGPU_CONTRACT.md`; the active
renderer was independently recomposed rather than produced by selectively
deleting imported lines.

### Clear later cmdy additions

History supports classifying these whole renderer helpers as later cmdy product additions:

- `CursorGlide.swift`
- `DynamicBufferRing.swift`
- `TerminalFontFeatures.swift`

That classification is an engineering inventory result, not legal clean-room certification. They remain subject to final review and may be retained only if that review confirms their provenance.

### Shader-specific authorship conclusion

The initial imported `Shaders.metal` at `512b859...` is exactly 123 lines. It contains only the basic glyph/text/color data declarations and the corresponding text/color vertex and fragment entry points. That imported scene pipeline is derived and must be discarded and independently replaced. Later edits to those inherited declarations and entry points do not make the wrapper independent; the conservative discard boundary includes the base scene wrapper through the original color fragment.

The CRT/post-process gallery did not exist in that imported file. Repository history shows it being introduced in commits authored by Andreas Pihlström for term64/cmdy:

| Commit | Demonstrable cmdy-owned shader contribution |
| --- | --- |
| `d2ce06f1b093` | initial post-process varyings/uniform interface, fullscreen pass, and CRT formula |
| `382b973bb9ed` | gallery modes 1–4: CRT, scanlines, glow, and VHS |
| `c077add57fe1` | continuous-surface/background behavior refinements for the early modes |
| `98c75cf88994` | modes 5–9 plus cmdy hash/palette and live-telemetry-driven effects |
| `c03c5a8b5d84` | modes 10–37, text-mask helper, expanded gallery uniforms, and associated formulas |
| `79a940347564` | modes 38–67, value-noise/fBm helpers, and the calm ambient formulas |
| `a652a3c0afe1` | Databloom text uniforms, hash/palette, and atlas-text fragment variant |

Those commits predate or postdate path extraction, but all are authored by the cmdy owner and add code beyond the 123-line imported file. The mode-specific formulas, cmdy helper formulas, uniforms required by those effects, and Databloom variant are therefore classified as **cmdy-original additions by repository evidence** and may be transplanted into a newly written independent wrapper to retain exact 68-mode and Databloom behavior. Their location under `Vendor/SwiftTerm` in early commits is a path fact, not evidence that SwiftTerm supplied those effects.

The transplant permission does not extend to imported scene structs, imported vertex/fragment bodies, or wrapper lines blended with the original 123-line pipeline. Recreate those boundaries from the public Metal contract and then connect the demonstrably later effect code. Where a later hunk mixes an inherited wrapper line with a cmdy formula, retain the formula only and independently express the surrounding control/data flow.

This conclusion is stronger than the generated report's automatic `vendor-era-uncertain` label because it adds commit-author and before/after evidence. It is still an engineering provenance conclusion, not a representation about whether every mathematical idiom is copyrightable or externally unique; the final independent reviewer must confirm the repository-authorship evidence before the public claim.

### App shaping/surface: adapted integration seam

`App/TermiteCoreShaping.swift` and `App/TermiteCoreSurface.swift` were created for the newer engine, but exact matching regions, conventions, and behavior show adaptation from the former view/renderer integration. The entire two-file seam is therefore the conservative replacement boundary.

Cmdy-specific product behavior within that boundary includes snapshot/damage publishing, failed-command styling, search, link detection, title-bar drag routing, smooth scrolling, renderer teardown, and window-observer cleanup. `SHAPING_SURFACE_CONTRACT.md` preserves that behavior without prescribing its implementation; `APP_SEAM_DECLARATIONS.md` freezes the integration declarations.

### Remaining CmdyCore engine

The preliminary exact multi-line clone scan found no copied blocks in the
remaining engine files beyond the width implementation. Those files were
introduced as the newer engine, but were developed while the reference
implementation was available. This is strong engineering evidence only. The
active-tree fingerprint gate therefore keeps those retained files under exact
reviewed hashes; any edit invalidates its classification. A final independent
review is still required before certifying them.

## Classification rules for final audit

Use these terms consistently:

- **Derived:** copied, moved, translated, or adapted implementation, regardless of later renaming or modification.
- **Cmdy-original addition:** introduced for cmdy with evidence of independent authorship; still subject to reviewer confirmation.
- **Uncertain:** history or similarity does not support a confident classification; treat as replacement/review scope.
- **Behavioral contract:** observations, public declarations, tests, or platform specifications that describe results without supplying implementation.

Do not infer that a source is independent merely because it is under a `Cmdy*` path, has a later blame commit, or no longer imports another module.

## Final audit commands

For the active working tree, including modified and untracked source:

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

`--mode report` is a triage mode and deliberately returns success even when
findings remain; it is not a release gate. The old
`audit-swiftterm-lineage.py --ref HEAD` form reads only the committed Git object
and can miss working-tree replacements, so it must not be used as evidence for
the active-tree claim.

The absence of unresolved source matches, dependency edges, retired imports,
and public-API drift, plus green behavioral tests, is necessary but not
sufficient. A reviewer independent of the replacement authors must compare the
final active tree, this inventory, the process records, license notices, and
release claim.

The completed reviewer verdict must bind its evidence to the exact committed
tree using [`PROVENANCE_REVIEW_TEMPLATE.md`](PROVENANCE_REVIEW_TEMPLATE.md).
The template is intentionally pending and cannot be cited as approval.

Historical releases and Git history retain their required MIT attribution. Removing current derived implementation does not authorize rewriting history or deleting notices from artifacts that still contain it.
