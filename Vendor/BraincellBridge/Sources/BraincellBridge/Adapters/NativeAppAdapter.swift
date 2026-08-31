import Foundation
import AppKit
import ApplicationServices
import ScreenCaptureKit
import CoreGraphics
import Carbon.HIToolbox

/// Drives an *already-running* macOS app, identified by bundle id, via
/// AX + CGEvent + ScreenCaptureKit. Distinct from `MacAppAdapter`, which
/// builds + spawns + owns its target Process. Here the user owns the
/// app's lifecycle — we only attach to whatever pid `NSWorkspace`
/// resolves the bundle id to right now, and let go cleanly when the
/// user quits it.
///
/// Built for the Slack / Notion / Figma desktop / Things / Bear class
/// of AX-aware apps: anything that exposes a sane AX tree responds to
/// the same 16-tool surface MacAppAdapter offers (minus build/run/stop,
/// since lifecycle isn't ours to manage).
///
/// Lifecycle:
/// - bind: `BridgeAppDelegate.bindSessionToNativeApp` resolves the
///   bundle id via `NSWorkspace.runningApplications`, instantiates the
///   adapter, and registers a `didTerminateApplication` observer.
/// - work: every tool call queries `runningPid` fresh — the user can
///   quit + relaunch the app at any time outside the bridge, so we
///   never trust a cached pid.
/// - close: when the user quits the app, the workspace observer fires,
///   we call `onTerminated`, the AppDelegate's universal close-target
///   handler runs `unbindSession`, and the `+` reappears on the
///   terminal exactly like the Chrome / Mac App / Simulator paths.
@MainActor
final class NativeAppAdapter: TargetAdapter {
    private static let maxAXNodes = 20_000
    private static let maxAXResults = 5_000
    private static let maxAXContentCharacters = 2 * 1024 * 1024

    /// TargetAdapter conformance: anchor visuals + wire to the bound app.
    /// Aliases `runningPid` (which already queries NSWorkspace fresh).
    var anchorPid: pid_t? { runningPid }

    /// TargetAdapter conformance: alias for `targetWindowFrame()`.
    func windowFrame() -> CGRect? { targetWindowFrame() }

