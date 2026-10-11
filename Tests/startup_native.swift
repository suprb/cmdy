// Diagnostic only. Capture is armed before one owned posix_spawn call.
import AppKit
import ApplicationServices
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import ScreenCaptureKit

private struct StartupSpec: Codable {
    let schemaVersion: Int
    let qualifying: Bool
    let token: String
    let targetGrid: [Int]
    let captureShowsCursor: Bool
    let foregroundMethod: String
    let executable: String
    let executableSHA256: String
    let arguments: [String]
    let environment: [String: String]
    let cwd: String
    let appLog: String
    let workerDirectory: String
    let workerExecutable: String
    let workerExecutableSHA256: String
    let inputFiles: [String: String]
    let displayID: UInt32
    let displayMode: ResizeDisplayModeSignature
    let displayBounds: ResizeBounds
    let lowPowerMode: Bool
    let thermalState: Int
}

private func encoded<T: Encodable>(_ value: T) throws -> Any {
    try startupJSONValue(value)
}
private func fileHash(_ path: String) throws -> String {
    gridHash(try Data(contentsOf: URL(fileURLWithPath: path)))
}
private func checkedJSON(_ path: String) throws -> Data {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw ResizeFailure("owned metadata is unavailable: \(errno)") }
    defer { close(fd) }
    var before = stat(), after = stat()
    try resizeRequire(fstat(fd, &before) == 0 && before.st_uid == getuid()
        && (before.st_mode & S_IFMT) == S_IFREG && (before.st_mode & 0o777) == 0o600
        && before.st_nlink == 1 && before.st_size > 0 && before.st_size <= 1_048_576,
        "startup metadata is not a bounded owned 0600 regular file")
    var data = Data(count: Int(before.st_size))
    let count = data.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
    try resizeRequire(count == data.count && fstat(fd, &after) == 0
        && before.st_dev == after.st_dev && before.st_ino == after.st_ino
        && before.st_size == after.st_size && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
        && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
        "startup metadata changed during descriptor read")
    return data
}

