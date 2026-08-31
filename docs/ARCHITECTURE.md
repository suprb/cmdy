# Architecture

cmdy is a native macOS terminal with a deliberately small hot path and an open
policy plane. The VT engine and Metal renderer remain independent of optional
Extensions; the app composes them into windows, tabs, splits, and native
platform features.

The governing rule is:

> Open the policy plane. Protect the hot loop.

## Repository map

| Path | Responsibility | Dependency direction |
|---|---|---|
| `Core/` | `CmdyCore`, the deterministic VT parser, screen buffers, reflow, graphics, blocks, and replay; `CmdyPTY`, the local process and PTY transport; `lib_cmdy`, an internal experimental C ABI. | Pure engine code. No AppKit or Metal in `CmdyCore`. |
| `Renderer/` | `CmdyGPU`, the Metal row-raster renderer, bounded compatibility glyph caches, cursor animation, images, built-in shaders, and user-shader pipeline. | Consumes the narrow `MetalRenderSource` interface; does not own a shell or VT parser. |
| `Kit/` | `CmdyKit`, the native platform layer: config, preferences, themes, fonts, sessions, named Workspaces, keybinding import, palette, Actions, Channels, Extensions, Surfaces, Marketplace, and workspace contributions. | May use AppKit. Depends on `Identity`; stays independent of the concrete app window tree and Metal engine. |
| `Identity/` | Canonical product metadata shared by Swift packages, Node tooling, packaging, and release scripts. | Leaf package with no product-feature dependencies. |
| `App/` | The executable target: application lifecycle, menus, windows, tabs, splits, panes, shell integration, editor, and adapters joining Core, Renderer, and Kit. | Composition root. It may depend on all lower layers; lower layers must not depend on `App`. |
| `Plugins/CmdySDK/` | Optional typed Swift client for the public HTTP/JSON and SSE Extension API. | Depends on `Identity`, not app internals. The wire protocol remains usable without the SDK. |
| `Plugins/` | First-party reference Extensions: Browser/Chromium, Sim, Swarm, Bridge, and Detox, plus the parked AppDock experiment. | Separate executables using the same public API available to third parties. Optional host components are explicit exceptions and must remain narrowly reviewed. |
| `Schemas/` | Machine-readable v1 manifests and Surface documents. | Public contracts; schemas and typed models change together. |
| `Vendor/` | Source retained from separately bounded upstream components, including the Bridge engine. | Keep upstream attribution and avoid leaking vendor internals into public protocols. |
| `website/` | React/Vite source, build verification, and render smoke tests for the public website. | Produces `site/`. |
| `site/` | Committed static website output and durable public assets. | Generated distributable; regenerate it from `website/` rather than treating generated HTML or JavaScript as source. |
| `Tests/` | Replay corpora, TUI zoo, oracle notes, performance gates, and UI-driving scripts. | Exercises public seams and application behavior. Package-local unit tests live beside their packages. |

The package names retain some internal `Cmdy*` identifiers for source and
protocol compatibility. The public product identity is `cmdy` and is loaded
from `Identity/Sources/ProductIdentity/Resources/product-identity.json`.

## Terminal data path

Each pane owns its mutable terminal state. Cross-thread consumers see immutable
snapshots rather than the live VT model.

```text
keyboard / paste / mouse
          │
          ▼
 AppKit pane and input routing
          │
          ▼
 CmdyPTY.LocalProcess ───────────────► shell / TUI child process
          ▲                                      │
          └──────────── PTY bytes ───────────────┘
          │
          ▼
 per-pane serial TerminalModel queue
          │ owns and mutates
          ▼
 CmdyCore.CmdyTerminal
          │ coalesced immutable CoreTerminalSnapshot
          ▼
 AppKit CmdyTerminalSurface / MetalRenderSource
          │
          ▼
 CmdyGPU.MetalTerminalRenderer ──────► MTKView / display
```

`TerminalModel` is the ownership boundary: PTY callbacks, parsing, terminal
mutation, and process lifecycle stay on a dedicated serial queue for that pane.
AppKit receives coalesced snapshot notifications on the main actor. Synchronous
operations such as resize capture a matching snapshot in the same model turn so
new view dimensions cannot be paired with stale grid state.

The renderer pulls only render-facing values through `MetalRenderSource`.
Damage information and stable row identities allow it to rebuild changed rows
instead of reconstructing the entire viewport.

## Window and platform composition

`AppDelegate` owns application lifecycle and shared service wiring.
`TerminalWindowController` owns one native window's tabs, split tree, adaptive
frame, toolbar, and grid participation. `TerminalPane` owns one live session and
connects shell integration, blocks, overlays, and pane-scoped features to a
`CmdyTerminalSurface`. Immutable snapshot-to-render values are produced by
`CmdySnapshotShaper`; image identity and decoding are bounded by
`CmdyCellImage`.

`CmdyKit` exposes protocols and value models at the seams. This keeps config,
session persistence, themes, Actions, Channels, and Extension services testable
without importing the full app target. New cross-layer behavior should prefer a
small protocol or immutable value over reaching into a controller.

## Extension and process boundary

