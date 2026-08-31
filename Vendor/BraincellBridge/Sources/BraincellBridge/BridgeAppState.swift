import Foundation
import AppKit
import Combine

struct BridgeConnectRequest: Equatable, Identifiable {
    let id = UUID()
    let sessionId: String
}

/// Central state container for the bridge app. Holds all the shared services that
/// the various features (HTTP server, MCP, hotkey overlay, popover UI) read/write.
///
/// Single instance, owned by `BridgeAppDelegate`. Most fields are filled in during
/// `applicationDidFinishLaunching` after async startup completes.
@MainActor
final class BridgeAppState: ObservableObject {
    /// Set by a cmdy window-edge plus. The popover observes the request,
    /// opens its connection picker, and preselects the originating pane.
    @Published var connectRequest: BridgeConnectRequest?

    /// Live registry of terminal sessions where Claude Code is running.
    let registry = TerminalRegistry()

    /// session-id → SessionBinding (one binding per session).
    let bindings = BindingStore()

    /// session-id → owned target adapter. ChromeAdapter owns its Chrome process + CDP client.
    /// Filled in lazily when a session is bound to a target.
    @Published var chromeAdapters: [String: ChromeAdapter] = [:]

    /// session-id → owned MacAppAdapter. One per session bound to a Mac
    /// app project. Owns the build/launch lifecycle + console buffer + AX
    /// tree access for the running app. First non-Chrome adapter shipped.
    @Published var macAppAdapters: [String: MacAppAdapter] = [:]

    /// session-id → owned NativeAppAdapter. One per session bound to an
    /// already-running macOS app (Slack/Notion/Figma desktop/etc) by
    /// bundle id. Distinct from `macAppAdapters`, which builds + spawns
    /// its target; these adapters attach to processes the user owns.
    /// Lifecycle is driven by NSWorkspace's `didTerminateApplication`
    /// notification — when the user quits the app, the adapter fires
    /// `onTerminated` and the universal close-target path drops the
    /// binding (matching Chrome / Mac App / Sim).
    @Published var nativeAdapters: [String: NativeAppAdapter] = [:]

    /// Per-session iOS Simulator adapters. One per binding, keyed by
    /// session id. The adapter is a thin `xcrun simctl` wrapper — no
    /// state owned by the bridge beyond the UDID + a state-watcher
    /// timer. Phase 5.2 first slice.
    @Published var simAdapters: [String: SimulatorAdapter] = [:]

    /// Currently booted simulators on the host. Refreshed each time the
    /// popover opens via `SimulatorAdapter.listBooted()`. Used by the bind
    /// menu to expose a per-sim "Bind iOS Simulator: <name>" entry rather
    /// than silently picking the first booted sim. Each entry has at least
    /// `udid` and `name` keys.
    @Published var bootedSimulators: [[String: Any]] = []

    /// User-facing macOS apps currently running, filtered + sorted for the
    /// "Bind Native App: <name>" submenu. Refreshed each popover open from
    /// `NSWorkspace.shared.runningApplications`. Each entry: `bundleId`,
    /// `name`. Filter drops apps with regular activation policy ≠ regular
    /// (menu-bar tools, agents, helpers) so the user doesn't see things
    /// like "bind to TouchBarServer."
    @Published var runningNativeApps: [[String: Any]] = []

    /// Whether Facebook idb (`brew install idb-companion && pip3 install
    /// fb-idb`) is reachable on PATH. Refreshed each popover open. Drives
    /// the inline "idb missing" banner in the popover when the user has
    /// any sim binding or a booted sim — gestures need it. Defaults true
    /// to avoid a flicker before the first check completes.
    @Published var idbInstalled: Bool = true

    // MARK: - TargetAdapter unified access