private struct WindowItem {
    let pid: Int32, id: UInt32, layer: Int
    let alpha: Double
    let bounds: ResizeBounds
    let ownerExecutable: String?
}
// AXFocusedApplication independently identifies the app receiving keyboard
// input, without changing focus or reading any element content.
private extension StartupAccessibilityFront {
    static func read() -> Self {
        let started = mach_absolute_time()
        let trusted = AXIsProcessTrusted()
        let system = AXUIElementCreateSystemWide()
        let timeoutStatus = AXUIElementSetMessagingTimeout(system, 0.1)
        var value: CFTypeRef?
        let query = AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &value)
        var pid: pid_t = -1
        var status = AXError.failure
        if query == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            status = AXUIElementGetPid(value as! AXUIElement, &pid)
        }
        return Self(startedTicks: started, finishedTicks: mach_absolute_time(),
            queryStatus: Int(query.rawValue), pidStatus: Int(status.rawValue),
            timeoutStatus: Int(timeoutStatus.rawValue), trusted: trusted, pid: pid)
    }
}
private struct WindowQuery {
    let items: [WindowItem]
    let foreground: Int32
    let ticks: UInt64
    let foregroundDiagnostic: StartupForegroundDiagnostic
    static func capture() -> Self {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let items = raw.compactMap { value -> WindowItem? in
            guard let pid = value[kCGWindowOwnerPID as String] as? Int32,
                  let id = value[kCGWindowNumber as String] as? UInt32,
                  let layer = value[kCGWindowLayer as String] as? Int,
                  let alpha = value[kCGWindowAlpha as String] as? Double,
                  let dictionary = value[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary) else { return nil }
            var executable: String?
            if layer == Int(CGWindowLevelForKey(.cursorWindow)) {
                var buffer = [CChar](repeating: 0, count: 4096)
                if buffer.withUnsafeMutableBytes({ proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }) > 0 {
                    executable = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
                }
            }
            return WindowItem(pid: pid, id: id, layer: layer, alpha: alpha,
                bounds: ResizeBounds(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height),
                ownerExecutable: executable)
        }
        let before = StartupAccessibilityFront.read()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        let cocoaTicks = mach_absolute_time(), after = StartupAccessibilityFront.read()
        let ticks = mach_absolute_time()
        let diagnostic = StartupForegroundDiagnostic(before: before, cocoaPID: foreground,
            cocoaTicks: cocoaTicks, after: after, queriedTicks: ticks)
        return Self(items: items, foreground: diagnostic.observedPID(), ticks: ticks,
                    foregroundDiagnostic: diagnostic)
    }
    func owned(_ app: ResizeProcessIdentity, spec: StartupSpec,
               excludedCursor: (WindowItem, UInt64) throws -> Void) throws -> ResizeWindowProof? {
        let owned = items.filter { $0.pid == app.pid && $0.layer == 0 && $0.alpha > 0 }
        try resizeRequire(owned.count <= 1, "multiple visible owned startup windows")
        guard let window = owned.first else { return nil }
        try resizeRequire(window.alpha >= 0.999 && spec.displayBounds.rectangle.contains(window.bounds.rectangle),
                          "startup window is translucent or outside pinned display")
        var occluded = false
        for other in items {
            if other.id == window.id { break }
            if other.alpha > 0 && other.bounds.rectangle.intersects(window.bounds.rectangle) {
                if !spec.captureShowsCursor && scrollIsCaptureExcludedCursor(layer: other.layer,
                                                                            ownerExecutable: other.ownerExecutable) {
                    try excludedCursor(other, ticks)
                } else { occluded = true }
            }
        }
        // Report metadata only on rejection; the successful measurement path is unchanged.
        if occluded {
            var details: [[String: Any]] = []
            var total = 0
            for other in items {
                if other.id == window.id { break }
                if other.alpha > 0 && other.bounds.rectangle.intersects(window.bounds.rectangle)
                    && !(!spec.captureShowsCursor && scrollIsCaptureExcludedCursor(
                        layer: other.layer, ownerExecutable: other.ownerExecutable)) {
                    total += 1
                    if details.count < 16 {
                        var detail: [String: Any] = ["pid": other.pid, "windowID": other.id,
                            "layer": other.layer, "alpha": other.alpha, "bounds": try encoded(other.bounds)]
                        if let identity = try? ResizeProcessIdentity.read(other.pid) {
                            detail["identityObservedAfterWindowQuery"] = try encoded(identity)
                        }
                        details.append(detail)
                    }
                }
            }
            let detailsJSON: [String: Any] = ["windowQueryTicks": ticks,
                "failureTicks": mach_absolute_time(), "ownedPID": app.pid,
                "ownedWindowID": window.id, "ownedBounds": try encoded(window.bounds),
                "occluders": details, "occluderCount": total, "windowTitlesOrContentsRead": false]
            let data = try JSONSerialization.data(withJSONObject: detailsJSON, options: [.sortedKeys])
            throw ResizeFailure("startup owned crop is occluded; metadata=" + String(decoding: data, as: UTF8.self))
        }
        return ResizeWindowProof(identity: app, windowID: window.id, displayID: spec.displayID,
            bounds: window.bounds, foregroundPID: foreground, occluded: false, queriedTicks: ticks)
    }
}

private struct StartupCursorExclusion: Codable {
    let windowID: UInt32, ownerPID: Int32, layer: Int
    let ownerExecutable: String
    var firstQueryTicks: UInt64
    var lastQueryTicks: UInt64
    var queries: Int
}

