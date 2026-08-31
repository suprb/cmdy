# PLAN — TermiteCore & the Ghostty-shaped re-architecture

> ## ✅ STATUS: COMPLETE (2026-07-05, commit 5fae570)
>
> **This plan was fully executed. It is kept as a historical record of HOW the
> re-architecture was done — it is NOT a description of current state.** All phases
> landed: the codebase is Ghostty-shaped (`Core/` TermiteCore · `Renderer/`
> TermiteGPU · `Kit/` TermiteKit · `App/` shell · `Plugins/`), TermiteCore is the
> only engine, and **`Vendor/SwiftTerm` is deleted**. The differential oracle that
> proved TermiteCore is parked at `~/.cache/termite-oracle/` (see `Tests/ORACLE.md`);
> its most recent 3.8-day soak found **zero core bugs** (`Tests/DIVERGENCES.md`).
>
> **For current state, read `README.md` (Architecture section) — not §1 below.**
> Everything under "1. WHERE WE ARE NOW" describes the PRE-refactor codebase
> (SwiftTerm vendored, one executable target) and is now false. What remains
> evergreen and worth reading: **§5 Rules of engagement** and **§1.7 Known
> landmines** — those still bind. The `Plugins/` roster has since grown
> (swarm, sim, Browser/chromium beyond bridge + detox).

> **Audience (original):** a fresh multi-agent session (Fable 5 Ultradev) with ZERO prior context.
> Read this whole file before touching code. Everything you need — current state,
> target state, phases, gates, and the non-negotiable rules — is here.
>
> **Mission in one line:** restructure termite into a Ghostty-shaped codebase
> (platform-free core library + thin app shell), replace the vendored SwiftTerm
> VT engine with our own **TermiteCore** (blocks, insets, and replay native to the
> buffer), and ship it **only when it is 100% finished and proven by tests** —
> the user-visible product must never regress at any point.

---

## 0. Definition of DONE (the whole plan is judged against this)

The project is finished when ALL of the following hold:

1. `swift build` produces termite.app with **TermiteCore as the default engine**
   and `Vendor/SwiftTerm` **deleted from the repo**.
2. Every existing regression suite passes on TermiteCore:
   `--selftest --panel-test --shader-test --reflow-test --wheel-test
   --scroll-test --graphics-test --ai-test` (all end with their ALL-PASS line).
3. The **differential harness** (new, Phase 2) reports **zero divergences** from
   the reference engines across the full fixture corpus + 24h of fuzzing.
4. The **TUI zoo** passes by hand-verified screenshot: Claude Code (scroll,
   inline UI, resize), vim, htop, less/man, tmux (inside termite), `cat` of a
   10MB file (throughput sanity).
5. Blocks, reflow anchors, insets, selection, wheel routing, kitty/sixel/iTerm2
   images, session save/restore all behave identically to the SwiftTerm build
   (verified by the suites + screenshot comparison).
6. The plugin SDK is untouched: Bridge and Detox run unmodified against the
   new build (launch both, verify commands appear, verify an inline panel
   opens over HTTP).
7. The codebase is split into the target packages (§3) and the app target is a
   thin shell. `Plugins/` continues to build via `./plugins.sh`.
8. README + PLUGINS.md + SHADERS.md updated where architecture is described.
9. Working tree committed in logical phase-commits; every commit builds and
   passes the suites (no broken intermediate states on main).

**If any gate cannot be met, STOP and leave SwiftTerm as the default engine —
that is an acceptable fallback state; a regressed terminal is not.**

---

## 1. WHERE WE ARE NOW

### 1.1 Product summary

termite (formerly term64; binary `termite`, bundle `com.termite.app`, config at
`~/.config/termite/`, CLI `t64`, env vars still `TERM64_*` for compat) is a
native macOS GPU terminal. Identity: **"The terminal is yours"** — three layers:

1. **Lean terminal** — Metal rendering, inline UI, command blocks, two-way
   config sync, AI that only types (never executes).
