import AppKit
import SwiftUI
import Combine
import Darwin
import ApplicationServices
@preconcurrency import ScreenCaptureKit

// Same private API used in TextInjection — maps AX window → CGWindowID so we
// can identify the specific bound terminal window when multiple windows of the
// app exist.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// AppDelegate for the menu bar bridge app. Owns the BridgeAppState, the status item,
/// and the popover. Wires together HTTP server, MCP server, and (later) hotkey + overlay.
@MainActor
final class BridgeAppDelegate: NSObject, NSApplicationDelegate {
    /// True when the engine runs inside cmdy (via BridgeEngine).
    /// The host owns the capture hotkeys (⌘⇧B/⌘⇧S) — skip registering ours.
    var embeddedInHost = false
    var onFeedback: ((String, [String: Any]) -> Void)?

    let appState = BridgeAppState()
    /// One 256-bit credential for this Bridge process lifetime. Every
    /// privileged loopback route requires it.
    let authenticationToken = HTTPServer.generateAuthenticationToken()
    /// Narrow credential exposed to the bound page-side Inspector. It can
    /// access only the two routes explicitly marked cross-origin and cannot
    /// authenticate session, injection, or automation endpoints.
    let browserAuthenticationToken = HTTPServer.generateAuthenticationToken()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hotkey: HotkeyManager?
    /// Second hotkey: ⌘⇧S → region picker via `screencapture -i -c`.
    /// Distinct `HotkeyManager` instance because each instance owns one
    /// Carbon hotkey registration; the manager filters by `EventHotKeyID.id`
    /// so the two don't cross-fire.
    private var regionHotkey: HotkeyManager?
    private var overlay: OverlayController?
    private var bindingsObserver: AnyCancellable?
    private var registryObserver: AnyCancellable?

    /// Track session ids we've already seen so the registry observer can detect
    /// newly-added sessions and auto-bind them to a sibling in the same project.
    private var knownSessionIds: Set<String> = []

    /// Floating overlay that draws a glowing wire between each bound terminal
    /// window and its bound Chrome window. Lazily created on first bind.
    private var wireOverlay: WireOverlayController?

    /// Floating "▶ Run <cmd>" pill anchored to the right edge of a bound
    /// terminal window when the project has a runnable dev command and the
    /// server isn't already listening. Replaces the menu-bar Run nag.
    private var runBubble: RunBubbleController?

    /// Floating "▶ Build & Run" pill for terminals bound to a Mac App
    /// project — analog of `runBubble` for non-Chrome bindings. Click
    /// triggers `MacAppAdapter.build()` then `.run()`; pill auto-hides
    /// while the launched app is alive.
    private var macBuildBubble: MacBuildBubbleController?

    /// Floating circular "+" anchored to the right edge of a bindable terminal
    /// window. Replaced the menu-bar bind affordance — putting it on the actual
    /// window is more discoverable and doesn't pollute the menu bar.
    private var bindBubble: BindBubbleController?
    private var visualTheme = BridgeVisualTheme.fallback
    /// Floating inspector toggle anchored to the right edge of the bound Chrome
    /// window. Mirrors the bind bubble pattern but for the per-session inspector
    /// state. Visible only when Chrome is frontmost AND its focused window
    /// matches a bound session.
    private var inspectorBubble: InspectorBubbleController?
    /// Generic native composer panel — replaces the in-page DOM popover that
    /// the inspector used to render. Source-agnostic so future contexts
    /// (terminal selection, simulator capture) can hand it the same shape.
    private var composer: ComposerController?
    private let feedbackOverlay = BridgeFeedbackOverlay()

    /// Per-project file watcher → CDP reload. Keeps the bound Chrome's DOM
    /// in sync as Claude edits files: CSS hot-swaps in place, everything else
    /// triggers a full reload. One watcher per unique projectPath.
    private let liveReloader = LiveReloader()

    private var workspaceActivationObserver: NSObjectProtocol?
    private var injectPulseObserver: NSObjectProtocol?
    private var bindRequestObserver: NSObjectProtocol?
    private var isShuttingDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Log permission state up front so it's obvious in the bridge log
        // when something silently fails downstream. AX is required for the
        // bind bubble's window detection, paste injection, and the inspector.
        let axTrusted = AXIsProcessTrusted()
        NSLog("[Bridge] Accessibility trusted: %@ (path: %@)",
              axTrusted ? "YES" : "NO",
              ProcessInfo.processInfo.arguments.first ?? "?")
        if !axTrusted {
            NSLog("[Bridge] WARNING: bind bubble + paste injection won't work until AX is granted")
            NSLog("[Bridge]   System Settings → Privacy & Security → Accessibility → enable %@",
                  BridgeHostIdentity.displayName)
        }
        buildStatusItem()
        buildPopover()
        Task { await startServer() }
        if !embeddedInHost {
            installHotkey()   // cmdy provides its own capture UX (Beam)
        }
        // Bindings are intentionally ephemeral — they live for the life of
        // the bridge process. No restorePersistedBindings call: quit →
        // forgotten, by design (see BindingStore docstring).
        // Intent overlay needs a way to look up the bound Chrome PID for any
        // session — closure-injection so the controller stays decoupled from
        // BridgeAppState's full surface.
        appState.intentOverlay.chromeProcessPid = { [weak self] sid in
            self?.appState.chromeAdapters[sid]?.chromeProcessPid
        }
        // Live-reload resolves sessionId → ChromeAdapter the same way.
        liveReloader.adapterFor = { [weak self] sid in
            self?.appState.chromeAdapters[sid]
        }

        // Stream proxy: start it, then wire its tool-stream events into the
        // intent overlay. Composing intents land before the MCP dispatch
        // fires; BridgeToolRouter.execute later transitions composing→active
        // when the actual call arrives.
        appState.streamProxy.onEvent = { [weak self] event in
            self?.handleStreamEvent(event)
        }
        Task { @MainActor [weak self] in
            do {
                try await self?.appState.streamProxy.start()
                if self?.isShuttingDown == true {
                    await self?.appState.streamProxy.stop()
                    return
                }
                NSLog("[Bridge] StreamProxy listening on 127.0.0.1:%d",
                      self?.appState.streamProxy.port ?? 0)
            } catch {
                NSLog("[Bridge] StreamProxy failed to start: %@",
                      error.localizedDescription)
            }
        }
        // Inspector → terminal injects post a Notification from the HTTP route
        // handler (which doesn't hold a BridgeAppState ref). We translate that
        // into a wire-overlay pulse here on the main actor.
        injectPulseObserver = NotificationCenter.default.addObserver(
            forName: .braincellBridgeInjectPulse, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?["sessionId"] as? String else { return }
            // The closure runs on the main queue but isn't @MainActor-annotated;
            // hop explicitly so the actor-isolated `pulse` call is well-formed.
            Task { @MainActor [weak self] in
                self?.appState.pulse(sessionId: id, direction: .inbound)
            }
        }

