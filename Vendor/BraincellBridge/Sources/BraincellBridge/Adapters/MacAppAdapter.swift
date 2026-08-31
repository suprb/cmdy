import Foundation
import AppKit
import ApplicationServices
import ScreenCaptureKit
import CoreGraphics
import Carbon.HIToolbox

/// Owns the build/run/observe/drive loop for a macOS app project.
/// First non-Chrome adapter — proves the multi-target abstraction.
///
/// Lifecycle: bind a session to a `projectPath` (Swift Package or Xcode
/// project root); the adapter exposes tools to build it, launch the
/// resulting binary, screenshot/inspect the running app via AX, click
/// and type, tail console output, and stop.
///
/// V1 supports `swift build` only. Xcode project (`xcodebuild`) support
/// is deferred — auto-detection logic isn't worth the complexity until
/// users ask for it.
///
/// Like `ChromeAdapter`, this owns its launched Process. When the user
/// quits the app (Cmd+Q, crash, parent kill), `onTerminated` fires so
/// the UI / wire layer can react. The binding stays alive through that
/// transition so the user can hit "Run again" without re-binding.
@MainActor
final class MacAppAdapter: TargetAdapter {
    private static let maxAXNodes = 20_000
    private static let maxAXResults = 5_000
    private static let maxAXContentCharacters = 2 * 1024 * 1024

    /// TargetAdapter conformance: anchor visuals + wire to the spawned app.
    var anchorPid: pid_t? { runningPid }

    /// TargetAdapter conformance: alias for `targetWindowFrame()`.
    func windowFrame() -> CGRect? { targetWindowFrame() }

    /// TargetAdapter conformance: stop the spawned app + drop console pipes.
    /// Async wrapper around the existing throwing `stop()` — protocol
    /// signature can't throw, and "we're being unbound, just clean up
    /// best-effort" is the right semantic here.
    func shutdown() async {
        _ = try? await stop()
    }

    let projectPath: String

    /// Fires on the main actor when the launched process terminates.
    var onTerminated: (() -> Void)?

    private var runningProcess: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var lastBuildResult: BuildResult?
    private var consoleBuffer: [ConsoleEntry] = []
    private let consoleMaxEntries = 2000

    // MARK: - Keep-alive

    /// When true, the adapter automatically relaunches the spawned process
    /// if it exits cleanly while a binding is active. Default true — protects
    /// users from SwiftPM `executableTarget` apps that quit on last-window-
    /// close (a SwiftUI app without an explicit `applicationShouldTerminate
    /// AfterLastWindowClosed = false` will exit when the user closes the
    /// window, even though the user usually didn't mean to fully quit).
    /// Keep-alive transparently relaunches after a clean last-window exit so
    /// the binding survives. Startup crashes are handled by the guard below.
    /// Disabled when the user (or Claude) explicitly calls `mac_stop`.
    var keepAlive: Bool = true

    /// Set by `stop()` to suppress the next keep-alive relaunch — the user
    /// asked for the app to stop, don't immediately bring it back. Consumed
    /// by the terminationHandler.
    private var suppressNextRelaunch: Bool = false

    /// When the current spawn started — used for the quick-exit guard. If
    /// the app exits within 5s of launch, treat as a startup crash and don't
    /// auto-relaunch (would loop forever on an unfixable error).
    private var lastLaunchedAt: Date?

    /// Counter for consecutive quick exits (uptime ≤ 5s). After 3 such
    /// failures in a row, give up and stop trying to relaunch — the app is
    /// genuinely broken right now.
    private var consecutiveQuickExits: Int = 0

    /// PID of the running app. Three sources, in priority order:
    /// 1. A `Process` we spawned via `run()` — bridge OWNS this lifecycle
    ///    (mac_stop will kill it).
    /// 2. An externally-launched app (user's `swift run` or Xcode) detected
    ///    via NSWorkspace by matching the project's executable path. Bridge
    ///    DOESN'T own this — mac_stop refuses to kill it (dangerous to
    ///    silently terminate the user's working window).
    /// 3. Nil — no instance running.
    /// Source 2 lets bind attach to an existing instance rather than spawning
    /// a duplicate and triggering macOS singleton behavior.
    var runningPid: pid_t? {
        if let p = runningProcess, p.isRunning {
            return p.processIdentifier
        }
        return externallyLaunchedPid()
    }

    /// True when `runningPid` came from a Process we spawned (vs. discovered
    /// via NSWorkspace). `mac_stop` checks this — refuses to kill an
    /// externally-launched app since the bridge didn't start it and shouldn't
    /// silently end the user's working window.
    var ownsRunningProcess: Bool {
        runningProcess?.isRunning == true
    }

    /// Look for a running NSRunningApplication whose `executableURL` lives
    /// under the bound `projectPath`. Catches `swift run` builds (`.build/
    /// debug/<exec>`) AND Xcode-launched debug builds. Lazy — queried fresh
    /// each call so the user can quit/relaunch externally and the bridge
    /// re-discovers.
    private func externallyLaunchedPid() -> pid_t? {
        let projectURL = URL(fileURLWithPath: projectPath).standardizedFileURL
        for app in NSWorkspace.shared.runningApplications {
            guard let exec = app.executableURL?.standardizedFileURL else { continue }
            // Match if the executable path is under the project dir.
            // covers .build/debug/<exec>, .build/release/<exec>, and Xcode's
            // DerivedData if symlinked, plus any other build output we don't
            // know about specifically.
            if exec.path.hasPrefix(projectURL.path + "/") {
                return app.processIdentifier
            }
        }
        return nil
    }

    init(projectPath: String) {
        self.projectPath = projectPath
    }

    deinit {
        // Don't call `runningProcess?.terminate()` here. Once the process is
        // spawned, the OS-level process is decoupled from this Swift Process
        // object — it can outlive the adapter cleanly. If the user closes
        // their terminal (registry orphan-cleanup drops the adapter from the
        // dict), the blockmark window should stay alive. The user can quit
        // it themselves or rebind a new terminal to reattach. Kill semantics
        // belong only in `stop()` which is called by user-explicit unbinds
        // and `mac_stop`. A terminal tab can disappear while its target must
        // remain alive, so terminating from deinit is needlessly aggressive.
    }

    // MARK: - Build

    /// Run `swift build` against the project. Captures stdout/stderr,
    /// parses error/warning lines, returns a structured result.
    @discardableResult
    func build(productName: String? = nil, configuration: String = "debug") async throws -> BuildResult {
        let started = Date()
        var args = ["swift", "build", "-c", configuration]
        if let p = productName {
            args.append(contentsOf: ["--product", p])
        }
        let captured = try await BridgeProcessCapture.runAsync(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: args,
            currentDirectoryURL: URL(fileURLWithPath: projectPath),
            timeout: 900,
            stdoutLimit: 32 * 1024 * 1024,
            stderrLimit: 32 * 1024 * 1024)
        let combined = String(decoding: captured.stdout, as: UTF8.self)
            + String(decoding: captured.stderr, as: UTF8.self)
        let result = BuildResult.parse(
            output: combined,
            success: captured.terminationStatus == 0,
            durationMs: Int(Date().timeIntervalSince(started) * 1000),
            projectPath: projectPath,
            productName: productName,
            configuration: configuration)
        lastBuildResult = result
        return result
    }