Normal Extensions are child processes. The host starts a dependency-free HTTP
server on `127.0.0.1`, mints a unique bearer token for each launch, and grants
only the capabilities declared by that Extension's manifest. HTTP/JSON is the
ABI; server-sent events carry semantic lifecycle events and private callbacks.

```text
Extension process
   │ per-launch token + declared capabilities
   ▼
loopback HTTP/JSON + SSE
   │ authentication, route authorization, ownership checks
   ▼
CmdyKit LocalHTTPServer / PluginManager
   │ bounded host operations and immutable data
   ▼
App panes, commands, hooks, Channels, and native Surfaces
```

An Extension cannot link into the parser, terminal model, PTY read loop, Metal
renderer, or input hot path. Semantic events are emitted after the corresponding
host transition; raw PTY bytes are not mirrored onto the Extension bus.

The capability system limits access to cmdy's host API. It is not a macOS
sandbox: an Extension executable otherwise runs with the current user's OS
permissions. Installed code must therefore be reviewable, project-local code
requires explicit trust, entrypoints cannot escape their package directory, and
launch exit revokes the token and removes launch-owned resources.

Actions are one-shot user or project workflows. Channels are capability-scoped
Extension connectors whose external input remains untrusted and reviewable.
Native Surfaces are host-rendered documents with bounded component types and a
required plain-text fallback; stdout and stderr remain canonical.

See [EXTENSION_PROTOCOL.md](../EXTENSION_PROTOCOL.md),
[SURFACE_PROTOCOL.md](../SURFACE_PROTOCOL.md), and
[SECURITY.md](../SECURITY.md) for the public contracts.

## Performance invariants

Changes should preserve these properties:

1. **One mutable owner per pane.** PTY I/O and VT mutation stay on the pane's
   serial model queue. AppKit and rendering consume immutable snapshots.
2. **No foreign work in the hot path.** Network requests, Extension callbacks,
   disk I/O, marketplace work, AI calls, and blocking orchestration do not run
   inside PTY reads, parser mutation, input dispatch, or Metal encoding.
3. **Incremental rendering.** Small terminal changes invalidate only affected
   rows. GPU buffers and glyph caches are reused after warm-up.
4. **Event-driven idle.** Static, background, and occluded windows do not keep a
   display loop alive. Animated shaders obey their frame and power budgets.
5. **Backpressure and bounds.** PTY delivery, HTTP connections, Surface
   documents, scrollback, logs, images, and caches must remain bounded under
   untrusted or sustained input.
6. **Coalesced UI state.** Burst updates publish the newest coherent snapshot or
   topology; stale animation completions must not restore old state.
7. **Fail-open platform features.** An unavailable Extension, Surface, Channel,
   shader, or assistant must not corrupt the terminal byte stream, process
   lifecycle, or ordinary input.

Performance work needs a repeatable workload and before/after evidence. The
historical measurements in
[`history/PERFORMANCE_AUDIT_2026-07.md`](history/PERFORMANCE_AUDIT_2026-07.md)
are useful context, not a
portable promise for every machine or workload.

## Build and test paths

The root package currently targets macOS 26 because the app shell uses
Foundation Models and current native split-view APIs. Use a matching Xcode
toolchain.

```sh
# Application build and headless integration suites
swift build -c release
./test.sh

# Package tests
swift test --package-path Core -c release
swift test --package-path Renderer -c release
swift test --package-path Kit -c release
swift test --package-path Identity -c release
swift test --package-path Plugins/CmdySDK -c release
swift test --package-path Plugins/chromium/Support -c release
swift test --package-path Plugins/sim -c release
swift test --package-path Vendor/BraincellBridge -c release

# Static website
cd website
npm ci
npm test
```

`./package.sh` assembles and signs a local `cmdy.app`. `./release.sh` performs
the notarized release path described in `RELEASING.md`. `./plugins.sh` builds
and installs first-party Extensions into the current user's cmdy configuration,
so it is an explicit local-development action rather than a read-only test.

CI should remain a faithful subset of these commands. Changes to a public
protocol must update its schema, `CmdyKit` host models, `CmdySDK` client
models, examples, compatibility notes, and denial tests together.

The independent terminal-stack source, API, Unicode, dependency, and linked
symbol gates are documented in [BUILDING.md](../BUILDING.md). The replacement
implementation is active, while its final randomized parity and release
qualification status remains explicit in
[`roadmap/INDEPENDENT_TERMINAL_STACK.md`](roadmap/INDEPENDENT_TERMINAL_STACK.md).

## Where new code belongs

- VT semantics, cell state, reflow, graphics decoding, or replay: `Core/`.
- GPU resource management, glyph rasterization, drawing, or post-processing:
  `Renderer/`.
- Reusable native platform models and services: `Kit/`.
- Window/pane composition or application lifecycle: `App/`.
- Optional behavior that can use a public capability: an Extension under
  `Plugins/` or a third-party package, not an app hot-path dependency.
- Protocol additions: begin with the smallest capability and schema change,
  then implement host, SDK, examples, tests, and documentation as one contract.

When ownership is unclear, preserve the dependency direction and add a narrow
seam. Convenience is not a reason to make the engine know about the app or an
Extension know about renderer internals.