    /// Look up the bound adapter for a session, regardless of target type.
    /// Returns the first match across the four per-target dicts; the dicts
    /// are mutually exclusive (one binding = one target type) so order
    /// doesn't matter, but Chrome wins if a stale duplicate ever exists.
    /// Used by preflight, unbindSession, and the wire overlay so they
    /// don't have to switch on Target. See `Adapters/TargetAdapter.swift`.
    func adapter(for sessionId: String) -> (any TargetAdapter)? {
        chromeAdapters[sessionId]
            ?? macAppAdapters[sessionId]
            ?? simAdapters[sessionId]
            ?? nativeAdapters[sessionId]
    }

    /// Iterate every (sessionId, adapter) pair across all target types.
    /// Used by `WireOverlayController.recomputeWires` to collapse what
    /// used to be four parallel iteration blocks into one.
    func allAdapters() -> [(sessionId: String, adapter: any TargetAdapter)] {
        var pairs: [(String, any TargetAdapter)] = []
        for (sid, a) in chromeAdapters   { pairs.append((sid, a)) }
        for (sid, a) in macAppAdapters   { pairs.append((sid, a)) }
        for (sid, a) in simAdapters      { pairs.append((sid, a)) }
        for (sid, a) in nativeAdapters   { pairs.append((sid, a)) }
        return pairs
    }

    /// Pop the bound adapter for a session out of whichever per-target
    /// dict holds it. Returns the removed adapter (caller awaits its
    /// shutdown). Used by `unbindSession` to replace the per-target
    /// `chromeAdapters.removeValue + macAppAdapters.removeValue + ...`
    /// chain with a single call.
    @discardableResult
    func removeAdapter(for sessionId: String) -> (any TargetAdapter)? {
        if let a = chromeAdapters.removeValue(forKey: sessionId) { return a }
        if let a = macAppAdapters.removeValue(forKey: sessionId) { return a }
        if let a = simAdapters.removeValue(forKey: sessionId)    { return a }
        if let a = nativeAdapters.removeValue(forKey: sessionId) { return a }
        return nil
    }

    /// Next CDP port to hand out. Allocated synchronously (incremented at bind-call
    /// time, not after Chrome launches) so two parallel binds don't race onto the
    /// same port. Starts at 9322 to dodge the IDE's 9222 default and the user's
    /// own Chrome which often listens on 9222 too.
    var nextCdpPort: Int = 9322

    /// session-id → analyzed project info for the session's cwd at bind time.
    /// Populated by `bindSessionToChrome` after launch; the popover reads this
    /// to surface the "Start <command>" affordance.
    @Published var projectInfos: [String: ProjectAnalyzer.ProjectInfo] = [:]

    /// session-id → last Chrome launch error message. Surfaced in the popover
    /// SessionCard as a red error box so the user can see *why* binding failed
    /// (instead of clicking "Bind Chrome" repeatedly and getting silent
    /// piggybacked Chrome windows). Cleared on next successful bind / unbind.
    @Published var lastLaunchErrors: [String: String] = [:]

    /// session-id → current activity pulse driving the wire animation. Outbound
    /// (terminal → browser) is set whenever Claude calls an MCP tool; inbound
    /// (browser → terminal) when the in-page inspector POSTs to /inject.
    /// Auto-expires; the wire reads this each frame to set dash direction.
    @Published var activityPulses: [String: ActivityPulse] = [:]

    /// session-id → port we successfully detected the dev server on after the
    /// user clicked Start. Cleared on unbind. The contextual menu-bar Start
    /// button uses this (plus a sync TCP probe) to hide itself while the
    /// server is alive — clicking Start again would just relaunch.
    @Published var runningDevServerPorts: [String: Int] = [:]

    /// Semantic notes captured from a bound surface. This is intentionally a
    /// small in-memory queue: agents can inspect and resolve records through
    /// MCP, while the embedded cmdy host receives each record immediately.
    let feedback = BridgeFeedbackStore()

    /// UI entry point injected by BridgeAppDelegate so MCP can arm the same
    /// target-aware picker as cmdy's command without owning UI objects.
    var beginFeedback: ((String) -> Void)?

