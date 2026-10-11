// Owned display observer runtime. Native execution requires an explicit parent
// slot and a reviewed calibration; headless tests use only the other modules.
import AppKit
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

private struct RuntimeSpec: Decodable {
    let pid: Int32
    let workerPID: Int32
    let ttyPath: String
    let executableSHA256: String
    let windowID: UInt32
    let displayID: UInt32
    let nonce: String
    let lowPowerMode: Bool
    let thermalState: Int
    let timeoutSeconds: Double
}

private func runtimeJSON<T: Encodable>(_ value: T) throws -> Any {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try JSONSerialization.jsonObject(with: encoder.encode(value))
}
private func runtimeEmit(_ value: [String: Any]) {
    do {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(10); try FileHandle.standardOutput.write(contentsOf: data)
    } catch { exit(2) }
}
private func runtimeTTY(_ path: String, worker: ResizeProcessIdentity, app: ResizeProcessIdentity) throws
    -> (grid: [String: Int], ancestry: [String: Any]) {
    try resizeRequire(path.range(of: "^/dev/ttys[0-9]+$", options: .regularExpression) != nil,
                      "worker did not report a concrete owned PTY")
    let ancestry = observeRepeatedKernelAncestry(app: app, worker: worker, expectedUID: getuid(),
        fullLookup: { try? ResizeProcessIdentity.read($0) })
    guard ancestry.proof != nil else {
        let raw = try JSONSerialization.data(withJSONObject: ancestry.evidence, options: [.sortedKeys])
        throw ResizeFailure("worker process lifetime/lineage changed: " + String(decoding: raw, as: UTF8.self))
    }
    let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK | O_NOFOLLOW)
    try resizeRequire(fd >= 0, "cannot open owned worker PTY")
    defer { close(fd) }
    var size = winsize(), device = stat(), process = proc_bsdinfo()
    let status = withUnsafeMutablePointer(to: &process) {
        proc_pidinfo(worker.pid, PROC_PIDTBSDINFO, 0, $0, Int32(MemoryLayout<proc_bsdinfo>.size))
    }
    try resizeRequire(ioctl(fd, TIOCGWINSZ, &size) == 0 && fstat(fd, &device) == 0
        && status == MemoryLayout<proc_bsdinfo>.size && process.pbi_uid == getuid()
        && (device.st_mode & S_IFMT) == S_IFCHR
        && process.e_tdev == UInt32(bitPattern: device.st_rdev)
        && process.pbi_pgid > 0 && process.e_tpgid == process.pbi_pgid,
        "owned worker geometry/controlling-terminal/foreground-group proof failed")
    return (["columns": Int(size.ws_col), "rows": Int(size.ws_row)], ancestry.evidence)
}