    /// TargetAdapter conformance: remove the NSWorkspace observer. We
    /// don't quit the user's app — they own it. Idempotent (already-removed
    /// observer is safe to remove again).
    func shutdown() async {
        if let obs = terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            terminationObserver = nil
        }
    }

    let bundleId: String

    /// Fires on the main actor when the bound app exits (Cmd+Q, crash,
    /// `kill`, `osascript quit app`). AppDelegate wires this to
    /// `unbindSession` so the binding doesn't outlive its target.
    var onTerminated: (() -> Void)?

    private var terminationObserver: NSObjectProtocol?

    init(bundleId: String) {
        self.bundleId = bundleId
        // Subscribe to NSWorkspace's app-terminated notifications and
        // filter by bundleId. We can't just watch the pid (no kqueue on
        // pids without raising privileges + complexity), and polling is
        // wasteful — NSWorkspace already knows. Capture-by-`self` is
        // fine because we tear the observer down in `deinit`.
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == self.bundleId else { return }
            NSLog("[NativeAppAdapter] %@ terminated (pid %d)", self.bundleId, app.processIdentifier)
            // Hop to MainActor for the callback — addObserver guarantees
            // the queue is main but the closure isn't @MainActor-annotated.
            Task { @MainActor [weak self] in
                self?.onTerminated?()
            }
        }
    }

    deinit {
        if let obs = terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    /// Currently-running pid for this bundle id, or nil if the app isn't
    /// running. Always queries `NSWorkspace` fresh — the user can quit
    /// + relaunch at any time outside the bridge, so a cached pid would
    /// silently point at a dead process. Cheap (NSWorkspace caches
    /// internally; this is just a dictionary lookup).
    var runningPid: pid_t? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleId }?
            .processIdentifier
    }

    // MARK: - Screenshot

    /// SCK capture of the largest on-screen window owned by the bound
    /// app. Returns PNG bytes. Same pipeline as `MacAppAdapter.screenshot`.
    func screenshot() async throws -> Data {
        guard let pid = runningPid else { throw NativeAppError.notRunning }
        let content = try await SCShareableContent.current
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.isOnScreen
        }
        guard let target = candidates.max(by: { lhs, rhs in
            (lhs.frame.width * lhs.frame.height) < (rhs.frame.width * rhs.frame.height)
        }) else {
            throw NativeAppError.noWindow
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        let pixelWidth = target.frame.width * 2
        let pixelHeight = target.frame.height * 2
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= 16_384, pixelHeight <= 16_384 else {
            throw NativeAppError.noWindow
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

    /// Walk the AX tree of the bound app's frontmost window down to
    /// `maxDepth`. JSON-friendly nested dict.
    func axTree(maxDepth: Int = 5) async throws -> [String: Any] {
        guard let pid = runningPid else { throw NativeAppError.notRunning }
        let app = AXUIElementCreateApplication(pid)
        let window = try focusedOrFirstWindow(of: app)
        var remaining = Self.maxAXNodes
        return Self.axNode(
            window,
            depth: 0,
            maxDepth: min(max(maxDepth, 0), 32),
            remaining: &remaining)
    }

    /// Find by query (lowercased substring against title/label/role/id/value)
    /// and dispatch AXPress. Returns matched element's path-info + screen
    /// frame so callers can position visuals at the click target.
    func click(query: String) async throws -> [String: Any] {
        guard let pid = runningPid else { throw NativeAppError.notRunning }
        let app = AXUIElementCreateApplication(pid)
        guard let match = Self.findFirst(in: app, matching: query.lowercased()) else {
            throw NativeAppError.elementNotFound(query: query)
        }
        let frame = Self.frameAttr(match.element)
        var summary = match.summary
        if let f = frame {
            summary["frame"] = ["x": f.origin.x, "y": f.origin.y,
                                "w": f.size.width, "h": f.size.height]
        }

        // CGEvent click is the primary path. Two reasons:
        //
        // 1. AXPress has different semantics across app frameworks. On plain
        //    AppKit buttons it's "press the button" (good). On Catalyst list
        //    rows (Messages' conversation list) it's "toggle this row's
        //    selection" — multi-clicks accumulate selections instead of
        //    opening one conversation. Real mouse clicks have replace-selection
        //    semantics across every framework.
        //
        // 2. CGEvent visualizes — the cursor warps to the click target
        //    (then restores), reinforcing where Claude actually clicked.
        //    AXPress is invisible.
        //
        // Fallback to AXPress only when the element has no on-screen frame
        // (off-screen, hidden, or AX returned no position) — CGEvent can't
        // click coords it doesn't have.
        if let f = frame {
            cgClick(at: CGPoint(x: f.midX, y: f.midY))
            summary["dispatch"] = "cgevent"
            return ["query": query, "match": summary]
        }
        // No frame — AXPress is our only option.
        let result = AXUIElementPerformAction(match.element, kAXPressAction as CFString)
        if result != .success {
            throw NativeAppError.axActionFailed(action: "press", code: result.rawValue)
        }
        summary["dispatch"] = "axpress"
        return ["query": query, "match": summary]
    }

    /// All elements matching `query`, document order. Useful for "list every
    /// matching button" reads where Claude wants to count or pick by index.
    func findAll(query: String) async throws -> [[String: Any]] {
        guard let pid = runningPid else { throw NativeAppError.notRunning }
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

    /// Concatenate visible text from the focused window's AX tree.
    /// Title + value + description per node, joined `\n` between nodes.
    func getContent() async throws -> String {
        guard let pid = runningPid else { throw NativeAppError.notRunning }
        let app = AXUIElementCreateApplication(pid)
        let window = try focusedOrFirstWindow(of: app)
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

    /// Detailed structured read of one element — all standard AX attributes.
    /// Pure inspection — no action.
    func getElement(query: String) async throws -> [String: Any] {
        guard let pid = runningPid else { throw NativeAppError.notRunning }
        let app = AXUIElementCreateApplication(pid)
        guard let match = Self.findFirst(in: app, matching: query.lowercased()) else {
            throw NativeAppError.elementNotFound(query: query)
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

    /// All elements with an interactive role (button/textfield/textarea/link/
    /// popUpButton/checkBox/radioButton/menuItem/tabGroup/slider/scrollBar).
    /// Optional `role` filter narrows further.
    func listInteractive(role: String? = nil) async throws -> [[String: Any]] {
        guard let pid = runningPid else { throw NativeAppError.notRunning }
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

    /// Poll until `query` resolves or `timeout` elapses. Throws on timeout.
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
        throw NativeAppError.elementNotFound(
            query: "wait_for(\(query)) timed out after \(safeTimeout)s")
    }

    /// Resolve `query` to its screen-space frame (top-left CG coords)
    /// without performing any action. Used by the cursor overlay to anchor
    /// the visual *before* the action fires.
    func findFrame(query: String) async throws -> CGRect {
        guard let pid = runningPid else { throw NativeAppError.notRunning }
        let app = AXUIElementCreateApplication(pid)
        guard let match = Self.findFirst(in: app, matching: query.lowercased()) else {
            throw NativeAppError.elementNotFound(query: query)
        }
        guard let frame = Self.frameAttr(match.element) else {
            throw NativeAppError.axActionFailed(action: "frame", code: -1)
        }
        return frame
    }

    /// Frame of the bound app's window. Disambiguation strategy when an
    /// app has multiple windows (Slack workspaces, Notion documents,
    /// Mail viewers) AND/OR when 2+ Claude sessions both bind the same
    /// bundle id: capture a CGWindowID at bind time via
    /// `lockToBoundWindow()` and look up THAT specific window here.
    /// Falls back to focused-or-first window if the captured ID is gone
    /// (user closed that specific window) or never set (legacy bind).
    func targetWindowFrame() -> CGRect? {
        guard let pid = runningPid else { return nil }
        // Bound-window path: look up our captured CGWindowID in
        // CGWindowList. Filters by both ID and pid (defense against ID
        // collisions across processes — extremely unlikely but cheap).
        if let wid = boundWindowId {
            let opts: CGWindowListOption = [.optionIncludingWindow, .excludeDesktopElements]
            if let list = CGWindowListCopyWindowInfo(opts, wid) as? [[String: Any]] {
                for w in list {
                    let owner = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
                    guard owner == pid,
                          let bounds = w[kCGWindowBounds as String] as? [String: Any],
                          let x = bounds["X"] as? CGFloat,
                          let y = bounds["Y"] as? CGFloat,
                          let width = bounds["Width"] as? CGFloat,
                          let height = bounds["Height"] as? CGFloat,
                          width > 50, height > 50 else { continue }
                    return CGRect(x: x, y: y, width: width, height: height)
                }
            }
            // Bound window vanished (user closed it). Fall through to
            // first-window — better visual than empty.
        }
        let app = AXUIElementCreateApplication(pid)
        guard let window = try? focusedOrFirstWindow(of: app) else { return nil }
        return Self.frameAttr(window)
    }

    /// CGWindowID captured at bind time so multi-window apps + multi-binding
    /// scenarios disambiguate cleanly. Set by `lockToBoundWindow()`; cleared
    /// when the captured window goes away (we just fall back to first-window
    /// then — caller might want to re-lock).
    private var boundWindowId: CGWindowID?

    /// Capture the bound app's frontmost window ID for the wire / cursor
    /// overlay to anchor to. Called by `BridgeAppDelegate.bindSessionToNativeApp`
    /// right after constructing the adapter. Strategy: walk CGWindowList
    /// for layer-0 windows owned by our pid, take the first (front-most by
    /// CGWindowList ordering) with reasonable size.
    func lockToBoundWindow() {
        guard let pid = runningPid else { return }
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        for w in list {
            let owner = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            guard owner == pid else { continue }
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            guard layer == 0 else { continue }
            guard let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  width > 100, height > 100,
                  let widNum = w[kCGWindowNumber as String] as? NSNumber else { continue }
            boundWindowId = CGWindowID(widNum.uint32Value)
            NSLog("[NativeAppAdapter] locked window %u for %@ (multi-window disambiguation)",
                  CGWindowID(widNum.uint32Value), bundleId)
            return
        }
    }

    /// Type into the focused element, or into the element matching `query`.
    /// For `query` mode: focus first via AX, then setValue. Reliable for
    /// AppKit text fields; some custom controls may not honor AXValue —
    /// caller can fall back to `sendKey` later.
    func type(text: String, query: String? = nil) async throws -> [String: Any] {
        guard let pid = runningPid else { throw NativeAppError.notRunning }
        let app = AXUIElementCreateApplication(pid)

        let target: AXUIElement
        if let q = query {
            guard let match = Self.findFirst(in: app, matching: q.lowercased()) else {
                throw NativeAppError.elementNotFound(query: q)
            }
            target = match.element
            AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        } else {
            var focusedRef: CFTypeRef?
            let r = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef)
            guard r == .success, let focused = AXSafety.element(focusedRef) else {
                throw NativeAppError.noFocusedElement
            }
            target = focused
        }
        let setResult = AXUIElementSetAttributeValue(
            target, kAXValueAttribute as CFString, text as CFTypeRef
        )
        if setResult != .success {
            throw NativeAppError.axActionFailed(action: "setValue", code: setResult.rawValue)
        }
        return ["typed": text, "query": query as Any]
    }

    // MARK: - Gestures (CGEvent + AX hybrid)
    //
    // Same pattern as MacAppAdapter: resolve a frame via AX (reliable
    // across apps), drive the gesture via CGEvent (uniform across every
    // responder, unlike `kAXShowMenuAction` which is inconsistent).

    private func centerOf(query: String) async throws -> CGPoint {
        let frame = try await findFrame(query: query)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    func doubleClick(query: String) async throws -> [String: Any] {
        guard runningPid != nil else { throw NativeAppError.notRunning }
        let center = try await centerOf(query: query)
        cgClick(at: center, button: .left, clickState: 1)
        try? await Task.sleep(nanoseconds: 50_000_000)
        cgClick(at: center, button: .left, clickState: 2)
        return ["query": query, "x": center.x, "y": center.y]
    }

    func rightClick(query: String) async throws -> [String: Any] {
        guard runningPid != nil else { throw NativeAppError.notRunning }
        let center = try await centerOf(query: query)
        cgClick(at: center, button: .right, clickState: 1)
        return ["query": query, "x": center.x, "y": center.y]
    }

    func hover(query: String, duration: Double = 1.0) async throws -> [String: Any] {
        guard runningPid != nil else { throw NativeAppError.notRunning }
        let center = try await centerOf(query: query)
        let originalBL = NSEvent.mouseLocation
        CGWarpMouseCursorPosition(center)
        if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: center, mouseButton: .left) {
            move.post(tap: .cghidEventTap)
        }
        let safeDuration = duration.isFinite ? min(max(duration, 0.0), 5.0) : 1
        let nanos = UInt64(safeDuration * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let restoreTL = CGPoint(x: originalBL.x, y: primaryHeight - originalBL.y)
        CGWarpMouseCursorPosition(restoreTL)
        return ["query": query, "x": center.x, "y": center.y,
                "durationMs": Int(safeDuration * 1000)]
    }

    func scroll(query: String?, direction: String, amount: Double = 100) async throws -> [String: Any] {
        guard runningPid != nil else { throw NativeAppError.notRunning }
        var anchor: CGPoint?
        if let q = query {
            let center = try await centerOf(query: q)
            CGWarpMouseCursorPosition(center)
            try? await Task.sleep(nanoseconds: 30_000_000)
            anchor = center
        }
        let dir = direction.lowercased()
        let delta = Int32(min(max(amount, 1.0), 10_000.0))
        let dy: Int32
        let dx: Int32
        switch dir {
        case "up":    dy =  delta; dx = 0
        case "down":  dy = -delta; dx = 0
        case "left":  dy = 0;      dx =  delta
        case "right": dy = 0;      dx = -delta
        default:
            throw NativeAppError.axActionFailed(action: "scroll(\(direction))", code: -1)
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

    func focus(query: String) async throws -> [String: Any] {
        guard let pid = runningPid else { throw NativeAppError.notRunning }
        let app = AXUIElementCreateApplication(pid)
        guard let match = Self.findFirst(in: app, matching: query.lowercased()) else {
            throw NativeAppError.elementNotFound(query: query)
        }
        let res = AXUIElementSetAttributeValue(match.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if res != .success {
            throw NativeAppError.axActionFailed(action: "setFocused", code: res.rawValue)
        }
        return ["query": query, "match": match.summary]
    }

    /// Send a chord like `"cmd+s"` to the bound app. Activates the app first
    /// so the OS routes the event there even if a different app is frontmost
    /// — important when Claude is sending shortcuts while the user is
    /// looking elsewhere.
    func sendKey(_ chord: String) async throws -> [String: Any] {
        guard let pid = runningPid else { throw NativeAppError.notRunning }
        // Activate the bound app so keystrokes land in its key window.
        // Without this, `cmd+s` while the user has the bridge popover
        // focused would save the popover, not Slack/Notion/etc.
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
        // Tiny settle so the activate() takes effect before the keystroke.
        try? await Task.sleep(nanoseconds: 30_000_000)
        guard let parsed = Self.parseKeys(chord) else {
            throw NativeAppError.axActionFailed(action: "parseKey(\(chord))", code: -1)
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: false) else {
            throw NativeAppError.axActionFailed(action: "createKeyEvent(\(chord))", code: -1)
        }
        down.flags = parsed.modifiers
        up.flags = parsed.modifiers
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return ["chord": chord, "keyCode": Int(parsed.keyCode), "modifiers": parsed.modifiers.rawValue]
    }

    func pressReturn() async throws -> [String: Any] {
        return try await sendKey("return")
    }

    /// Synthesize a click at `point`. Saves and restores the user's real
    /// cursor so gestures don't leave it stranded over the bound app.
    private func cgClick(at point: CGPoint, button: CGMouseButton = .left, clickState: Int64 = 1) {
        let originalBL = NSEvent.mouseLocation
        CGWarpMouseCursorPosition(point)
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
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let restoreTL = CGPoint(x: originalBL.x, y: primaryHeight - originalBL.y)
        CGWarpMouseCursorPosition(restoreTL)
    }

    // MARK: - AX helpers

    /// Focused window of `app`, or first window as fallback. Throws if the
    /// app has no windows at all (rare, but happens during launch / when the
    /// user has closed every window without quitting the app).
    private func focusedOrFirstWindow(of app: AXUIElement) throws -> AXUIElement {
        var focusedRef: CFTypeRef?
        let res = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRef)
        if res == .success, let focused = AXSafety.element(focusedRef) {
            return focused
        }
        var windowsRef: CFTypeRef?
        let r2 = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard r2 == .success, let arr = windowsRef as? [AXUIElement], let first = arr.first else {
            throw NativeAppError.noWindow
        }
        return first
    }

    private func pngData(from image: CGImage) throws -> Data {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NativeAppError.imageEncodingFailed
        }
        return data
    }

    // MARK: - AX walking (static — no actor isolation needed)

    private struct AXMatch {
        let element: AXUIElement
        let summary: [String: Any]
    }

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

    // MARK: - Chord parser (mirror of MacAppAdapter)

    /// Parse `"cmd+shift+t"` → (CGEventFlags, virtual key code). Returns nil
    /// for unrecognized tokens. Tokens separated by `+` or `-`.
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
                keyToken = tok
            }
        }
        guard let key = keyToken, let code = keyCodeFor(key) else { return nil }
        return (flags, code)
    }

    private static func keyCodeFor(_ token: String) -> CGKeyCode? {
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
}

enum NativeAppError: Error, LocalizedError {
    case notRunning
    case noWindow
    case noFocusedElement
    case elementNotFound(query: String)
    case axActionFailed(action: String, code: Int32)
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .notRunning: return "Bound app is not running. Re-bind from the Bridge menu bar."
        case .noWindow: return "No on-screen window for the bound app."
        case .noFocusedElement: return "No focused AX element."
        case .elementNotFound(let q): return "No AX element matched query: \(q)"
        case .axActionFailed(let a, let c): return "AX action '\(a)' failed (code \(c))"
        case .imageEncodingFailed: return "Failed to encode screenshot as PNG"
        }
    }
}
