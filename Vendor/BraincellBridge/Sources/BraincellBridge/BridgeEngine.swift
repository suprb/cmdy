import AppKit
import Darwin

/// Public entry point for running the Bridge engine inside cmdy. It supplies
/// single-instance defense, orphan-Chrome cleanup, and the full
/// BridgeAppDelegate boot (status item, popover, HTTP server
/// on 3457, MCP runtime, adapters, stream proxy).
@MainActor
public final class BridgeEngine {
    public static let shared = BridgeEngine()

    private var delegate: BridgeAppDelegate?
    private var visualTheme = BridgeVisualTheme.fallback
    private var feedbackHandler: ((String, [String: Any]) -> Void)?
    public private(set) var running = false

    /// Bearer credential for first-party clients hosted in the same process.
    /// It changes on every engine launch and is never replaced by a fixed
    /// development fallback.
    public var authenticationToken: String? {
        delegate?.authenticationToken
    }

    private init() {}

    /// Boot the engine in-process. `hostOwnsCaptureHotkeys: true` skips the
    /// engine's own ⌘⇧B/⌘⇧S registration (the host provides capture UX).
    public func start(hostOwnsCaptureHotkeys: Bool = true) {
        guard !running else { return }
        running = true

        // Single-instance: a standalone bridge would fight for port 3457,
        // the menu-bar item, and the orphan-defense timers. Take over.
        let pidURL = URL(fileURLWithPath: "/tmp/braincell-bridge.pid")
        if let oldPid = BridgePIDFile.previousPID(
            at: pidURL, excluding: getpid()
        ) {
            if kill(oldPid, 0) == 0 {
                kill(oldPid, SIGTERM)
                Thread.sleep(forTimeInterval: 0.4)
                if kill(oldPid, 0) == 0 { kill(oldPid, SIGKILL) }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        BridgePIDFile.writeCurrentPID(getpid(), to: pidURL)

        // Orphan Chrome processes from previous runs hold the profile-dir
        // lock + CDP port; a fresh bind would silently piggyback. Clear them.
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-f", "braincell-bridge-chrome-"]
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        try? killer.run()
        killer.waitUntilExit()

        let bridgeDelegate = BridgeAppDelegate()
        bridgeDelegate.embeddedInHost = hostOwnsCaptureHotkeys
        bridgeDelegate.onFeedback = { [weak self] sessionId, record in
            self?.feedbackHandler?(sessionId, record)
        }
        bridgeDelegate.applyVisualTheme(visualTheme)
        delegate = bridgeDelegate
        bridgeDelegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification))
        NSLog("[Bridge] engine embedded in host (pid %d)", getpid())
    }

    /// Target kinds a host can bind a session to from its own UI.
    public enum BindKind {
        case chrome
        case macAppProject(path: String)
        case simulator(udid: String)
        case nativeApp(bundleId: String)
    }

    /// Bind an engine session (a cmdy pane, registered via /sessions) to a
    /// target — the same path the popover's bind buttons take. The engine
    /// launches/attaches the target, draws the bind node + wire overlay, and
    /// routes the session's MCP tools there.
    public func bind(sessionId: String, to kind: BindKind) {
        guard running else { return }
        let target: Target
        switch kind {
        case .chrome: target = .chrome(profileDir: "", cdpPort: 0)
        case .macAppProject(let path): target = .macAppProject(projectPath: path)
        case .simulator(let udid): target = .simulator(udid: udid)
        case .nativeApp(let bundleId): target = .nativeApp(bundleId: bundleId)
        }
        NotificationCenter.default.post(
            name: .bridgeBindRequested, object: nil,
            userInfo: ["sessionId": sessionId, "target": target])
    }

    /// Show the engine's menu-bar popover (the full session/bind/target UI).
    public func presentPopover() {
        delegate?.presentPopoverPublic()
    }

    /// Receive semantic feedback captured by a bound surface. An embedded host
    /// uses this to route the record to the exact pane/agent that owns the
    /// Bridge session. Standalone Bridge falls back to text injection.
    public func onFeedback(_ handler: ((String, [String: Any]) -> Void)?) {
        feedbackHandler = handler
    }

    /// Begin target-aware semantic selection for a Bridge session. Chrome uses
    /// its live DOM inspector. Other targets open the accessibility/region
    /// picker owned by the bridge delegate.
    public func beginFeedback(sessionId: String) {
        delegate?.beginFeedbackPublic(sessionId: sessionId)
    }

    /// Match Bridge's edge button and connection wire to the host terminal.
    /// The cursor color is the interaction accent; background/foreground retain
    /// the same contrast relationship as the terminal grid.
    public func setVisualTheme(backgroundHex: String, foregroundHex: String,
                               cursorHex: String, borderHex: String) {
        let theme = BridgeVisualTheme(
            backgroundHex: backgroundHex,
            foregroundHex: foregroundHex,
            accentHex: cursorHex,
            borderHex: borderHex
        )
        guard theme != visualTheme else { return }
        visualTheme = theme
        delegate?.applyVisualTheme(theme)
    }

    public func stop() {
        guard running, let bridgeDelegate = delegate else { return }
        bridgeDelegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification))
        delegate = nil
        feedbackHandler = nil
        running = false
        try? FileManager.default.removeItem(atPath: "/tmp/braincell-bridge.pid")
        try? FileManager.default.removeItem(atPath: HTTPServer.portFilePath)
        try? FileManager.default.removeItem(atPath: HTTPServer.tokenFilePath)
    }
}