    // MARK: - Run

    /// Launch the most recently built executable from `.build/<arch>/<config>/`.
    /// If multiple executables exist, prefer one matching `productName`,
    /// otherwise pick the most recently modified file. Returns the PID
    /// and a settle delay so callers know when AX/screenshot tools will
    /// have something to look at.
    func run(productName: String? = nil, args: [String] = [], configuration: String = "debug") async throws -> [String: Any] {
        if let existing = runningProcess, existing.isRunning {
            throw MacAppError.alreadyRunning(pid: existing.processIdentifier)
        }
        // Externally-launched check: if the user has blockmark open from
        // `swift run` or Xcode, DON'T spawn a duplicate. Spawning a second
        // instance fights macOS app-singleton logic and one of the two
        // (often the user's original) gets killed. Throwing alreadyRunning
        // means the Build & Run pill
        // surfaces an error rather than silently destroying the window.
        if let externalPid = externallyLaunchedPid() {
            throw MacAppError.alreadyRunning(pid: externalPid)
        }
        let exec = try locateExecutable(productName: productName, configuration: configuration)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exec)
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: projectPath)

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        attachConsoleReader(pipe: outPipe, stream: .stdout)
        attachConsoleReader(pipe: errPipe, stream: .stderr)

        proc.terminationHandler = { [weak self] terminatedProc in
            let exitStatus = terminatedProc.terminationStatus
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.runningProcess = nil
                self.stdoutPipe = nil
                self.stderrPipe = nil

                // Decide: keep-alive relaunch or fall through to onTerminated?
                // Skip relaunch if:
                // 1. keep-alive is off
                // 2. user (or Claude) just asked to stop
                // 3. exit was non-clean (status != 0) — likely a crash; don't loop
                // 4. uptime ≤ 5s — startup-crash territory; cap consecutive
                // 5. consecutiveQuickExits ≥ 3 — give up
                let uptime = self.lastLaunchedAt.map { Date().timeIntervalSince($0) } ?? 0

                if self.suppressNextRelaunch {
                    self.suppressNextRelaunch = false
                    // Bridge-initiated stop (mac_stop or shutdown via unbind).
                    // Skip BOTH relaunch AND onTerminated. Adapter stays in
                    // macAppAdapters; binding stays alive. Critical for the
                    // dev loop: mac_build → mac_stop → mac_run cycle needs
                    // the adapter alive across the stop. Firing onTerminated
                    // would unbind mid-loop and break the next mac_run.
                    // The unbind path (when called from shutdown) doesn't
                    // need onTerminated either — unbindSession is doing the
                    // cleanup itself.
                    NSLog("[MacAppAdapter] terminated; explicit stop — adapter stays bound, ready for next mac_run")
                    return
                }
                if !self.keepAlive {
                    self.onTerminated?()
                    return
                }
                if exitStatus != 0 {
                    NSLog("[MacAppAdapter] terminated with non-zero status %d; not relaunching (likely crash)", exitStatus)
                    self.onTerminated?()
                    return
                }
                if uptime <= 5.0 {
                    self.consecutiveQuickExits += 1
                    NSLog("[MacAppAdapter] quick exit (%.2fs uptime, count=%d); not relaunching",
                          uptime, self.consecutiveQuickExits)
                    self.onTerminated?()
                    return
                }
                if self.consecutiveQuickExits >= 3 {
                    NSLog("[MacAppAdapter] 3 consecutive quick exits — giving up on keep-alive")
                    self.onTerminated?()
                    return
                }

                // Healthy exit (uptime > 5s, clean status, keep-alive on, not
                // user-requested). Relaunch transparently. Reset quick-exit
                // counter — we ran for a while, this counts as "the app is
                // working." Brief delay so any system cleanup completes
                // before we re-spawn.
                self.consecutiveQuickExits = 0
                NSLog("[MacAppAdapter] keep-alive: relaunching after %.1fs uptime", uptime)
                try? await Task.sleep(nanoseconds: 200_000_000)
                _ = try? await self.run()
            }
        }
        try proc.run()
        runningProcess = proc
        stdoutPipe = outPipe
        stderrPipe = errPipe
        lastLaunchedAt = Date()
        NSLog("[MacAppAdapter] launched %@ pid=%d", exec, proc.processIdentifier)

        // Brief settle so subsequent screenshot/AX calls have a window
        // to look at. 500ms is empirically enough for most AppKit apps.
        try? await Task.sleep(nanoseconds: 500_000_000)

        return [
            "executable": exec,
            "pid": Int(proc.processIdentifier),
            "windowCount": frontmostWindowCount(forPid: proc.processIdentifier),
        ]
    }

    /// Terminate the running process. SIGTERM first; if still alive after
    /// 1s, SIGKILL. Returns whether the kill was forced.
    ///
    /// **Refuses to kill externally-launched apps.** When the user has
    /// blockmark open from `swift run` or Xcode and the bridge ATTACHED
    /// (per `runningPid`'s NSWorkspace fallback), `runningProcess` is nil
    /// and we silently no-op rather than try to kill a process the bridge
    /// didn't start. The bridge follows a strict ownership rule: what it did
    /// not spawn, it does not kill.
    func stop() async throws -> [String: Any] {
        // User (or Claude) is explicitly asking to stop. Suppress the next
        // keep-alive relaunch — they want it stopped, not "stopped then
        // bounced back up." Consumed by the terminationHandler.
        suppressNextRelaunch = true
        guard let proc = runningProcess, proc.isRunning else {
            // No bridge-owned process. Maybe one's running externally;
            // surface that fact so callers (including Claude reading the
            // response) understand WHY nothing happened.
            if let externalPid = externallyLaunchedPid() {
                return [
                    "wasRunning": false,
                    "attached": true,
                    "externalPid": Int(externalPid),
                    "note": "App is running externally (launched outside the bridge). mac_stop refuses to kill it — quit it yourself if needed."
                ]
            }
            return ["wasRunning": false]
        }
        let pid = proc.processIdentifier
        proc.terminate()  // SIGTERM
        for _ in 0..<10 {
            if !proc.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        var forced = false
        if proc.isRunning {
            kill(pid, SIGKILL)
            forced = true
        }
        runningProcess = nil
        stdoutPipe = nil
        stderrPipe = nil
        return ["wasRunning": true, "pid": Int(pid), "forced": forced]
    }

    // MARK: - Screenshot

    /// SCK capture of the frontmost window owned by the running PID.
    /// Returns PNG bytes. Same pipeline pattern as `VisionFinder`.
    func screenshot() async throws -> Data {
        guard let pid = runningPid else { throw MacAppError.notRunning }
        let content = try await SCShareableContent.current
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.isOnScreen
        }
        guard let target = candidates.max(by: { lhs, rhs in
            (lhs.frame.width * lhs.frame.height) < (rhs.frame.width * rhs.frame.height)
        }) else {
            throw MacAppError.noWindow
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        let pixelWidth = target.frame.width * 2
        let pixelHeight = target.frame.height * 2
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= 16_384, pixelHeight <= 16_384 else {
            throw MacAppError.noWindow
        }
        config.width = Int(pixelWidth.rounded(.up))   // assume Retina
        config.height = Int(pixelHeight.rounded(.up))
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return try pngData(from: image)
    }

    // MARK: - Accessibility tree

    /// Walk the AX tree of the running app's frontmost window down to
    /// `maxDepth`. Returns a JSON-friendly nested dict. Used by Claude
    /// to find clickable/typeable elements before issuing `click`/`type`.
    func axTree(maxDepth: Int = 5) async throws -> [String: Any] {
        guard let pid = runningPid else { throw MacAppError.notRunning }
        let app = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        let res = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRef)
        let window: AXUIElement
        if res == .success, let focused = AXSafety.element(focusedRef) {
            window = focused
        } else {
            // Fall back to first window.
            var windowsRef: CFTypeRef?
            let r2 = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
            guard r2 == .success, let arr = windowsRef as? [AXUIElement], let first = arr.first else {
                throw MacAppError.noWindow
            }
            window = first
        }
        var remaining = Self.maxAXNodes
        return Self.axNode(
            window,
            depth: 0,
            maxDepth: min(max(maxDepth, 0), 32),
            remaining: &remaining)
    }

    /// Find an element by query (case-insensitive substring match against
    /// title, label, role, identifier) and dispatch AXPressAction.
    /// Returns the matched element's path-info + screen-space frame
    /// (top-left origin CG coords) so callers can position visuals at the
    /// click target.
    func click(query: String) async throws -> [String: Any] {
        guard let pid = runningPid else { throw MacAppError.notRunning }
        let app = AXUIElementCreateApplication(pid)
        guard let match = Self.findFirst(in: app, matching: query.lowercased()) else {
            throw MacAppError.elementNotFound(query: query)
        }
        let frame = Self.frameAttr(match.element)
        let result = AXUIElementPerformAction(match.element, kAXPressAction as CFString)
        if result != .success {
            throw MacAppError.axActionFailed(action: "press", code: result.rawValue)
        }
        var summary = match.summary
        if let f = frame {
            summary["frame"] = ["x": f.origin.x, "y": f.origin.y,
                                "w": f.size.width, "h": f.size.height]
        }
        return ["query": query, "match": summary]
    }

    /// Return ALL AX elements matching `query`. Pre-order walk; matches
    /// are in document order. Useful for "list every Save button" reads
    /// where Claude wants to count matches or pick by index, not just
    /// take the first one. Mirrors Chrome's `find` (which returns array).
    func findAll(query: String) async throws -> [[String: Any]] {
        guard let pid = runningPid else { throw MacAppError.notRunning }
        let app = AXUIElementCreateApplication(pid)
        var matches: [[String: Any]] = []
        var stack: [AXUIElement] = [app]
        let needle = query.lowercased()
        var visited = 0
        while let el = stack.popLast(),
              visited < Self.maxAXNodes,
              matches.count < Self.maxAXResults {
            visited += 1
            let title = (Self.stringAttr(el, kAXTitleAttribute) ?? "").lowercased()
            let label = (Self.stringAttr(el, kAXDescriptionAttribute) ?? "").lowercased()
            let role = (Self.stringAttr(el, kAXRoleAttribute) ?? "").lowercased()
            let id = (Self.stringAttr(el, kAXIdentifierAttribute) ?? "").lowercased()
            let value = (Self.stringAttr(el, kAXValueAttribute) ?? "").lowercased()
            if title.contains(needle) || label.contains(needle)
                || role.contains(needle) || id.contains(needle) || value.contains(needle) {
                var summary: [String: Any] = [
                    "role": role, "title": title, "label": label, "id": id, "value": value,
                ]
                if let f = Self.frameAttr(el) {
                    summary["frame"] = ["x": f.origin.x, "y": f.origin.y,
                                        "w": f.size.width, "h": f.size.height]
                }
                matches.append(summary)
            }
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                stack.append(contentsOf: children.reversed())
            }
        }
        return matches
    }

    /// Recursively concatenate visible text from the focused window's AX
    /// tree (title + value + description per node, joined by ` · ` within
    /// a node and `\n` between nodes). Skips empty nodes. Returns one
    /// string — Claude can read "what does the screen say" without paging
    /// through a verbose ax_tree dump. Mirrors Chrome's `get_content`.
    func getContent() async throws -> String {
        guard let pid = runningPid else { throw MacAppError.notRunning }
        let app = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        let res = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRef)
        let window: AXUIElement
        if res == .success, let focused = AXSafety.element(focusedRef) {
            window = focused
        } else {
            var windowsRef: CFTypeRef?
            let r2 = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
            guard r2 == .success, let arr = windowsRef as? [AXUIElement], let first = arr.first else {
                throw MacAppError.noWindow
            }
            window = first
        }
        var lines: [String] = []
        var stack: [AXUIElement] = [window]
        var visited = 0
        var characters = 0
        while let el = stack.popLast(),
              visited < Self.maxAXNodes,
              characters < Self.maxAXContentCharacters {
            visited += 1
            let t = Self.stringAttr(el, kAXTitleAttribute) ?? ""
            let v = Self.stringAttr(el, kAXValueAttribute) ?? ""
            let d = Self.stringAttr(el, kAXDescriptionAttribute) ?? ""
            let combined = [t, v, d].filter { !$0.isEmpty }.joined(separator: " · ")
            if !combined.isEmpty {
                let available = Self.maxAXContentCharacters - characters
                let line = String(combined.prefix(available))
                lines.append(line)
                characters += line.count + 1
            }
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let arr = childrenRef as? [AXUIElement] {
                stack.append(contentsOf: arr.reversed())
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Detailed read of one element matching `query`. Returns ALL standard
    /// AX attributes for inspection: role, roleDescription, title, label,
    /// value, id, help, frame, enabled, focused, childrenCount. No action
    /// taken — pure inspection. Mirrors Chrome's `get_element`.
    func getElement(query: String) async throws -> [String: Any] {
        guard let pid = runningPid else { throw MacAppError.notRunning }
        let app = AXUIElementCreateApplication(pid)
        guard let match = Self.findFirst(in: app, matching: query.lowercased()) else {
            throw MacAppError.elementNotFound(query: query)
        }
        let el = match.element
        var info: [String: Any] = [:]
        info["role"] = Self.stringAttr(el, kAXRoleAttribute) ?? ""
        info["roleDescription"] = Self.stringAttr(el, kAXRoleDescriptionAttribute) ?? ""
        info["title"] = Self.stringAttr(el, kAXTitleAttribute) ?? ""
        info["label"] = Self.stringAttr(el, kAXDescriptionAttribute) ?? ""
        info["value"] = Self.stringAttr(el, kAXValueAttribute) ?? ""
        info["id"] = Self.stringAttr(el, kAXIdentifierAttribute) ?? ""
        info["help"] = Self.stringAttr(el, kAXHelpAttribute) ?? ""
        if let frame = Self.frameAttr(el) {
            info["frame"] = ["x": frame.origin.x, "y": frame.origin.y,
                             "w": frame.size.width, "h": frame.size.height]
        }
        var enabledRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXEnabledAttribute as CFString, &enabledRef) == .success,
           let v = enabledRef as? Bool { info["enabled"] = v }
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXFocusedAttribute as CFString, &focusedRef) == .success,
           let v = focusedRef as? Bool { info["focused"] = v }
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let arr = childrenRef as? [AXUIElement] { info["childrenCount"] = arr.count }
        return info
    }

    /// Walk the AX tree and return all elements with an interactive role
    /// (button/textfield/textarea/link/popUpButton/checkBox/radioButton/
    /// menuItem/tabGroup/slider/scrollBar). Optional `role` filter narrows
    /// further. Mirrors Chrome's `list_interactive` — answers "what can
    /// Claude click here?" without needing a full ax_tree dump.
    func listInteractive(role: String? = nil) async throws -> [[String: Any]] {
        guard let pid = runningPid else { throw MacAppError.notRunning }
        let interactiveRoles: Set<String> = [
            "AXButton", "AXTextField", "AXTextArea", "AXLink",
            "AXPopUpButton", "AXCheckBox", "AXRadioButton",
            "AXMenuItem", "AXTabGroup", "AXSlider", "AXScrollBar",
        ]
        let app = AXUIElementCreateApplication(pid)
        var results: [[String: Any]] = []
        var stack: [AXUIElement] = [app]
        var visited = 0
        while let el = stack.popLast(),
              visited < Self.maxAXNodes,
              results.count < Self.maxAXResults {
            visited += 1
            let r = Self.stringAttr(el, kAXRoleAttribute) ?? ""
            if interactiveRoles.contains(r), (role == nil || r == role) {
                var info: [String: Any] = [
                    "role": r,
                    "title": Self.stringAttr(el, kAXTitleAttribute) ?? "",
                    "label": Self.stringAttr(el, kAXDescriptionAttribute) ?? "",
                    "id": Self.stringAttr(el, kAXIdentifierAttribute) ?? "",
                    "value": Self.stringAttr(el, kAXValueAttribute) ?? "",
                ]
                if let f = Self.frameAttr(el) {
                    info["frame"] = ["x": f.origin.x, "y": f.origin.y,
                                     "w": f.size.width, "h": f.size.height]
                }
                results.append(info)
            }
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                stack.append(contentsOf: children.reversed())
            }
        }
        return results
    }

    /// Poll `findFrame` every 150ms until the element appears or `timeout`
    /// elapses. Throws `elementNotFound` on timeout. Useful for "click
    /// submit after the dialog finishes loading" patterns where the AX
    /// tree is still settling. 5s default matches Chrome's wait_for.
    func waitFor(query: String, timeout: Double = 5.0) async throws -> [String: Any] {
        let safeTimeout = timeout.isFinite ? min(max(timeout, 0), 120) : 5
        let deadline = Date().addingTimeInterval(safeTimeout)
        while Date() < deadline {
            if let frame = try? await findFrame(query: query) {
                return [
                    "query": query,
                    "found": true,
                    "frame": ["x": frame.origin.x, "y": frame.origin.y,
                              "w": frame.size.width, "h": frame.size.height],
                ]
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        throw MacAppError.elementNotFound(
            query: "wait_for(\(query)) timed out after \(safeTimeout)s")
    }

    /// Locate an element by query and return its screen-space frame
    /// (top-left origin CG coords) without performing any action. Used by
    /// the cursor overlay to anchor the visual *before* the press fires,
    /// so the user sees Claude's intent in advance rather than after.
    func findFrame(query: String) async throws -> CGRect {
        guard let pid = runningPid else { throw MacAppError.notRunning }
        let app = AXUIElementCreateApplication(pid)
        guard let match = Self.findFirst(in: app, matching: query.lowercased()) else {
            throw MacAppError.elementNotFound(query: query)
        }
        guard let frame = Self.frameAttr(match.element) else {
            throw MacAppError.axActionFailed(action: "frame", code: -1)
        }
        return frame
    }

    /// Frame (top-left CG screen coords) of the bound app's focused window,
    /// or its first window as fallback. Used by visual overlays (screenshot
    /// rect, future intent strip) to anchor over the right surface.
    func targetWindowFrame() -> CGRect? {
        guard let pid = runningPid else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        let res = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref)
        let window: AXUIElement
        if res == .success, let focused = AXSafety.element(ref) {
            window = focused
        } else {
            var windowsRef: CFTypeRef?
            let r2 = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
            guard r2 == .success, let arr = windowsRef as? [AXUIElement], let first = arr.first else {
                return nil
            }
            window = first
        }
        return Self.frameAttr(window)
    }

    /// Type text into the focused element, or into the element matching
    /// `query` if provided. For `query` mode: focus the element first via
    /// AXSetAttribute, then set value. Reliable for AppKit text fields;
    /// some custom controls may not honor AXValue mutation — caller can
    /// fall back to `press` + key events later.
    func type(text: String, query: String? = nil) async throws -> [String: Any] {
        guard let pid = runningPid else { throw MacAppError.notRunning }
        let app = AXUIElementCreateApplication(pid)

        let target: AXUIElement
        if let q = query {
            guard let match = Self.findFirst(in: app, matching: q.lowercased()) else {
                throw MacAppError.elementNotFound(query: q)
            }
            target = match.element
            // Focus the element so subsequent input goes there.
            AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        } else {
            var focusedRef: CFTypeRef?
            let r = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef)
            guard r == .success, let focused = AXSafety.element(focusedRef) else {
                throw MacAppError.noFocusedElement
            }
            target = focused
        }
        let setResult = AXUIElementSetAttributeValue(
            target, kAXValueAttribute as CFString, text as CFTypeRef
        )
        if setResult != .success {
            throw MacAppError.axActionFailed(action: "setValue", code: setResult.rawValue)
        }
        return ["typed": text, "query": query as Any]
    }

    // MARK: - Gestures (CGEvent + AX hybrid)
    //
    // For element-targeted ops we resolve a frame via AX (reliable across
    // apps), then drive the actual gesture via CGEvent because AX has no
    // primitive for double-click / right-click / drag / hover / arbitrary
    // key chords. AX `kAXShowMenuAction` works on some elements (table
    // rows, status items) but is inconsistent; using CGEvent right-click
    // gives a uniform behavior across every responder.

    /// Find the matching AX element and return its center in top-left CG
    /// screen coords. Used by every gesture below to anchor the synthetic
    /// CGEvent at the right point.
    private func centerOf(query: String) async throws -> CGPoint {
        let frame = try await findFrame(query: query)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Double-click the element matching `query`. AX has no double-click
    /// primitive, so we synthesize two `leftMouseDown`/`leftMouseUp` pairs
    /// in quick succession with `mouseEventClickState` set so the OS
    /// recognizes them as a single double-click event.
    func doubleClick(query: String) async throws -> [String: Any] {
        guard runningPid != nil else { throw MacAppError.notRunning }
        let center = try await centerOf(query: query)
        // First click: clickState 1
        cgClick(at: center, button: .left, clickState: 1)
        // Tiny gap so the OS treats the next pair as the second of a pair.
        // 50ms is well within the system double-click interval (~500ms default).
        try? await Task.sleep(nanoseconds: 50_000_000)
        // Second click: clickState 2 — this is what makes it a double-click.
        cgClick(at: center, button: .left, clickState: 2)
        return ["query": query, "x": center.x, "y": center.y]
    }

    /// Right-click the element matching `query`. We use CGEvent rather than
    /// `kAXShowMenuAction` because the latter only works on some elements
    /// (notably table rows and outline cells) and silently no-ops elsewhere.
    func rightClick(query: String) async throws -> [String: Any] {
        guard runningPid != nil else { throw MacAppError.notRunning }
        let center = try await centerOf(query: query)
        cgClick(at: center, button: .right, clickState: 1)
        return ["query": query, "x": center.x, "y": center.y]
    }

    /// Hover the cursor over the element matching `query` for `duration`
    /// seconds. Snapshots the user's real cursor position, warps to the
    /// target, posts a `mouseMoved` event so AppKit's tracking-area
    /// machinery fires (tooltips, hover styles), then waits and warps
    /// back. Caller-visible side effect: real cursor briefly disappears
    /// from where the user left it. We restore it before returning.
    func hover(query: String, duration: Double = 1.0) async throws -> [String: Any] {
        guard runningPid != nil else { throw MacAppError.notRunning }
        let center = try await centerOf(query: query)
        let originalBL = NSEvent.mouseLocation  // bottom-left coords
        // Move to the target. mouseMoved is what triggers tracking areas /
        // tooltips; CGWarp alone doesn't fire those events.
        CGWarpMouseCursorPosition(center)
        if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: center, mouseButton: .left) {
            move.post(tap: .cghidEventTap)
        }
        // Hold so tooltips have time to materialize. Cap at 5s to avoid
        // beach-balling the bridge if a caller passes something silly.
        let safeDuration = duration.isFinite ? min(max(duration, 0.0), 5.0) : 1
        let nanos = UInt64(safeDuration * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
        // Restore the user's cursor where they left it.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let restoreTL = CGPoint(x: originalBL.x, y: primaryHeight - originalBL.y)
        CGWarpMouseCursorPosition(restoreTL)
        return ["query": query, "x": center.x, "y": center.y,
                "durationMs": Int(safeDuration * 1000)]
    }

    /// Scroll. If `query` is given, resolve the element and scroll there;
    /// otherwise scroll wherever the focused-element/cursor is. Direction
    /// in {"up", "down", "left", "right"}. Amount is in pixels (gets
    /// negated as appropriate for direction).
    func scroll(query: String?, direction: String, amount: Double = 100) async throws -> [String: Any] {
        guard runningPid != nil else { throw MacAppError.notRunning }
        // If we have a query, warp to that point first so the scroll lands
        // on the intended container.
        var anchor: CGPoint?
        if let q = query {
            let center = try await centerOf(query: q)
            CGWarpMouseCursorPosition(center)
            // Brief settle so the new cursor position is the active hit-test
            // origin for the wheel event.
            try? await Task.sleep(nanoseconds: 30_000_000)
            anchor = center
        }
        let dir = direction.lowercased()
        let delta = Int32(min(max(amount, 1.0), 10_000.0))
        // Scroll wheel sign convention on macOS: positive Y = scroll up
        // (content moves down), negative Y = scroll down. Same for X but
        // inverted: positive = scroll left, negative = scroll right.
        let dy: Int32
        let dx: Int32
        switch dir {
        case "up":    dy =  delta; dx = 0
        case "down":  dy = -delta; dx = 0
        case "left":  dy = 0;      dx =  delta
        case "right": dy = 0;      dx = -delta
        default:
            throw MacAppError.axActionFailed(action: "scroll(\(direction))", code: -1)
        }
        if let event = CGEvent(scrollWheelEvent2Source: nil,
                               units: .pixel,
                               wheelCount: 2,
                               wheel1: dy, wheel2: dx, wheel3: 0) {
            event.post(tap: .cghidEventTap)
        }
        return [
            "query": query as Any,
            "direction": dir,
            "amount": Int(amount),
            "x": anchor?.x as Any,
            "y": anchor?.y as Any,
        ]
    }

    /// Drag from the element matching `fromQuery` to the one matching
    /// `toQuery`, over `duration` seconds. Synthesizes a leftMouseDown at
    /// the source, ~30 intermediate `leftMouseDragged` frames along the
    /// straight-line path, then a leftMouseUp at the target. Drag distance
    /// is split into 60 FPS chunks so AppKit's drag-tracking sees a smooth
    /// motion (single big jump can be misread as a flick).
    func drag(fromQuery: String, toQuery: String, duration: Double = 0.5) async throws -> [String: Any] {
        guard runningPid != nil else { throw MacAppError.notRunning }
        let from = try await centerOf(query: fromQuery)
        let to = try await centerOf(query: toQuery)
        let originalBL = NSEvent.mouseLocation
        // Mouse down at source.
        CGWarpMouseCursorPosition(from)
        if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                              mouseCursorPosition: from, mouseButton: .left) {
            down.post(tap: .cghidEventTap)
        }
        // Intermediate drag frames. Cap frame count so very short durations
        // still get a few samples (some AppKit drag controllers need >=2
        // dragged events to commit).
        let frameInterval: TimeInterval = 1.0 / 60.0
        let safeDuration = duration.isFinite ? min(max(duration, 0.05), 10) : 0.5
        let frames = min(600, max(2, Int((safeDuration / frameInterval).rounded())))
        for i in 1...frames {
            let t = CGFloat(i) / CGFloat(frames)
            let x = from.x + (to.x - from.x) * t
            let y = from.y + (to.y - from.y) * t
            let p = CGPoint(x: x, y: y)
            if let dragged = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                     mouseCursorPosition: p, mouseButton: .left) {
                dragged.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: UInt64(frameInterval * 1_000_000_000))
        }
        // Mouse up at target.
        if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                            mouseCursorPosition: to, mouseButton: .left) {
            up.post(tap: .cghidEventTap)
        }
        // Restore user's cursor.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let restoreTL = CGPoint(x: originalBL.x, y: primaryHeight - originalBL.y)
        CGWarpMouseCursorPosition(restoreTL)
        return [
            "from": ["x": from.x, "y": from.y],
            "to": ["x": to.x, "y": to.y],
            "fromQuery": fromQuery,
            "toQuery": toQuery,
            "durationMs": Int(safeDuration * 1000),
        ]
    }

    /// Focus the element matching `query` by setting `kAXFocusedAttribute`.
    /// Pure AX — no CGEvent injection — so it doesn't perturb the user's
    /// cursor position.
    func focus(query: String) async throws -> [String: Any] {
        guard let pid = runningPid else { throw MacAppError.notRunning }
        let app = AXUIElementCreateApplication(pid)
        guard let match = Self.findFirst(in: app, matching: query.lowercased()) else {
            throw MacAppError.elementNotFound(query: query)
        }
        let res = AXUIElementSetAttributeValue(match.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if res != .success {
            throw MacAppError.axActionFailed(action: "setFocused", code: res.rawValue)
        }
        return ["query": query, "match": match.summary]
    }

    /// Send a keyboard chord like `"cmd+s"` or `"shift+cmd+t"` to the
    /// running app. Modifier-aware: parses `cmd|ctrl|alt|option|shift`
    /// tokens, plus a final key token (letter, number, or named special
    /// like `return`, `escape`, `tab`, `space`, `up`, `f1`).
    func sendKey(_ chord: String) async throws -> [String: Any] {
        guard runningPid != nil else { throw MacAppError.notRunning }
        guard let parsed = Self.parseKeys(chord) else {
            throw MacAppError.axActionFailed(action: "parseKey(\(chord))", code: -1)
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: false) else {
            throw MacAppError.axActionFailed(action: "createKeyEvent(\(chord))", code: -1)
        }
        down.flags = parsed.modifiers
        up.flags = parsed.modifiers
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return ["chord": chord, "keyCode": Int(parsed.keyCode), "modifiers": parsed.modifiers.rawValue]
    }

    /// Convenience for the most common chord — pressing return to submit
    /// a form or accept a dialog. Just delegates to `sendKey("return")`
    /// but exposed as its own MCP tool because Claude reaches for it
    /// often enough that having a dedicated verb is clearer.
    func pressReturn() async throws -> [String: Any] {
        return try await sendKey("return")
    }

    /// Synthesize a mouse-down + mouse-up at `point` (top-left CG coords)
    /// with the given button. `clickState` is for double-click semantics:
    /// 1 = single, 2 = second click of a double-click pair (the OS uses
    /// this field to recognize doubles vs. two separate single clicks).
    /// Saves the user's real cursor position and restores it after, so
    /// gestures don't leave the cursor stranded over the bound app.
    private func cgClick(at point: CGPoint, button: CGMouseButton = .left, clickState: Int64 = 1) {
        let originalBL = NSEvent.mouseLocation  // bottom-left
        CGWarpMouseCursorPosition(point)        // top-left
        let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        if let down = CGEvent(mouseEventSource: nil, mouseType: downType,
                              mouseCursorPosition: point, mouseButton: button) {
            down.setIntegerValueField(.mouseEventClickState, value: clickState)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: nil, mouseType: upType,
                            mouseCursorPosition: point, mouseButton: button) {
            up.setIntegerValueField(.mouseEventClickState, value: clickState)
            up.post(tap: .cghidEventTap)
        }
        // Restore the user's cursor where they left it. NSEvent.mouseLocation
        // is bottom-left primary-screen-relative; CGWarp wants top-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let restoreTL = CGPoint(x: originalBL.x, y: primaryHeight - originalBL.y)
        CGWarpMouseCursorPosition(restoreTL)
    }

    /// Parse a chord string like `"cmd+shift+t"` into a CGEventFlags +
    /// virtual key code. Returns nil if any token is unrecognized — caller
    /// should surface a friendly error rather than silently dropping the
    /// keystroke. Tokens are separated by `+` or `-`, lowercased before
    /// lookup. Modifier tokens recognized: cmd, command, ctrl, control,
    /// alt, option, opt, shift. Final token is the key itself.
    private static func parseKeys(_ chord: String) -> (modifiers: CGEventFlags, keyCode: CGKeyCode)? {
        let tokens = chord
            .lowercased()
            .split(whereSeparator: { $0 == "+" || $0 == "-" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        var flags: CGEventFlags = []
        var keyToken: String?
        for tok in tokens {
            switch tok {
            case "cmd", "command", "meta":     flags.insert(.maskCommand)
            case "ctrl", "control":             flags.insert(.maskControl)
            case "alt", "option", "opt":        flags.insert(.maskAlternate)
            case "shift":                       flags.insert(.maskShift)
            case "fn", "function":              flags.insert(.maskSecondaryFn)
            default:
                // Last non-modifier token wins as the key. Multiple key
                // tokens isn't meaningful (one chord = one key event), so
                // we accept the final occurrence.
                keyToken = tok
            }
        }
        guard let key = keyToken, let code = keyCodeFor(key) else { return nil }
        return (flags, code)
    }

    /// Map a key token to a Carbon virtual key code. Covers ASCII letters,
    /// digits, and the common named specials. Returns nil for unknown
    /// tokens. Ranges like a-z and 0-9 are computed inline; the named
    /// table covers everything else (return/tab/escape/arrows/F-keys/punct).
    private static func keyCodeFor(_ token: String) -> CGKeyCode? {
        // Single character: letter or digit, fall through to the table for
        // punctuation that doesn't have a stable letter form.
        if token.count == 1, let scalar = token.unicodeScalars.first {
            let v = scalar.value
            if v >= 0x61 && v <= 0x7A { // a-z
                let letterMap: [CGKeyCode] = [
                    CGKeyCode(kVK_ANSI_A), CGKeyCode(kVK_ANSI_B), CGKeyCode(kVK_ANSI_C),
                    CGKeyCode(kVK_ANSI_D), CGKeyCode(kVK_ANSI_E), CGKeyCode(kVK_ANSI_F),
                    CGKeyCode(kVK_ANSI_G), CGKeyCode(kVK_ANSI_H), CGKeyCode(kVK_ANSI_I),
                    CGKeyCode(kVK_ANSI_J), CGKeyCode(kVK_ANSI_K), CGKeyCode(kVK_ANSI_L),
                    CGKeyCode(kVK_ANSI_M), CGKeyCode(kVK_ANSI_N), CGKeyCode(kVK_ANSI_O),
                    CGKeyCode(kVK_ANSI_P), CGKeyCode(kVK_ANSI_Q), CGKeyCode(kVK_ANSI_R),
                    CGKeyCode(kVK_ANSI_S), CGKeyCode(kVK_ANSI_T), CGKeyCode(kVK_ANSI_U),
                    CGKeyCode(kVK_ANSI_V), CGKeyCode(kVK_ANSI_W), CGKeyCode(kVK_ANSI_X),
                    CGKeyCode(kVK_ANSI_Y), CGKeyCode(kVK_ANSI_Z),
                ]
                return letterMap[Int(v - 0x61)]
            }
            if v >= 0x30 && v <= 0x39 { // 0-9
                let digitMap: [CGKeyCode] = [
                    CGKeyCode(kVK_ANSI_0), CGKeyCode(kVK_ANSI_1), CGKeyCode(kVK_ANSI_2),
                    CGKeyCode(kVK_ANSI_3), CGKeyCode(kVK_ANSI_4), CGKeyCode(kVK_ANSI_5),
                    CGKeyCode(kVK_ANSI_6), CGKeyCode(kVK_ANSI_7), CGKeyCode(kVK_ANSI_8),
                    CGKeyCode(kVK_ANSI_9),
                ]
                return digitMap[Int(v - 0x30)]
            }
        }
        switch token {
        case "return", "enter":           return CGKeyCode(kVK_Return)
        case "tab":                       return CGKeyCode(kVK_Tab)
        case "space", "spacebar":         return CGKeyCode(kVK_Space)
        case "delete", "backspace":       return CGKeyCode(kVK_Delete)
        case "forwarddelete", "fwddelete":return CGKeyCode(kVK_ForwardDelete)
        case "escape", "esc":             return CGKeyCode(kVK_Escape)
        case "left", "leftarrow":         return CGKeyCode(kVK_LeftArrow)
        case "right", "rightarrow":       return CGKeyCode(kVK_RightArrow)
        case "up", "uparrow":             return CGKeyCode(kVK_UpArrow)
        case "down", "downarrow":         return CGKeyCode(kVK_DownArrow)
        case "home":                      return CGKeyCode(kVK_Home)
        case "end":                       return CGKeyCode(kVK_End)
        case "pageup", "pgup":            return CGKeyCode(kVK_PageUp)
        case "pagedown", "pgdn":          return CGKeyCode(kVK_PageDown)
        case "f1":  return CGKeyCode(kVK_F1)
        case "f2":  return CGKeyCode(kVK_F2)
        case "f3":  return CGKeyCode(kVK_F3)
        case "f4":  return CGKeyCode(kVK_F4)
        case "f5":  return CGKeyCode(kVK_F5)
        case "f6":  return CGKeyCode(kVK_F6)
        case "f7":  return CGKeyCode(kVK_F7)
        case "f8":  return CGKeyCode(kVK_F8)
        case "f9":  return CGKeyCode(kVK_F9)
        case "f10": return CGKeyCode(kVK_F10)
        case "f11": return CGKeyCode(kVK_F11)
        case "f12": return CGKeyCode(kVK_F12)
        case "minus", "-":  return CGKeyCode(kVK_ANSI_Minus)
        case "equal", "=":  return CGKeyCode(kVK_ANSI_Equal)
        case "comma", ",":  return CGKeyCode(kVK_ANSI_Comma)
        case "period", ".": return CGKeyCode(kVK_ANSI_Period)
        case "slash", "/":  return CGKeyCode(kVK_ANSI_Slash)
        case "semicolon", ";": return CGKeyCode(kVK_ANSI_Semicolon)
        case "quote", "'":  return CGKeyCode(kVK_ANSI_Quote)
        case "backslash", "\\": return CGKeyCode(kVK_ANSI_Backslash)
        case "leftbracket", "[":  return CGKeyCode(kVK_ANSI_LeftBracket)
        case "rightbracket", "]": return CGKeyCode(kVK_ANSI_RightBracket)
        case "grave", "backtick", "`": return CGKeyCode(kVK_ANSI_Grave)
        default: return nil
        }
    }

    // MARK: - Console buffer

    func console(limit: Int = 200, stream: String? = nil) -> [[String: Any]] {
        let filtered: [ConsoleEntry]
        if let s = stream?.lowercased() {
            filtered = consoleBuffer.filter { $0.stream.rawValue == s }
        } else {
            filtered = consoleBuffer
        }
        let suffix = filtered.suffix(min(max(limit, 0), consoleMaxEntries))
        return suffix.map {
            ["t": ISO8601DateFormatter().string(from: $0.timestamp),
             "stream": $0.stream.rawValue,
             "text": $0.text]
        }
    }

    func clearConsole() {
        consoleBuffer.removeAll()
    }

    // MARK: - Internals

    private func attachConsoleReader(pipe: Pipe, stream: ConsoleEntry.Stream) {
        // Pipe reads happen on the background queue; bounce each chunk
        // back to main to mutate the buffer safely.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            let now = Date()
            // Split on newlines; drop empty trailing fragment if present.
            let lines = chunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                for line in lines where !line.isEmpty {
                    self.consoleBuffer.append(ConsoleEntry(
                        timestamp: now, stream: stream, text: line
                    ))
                }
                if self.consoleBuffer.count > self.consoleMaxEntries {
                    let overflow = self.consoleBuffer.count - self.consoleMaxEntries
                    self.consoleBuffer.removeFirst(overflow)
                }
            }
        }
    }

    private func locateExecutable(productName: String?, configuration: String) throws -> String {
        // SwiftPM puts arch-specific build outputs in
        // `.build/<triple>/<config>/`. On Apple Silicon Macs this is
        // typically `arm64-apple-macosx/debug/`. There's also a stable
        // symlink at `.build/<config>/` we can use, but it's not
        // populated by all swift-tools versions; fall back to scanning.
        let buildDir = projectPath + "/.build"
        let fm = FileManager.default
        let stableDir = "\(buildDir)/\(configuration)"
        let candidates: [String] = {
            if let entries = try? fm.contentsOfDirectory(atPath: stableDir), !entries.isEmpty {
                return entries.map { "\(stableDir)/\($0)" }
            }
            // Fall back: look in arch-specific dirs.
            guard let archDirs = try? fm.contentsOfDirectory(atPath: buildDir) else { return [] }
            var found: [String] = []
            for arch in archDirs where arch.contains("apple-macosx") {
                let dir = "\(buildDir)/\(arch)/\(configuration)"
                if let entries = try? fm.contentsOfDirectory(atPath: dir) {
                    found.append(contentsOf: entries.map { "\(dir)/\($0)" })
                }
            }
            return found
        }()
        // Filter to executables (regular files, executable bit set, no
        // file extension typically — SPM products are bare names).
        let executables = candidates.filter { path in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return false }
            return fm.isExecutableFile(atPath: path)
                && !path.hasSuffix(".o") && !path.hasSuffix(".swiftmodule")
                && !path.hasSuffix(".a") && !path.hasSuffix(".dylib")
                && !path.hasSuffix(".swiftdoc") && !path.hasSuffix(".swiftsourceinfo")
                && !path.contains("/Modules/")
        }
        if executables.isEmpty { throw MacAppError.executableNotFound(searchedIn: buildDir) }
        if let p = productName, let match = executables.first(where: { ($0 as NSString).lastPathComponent == p }) {
            return match
        }
        // Pick the most recently modified executable as a default.
        let withDates = executables.compactMap { path -> (String, Date)? in
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let date = attrs[.modificationDate] as? Date else { return nil }
            return (path, date)
        }
        guard let newest = withDates.max(by: { $0.1 < $1.1 })?.0 else {
            throw MacAppError.executableNotFound(searchedIn: buildDir)
        }
        return newest
    }

    private func frontmostWindowCount(forPid pid: pid_t) -> Int {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return 0 }
        return list.filter { w in
            let owner = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            return owner == pid && layer == 0
        }.count
    }

    private func pngData(from image: CGImage) throws -> Data {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw MacAppError.imageEncodingFailed
        }
        return data
    }

    // MARK: - AX walking (static so it doesn't need actor isolation)

    private struct AXMatch {
        let element: AXUIElement
        let summary: [String: Any]
    }

    /// Recursive AX walk. Returns a JSON-friendly snapshot of one node
    /// + children up to `maxDepth`. Skips invisible/zero-size elements
    /// to keep the tree small.
    private static func axNode(_ element: AXUIElement, depth: Int, maxDepth: Int,
                               remaining: inout Int) -> [String: Any] {
        guard remaining > 0 else { return [:] }
        remaining -= 1
        var node: [String: Any] = [:]
        node["role"] = stringAttr(element, kAXRoleAttribute) ?? ""
        if let title = stringAttr(element, kAXTitleAttribute), !title.isEmpty {
            node["title"] = title
        }
        if let label = stringAttr(element, kAXDescriptionAttribute), !label.isEmpty {
            node["label"] = label
        }
        if let value = stringAttr(element, kAXValueAttribute), !value.isEmpty {
            node["value"] = value
        }
        if let id = stringAttr(element, kAXIdentifierAttribute), !id.isEmpty {
            node["id"] = id
        }
        if let frame = frameAttr(element) {
            node["frame"] = ["x": frame.origin.x, "y": frame.origin.y,
                             "w": frame.size.width, "h": frame.size.height]
        }
        if depth < maxDepth {
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement], !children.isEmpty {
                var kids: [[String: Any]] = []
                for child in children {
                    guard remaining > 0 else { break }
                    kids.append(axNode(
                        child, depth: depth + 1,
                        maxDepth: maxDepth, remaining: &remaining))
                }
                if !kids.isEmpty { node["children"] = kids }
            }
        }
        return node
    }

    /// First element matching the query (lowercased substring against
    /// title / label / role / identifier / value). Pre-order walk so
    /// matches near the top of the tree win.
    private static func findFirst(in root: AXUIElement, matching needle: String) -> AXMatch? {
        var stack: [AXUIElement] = [root]
        var visited = 0
        while let el = stack.popLast(), visited < maxAXNodes {
            visited += 1
            let title = (stringAttr(el, kAXTitleAttribute) ?? "").lowercased()
            let label = (stringAttr(el, kAXDescriptionAttribute) ?? "").lowercased()
            let role = (stringAttr(el, kAXRoleAttribute) ?? "").lowercased()
            let id = (stringAttr(el, kAXIdentifierAttribute) ?? "").lowercased()
            let value = (stringAttr(el, kAXValueAttribute) ?? "").lowercased()
            if title.contains(needle) || label.contains(needle)
                || role.contains(needle) || id.contains(needle) || value.contains(needle) {
                let summary: [String: Any] = [
                    "role": role, "title": title, "label": label, "id": id,
                ]
                return AXMatch(element: el, summary: summary)
            }
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                // Push in reverse so first-child is popped first (pre-order).
                stack.append(contentsOf: children.reversed())
            }
        }
        return nil
    }

    private static func stringAttr(_ element: AXUIElement, _ key: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func frameAttr(_ element: AXUIElement) -> CGRect? {
        AXSafety.frame(of: element)
    }
}

