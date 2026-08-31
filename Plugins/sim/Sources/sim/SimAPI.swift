import AppKit
import ApplicationServices
import CmdySDK

// SimAPI — the agent↔simulator layer. POST /execute {tool, arguments} →
// {result}|{error}; discovery file with a bearer token (same contract as the
// browser/appdock APIs). Tools map to the simctl/xcodebuild lifecycle plus a
// coordinate tap and Injection status.
//
// The dev loop for an agent building an iOS app: `run` (build → install →
// launch → dock → screenshot) once; then for small edits, if the project is
// Injection-ready, the agent just edits the file and the running app
// hot-reloads — re-`screenshot` to see it. Otherwise `run` again.

enum SimAPIError: LocalizedError {
    case missingParam(String)
    case noProject(String)
    case notBooted
    case buildFailed(String)
    case simctl(String)

    var errorDescription: String? {
        switch self {
        case .missingParam(let p): return "missing parameter: \(p)"
        case .noProject(let m): return m
        case .notBooted: return "no simulator is booted — call boot first"
        case .buildFailed(let m): return "build failed:\n\(m)"
        case .simctl(let m): return m
        }
    }
}

final class SimAPI: @unchecked Sendable {
    typealias ToolExecution = (
        _ tool: String,
        _ arguments: [String: Any],
        _ windowNumber: CGWindowID?
    ) throws -> Any

    /// Adopt Simulator.app's window into the strip (installed by main.swift).
    var dockSimulator: (() -> Void)?
    var undock: (() -> Void)?
    /// Simulator.app's docked window (for a coordinate tap), if any.
    var simulatorWindow: (() -> AXUIElement?)?
    /// Force the window on-screen + raised for a tap (it may be parked
    /// off-screen while cmdy isn't frontmost). Installed by main.swift.
    var prepareForTap: (() -> Void)?
    /// Start/stop one serve-sim mirror for the calling Cmdy window.
    /// Installed by main.swift. A nil window falls back to the current key
    /// Cmdy window for command-palette compatibility.
    var startMirror: ((CGWindowID?, String?) -> [String: Any])?
    var stopMirror: ((CGWindowID?, Bool) -> [String: Any])?
    /// Start the native accessibility-element feedback picker.
    var beginFeedback: (() -> Void)?

    private let server = SimHTTPServer()
    /// Stateful Simulator tools are deliberately single-file. Besides keeping
    /// xcodebuild/simctl lifecycle operations in request order, this makes the
    /// remembered project, bundle, and screenshot coordinate space one
    /// coherent session. Health uses a separate utility queue below.
    private let executionQueue = DispatchQueue(
        label: "com.cmdy.sim.execute", qos: .userInitiated)
    private let toolExecutionOverride: ToolExecution?
    private let healthProbe: () -> Bool
    var port: Int { server.port }
    private let derivedData = NSHomeDirectory()
        + "/.cache/\(HostProductIdentity.slug)-sim/DerivedData"
    private let feedback = CmdyFeedbackStore()

    static let discoveryURL = HostProductIdentity.configurationDirectory
        .appendingPathComponent("sim-api.json")

    private struct RememberedSessionState {
        // Remembered so `run`/relaunch don't need the args each time.
        var projectDirectory = FileManager.default.currentDirectoryPath
        var bundleID: String?
        /// Size of the most recent screenshot IMAGE — taps arrive in this
        /// coordinate space and are mapped onto the docked window.
        var shotSize: CGSize?
    }

    /// UI feedback metadata can be requested on the main thread while a tool
    /// is running. The execution queue orders tool mutations; this small lock
    /// makes that external read a race-free snapshot without waiting for a
    /// long xcodebuild operation (or risking a main-queue inversion).
    private let rememberedStateLock = NSLock()
    private var rememberedState = RememberedSessionState()

    init(
        toolExecutionOverride: ToolExecution? = nil,
        healthProbe: @escaping () -> Bool = { Simctl.bootedUDID() != nil }
    ) {
        self.toolExecutionOverride = toolExecutionOverride
        self.healthProbe = healthProbe
    }

