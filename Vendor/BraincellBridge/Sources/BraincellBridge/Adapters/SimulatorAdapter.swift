import Foundation
import AppKit

/// iOS Simulator adapter. Drives a single booted simulator (identified
/// by UDID) via `xcrun simctl` subprocesses. Phase 5.2 first slice — no
/// tap/swipe/AX-tree yet (those require Facebook idb or private
/// XCUITest APIs); v1 covers screenshot, launch/terminate, openurl,
/// install/uninstall, push notifications, appearance toggle.
///
/// Pattern matches `MacAppAdapter`: each public method awaits a
/// short-lived Process invocation off-main, returns a structured dict
/// that round-trips through MCP. No persistent state in the adapter
/// itself — the simulator is owned by Simulator.app, not by the bridge.
@MainActor
final class SimulatorAdapter: TargetAdapter {
    /// TargetAdapter conformance: anchor to the Simulator.app pid (shared
    /// across all booted sims). Queried fresh — the user can quit + relaunch
    /// Simulator.app outside the bridge between calls. Nil if Simulator.app
    /// isn't running, which means our bound sim isn't reachable either.
    var anchorPid: pid_t? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.apple.iphonesimulator" }?
            .processIdentifier
    }

    /// TargetAdapter conformance: alias for `targetWindowFrame()`.
    func windowFrame() -> CGRect? { targetWindowFrame() }

    /// TargetAdapter conformance: invalidate the state-watcher Timer. We
    /// don't shut down the user's actual simulator — they own it.
    /// Idempotent (already-invalidated calls are no-ops).
    func shutdown() async {
        stateWatcher?.invalidate()
        stateWatcher = nil
    }

    let udid: String

    /// Fires when the simulator we're bound to shuts down (or the
    /// Simulator app quits). Wired in BridgeAppDelegate to call
    /// `unbindSession`, matching the Chrome + Mac App lifecycle policy
    /// (target dies → binding dies → `+` reappears for fresh re-bind).
    var onTerminated: (() -> Void)?

    private var stateWatcher: Timer?

    init(udid: String) {
        self.udid = udid
        startStateWatcher()
    }

    deinit {
        stateWatcher?.invalidate()
    }

    // MARK: - Tools

    /// PNG screenshot of the simulator's current screen. Uses
    /// `simctl io <udid> screenshot --type=png -` (output to stdout) so
    /// we don't litter /tmp with files.
    func screenshot() async throws -> Data {
        let result = try await runSimctl(
            ["io", udid, "screenshot", "--type=png", "-"],
            captureBinary: true
        )
        guard !result.stdoutData.isEmpty else {
            throw SimulatorError.simctlFailed(
                exitCode: result.exitCode,
                stderr: String(data: result.stderrData, encoding: .utf8) ?? ""
            )
        }
        return result.stdoutData
    }

    /// Launch an app by bundle id. Returns the launched pid (parsed from
    /// simctl's stdout: "BundleId: PID").
    func launch(bundleId: String, args: [String] = []) async throws -> [String: Any] {
        var cmd = ["launch", udid, bundleId]
        cmd.append(contentsOf: args)
        let result = try await runSimctl(cmd, captureBinary: false)
        let stdout = String(data: result.stdoutData, encoding: .utf8) ?? ""
        let pid = Self.parseLaunchPid(from: stdout)
        if result.exitCode != 0 {
            let stderr = String(data: result.stderrData, encoding: .utf8) ?? ""
            throw SimulatorError.simctlFailed(exitCode: result.exitCode, stderr: stderr)
        }
        return ["bundleId": bundleId, "pid": pid as Any, "stdout": stdout]
    }

    /// Force-quit an app by bundle id.
    func terminate(bundleId: String) async throws -> [String: Any] {
        let result = try await runSimctl(["terminate", udid, bundleId], captureBinary: false)
        if result.exitCode != 0 {
            let stderr = String(data: result.stderrData, encoding: .utf8) ?? ""
            throw SimulatorError.simctlFailed(exitCode: result.exitCode, stderr: stderr)
        }
        return ["bundleId": bundleId, "terminated": true]
    }

    /// Open a URL inside the simulator. Routes to the appropriate handler
    /// (Safari for http(s), other apps for custom schemes).
    func openurl(_ url: String) async throws -> [String: Any] {
        let result = try await runSimctl(["openurl", udid, url], captureBinary: false)
        if result.exitCode != 0 {
            let stderr = String(data: result.stderrData, encoding: .utf8) ?? ""
            throw SimulatorError.simctlFailed(exitCode: result.exitCode, stderr: stderr)
        }
        return ["url": url, "opened": true]
    }

    /// Install a `.app` bundle into the simulator. `path` is the host-side
    /// path to the .app directory.
    func install(appPath: String) async throws -> [String: Any] {
        let result = try await runSimctl(["install", udid, appPath], captureBinary: false)
        if result.exitCode != 0 {
            let stderr = String(data: result.stderrData, encoding: .utf8) ?? ""
            throw SimulatorError.simctlFailed(exitCode: result.exitCode, stderr: stderr)
        }
        return ["appPath": appPath, "installed": true]
    }

    /// Uninstall an app by bundle id.
    func uninstall(bundleId: String) async throws -> [String: Any] {
        let result = try await runSimctl(["uninstall", udid, bundleId], captureBinary: false)
        if result.exitCode != 0 {
            let stderr = String(data: result.stderrData, encoding: .utf8) ?? ""
            throw SimulatorError.simctlFailed(exitCode: result.exitCode, stderr: stderr)
        }
        return ["bundleId": bundleId, "uninstalled": true]
    }

    /// Set system appearance (iOS 17+). `mode` is "light" or "dark".
    func setAppearance(_ mode: String) async throws -> [String: Any] {
        let normalized = mode.lowercased()
        guard ["light", "dark"].contains(normalized) else {
            throw SimulatorError.invalidArgument(
                "appearance mode must be 'light' or 'dark', got '\(mode)'"
            )
        }
        let result = try await runSimctl(["ui", udid, "appearance", normalized], captureBinary: false)
        if result.exitCode != 0 {
            let stderr = String(data: result.stderrData, encoding: .utf8) ?? ""
            throw SimulatorError.simctlFailed(exitCode: result.exitCode, stderr: stderr)
        }
        return ["mode": normalized, "applied": true]
    }

    /// Push a JSON payload to a bundle id (silent or alert). `payloadJson`
    /// is a string the caller should hand-construct or load.
    func sendPush(bundleId: String, payloadJson: String) async throws -> [String: Any] {
        // simctl push needs a file path, not stdin. Drop the JSON to a
        // temp file, push, delete.
        let tmp = NSTemporaryDirectory() + "sim-push-\(UUID().uuidString).json"
        try payloadJson.write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let result = try await runSimctl(
            ["push", udid, bundleId, tmp], captureBinary: false
        )
        if result.exitCode != 0 {
            let stderr = String(data: result.stderrData, encoding: .utf8) ?? ""
            throw SimulatorError.simctlFailed(exitCode: result.exitCode, stderr: stderr)
        }
        return ["bundleId": bundleId, "pushed": true]
    }

    /// Current state of the bound simulator: Booted / Shutdown / etc.
    /// Useful for sanity check + binding-died detection.
    func currentState() async throws -> [String: Any] {
        let result = try await runSimctl(["list", "devices", "-j"], captureBinary: true)
        guard let stdout = String(data: result.stdoutData, encoding: .utf8),
              let json = stdout.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let devicesByRuntime = parsed["devices"] as? [String: Any] else {
            return ["udid": udid, "state": "unknown"]
        }
        for (_, devices) in devicesByRuntime {
            guard let arr = devices as? [[String: Any]] else { continue }
            for dev in arr {
                if (dev["udid"] as? String) == udid {
                    return [
                        "udid": udid,
                        "name": dev["name"] as? String ?? "",
                        "state": dev["state"] as? String ?? "unknown",
                        "deviceTypeIdentifier": dev["deviceTypeIdentifier"] as? String ?? ""
                    ]
                }
            }
        }
        return ["udid": udid, "state": "not_found"]
    }

    // MARK: - Window anchor (for native cursor overlay later)

    /// Frame of the Simulator.app window currently showing this UDID.
    /// Top-left CG screen coords. Returns nil if Simulator isn't running
    /// or no matching window is on screen. Used by overlay controllers
    /// to anchor cursor + screenshot rect against the simulator's frame.
    func targetWindowFrame() -> CGRect? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // Multi-sim disambiguation: when 2+ simulators are booted they're
        // ALL children of the same Simulator.app process, so we can't tell
        // them apart by pid. Simulator titles each window with the device
        // name (e.g. "iPhone 15 Pro — iOS 17.5") + the kCGWindowName surfaces
        // that title (Screen Recording permission required for window
        // titles on Sonoma+; without it, names are nil and we fall back to
        // first-Simulator-window which is the v1 behavior).
        //
        // `boundDeviceName` is captured at bind time via NSNotification or
        // the sim's currentState; matching kCGWindowName against it picks
        // the right window.
        var fallback: CGRect?
        for w in list {
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            guard owner == "Simulator" else { continue }
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            guard layer == 0 else { continue }
            guard let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  width > 200, height > 200 else { continue }
            let frame = CGRect(x: x, y: y, width: width, height: height)
            // Title-match if we know the device name. Simulator window
            // titles are like "iPhone 15 Pro — iOS 17.5" — substring match
            // against the bound device name picks the right window.
            if let name = boundDeviceName, !name.isEmpty,
               let title = w[kCGWindowName as String] as? String, !title.isEmpty {
                if title.localizedStandardContains(name) {
                    return frame
                }
            } else if fallback == nil {
                // No name to match (or no window-title permission) — keep the
                // first valid window as last-resort fallback.
                fallback = frame
            }
        }
        return fallback
    }

    /// Cached device name captured at bind time (e.g. "iPhone 15 Pro").
    /// Populated by `lockToBoundWindow()` so the wire/cursor anchors to
    /// THIS sim's window when 2+ sims are booted concurrently.
    private var boundDeviceName: String?

    /// Resolve the sim's device name (via simctl list) and cache it for
    /// `targetWindowFrame` to match against window titles. Called by
    /// `BridgeAppDelegate.bindSessionToSimulator` right after constructing
    /// the adapter. Idempotent — safe to call again if the sim's name
    /// changes (rare).
    func lockToBoundWindow() async {
        guard let state = try? await currentState(),
              let name = state["name"] as? String, !name.isEmpty else { return }
        boundDeviceName = name
        NSLog("[SimulatorAdapter] bound to device name '%@' for window-title disambiguation", name)
    }

    // MARK: - Coord translation

    /// Convert a host-screen point (top-left CG screen coords) to the
    /// simulator's logical-point viewport coords (the device's UIKit
    /// coordinate space — what `idb ui tap` expects).
    ///
    /// Strategy:
    ///   1. Locate the Simulator window frame on screen.
    ///   2. Strip the title bar (~28pt) — the device-screen subview
    ///      starts below it. We don't probe AX for a tighter rect in v1;
    ///      future work can sharpen this.
    ///   3. Read the device's logical viewport size from `currentState()`'s
    ///      deviceTypeIdentifier (cached lookup table for common devices),
    ///      then scale screen→viewport by deviceFrame size.
    ///
    /// Returns nil if the Simulator window isn't on screen for this UDID
    /// or if the point falls outside the device area.
    func screenToViewport(_ p: CGPoint) async -> CGPoint? {
        guard let frame = targetWindowFrame() else { return nil }
        let titleBar: CGFloat = 28
        let deviceFrame = CGRect(
            x: frame.minX, y: frame.minY + titleBar,
            width: frame.width, height: frame.height - titleBar
        )
        // Reject clearly-out-of-bounds points; clamp gentle slop.
        guard deviceFrame.contains(p) else {
            // Allow ±4pt slop for AI-driven gestures aimed at hot edges.
            let inset = deviceFrame.insetBy(dx: -4, dy: -4)
            guard inset.contains(p) else { return nil }
            return nil
        }
        // Get the device's logical viewport size. Default to a sensible
        // iPhone if we can't resolve it.
        let logicalSize = await deviceLogicalSize() ?? CGSize(width: 393, height: 852)
        let xRatio = (p.x - deviceFrame.minX) / deviceFrame.width
        let yRatio = (p.y - deviceFrame.minY) / deviceFrame.height
        return CGPoint(
            x: logicalSize.width * xRatio,
            y: logicalSize.height * yRatio
        )
    }

    /// Lookup table for common device types → logical (UIKit point) size.
    /// idb takes coords in this space. We look up by deviceTypeIdentifier;
    /// unknown devices fall back to nil and the caller substitutes a
    /// default. Future: enumerate via `simctl list devicetypes -j` once
    /// per adapter init.
    private static let deviceLogicalSizes: [String: CGSize] = [
        // iPhones (modern)
        "com.apple.CoreSimulator.SimDeviceType.iPhone-15": CGSize(width: 393, height: 852),
        "com.apple.CoreSimulator.SimDeviceType.iPhone-15-Plus": CGSize(width: 430, height: 932),
        "com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro": CGSize(width: 393, height: 852),
        "com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro-Max": CGSize(width: 430, height: 932),
        "com.apple.CoreSimulator.SimDeviceType.iPhone-16": CGSize(width: 393, height: 852),
        "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Plus": CGSize(width: 430, height: 932),
        "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro": CGSize(width: 402, height: 874),
        "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro-Max": CGSize(width: 440, height: 956),
        "com.apple.CoreSimulator.SimDeviceType.iPhone-14": CGSize(width: 390, height: 844),
        "com.apple.CoreSimulator.SimDeviceType.iPhone-14-Plus": CGSize(width: 428, height: 926),
        "com.apple.CoreSimulator.SimDeviceType.iPhone-14-Pro": CGSize(width: 393, height: 852),
        "com.apple.CoreSimulator.SimDeviceType.iPhone-14-Pro-Max": CGSize(width: 430, height: 932),
        "com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation": CGSize(width: 375, height: 667),
        // iPads
        "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4-8GB": CGSize(width: 834, height: 1194),
        "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB": CGSize(width: 1024, height: 1366),
        "com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M2": CGSize(width: 820, height: 1180),
        "com.apple.CoreSimulator.SimDeviceType.iPad-mini-A17-Pro": CGSize(width: 744, height: 1133),
    ]

    private func deviceLogicalSize() async -> CGSize? {
        let state = try? await currentState()
        let id = (state?["deviceTypeIdentifier"] as? String) ?? ""
        if let size = Self.deviceLogicalSizes[id] { return size }
        // Heuristic: anything iPad → 820×1180, anything iPhone → 393×852.
        if id.contains("iPad") { return CGSize(width: 820, height: 1180) }
        if id.contains("iPhone") { return CGSize(width: 393, height: 852) }
        return nil
    }

    // MARK: - idb gestures (Phase 5.2)

    /// Single tap at a logical-viewport coord (what idb expects).
    /// `screenPoint` is the host-screen coord we anchored on for the
    /// cursor visual — included in the response purely for diagnostics.
    func tap(viewportX: Double, viewportY: Double, durationSec: Double = 0.05) async throws -> [String: Any] {
        try await ensureIDB()
        let result = try await runIDB([
            "ui", "tap", "--udid", udid, "--duration", String(durationSec),
            String(viewportX), String(viewportY),
        ])
        if result.exitCode != 0 {
            throw SimulatorError.idbFailed(
                exitCode: result.exitCode,
                stderr: String(data: result.stderrData, encoding: .utf8) ?? ""
            )
        }
        return ["x": viewportX, "y": viewportY, "tapped": true]
    }

    /// Double tap: two short taps with ~130ms gap, executed at the same
    /// viewport point. idb has no native double-tap so we issue twice.
    func doubleTap(viewportX: Double, viewportY: Double) async throws -> [String: Any] {
        try await ensureIDB()
        // First tap
        _ = try await runIDB([
            "ui", "tap", "--udid", udid, "--duration", "0.05",
            String(viewportX), String(viewportY),
        ])
        try await Task.sleep(nanoseconds: 130_000_000)
        // Second tap
        let result = try await runIDB([
            "ui", "tap", "--udid", udid, "--duration", "0.05",
            String(viewportX), String(viewportY),
        ])
        if result.exitCode != 0 {
            throw SimulatorError.idbFailed(
                exitCode: result.exitCode,
                stderr: String(data: result.stderrData, encoding: .utf8) ?? ""
            )
        }
        return ["x": viewportX, "y": viewportY, "doubleTapped": true]
    }

    /// Long press: tap with extended duration. Default 0.8s ≈ iOS context
    /// menu threshold.
    func longPress(viewportX: Double, viewportY: Double, durationSec: Double = 0.8) async throws -> [String: Any] {
        try await ensureIDB()
        let result = try await runIDB([
            "ui", "tap", "--udid", udid, "--duration", String(durationSec),
            String(viewportX), String(viewportY),
        ])
        if result.exitCode != 0 {
            throw SimulatorError.idbFailed(
                exitCode: result.exitCode,
                stderr: String(data: result.stderrData, encoding: .utf8) ?? ""
            )
        }
        return ["x": viewportX, "y": viewportY, "duration": durationSec, "longPressed": true]
    }

    /// Swipe from one viewport point to another over `durationSec`.
    /// Used for swipes (fast) and drags (slow). idb's `ui swipe` accepts
    /// `--duration` for the gesture time and `--delta` for the per-step
    /// pixel delta (smaller = smoother).
    func swipe(
        fromX: Double, fromY: Double,
        toX: Double, toY: Double,
        durationSec: Double = 0.25
    ) async throws -> [String: Any] {
        try await ensureIDB()
        let result = try await runIDB([
            "ui", "swipe", "--udid", udid,
            "--duration", String(durationSec),
            String(fromX), String(fromY),
            String(toX), String(toY),
        ])
        if result.exitCode != 0 {
            throw SimulatorError.idbFailed(
                exitCode: result.exitCode,
                stderr: String(data: result.stderrData, encoding: .utf8) ?? ""
            )
        }
        return [
            "from": ["x": fromX, "y": fromY],
            "to": ["x": toX, "y": toY],
            "duration": durationSec,
            "swiped": true,
        ]
    }

    /// Hardware button press. `name` is one of the idb-recognized values:
    /// "HOME", "LOCK", "SIDE_BUTTON", "SIRI", "APPLE_PAY". We accept
    /// loose lower-case input and uppercase before forwarding so AI
    /// callers can pass "home" / "lock" naturally.
    func pressButton(_ name: String) async throws -> [String: Any] {
        try await ensureIDB()
        let normalized = Self.normalizeButtonName(name)
        guard !normalized.isEmpty else {
            throw SimulatorError.invalidArgument(
                "button name must be one of: home, lock, side-button, siri, apple-pay (got '\(name)')"
            )
        }
        let result = try await runIDB([
            "ui", "button", "--udid", udid, normalized,
        ])
        if result.exitCode != 0 {
            throw SimulatorError.idbFailed(
                exitCode: result.exitCode,
                stderr: String(data: result.stderrData, encoding: .utf8) ?? ""
            )
        }
        return ["button": normalized, "pressed": true]
    }

    /// Type literal text into the focused responder. idb sends each
    /// character as a key press through the simulator's keyboard. Caller
    /// is responsible for focusing a text field first (via tap).
    func typeText(_ text: String) async throws -> [String: Any] {
        try await ensureIDB()
        let result = try await runIDB([
            "ui", "text", "--udid", udid, text,
        ])
        if result.exitCode != 0 {
            throw SimulatorError.idbFailed(
                exitCode: result.exitCode,
                stderr: String(data: result.stderrData, encoding: .utf8) ?? ""
            )
        }
        return ["text": text, "typed": true]
    }

    /// Send a single HID keycode. `keycode` is a USB HID usage code (e.g.
    /// 40 = Return, 42 = Backspace, 41 = Escape).
    func pressKey(_ keycode: Int) async throws -> [String: Any] {
        try await ensureIDB()
        let result = try await runIDB([
            "ui", "key", "--udid", udid, String(keycode),
        ])
        if result.exitCode != 0 {
            throw SimulatorError.idbFailed(
                exitCode: result.exitCode,
                stderr: String(data: result.stderrData, encoding: .utf8) ?? ""
            )
        }
        return ["keycode": keycode, "pressed": true]
    }

    /// Send a sequence of HID keycodes (e.g. for chords or rapid input).
    func pressKeySequence(_ keycodes: [Int]) async throws -> [String: Any] {
        try await ensureIDB()
        var args = ["ui", "key-sequence", "--udid", udid]
        args.append(contentsOf: keycodes.map { String($0) })
        let result = try await runIDB(args)
        if result.exitCode != 0 {
            throw SimulatorError.idbFailed(
                exitCode: result.exitCode,
                stderr: String(data: result.stderrData, encoding: .utf8) ?? ""
            )
        }
        return ["keycodes": keycodes, "pressed": true]
    }

    // MARK: - AX tree introspection (idb describe-all)

    /// Get the full iOS AX tree as nested dicts via `idb ui describe-all`.
    /// describe-all is ~200-500ms so callers should avoid duplicate
    /// invocations within the same dispatch. Internal helper for the
    /// find_element / wait_for / list_interactive / get_element family.
    private func describeAll() async throws -> [[String: Any]] {
        try await ensureIDB()
        let result = try await runIDB(["ui", "describe-all", "--udid", udid, "--json"])
        if result.exitCode != 0 {
            throw SimulatorError.idbFailed(
                exitCode: result.exitCode,
                stderr: String(data: result.stderrData, encoding: .utf8) ?? ""
            )
        }
        guard let parsed = try JSONSerialization.jsonObject(with: result.stdoutData) as? [[String: Any]] else {
            throw SimulatorError.invalidArgument("idb describe-all returned non-array JSON")
        }
        return parsed
    }

    /// Recursively flatten the AX tree into a single list of node dicts.
    /// `subviews` keys are stripped from each (the flattener already
    /// captured them). Each node retains everything else.
    private static func flattenAXTree(_ nodes: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var stack: [[String: Any]] = nodes
        while let node = stack.popLast(), out.count < 20_000 {
            var copy = node
            if let kids = copy.removeValue(forKey: "subviews") as? [[String: Any]] {
                let remaining = max(0, 20_000 - out.count - stack.count)
                stack.append(contentsOf: kids.prefix(remaining))
            }
            out.append(copy)
        }
        return out
    }

    /// Substring match against AXLabel / AXValue / type / title / help / AXUniqueId.
    private static func matches(_ node: [String: Any], _ needle: String) -> Bool {
        let fields = ["AXLabel", "AXValue", "type", "title", "help", "AXUniqueId"]
        for field in fields {
            if let s = node[field] as? String, s.lowercased().contains(needle) {
                return true
            }
        }
        return false
    }

    /// Find ALL elements matching `query` via idb describe-all + substring
    /// match. Returns array of node dicts (all fields idb provides).
    func findElement(query: String) async throws -> [[String: Any]] {
        let needle = query.lowercased()
        let tree = try await describeAll()
        let flat = Self.flattenAXTree(tree)
        return flat.filter { Self.matches($0, needle) }
    }

    /// Poll findElement every 250ms until at least one match or `timeout`
    /// elapses. Throws elementNotFound on timeout.
    func waitForElement(query: String, timeout: Double = 5.0) async throws -> [String: Any] {
        let safeTimeout = timeout.isFinite ? min(max(timeout, 0), 120) : 5
        let deadline = Date().addingTimeInterval(safeTimeout)
        while Date() < deadline {
            if let first = (try? await findElement(query: query))?.first {
                return ["query": query, "found": true, "match": first]
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw SimulatorError.elementNotFound(
            query: "wait_for(\(query)) timed out after \(safeTimeout)s")
    }

    /// Enumerate interactive iOS UI elements. Optional `type` filter narrows.
    func listInteractive(type: String? = nil) async throws -> [[String: Any]] {
        let interactive: Set<String> = [
            "Button", "TextField", "SecureTextField",
            "Link", "Switch", "Cell", "MenuItem", "Tab", "Slider",
        ]
        let tree = try await describeAll()
        let flat = Self.flattenAXTree(tree)
        return flat.filter { node in
            guard let t = node["type"] as? String, interactive.contains(t) else { return false }
            if let filter = type, t != filter { return false }
            return true
        }.prefix(5_000).map { $0 }
    }

    /// Single-element detail for the first match of `query`. Same shape as
    /// findElement but returns the first match unwrapped.
    func getElement(query: String) async throws -> [String: Any] {
        let matches = try await findElement(query: query)
        guard let first = matches.first else {
            throw SimulatorError.elementNotFound(query: query)
        }
        return first
    }

    private static func normalizeButtonName(_ raw: String) -> String {
        let lower = raw.lowercased().replacingOccurrences(of: "-", with: "_")
        switch lower {
        case "home", "home2x": return "HOME"
        case "lock": return "LOCK"
        case "side", "side_button", "sidebutton": return "SIDE_BUTTON"
        case "siri": return "SIRI"
        case "apple_pay", "applepay", "pay": return "APPLE_PAY"
        default: return ""
        }
    }

    // MARK: - idb runner

    private struct IDBResult {
        let exitCode: Int32
        let stdoutData: Data
        let stderrData: Data
    }

    /// Resolved path to the `idb` CLI, or nil if not installed. Cached to
    /// avoid a `which` per call. Set by the first `ensureIDB()` invocation.
    private static var resolvedIDBPath: String? = nil
    private static var idbDetectionDone: Bool = false

    /// Probe for idb at startup (or first use). Logs an instruction once
    /// when missing. Subsequent gesture tools throw `idbNotInstalled` so
    /// Claude sees a usable error message.
    static func idbAvailable() async -> Bool {
        if idbDetectionDone { return resolvedIDBPath != nil }
        // Walk a small set of known install locations + PATH-resolved
        // `which idb`. We can't trust the bridge's PATH (NSStatusItem app
        // launched from Finder has a minimal env), so check absolute
        // paths first.
        let candidates = [
            "/opt/homebrew/bin/idb",
            "/usr/local/bin/idb",
            "/Users/\(NSUserName())/.local/bin/idb",
        ]
        for p in candidates {
            if FileManager.default.isExecutableFile(atPath: p) {
                resolvedIDBPath = p
                idbDetectionDone = true
                NSLog("[SimulatorAdapter] idb detected at %@", p)
                return true
            }
        }
        // Fall back to `/usr/bin/which idb` in a login shell so PATH
        // gets populated from .zshrc / .bash_profile.
        guard let captured = try? await BridgeProcessCapture.runAsync(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-l", "-c", "which idb"],
            timeout: 5,
            stdoutLimit: 16 * 1024,
            stderrLimit: 16 * 1024) else {
            idbDetectionDone = true
            logIDBMissing()
            return false
        }
        let path = String(decoding: captured.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if captured.terminationStatus == 0, !path.isEmpty,
           FileManager.default.isExecutableFile(atPath: path) {
            resolvedIDBPath = path
            idbDetectionDone = true
            NSLog("[SimulatorAdapter] idb detected at %@", path)
            return true
        }
        idbDetectionDone = true
        logIDBMissing()
        return false
    }

    private static func logIDBMissing() {
        NSLog("[SimulatorAdapter] idb not found. iOS gesture tools (sim_tap, sim_swipe, sim_button, sim_text, sim_key) will be unavailable. Install with: brew tap facebook/fb && brew install idb-companion && pip3 install fb-idb")
    }

    private func ensureIDB() async throws {
        if Self.resolvedIDBPath == nil {
            _ = await Self.idbAvailable()
        }
        if Self.resolvedIDBPath == nil {
            throw SimulatorError.idbNotInstalled
        }
    }

    private func runIDB(_ args: [String]) async throws -> IDBResult {
        guard let path = Self.resolvedIDBPath else {
            throw SimulatorError.idbNotInstalled
        }
        let captured = try await BridgeProcessCapture.runAsync(
            executable: URL(fileURLWithPath: path),
            arguments: args,
            timeout: 120,
            stdoutLimit: 32 * 1024 * 1024,
            stderrLimit: 4 * 1024 * 1024)
        return IDBResult(
            exitCode: captured.terminationStatus,
            stdoutData: captured.stdout,
            stderrData: captured.stderr)
    }

    // MARK: - State watcher

    /// Poll the simulator's state every 5s. If it transitions to anything
    /// other than Booted (Shutdown, Booting, Creating, etc.), fire
    /// onTerminated so the binding gets cleaned up.
    private func startStateWatcher() {
        stateWatcher = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let state = (try? await self.currentState())?["state"] as? String ?? ""
                if state != "Booted" && !state.isEmpty {
                    NSLog("[SimulatorAdapter] %@ state=%@; firing onTerminated", self.udid, state)
                    self.stateWatcher?.invalidate()
                    self.stateWatcher = nil
                    self.onTerminated?()
                }
            }
        }
    }

    // MARK: - simctl runner

    private struct SimctlResult {
        let exitCode: Int32
        let stdoutData: Data
        let stderrData: Data
    }

    private func runSimctl(_ args: [String], captureBinary: Bool) async throws -> SimctlResult {
        let captured = try await BridgeProcessCapture.runAsync(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl"] + args,
            timeout: 120,
            stdoutLimit: captureBinary ? 64 * 1024 * 1024 : 4 * 1024 * 1024,
            stderrLimit: 4 * 1024 * 1024)
        return SimctlResult(
            exitCode: captured.terminationStatus,
            stdoutData: captured.stdout,
            stderrData: captured.stderr)
    }

    // MARK: - Static helpers

    /// Enumerate currently booted simulators. Used by the bind picker
    /// (when it lands) and for diagnostic reads via curl.
    static func listBooted() async -> [[String: Any]] {
        guard let captured = try? await BridgeProcessCapture.runAsync(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "list", "devices", "booted", "-j"],
            timeout: 30,
            stdoutLimit: 4 * 1024 * 1024,
            stderrLimit: 1_048_576),
              let parsed = try? JSONSerialization.jsonObject(
                with: captured.stdout) as? [String: Any],
              let devicesByRuntime = parsed["devices"] as? [String: Any] else {
            return []
        }
        var booted: [[String: Any]] = []
        for (runtime, devices) in devicesByRuntime {
            guard let arr = devices as? [[String: Any]] else { continue }
            for dev in arr where (dev["state"] as? String) == "Booted" {
                var d = dev
                d["runtime"] = runtime
                booted.append(d)
            }
        }
        return booted
    }

    /// Parse "<bundleId>: <pid>" from `simctl launch` output. Returns nil
    /// if the format isn't recognized (older Xcode versions vary).
    private static func parseLaunchPid(from stdout: String) -> Int? {
        for line in stdout.split(separator: "\n") {
            let parts = line.split(separator: ":")
            if parts.count >= 2, let pid = Int(parts.last!.trimmingCharacters(in: .whitespaces)) {
                return pid
            }
        }
        return nil
    }
}

enum SimulatorError: LocalizedError {
    case simctlFailed(exitCode: Int32, stderr: String)
    case invalidArgument(String)
    case notBooted(udid: String)
    case idbNotInstalled
    case idbFailed(exitCode: Int32, stderr: String)
    case simulatorWindowOffscreen
    case elementNotFound(query: String)

    var errorDescription: String? {
        switch self {
        case .simctlFailed(let code, let err):
            let trimmed = err.trimmingCharacters(in: .whitespacesAndNewlines)
            return "simctl exited \(code): \(trimmed)"
        case .invalidArgument(let msg): return msg
        case .notBooted(let udid): return "Simulator \(udid) is not booted"
        case .idbNotInstalled:
            return "idb is not installed. iOS gesture tools require Facebook idb. Install: `brew tap facebook/fb && brew install idb-companion && pip3 install fb-idb`, then restart the bridge."
        case .idbFailed(let code, let err):
            let trimmed = err.trimmingCharacters(in: .whitespacesAndNewlines)
            return "idb exited \(code): \(trimmed)"
        case .simulatorWindowOffscreen:
            return "Simulator window not visible on screen. Bring Simulator.app to the foreground and try again."
        case .elementNotFound(let q): return "Element not found in simulator: \(q)"
        }
    }
}