// MARK: - Supporting types

struct ConsoleEntry {
    enum Stream: String { case stdout, stderr }
    let timestamp: Date
    let stream: Stream
    let text: String
}

struct BuildResult {
    let success: Bool
    let durationMs: Int
    let errors: [BuildIssue]
    let warnings: [BuildIssue]
    let executablePath: String?
    let projectPath: String
    let configuration: String

    /// JSON-friendly representation for MCP responses.
    func asDict() -> [String: Any] {
        [
            "success": success,
            "durationMs": durationMs,
            "errors": errors.map { $0.asDict() },
            "warnings": warnings.map { $0.asDict() },
            "executablePath": executablePath as Any,
            "projectPath": projectPath,
            "configuration": configuration,
        ]
    }

    /// Parse `swift build` output. Lines like
    /// `/path/to/file.swift:42:13: error: cannot find 'foo' in scope`
    /// → structured BuildIssue. `note` lines attach to nothing (dropped).
    static func parse(output: String, success: Bool, durationMs: Int,
                      projectPath: String, productName: String?, configuration: String) -> BuildResult {
        var errors: [BuildIssue] = []
        var warnings: [BuildIssue] = []
        let pattern = #"^(.+?):(\d+):(\d+):\s+(error|warning|note):\s+(.+)$"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.anchorsMatchLines]) else {
            return BuildResult(
                success: success, durationMs: durationMs, errors: [], warnings: [],
                executablePath: nil,
                projectPath: projectPath, configuration: configuration)
        }
        let nsOutput = output as NSString
        let range = NSRange(location: 0, length: nsOutput.length)
        regex.enumerateMatches(in: output, options: [], range: range) { match, _, _ in
            guard let m = match, m.numberOfRanges == 6 else { return }
            let file = nsOutput.substring(with: m.range(at: 1))
            let line = Int(nsOutput.substring(with: m.range(at: 2))) ?? 0
            let col = Int(nsOutput.substring(with: m.range(at: 3))) ?? 0
            let severity = nsOutput.substring(with: m.range(at: 4))
            let message = nsOutput.substring(with: m.range(at: 5))
            let issue = BuildIssue(file: file, line: line, column: col,
                                   severity: severity, message: message)
            switch severity {
            case "error": errors.append(issue)
            case "warning": warnings.append(issue)
            default: break  // notes dropped
            }
        }
        return BuildResult(
            success: success,
            durationMs: durationMs,
            errors: errors,
            warnings: warnings,
            executablePath: nil,  // populated by caller if known
            projectPath: projectPath,
            configuration: configuration
        )
    }
}

struct BuildIssue {
    let file: String
    let line: Int
    let column: Int
    let severity: String
    let message: String

    func asDict() -> [String: Any] {
        ["file": file, "line": line, "column": column, "severity": severity, "message": message]
    }
}

enum MacAppError: Error, LocalizedError {
    case alreadyRunning(pid: pid_t)
    case notRunning
    case noWindow
    case noFocusedElement
    case executableNotFound(searchedIn: String)
    case elementNotFound(query: String)
    case axActionFailed(action: String, code: Int32)
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRunning(let pid): return "App already running (pid \(pid))"
        case .notRunning: return "App is not running — call run() first"
        case .noWindow: return "No on-screen window found for the running app"
        case .noFocusedElement: return "No focused AX element"
        case .executableNotFound(let dir): return "No executable found in \(dir) — did you build first?"
        case .elementNotFound(let q): return "No AX element matched query: \(q)"
        case .axActionFailed(let a, let c): return "AX action '\(a)' failed (code \(c))"
        case .imageEncodingFailed: return "Failed to encode screenshot as PNG"
        }
    }
}