2. **Platform** — HTTP+SSE plugin SDK, any language, up to native inline UI.
3. **Proof** — Bridge & Detox: first-party plugins by the project author,
   bundled as examples of the SDK. NOT features of the terminal. Zero private
   hooks — everything they do goes through the public API.

Roadmap themes beyond this plan: agent-native features (Claude Code/Codex/pi
presence), collaboration layers (event-sourced state → shared/replayable
sessions), `lib_cmdy` C ABI so third parties embed our engine.

### 1.2 Repo map (HEAD = b9a6389)

```
term64/                          (dir name is legacy; app is "termite")
├─ Package.swift                 name "termite", ONE executable target "term64"
│                                (path Sources/term64, resources: Fonts)
├─ Sources/term64/               ~8,000 lines, 34 files — THE ENTIRE APP:
│   main.swift                   menus, test-flag entrypoints (§1.6)
│   AppDelegate.swift            palette tree, pickers, mixer, plugin wiring
│   TerminalPane.swift           pane = SwiftTerm view host + inline panel host
│   TerminalWindowController.swift  splits/tabs/drag-dock, blocks UI, SDK events
│   InlinePanel.swift            THE UI surface: list/input/text/editor/tabs
│   CommandPalette.swift         PaletteItem tree + fuzzy scoring
│   PluginKit.swift              PluginManager: HTTP routes, SDK, builtins=[]
│   LocalHTTPServer.swift        BSD-socket HTTP/1.1 + SSE (streamRoute/broadcast)
│   PluginsWindow.swift          plugin manager UI
│   Blocks.swift                 OSC 133 block model, remapRows
│   ConfigFile.swift             two-way config sync (writeBack preserves comments)
│   Preferences.swift            all settings; shaderNames APPEND-ONLY
│   UserShaders.swift            ~/.config/termite/shaders/*.metal hot reload
│   Theme.swift / FontLoader.swift / SessionStore.swift / ShellIntegration.swift
│   AIKit/AgentKit/AIResponseWindow  (AI verbs)
│   BeamKit.swift                beam text/screenshot → pane (APP feature, not Bridge's)
│   SelfTest.swift               --selftest suite
│   SystemInfo.swift             TRMT boot logo (░/█ art — treat as glyphs!)
│   + HotKeyCenter, Notifier, WindowDock, FindBar, DropView,
│     Retrobleeps, HistoryStore, CrashLogger, IconGenerator, BlockOverlayView
├─ Vendor/SwiftTerm/             vendored + HEAVILY PATCHED (see §1.4)
├─ Vendor/BraincellBridge/       BraincellBridgeKit lib (used ONLY by Plugins/bridge)
├─ Plugins/
│   ├─ TermiteSDK/               Swift SDK client (Termite class; SSE auto-reconnect)
│   ├─ bridge/                   external plugin exec (engine + pane reconcile)
│   └─ detox/                    external plugin exec (WebAudio synth in WKWebView,
│                                 resources in Sources/detox/Detox/)
├─ plugins.sh                    builds + installs plugins → ~/.config/termite/plugins/
│                                 (rm-before-cp: fresh inode or SIGKILL — §1.7)
├─ package.sh                    builds termite.app
├─ site/                         static site (Geist design system — leave alone)
├─ PLUGINS.md                    SDK docs (the ABI contract — do not break)
├─ SHADERS.md                    user-shader authoring contract
└─ README.md
```

### 1.3 Architecture as it stands

- **One executable target contains everything** — app chrome, UI kit, plugin
  bus, config, AI. There is no library separation yet. That is Phase 0/4's job.
- **Rendering** is two Metal passes inside the vendored SwiftTerm:
  `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/`
  (`MetalTerminalRenderer.swift`, `Shaders.metal`, `GlyphAtlas`,
  `CoreTextGlyphRasterizer`). Pass 1 rasters the grid; pass 2 is one fragment
  shader with an `int mode` switch (37 modes; mode index == position in
  `Preferences.shaderNames` — APPEND-ONLY) plus a runtime-compiled user
  pipeline (`shaderMode == -1`, `termite_main` contract, preamble in
  `userShaderPreamble`).