private final class ResizeRuntime: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let spec: RuntimeSpec
    let identity: ResizeProcessIdentity
    let workerIdentity: ResizeProcessIdentity
    let initialTTYGrid: [String: Int]
    let initialAncestry: [String: Any]
    let action: OwnedResizeAction
    let queue = DispatchQueue(label: "resize.generated.display-observer", qos: .userInitiated)
    private var stream: SCStream?
    private var timer: DispatchSourceTimer?
    private var input = Data()
    private var mode = "idle"
    private var command: [String: Any] = [:]
    private var expectation: ResizeFrameExpectation?
    private var sourceCalibration: ResizeRasterCalibration?
    private var observation = ResizeObservationState()
    private var earlyFrames: [ResizeFrameRecord] = []
    private var eventStatuses: [ResizeStatusRecord] = []
    private var receipt: ResizeActionReceipt?
    private var deadline = Double.infinity
    private var lifetimeDeadline = Double.infinity
    private var lastPixels: CVPixelBuffer?
    private var lastDisplayTicks: UInt64?
    private var lastCallbackTicks: UInt64?
    private var captureWidth = 0, captureHeight = 0
    private var displayBounds = ResizeBounds(x: 0, y: 0, width: 1, height: 1)
    private var displayMode: ResizeDisplayModeSignature?
    private var completeFrameCount = 0
    private var idleFrameCount = 0
    private var frameStatuses: [Int: Int] = [:]
    private var finished = false
    private var completion: (@Sendable (Int32) -> Void)?

    @MainActor init(spec: RuntimeSpec) throws {
        try resizeNonce(spec.nonce)
        try resizeRequire((1...600).contains(spec.timeoutSeconds) && spec.thermalState == 0,
                          "bounded lifetime and nominal preregistered thermal state required")
        self.spec = spec
        identity = try ResizeProcessIdentity.read(spec.pid)
        workerIdentity = try ResizeProcessIdentity.read(spec.workerPID)
        action = OwnedResizeAction(identity: identity, executableSHA256: spec.executableSHA256,
                                   windowID: spec.windowID, displayID: spec.displayID)
        let initial = try runtimeTTY(spec.ttyPath, worker: workerIdentity, app: identity)
        initialTTYGrid = initial.grid; initialAncestry = initial.ancestry
        super.init()
        try action.preflight()
    }

    @MainActor func start(completion: @escaping @Sendable (Int32) -> Void) async throws {
        // Install the one completion path before any fallible startup step.
        // Startup and delegate failures both enter fail() on the serial queue,
        // so a startCapture error racing didStopWithError cannot resume twice.
        self.completion = completion
        try resizeRequire(CGPreflightScreenCaptureAccess(), "screen capture is not already authorized")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == spec.displayID }) else {
            throw ResizeFailure("pinned display is unavailable")
        }
        let pinnedMode = try ResizeDisplayModeSignature.read(spec.displayID)
        displayMode = pinnedMode
        let bounds = CGDisplayBounds(spec.displayID)
        displayBounds = ResizeBounds(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height)
        captureWidth = pinnedMode.pixelWidth; captureHeight = pinnedMode.pixelHeight
        let config = SCStreamConfiguration()
        config.width = captureWidth; config.height = captureHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.queueDepth = 3; config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB; config.showsCursor = false; config.capturesAudio = false
        let created = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                               configuration: config, delegate: self)
        try created.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = created
        lifetimeDeadline = ProcessInfo.processInfo.systemUptime + spec.timeoutSeconds
        try await created.startCapture()
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        let announcement: [String: Any] = ["ok": true, "op": "started", "observationScope": resizeObservationScope,
            "fixtureVersion": resizeFixtureVersion,
            "requestClock": "mach_absolute_time", "frameClock": "SCStreamFrameInfo.displayTime",
            "qualifying": false, "identity": try runtimeJSON(identity),
            "workerIdentity": try runtimeJSON(workerIdentity), "initialTTYGrid": initialTTYGrid,
            "initialAncestry": initialAncestry,
            "windowID": spec.windowID, "displayID": spec.displayID,
            "displayBounds": try runtimeJSON(displayBounds), "captureWidth": captureWidth,
            "captureHeight": captureHeight, "requestedFPS": 120,
            "displayRefreshRate": pinnedMode.refreshRate, "displayMode": try runtimeJSON(pinnedMode),
            "timebase": ["numer": timebase.numer, "denom": timebase.denom],
            "environment": ["lowPowerMode": spec.lowPowerMode, "thermalState": spec.thermalState]]
        queue.sync {
            guard !finished else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25))
            timer.setEventHandler { [weak self] in self?.watchdog() }
            self.timer = timer; timer.resume()
            FileHandle.standardInput.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                self?.queue.async { self?.receiveInput(data) }
            }
            runtimeEmit(announcement)
        }
    }

    func startupFailed(_ error: Error) {
        queue.async { self.fail("startup: " + String(describing: error), fields: resizeFailureFields(error)) }
    }

    private func checkEnvironment() throws {
        let value = ProcessInfo.processInfo
        try resizeRequire(value.isLowPowerModeEnabled == spec.lowPowerMode
            && value.thermalState.rawValue == spec.thermalState, "power/thermal condition changed")
        guard let displayMode else { throw ResizeFailure("pinned display mode is missing") }
        try displayMode.requireUnchanged(ResizeDisplayModeSignature.read(spec.displayID))
        try resizeRequire(CGDisplayBounds(spec.displayID) == displayBounds.rectangle,
                          "pinned display geometry changed")
    }
    private func proof() throws -> ResizeWindowProof {
        try checkEnvironment()
        return try ResizeWindowProof.capture(identity: identity, windowID: spec.windowID, displayID: spec.displayID)
    }
    private func decode<T: Decodable>(_ value: Any?, as type: T.Type) throws -> T {
        guard let value else { throw ResizeFailure("command field is missing") }
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
    private func sequence(_ value: Any?) throws -> UInt32 {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue <= Double(UInt32.max), number.doubleValue.rounded() == number.doubleValue else {
            throw ResizeFailure("sequence must be uint32")
        }
        return number.uint32Value
    }
    private func receiveInput(_ data: Data) {
        guard !finished else { return }
        if data.isEmpty { fail("controller input closed"); return }
        input.append(data)
        if input.count > 512 * 1024 { fail("controller request exceeds bound"); return }
        while let end = input.firstIndex(of: 10) {
            let line = input[..<end]; input.removeSubrange(...end)
            do {
                guard let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw ResizeFailure("controller request is not an object")
                }
                try process(value)
            } catch { fail(error) }
        }
    }

    private func process(_ value: [String: Any]) throws {
        let op = value["op"] as? String ?? ""
        if op == "go" {
            guard mode == "armed", let expected = expectation,
                  try sequence(value["sequence"]) == expected.sequence,
                  let source = sourceCalibration else { throw ResizeFailure("GO is stale or no singular event is armed") }
            mode = "request-in-flight"; deadline = ProcessInfo.processInfo.systemUptime + 3
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try action.perform(from: source.outerBounds, to: expected.calibration.outerBounds)
                    queue.async { self.actionReturned(result) }
                } catch { queue.async { self.fail(error) } }
            }
            return
        }
        try resizeRequire(mode == "idle", "another native request is outstanding")
        command = value
        switch op {
        case "discover":
            guard let columns = value["columns"] as? Int, let rows = value["rows"] as? Int else {
                throw ResizeFailure("discovery grid is missing")
            }
            try resizeGrid(columns, rows); _ = try sequence(value["sequence"])
            mode = "discover"; deadline = ProcessInfo.processInfo.systemUptime + 3
            if let lastPixels, let lastDisplayTicks, let lastCallbackTicks {
                try inspect(lastPixels, displayTicks: lastDisplayTicks, callbackTicks: lastCallbackTicks)
            }
        case "verify", "arm":
            if let minimum = value["afterTicks"] {
                guard let number = minimum as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue >= 0, number.doubleValue <= Double(Int64.max),
                      number.doubleValue.rounded() == number.doubleValue else {
                    throw ResizeFailure("post-setup display clock must be a nonnegative integer")
                }
            }
            let calibration = try decode(value["calibration"], as: ResizeRasterCalibration.self)
            try resizeRequire(calibration.displayBounds == displayBounds
                && calibration.displayMode == displayMode
                && calibration.captureWidth == captureWidth && calibration.captureHeight == captureHeight,
                "calibration uses a different display capture")
            expectation = try resizeExpectation(nonce: spec.nonce, sequence: sequence(value["sequence"]), calibration: calibration)
            if op == "arm" {
                sourceCalibration = try decode(value["sourceCalibration"], as: ResizeRasterCalibration.self)
                let sourceSequence = try sequence(value["sourceSequence"])
                guard let source = sourceCalibration, let pixels = lastPixels else { throw ResizeFailure("source frame is unavailable") }
                try resizeRequire(source.displayBounds == displayBounds && source.displayMode == displayMode
                    && source.captureWidth == captureWidth && source.captureHeight == captureHeight,
                    "source calibration uses a different display capture")
                let sourceExpected = try resizeExpectation(nonce: spec.nonce, sequence: sourceSequence, calibration: source)
                let before = try proof()
                try resizeRequire(before.bounds == source.outerBounds
                    && resizeMatches(pixels, expected: sourceExpected, window: before.bounds),
                    "source pixels/bounds do not reproduce frozen calibration")
                let after = try proof()
                try resizeRequire(before.bounds == after.bounds, "source bounds changed around decode")
                observation = ResizeObservationState(); earlyFrames = []; eventStatuses = []; receipt = nil
                mode = "armed"; deadline = ProcessInfo.processInfo.systemUptime + 2
                runtimeEmit(["ok": true, "op": "armed", "sequence": expectation!.sequence,
                             "sourceProof": try runtimeJSON(after), "sourceDisplayTicks": lastDisplayTicks ?? 0])
            } else {
                mode = "verify"; deadline = ProcessInfo.processInfo.systemUptime + 3
                if let lastPixels, let lastDisplayTicks, let lastCallbackTicks {
                    try inspect(lastPixels, displayTicks: lastDisplayTicks, callbackTicks: lastCallbackTicks)
                }
            }
        case "finish":
            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try action.preflight(); queue.async { self.stop(0) } }
                catch { queue.async { self.fail(error) } }
            }
        default: throw ResizeFailure("unknown bounded native operation")
        }
    }

    private func actionReturned(_ value: ResizeActionReceipt) {
        guard !finished else { return }
        do {
            try resizeRequire(mode == "request-in-flight", "native action returned out of order")
            receipt = value
            try observation.begin(at: value.beforeTicks)
            try observation.actionReturned(at: value.afterTicks)
            for frame in earlyFrames { try observation.receive(frame) }
            try resizeValidateStatuses(eventStatuses, firstDisplay: observation.firstCompleteMatch?.displayTicks,
                                       firstCallback: observation.firstCompleteMatch?.callbackTicks)
            earlyFrames.removeAll()
            if let error = value.error { throw ResizeFailure(error) }
            mode = "measuring"
            try maybeComplete()
        } catch { fail(error) }
    }

    private func inspect(_ pixels: CVPixelBuffer, displayTicks: UInt64, callbackTicks: UInt64) throws {
        guard mode != "idle" else { return }
        let before = try proof()
        if mode == "discover" {
            guard let displayMode else { throw ResizeFailure("pinned display mode is missing") }
            let columns = command["columns"] as! Int, rows = command["rows"] as! Int
            let value = try resizeDiscover(pixels, nonce: spec.nonce, sequence: sequence(command["sequence"]),
                columns: columns, rows: rows, window: before, displayBounds: displayBounds,
                displayMode: displayMode, displayTicks: displayTicks)
            let after = try proof()
            try resizeRequire(before.bounds == after.bounds, "native bounds changed during unpooled discovery")
            if let value {
                mode = "idle"; deadline = .infinity
                runtimeEmit(["ok": true, "op": "discover", "result": try runtimeJSON(value)])
            }
            return
        }
        guard let expected = expectation else { throw ResizeFailure("active expected frame missing") }
        let observedClasses = before.bounds == expected.calibration.outerBounds
            ? try resizeMatchingCellClasses(pixels, expected: expected, window: before.bounds) : nil
        let matched = observedClasses != nil
        let after = try proof()
        if matched { try resizeRequire(before.bounds == after.bounds, "first correct pixels changed native bounds during decode") }
        if mode == "verify" {
            let minimum = command["afterTicks"] as? UInt64 ?? 0
            if matched && displayTicks >= minimum {
                mode = "idle"; deadline = .infinity
                guard let observedClasses else { throw ResizeFailure("verified viewport lost decoded cells") }
                runtimeEmit(["ok": true, "op": "verify", "sequence": expected.sequence,
                    "observationScope": resizeObservationScope, "fixtureVersion": resizeFixtureVersion,
                    "nonce": expected.nonce, "displayTicks": displayTicks, "callbackTicks": callbackTicks,
                    "checkedTicks": mach_absolute_time(), "afterTicks": minimum,
                    "matchedCells": observedClasses.count, "observedCellClasses": observedClasses.base64EncodedString(),
                    "cellClassesSHA256": resizeDigest(observedClasses),
                    "beforeProof": try runtimeJSON(before), "afterProof": try runtimeJSON(after)])
            }
            return
        }
        let frame = ResizeFrameRecord(displayTicks: displayTicks, callbackTicks: callbackTicks,
            checkedTicks: mach_absolute_time(), matching: matched, before: before, after: after,
            observedCellClasses: observedClasses)
        if mode == "armed" || mode == "request-in-flight" {
            try resizeRequire(earlyFrames.count < 500, "pre-return frame metadata bound exceeded")
            earlyFrames.append(frame)
        } else if mode == "measuring" {
            try observation.receive(frame); try maybeComplete()
        }
    }

    private func maybeComplete() throws {
        try resizeValidateStatuses(eventStatuses, firstDisplay: observation.firstCompleteMatch?.displayTicks,
                                   firstCallback: observation.firstCompleteMatch?.callbackTicks)
        guard mode == "measuring", let expected = expectation, let receipt,
              let first = observation.firstCompleteMatch else { return }
        let now = mach_absolute_time()
        let firstClocksEnded = max(first.displayTicks, first.callbackTicks)
        let statusesEnded = eventStatuses.reduce(UInt64(0)) { max($0, max($1.callbackTicks, $1.displayTicks ?? 0)) }
        // A future display timestamp is not retimed to its earlier callback.
        // Wait for validation to enclose both, with the existing 3s watchdog.
        guard now >= max(observation.validationNotBeforeTicks, statusesEnded), now >= firstClocksEnded,
              try resizeSignedNS(now, firstClocksEnded) >= 50_000_000 else { return }
        let final = try proof()
        try resizeValidateStatuses(eventStatuses, firstDisplay: first.displayTicks, firstCallback: first.callbackTicks,
                                   validatedAt: final.queriedTicks)
        let tty = try runtimeTTY(spec.ttyPath, worker: workerIdentity, app: identity)
        try resizeRequire(tty.grid == ["columns": expected.calibration.columns, "rows": expected.calibration.rows],
                          "final native worker grid differs from target")
        let finishedTicks = mach_absolute_time()
        try resizeValidateFrameCoverage(observation.frames, eventStatuses)
        let result = try observation.result(at: finishedTicks, target: expected.calibration.outerBounds, finalProof: final)
        guard let observed = first.observedCellClasses else {
            throw ResizeFailure("first matching frame lost its observed cell classes")
        }
        let columns = expected.calibration.columns
        let observedRows = observed.count / columns
        let words = (0..<observedRows).map { row in
            observed[(row * columns + 1)..<(row * columns + 61)].map { String($0, radix: 16) }.joined()
        }
        let complete: [String: Any] = ["complete": true, "matchedRows": observedRows,
            "matchedCells": observed.count, "cellClassesSHA256": resizeDigest(observed),
            "observedCellClasses": observed.base64EncodedString(), "words": words, "displayTicks": first.displayTicks,
            "callbackTicks": first.callbackTicks, "checkedTicks": first.checkedTicks,
            "beforeProof": try runtimeJSON(first.before), "afterProof": try runtimeJSON(first.after)]
        runtimeEmit(["ok": true, "op": "complete", "observationScope": resizeObservationScope,
            "fixtureVersion": resizeFixtureVersion,
            "qualifying": false, "sequence": expected.sequence,
            "action": try runtimeJSON(receipt), "firstCompleteFrame": complete,
            "frames": try runtimeJSON(observation.frames), "statusRecords": try runtimeJSON(eventStatuses),
            "finalProof": try runtimeJSON(final),
            "finalTTYGrid": tty.grid, "finalAncestry": tty.ancestry, "metricsNS": result, "finishedTicks": finishedTicks,
            "stableAfterFirst": true, "ownershipValid": true, "signedClockValid": true,
            "observerFailures": [], "completeFramesObserved": completeFrameCount, "idleFramesObserved": idleFrameCount])
        mode = "idle"; deadline = .infinity; expectation = nil; sourceCalibration = nil
    }
    private func watchdog() {
        guard !finished else { return }
        if ProcessInfo.processInfo.systemUptime >= min(deadline, lifetimeDeadline) {
            fail("bounded native observation deadline exceeded"); return
        }
        do {
            if mode == "measuring" || mode == "armed" || mode == "request-in-flight" { _ = try proof() }
            try maybeComplete()
        } catch { fail(error) }
    }
    private func fail(_ error: Error) {
        fail(String(describing: error), fields: resizeFailureFields(error))
    }
    private func fail(_ error: String, fields: [String: Any] = [:]) {
        guard !finished else { return }
        var value: [String: Any] = ["ok": false, "op": "failure", "mode": mode, "error": error,
            "completeFrames": completeFrameCount, "idleFrames": idleFrameCount,
            "frameStatuses": Dictionary(uniqueKeysWithValues: frameStatuses.map { (String($0.key), $0.value) })]
        value.merge(fields) { _, new in new }
        value["sequence"] = expectation.map { $0.sequence } ?? 0
        value["earlyFrames"] = try? runtimeJSON(earlyFrames)
        value["frames"] = try? runtimeJSON(observation.frames)
        value["statusRecords"] = try? runtimeJSON(eventStatuses)
        if let receipt { value["action"] = try? runtimeJSON(receipt) }
        runtimeEmit(value); stop(2)
    }
    private func stop(_ code: Int32) {
        guard !finished else { return }; finished = true
        timer?.cancel(); timer = nil
        FileHandle.standardInput.readabilityHandler = nil
        let completion = completion
        Task { [weak self] in
            try? await self?.stream?.stopCapture()
            if code == 0 { runtimeEmit(["ok": true, "op": "finished"]) }
            completion?(code)
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.fail("SCStream stopped: " + error.localizedDescription) }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finished, type == .screen else { return }
        guard sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]], let info = attachments.first,
              let status = info[.status] as? Int else {
            fail("screen sample lacks valid capture status"); return
        }
        let callbackTicks = mach_absolute_time()
        frameStatuses[status, default: 0] += 1
        do {
            if mode == "armed" || mode == "request-in-flight" || mode == "measuring" {
                eventStatuses.append(ResizeStatusRecord(status: status, callbackTicks: callbackTicks,
                    displayTicks: (info[.displayTime] as? NSNumber)?.uint64Value))
                try resizeValidateStatuses(eventStatuses, firstDisplay: observation.firstCompleteMatch?.displayTicks,
                                           firstCallback: observation.firstCompleteMatch?.callbackTicks)
            }
            if status == SCFrameStatus.idle.rawValue { idleFrameCount += 1; return }
            if status == SCFrameStatus.suspended.rawValue || status == SCFrameStatus.stopped.rawValue {
                throw ResizeFailure("display capture suspended or stopped")
            }
            guard status == SCFrameStatus.complete.rawValue else {
                try resizeRequire(status == SCFrameStatus.blank.rawValue || status == SCFrameStatus.started.rawValue,
                                  "unknown display capture status")
                lastPixels = nil; lastDisplayTicks = nil; lastCallbackTicks = nil
                return
            }
            guard let stamp = info[.displayTime] as? NSNumber,
                  let pixels = CMSampleBufferGetImageBuffer(sample) else { throw ResizeFailure("complete frame lacks display clock or pixels") }
            try resizeRequire(CVPixelBufferGetWidth(pixels) == captureWidth && CVPixelBufferGetHeight(pixels) == captureHeight,
                              "SCK capture resolution changed")
            completeFrameCount += 1; lastPixels = pixels; lastDisplayTicks = stamp.uint64Value
            lastCallbackTicks = callbackTicks
            try inspect(pixels, displayTicks: stamp.uint64Value, callbackTicks: callbackTicks)
        } catch { fail(error) }
    }
}

@main
private struct ResizeNativeMain {
    @MainActor static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count == 3 && args[1] == "--spec" else { throw ResizeFailure("usage: resize-observer --spec GENERATED_SPEC.json") }
            let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
            try resizeRequire(data.count <= 32_768, "native spec exceeds bound")
            let spec = try JSONDecoder().decode(RuntimeSpec.self, from: data)
            NSApplication.shared.setActivationPolicy(.prohibited)
            let runtime = try ResizeRuntime(spec: spec)
            let result: Int32 = await withCheckedContinuation { continuation in
                Task { @MainActor in
                    do { try await runtime.start { continuation.resume(returning: $0) } }
                    catch { runtime.startupFailed(error) }
                }
            }
            exit(result)
        } catch {
            runtimeEmit(resizeFailureFields(error).merging(["ok": false, "op": "startup-failure"]) { _, new in new }); exit(2)
        }
    }
}