    /// Session IDs where the user manually dismissed the Run pill via its ×.
    /// Suppresses the pill until the binding is removed (so re-binding starts
    /// fresh). Lets users say "I'm running the server externally, stop nagging."
    @Published var runPillDismissed: Set<String> = []

    /// Same idea for Mac App "Build & Run" pill — user can hide it if they
    /// prefer to drive the build manually from the terminal.
    @Published var macBuildPillDismissed: Set<String> = []

    /// Underlying HTTP server. MCP `/execute` and registry `/sessions/*` routes are
    /// registered against it during launch.
    var httpServer: HTTPServer!

    /// MCP server instance — wraps tool dispatch over the HTTPServer.
    var mcpServer: BridgeMCPServer!

    /// Renders Claude's intent (a labeled ribbon + edge strip) directly on the
    /// bound Chrome window for the duration of every tool call. First slice of
    /// the perceived-latency strategy: collapse the user's "I typed → nothing
    /// happened → Chrome moved" attention bounce by giving Chrome itself
    /// continuous visible activity. Read by `BridgeToolRouter` around dispatch;
    /// the Chrome-PID-lookup closure is wired in `BridgeAppDelegate`.
    let intentOverlay = IntentOverlayController()

    /// Native AI cursor + click ripple drawn over any bound surface. Today
    /// fires for Mac App tool calls (no DOM to inject into); the plan is to
    /// flip Chrome over to it as well so we have one cursor mechanic and
    /// one visual language across every target. Click-through panel; never
    /// captures input.
    let cursorOverlay = OverlayCursorController()

    /// Local OCR pipeline (Apple Vision) for resolving `find` queries against
    /// the bound Chrome window's actual rendered pixels — catches text in
    /// canvas/SVG/images that DOM scraping misses. Used by `BridgeToolRouter`
    /// in parallel with the existing CDP DOM scan; matches are surfaced under
    /// `visualMatches` on the `find` response. This is intentionally on-demand
    /// only for now.
    let visionFinder = VisionFinder()

    /// Local HTTP proxy in front of `api.anthropic.com`. With
    /// `ANTHROPIC_BASE_URL=http://127.0.0.1:<streamProxy.port>/sess/<sessionId>`
    /// set in a bound terminal, every Claude Code call flows through this
    /// proxy. We forward everything verbatim and tee the SSE response into a
    /// parser that surfaces `tool_use` composition events to the intent
    /// overlay — gives the user visible "Claude is composing X" feedback
    /// while Claude is still streaming, before the actual MCP dispatch fires.
    /// Started in `BridgeAppDelegate.applicationDidFinishLaunching`.
    let streamProxy = StreamProxyServer()

    /// Record an outbound (Claude → browser) or inbound (browser → Claude)
    /// activity for `sessionId`. Lasts ~1.2s by default — long enough for the
    /// user to register the visual cue, short enough not to feel laggy.
    func pulse(sessionId: String, direction: ActivityDirection, duration: TimeInterval = 1.2) {
        activityPulses[sessionId] = ActivityPulse(direction: direction, until: Date().addingTimeInterval(duration))
    }

    /// Tear-down everything. Called from applicationWillTerminate.
    func shutdown() async {
        let adapters = allAdapters().map(\.adapter)
        adapters.forEach { $0.onTerminated = nil }
        chromeAdapters.removeAll()
        simAdapters.removeAll()
        macAppAdapters.removeAll()
        nativeAdapters.removeAll()
        for adapter in adapters { await adapter.shutdown() }
        await streamProxy.stop()
        await httpServer?.stop()
        mcpServer = nil
        beginFeedback = nil
        httpServer = nil
    }
}

enum ActivityDirection: Equatable {
    case outbound  // terminal/Claude → browser  (MCP tool call)
    case inbound   // browser → terminal/Claude  (inspector inject)
}

struct ActivityPulse: Equatable {
    let direction: ActivityDirection
    let until: Date
}