- **Inline UI**: `InlinePanel` is docked at pane bottom; the pane reserves grid
  rows via `bottomContentInset` so the shell reflows (real resize, not overlay).
- **Blocks**: OSC 133 markers; anchors survive reflow by snapshotting
  CURSOR-relative logical (unwrapped) line indices around resize
  (`snapshotBlockAnchors`/`restoreBlockAnchors` in TerminalPane +
  `willReflowBuffer`/`didReflowBuffer` hooks patched into SwiftTerm — hooks
  exist in BOTH resize routes: `processSizeChange` AND `resetFont`→public
  `resize(cols:rows:)`).
- **Plugin SDK** (PluginKit + LocalHTTPServer): port 4664+, bearer token,
  discovery file `~/.config/termite/plugin-api.json`. Routes:
  `GET /v1` (self-describing index), `GET /v1/panes` (incl. `focused`),
  `POST /v1/panes/<id>/type|run|focus`, `GET .../output`, `POST .../feed`,
  `POST /v1/notify`, `GET /v1/events` (SSE), `POST /v1/commands` (with
  `plugin` grouping field), `POST /v1/hotkeys`,
  `POST /v1/ui/panel` + `/v1/ui/<id>/update|dismiss`.
  Events: `pane-opened/closed`, `command-finished {pane,command,exitCode,cwd}`
  (emitted from `TerminalWindowController.wire`), `command`, `hotkey`,
  `ui {panel,event: pick|submit|evaluate|changed|dismissed, value}`.
  **This surface is the frozen ABI. It must not change during this project.**
- **External plugins**: any executable + `manifest.json
  {"name","exec","enabled"}` in `~/.config/termite/plugins/<name>/`, launched
  with `TERM64_PORT`/`TERM64_TOKEN` env. App builtins list is EMPTY.

### 1.4 The SwiftTerm patch inventory (what TermiteCore must subsume)

Our vendored SwiftTerm diverges from upstream (8e7a1e15) in ~29+ places across
`Mac/MacTerminalView.swift`, `Apple/AppleTerminalView.swift`, `Terminal.swift`,
and the entire `Apple/Metal/` renderer (ours). The behavioral patches:

| Patch | Where | Why |
|---|---|---|
| xterm wheel routing (SGR buttons 64/65 when app requests mouse; arrows in alt screen; `forwardWheelToApplication`) | MacTerminalView | Claude Code/htop scroll |
| `willReflowBuffer`/`didReflowBuffer` closures in BOTH resize routes | AppleTerminalView | reflow-proof block anchors |
| Content insets: `leftContentInset`, `rightContentInset`, `topContentInset`, `bottomContentInset`, `contentXOrigin` (centered wrap remainder), `showsScroller=false` | MacTerminalView + AppleTerminalView | symmetric margins + inline panels |
| Occlusion gating (skip draw + blink tick when window not visible; repaint on occlusion notification) | MetalTerminalRenderer + MacTerminalView | zero background GPU, instant wake |
| Grid-snapped glyphs w/ `isEffectivelyMonospaced` cache; cell width from "0"; `.ligature: 0` in both shaping paths | renderer + AppleTerminalView | crisp grid, proportional font support |
| Cursor glide `exp(-dt*40)`; location-aware `cursorUpdate` | renderer / MacTerminalView | smooth cursor; no I-beam over header |
| `setUserShader(source:) -> String?` + re-apply on renderer recreation; `userPipeline`; `userShaderPreamble` | renderer | user shader runtime |
| Markers drawn in-scene as circles (failed red r=2 α.95, running gray α.7, success skipped) | renderer | quiet block markers, shader-affected |
| Public accessors: `cursorColumn`, `bufferLineCount`, `isBufferRowWrapped`, `kittyImageCount`, `linesWithImagesCount` | Terminal.swift | tests + anchors |

**Everything in this table is a REQUIREMENT on TermiteCore + TermiteGPU**, not
an implementation detail to rediscover.

### 1.5 What SwiftTerm still provides (the part being replaced)

- VT100/xterm escape parsing (`EscapeSequenceParser`), terminal state machine
- Buffer model: `Buffer`, `BufferLine`, `CircularList` scrollback, alt screen,
  reflow on resize, `CharData` cells + attributes