        bindRequestObserver = NotificationCenter.default.addObserver(
            forName: .bridgeBindRequested, object: nil, queue: .main
        ) { [weak self] note in
            guard let sessionId = note.userInfo?["sessionId"] as? String,
                  let target = note.userInfo?["target"] as? Target else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch target {
                case .chrome:
                    self.bindSessionToChrome(sessionId: sessionId, useMyChrome: false)
                case .macAppProject:
                    self.bindSessionToMacApp(sessionId: sessionId)
                case .simulator(let udid):
                    await self.bindSessionToSimulator(sessionId: sessionId, udid: udid)
                case .nativeApp(let bundleId):
                    self.bindSessionToNativeApp(sessionId: sessionId, bundleId: bundleId)
                }
            }
        }

    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdown()
    }

    /// Hide every process-owned surface synchronously before AppKit lets the
    /// external plugin exit. Service/process cleanup continues asynchronously,
    /// but the Bridge edge button and overlays disappear in this run-loop turn.
    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        hotkey?.unregister()
        hotkey = nil
        regionHotkey?.unregister()
        regionHotkey = nil
        bindingsObserver?.cancel()
        bindingsObserver = nil
        registryObserver?.cancel()
        registryObserver = nil
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
        workspaceActivationObserver = nil
        if let injectPulseObserver { NotificationCenter.default.removeObserver(injectPulseObserver) }
        injectPulseObserver = nil
        if let bindRequestObserver { NotificationCenter.default.removeObserver(bindRequestObserver) }
        bindRequestObserver = nil

        popover?.performClose(nil)
        overlay?.hide()
        overlay = nil
        composer?.close()
        composer = nil
        runBubble?.shutdown()
        runBubble = nil
        macBuildBubble?.shutdown()
        macBuildBubble = nil
        bindBubble?.shutdown()
        bindBubble = nil
        inspectorBubble?.shutdown()
        inspectorBubble = nil
        wireOverlay?.shutdown()
        wireOverlay = nil
        appState.intentOverlay.hide()
        appState.cursorOverlay.hide()
        liveReloader.stopAll()
        appState.streamProxy.onEvent = nil
        appState.bindings.unbindAll()
        appState.registry.removeAll()

        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        Task { @MainActor [appState] in await appState.shutdown() }
    }

    // MARK: - Status Item

    private func buildStatusItem() {
        // Plain brain status item. Click opens the popover. Title shows the
        // bindings count (" N") when ≥1, blank otherwise. The bind affordance
        // lives on the terminal window itself (BindBubbleController) — not in
        // the menu bar — for better discoverability.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "point.3.filled.connected.trianglepath.dotted", accessibilityDescription: "Bridge")
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover)
            button.target = self
            button.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        }

        let runner = RunBubbleController()
        runner.onRun = { [weak self] sessionId, command in
            self?.runCommandInSession(sessionId: sessionId, command: command)
        }
        runner.onDismiss = { [weak self] sessionId in
            self?.appState.runPillDismissed.insert(sessionId)
        }
        runBubble = runner

        let macBuild = MacBuildBubbleController()
        macBuild.onBuildAndRun = { [weak self] sessionId in
            self?.runMacAppBuildAndRun(sessionId: sessionId)
        }
        macBuild.onDismiss = { [weak self] sessionId in
            self?.appState.macBuildPillDismissed.insert(sessionId)
        }
        macBuildBubble = macBuild

        let bubble = BindBubbleController()
        bubble.setVisualTheme(visualTheme)
        bubble.onBind = { [weak self] sessionId in
            guard let self = self else { return }
            self.appState.connectRequest = BridgeConnectRequest(sessionId: sessionId)
            self.presentPopoverPublic()
        }
        bindBubble = bubble

        let insp = InspectorBubbleController()
        insp.onToggle = { [weak self] sessionId, enabled in
            self?.setInspectorEnabled(sessionId: sessionId, enabled: enabled)
        }
        inspectorBubble = insp

        let comp = ComposerController()
        comp.onSend = { [weak self] context, note, withImage in
            self?.handleComposerSend(context: context, note: note, withImage: withImage)
        }
        comp.bakeAnnotations = { [weak self] path, strokes, displaySize in
            self?.bakeAnnotatedImage(originalPath: path, strokes: strokes, displaySize: displaySize)
        }
        composer = comp
        appState.beginFeedback = { [weak self] sessionId in
            self?.beginFeedbackPublic(sessionId: sessionId)
        }

        // App activation plus registry/binding changes cover the contextual UI.
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshStartItem() }
        }
        refreshStartItem()
        refreshStatusBadge()
        // Re-render the badge whenever bindings change.
        bindingsObserver = appState.bindings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshStatusBadge()
                DispatchQueue.main.async { self?.refreshStartItem() }
            }
        // Two responsibilities on every registry update:
        //   1) Auto-unbind orphans — cmdy reported a pane close or its
        //      process exited, so its binding goes with it. This is how
        //      "close terminal → binding destroyed" gets enforced.
        //   2) Auto-bind newly-registered sessions to a sibling in the
        //      same project so opening a new tab inside a bound terminal
        //      window doesn't strand the new shell — it joins the existing
        //      Chrome adapter.
        registryObserver = appState.registry.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                guard let self = self else { return }
                let live = Set(sessions.map { $0.id })
                // Orphan check: only unbind a session that we PREVIOUSLY KNEW
                // to be alive and now isn't. The knownSessionIds guard was
                // originally added to protect restored-from-disk bindings
                // from being wiped before shells re-registered (commit
                // 92d1857). Bindings are now ephemeral so that race is
                // gone, but the guard still serves a purpose: prevents a
                // brand-new binding from being clobbered if the observer
                // fires before the shell has phoned in. Cheap insurance.
                let orphans = self.appState.bindings.bindings.keys.filter {
                    self.knownSessionIds.contains($0) && !live.contains($0)
                }
                if !orphans.isEmpty {
                    NSLog("[Bridge] orphan-cleanup live=%d known=%d bindings=%d orphans=%@",
                          live.count,
                          self.knownSessionIds.count,
                          self.appState.bindings.bindings.count,
                          Array(orphans).joined(separator: ","))
                }
                for id in orphans {
                    // terminateAdapter: false because the source TERMINAL
                    // is gone, not because the user wants the target
                    // dead. Bridge releases the adapter but leaves the
                    // spawned process alive — user can quit it themselves
                    // or rebind a new terminal to reattach.
                    self.unbindSession(sessionId: id, terminateAdapter: false)
                }
                let newIds = live.subtracting(self.knownSessionIds)
                for newId in newIds {
                    if let session = sessions.first(where: { $0.id == newId }) {
                        self.autoBindToSibling(session: session)
                    }
                }
                self.knownSessionIds.formUnion(live)
                self.refreshStatusBadge()
                self.refreshStartItem()
            }
    }

    func applyVisualTheme(_ theme: BridgeVisualTheme) {
        visualTheme = theme
        bindBubble?.setVisualTheme(theme)
        wireOverlay?.setVisualTheme(theme)
    }

    /// Decide what the contextual UI should show right now. Priority:
    ///   1. Runnable session focused → floating Run nag (carries the command).
    ///   2. Bindable session focused → chain icon next to the brain.
    ///   3. Neither → nothing.
    /// Run wins because once you're bound + dev-server-able, you've passed the
    /// bind step and the next contextual action is always Run.
    private func refreshStartItem() {
        // Run pill: every visible bound terminal that has a runnable dev
        // command and whose dev server isn't already listening. Anchored to
        // each terminal's right edge — same real estate as the bind bubble
        // (mutex per window: a window is either unbound = bind candidate,
        // or bound + has command + not running = run candidate, or running
        // = nothing).
        let runTargets: [RunBubbleController.Target] = appState.bindings.bindings.compactMap { (sid, _) in
            // User clicked × on the pill — suppress until rebound.
            if appState.runPillDismissed.contains(sid) { return nil }
            guard let runnable = runnableIfNotAlreadyRunning(sessionId: sid),
                  let wid = wireOverlay?.boundTerminalWindowId(for: sid),
                  let session = appState.registry.session(id: sid)
            else { return nil }
            let project = (session.projectPath as NSString?)?.lastPathComponent ?? "project"
            return RunBubbleController.Target(
                sessionId: sid,
                project: project,
                command: runnable.command,
                windowId: wid
            )
        }
        runBubble?.update(targets: runTargets)
        // One connection-menu plus per exact visible cmdy window.
        let bindTargets = bindableSessions().map { match -> BindBubbleController.Target in
            return BindBubbleController.Target(
                sessionId: match.sessionId,
                project: match.project,
                windowId: match.windowId
            )
        }
        bindBubble?.update(targets: bindTargets)

        // Inspector bubble: focused bound Chrome window (if any).
        let inspTargets = boundChromeSessions().map { match in
            InspectorBubbleController.Target(
                sessionId: match.sessionId,
                project: match.project,
                windowId: match.windowId,
                enabled: appState.chromeAdapters[match.sessionId]?.inspectorEnabled ?? false
            )
        }
        inspectorBubble?.update(targets: inspTargets)

        // Mac App Build & Run pill: every bound Mac App session whose
        // launched process is NOT currently alive (so the user has
        // something useful to click). Suppressed by × dismiss until rebind.
        let macBuildTargets: [MacBuildBubbleController.Target] = appState.bindings.bindings.compactMap { (sid, binding) in
            guard case .macAppProject = binding.target else { return nil }
            if appState.macBuildPillDismissed.contains(sid) { return nil }
            if let adapter = appState.macAppAdapters[sid], adapter.runningPid != nil { return nil }
            guard let wid = wireOverlay?.boundTerminalWindowId(for: sid),
                  let session = appState.registry.session(id: sid) else { return nil }
            let project = (session.projectPath as NSString?)?.lastPathComponent ?? "project"
            return MacBuildBubbleController.Target(sessionId: sid, project: project, windowId: wid)
        }
        macBuildBubble?.update(targets: macBuildTargets)
    }

    /// Triggered when the user clicks the floating "▶ Build & Run" pill on
    /// a Mac-App-bound terminal. Builds via `swift build`, runs the resulting
    /// binary if build succeeded. Reports state back to the pill so the
    /// label/color reflects "Building…" / "Error" / running.
    private func runMacAppBuildAndRun(sessionId: String) {
        guard let adapter = appState.macAppAdapters[sessionId] else { return }
        // Trace: when does the build/run cycle actually fire? Both the
        // Build & Run pill click AND any future auto-trigger funnel through
        // here. Caller is in the stack trace if the user filed a "why did
        // my window close" ticket.
        NSLog("[runMacAppBuildAndRun] starting for session=%@ project=%@",
              sessionId, adapter.projectPath)
        macBuildBubble?.setState(.building, for: sessionId)
        Task { @MainActor [weak self] in
            do {
                let result = try await adapter.build()
                if !result.success {
                    let msg = result.errors.first?.message ?? "build failed"
                    self?.macBuildBubble?.setState(.error(msg), for: sessionId)
                    return
                }
                _ = try await adapter.run()
                // Pill auto-removes on the next refreshStartItem tick once
                // adapter.runningPid != nil. No need to set .running state
                // explicitly — refreshStartItem polling drives it.
                self?.refreshStartItem()
            } catch {
                self?.macBuildBubble?.setState(.error(error.localizedDescription), for: sessionId)
            }
        }
    }

    /// Find ALL bound Chrome windows that are currently visible — not just
    /// the focused one. Inspector toggle should persist across focus changes
    /// so users can flip it without losing the bubble. Iterates every
    /// `chromeAdapters` entry, looks up its Chrome process's first layer-0
    /// window in the CGWindowList snapshot.
    private func boundChromeSessions() -> [(sessionId: String, project: String, windowId: CGWindowID)] {
        if appState.chromeAdapters.isEmpty { return [] }
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        // Build pid → first layer-0 windowId map (front-to-back gives us the
        // topmost window per pid, which is what we want).
        var firstWindow: [pid_t: CGWindowID] = [:]
        for w in list {
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            if firstWindow[pid] != nil { continue }
            firstWindow[pid] = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
        }
        var result: [(sessionId: String, project: String, windowId: CGWindowID)] = []
        for (sid, adapter) in appState.chromeAdapters {
            guard let pid = adapter.chromeProcessPid, let wid = firstWindow[pid] else { continue }
            let project = appState.registry.session(id: sid)?.projectPath
                .map { ($0 as NSString).lastPathComponent } ?? "session"
            result.append((sid, project, wid))
        }
        return result
    }

    /// Find unbound host sessions whose exact AppKit window is visible.
    /// The window number published by the host is the identity; Bridge never
    /// guesses from a title, cwd, process ancestry, or another terminal app.
    private func bindableSessions() -> [(sessionId: String, project: String, windowId: CGWindowID)] {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier == BridgeHostIdentity.bundleIdentifier else { return [] }
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let visibleHostWindows = Set(list.compactMap { window -> CGWindowID? in
            let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            guard owner == frontmost.processIdentifier, layer == 0 else { return nil }
            return (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        })

        // Focused panes win within a split window. Preserve registry order for
        // ordinary one-pane windows and as the fallback during focus transfer.
        let sessions = appState.registry.sessions.filter(\.paneFocused)
            + appState.registry.sessions.filter { !$0.paneFocused }
        var emitted: Set<CGWindowID> = []
        return sessions.compactMap { session in
            guard session.terminalApp.caseInsensitiveCompare(
                    BridgeHostIdentity.slug) == .orderedSame,
                  appState.bindings.get(sessionId: session.id) == nil,
                  let windowId = session.windowId,
                  visibleHostWindows.contains(windowId),
                  emitted.insert(windowId).inserted else { return nil }
            let project = session.projectPath.flatMap { path in
                path.isEmpty ? nil : (path as NSString).lastPathComponent
            } ?? session.windowTitle ?? "shell"
            return (session.id, project, windowId)
        }
    }

    /// If the frontmost app is either a recognised terminal hosting a bound
    /// session, OR one of our bound Chrome processes, AND that session has a
    /// runnable command AND its dev server isn't already listening — return
    /// (sessionId, command). Used by the contextual menu-bar Start button.
    private func focusedRunnableSession() -> (sessionId: String, command: String)? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        let frontPid = frontmost.processIdentifier
        let bid = frontmost.bundleIdentifier ?? ""

        // Path 1: focused app is a recognised terminal — walk session shell PIDs
        // up to find one whose ancestor matches AND has a runnable command.
        // A session that walks to this app but isn't runnable (no projectInfo,
        // no dev script, or server already running) shouldn't gate later
        // sessions in the iteration: keep searching, return nil only if no
        // candidate qualifies.
        if TextInjection.isTerminalApp(bundleId: bid) {
            for session in appState.registry.sessions {
                var pid: pid_t = pid_t(session.pid)
                var matchedApp = false
                for _ in 0..<8 {
                    if pid == frontPid {
                        matchedApp = true
                        break
                    }
                    let parent = parentPID(of: pid)
                    if parent <= 1 { break }
                    pid = parent
                }
                if matchedApp, let result = runnableIfNotAlreadyRunning(sessionId: session.id) {
                    return result
                }
            }
        }

        // Path 2: focused app is a Chrome process we launched — match by PID
        // against our adapters. The button shows up while the user is looking
        // at the bound browser too, not just the terminal.
        for (sessionId, adapter) in appState.chromeAdapters {
            if adapter.chromeProcessPid == frontPid {
                return runnableIfNotAlreadyRunning(sessionId: sessionId)
            }
        }
        return nil
    }

    /// Resolve project command for a session, gated on "the dev server isn't
    /// already running on its known port" — clicking Start while the server is
    /// up would just relaunch (or fail with EADDRINUSE), so we hide the button.
    /// Checks ACROSS the project group: if any session in the same project has
    /// an active running port, hide for all. Without this a fresh tab in the
    /// same project would have an empty entry and the nag would re-fire.
    private func runnableIfNotAlreadyRunning(sessionId: String) -> (sessionId: String, command: String)? {
        guard let info = appState.projectInfos[sessionId],
              let cmd = ProjectAnalyzer.primaryRunCommand(for: info) else { return nil }

        let projectPath = appState.registry.session(id: sessionId)?.projectPath
        let groupSessionIds: [String] = appState.registry.sessions
            .filter { $0.projectPath == projectPath }
            .map { $0.id }

        for sid in groupSessionIds {
            guard let port = appState.runningDevServerPorts[sid] else { continue }
            if Self.isPortListeningOnLoopback(port) {
                return nil  // a sibling's server is alive → hide Start for everyone
            } else {
                // Cached port no longer listens — server died, clear so Start re-appears.
                appState.runningDevServerPorts.removeValue(forKey: sid)
            }
        }
        return (sessionId, cmd.command)
    }

    /// Sync TCP connect to 127.0.0.1:port. Loopback rejects connections to
    /// non-listening ports instantly (RST), so this is reliably <5ms.
    private static func isPortListeningOnLoopback(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saddr in
                connect(sock, saddr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let r = mib.withUnsafeMutableBufferPointer { ptr -> Int32 in
            sysctl(ptr.baseAddress, u_int(ptr.count), &info, &size, nil, 0)
        }
        if r != 0 || size == 0 { return -1 }
        return info.kp_eproc.e_ppid
    }

    /// Brain's count badge: " N" where N is the number of LIVE bound sessions
    /// (binding exists AND the shell is currently registered). Persisted-but-
    /// not-yet-live bindings are NOT counted — otherwise the badge says "1"
    /// while the popover's session list is empty (because the bound shell
    /// hasn't re-registered after a bridge restart). This keeps the badge
    /// consistent with the sessions shown in the popover.
    private func refreshStatusBadge() {
        guard let button = statusItem?.button else { return }
        let live = Set(appState.registry.sessions.map { $0.id })
        let count = appState.bindings.bindings.keys.filter { live.contains($0) }.count
        button.title = count == 0 ? "" : " \(count)"
    }

    private func buildPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        // Must match `PopoverContent.body`'s `.frame` exactly — otherwise the
        // popover window crops the SwiftUI view (header gets pushed off-screen).
        popover.contentSize = NSSize(width: 380, height: 520)
        let root = PopoverContent(
            appState: appState,
            onBindChrome: { [weak self] sessionId, useMyChrome in
                self?.bindSessionToChrome(sessionId: sessionId, useMyChrome: useMyChrome)
            },
            onBindMacApp: { [weak self] sessionId in
                self?.bindSessionToMacApp(sessionId: sessionId)
            },
            onBindSimulator: { [weak self] sessionId, udid in
                Task { @MainActor [weak self] in
                    await self?.bindSessionToSimulator(sessionId: sessionId, udid: udid)
                }
            },
            onBindNativeApp: { [weak self] sessionId, bundleId in
                self?.bindSessionToNativeApp(sessionId: sessionId, bundleId: bundleId)
            },
            onUnbind: { [weak self] sessionId in self?.unbindSession(sessionId: sessionId) },
            onUnbindGroup: { [weak self] sessionIds in
                guard let self = self else { return }
                for id in sessionIds { self.unbindSession(sessionId: id) }
            },
            onToggleInspector: { [weak self] sessionId, enabled in
                self?.setInspectorEnabled(sessionId: sessionId, enabled: enabled)
            },
            onRunCommand: { [weak self] sessionId, command in
                self?.runCommandInSession(sessionId: sessionId, command: command)
            },
            onReopenChrome: { [weak self] sessionId in
                self?.reopenSession(sessionId: sessionId)
            },
            onResetAll: { [weak self] in self?.resetAllState() }
        )
        popover.contentViewController = NSHostingController(rootView: root)
    }

    /// Show the menu-bar connection UI without toggling an already-open
    /// popover closed. Used by cmdy's window-edge plus.
    func presentPopoverPublic() {
        if !popover.isShown { showPopover() }
    }

    /// Arm semantic feedback on the target owned by `sessionId`. Chrome can
    /// expose exact DOM identity, so it uses the in-page inspector. Other
    /// adapters still preserve the bound target and window geometry in a
    /// native composer rather than degrading to an unrelated screenshot.
    func beginFeedbackPublic(sessionId: String) {
        guard let binding = appState.bindings.get(sessionId: sessionId),
              let adapter = appState.adapter(for: sessionId) else {
            NSSound.beep()
            return
        }
        if case .chrome = binding.target {
            setInspectorEnabled(sessionId: sessionId, enabled: true)
            return
        }

        let frame = adapter.windowFrame()
        let target: String
        var metadata: [String: Any] = ["sessionId": sessionId]
        switch binding.target {
        case .chrome:
            target = "Chrome"
        case .macAppProject(let path):
            target = (path as NSString).lastPathComponent
            metadata["projectPath"] = path
            metadata["targetKind"] = "mac-app-project"
        case .simulator(let udid):
            target = "iOS Simulator"
            metadata["udid"] = udid
            metadata["targetKind"] = "simulator"
        case .nativeApp(let bundleId):
            target = bundleId
            metadata["bundleId"] = bundleId
            metadata["targetKind"] = "native-app"
        }
        metadata["target"] = target
        if let frame {
            metadata["windowBounds"] = [
                "x": frame.minX, "y": frame.minY,
                "width": frame.width, "height": frame.height,
            ]
        }
        guard let pid = adapter.anchorPid, let frame else {
            NSSound.beep()
            return
        }
        feedbackOverlay.begin(pid: pid, frame: frame, targetContext: metadata) { [weak self] payload in
            self?.recordFeedback(sessionId: sessionId, payload: payload)
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        appState.registry.purgeStale()

        Task { @MainActor in
            self.appState.bootedSimulators = await SimulatorAdapter.listBooted()
            self.appState.idbInstalled = await SimulatorAdapter.idbAvailable()
        }

        let myPid = NSRunningApplication.current.processIdentifier
        appState.runningNativeApps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  let bundleId = app.bundleIdentifier,
                  !TextInjection.isTerminalLikeApp(bundleId: bundleId),
                  app.processIdentifier != myPid else { return nil }
            return ["bundleId": bundleId, "name": app.localizedName ?? bundleId]
        }
        .sorted {
            ($0["name"] as? String ?? "").localizedCaseInsensitiveCompare(
                $1["name"] as? String ?? "") == .orderedAscending
        }

        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: - HTTP / MCP startup

    private func startServer() async {
        let http = HTTPServer(
            port: 3457,
            authenticationToken: authenticationToken,
            crossOriginAuthenticationToken: browserAuthenticationToken)
        appState.httpServer = http

        // Registry routes (will be expanded by RegistryRoutes agent module).
        RegistryRoutes.register(
            on: http,
            registry: appState.registry,
            bindings: appState.bindings,
            proxyPort: { [weak self] in self?.appState.streamProxy.port ?? 0 }
        )

        // Thumbnail serving for the screenshot animation. The cursor JS in the bound
        // Chrome page loads `http://127.0.0.1:<port>/thumbnail/<filename>` to display
        // the captured image — going via HTTP avoids both base64-string truncation in
        // big screenshots and CSP rejections of `data:` URIs.
        http.routePrefix(.GET, "/thumbnail/", allowsCrossOrigin: true) { req in
            let filename = req.pathTail
            // Strict whitelist: only `bridge-shot-<uuid>.png|jpg` from /tmp.
            let safe = filename.allSatisfy {
                $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "."
            }
            guard safe,
                  filename.hasPrefix("bridge-shot-"),
                  filename.hasSuffix(".png") || filename.hasSuffix(".jpg")
            else { return .notFound() }
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)
            guard let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 128 * 1024 * 1024,
                  let data = try? BridgeBoundedFileReader.data(
                    at: url, maxBytes: 128 * 1024 * 1024)
            else { return .notFound() }
            let mime = filename.hasSuffix(".png") ? "image/png" : "image/jpeg"
            return HTTPServer.HTTPResponse(
                status: .ok,
                body: NSNull(),
                contentType: mime,
                rawData: data
            )
        }

        // Composer panel handoff. Any source (web inspector, future terminal-
        // selection capture, simulator picker, etc.) POSTs structured context
        // here; the bridge captures a screenshot if a clip is provided, then
        // shows a native NSPanel composer where the user types their note and
        // hits Send. Decouples capture (web/native/terminal) from the
        // composer UI, so we can grow new sources without page-side popups.
        // Body: {
        //   sessionId, title, subtitle?, bodyMarkdown,
        //   screenshotClip?: {x,y,width,height}   // captured via CDP if set
        // }
        http.route(.POST, "/composer/show", allowsCrossOrigin: true) { [weak self] req in
            guard let self = self else { return .badRequest("controller gone") }
            guard let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let sid = json["sessionId"] as? String,
                  let title = json["title"] as? String,
                  !sid.isEmpty, sid.utf8.count <= 128,
                  !title.isEmpty, title.utf8.count <= 4_096
            else {
                return .badRequest("Body: { sessionId, title, source?, context?, bodyMarkdown? }")
            }
            let body = json["bodyMarkdown"] as? String ?? ""
            let subtitle = json["subtitle"] as? String
            let source = json["source"] as? String ?? "bridge"
            guard body.utf8.count <= 4 * 1024 * 1024,
                  (subtitle?.utf8.count ?? 0) <= 4_096,
                  !source.isEmpty, source.utf8.count <= 256 else {
                return .badRequest("Composer fields are too large")
            }
            let sessionExists = await MainActor.run {
                self.appState.registry.session(id: sid) != nil
            }
            guard sessionExists else { return .notFound() }
            let structuredContext = json["context"] as? [String: Any] ?? [:]
            var imagePath: String? = nil
            if let shot = json["screenshot"] as? [String: Any],
               let rect = shot["rect"] as? [String: Any],
               let rx = (rect["x"] as? NSNumber)?.doubleValue,
               let ry = (rect["y"] as? NSNumber)?.doubleValue,
               let rw = (rect["width"] as? NSNumber)?.doubleValue,
               let rh = (rect["height"] as? NSNumber)?.doubleValue {
                let chromeTop = (shot["chromeTop"] as? NSNumber)?.doubleValue ?? 80
                let dpr = (shot["dpr"] as? NSNumber)?.doubleValue ?? 1
                imagePath = await self.captureChromeRegion(
                    sessionId: sid,
                    viewportRect: CGRect(x: rx, y: ry, width: rw, height: rh),
                    chromeTopHeight: chromeTop,
                    dpr: dpr
                )
            }
            // Element rect in NSScreen coords (bottom-left, points).
            // JS sends top-left web pixels — flip y using the screen the
            // element sits on (multi-monitor safe via screen-finding by
            // rough Y range; falls back to primary).
            var elementRect: NSRect? = nil
            if let er = json["elementRect"] as? [String: Any],
               let ex = (er["x"] as? NSNumber)?.doubleValue,
               let ey = (er["y"] as? NSNumber)?.doubleValue,
               let ew = (er["width"] as? NSNumber)?.doubleValue,
               let eh = (er["height"] as? NSNumber)?.doubleValue,
               ex.isFinite, ey.isFinite, ew.isFinite, eh.isFinite,
               abs(ex) <= 1_000_000, abs(ey) <= 1_000_000,
               ew > 0, eh > 0, ew <= 1_000_000, eh <= 1_000_000 {
                let primaryHeight = await MainActor.run {
                    NSScreen.main?.frame.height ?? NSScreen.screens.first?.frame.height ?? 0
                }
                elementRect = NSRect(
                    x: ex,
                    y: primaryHeight - ey - eh,
                    width: ew,
                    height: eh
                )
            }
            await MainActor.run {
                self.composer?.show(
                    context: .init(
                        sessionId: sid,
                        source: source,
                        title: title,
                        subtitle: subtitle,
                        bodyMarkdown: body,
                        imagePath: imagePath,
                        structuredContext: structuredContext
                    ),
                    elementRect: elementRect
                )
                // Auto-disable inspect mode on capture. The user just picked
                // an element — they're done browsing for elements; let them
                // interact with the page normally. To capture another element
                // they re-arm via the scope dot. Mirrors how Cleanshot /
                // macOS Markup behave: capture → exit selection mode.
                self.setInspectorEnabled(sessionId: sid, enabled: false)
            }
            return .ok(["ok": true])
        }

        // MCP routes.
        let mcp = BridgeMCPServer(appState: appState)
        appState.mcpServer = mcp
        mcp.registerRoutes(on: http)

        do {
            let port = try await http.start()
            if isShuttingDown {
                await http.stop()
                return
            }
            NSLog("[Bridge] HTTP server listening on %d", port)
            NSLog("[Bridge] Binary built %@ at %@",
                  BuildInfo.shortStamp,
                  Bundle.main.executableURL?.path ?? "?")
        } catch {
            NSLog("[Bridge] HTTP server failed to start: %@", error.localizedDescription)
        }
    }

    /// Capture a region of the bound Chrome window using NATIVE macOS window
    /// capture (CGWindowListCreateImage), then crop in CG and save as PNG.
    /// Native capture reads pixels directly from the WindowServer surface
    /// with ZERO involvement from Chrome's renderer — no Chrome paint, no
    /// flash, no CDP-induced repaint side-effects.
    ///
    /// Coordinate translation: viewport (page) coords → screen coords =
    /// windowFrame.origin + (chromeTopHeight, 0) + (rect.x, rect.y), all in
    /// device-independent points. CG image is in PIXELS (Retina = 2x) so
    /// crop coords get multiplied by `dpr` before slicing.
    private func captureChromeRegion(
        sessionId: String,
        viewportRect: CGRect,
        chromeTopHeight: CGFloat,
        dpr: CGFloat
    ) async -> String? {
        guard let adapter = appState.chromeAdapters[sessionId],
              let chromePid = adapter.chromeProcessPid else {
            NSLog("[Bridge] capture: no adapter / pid for %@", sessionId)
            return nil
        }
        // Find the Chrome window's CGWindowID by pid.
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var wid: CGWindowID = 0
        for w in list {
            let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard pid == chromePid && layer == 0 else { continue }
            wid = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            break
        }
        guard wid != 0 else {
            NSLog("[Bridge] capture: no chrome window for pid %d", chromePid)
            return nil
        }
        // ScreenCaptureKit window-targeted screenshot. Replaces the now-removed
        // CGWindowListCreateImage. Reads from the WindowServer surface — no
        // Chrome paint, no flash.
        do {
            let content = try await SCShareableContent.current
            guard let window = content.windows.first(where: { $0.windowID == wid }) else {
                NSLog("[Bridge] capture: SCShareableContent has no window %u", wid)
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let pixelWidth = window.frame.width * dpr
            let pixelHeight = window.frame.height * dpr
            guard dpr.isFinite, dpr > 0,
                  pixelWidth.isFinite, pixelHeight.isFinite,
                  pixelWidth > 0, pixelHeight > 0,
                  pixelWidth <= 16_384, pixelHeight <= 16_384 else {
                NSLog("[Bridge] capture: invalid window dimensions")
                return nil
            }
            config.width = Int(pixelWidth.rounded(.up))
            config.height = Int(pixelHeight.rounded(.up))
            config.scalesToFit = false
            config.showsCursor = false
            let windowImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            // Crop in pixels. Window image's origin is the window's top-left;
            // page viewport begins `chromeTopHeight` below that.
            let cropX = viewportRect.minX * dpr
            let cropY = (chromeTopHeight + viewportRect.minY) * dpr
            let cropW = viewportRect.width * dpr
            let cropH = viewportRect.height * dpr
            guard cropX.isFinite, cropY.isFinite,
                  cropW.isFinite, cropH.isFinite,
                  cropW > 0, cropH > 0 else {
                NSLog("[Bridge] capture: invalid crop dimensions")
                return nil
            }
            let cropPx = CGRect(x: cropX, y: cropY, width: cropW, height: cropH).integral
            let imageRect = CGRect(x: 0, y: 0, width: windowImage.width, height: windowImage.height)
            let safeCrop = cropPx.intersection(imageRect)
            guard !safeCrop.isEmpty, let cropped = windowImage.cropping(to: safeCrop) else {
                NSLog("[Bridge] capture: crop failed (px=%@ image=%dx%d)",
                      String(describing: cropPx), windowImage.width, windowImage.height)
                return nil
            }
            let filename = "bridge-shot-\(UUID().uuidString.prefix(8)).png"
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)
            let bitmap = NSBitmapImageRep(cgImage: cropped)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                NSLog("[Bridge] capture: PNG encode failed")
                return nil
            }
            try png.write(to: url)
            return url.path
        } catch {
            NSLog("[Bridge] capture: SC capture failed: %@", String(describing: error))
            return nil
        }
    }

    /// Flatten user annotations into a single image and scale down for token
    /// efficiency. Pen strokes from the SwiftUI canvas are in DISPLAY-POINT
    /// space relative to the image's display rect; we transform them to the
    /// original image's PIXEL space, render onto the original via CGContext,
    /// then scale the whole thing to a max long-edge of 1024px and JPEG-encode.
    /// Returns the path of the new baked file (or nil on failure).
    private func bakeAnnotatedImage(
        originalPath: String,
        strokes: [Stroke],
        displaySize: CGSize
    ) -> String? {
        guard let original = NSImage(contentsOfFile: originalPath),
              let cgOriginal = original.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let pixelW = CGFloat(cgOriginal.width)
        let pixelH = CGFloat(cgOriginal.height)
        // Token-efficiency cap: long edge ≤ 1024px.
        let maxLong: CGFloat = 1024
        let scale = min(1.0, maxLong / max(pixelW, pixelH))
        let outW = Int((pixelW * scale).rounded())
        let outH = Int((pixelH * scale).rounded())
        // SwiftUI canvas points → output pixels.
        let xScale = CGFloat(outW) / displaySize.width
        let yScale = CGFloat(outH) / displaySize.height

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Use top-left origin to match SwiftUI canvas coords.
        ctx.translateBy(x: 0, y: CGFloat(outH))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high

        // Draw the (scaled) original.
        ctx.draw(cgOriginal, in: CGRect(x: 0, y: 0, width: outW, height: outH))

        // Draw strokes on top.
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for stroke in strokes {
            ctx.setStrokeColor(stroke.color.cgColor)
            ctx.setFillColor(stroke.color.cgColor)
            let scaledWidth = stroke.width * xScale
            ctx.setLineWidth(scaledWidth)
            if stroke.points.count == 1 {
                let p = stroke.points[0]
                let r = CGRect(
                    x: p.x * xScale - scaledWidth / 2,
                    y: p.y * yScale - scaledWidth / 2,
                    width: scaledWidth, height: scaledWidth
                )
                ctx.fillEllipse(in: r)
            } else if stroke.points.count > 1 {
                ctx.beginPath()
                let first = stroke.points[0]
                ctx.move(to: CGPoint(x: first.x * xScale, y: first.y * yScale))
                for p in stroke.points.dropFirst() {
                    ctx.addLine(to: CGPoint(x: p.x * xScale, y: p.y * yScale))
                }
                ctx.strokePath()
            }
        }

        guard let baked = ctx.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: baked)
        guard let data = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.85]
        ) else { return nil }
        let outPath = NSTemporaryDirectory() + "bridge-baked-\(UUID().uuidString.prefix(8)).jpg"
        do {
            try data.write(to: URL(fileURLWithPath: outPath))
            return outPath
        } catch {
            NSLog("[Bridge] bake: write failed: %@", String(describing: error))
            return nil
        }
    }

    /// Composer Send button → build final markdown (body + optional image
    /// + user note), inject into the bound terminal, and pulse the wire.
    /// Route a tool-stream event from the proxy into the intent overlay.
    /// Bridge-MCP tool names look like `mcp__braincell-bridge__<tool>` over the
    /// wire — we strip that prefix and only fire the overlay for our own tools
    /// (Claude may also call IDE tools like `read`/`bash`/`edit` in the same
    /// stream; those are not bridge concerns).
    private func handleStreamEvent(_ event: ToolStreamEvent) {
        switch event {
        case .composeStart(let sid, let toolName, _):
            guard let bridgeTool = Self.bridgeToolName(from: toolName) else { return }
            appState.intentOverlay.startComposing(sessionId: sid, toolName: bridgeTool)

        case .composeDelta:
            // V1: ignore deltas. The label updates on composeStop with the
            // full reconstructed args. Future: progressive label resolution
            // as the partial JSON parses.
            return

        case .composeStop(let sid, let toolName, let full):
            guard let bridgeTool = Self.bridgeToolName(from: toolName) else { return }
            // Best-effort: if the args reconstruct to valid JSON, build the
            // resolved label. Otherwise leave the "composing X…" label as-is
            // until the MCP dispatch arrives and overrides it.
            if let data = full.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let label = IntentOverlayController.label(for: bridgeTool, args: parsed)
                appState.intentOverlay.updateComposing(sessionId: sid, label: label)
            }
        }
    }

    /// Strip the MCP namespace prefix from a streamed tool name. Names look
    /// like `mcp__braincell-bridge__click` or `mcp__bridge__click`. Returns
    /// nil for non-bridge tools.
    private static func bridgeToolName(from streamedName: String) -> String? {
        let parts = streamedName.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp", parts[1].contains("bridge") else { return nil }
        return parts[2...].joined(separator: "__")
    }

    private func handleComposerSend(
        context: ComposerController.Context,
        note: String,
        withImage: Bool
    ) {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNote.isEmpty else { return }
        var payload: [String: Any] = [
            "source": context.source,
            "comment": trimmedNote,
            "context": context.structuredContext,
            "sessionId": context.sessionId,
            "intent": "change",
            "severity": "normal",
            "status": "open",
        ]
        if withImage, let path = context.imagePath {
            payload["attachment"] = ["kind": "image", "path": path]
        }
        recordFeedback(sessionId: context.sessionId, payload: payload,
                       fallbackMarkdown: context.bodyMarkdown,
                       fallbackImagePath: withImage ? context.imagePath : nil)
    }

    private func recordFeedback(sessionId: String, payload: [String: Any],
                                fallbackMarkdown: String = "",
                                fallbackImagePath: String? = nil) {
        var payload = payload
        payload["sessionId"] = sessionId
        let record = appState.feedback.add(payload)
        if let onFeedback {
            onFeedback(sessionId, record)
        } else if let session = appState.registry.session(id: sessionId) {
            let comment = payload["comment"] as? String ?? ""
            var md = fallbackMarkdown
            if !md.isEmpty { md += "\n\n" }
            md += comment
            if let path = fallbackImagePath {
                md += "\n\n![selected element](\(path))"
            }
            if !md.hasSuffix("\n") { md += "\n" }
            Task { await TextInjection.send(md, to: session, pressReturn: false) }
        }
        NotificationCenter.default.post(
            name: .braincellBridgeInjectPulse,
            object: nil,
            userInfo: ["sessionId": sessionId]
        )
    }

    // MARK: - Bindings (called from popover UI)

    private func bindSessionToChrome(sessionId: String, useMyChrome: Bool = false) {
        // Allocate the port synchronously BEFORE the async Chrome launch so two
        // back-to-back Bind clicks don't race onto the same port and produce the
        // "No page targets found" CDP error.
        let cdpPort = appState.nextCdpPort
        appState.nextCdpPort += 1

        // useMyChrome=true: launch Chrome with the user's real profile (extensions,
        // bookmarks, logins). Requires their main Chrome to NOT be running with the
        // same profile — otherwise the new launch piggybacks on the existing process
        // and CDP won't activate. We surface a clear error in that case.
        let profileDir: String = useMyChrome
            ? Self.defaultChromeProfileDir
            : NSTemporaryDirectory() + "braincell-bridge-chrome-\(sessionId.prefix(8))"

        if useMyChrome && Self.isMainChromeRunningWithDefaultProfile() {
            NSLog("[Bridge] Refusing to bind My Chrome — main Chrome appears to be running.")
            appState.chromeAdapters.removeValue(forKey: sessionId)
            // Surface the issue via a brief NSAlert so the user understands.
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Quit Chrome first"
            alert.informativeText = "To use your real Chrome profile, please quit Google Chrome first, then click Bind My Chrome again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Pre-compute Chrome's launch frame so it OPENS in the right place
        // (no visible jump from default position → AX-snapped position).
        let chromeLaunchFrame = computeChromeLaunchFrame(forSessionId: sessionId)
        let adapter = ChromeAdapter(cdpPort: cdpPort, profileDir: profileDir, initialFrame: chromeLaunchFrame)
        // When the bound Chrome window closes (Cmd+W, Cmd+Q, crash), drop
        // the binding entirely. The `+` bind affordance reappears on the
        // terminal; clicking it re-binds and re-launches Chrome. This is
        // cleaner than keeping a half-alive adapter around with
        // Reopen/Forget UI.
        adapter.onTerminated = { [weak self] in
            guard let self = self else { return }
            NSLog("[Bridge] Chrome process for session %@ terminated; unbinding", sessionId)
            self.unbindSession(sessionId: sessionId)
        }
        // Reserve the dictionary slot immediately so concurrent state reads see it.
        appState.chromeAdapters[sessionId] = adapter

        appState.lastLaunchErrors.removeValue(forKey: sessionId)

        // Capture the frontmost terminal window NOW, before launching Chrome
        // (which will likely steal focus + change z-order). Wire overlay anchors
        // to this specific window for the lifetime of the binding.
        ensureWireOverlay()
        if let session = appState.registry.session(id: sessionId) {
            wireOverlay?.stickToTerminalWindowAtBindTime(forSession: session)
        }

        // Synchronously commit binding state so any affordance that watches
        // `appState.bindings` (Run pill, status badge count, popover) shows
        // up immediately rather than after Chrome's 1–2s launch. If launch
        // fails we'll roll back in the catch block.
        let projectPath = appState.registry.session(id: sessionId)?.projectPath
        if let projectPath = projectPath {
            appState.projectInfos[sessionId] = ProjectAnalyzer.analyze(path: projectPath)
            liveReloader.start(sessionId: sessionId, projectPath: projectPath)
        }
        appState.bindings.bind(sessionId: sessionId, target: .chrome(profileDir: profileDir, cdpPort: cdpPort))

        Task {
            do {
                try await adapter.launch()
                if let projectPath = projectPath, let info = appState.projectInfos[sessionId] {
                    if info.hasIndexHtml {
                        let indexPath = (projectPath as NSString).appendingPathComponent("index.html")
                        try? await adapter.navigate(to: "file://\(indexPath)")
                    }
                }
                // Sweep up sibling sessions in the same project that registered
                // before the user clicked Bind.
                autoBindSiblingsAfterBind(
                    sourceSessionId: sessionId,
                    projectPath: projectPath,
                    adapter: adapter,
                    target: .chrome(profileDir: profileDir, cdpPort: cdpPort)
                )
                ensureWireOverlay()
                // Tile bound terminal + Chrome side-by-side so the user sees
                // both at once. Preserves which side each was on originally.
                arrangeWindowsSideBySide(sessionId: sessionId)
            } catch {
                NSLog("[Bridge] Failed to launch Chrome for session %@ on port %d: %@",
                      sessionId, cdpPort, error.localizedDescription)
                // Roll back EVERY synchronous side-effect — adapter slot,
                // binding entry, projectInfos cache — so the popover/bubbles
                // reflect the failure state and the user can retry cleanly.
                appState.chromeAdapters.removeValue(forKey: sessionId)
                appState.bindings.unbind(sessionId: sessionId)
                appState.projectInfos.removeValue(forKey: sessionId)
                liveReloader.stop(sessionId: sessionId)
                appState.lastLaunchErrors[sessionId] = error.localizedDescription
            }
        }
    }

    /// Toggle the inspector toolbar in a bound session's Chrome window.
    private func setInspectorEnabled(sessionId: String, enabled: Bool) {
        guard let adapter = appState.chromeAdapters[sessionId] else { return }
        Task {
            if enabled {
                if let port = appState.httpServer?.port {
                    await adapter.enableInspector(
                        sessionId: sessionId,
                        httpPort: port,
                        authenticationToken: browserAuthenticationToken)
                }
            } else {
                await adapter.disableInspector()
            }
            // Force a SwiftUI republish so the popover toggle reflects the new
            // state, AND refresh the floating inspector bubble so its color
            // updates immediately (it reads adapter.inspectorEnabled per tick).
            appState.objectWillChange.send()
            refreshStartItem()
        }
    }

    // MARK: - Chrome profile detection

    private static var defaultChromeProfileDir: String {
        ("~/Library/Application Support/Google/Chrome" as NSString).expandingTildeInPath
    }

    /// Best-effort check: is the user's main Chrome currently running with the
    /// default profile? Looks for any process named "Google Chrome" (the parent;
    /// the renderers are "Google Chrome Helper") via `pgrep`.
    private static func isMainChromeRunningWithDefaultProfile() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-x", "Google Chrome"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return false
        }
        return proc.terminationStatus == 0
    }

    /// Wipe ALL bridge state — every session, every binding, every Chrome
    /// adapter. Used when stale state accumulates from dev-cycle terminal
    /// churn or when the user wants to start fresh. Surviving zsh hooks
    /// will re-register their sessions on the next heartbeat.
    private func resetAllState() {
        NSLog("[Bridge] Reset all: wiping %d sessions, %d bindings, %d adapters",
              appState.registry.sessions.count,
              appState.bindings.bindings.count,
              appState.chromeAdapters.count)
        // TargetAdapter protocol: shutdown every adapter (kills Chromes
        // + any running Mac App processes; sim/native are no-op shutdowns
        // since we don't own those processes), then clear all dicts.
        for pair in appState.allAdapters() {
            let adapter = pair.adapter
            Task { await adapter.shutdown() }
        }
        appState.chromeAdapters.removeAll()
        appState.macAppAdapters.removeAll()
        appState.simAdapters.removeAll()
        appState.nativeAdapters.removeAll()
        appState.bindings.unbindAll()
        appState.projectInfos.removeAll()
        appState.lastLaunchErrors.removeAll()
        appState.runningDevServerPorts.removeAll()
        appState.runPillDismissed.removeAll()
        appState.macBuildPillDismissed.removeAll()
        liveReloader.stopAll()
        // Drop every registered session so the registry starts clean. Hooks
        // running in live shells will re-register on their next heartbeat
        // (every 30s) — within ~30s the popover repopulates with only the
        // currently-alive shells.
        appState.registry.removeAll()
        wireOverlay?.refreshVisibility()
        refreshStatusBadge()
    }

    /// Unbind a session.
    ///
    /// `terminateAdapter` controls whether the adapter's spawned process
    /// gets killed:
    /// - `true` (default) — user-explicit unbind. Kills Chrome / quits Mac
    ///   App / removes Sim or Native observers. Standard "I want this gone"
    ///   semantics.
    /// - `false` — terminal closed (registry orphan cleanup). Drops the
    ///   binding + adapter ref but leaves the spawned process ALIVE.
    ///   Closing a terminal should not terminate the app the bridge spawned;
    ///   the target survives and can be rebound from another session.
    private func unbindSession(sessionId: String, terminateAdapter: Bool = true) {
        // Generic per-session state cleanup (no adapter awareness needed).
        appState.bindings.unbind(sessionId: sessionId)
        appState.projectInfos.removeValue(forKey: sessionId)
        appState.lastLaunchErrors.removeValue(forKey: sessionId)
        appState.runningDevServerPorts.removeValue(forKey: sessionId)
        appState.runPillDismissed.remove(sessionId)
        appState.macBuildPillDismissed.remove(sessionId)
        liveReloader.stop(sessionId: sessionId)

        // TargetAdapter protocol: pop whichever adapter holds this session
        // out of its per-target dict. Reference-counted shutdown — an
        // adapter shared by multiple sessions (Chrome's sibling auto-bind
        // cascade) only gets shutdown when the LAST session unbinds.
        if let adapter = appState.removeAdapter(for: sessionId) {
            let stillReferenced = appState.allAdapters().contains { $0.adapter === adapter }
            if !stillReferenced && terminateAdapter {
                Task { await adapter.shutdown() }
            } else if !stillReferenced {
                NSLog("[Bridge] unbind sessionId=%@ terminateAdapter=false — adapter released without shutdown (spawned process keeps running)", sessionId)
            }
        }
        wireOverlay?.refreshVisibility()
    }

    /// Bind a session to its current project as a Mac app project. Creates a
    /// MacAppAdapter rooted at the session's `projectPath`; tools become
    /// available via the `mac_*` MCP surface immediately. No process is
    /// launched until Claude calls `mac_run` (after `mac_build`).
    private func bindSessionToMacApp(sessionId: String) {
        guard let session = appState.registry.session(id: sessionId),
              let projectPath = session.projectPath, !projectPath.isEmpty else {
            NSLog("[Bridge] bindSessionToMacApp: no projectPath for session %@", sessionId)
            return
        }
        // If the session is already bound (e.g. to Chrome), unbind first so
        // we don't end up with two competing target adapters per session.
        if appState.bindings.get(sessionId: sessionId) != nil {
            unbindSession(sessionId: sessionId)
        }
        let adapter = MacAppAdapter(projectPath: projectPath)
        adapter.onTerminated = { [weak self] in
            // App process exited (Cmd+Q, crash, manual stop). Drop the
            // binding so the `+` reappears on the terminal — clicking it
            // re-binds and rebuilds+relaunches the app. Same lifecycle as
            // Chrome: target dies → binding dies → re-bind to re-open.
            guard let self = self else { return }
            NSLog("[Bridge] Mac App process for session %@ terminated; unbinding", sessionId)
            self.unbindSession(sessionId: sessionId)
        }
        appState.macAppAdapters[sessionId] = adapter
        appState.bindings.bind(sessionId: sessionId, target: .macAppProject(projectPath: projectPath))
        // Capture which terminal window this session lives in so the
        // MacBuildBubble (and any other window-edge overlay) can anchor
        // to it. Same call ChromeAdapter binding makes — without this
        // the pill has no windowId to attach to and silently doesn't render.
        ensureWireOverlay()
        wireOverlay?.stickToTerminalWindowAtBindTime(forSession: session)
        NSLog("[Bridge] bound session %@ to Mac app project %@", sessionId, projectPath)
        refreshStatusBadge()
        refreshStartItem()
        wireOverlay?.refreshVisibility()

        // Auto-run on bind was removed. Auto-running made `mac_run` (and the
        // surrounding build/restart cycle Claude would invoke to verify a
        // fix) destructive to whatever instance the user already had open.
        // Bind is now non-destructive: adapter ready, AX-introspection +
        // screenshot tools work against whatever instance is running, but
        // nothing spawns or kills automatically. If the user wants the
        // bridge to manage the build/run cycle, they invoke `mac_run`
        // explicitly (or via the popover's Build & Run pill — kept for
        // discoverability).
    }

    /// Bind a session to an already-running macOS app, identified by bundle
    /// id. The user owns the app's lifecycle — we attach via NSWorkspace,
    /// drive via AX + CGEvent, and react to Cmd+Q via `onTerminated` (which
    /// drops the binding so the `+` reappears, mirroring Chrome / Mac App
    /// / Sim). Tools become available via the `native_*` MCP surface
    /// immediately.
    private func bindSessionToNativeApp(sessionId: String, bundleId: String) {
        guard let session = appState.registry.session(id: sessionId) else {
            NSLog("[Bridge] bindSessionToNativeApp: no session %@", sessionId)
            return
        }
        // Refuse if the requested app isn't currently running. Spawning is
        // out of scope for this adapter — that's what `mac_app_project`
        // covers. If the user wants to rebind after a quit, NSWorkspace's
        // `didLaunchApplicationNotification` would be the obvious extension
        // point; deferred until someone asks for it.
        let pid = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleId }?
            .processIdentifier
        guard pid != nil else {
            NSLog("[Bridge] bindSessionToNativeApp: %@ is not running", bundleId)
            appState.lastLaunchErrors[sessionId] = "\(bundleId) is not running. Launch the app first, then bind."
            return
        }
        // Already bound? Drop the previous binding so we don't end up with
        // two competing target adapters per session. Mirrors Mac App / Sim.
        if appState.bindings.get(sessionId: sessionId) != nil {
            unbindSession(sessionId: sessionId)
        }
        let adapter = NativeAppAdapter(bundleId: bundleId)
        adapter.onTerminated = { [weak self] in
            // User quit the app (Cmd+Q, crash, kill). Drop the binding so
            // the `+` reappears on the terminal — clicking it can re-bind
            // (re-launch is the user's job, by design).
            guard let self = self else { return }
            NSLog("[Bridge] Native app %@ terminated; unbinding session %@", bundleId, sessionId)
            self.unbindSession(sessionId: sessionId)
        }
        appState.nativeAdapters[sessionId] = adapter
        appState.bindings.bind(sessionId: sessionId, target: .nativeApp(bundleId: bundleId))
        appState.lastLaunchErrors.removeValue(forKey: sessionId)
        // Multi-window / multi-binding disambiguation: capture the bound
        // app's frontmost CGWindowID so wire/cursor anchoring picks THIS
        // window rather than "first window of the bundle id" (which would
        // collide if 2+ bindings share a bundle id, e.g. two Slack
        // workspace windows or two Notion documents).
        adapter.lockToBoundWindow()
        // Same wire-overlay anchoring as Mac App / Sim: capture the terminal
        // window now so the wire has somewhere to attach the source end.
        ensureWireOverlay()
        wireOverlay?.stickToTerminalWindowAtBindTime(forSession: session)
        NSLog("[Bridge] bound session %@ to native app %@", sessionId, bundleId)
        refreshStatusBadge()
        refreshStartItem()
        wireOverlay?.refreshVisibility()
    }

    /// Bind a session to a booted iOS Simulator. If `udid` is given, bind
    /// to that exact device (used by per-sim menu items when multiple
    /// simulators are booted). Otherwise enumerate and pick the first
    /// booted; if none, surface an inline error.
    /// Sets up the same close-target-→-unbind lifecycle as Chrome + Mac
    /// App via SimulatorAdapter.onTerminated.
    private func bindSessionToSimulator(sessionId: String, udid explicitUdid: String? = nil) async {
        guard let session = appState.registry.session(id: sessionId) else {
            NSLog("[Bridge] bindSessionToSimulator: no session %@", sessionId)
            return
        }
        let booted = await SimulatorAdapter.listBooted()
        let target: [String: Any]?
        if let explicit = explicitUdid {
            target = booted.first { ($0["udid"] as? String) == explicit }
        } else {
            target = booted.first
        }
        guard let chosen = target, let udid = chosen["udid"] as? String else {
            NSLog("[Bridge] bindSessionToSimulator: no booted simulators (or requested udid not found). Boot one in Simulator.app first.")
            appState.lastLaunchErrors[sessionId] = "No booted iOS Simulator found. Open Simulator.app and boot a device first."
            return
        }
        let name = (chosen["name"] as? String) ?? udid.prefix(8).description
        // Already bound elsewhere? Unbind first so we don't end up with two
        // competing target adapters per session.
        if appState.bindings.get(sessionId: sessionId) != nil {
            unbindSession(sessionId: sessionId)
        }
        let adapter = SimulatorAdapter(udid: udid)
        adapter.onTerminated = { [weak self] in
            guard let self = self else { return }
            NSLog("[Bridge] Simulator %@ shut down; unbinding session %@", udid, sessionId)
            self.unbindSession(sessionId: sessionId)
        }
        appState.simAdapters[sessionId] = adapter
        appState.bindings.bind(sessionId: sessionId, target: .simulator(udid: udid))
        // Multi-sim disambiguation: all sims share Simulator.app's pid, so
        // window-by-pid lookup can't tell them apart. lockToBoundWindow
        // caches the device name so targetWindowFrame matches by window
        // title (Simulator titles each window like "iPhone 15 Pro — iOS 17.5").
        Task { @MainActor in await adapter.lockToBoundWindow() }
        ensureWireOverlay()
        wireOverlay?.stickToTerminalWindowAtBindTime(forSession: session)
        NSLog("[Bridge] bound session %@ to iOS Simulator %@ (%@)", sessionId, name, udid)
        refreshStatusBadge()
        refreshStartItem()
        wireOverlay?.refreshVisibility()
    }

    /// If `session` shares a `projectPath` with any already-bound session whose
    /// target is Chrome, attach this new session to the SAME `ChromeAdapter`.
    /// New tabs in a bound terminal window inherit the project (cwd at spawn);
    /// without auto-bind they'd register but stay unbound, missing out on the
    /// inspector/run/wire affordances.
    /// Walk the process tree from `shellPid` downward; return true if any
    /// descendant's binary name contains "claude". Catches direct children
    /// (when the user runs `claude` in their shell) and grandchildren (when
    /// claude is wrapped by node / a script — Claude Code sets process.title
    /// to "claude" so it shows up that way in p_comm). Used to gate
    /// auto-bind: a shell that just sourced our zsh hook but isn't running
    /// Claude Code shouldn't be auto-bound to a sibling project's Chrome.
    ///
    /// In-process via `sysctl(KERN_PROC_ALL)` — ~1ms. Earlier subprocess
    /// version (`ps -A`) blocked the main thread for 100–500ms per call,
    /// which beach-balled on busy systems.
    private func sessionHasClaudeRunning(shellPid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        if sysctl(&mib, 4, nil, &size, nil, 0) != 0 || size == 0 { return false }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        if sysctl(&mib, 4, &procs, &size, nil, 0) != 0 { return false }

        var children: [pid_t: [pid_t]] = [:]
        var nameByPid: [pid_t: String] = [:]
        for i in 0..<procs.count {
            let pid = procs[i].kp_proc.p_pid
            let ppid = procs[i].kp_eproc.e_ppid
            // p_comm is char[MAXCOMLEN+1] (17 bytes, null-terminated).
            let name = withUnsafeBytes(of: &procs[i].kp_proc.p_comm) { raw -> String in
                let base = raw.bindMemory(to: CChar.self).baseAddress!
                return String(cString: base).lowercased()
            }
            nameByPid[pid] = name
            children[ppid, default: []].append(pid)
        }

        var stack: [pid_t] = [shellPid]
        var visited: Set<pid_t> = []
        while let p = stack.popLast() {
            if !visited.insert(p).inserted { continue }
            if let n = nameByPid[p], n.contains("claude") { return true }
            if let kids = children[p] { stack.append(contentsOf: kids) }
        }
        return false
    }

    private func autoBindToSibling(session: TerminalSession) {
        guard let projectPath = session.projectPath, !projectPath.isEmpty else { return }
        // Don't override an existing binding (e.g. registered + bound elsewhere).
        if appState.bindings.get(sessionId: session.id) != nil { return }
        // Don't auto-bind shells that aren't actively running Claude Code —
        // the hook fires in EVERY shell that sourced .zshrc, including ones
        // running unrelated foreground programs (e.g. the bridge binary
        // itself). Without this gate, those shells get phantom bindings and
        // phantom wires.
        if !sessionHasClaudeRunning(shellPid: session.pid) {
            NSLog("[Bridge] auto-bind skipped session %@: no claude descendant of pid %d",
                  session.id, session.pid)
            return
        }
        for (otherSessionId, binding) in appState.bindings.bindings {
            guard otherSessionId != session.id,
                  case .chrome = binding.target,
                  let other = appState.registry.session(id: otherSessionId),
                  other.projectPath == projectPath,
                  let adapter = appState.chromeAdapters[otherSessionId] else { continue }
            appState.chromeAdapters[session.id] = adapter
            appState.bindings.bind(sessionId: session.id, target: binding.target)
            if let info = appState.projectInfos[otherSessionId] {
                appState.projectInfos[session.id] = info
            }
            // Register sibling with live-reloader so its session-id resolves
            // to the right adapter even after the original binder unbinds.
            // start() dedupes per projectPath, so this is a no-op for the
            // watcher itself but keeps the session→path mapping live.
            liveReloader.start(sessionId: session.id, projectPath: projectPath)
            // Pre-seed wire overlay sticky cache so the wire anchors correctly
            // (Apple Terminal tabs share a window, so the same window-id is the
            // right answer for both — but in case sibling is in a different
            // window, this captures the correct one for THIS session).
            wireOverlay?.stickToTerminalWindowAtBindTime(forSession: session)
            wireOverlay?.refreshVisibility()
            NSLog("[Bridge] Auto-bound session %@ to sibling %@ (project=%@)",
                  session.id, otherSessionId, projectPath)
            return
        }
    }

    /// Called from `bindSessionToChrome` after a successful bind to vacuum up any
    /// other un-bound sessions for the same project — covers the case where the
    /// siblings registered BEFORE the user clicked Bind.
    private func autoBindSiblingsAfterBind(sourceSessionId: String, projectPath: String?, adapter: ChromeAdapter, target: Target) {
        guard let projectPath = projectPath, !projectPath.isEmpty else { return }
        for sibling in appState.registry.sessions {
            if sibling.id == sourceSessionId { continue }
            if sibling.projectPath != projectPath { continue }
            if appState.bindings.get(sessionId: sibling.id) != nil { continue }
            // Same Claude-running gate as autoBindToSibling. Bridge binary's
            // own shell should not get swept up as a sibling.
            if !sessionHasClaudeRunning(shellPid: sibling.pid) {
                NSLog("[Bridge] auto-bind sweep skipped session %@: no claude descendant of pid %d",
                      sibling.id, sibling.pid)
                continue
            }
            appState.chromeAdapters[sibling.id] = adapter
            appState.bindings.bind(sessionId: sibling.id, target: target)
            if let info = appState.projectInfos[sourceSessionId] {
                appState.projectInfos[sibling.id] = info
            }
            liveReloader.start(sessionId: sibling.id, projectPath: projectPath)
            wireOverlay?.stickToTerminalWindowAtBindTime(forSession: sibling)
            NSLog("[Bridge] Auto-bound sibling %@ on bind (project=%@)", sibling.id, projectPath)
        }
        wireOverlay?.refreshVisibility()
    }

    /// Compute where Chrome should appear at first launch — opposite side of
    /// the user's bound terminal window, anchored to the far edge of the screen.
    /// Returned frame is in CG coords (top-left origin) and gets fed to Chrome
    /// as `--window-position` + `--window-size` so there's no jump from
    /// default-launch-position → AX-snapped-position. Returns nil if the
    /// terminal window can't be located (rare — e.g. session has no AX-readable
    /// window yet); caller falls back to the default 1024x768 launch.
    private func computeChromeLaunchFrame(forSessionId sessionId: String) -> CGRect? {
        guard let session = appState.registry.session(id: sessionId) else { return nil }
        let terminalPid = resolvedTerminalAppPidForSession(session)
        let cachedTermWid = wireOverlay?.boundTerminalWindowId(for: sessionId)
        guard let termAx = Self.axWindow(forPid: terminalPid, matchingCGWindowID: cachedTermWid),
              let termFrame = Self.axFrame(of: termAx) else { return nil }

        let target = Self.screen(containingCGPoint: CGPoint(x: termFrame.midX, y: termFrame.midY))
            ?? NSScreen.screens.first
        guard let screen = target else { return nil }
        let visible = Self.visibleFrameCG(screen)
        let termOnLeft = termFrame.midX < visible.midX
        let minChromeWidth: CGFloat = 360

        // Available width on the OPPOSITE side of the terminal.
        let availOpposite: CGFloat
        if termOnLeft {
            availOpposite = visible.maxX - (termFrame.minX + termFrame.width)
        } else {
            availOpposite = termFrame.minX - visible.minX
        }

        // Chrome takes whatever's available on the opposite side, with a sane
        // minimum. If even the minimum doesn't fit (terminal hogging > visible
        // − minChromeWidth), fall back to half-screen — the post-launch
        // `arrangeWindowsSideBySide` then shrinks the terminal too.
        let chromeW = availOpposite >= minChromeWidth ? availOpposite : visible.width / 2
        let chromeH = visible.height
        let chromeX = termOnLeft ? (visible.maxX - chromeW) : visible.minX
        let chromeY = visible.minY

        return CGRect(x: chromeX, y: chromeY, width: chromeW, height: chromeH)
    }

    /// Arrange the bound terminal + Chrome side-by-side, preserving the
    /// terminal's current side relative to screen center and ONLY resizing
    /// when their combined widths would overflow. The goal is "side by side,"
    /// not "always halve" — if they already fit at their current widths, just
    /// position them, leave sizes alone.
    ///
    /// Side: terminal stays on whichever half of `visibleFrame` its midX is on.
    /// Chrome takes the opposite side. Anchoring: each window pulls to the far
    /// edge of its half.
    /// Resizing: if `term.width + chrome.width <= visible.width`, no resize. Else
    /// shrink chrome to fit while keeping terminal; if that pushes chrome below
    /// `minWindowWidth`, fall back to even halves so neither becomes unusable.
    private func arrangeWindowsSideBySide(sessionId: String) {
        guard let session = appState.registry.session(id: sessionId),
              let adapter = appState.chromeAdapters[sessionId],
              let chromePid = adapter.chromeProcessPid else { return }

        let terminalPid = resolvedTerminalAppPidForSession(session)
        let cachedTermWid = wireOverlay?.boundTerminalWindowId(for: sessionId)
        guard let termAx = Self.axWindow(forPid: terminalPid, matchingCGWindowID: cachedTermWid),
              let chromeAx = Self.axWindow(forPid: chromePid, matchingCGWindowID: nil)
        else {
            NSLog("[Bridge] arrange: missing AX window (terminal=%d, chrome=%d)", terminalPid, chromePid)
            return
        }
        guard let termFrame = Self.axFrame(of: termAx),
              let chromeFrame = Self.axFrame(of: chromeAx) else { return }

        // Target screen: the one the TERMINAL is on (it's the user's anchor —
        // Chrome is the new window we just opened, easier to bring to terminal
        // than the other way around).
        let termCenter = CGPoint(x: termFrame.midX, y: termFrame.midY)
        let target = Self.screen(containingCGPoint: termCenter)
            ?? Self.screen(containingCGPoint: CGPoint(x: chromeFrame.midX, y: chromeFrame.midY))
            ?? NSScreen.screens.first
        guard let screen = target else { return }
        let visible = Self.visibleFrameCG(screen)

        // Side preservation: terminal's current midX vs screen midX.
        let termOnLeft = termFrame.midX < visible.midX

        // Early-out: if both windows already fit side-by-side (no horizontal
        // overlap, both within visible frame, terminal on its preferred side),
        // there's nothing to do — moving them would just be visual jitter.
        let withinVisible: (CGRect) -> Bool = { f in
            f.minX >= visible.minX - 1 && f.maxX <= visible.maxX + 1 &&
            f.minY >= visible.minY - 1 && f.maxY <= visible.maxY + 1
        }
        let horizontallyDisjoint = termFrame.maxX <= chromeFrame.minX + 1 || chromeFrame.maxX <= termFrame.minX + 1
        if withinVisible(termFrame) && withinVisible(chromeFrame) && horizontallyDisjoint {
            NSLog("[Bridge] arrange: skipped — windows already fit side-by-side")
            return
        }

        // Compute target widths — keep current unless they don't fit together.
        let minWidth: CGFloat = 360
        let combined = termFrame.width + chromeFrame.width
        var termW = termFrame.width
        var chromeW = chromeFrame.width
        if combined > visible.width {
            // Try to keep terminal width; shrink chrome.
            let chromeIfTermKept = visible.width - termW
            if chromeIfTermKept >= minWidth {
                chromeW = chromeIfTermKept
            } else {
                // Terminal too wide for chrome to fit alongside. Halve both.
                termW = visible.width / 2
                chromeW = visible.width / 2
            }
        }
        // Cap each at half just in case (e.g., a single window is wider than
        // the whole screen — rare but possible after a screen change).
        termW = min(termW, visible.width)
        chromeW = min(chromeW, visible.width)

        // Heights: clamp to visibleFrame.
        let termH = min(termFrame.height, visible.height)
        let chromeH = min(chromeFrame.height, visible.height)

        // Vertical position: keep current Y if it fits within visibleFrame,
        // otherwise pull into bounds.
        let termY = max(visible.minY, min(termFrame.minY, visible.maxY - termH))
        let chromeY = max(visible.minY, min(chromeFrame.minY, visible.maxY - chromeH))

        // Horizontal anchors: terminal on its side, chrome on the opposite.
        let termX: CGFloat
        let chromeX: CGFloat
        if termOnLeft {
            termX = visible.minX
            chromeX = visible.maxX - chromeW
        } else {
            termX = visible.maxX - termW
            chromeX = visible.minX
        }

        Self.setAxFrame(CGRect(x: termX, y: termY, width: termW, height: termH), on: termAx)
        Self.setAxFrame(CGRect(x: chromeX, y: chromeY, width: chromeW, height: chromeH), on: chromeAx)
        NSLog("[Bridge] arranged: terminal %@ stays on %@ (resized=%@); chrome on %@ (resized=%@)",
              session.id,
              termOnLeft ? "left" : "right",
              termW != termFrame.width ? "yes" : "no",
              termOnLeft ? "right" : "left",
              chromeW != chromeFrame.width ? "yes" : "no")
    }

    /// Walk the shell PID's parent chain looking for a recognised terminal app.
    /// Mirrors WireOverlayController.resolvedTerminalAppPid; duplicated rather
    /// than exposed as a static helper to keep that file self-contained.
    private func resolvedTerminalAppPidForSession(_ session: TerminalSession) -> pid_t {
        var pid: pid_t = pid_t(session.pid)
        for _ in 0..<8 {
            if let app = NSRunningApplication(processIdentifier: pid),
               let bid = app.bundleIdentifier,
               TextInjection.isTerminalApp(bundleId: bid) {
                return pid
            }
            let parent = parentPID(of: pid)
            if parent <= 1 { break }
            pid = parent
        }
        return pid_t(session.pid)
    }

    // MARK: - AX window helpers

    /// Find the AX window for `pid`. If `matchingCGWindowID` is non-nil, walks
    /// the app's windows and uses `_AXUIElementGetWindow` to pick the one whose
    /// CGWindowID matches. Otherwise returns the first window.
    private static func axWindow(forPid pid: pid_t, matchingCGWindowID target: CGWindowID?) -> AXUIElement? {
        let appRef = AXUIElementCreateApplication(pid)
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement], !windows.isEmpty else { return nil }
        guard let target = target else { return windows.first }
        for window in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(window, &wid) == .success, wid == target {
                return window
            }
        }
        return windows.first
    }

    private static func axFrame(of axWindow: AXUIElement) -> CGRect? {
        AXSafety.frame(of: axWindow)
    }

    private static func setAxFrame(_ frame: CGRect, on axWindow: AXUIElement) {
        var pos = frame.origin
        var size = frame.size
        if let posValue = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    /// Find the NSScreen whose frame (in CG coords, top-left origin) contains a
    /// point. CGWindowList frames are in CG coords; NSScreen.frame is in NS
    /// coords (bottom-left origin), so we flip here.
    private static func screen(containingCGPoint cg: CGPoint) -> NSScreen? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens {
            let nsFrame = screen.frame
            // Convert NS frame to CG frame
            let cgY = primaryHeight - nsFrame.maxY
            let cgFrame = CGRect(x: nsFrame.minX, y: cgY, width: nsFrame.width, height: nsFrame.height)
            if cgFrame.contains(cg) { return screen }
        }
        return nil
    }

    /// Visible frame of `screen` (excluding menu bar + dock) in CG coords
    /// (top-left origin), with the NSScreen → CG y-flip applied.
    private static func visibleFrameCG(_ screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let v = screen.visibleFrame
        let cgY = primaryHeight - v.maxY
        return CGRect(x: v.minX, y: cgY, width: v.width, height: v.height)
    }

    /// Lazily initialise the wire-overlay controller and ask it to refresh
    /// (bind = show, unbind = hide). Called from bind + unbind paths.
    private func ensureWireOverlay() {
        if wireOverlay == nil {
            wireOverlay = WireOverlayController(appState: appState)
            wireOverlay?.setVisualTheme(visualTheme)
        }
        wireOverlay?.refreshVisibility()
    }

    /// Inject a shell command into the bound terminal — used by the popover's
    /// "Start <dev command>" affordance. Looks up the session's bound terminal
    /// window id from the wire overlay's sticky cache so the paste lands in the
    /// SPECIFIC window the user bound, not whatever sibling window of the app
    /// is currently key-focused. After injecting, auto-detects whichever port
    /// the dev server starts listening on and navigates the bound Chrome there.
    private func runCommandInSession(sessionId: String, command: String) {
        guard let session = appState.registry.session(id: sessionId) else { return }
        let targetWindow = wireOverlay?.boundTerminalWindowId(for: sessionId)
        // Snapshot listening ports BEFORE the command runs so we can diff for
        // the new one afterwards. Caller-side capture so it's truly "before."
        let baseline = Self.listeningTCPPorts()
        Task {
            await TextInjection.send(command, to: session, pressReturn: true, targetWindowId: targetWindow)
            await Self.autoNavigateToDevServer(sessionId: sessionId, appState: appState, baseline: baseline)
        }
    }

    /// Diff `lsof -iTCP -sTCP:LISTEN` against a baseline taken before the run
    /// command fired. Any port that wasn't there before AND now serves HTTP is
    /// the new dev server — works regardless of which port the user configured.
    /// Falls back to a curated common-port list if `lsof` returned nothing
    /// (rare — would mean the binary isn't available or the user has no
    /// listeners at all, in which case the diff is the same set as common).
    private static func autoNavigateToDevServer(sessionId: String, appState: BridgeAppState, baseline: Set<Int>) async {
        guard let adapter = appState.chromeAdapters[sessionId] else { return }
        let pollDelays: [TimeInterval] = [1.0, 1.0, 2.0, 2.0, 3.0, 3.0, 3.0]   // total ~15s
        let commonPorts: [Int] = [3000, 5173, 8080, 4321, 4000, 8000, 3001]
        var elapsed: TimeInterval = 0
        for delay in pollDelays {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            elapsed += delay
            let nowListening = Self.listeningTCPPorts()
            let newPorts = nowListening.subtracting(baseline).sorted()
            // Try newly-appeared ports first (any port the dev server picked,
            // including custom ones). Fall back to common ports if the diff is
            // empty (e.g. lsof failed silently).
            let candidates = newPorts.isEmpty ? commonPorts : newPorts
            for port in candidates {
                if await isPortServingHTTP(port) {
                    NSLog("[Bridge] Auto-nav: dev server up on :%d after %.1fs (newly-listening: %@)",
                          port, elapsed, newPorts.isEmpty ? "fallback" : "yes")
                    try? await adapter.navigate(to: "http://localhost:\(port)")
                    // Remember the running port so the menu-bar Start button can
                    // hide itself while the server is alive.
                    appState.runningDevServerPorts[sessionId] = port
                    return
                }
            }
        }
        NSLog("[Bridge] Auto-nav: no dev server detected within %.1fs", elapsed)
    }

    /// Snapshot of TCP ports that are currently in LISTEN state for our user.
    /// `lsof -nP -iTCP -sTCP:LISTEN` runs in ~50–150ms typically. Output looks
    /// like `node 12345 user 20u IPv6 ... TCP *:3000 (LISTEN)` — we grab the
    /// `:NNNN (LISTEN)` group.
    private static func listeningTCPPorts() -> Set<Int> {
        guard let result = try? BridgeProcessCapture.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN"],
            timeout: 5,
            stdoutLimit: 4 * 1024 * 1024,
            stderrLimit: 1_048_576) else {
            return []
        }
        let output = String(decoding: result.stdout, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#) else { return [] }
        var ports = Set<Int>()
        for line in output.split(separator: "\n") {
            let str = String(line)
            let range = NSRange(str.startIndex..<str.endIndex, in: str)
            if let match = regex.firstMatch(in: str, range: range),
               match.numberOfRanges >= 2,
               let portRange = Range(match.range(at: 1), in: str),
               let port = Int(str[portRange]) {
                ports.insert(port)
            }
        }
        return ports
    }

    private static func isPortServingHTTP(_ port: Int) async -> Bool {
        guard let url = URL(string: "http://localhost:\(port)/") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 1.0
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }

    /// Re-launch the Chrome window for a session whose previous Chrome was
    /// closed. Reuses the SAME profile dir (cookies/storage preserved) and
    /// restores the last URL via `ChromeAdapter.relaunch(newCdpPort:)`.
    private func reopenSession(sessionId: String) {
        guard let adapter = appState.chromeAdapters[sessionId] else { return }
        let newPort = appState.nextCdpPort
        appState.nextCdpPort += 1
        Task {
            do {
                try await adapter.relaunch(newCdpPort: newPort)
                // Re-enable inspector ONLY if it was on before the disconnect —
                // adapter.inspectorEnabled persists across the dead-window window.
                if adapter.inspectorEnabled, let port = appState.httpServer?.port {
                    await adapter.enableInspector(
                        sessionId: sessionId,
                        httpPort: port,
                        authenticationToken: browserAuthenticationToken)
                }
                appState.objectWillChange.send()
                wireOverlay?.refreshVisibility()
            } catch {
                NSLog("[Bridge] Reopen failed for session %@ on port %d: %@",
                      sessionId, newPort, error.localizedDescription)
                appState.lastLaunchErrors[sessionId] = "Reopen failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Global hotkey

    private func installHotkey() {
        // ⌘⇧B — text selection from the frontmost app, with pasteboard
        // fallback when AX is silent.
        let textManager = HotkeyManager()
        textManager.register(keyCode: 11, modifiers: [.command, .shift]) { [weak self] in
            // 11 = "B" virtual keycode → ⌘⇧B
            self?.openOverlay()
        }
        hotkey = textManager

        // ⌘⇧S — region picker via the system `screencapture -i -c`. Bypasses
        // selection capture entirely; useful for Electron apps where AX +
        // pasteboard both come back empty, plus general "grab a region of
        // the screen" intent.
        let regionManager = HotkeyManager()
        regionManager.register(keyCode: 1, modifiers: [.command, .shift]) { [weak self] in
            // 1 = "S" virtual keycode → ⌘⇧S
            self?.openRegionPicker()
        }
        regionHotkey = regionManager
    }

    private func openOverlay() {
        ensureOverlay()
        overlay?.show()
    }

    /// Run the system region picker, then hand the captured PNG off to the
    /// overlay's session picker. Wired to ⌘⇧S and to the inline "capture a
    /// region instead?" hint shown when ⌘⇧B comes back empty.
    private func openRegionPicker() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // If the overlay is already up (e.g. user hit ⌘⇧B then clicked
            // the fallback hint), hide it so its panel doesn't end up under
            // the screencapture crosshair.
            self.overlay?.hide()
            guard let png = await RegionCapture.captureToPasteboard() else {
                NSLog("[Bridge] openRegionPicker: cancelled / no image captured")
                return
            }
            let dims = NSImage(data: png)?.bridge_pixelSize()
            self.ensureOverlay()
            self.overlay?.showWithImage(png, dimensions: dims)
        }
    }

    private func ensureOverlay() {
        if overlay == nil {
            let oc = OverlayController(appState: appState)
            // Wire the inline fallback hint's "⌘⇧S" button so it shares the
            // same code path as the global hotkey.
            oc.onCaptureRegion = { [weak self] in self?.openRegionPicker() }
            overlay = oc
        }
    }
}
