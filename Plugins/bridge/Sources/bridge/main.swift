import AppKit
import CmdySDK
import BraincellBridgeKit

// Bridge — the braincell engine (MCP runtime + Chrome/Mac/iOS/native adapters,
// 93 tools, port 3457) as an EXTERNAL cmdy plugin. cmdy launches this
// process; the engine and its menu-bar UI live here, and every cmdy-side
// interaction (commands, pane registration, status) goes through the public
// SDK — proof that Bridge-scale plugins need no private hooks.

@MainActor
final class BridgeApp: NSObject, NSApplicationDelegate {
    let cmdy: Cmdy
    /// cmdy pane id → engine session id.
    var engineSessions: [String: String] = [:]
    var engineAvailable = false
    var pendingPaneIds: Set<String> = []
    var retryWorkItem: DispatchWorkItem?
    var sigTermSource: DispatchSourceSignal?
    var offeredAgent = false

    var enginePort: Int {
        let portFile = URL(fileURLWithPath: "/tmp/braincell-bridge.port")
        if let values = try? portFile.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
           values.isRegularFile == true, values.isSymbolicLink != true,
           let size = values.fileSize, size <= 1_024,
           let s = try? String(contentsOf: portFile, encoding: .utf8),
           let p = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)),
           (1...65_535).contains(p) {
            return p
        }
        if let port = Int(
            ProcessInfo.processInfo.environment["BRIDGE_ENGINE_PORT"] ?? ""),
           (1...65_535).contains(port) {
            return port
        }
        return 3457
    }

    init(cmdy: Cmdy) {
        self.cmdy = cmdy
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        cmdy.registerCommand(id: "bridge.status", title: "Bridge: Engine Status", plugin: "Bridge")
        cmdy.registerCommand(id: "bridge.panel", title: "Bridge: Open Bridge Panel (sessions & targets)", plugin: "Bridge")
        cmdy.registerCommand(id: "bridge.bind-chrome", title: "Bridge: Bind This Pane → Chrome", plugin: "Bridge")
        cmdy.registerCommand(id: "bridge.bind-macapp", title: "Bridge: Bind This Pane → Mac App (this project)", plugin: "Bridge")
        cmdy.registerCommand(id: "bridge.annotate", title: "Bridge: Add UI Feedback", plugin: "Bridge")
        cmdy.onEvent = { [weak self] event in self?.handle(event) }
        cmdy.listen()

        // cmdy toggles/quits us with SIGTERM; without catching it the
        // default disposition kills us instantly and applicationWillTerminate
        // never runs — so the engine (and any Chrome/Mac/iOS helpers it spawned)
        // orphans. Ignore + drain to a clean NSApp.terminate, like the sibling
        // plugins (swarm/sim/chromium). onParentExit covers the crash path.
        signal(SIGTERM, SIG_IGN)
        let sig = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sig.setEventHandler { NSApp.terminate(nil) }
        sig.resume()
        sigTermSource = sig
        cmdy.onParentExit = { NSApp.terminate(nil) }

        MainActor.assumeIsolated {
            BridgeEngine.shared.start(hostOwnsCaptureHotkeys: false)
            BridgeEngine.shared.onFeedback { [weak self] sessionId, record in
                self?.routeFeedback(sessionId: sessionId, payload: record)
            }
        }
        syncTheme()

        scheduleSyncRetry(attempt: 0)
    }

    func applicationWillTerminate(_ notification: Notification) {
        for sessionId in engineSessions.values {
            engineRequest("DELETE", "/sessions/\(sessionId)", nil) { _ in }
        }
        MainActor.assumeIsolated { BridgeEngine.shared.stop() }
    }

    // MARK: - cmdy events

    func handle(_ event: [String: Any]) {
        switch event["kind"] as? String {
        case "command":
            switch event["id"] as? String {
            case "bridge.status": showStatus()
            case "bridge.panel":
                MainActor.assumeIsolated { BridgeEngine.shared.presentPopover() }
                offerAgentIfNeeded()
            case "bridge.bind-chrome":
                bindFocused(.chrome)
                offerAgentIfNeeded()
            case "bridge.bind-macapp":
                cmdy.focusedPane { [weak self] pane in
                    guard let cwd = pane?["cwd"] as? String, !cwd.isEmpty else { NSSound.beep(); return }
                    self?.bindFocused(.macAppProject(path: cwd))
                }
                offerAgentIfNeeded()
            case "bridge.annotate": beginFeedback()
            default: break
            }
        case "pane-opened", "pane-updated", "command-finished":
            sync()
        case "pane-closed":
            if let paneId = event["pane"] as? String, let sessionId = engineSessions[paneId] {
                engineRequest("DELETE", "/sessions/\(sessionId)", nil) { _ in }
                engineSessions[paneId] = nil
            }
            sync()
        case "theme-changed":
            if let theme = CmdyTheme(payload: event) { apply(theme: theme) }
        default:
            break
        }
    }

    private func offerAgentIfNeeded() {
        guard !offeredAgent else { return }
        offeredAgent = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.cmdy.offerAgentAttach()
        }
    }

    private func beginFeedback() {
        cmdy.focusedPane { [weak self] pane in
            guard let self, let pane, let paneId = pane["id"] as? String else {
                NSSound.beep()
                return
            }
            guard let sessionId = self.engineSessions[paneId] else {
                self.cmdy.notify(title: "Bridge", body: "This pane is still connecting to Bridge. Try again in a moment.")
                return
            }
            BridgeEngine.shared.beginFeedback(sessionId: sessionId)
        }
    }

    private func routeFeedback(sessionId: String, payload: [String: Any]) {
        guard let paneId = engineSessions.first(where: { $0.value == sessionId })?.key else {
            cmdy.submitFeedback(payload)
            return
        }
        cmdy.panes { [weak self] panes in
            guard let self else { return }
            let pane = panes.first { ($0["id"] as? String) == paneId }
            let window: CGWindowID?
            if let number = pane?["windowNumber"] as? NSNumber {
                window = CGWindowID(number.uint32Value)
            } else if let number = pane?["windowNumber"] as? Int, number > 0 {
                window = CGWindowID(number)
            } else {
                window = nil
            }
            self.cmdy.submitFeedback(payload, windowNumber: window)
        }
    }

    private func syncTheme() {
        cmdy.theme { [weak self] theme in
            guard let self, let theme else { return }
            self.apply(theme: theme)
        }
    }

    private func apply(theme: CmdyTheme) {
        BridgeEngine.shared.setVisualTheme(
            backgroundHex: theme.background,
            foregroundHex: theme.foreground,
            cursorHex: theme.cursor,
            borderHex: theme.border
        )
    }

    // MARK: - Pane ↔ engine reconcile (over the public SDK)

    func sync() {
        engineRequest("GET", "/health", nil) { [weak self] health in
            guard let self else { return }
            let up = health != nil
            if up != self.engineAvailable {
                self.engineAvailable = up
                NSLog("bridge: engine %@ (port %d)", up ? "connected" : "offline", self.enginePort)
                if !up { self.engineSessions.removeAll() }
            }
            guard up else { self.scheduleSyncRetry(attempt: 0); return }
            self.retryWorkItem?.cancel()
            self.retryWorkItem = nil
            self.cmdy.panes { panes in self.reconcile(panes) }
        }
    }

    func scheduleSyncRetry(attempt: Int) {
        guard retryWorkItem == nil, attempt < 8 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWorkItem = nil
            self.engineRequest("GET", "/health", nil) { health in
                if health != nil { self.sync() }
                else { self.scheduleSyncRetry(attempt: attempt + 1) }
            }
        }
        retryWorkItem = work
        let delay = min(4.0, 0.2 * pow(1.8, Double(attempt)))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func sessionBody(for pane: [String: Any]) -> [String: Any]? {
        guard let tty = pane["tty"] as? String, !tty.isEmpty,
              let windowId = pane["windowNumber"] as? Int, windowId > 0 else { return nil }
        return [
            "pid": pane["pid"] as? Int ?? 0,
            "tty": tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)",
            "terminalApp": HostProductIdentity.slug,
            "windowId": windowId,
            "paneId": pane["id"] as? String ?? "",
            "paneFocused": pane["focused"] as? Bool ?? false,
            "windowTitle": pane["window"] as? String ?? pane["title"] as? String ?? "",
            "projectPath": pane["cwd"] as? String ?? "",
        ]
    }

    func reconcile(_ panes: [[String: Any]]) {
        for pane in panes {
            guard let id = pane["id"] as? String,
                  let body = sessionBody(for: pane) else { continue }
            if let sessionId = engineSessions[id] {
                engineRequest("PATCH", "/sessions/\(sessionId)", body) { _ in }
                continue
            }
            guard !pendingPaneIds.contains(id) else { continue }
            pendingPaneIds.insert(id)
            engineRequest("POST", "/sessions", body) { [weak self] reply in
                self?.pendingPaneIds.remove(id)
                if let sessionId = reply?["id"] as? String {
                    self?.engineSessions[id] = sessionId
                }
            }
        }
        let liveIds = Set(panes.compactMap { $0["id"] as? String })
        for (paneId, sessionId) in engineSessions where !liveIds.contains(paneId) {
            engineRequest("DELETE", "/sessions/\(sessionId)", nil) { _ in }
            engineSessions[paneId] = nil
        }
    }

    func bindFocused(_ kind: BridgeEngine.BindKind) {
        cmdy.focusedPane { [weak self] pane in
            guard let self, let pane, let paneId = pane["id"] as? String else { NSSound.beep(); return }
            if let sessionId = self.engineSessions[paneId] {
                MainActor.assumeIsolated { BridgeEngine.shared.bind(sessionId: sessionId, to: kind) }
                return
            }
            guard let body = self.sessionBody(for: pane) else {
                self.cmdy.notify(title: "Bridge", body: "Couldn't identify this pane's tty yet — try again in a moment.")
                return
            }
            self.engineRequest("POST", "/sessions", body) { reply in
                guard let sessionId = reply?["id"] as? String else { return }
                self.engineSessions[paneId] = sessionId
                BridgeEngine.shared.bind(sessionId: sessionId, to: kind)
            }
        }
    }

    func showStatus() {
        let count = engineSessions.count
        let status = engineAvailable
            ? "Engine connected on port \(enginePort) — \(count) pane\(count == 1 ? "" : "s") registered."
            : "Engine offline (port \(enginePort))."
        cmdy.openPanel([
            "mode": "text",
            "title": "✦ Bridge",
            "body": status + "\n\nRunning as an external plugin (pid \(ProcessInfo.processInfo.processIdentifier)) — built on the public SDK.",
            "hint": "esc close",
        ])
    }

    func engineRequest(_ method: String, _ path: String, _ body: [String: Any]?,
                       completion: @escaping ([String: Any]?) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(enginePort)\(path)") else { completion(nil); return }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 2
        if path != "/health" {
            guard let token = BridgeEngine.shared.authenticationToken else {
                completion(nil)
                return
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        Task { @MainActor in
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                completion(nil)
                return
            }
            let result = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            completion(result)
        }
    }
}

guard let cmdy = Cmdy() else {
    FileHandle.standardError.write(Data(
        ("bridge: not launched by \(HostProductIdentity.name) "
            + "(missing \(HostProductIdentity.environmentPrefix)_PORT/TOKEN)\n").utf8))
    exit(1)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar item only (the engine's popover)
let delegate = MainActor.assumeIsolated { BridgeApp(cmdy: cmdy) }
app.delegate = delegate
app.run()