- PTY / `LocalProcess`
- Selection model, mouse encoding, OSC/DCS handling incl. kitty graphics &
  sixel decode, iTerm2 images

### 1.6 Test & verification infrastructure (KEEP GREEN AT ALL TIMES)

Headless suites (each a flag on the debug binary, each prints a final
ALL-PASS line; run: `swift build && .build/debug/termite --<flag>`):

- `--selftest` — core unit checks (config rewriting, sanitizer, fuzzy score…)
- `--panel-test` — inline panel: previews, tree nav, scroll, mixer pin/esc
- `--shader-test` — user-shader template compiles via real runtime; errors report
- `--reflow-test` — 7 scenarios incl. sparse markers + zoom (this suite CAUGHT
  the old anchor bug — proven by stash-run-fail)
- `--wheel-test`, `--scroll-test`, `--graphics-test` (kitty i=7 + sixel), `--ai-test`

Visual verification method (hard-won; follow exactly):

- Launch a test instance of `.build/debug/termite`, screenshot **by window ID
  filtered to owner PID** (Quartz `CGWindowListCopyWindowInfo` + `screencapture
  -l<id>`), pixel-diff two captures rather than absolute color scans.
- Drive menus via AppleScript **addressed by unix id** — the user's own
  termite.app is usually running and `process "termite"` hits THEIRS:
  `tell (first process whose unix id is <pid>) …`
- **NEVER inject keystrokes** (osascript `keystroke` is banned by the user).
  Menu clicks + synthetic NSEvents dispatched directly to views are OK.
- **Park the user's config** during UI tests (move `~/.config/termite/config`
  aside, restore after). Tests must restore ALL state they touch.
- Scope any `pkill` to your own paths — a broad pattern once killed the
  user's live plugin processes.

### 1.7 Known landmines (each cost a debugging round once)

1. Overwriting a signed binary **in place** poisons the kernel code-sign cache
   → relaunch dies SIGKILL (exit 137, zero output), `codesign -vv` still says
   valid. Always `rm -f` before `cp` (plugins.sh does this — keep it).
2. WKWebView: ES-module imports on `file://` are CORS-blocked AND bypass
   `window.onerror` (silent dead page) — needs `allowFileAccessFromFileURLs` +
   `allowUniversalAccessFromFileURLs`; WebKit clocks need the view in a window
   even in agent processes (detox uses an offscreen NSWindow).
3. `Package.swift`: `platforms` must precede `products`.
4. Writing shell scripts through python heredocs can mangle multi-byte chars
   (`…` → broken bytes → "unbound variable"). ASCII in scripts.
5. A flex child with `margin: 0 auto` shrink-wraps (needs `width: 100%`) —
   site only, but noted.
6. OSC handlers hop through the main queue — drain the runloop after each
   marker feed in tests or recorded rows are stale.
7. `Preferences.shaderNames` order == shader mode number: **append-only**.
8. The TRMT boot logo is pixel art — decode ░/█ as glyphs, never improvise it.

### 1.8 Build & release commands

```
swift build                       # debug build (.build/debug/termite)
./package.sh                      # termite.app (drag to /Applications)
./plugins.sh                      # build + install Bridge/Detox plugins
for t in selftest panel-test shader-test reflow-test wheel-test scroll-test \
         graphics-test ai-test; do .build/debug/termite --$t; done
```

---

## 2. WHERE WE ARE HEADING

Ghostty's shape: **a platform-free core library + thin native shells**, and an
embeddable artifact for third parties. Our version, with our differentiators
(semantic blocks, UI-aware grid, deterministic replay) built INTO the core:

```
termite/
├─ Core/         TermiteCore   — pure Swift, ZERO AppKit/Metal imports
│                 VT500 parser · buffer/scrollback/reflow · alt screen ·
│                 BLOCKS as native buffer structure · INSETS as native grid
│                 concept · selection · mouse encoding · PTY ·
│                 deterministic record/replay of escape streams
├─ Renderer/     TermiteGPU    — Metal two-pass pipeline + shader runtime,
│                 glyph atlas; consumes Core via the TerminalCore protocol
├─ Kit/          TermiteKit    — InlinePanel + palette, config engine,
│                 plugin bus (HTTP/SSE), blocks UI, session persistence
├─ App/          termite       — thin AppKit shell: windows/tabs/splits/menus
├─ Plugins/      TermiteSDK · bridge · detox        (unchanged)
└─ Tests/        suites · differential harness · replay corpus · fuzzer
```

Later (OUT OF SCOPE for this plan, but never block it architecturally):
`lib_cmdy` C ABI (`@_cdecl`, opaque handles) so third parties embed the
engine; collaboration layers riding the event-sourced core; agent-presence
features on the SDK.

---

## 3. THE PHASES

Execute in order. **Each phase ends with: all suites green, a screenshot
sanity pass, and one commit.** Do not start phase N+1 with phase N red.

### Phase 0 — The boundary (pure refactor, zero behavior change)

Goal: define `protocol TerminalCore` (and satellite protocols) capturing the
EXACT surface the app consumes from SwiftTerm today, then make vendored
SwiftTerm the first implementation via an adapter.

Tasks:
1. Inventory every SwiftTerm symbol referenced from `Sources/term64/`
   (`grep -rn "SwiftTerm\|TerminalView\|terminal\." Sources/term64` and
   classify). Expect: view hosting, feed/send, resize, scroll, buffer reads
   (blocks anchors), insets, selection, images counts, PTY lifecycle.
2. Design the protocol set — suggested split:
   - `TerminalEngine` (state): feed(bytes), resize, buffer snapshot access,
     cursor, scrollback, modes, reflow hooks, blocks/anchors API
   - `TerminalSurface` (view+renderer glue): insets, contentXOrigin, wheel
     routing policy, user shader hooks
   - `TerminalSession` (PTY): spawn, write, resize, terminate, exit callback
3. `SwiftTermAdapter` conforming to all three, wrapping today's classes.
   TerminalPane and the renderer talk ONLY to the protocols afterward.
4. No file moves yet. No new packages yet. Just the seam.

Gate: all 8 suites pass; screenshot of a running pane identical (pixel-diff)
to pre-refactor; commit `Phase 0: TerminalCore boundary`.

### Phase 1 — Extract TermiteGPU (mechanical move)

Goal: renderer becomes a package that depends only on the protocols.

Tasks:
1. New SwiftPM package `Renderer/` (product `TermiteGPU`) containing
   `MetalTerminalRenderer`, `Shaders.metal`, `GlyphAtlas`,
   `CoreTextGlyphRasterizer`, user-shader pipeline. Move them OUT of
   Vendor/SwiftTerm (they're ours; SwiftTerm keeps only a stub render path or
   none — the app always uses TermiteGPU).
2. The renderer's inputs become protocol types (cell rows, damage, cursor,
   images). Write the thin adapter where SwiftTerm types cross the boundary.
3. Keep shader mode numbering and `termite_main` contract byte-identical
   (SHADERS.md is a public contract).

Gate: suites + `--shader-test` green; visual pixel-diff on 3 shaders (off,
CRT, Floor) unchanged; commit.

### Phase 2 — Build TermiteCore beside SwiftTerm (the real work)

Goal: our own engine, correctness proven by a differential oracle — NOT by
hope. SwiftTerm remains the default throughout.

Order of construction:
1. **Package `Core/`** (`TermiteCore`), pure Swift, no AppKit/Metal. CI-able
   headless. Swift 6 concurrency-clean.
2. **Parser**: Paul Williams' VT500 state machine (states/actions table-driven).
   Full coverage of CSI/ESC/OSC/DCS/APC dispatch with parameter/intermediate
   collection. Grapheme-cluster aware UTF-8 (Swift native strings help).
3. **Screen model**: cells (char + SGR attrs + width), rows, scrollback ring,
   alt screen, scroll regions (DECSTBM), tabs, wrap + **reflow** — and the two
   termite-native concepts from day one:
   - **Blocks**: OSC 133 regions as first-class structures (id, promptRow,
     commandText, exitCode, duration) with anchors that remap through reflow
     BY CONSTRUCTION (logical-line identity, not row math).
   - **Insets**: the grid can lend rows/columns to UI; resize math accounts
     for reserved space natively.