    func start() {
        let preferred = HostProductIdentity.environmentValue("SIM_PORT")
            .flatMap(UInt16.init) ?? 4700
        guard server.start(preferredPort: preferred) else {
            NSLog("sim: API failed to bind near %d", Int(preferred)); return
        }
        server.handler = { [weak self] request, respond in
            guard let self else { respond(503, ["error": "shutting down"]); return }
            self.route(request, respond)
        }
        writeDiscoveryFile()
        NSLog("sim: API listening on 127.0.0.1:%d", server.port)
    }

    func stop() { server.stop(); try? FileManager.default.removeItem(at: Self.discoveryURL) }

    private func writeDiscoveryFile() {
        let info: [String: Any] = ["port": server.port, "token": server.authToken,
                                   "api": "sim-v1", "pid": Int(getpid())]
        if let data = try? JSONSerialization.data(withJSONObject: info) {
            try? FileManager.default.createDirectory(
                at: Self.discoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.discoveryURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: Self.discoveryURL.path)
        }
    }

    private func route(_ request: SimHTTPServer.Request, _ respond: @escaping (Int, Any) -> Void) {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            // Process termination notifications are delivered through the
            // app run loop. Waiting for `simctl` on the main thread can keep
            // Process.isRunning true forever and wedge every later request.
            DispatchQueue.global(qos: .utility).async {
                respond(200, ["status": "ok",
                              "app": "\(HostProductIdentity.slug)-sim",
                              "api": "sim-v1", "port": self.server.port,
                              "booted": self.healthProbe()])
            }
        case ("POST", "/execute"):
            guard let json = request.json, let tool = json["tool"] as? String else {
                respond(400, ["error": "expected {\"tool\": …, \"arguments\": {…}}"]); return
            }
            let arguments = json["arguments"] as? [String: Any] ?? [:]
            let rawWindow = (json["window"] as? NSNumber)?.uint64Value
            let windowNumber = rawWindow.flatMap {
                $0 > 0 && $0 <= UInt64(UInt32.max)
                    ? CGWindowID($0) : nil
            }
            // simctl/xcodebuild block; preserve request order on the dedicated
            // stateful lane while health remains independently responsive.
            executionQueue.async {
                do {
                    let result: Any
                    if let override = self.toolExecutionOverride {
                        result = try override(tool, arguments, windowNumber)
                    } else {
                        result = try self.execute(
                            tool: tool, arguments: arguments,
                            windowNumber: windowNumber)
                    }
                    respond(200, ["result": result])
                }
                catch { respond(200, ["error": error.localizedDescription]) }
            }
        default:
            respond(404, ["error": "no route for \(request.method) \(request.path)"])
        }
    }

    /// Test the real request scheduler without binding a TCP port or invoking
    /// external Simulator tooling.
    func routeForTesting(
        _ request: SimHTTPServer.Request,
        _ respond: @escaping (Int, Any) -> Void
    ) {
        route(request, respond)
    }

    // MARK: - Tools

    @discardableResult
    func recordFeedback(_ record: [String: Any]) -> [String: Any] {
        feedback.add(record)
    }

    func feedbackMetadata() -> [String: Any] {
        let remembered = rememberedStateSnapshot()
        var value: [String: Any] = [
            "projectDirectory": remembered.projectDirectory,
        ]
        if let bundleID = remembered.bundleID { value["bundleId"] = bundleID }
        if let udid = Simctl.bootedUDID() { value["udid"] = udid }
        return value
    }

    private func execute(
        tool: String,
        arguments args: [String: Any],
        windowNumber: CGWindowID? = nil
    ) throws -> Any {
        switch tool {
        case "begin_feedback":
            DispatchQueue.main.async { self.beginFeedback?() }
            return ["success": true, "active": true]

        case "get_feedback":
            let status = args["status"] as? String
            let id = args["id"] as? String
            var records = feedback.list(status: status)
            if let id { records = records.filter { $0["id"] as? String == id } }
            return ["success": true, "count": records.count, "feedback": records]

        case "resolve_feedback":
            guard let id = args["id"] as? String else { throw SimAPIError.missingParam("id") }
            let record = feedback.resolve(id: id, resolution: args["resolution"] as? String)
            let value: Any = record.map { $0 as Any } ?? NSNull()
            return ["success": record != nil, "feedback": value]

        case "clear_feedback":
            let removed = feedback.clear(resolvedOnly: args["resolvedOnly"] as? Bool ?? false)
            return ["success": true, "removed": removed]

        case "devices":
            let list = Simctl.devices()
            return ["success": true, "devices": list.map {
                ["udid": $0.udid, "name": $0.name, "state": $0.state, "runtime": $0.runtime] }]

        case "boot":
            let r = Simctl.boot(args["device"] as? String)
            guard r.ok else { throw SimAPIError.simctl(r.combined) }
            DispatchQueue.main.async { self.dockSimulator?() }
            return ["success": true, "udid": r.out, "docked": true]

        case "build":
            return try build(args)

        case "run":
            // The money tool: build → install → launch → dock → screenshot.
            let build = try build(args)
            guard let appPath = (build as? [String: Any])?["appPath"] as? String,
                  let bundleId = (build as? [String: Any])?["bundleId"] as? String else {
                return build   // build already returned its failure
            }
            guard let udid = Simctl.bootedUDID() ?? bootIfNeeded() else { throw SimAPIError.notBooted }
            let inst = Simctl.install(udid: udid, appPath: appPath)
            guard inst.ok else { throw SimAPIError.simctl("install: \(inst.combined)") }
            _ = Simctl.terminate(udid: udid, bundleId: bundleId)
            let launch = Simctl.launch(udid: udid, bundleId: bundleId)
            guard launch.ok else { throw SimAPIError.simctl("launch: \(launch.combined)") }
            updateRememberedState { $0.bundleID = bundleId }
            DispatchQueue.main.async { self.dockSimulator?() }
            Thread.sleep(forTimeInterval: 1.2)
            var out: [String: Any] = ["success": true, "bundleId": bundleId, "udid": udid,
                                      "injection": injectionDict(args)]
            if let shot = Simctl.screenshot(udid: udid) {
                out["image"] = shot.base64EncodedString(); out["format"] = "png"
            }
            return out

        case "screenshot":
            guard let udid = Simctl.bootedUDID() else { throw SimAPIError.notBooted }
            guard let shot = Simctl.screenshot(udid: udid) else { throw SimAPIError.simctl("screenshot failed") }
            let (b64, w, h) = downscale(shot)
            updateRememberedState { $0.shotSize = CGSize(width: w, height: h) }
            return ["success": true, "image": b64, "width": w, "height": h,
                    "format": "png", "encoding": "base64",
                    "note": "tap x/y are in this image's coordinate space"]

        case "logs":
            guard let udid = Simctl.bootedUDID() else { throw SimAPIError.notBooted }
            guard let bundleId = (args["bundleId"] as? String)
                    ?? rememberedStateSnapshot().bundleID else {
                throw SimAPIError.missingParam("bundleId (or run something first)")
            }
            return ["success": true, "logs": Simctl.logs(udid: udid, bundleId: bundleId, tail: args["tail"] as? Int ?? 4000)]

        case "openurl":
            guard let udid = Simctl.bootedUDID() else { throw SimAPIError.notBooted }
            guard let url = args["url"] as? String else { throw SimAPIError.missingParam("url") }
            let r = Simctl.openURL(udid: udid, url: url)
            guard r.ok else { throw SimAPIError.simctl(r.combined) }
            return ["success": true, "opened": url]

        case "push":
            guard let udid = Simctl.bootedUDID() else { throw SimAPIError.notBooted }
            guard let bundleId = (args["bundleId"] as? String)
                    ?? rememberedStateSnapshot().bundleID,
                  let payloadPath = args["payload"] as? String else {
                throw SimAPIError.missingParam("bundleId and payload (path to an APNs JSON)")
            }
            let r = Simctl.push(udid: udid, bundleId: bundleId, payloadPath: payloadPath)
            guard r.ok else { throw SimAPIError.simctl(r.combined) }
            return ["success": true]

        case "terminate":
            guard let udid = Simctl.bootedUDID() else { throw SimAPIError.notBooted }
            guard let bundleId = (args["bundleId"] as? String)
                    ?? rememberedStateSnapshot().bundleID else {
                throw SimAPIError.missingParam("bundleId")
            }
            _ = Simctl.terminate(udid: udid, bundleId: bundleId)
            return ["success": true]

        case "tap":
            // Coordinate tap: x/y are in the LATEST SCREENSHOT's image space
            // (what the agent actually looked at), mapped here onto the live
            // window. Element-level taps need WebDriverAgent — see the README.
            guard let x = numeric(args["x"]), let y = numeric(args["y"]) else {
                throw SimAPIError.missingParam("x and y (in the last screenshot's coordinates)")
            }
            try tapSimulator(imageX: x, imageY: y)
            return ["success": true, "tapped": ["x": x, "y": y],
                    "note": "tapped via the last screenshot's coordinate space"]

        case "injection_status":
            let inj = Simctl.injection(
                projectDir: (args["projectDir"] as? String)
                    ?? rememberedStateSnapshot().projectDirectory)
            return ["ready": inj.ready, "reason": inj.reason]

        case "undock":
            DispatchQueue.main.async { self.undock?() }
            return ["success": true]

        case "mirror":
            // The streamed alternative to the dock: spawns serve-sim (Evan
            // Bacon, Apache-2.0) and opens the interactive mirror in the
            // docked Browser. Fluid resize, multi-device, up to 60fps.
            guard let startMirror else {
                throw SimAPIError.simctl("simulator mirror is unavailable")
            }
            return onMain {
                startMirror(windowNumber, args["device"] as? String)
            }

        case "mirror_stop":
            guard let stopMirror else {
                throw SimAPIError.simctl("simulator mirror is unavailable")
            }
            return onMain {
                stopMirror(windowNumber, args["all"] as? Bool ?? false)
            }

        default:
            throw SimAPIError.simctl("unknown tool: \(tool)")
        }
    }

    private func onMain<T>(_ operation: () -> T) -> T {
        if Thread.isMainThread { return operation() }
        return DispatchQueue.main.sync(execute: operation)
    }

    // MARK: - Build helper

    private func build(_ args: [String: Any]) throws -> Any {
        let project = args["project"] as? String
        let workspace = args["workspace"] as? String
        guard let scheme = args["scheme"] as? String else { throw SimAPIError.missingParam("scheme") }
        if project == nil && workspace == nil {
            throw SimAPIError.noProject("need project (.xcodeproj) or workspace (.xcworkspace)")
        }
        if let dir = (project ?? workspace).map({ ($0 as NSString).deletingLastPathComponent }), !dir.isEmpty {
            updateRememberedState { $0.projectDirectory = dir }
        }
        let config = args["configuration"] as? String ?? "Debug"
        let result = Simctl.build(project: project, workspace: workspace, scheme: scheme,
                                  configuration: config, derivedData: derivedData)
        guard result.ok, let appPath = result.appPath else {
            throw SimAPIError.buildFailed(result.log)
        }
        return ["success": true, "appPath": appPath, "bundleId": result.bundleId as Any,
                "injection": injectionDict(args)]
    }

    private func bootIfNeeded() -> String? {
        let r = Simctl.boot(nil)
        return r.ok ? r.out : nil
    }

    private func injectionDict(_ args: [String: Any]) -> [String: Any] {
        let projectDirectory = (args["project"] as? String).map {
            ($0 as NSString).deletingLastPathComponent
        } ?? rememberedStateSnapshot().projectDirectory
        let inj = Simctl.injection(projectDir: projectDirectory)
        return ["ready": inj.ready, "reason": inj.reason]
    }

    // MARK: - Tap + image helpers

    private func numeric(_ v: Any?) -> CGFloat? {
        if let n = v as? NSNumber { return CGFloat(truncating: n) }
        if let s = v as? String, let d = Double(s) { return CGFloat(d) }
        return nil
    }

    @MainActor private func windowFrameSync() -> CGRect? {
        guard let win = simulatorWindow?() else { return nil }
        return AXKit.frame(of: win)
    }

    private func tapSimulator(imageX: CGFloat, imageY: CGFloat) throws {
        // Map a point from the LAST SCREENSHOT's image space onto the docked
        // window, so "tap what you saw" works regardless of the window's
        // on-screen size. The window is a title bar over the device screen
        // (same aspect as the screenshot), so content height derives from the
        // window width and the image aspect; the remainder on top is chrome.
        guard let shot = rememberedStateSnapshot().shotSize,
              shot.width > 0, shot.height > 0 else {
            throw SimAPIError.simctl("take a screenshot first — tap x/y are in its coordinates")
        }
        guard imageX.isFinite, imageY.isFinite,
              imageX >= 0, imageY >= 0,
              imageX <= shot.width, imageY <= shot.height else {
            throw SimAPIError.simctl(
                "tap coordinates must be inside the last screenshot "
                + "(0...\(Int(shot.width)), 0...\(Int(shot.height)))")
        }
        func windowFrame() -> CGRect? {
            var f: CGRect?
            DispatchQueue.main.sync { f = self.simulatorWindow.flatMap { $0() }.flatMap { AXKit.frame(of: $0) } }
            return f
        }
        // The window may be parked off-screen (cmdy backgrounded): force
        // it into the strip + raised, then give the click its best chance by
        // activating Simulator (an inactive view can swallow the first click).
        DispatchQueue.main.sync { self.prepareForTap?() }
        var winPid: pid_t = 0
        DispatchQueue.main.sync {
            if let w = self.simulatorWindow.flatMap({ $0() }) { AXUIElementGetPid(w, &winPid) }
        }
        if winPid > 0, NSWorkspace.shared.frontmostApplication?.processIdentifier != winPid {
            NSRunningApplication(processIdentifier: winPid)?.activate()
        }
        usleep(300_000)
        guard let frame = windowFrame() else { throw SimAPIError.notBooted }
        // Map image space → the device-screen rect inside the window: the
        // largest shot-aspect rect that fits under the title bar (Simulator
        // letterboxes when the window aspect drifts from the device's).
        let titleH: CGFloat = 28
        let availW = frame.width, availH = max(1, frame.height - titleH)
        let scale = min(availW / shot.width, availH / shot.height)
        let contentW = shot.width * scale, contentH = shot.height * scale
        let originX = frame.origin.x + (availW - contentW) / 2
        let originY = frame.origin.y + titleH + (availH - contentH) / 2
        let point = CGPoint(x: originX + imageX * scale, y: originY + imageY * scale)
        NSLog("sim: tap image(%.0f,%.0f) → screen(%.0f,%.0f) window=(%.0f,%.0f %.0fx%.0f) shot=%.0fx%.0f",
              imageX, imageY, point.x, point.y,
              frame.origin.x, frame.origin.y, frame.width, frame.height, shot.width, shot.height)
        // A convincing click: HID-level source, clickState=1 (AppKit computes
        // clickCount from it — without it some views ignore the "click"), and
        // a human-ish press duration.
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            if let e = CGEvent(mouseEventSource: src, mouseType: down ? .leftMouseDown : .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) {
                e.setIntegerValueField(.mouseEventClickState, value: 1)
                e.post(tap: .cghidEventTap)
            }
            usleep(60_000)   // a real press: ~60ms between down and up
        }
    }

    private func rememberedStateSnapshot() -> RememberedSessionState {
        rememberedStateLock.lock()
        defer { rememberedStateLock.unlock() }
        return rememberedState
    }

    private func updateRememberedState(
        _ update: (inout RememberedSessionState) -> Void
    ) {
        rememberedStateLock.lock()
        update(&rememberedState)
        rememberedStateLock.unlock()
    }

    /// Returns (base64, width, height) of the possibly-downscaled image —
    /// the dimensions define the tap coordinate space.
    private func downscale(_ png: Data, maxDim: CGFloat = 900) -> (String, Int, Int) {
        guard let src = NSBitmapImageRep(data: png), src.pixelsWide > 0 else {
            return (png.base64EncodedString(), 0, 0)
        }
        let fullW = src.pixelsWide, fullH = src.pixelsHigh
        let longest = CGFloat(max(fullW, fullH))
        guard longest > maxDim else { return (png.base64EncodedString(), fullW, fullH) }
        let ratio = maxDim / longest
        let w = max(1, Int((CGFloat(fullW) * ratio).rounded()))
        let h = max(1, Int((CGFloat(fullH) * ratio).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = src.cgImage else { return (png.base64EncodedString(), fullW, fullH) }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return (png.base64EncodedString(), fullW, fullH) }
        let rep = NSBitmapImageRep(cgImage: scaled)
        return ((rep.representation(using: .png, properties: [:]) ?? png).base64EncodedString(), w, h)
    }
}