private final class StartupCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "cmdy.startup.prearmed-capture", qos: .userInitiated)
    let spec: StartupSpec
    private(set) var observation: StartupObservation
    private(set) var failure: String?
    // Bounded counters contain only decoder stages and nonce-verified geometry.
    // They retain no unmatched screen pixels and never affect frame selection.
    private(set) var decodeStages: [String: Int] = [:]
    private(set) var decodeStageGeometry: [String: [Int]] = [:]
    private(set) var decodedHeaders: [String: Int] = [:]
    private(set) var excludedCursors: [String: StartupCursorExclusion] = [:]
    private(set) var foregroundDiagnostics: [StartupForegroundDiagnostic] = []
    private var pending: [(CMSampleBuffer, UInt64, UInt64, WindowQuery)] = []
    private var preparingLaunch = false
    private var closed = false
    private var foregroundEstablished = false
    private var verificationPlan: (StartupGridProof, [[StartupGridRGB?]])?
    init(_ spec: StartupSpec) {
        self.spec = spec
        observation = StartupObservation(displayBounds: spec.displayBounds,
            targetColumns: spec.targetGrid[0], targetRows: spec.targetGrid[1])
    }

    func environment() throws {
        try spec.displayMode.requireUnchanged(ResizeDisplayModeSignature.read(spec.displayID))
        try resizeRequire(CGDisplayBounds(spec.displayID) == spec.displayBounds.rectangle
            && ProcessInfo.processInfo.isLowPowerModeEnabled == spec.lowPowerMode
            && ProcessInfo.processInfo.thermalState.rawValue == spec.thermalState,
            "startup display/power/thermal pin changed")
    }
    func beforeLaunch() throws -> Bool {
        try environment()
        try resizeRequire(observation.launchBefore == nil && !preparingLaunch, "startup capture already armed")
        guard observation.prelaunchReady(at: mach_absolute_time()) else { return false }
        preparingLaunch = true
        return true
    }
    func bind(before: UInt64, after: UInt64, app: ResizeProcessIdentity) throws {
        try observation.launch(before: before, after: after, identity: app)
        for value in pending { try inspect(value.0, display: value.1, callback: value.2, query: value.3) }
        pending.removeAll()
    }
    func currentProof() throws -> ResizeWindowProof {
        try environment()
        guard let app = observation.app else { throw ResizeFailure("startup app is not bound") }
        try resizeRequire(ResizeProcessIdentity.read(app.pid) == app, "startup app lifetime changed")
        let query = WindowQuery.capture()
        try recordForeground(query)
        guard let proof = try query.owned(app, spec: spec, excludedCursor: recordExcludedCursor) else {
            throw ResizeFailure("startup owned window is not visible and foreground")
        }
        try resizeRequire(proof.foregroundPID == app.pid, "startup owned window is not foreground")
        return proof
    }
    private func recordForeground(_ query: WindowQuery) throws {
        try resizeRequire(foregroundDiagnostics.count < 8000, "startup foreground diagnostic bound exceeded")
        foregroundDiagnostics.append(query.foregroundDiagnostic)
    }
    private func recordExcludedCursor(_ item: WindowItem, _ tick: UInt64) throws {
        let key = "\(item.pid)/\(item.id)"
        try resizeRequire(excludedCursors.count < 8 || excludedCursors[key] != nil,
                          "startup excluded cursor inventory exceeded its bound")
        if var prior = excludedCursors[key] {
            try resizeRequire(prior.ownerExecutable == item.ownerExecutable && prior.layer == item.layer
                && prior.queries < 10000, "startup cursor identity/query bound changed")
            // Buffered prebinding queries can be inspected after newer queries.
            prior.firstQueryTicks = min(prior.firstQueryTicks, tick)
            prior.lastQueryTicks = max(prior.lastQueryTicks, tick)
            prior.queries += 1; excludedCursors[key] = prior
        } else {
            excludedCursors[key] = StartupCursorExclusion(windowID: item.id, ownerPID: item.pid, layer: item.layer,
                ownerExecutable: item.ownerExecutable!, firstQueryTicks: tick, lastQueryTicks: tick, queries: 1)
        }
    }
    func freeze() { closed = true }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { if !self.closed { self.failure = "capture stopped: " + error.localizedDescription } }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !closed && failure == nil && type == .screen else { return }
        do {
            try environment()
            guard sample.isValid,
                  let records = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let info = records.first, let status = info[.status] as? Int else {
                throw ResizeFailure("startup capture status missing")
            }
            let callback = mach_absolute_time(), display = (info[.displayTime] as? NSNumber)?.uint64Value
            try observation.status(StartupStatus(status: status, displayTicks: display, callbackTicks: callback))
            guard status == SCFrameStatus.complete.rawValue else { return }
            guard let display, let pixels = CMSampleBufferGetImageBuffer(sample) else {
                throw ResizeFailure("complete startup sample lacks pixels/display clock")
            }
            try resizeRequire(CVPixelBufferGetWidth(pixels) == spec.displayMode.pixelWidth
                && CVPixelBufferGetHeight(pixels) == spec.displayMode.pixelHeight,
                "startup capture resolution changed")
            if !preparingLaunch {
                try observation.receive(StartupFrame(displayTicks: display, callbackTicks: callback,
                    checkedTicks: mach_absolute_time(), stage: "prelaunch", before: nil, after: nil, proofSHA256: nil))
            } else {
                let query = WindowQuery.capture()
                if observation.app == nil {
                    try resizeRequire(pending.count < 8, "prebinding capture queue overflow")
                    pending.append((sample, display, callback, query))
                } else { try inspect(sample, display: display, callback: callback, query: query) }
            }
        } catch { failure = String(describing: error) }
    }

    private func inspect(_ sample: CMSampleBuffer, display: UInt64, callback: UInt64, query: WindowQuery) throws {
        guard let app = observation.app, let start = observation.launchBefore else {
            throw ResizeFailure("pending frame has no native launch binding")
        }
        if display < start {
            try observation.receive(StartupFrame(displayTicks: display, callbackTicks: callback,
                checkedTicks: mach_absolute_time(), stage: "prelaunch-late", before: nil, after: nil, proofSHA256: nil))
            return
        }
        try resizeRequire(ResizeProcessIdentity.read(app.pid) == app, "startup child lifetime changed")
        try recordForeground(query)
        if foregroundEstablished { try resizeRequire(query.foreground == app.pid, "startup app lost foreground") }
        if query.foreground == app.pid { foregroundEstablished = true }
        let before = try query.owned(app, spec: spec, excludedCursor: recordExcludedCursor)
        var proof: StartupGridProof?
        var after: ResizeWindowProof?
        if let before, let buffer = CMSampleBufferGetImageBuffer(sample) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
                  let base = CVPixelBufferGetBaseAddress(buffer) else { throw ResizeFailure("startup BGRA pixels unavailable") }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let sx = Double(width) / spec.displayBounds.width, sy = Double(height) / spec.displayBounds.height
            let crop = StartupGridPixelRect(x0: Int(ceil((before.bounds.x - spec.displayBounds.x) * sx)),
                y0: Int(ceil((before.bounds.y - spec.displayBounds.y) * sy)),
                x1: Int(floor((before.bounds.x + before.bounds.width - spec.displayBounds.x) * sx)),
                y1: Int(floor((before.bounds.y + before.bounds.height - spec.displayBounds.y) * sy)))
            let pixels = StartupGridPixels(bytes: base.assumingMemoryBound(to: UInt8.self), width: width,
                height: height, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
            if let (latest, colors) = verificationPlan {
                proof = try StartupGridMatcher.verify(pixels, witness: latest.witness,
                    raster: latest.raster, expectedColors: colors, generatedSHA256: latest.generatedSHA256)
            }
            // An opening transform can move the pixels without changing the PTY
            // grid. Rediscover on this same sample; never skip a failed sample.
            if proof == nil {
                decodeStages["header-searched", default: 0] += 1
                if let header = try StartupGridMatcher.header(pixels, rectangle: crop, token: spec.token) {
                    let key = "\(header.witness.columns)x\(header.witness.rows)/\(header.witness.generation)"
                    try resizeRequire(decodedHeaders.count < 64 || decodedHeaders[key] != nil,
                                      "startup diagnostic header bound exceeded")
                    decodedHeaders[key, default: 0] += 1
                    proof = try StartupGridMatcher.discover(pixels, rectangle: crop, header: header) { stage, geometry in
                        self.decodeStages[stage, default: 0] += 1
                        self.decodeStageGeometry[stage] = geometry
                    }
                }
            }
            // Inspect an already visible owned crop even before activation. A
            // complete background viewport must invalidate, not disappear from
            // first-frame selection and be replaced after activation.
            try environment()
            try resizeRequire(ResizeProcessIdentity.read(app.pid) == app, "startup app lifetime changed during decode")
            let queryAfter = WindowQuery.capture()
            try recordForeground(queryAfter)
            after = try queryAfter.owned(app, spec: spec, excludedCursor: recordExcludedCursor)
        }
        let key = try proof.map { gridHash(try gridCanonical($0)) }
        let frame = StartupFrame(displayTicks: display, callbackTicks: callback, checkedTicks: mach_absolute_time(),
            stage: proof != nil ? "complete-generated" : (before == nil ? "not-owned-visible" : "fixture-incomplete"),
            before: before, after: after, proofSHA256: key)
        try observation.receive(frame, proof: proof)
        if let proof {
            let colors = try verificationPlan?.1 ?? (0..<proof.witness.rows).map { row in
                try (0..<proof.witness.columns).map { column in try proof.witness.color(column: column, row: row) }
            }
            verificationPlan = (proof, colors)
        }
    }
}