4. **Record/replay**: every byte fed is appendable to a session log; replaying
   a log reproduces the identical screen (deterministic — no wall clock in
   core). This is both a test tool and the future collab substrate.
5. **Semantics needed by the app** (from §1.4/§1.5): modes (DECCKM, DECTCEM,
   1049 alt screen, 1000/1002/1003/1006 mouse, 2004 bracketed paste, kitty
   keyboard protocol), SGR incl. 256/truecolor, OSC 0/2 title, OSC 7 cwd,
   OSC 8 links, OSC 52 clipboard (policy-gated), OSC 133, kitty graphics +
   sixel + iTerm2 inline images (decode to image cells), DECRQM reports,
   charsets: UTF-8 only (declare non-goal: legacy charset museum initially).
6. **PTY**: small macOS PTY module (posix_spawn + openpty) — or lift
   SwiftTerm's LocalProcess wholesale (it is Miguel's MIT code; keep the
   attribution header).
7. **The differential harness** (`Tests/differential/`):
   - Feed identical byte streams to TermiteCore AND SwiftTerm (and, where
     available, `libghostty-vt` as a third oracle — vendor it pinned if its
     C API is practical to embed; if not, two-way is acceptable).
   - Compare: final screen text+attrs, cursor, scrollback length, mode flags.
   - Fixture sources: (a) hand-written per-feature cases, (b) **recorded real
     sessions** — record PTY output of scripted vim/htop/less/tmux/Claude
     Code runs into `Tests/corpus/*.term` replay files, (c) a mutation fuzzer
     over valid sequence grammars.
   - Any divergence = a failing test with the minimized byte stream attached.
8. **`TermiteCoreAdapter`** conforming to the Phase 0 protocols.

Gate (hard): differential harness zero-divergence on the corpus; a dedicated
`--core-test` suite (parser conformance + blocks + reflow + replay) green;
suites still green on the DEFAULT SwiftTerm build; commit(s) — this phase may
be several commits (`parser`, `screen`, `blocks`, `images`, `harness`).

### Phase 3 — Flip behind a flag, then flip the default

Tasks:
1. Config key `core = swiftterm | termite` (default `swiftterm`), applied per
   new pane — panes with different cores can coexist (A/B in one window).
2. Run EVERYTHING on `core = termite`: all 8 suites (add a CI-style script
   `./test.sh <core>` that sets the config), the TUI zoo by hand (screenshots
   into `Tests/zoo-results/`), 24h fuzz, throughput check (`cat` 10MB ≤ 1.5×
   SwiftTerm time; target: faster).
3. Fix divergences until quiet. THEN default `core = termite`; SwiftTerm still
   selectable for one release as an escape hatch.
