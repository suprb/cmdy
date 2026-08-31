import AppKit
import CoreGraphics
import ScreenCaptureKit
import ApplicationServices
import CmdySDK

// DockAPI — the agent↔app layer. Same contract as the chromium browser API
// (POST /execute {tool, arguments} → {result}|{error}; discovery file with a
// bearer token), but the tools drive a FOREIGN native app through
// Accessibility instead of an owned browser:
//
//   lifecycle : dock, launch, relaunch, undock, info
//   inspect   : ax_tree, ax_find, screenshot, logs
//   drive     : ax_click, ax_type, ax_focus, key
//
// The dev loop for an agent building an app: launch (captures stdout/stderr),
// edit the source itself, relaunch, screenshot / read logs, ax_click to
// exercise it — the live thing, beside the conversation.

enum DockAPIError: LocalizedError {
    case missingParam(String)
    case noTarget
    case notTrusted
    case badPath(String)
    case launchFailed(String)
    case screenshotFailed(String)
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .missingParam(let p): return "missing parameter: \(p)"
        case .noTarget: return "no app is docked — call dock or launch first"
        case .notTrusted: return "appdock needs the Accessibility permission (System Settings ▸ Privacy ▸ Accessibility)"
        case .badPath(let p): return "no element at path \(p) — re-read ax_tree (the tree shifts as the UI changes)"
        case .launchFailed(let m): return "launch failed: \(m)"
        case .screenshotFailed(let m): return "screenshot failed: \(m)"
        case .unknownTool(let t): return "unknown tool: \(t)"
        }
    }
}

final class DockAPI: @unchecked Sendable {
    // Installed by main.swift; run on the main thread.
    /// Adopt a pid's window into the strip; returns the target pid or nil.
    var dockPid: ((pid_t) -> Bool)?
    /// Release the current target, restoring its frame.
    var undock: (() -> Void)?
    /// The currently docked pid + its AX window, if any.
    var currentTarget: (() -> (pid: pid_t, window: AXUIElement)?)?
    /// Show the strip window on screen for a capture; returns nothing (we
    /// screenshot the target app's window directly by its number).
    var beforeScreenshot: (() -> Void)?

    private let server = DockHTTPServer()
    var port: Int { server.port }

    /// Child processes we launched, by pid — their captured output feeds `logs`.
    private var launched: [pid_t: LaunchedProcess] = [:]
    private let launchLock = NSLock()

    static let discoveryURL = HostProductIdentity.configurationDirectory
        .appendingPathComponent("appdock-api.json")