private struct WorkerReady: Codable {
    let token: String, executable: String, ttyPath: String
    let pid: Int32, parentPID: UInt32
    let startedTicks: UInt64
    let initialColumns: Int, initialRows: Int
}
private func workerIdentity(_ spec: StartupSpec, app: ResizeProcessIdentity) throws
    -> (ResizeProcessIdentity, WorkerReady, [String: Any], [String: Int], [String: Any]) {
    let ready = try JSONDecoder().decode(WorkerReady.self, from: checkedJSON(spec.workerDirectory + "/ready.json"))
    let worker = try ResizeProcessIdentity.read(ready.pid)
    try resizeRequire(ready.token == spec.token && ready.executable == spec.workerExecutable
        && worker.executable == spec.workerExecutable && ready.parentPID == worker.parentPID
        && ready.startedTicks > 0 && ready.startedTicks <= UInt64(Int64.max)
        && (try fileHash(spec.workerExecutable)) == spec.workerExecutableSHA256,
        "startup worker executable/nonce/lifetime differs")
    let ancestry = observeRepeatedKernelAncestry(app: app, worker: worker, expectedUID: getuid(),
        fullLookup: { try? ResizeProcessIdentity.read($0) })
    try resizeRequire(ancestry.proof != nil, "startup worker does not belong to spawned app")
    try resizeRequire(ready.ttyPath.range(of: "^/dev/ttys[0-9]+$", options: .regularExpression) != nil,
                      "startup worker has no concrete PTY")
    let fd = open(ready.ttyPath, O_RDONLY | O_NOCTTY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw ResizeFailure("startup PTY unavailable") }
    defer { close(fd) }
    var size = winsize(), device = stat(), process = proc_bsdinfo()
    let ttyStarted = mach_absolute_time()
    let count = withUnsafeMutablePointer(to: &process) {
        proc_pidinfo(worker.pid, PROC_PIDTBSDINFO, 0, $0, Int32(MemoryLayout<proc_bsdinfo>.size))
    }
    try resizeRequire(ioctl(fd, TIOCGWINSZ, &size) == 0 && fstat(fd, &device) == 0
        && count == MemoryLayout<proc_bsdinfo>.size && process.pbi_uid == getuid()
        && (device.st_mode & S_IFMT) == S_IFCHR && process.e_tdev == UInt32(bitPattern: device.st_rdev)
        && process.pbi_pgid > 0 && process.e_tpgid == process.pbi_pgid, "startup controlling/foreground PTY differs")
    try resizeRequire(ResizeProcessIdentity.read(worker.pid) == worker && ResizeProcessIdentity.read(app.pid) == app,
                      "startup endpoint changed around PTY observation")
    let grid = ["columns": Int(size.ws_col), "rows": Int(size.ws_row)]
    let tty: [String: Any] = ["path": ready.ttyPath, "startedTicks": ttyStarted, "finishedTicks": mach_absolute_time(),
        "pid": worker.pid, "uid": device.st_uid, "device": UInt32(bitPattern: device.st_rdev),
        "characterDevice": (device.st_mode & S_IFMT) == S_IFCHR, "processDevice": process.e_tdev,
        "processGroup": process.pbi_pgid, "foregroundGroup": process.e_tpgid, "grid": grid]
    return (worker, ready, ancestry.evidence, grid, tty)
}
private func workerProof(_ spec: StartupSpec, app: ResizeProcessIdentity) throws
    -> (ResizeProcessIdentity, WorkerReady, [String: Any], [String: Int], [String: Any], [String: Any]) {
    let identity = try workerIdentity(spec, app: app)
    guard let events = try JSONSerialization.jsonObject(with: checkedJSON(spec.workerDirectory + "/events.json")) as? [String: Any] else {
        throw ResizeFailure("startup worker event object missing")
    }
    return (identity.0, identity.1, identity.2, identity.3, events, identity.4)
}