4. Final: delete `Vendor/SwiftTerm`, delete the adapter, delete the flag.
   (Only after a full pass of gate #2 on the termite-only build.)

Gate: §0 items 1–6 all satisfied. Commit sequence: `flag`, `default flip`,
`remove SwiftTerm`.

### Phase 4 — Extract TermiteKit; the app becomes a shell

Tasks:
1. New package `Kit/` (`TermiteKit`): InlinePanel + CommandPalette,
   ConfigFile + Preferences, PluginKit + LocalHTTPServer + PluginsWindow
   model, Blocks UI model, SessionStore, Theme/FontLoader, Notifier.
   (AppKit allowed here — Kit is the *platform* layer, not the engine.)
2. `Sources/term64/` shrinks to: AppDelegate, window controller, pane
   host wiring, menus, main. Rename target dir to `App/` (keep product name
   `termite`; update package.sh paths).
3. Re-point plugins.sh / tests; PLUGINS.md unchanged (ABI stable).

Gate: suites green; Bridge+Detox still work; `wc -l App/` meaningfully small;
commit.

### Phase 5 — (Optional, only if time remains) lib_cmdy spike

A `@_cdecl` C-ABI wrapper over TermiteCore (create/feed/read-cells/resize/
free + blocks query). One C demo program that cats a VT stream and prints the
grid. Do NOT publish/promise API stability. Gate: demo runs; commit.

---

## 4. Testing strategy (summary of obligations)

| Layer | Tool | When |
|---|---|---|
| Existing 8 suites | `.build/debug/termite --<flag>` | after EVERY task, both cores once Phase 3 starts |
| New `--core-test` | parser/blocks/reflow/replay unit conformance | Phase 2 onward |
| Differential harness | corpus + fuzz vs SwiftTerm (+ libghostty-vt if embedded) | Phase 2 onward, 24h soak before default flip |
| Replay corpus | recorded real sessions replayed byte-perfect | Phase 2 onward |
| TUI zoo (manual) | Claude Code, vim, htop, less/man, tmux; screenshot by PID | before each phase commit; exhaustively at Phase 3 |
| Throughput | `time cat 10MB` both cores | Phase 3 |
| Plugin ABI | launch Bridge+Detox, curl /v1, open editor panel | Phase 3, 4 |
| Visual pixel-diff | two-capture diff method (§1.6) | any renderer-adjacent change |

---

## 5. Rules of engagement (user-imposed; violating these has burned us)

1. **Never** inject keystrokes via osascript. Menu clicks / direct NSEvents only.
2. Park `~/.config/termite/config` during UI tests; restore everything.
3. Address test instances by **unix id** in AppleScript; the user's own
   termite.app is typically running — do not touch it, do not broad-pkill.
4. `rm -f` before installing over any signed binary.
5. `Preferences.shaderNames` is append-only; shader mode numbers are public.
6. The plugin HTTP ABI (PLUGINS.md) is frozen — additive changes only.
7. GPU performance is core identity — no regressions; occlusion gating stays.
8. All UI belongs in InlinePanel inside the pane. Never new NSPanels/windows.
9. Design taste: minimal, muted defaults; "a bit" means a parameter tweak plus
   a config knob. No selly copy anywhere.
10. Commit style: thematic commits with story-telling messages (see git log);
    end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
    Every commit must build + pass suites.

---

## 6. Risks & mitigations

| Risk | Mitigation |
|---|---|
| VT conformance tail is long | differential oracle turns folklore into failing tests; UTF-8-only + modern-xterm scope; SwiftTerm stays default until QUIET |
| Reflow/blocks semantics subtly diverge | they are native structures in Core + the `--reflow-test` suite is the spec; port its 7 scenarios into `--core-test` first, TDD-style |
| Renderer/core seam perf (copying cells) | damage-based diffs; benchmark in Phase 1 before Core exists (adapter cost baseline) |
| libghostty-vt embed friction (Zig artifact) | it is an OPTIONAL third oracle; two-way differential vs SwiftTerm is sufficient |
| Kitty graphics/sixel complexity | reuse decode approach from SwiftTerm (MIT) where sensible; `--graphics-test` is the gate |
| Long-running fuzz flakiness | minimize + commit every divergence as a fixture; fuzz runs must be reproducible (seeded) |
| Scope creep into collab/agent features | explicitly OUT of scope; only requirement is "no architectural roots that block them" (no wall-clock in core, events serializable) |

---

## 7. Glossary

- **TermiteCore** — our VT engine (parser + buffer + blocks + replay). Pure Swift.
- **TermiteGPU** — the Metal renderer package (ours already, being extracted).
- **TermiteKit** — platform layer: inline UI, config, plugin bus.
- **TerminalCore protocol(s)** — the Phase 0 seam everything meets at.
- **Differential harness** — same bytes → N engines → diff screens.
- **Replay corpus** — recorded `.term` byte streams from real sessions.
- **TUI zoo** — the manual acceptance set (Claude Code, vim, htop, less, tmux).
- **Blocks** — OSC 133 command regions; termite's signature semantic feature.
- **The ABI** — the `/v1` HTTP surface documented in PLUGINS.md. Frozen.

*Written 2026-07-05 at HEAD b9a6389 ("termite.site: Geist-system landing + docs").*