    final class LaunchedProcess {
        let process: Process
        var output = Data()
        let lock = NSLock()
        init(_ p: Process) { process = p }
        func append(_ d: Data) {
            lock.lock()
            output.append(d)
            if output.count > 400_000 {
                output.removeFirst(output.count - 400_000)
            }
            lock.unlock()
        }
        func text() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: output, as: UTF8.self) }
    }

    /// Keep NSLock use inside synchronous helpers. Calling lock()/unlock()
    /// directly from an async function is rejected in Swift 6 even when the
    /// critical section contains no suspension.
    private func launchedProcess(for pid: pid_t) -> LaunchedProcess? {
        launchLock.lock()
        defer { launchLock.unlock() }
        return launched[pid]
    }

    private func remember(_ process: LaunchedProcess, for pid: pid_t) {
        launchLock.lock()
        launched[pid] = process
        launchLock.unlock()
    }

    // MARK: - Lifecycle

    func start() {
        let preferred = HostProductIdentity.environmentValue("APPDOCK_PORT")
            .flatMap(UInt16.init) ?? 4690
        guard server.start(preferredPort: preferred) else {
            NSLog("appdock: API failed to bind near %d", Int(preferred)); return
        }
        server.handler = { [weak self] request, respond in
            guard let self else { respond(503, ["error": "shutting down"]); return }
            self.route(request, respond)
        }
        writeDiscoveryFile()
        NSLog("appdock: API listening on 127.0.0.1:%d", server.port)
    }

    func stop() {
        server.stop()
        try? FileManager.default.removeItem(at: Self.discoveryURL)
    }

    private func writeDiscoveryFile() {
        let info: [String: Any] = ["port": server.port, "token": server.authToken,
                                   "api": "appdock-v1", "pid": Int(getpid())]
        if let data = try? JSONSerialization.data(withJSONObject: info) {
            try? FileManager.default.createDirectory(
                at: Self.discoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.discoveryURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: Self.discoveryURL.path)
        }
    }

    // MARK: - Routing

    private func route(_ request: DockHTTPServer.Request, _ respond: @escaping (Int, Any) -> Void) {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            respond(200, ["status": "ok",
                          "app": "\(HostProductIdentity.slug)-appdock",
                          "api": "appdock-v1",
                          "port": server.port, "trusted": AXKit.trusted(prompt: false)])
        case ("POST", "/execute"):
            guard let json = request.json, let tool = json["tool"] as? String else {
                respond(400, ["error": "expected {\"tool\": …, \"arguments\": {…}}"]); return
            }
            let arguments = json["arguments"] as? [String: Any] ?? [:]
            Task { @MainActor in
                do { respond(200, ["result": try await self.execute(tool: tool, arguments: arguments)]) }
                catch { respond(200, ["error": error.localizedDescription]) }
            }
        default:
            respond(404, ["error": "no route for \(request.method) \(request.path)"])
        }
    }

    // MARK: - Tools

    @MainActor
    func execute(tool: String, arguments args: [String: Any]) async throws -> Any {
        switch tool {
        case "info":
            let trusted = AXKit.trusted(prompt: false)
            guard let target = currentTarget?() else {
                return ["docked": false, "trusted": trusted]
            }
            let app = NSRunningApplication(processIdentifier: target.pid)
            var d: [String: Any] = ["docked": true, "trusted": trusted, "pid": Int(target.pid),
                                    "app": app?.localizedName ?? "?"]
            if let f = AXKit.frame(of: target.window) {
                d["frame"] = ["x": Int(f.origin.x), "y": Int(f.origin.y), "w": Int(f.width), "h": Int(f.height)]
            }
            return d

        case "dock":
            // Adopt an already-running app, by pid or bundle-id/name.
            let pid = try resolvePid(args)
            guard AXKit.trusted(prompt: true) else { throw DockAPIError.notTrusted }
            guard dockPid?(pid) == true else { throw DockAPIError.launchFailed("no window for pid \(pid) yet") }
            return ["success": true, "pid": Int(pid)]

        case "launch":
            return try await launch(args)

        case "relaunch":
            guard let target = currentTarget?() else { throw DockAPIError.noTarget }
            let bundleURL = NSRunningApplication(processIdentifier: target.pid)?.bundleURL
            if let prior = launchedProcess(for: target.pid),
               let command = prior.process.executableURL {
                // We launched it — restart the same command, recapture output.
                let cmdArgs = prior.process.arguments ?? []
                undock?()
                prior.process.terminate()
                return try await launch(["command": command.path, "args": cmdArgs])
            }
            guard let bundleURL else { throw DockAPIError.launchFailed("cannot relaunch — not launched by appdock and no bundle") }
            NSRunningApplication(processIdentifier: target.pid)?.terminate()
            try await Task.sleep(nanoseconds: 400_000_000)
            return try await launch(["bundle": bundleURL.path])

        case "undock":
            undock?()
            return ["success": true]

        case "logs":
            guard let target = currentTarget?() else { throw DockAPIError.noTarget }
            let proc = launchedProcess(for: target.pid)
            guard let proc else { return ["success": true, "logs": "", "note": "app was not launched by appdock — no captured output"] }
            let tail = min(max(args["tail"] as? Int ?? 4000, 0), 400_000)
            let text = proc.text()
            return ["success": true, "logs": String(text.suffix(tail)), "running": proc.process.isRunning]

        case "ax_tree":
            let window = try requireWindow()
            let depth = min(max(args["depth"] as? Int ?? 12, 0), 64)
            let interactiveOnly = args["all"] as? Bool != true
            let nodes = AXKit.tree(window: window, maxDepth: depth, interactiveOnly: interactiveOnly)
            return ["success": true, "count": nodes.count, "nodes": nodes.map(\.dictionary)]

        case "ax_find":
            guard let query = (args["query"] as? String)?.lowercased() else { throw DockAPIError.missingParam("query") }
            let window = try requireWindow()
            let nodes = AXKit.tree(window: window, maxDepth: 16, interactiveOnly: true).filter {
                $0.title.lowercased().contains(query) || $0.value.lowercased().contains(query)
                    || $0.role.lowercased().contains(query)
            }
            return ["success": true, "count": nodes.count, "nodes": nodes.prefix(20).map(\.dictionary)]

        case "ax_click":
            let (window, path) = try requirePath(args)
            guard let el = AXKit.element(in: window, path: path) else { throw DockAPIError.badPath(path) }
            AXKit.raiseIfPossible(currentTarget?()?.window)
            guard AXKit.press(el) else {
                // Not pressable — synthesize a click at its center.
                let node = AXKit.node(for: el, path: path)
                clickAt(CGPoint(x: node.frame.midX, y: node.frame.midY))
                return ["success": true, "clicked": path, "via": "synthetic"]
            }
            return ["success": true, "clicked": path, "via": "AXPress"]

        case "ax_type":
            let (window, path) = try requirePath(args)
            guard let text = args["text"] as? String else { throw DockAPIError.missingParam("text") }
            guard let el = AXKit.element(in: window, path: path) else { throw DockAPIError.badPath(path) }
            _ = AXKit.focus(el)
            if AXKit.setValue(el, text) {
                return ["success": true, "typed": text, "via": "AXValue"]
            }
            typeText(text)   // fields that reject AXValue take synthesized keys
            return ["success": true, "typed": text, "via": "keys"]

        case "ax_focus":
            let (window, path) = try requirePath(args)
            guard let el = AXKit.element(in: window, path: path) else { throw DockAPIError.badPath(path) }
            return ["success": AXKit.focus(el), "focused": path]

        case "key":
            guard let key = args["key"] as? String else { throw DockAPIError.missingParam("key") }
            pressKey(key, modifiers: args["modifiers"] as? [String] ?? [])
            return ["success": true, "key": key]

        case "screenshot":
            return try await screenshot()

        default:
            throw DockAPIError.unknownTool(tool)
        }
    }

    // MARK: - Helpers

    @MainActor
    private func requireWindow() throws -> AXUIElement {
        guard AXKit.trusted(prompt: false) else { throw DockAPIError.notTrusted }
        guard let target = currentTarget?() else { throw DockAPIError.noTarget }
        return target.window
    }

    @MainActor
    private func requirePath(_ args: [String: Any]) throws -> (AXUIElement, String) {
        let window = try requireWindow()
        guard let path = args["path"] as? String else { throw DockAPIError.missingParam("path") }
        return (window, path)
    }

    private func resolvePid(_ args: [String: Any]) throws -> pid_t {
        if let pid = args["pid"] as? Int,
           pid > 0, pid <= Int(Int32.max) {
            return pid_t(pid)
        }
        let apps = NSWorkspace.shared.runningApplications
        if let bundle = args["bundle"] as? String,
           let app = apps.first(where: { $0.bundleIdentifier == bundle }) {
            return app.processIdentifier
        }
        if let name = (args["name"] as? String)?.lowercased(),
           let app = apps.first(where: { ($0.localizedName ?? "").lowercased() == name }) {
            return app.processIdentifier
        }
        throw DockAPIError.missingParam("pid, bundle, or name of a running app")
    }

    /// Launch a bundle (.app) or a bare executable, capture its output, and
    /// dock its window once it appears.
    @MainActor
    private func launch(_ args: [String: Any]) async throws -> Any {
        guard AXKit.trusted(prompt: true) else { throw DockAPIError.notTrusted }
        let process = Process()
        if let bundle = args["bundle"] as? String {
            // Resolve the real executable inside the .app so we own the child.
            let appURL = URL(fileURLWithPath: bundle)
            guard let exec = Bundle(url: appURL)?.executableURL else {
                throw DockAPIError.launchFailed("no executable in \(bundle)")
            }
            process.executableURL = exec
        } else if let command = args["command"] as? String {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = args["args"] as? [String] ?? []
        } else {
            throw DockAPIError.missingParam("bundle or command")
        }
        let record = LaunchedProcess(process)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
            } else {
                record.append(d)
            }
        }
        do { try process.run() } catch { throw DockAPIError.launchFailed(error.localizedDescription) }
        let pid = process.processIdentifier
        remember(record, for: pid)

        // Wait for the window, then adopt it.
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 150_000_000)
            if AXKit.mainWindow(pid: pid) != nil, dockPid?(pid) == true {
                return ["success": true, "pid": Int(pid), "docked": true]
            }
        }
        return ["success": true, "pid": Int(pid), "docked": false,
                "note": "launched but no window adopted yet — call dock with this pid, or check logs"]
    }

    // MARK: - Synthetic input (fields/apps that reject AX writes)

    private func clickAt(_ p: CGPoint) {
        for (type, isDown) in [(CGEventType.leftMouseDown, true), (.leftMouseUp, false)] {
            if let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left) {
                e.post(tap: .cghidEventTap)
            }
            _ = isDown
        }
    }

    private func typeText(_ text: String) {
        for scalar in text.unicodeScalars {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            var ch = UniChar(scalar.value & 0xFFFF)
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private func pressKey(_ key: String, modifiers: [String]) {
        let map: [String: CGKeyCode] = ["return": 36, "enter": 36, "tab": 48, "space": 49,
            "delete": 51, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126]
        guard let code = map[key.lowercased()] else { return }
        var flags = CGEventFlags()
        for m in modifiers.map({ $0.lowercased() }) {
            switch m {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: break
            }
        }
        for isDown in [true, false] {
            if let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: isDown) {
                e.flags = flags
                e.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Screenshot (the docked app's window)

    @MainActor
    private func screenshot() async throws -> Any {
        guard let target = currentTarget?() else { throw DockAPIError.noTarget }
        beforeScreenshot?()
        try await Task.sleep(nanoseconds: 200_000_000)
        // Find the target's on-screen window by owner pid via ScreenCaptureKit.
        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scWindow = shareable.windows
            .filter({ $0.owningApplication?.processID == target.pid && $0.frame.width > 40 })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw DockAPIError.screenshotFailed("no on-screen window for the docked app")
        }
        let config = SCStreamConfiguration()
        let scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
        let pixelWidth = scWindow.frame.width * scale
        let pixelHeight = scWindow.frame.height * scale
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= 16_384, pixelHeight <= 16_384 else {
            throw DockAPIError.screenshotFailed("invalid window dimensions")
        }
        config.width = Int(pixelWidth.rounded(.up))
        config.height = Int(pixelHeight.rounded(.up))
        config.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        let maxDim: CGFloat = 900
        let longest = max(CGFloat(image.width), CGFloat(image.height))
        var final = image
        if longest > maxDim {
            let ratio = maxDim / longest
            let w = max(1, Int((CGFloat(image.width) * ratio).rounded()))
            let h = max(1, Int((CGFloat(image.height) * ratio).rounded()))
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let s = ctx.makeImage() { final = s }
            }
        }
        let rep = NSBitmapImageRep(cgImage: final)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else {
            throw DockAPIError.screenshotFailed("JPEG encode failed")
        }
        return ["success": true, "image": jpeg.base64EncodedString(), "format": "jpeg", "encoding": "base64"]
    }
}

extension AXKit {
    static func raiseIfPossible(_ window: AXUIElement?) {
        if let window { raise(window) }
    }
}