@main private struct StartupMain {
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("Startup diagnostic: \(error)\n", stderr); exit(2) }
    }
    @MainActor static func run() async throws {
        let args = CommandLine.arguments
        if args.count == 3 && args[1] == "--probe-display", let displayID = UInt32(args[2]), displayID > 0 {
            // Read-only setup metadata. No capture, application, AX or permission API.
            let mode = try ResizeDisplayModeSignature.read(displayID)
            let bounds = CGDisplayBounds(displayID)
            let value: [String: Any] = ["schemaVersion": 1, "qualifying": false,
                "displayID": displayID, "displayMode": try encoded(mode),
                "displayBounds": try encoded(ResizeBounds(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height)),
                "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
                "thermalState": ProcessInfo.processInfo.thermalState.rawValue]
            print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
            return
        }
        try resizeRequire(args.count == 5 && args[1] == "--spec" && args[3] == "--output",
                          "usage: startup-observer --spec GENERATED.json --output NEW.json")
        let output = URL(fileURLWithPath: args[4])
        try resizeRequire(!FileManager.default.fileExists(atPath: output.path), "startup result already exists")
        let specData = try checkedJSON(args[2])
        let spec = try JSONDecoder().decode(StartupSpec.self, from: specData)
        try resizeRequire(spec.schemaVersion == 1 && !spec.qualifying && !spec.captureShowsCursor && spec.thermalState == 0
            && spec.foregroundMethod == startupForegroundMethod
            && spec.arguments.count <= 32 && spec.environment.count <= 64 && spec.inputFiles.count >= 4
            && spec.environment["CMDY_FRAME_TRACE"] == nil && spec.displayID > 0
            && spec.displayBounds.rectangle.width > 0 && spec.displayBounds.rectangle.height > 0,
            "invalid diagnostic launch contract")
        try resizeRequire(spec.targetGrid.count == 2, "startup target grid was not declared before launch")
        try StartupGridWitness(token: spec.token, columns: spec.targetGrid[0], rows: spec.targetGrid[1],
                               generation: 1, frameKind: 1).validate()
        try spec.displayMode.validate()
        try resizeRequire(try fileHash(spec.executable) == spec.executableSHA256, "startup application bytes changed")
        for (path, hash) in spec.inputFiles { try resizeRequire(try fileHash(path) == hash, "startup input changed") }
        for suffix in ["ready.json", "events.json", "cleanup.json"] {
            try resizeRequire(!FileManager.default.fileExists(atPath: spec.workerDirectory + "/" + suffix),
                              "startup worker output already exists")
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        try resizeRequire(CGPreflightScreenCaptureAccess(), "capture is not already authorized; no prompt requested")
        let capture = StartupCapture(spec)
        try capture.environment()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == spec.displayID }) else {
            throw ResizeFailure("startup pinned display unavailable")
        }
        let config = SCStreamConfiguration()
        config.width = spec.displayMode.pixelWidth; config.height = spec.displayMode.pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.queueDepth = 3; config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB; config.showsCursor = spec.captureShowsCursor; config.capturesAudio = false
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: capture)
        try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: capture.queue)
        var actions: posix_spawn_file_actions_t?
        try resizeRequire(posix_spawn_file_actions_init(&actions) == 0, "spawn file actions unavailable")
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        try resizeRequire(posix_spawnattr_init(&attributes) == 0, "spawn attributes unavailable")
        defer { posix_spawnattr_destroy(&attributes) }
        var defaultSignals = sigset_t(0)
        sigemptyset(&defaultSignals); sigaddset(&defaultSignals, SIGTERM); sigaddset(&defaultSignals, SIGINT)
        try resizeRequire(posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0
            && posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF)) == 0,
            "startup child signal defaults unavailable")
        let log = open(spec.appLog, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard log >= 0 else { throw ResizeFailure("startup app log could not be created") }
        defer { close(log) }
        try resizeRequire(posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) == 0
            && posix_spawn_file_actions_adddup2(&actions, log, 1) == 0
            && posix_spawn_file_actions_adddup2(&actions, log, 2) == 0
            && posix_spawn_file_actions_addclose(&actions, log) == 0
            && posix_spawn_file_actions_addchdir_np(&actions, spec.cwd) == 0, "startup spawn file actions failed")
        let argv = ([spec.executable] + spec.arguments).map { strdup($0) } + [nil]
        let env = spec.environment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for item in argv + env { free(item) } }
        try resizeRequire(argv.dropLast().allSatisfy { $0 != nil } && env.dropLast().allSatisfy { $0 != nil },
                          "startup argument allocation failed")
        // Let the wrapper's bounded SIGTERM request enter normal owned cleanup.
        // Abrupt death cannot produce an eligible diagnostic.
        var cancelled = false
        let previousTerm = signal(SIGTERM, SIG_IGN), previousInterrupt = signal(SIGINT, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        termination.setEventHandler { cancelled = true }; interruption.setEventHandler { cancelled = true }
        termination.resume(); interruption.resume()
        defer {
            termination.cancel(); interruption.cancel()
            signal(SIGTERM, previousTerm); signal(SIGINT, previousInterrupt)
        }
        var pid: pid_t = 0, reaped = false, childStatus: Int32 = 0
        var app: ResizeProcessIdentity?, worker: ResizeProcessIdentity?
        var report: [String: Any] = ["schemaVersion": 1, "qualifying": false, "status": "invalid",
            "case": "startup/first-visible", "metric": startupMetric, "protocol": startupProtocol,
            "specSHA256": gridHash(specData), "spec": try encoded(spec)]
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        report["timebase"] = ["numer": tb.numer, "denom": tb.denom]
        func alive() -> Bool {
            guard pid > 0 && !reaped else { return false }
            let result = waitpid(pid, &childStatus, WNOHANG)
            if result == pid { reaped = true; return false }
            return result == 0
        }
        do {
            try await stream.startCapture()
            let prearm = ProcessInfo.processInfo.systemUptime + 5
            while true {
                try resizeRequire(!cancelled, "startup observer cancellation requested")
                // Read the current prelaunch clock and stop replacing that frame
                // in one transaction; a later callback cannot invalidate readiness.
                let armed = try capture.queue.sync {
                    if let error = capture.failure { throw ResizeFailure(error) }
                    return try capture.beforeLaunch()
                }
                if armed { break }
                try resizeRequire(ProcessInfo.processInfo.systemUptime < prearm, "no complete prelaunch capture")
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            var before: UInt64 = 0, after: UInt64 = 0
            let code = argv.withUnsafeBufferPointer { args in env.withUnsafeBufferPointer { environment in
                before = mach_absolute_time()
                let result = posix_spawn(&pid, args[0]!, &actions, &attributes,
                    UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: environment.baseAddress!))
                after = mach_absolute_time()
                return result
            }}
            report["launch"] = ["beforeTicks": before, "afterTicks": after, "api": "posix_spawn", "calls": 1, "result": code, "pid": pid]
            try resizeRequire(code == 0, "owned startup spawn failed")
            let identity = try ResizeProcessIdentity.read(pid)
            try resizeRequire(identity.executable == spec.executable && identity.uid == getuid(), "spawned app identity differs")
            app = identity; report["appIdentity"] = try encoded(identity)
            try capture.queue.sync { try capture.bind(before: before, after: after, app: identity) }
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while true {
                try resizeRequire(!cancelled && alive() && ProcessInfo.processInfo.systemUptime < deadline,
                                  "startup cancelled, app exited or observation timed out")
                let state = capture.queue.sync { (capture.observation, capture.failure) }
                if let error = state.1 { throw ResizeFailure(error) }
                if state.0.first != nil {
                    _ = try capture.queue.sync { try capture.currentProof() }
                    if try state.0.stabilityReady(at: mach_absolute_time()) {
                        let proof = try workerProof(spec, app: identity)
                        worker = proof.0
                        report["workerIdentity"] = try encoded(proof.0); report["workerReady"] = try encoded(proof.1)
                        report["ancestry"] = proof.2; report["finalTTYGrid"] = proof.3; report["workerEvents"] = proof.4
                        report["workerTTY"] = proof.5
                        // Query, close chronology and freeze in one queue transaction.
                        // A callback cannot slip between the final guard and its result.
                        let completed = try capture.queue.sync { () -> (ResizeWindowProof, UInt64, [String: Int64])? in
                            if let error = capture.failure { throw ResizeFailure(error) }
                            let final = try capture.currentProof(), finished = mach_absolute_time()
                            // A delivered status may name a future display instant.
                            // Keep observing until it passes; never clamp or discard it.
                            guard capture.observation.captureClocksReady(at: final.queriedTicks) else { return nil }
                            let metrics = try capture.observation.result(at: finished, final: final)
                            capture.freeze()
                            return (final, finished, metrics)
                        }
                        if let completed {
                            report["finalProof"] = try encoded(completed.0); report["finishedTicks"] = completed.1
                            report["metricsNS"] = completed.2
                            try resizeRequire(proof.3 == ["columns": spec.targetGrid[0], "rows": spec.targetGrid[1]],
                                          "final startup TTY grid differs")
                            report["status"] = "diagnostic-only"
                            break
                        }
                    }
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        } catch { report["error"] = String(describing: error) }
        let finalState = capture.queue.sync { capture.freeze(); return (capture.observation, capture.failure) }
        try? await stream.stopCapture()
        var recoveredWorker: (ResizeProcessIdentity, WorkerReady, [String: Any], [String: Int], [String: Any])?
        var recoveredEvents: Any?, unverifiedReady: Any?
        if worker == nil, let app, let value = try? workerIdentity(spec, app: app) {
            worker = value.0
            recoveredWorker = value
            if let data = try? checkedJSON(spec.workerDirectory + "/events.json") {
                recoveredEvents = try? JSONSerialization.jsonObject(with: data)
            }
        }
        if report["workerReady"] == nil && recoveredWorker == nil,
           let data = try? checkedJSON(spec.workerDirectory + "/ready.json") {
            unverifiedReady = try? JSONSerialization.jsonObject(with: data)
        }
        report = try await startupFinalizeReport(report, cleanup: {
            if let worker, (try? ResizeProcessIdentity.read(worker.pid)) == worker { kill(worker.pid, SIGTERM) }
            let workerDeadline = ProcessInfo.processInfo.systemUptime + 2
            while let worker, (try? ResizeProcessIdentity.read(worker.pid)) == worker,
                  ProcessInfo.processInfo.systemUptime < workerDeadline { try? await Task.sleep(nanoseconds: 10_000_000) }
            if let worker, (try? ResizeProcessIdentity.read(worker.pid)) == worker { kill(worker.pid, SIGKILL) }
            if alive(), app == nil || (try? ResizeProcessIdentity.read(pid)) == app { kill(pid, SIGTERM) }
            let appDeadline = ProcessInfo.processInfo.systemUptime + 2
            while alive() && ProcessInfo.processInfo.systemUptime < appDeadline { try? await Task.sleep(nanoseconds: 10_000_000) }
            if alive() { kill(pid, SIGKILL); _ = waitpid(pid, &childStatus, 0); reaped = true }
            let workerGone = worker.map { (try? ResizeProcessIdentity.read($0.pid)) != $0 } ?? false
            var cleanup: [String: Any] = ["appPID": pid, "appReaped": reaped, "childStatus": childStatus, "workerGone": workerGone]
            if let worker { cleanup["workerPID"] = worker.pid }
            if let data = try? checkedJSON(spec.workerDirectory + "/cleanup.json") {
                cleanup["worker"] = try? JSONSerialization.jsonObject(with: data)
            }
            return cleanup
        }, appendDiagnostics: { final in
            // Capture the complete v5 worker trace only after owned cleanup.
            // The earlier live snapshot remains separately bound to the frame.
            if let data = try? checkedJSON(spec.workerDirectory + "/events.json") {
                final["workerFinalEvents"] = try? JSONSerialization.jsonObject(with: data)
            }
            final["decodeStages"] = capture.decodeStages
            final["decodeStageGeometry"] = capture.decodeStageGeometry
            final["decodedHeaders"] = capture.decodedHeaders
            final["captureExcludedSystemCursors"] = try encoded(capture.excludedCursors)
            final["foregroundDiagnostics"] = try encoded(capture.foregroundDiagnostics)
            final["frames"] = try encoded(finalState.0.frames); final["statuses"] = try encoded(finalState.0.statuses)
            final["proofs"] = try encoded(finalState.0.proofs); final["firstFrame"] = try encoded(finalState.0.first)
            final["prelaunchFrame"] = try encoded(finalState.0.prelaunch)
            final["observerFailure"] = finalState.1.map { $0 as Any } ?? NSNull()
            if let value = recoveredWorker {
                // Actual geometry is observed while the owned worker is alive,
                // then encoded only after owned process cleanup has completed.
                final["workerIdentity"] = try encoded(value.0); final["workerReady"] = try encoded(value.1)
                final["ancestry"] = value.2; final["finalTTYGrid"] = value.3; final["workerTTY"] = value.4
                final["workerEvents"] = recoveredEvents
            }
            // An exited worker's self-report never grants cleanup authority.
            final["unverifiedWorkerReady"] = unverifiedReady
            do {
                try resizeRequire(try fileHash(spec.executable) == spec.executableSHA256, "startup app bytes changed during observation")
                for (path, hash) in spec.inputFiles { try resizeRequire(try fileHash(path) == hash, "startup input changed during observation") }
                final["inputHashesUnchanged"] = true
            } catch { final["status"] = "invalid"; final["inputHashError"] = String(describing: error) }
        }, write: { try startupWriteReport($0, to: output) })
        if report["status"] as? String != "diagnostic-only" { throw ResizeFailure("startup diagnostic failed; raw receipt retained") }
    }
}
