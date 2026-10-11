// Public keyboard/file-export pilot. Build-only qualification never invokes this
// executable. No Apple Events, pasteboard API, app launch or activation path.
import AppKit
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import ScreenCaptureKit

private struct HistorySpec: Decodable {
    let pid: Int32, workerPID: Int32
    let ttyPath: String, executableSHA256: String, nonce: String
    let windowID: UInt32, displayID: UInt32
    let expectedApp: ResizeProcessIdentity?
    let expectedWorker: ResizeProcessIdentity?
    let afterTicks: UInt64?
    let proofScope: HistoryProofScope?
    let verificationPolicy: String?
    let verificationScope: String?
    let exportCase: String?
}

private func encoded<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}
private func emit(_ value: [String: Any]) {
    do {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    } catch { exit(2) }
}

private struct HistoryOwner {
    let spec: HistorySpec
    let app: ResizeProcessIdentity, worker: ResizeProcessIdentity
    init(_ spec: HistorySpec) throws {
        try resizeNonce(spec.nonce)
        self.spec = spec
        app = try ResizeProcessIdentity.read(spec.pid); worker = try ResizeProcessIdentity.read(spec.workerPID)
        try resizeRequire(app.uid == getuid() && worker.uid == getuid() && app.pid != worker.pid,
                          "distinct owned app and worker required")
        if let expected = spec.expectedApp { try resizeRequire(app == expected, "app lifetime changed") }
        if let expected = spec.expectedWorker { try resizeRequire(worker == expected, "worker lifetime changed") }
        let checksum = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: app.executable)))
            .map { String(format: "%02x", $0) }.joined()
        try resizeRequire(checksum == spec.executableSHA256, "app executable checksum changed")
    }
    func proof() throws -> [String: Any] {
        let ancestry = observeRepeatedKernelAncestry(app: app, worker: worker, expectedUID: getuid(),
            fullLookup: { try? ResizeProcessIdentity.read($0) })
        try resizeRequire(ancestry.proof != nil, "owned worker ancestry changed")
        try resizeRequire(spec.ttyPath.range(of: "^/dev/ttys[0-9]+$", options: .regularExpression) != nil,
                          "concrete owned PTY required")
        let fd = open(spec.ttyPath, O_RDONLY | O_NOCTTY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        try resizeRequire(fd >= 0, "owned PTY cannot be opened")
        defer { close(fd) }
        var size = winsize(), device = stat(), process = proc_bsdinfo()
        let bytes = withUnsafeMutablePointer(to: &process) {
            proc_pidinfo(worker.pid, PROC_PIDTBSDINFO, 0, $0, Int32(MemoryLayout<proc_bsdinfo>.size))
        }
        try resizeRequire(bytes == MemoryLayout<proc_bsdinfo>.size && fstat(fd, &device) == 0
            && ioctl(fd, TIOCGWINSZ, &size) == 0 && size.ws_col == 120 && size.ws_row == 36
            && process.pbi_uid == getuid() && (device.st_mode & S_IFMT) == S_IFCHR
            && process.e_tdev == UInt32(bitPattern: device.st_rdev)
            && process.pbi_pgid > 0 && process.e_tpgid == process.pbi_pgid,
            "worker PTY device, foreground group or actual 120x36 geometry differs")
        let window: Any
        if spec.proofScope == .fileTransport {
            let current = try ResizeProcessIdentity.read(app.pid)
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
            let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
            window = try encoded(historyFileWindowProof(raw, expected: app, current: current, observerUID: getuid(),
                foregroundPID: foreground, windowID: spec.windowID, displayID: spec.displayID,
                displayBounds: CGDisplayBounds(spec.displayID), displayActive: CGDisplayIsActive(spec.displayID) != 0,
                queriedTicks: mach_absolute_time()))
        } else {
            window = try encoded(ResizeWindowProof.capture(identity: app, windowID: spec.windowID, displayID: spec.displayID))
        }
        return ["identity": try encoded(app), "workerIdentity": try encoded(worker),
                "ancestry": ancestry.evidence, "window": window,
                "grid": ["columns": 120, "rows": 36], "ttyPath": spec.ttyPath,
                "ttyDevice": device.st_rdev, "workerTTYDevice": process.e_tdev,
                "workerProcessGroup": process.pbi_pgid, "workerForegroundGroup": process.e_tpgid]
    }
}

// One new stream per observation requires a fresh WindowServer display clock;
// no last-frame cache or request/completion timestamp is accepted as a frame.
private final class HistoryCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let owner: HistoryOwner
    let queue = DispatchQueue(label: "history.export.generated-viewport")
    private var stream: SCStream?
    private var completed = false
    private var continuation: CheckedContinuation<[String: Any], Error>?
    private var started: UInt64 = 0
    private var mode: ResizeDisplayModeSignature?
    private var bounds: ResizeBounds?
    private var beforeOwner: [String: Any] = [:]
    private var statuses: [[String: Any]] = []
    init(_ owner: HistoryOwner) { self.owner = owner }

    @MainActor func run() async throws -> [String: Any] {
        try historyValidateScope(owner.spec.proofScope, operation: "observe")
        try resizeRequire(CGPreflightScreenCaptureAccess(), "capture grant missing; no permission request made")
        beforeOwner = try owner.proof()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == owner.spec.displayID }) else {
            throw ResizeFailure("pinned display missing")
        }
        let signature = try ResizeDisplayModeSignature.read(owner.spec.displayID); mode = signature
        let rect = CGDisplayBounds(owner.spec.displayID)
        bounds = ResizeBounds(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        let config = SCStreamConfiguration()
        config.width = signature.pixelWidth; config.height = signature.pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120); config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA; config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false; config.capturesAudio = false
        let created = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: config, delegate: self)
        try created.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue); stream = created
        return try await withCheckedThrowingContinuation { waiting in
            queue.sync { continuation = waiting; started = mach_absolute_time() }
            queue.asyncAfter(deadline: .now() + 5) { self.finish(.failure(ResizeFailure("fresh complete generated viewport timeout"))) }
            Task {
                do { try await created.startCapture() }
                catch { queue.async { self.finish(.failure(ResizeFailure("display capture start failed"))) } }
            }
        }
    }

    private func finish(_ result: Result<[String: Any], Error>) {
        guard !completed else { return }; completed = true
        let waiting = continuation; continuation = nil
        Task {
            do { try await stream?.stopCapture(); waiting?.resume(with: result) }
            catch { waiting?.resume(throwing: ResizeFailure("display capture stop failed")) }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.finish(.failure(ResizeFailure("display stream stopped unexpectedly"))) }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !completed, type == .screen else { return }
        do {
            guard sample.isValid, let items = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]], let info = items.first, let status = info[.status] as? Int else {
                throw ResizeFailure("missing native capture status")
            }
            try resizeRequire(statuses.count < 600, "capture record bound")
            let callback = mach_absolute_time(), tick = (info[.displayTime] as? NSNumber)?.uint64Value
            statuses.append(["status": status, "callbackTicks": callback, "displayTicks": tick as Any? ?? NSNull()])
            if status == SCFrameStatus.idle.rawValue || status == SCFrameStatus.started.rawValue || status == SCFrameStatus.blank.rawValue { return }
            try resizeRequire(status == SCFrameStatus.complete.rawValue, "display capture suspended, stopped or unknown")
            guard let tick, tick >= max(started, owner.spec.afterTicks ?? 0), tick <= callback,
                  let pixels = sample.imageBuffer, let mode, let bounds else { return }
            try mode.requireUnchanged(ResizeDisplayModeSignature.read(owner.spec.displayID))
            let before = try ResizeWindowProof.capture(identity: owner.app, windowID: owner.spec.windowID, displayID: owner.spec.displayID)
            guard let discovered = try resizeDiscover(pixels, nonce: owner.spec.nonce, sequence: 0,
                columns: 120, rows: 36, window: before, displayBounds: bounds, displayMode: mode, displayTicks: tick) else { return }
            let expected = try resizeExpectation(nonce: owner.spec.nonce, sequence: 0, calibration: discovered.calibration)
            guard let observed = try resizeMatchingCellClasses(pixels, expected: expected, window: before.bounds) else { return }
            let after = try owner.proof()
            let afterWindow = after["window"] as! [String: Any]
            let beforeWindow = try encoded(before) as! [String: Any]
            try resizeRequire(NSDictionary(dictionary: afterWindow["bounds"] as! [String: Any])
                == NSDictionary(dictionary: beforeWindow["bounds"] as! [String: Any]), "window bounds changed around decode")
            var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
            finish(.success(["ok": true, "op": "observe", "scope": "complete-generated-cell-viewport-v2",
                "nonce": owner.spec.nonce, "sequence": 0, "captureStartedTicks": started,
                "afterTicks": owner.spec.afterTicks ?? 0, "displayTicks": tick, "callbackTicks": callback,
                "discovery": try encoded(discovered), "cellClassesBase64": observed.base64EncodedString(),
                "cellClassesSHA256": resizeDigest(observed), "matchedCells": observed.count,
                "beforeOwner": beforeOwner, "afterOwner": after, "statuses": statuses,
                "timebase": ["numer": timebase.numer, "denom": timebase.denom], "streamStopped": true]))
        } catch { finish(.failure(error)) }
    }
}

@main private struct HistoryExportMain {
    @MainActor static func main() async {
        do {
            let args = CommandLine.arguments
            if args.count == 2 && args[1] == "conditions" {
                let process = ProcessInfo.processInfo
                var base = mach_timebase_info_data_t(); mach_timebase_info(&base)
                let ticks = mach_absolute_time(), quotient = ticks / UInt64(base.denom), remainder = ticks % UInt64(base.denom)
                emit(["ok": true, "lowPowerMode": process.isLowPowerModeEnabled, "thermalState": process.thermalState.rawValue,
                      "physicalMemoryBytes": process.physicalMemory, "processorCount": process.processorCount,
                      "os": process.operatingSystemVersionString,
                      "monotonicNS": quotient * UInt64(base.numer) + remainder * UInt64(base.numer) / UInt64(base.denom)])
                return
            }
            try resizeRequire(args.count == 4 && args[2] == "--spec"
                && ["inspect", "post-key", "observe"].contains(args[1]), "expected inspect/post-key/observe --spec owned.json")
            let url = URL(fileURLWithPath: args[3]); let data = try Data(contentsOf: url)
            try resizeRequire(data.count <= 16384, "native specification bound")
            let spec = try JSONDecoder().decode(HistorySpec.self, from: data)
            try historyValidateScope(spec.proofScope, operation: args[1])
            guard let intendedAction = HistoryExportKey.action(verificationPolicy: spec.verificationPolicy,
                                                               exportCase: spec.exportCase) else {
                throw ResizeFailure("unknown verification policy or export case")
            }
            if let scope = spec.verificationScope {
                try resizeRequire(scope == "strict-visual-memory-v1" && spec.proofScope == nil
                    && spec.verificationPolicy == "post-sample-public-history-v1" && args[1] != "observe",
                    "visual memory phase requires its explicit policy and cannot observe a viewport")
            } else {
                try resizeRequire(spec.verificationPolicy == nil || spec.proofScope == .fileTransport && args[1] != "observe",
                                  "verification phase is file-only and cannot observe a viewport")
            }
            let owner = try HistoryOwner(spec)
            if args[1] == "observe" { emit(try await HistoryCapture(owner).run()); return }
            let before = try owner.proof()
            if args[1] == "inspect" { emit(["ok": true, "op": "inspect", "owner": before]); return }
            try resizeRequire(spec.expectedApp != nil && spec.expectedWorker != nil, "posting requires previously pinned lifetimes")
            try resizeRequire(CGPreflightPostEventAccess(), "event grant missing; no permission request made")
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: HistoryExportKey.code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: HistoryExportKey.code, keyDown: false) else {
                throw ResizeFailure("cannot create public shortcut events")
            }
            for event in [down, up] {
                event.flags = HistoryExportKey.flags; event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            }
            let start = mach_absolute_time(); down.postToPid(owner.app.pid)
            let between = mach_absolute_time(); up.postToPid(owner.app.pid); let end = mach_absolute_time()
            let after = try owner.proof()
            emit(["ok": true, "op": "post-key", "intendedAction": intendedAction,
                  "actionInvocationVerified": false, "shortcut": HistoryExportKey.shortcut,
                  "keyCode": HistoryExportKey.code, "modifierFlags": HistoryExportKey.flags.rawValue,
                  "eventTypes": ["keyDown", "keyUp"], "eventCount": 2, "autorepeat": 0, "targetPID": owner.app.pid,
                  "beforeTicks": start, "betweenTicks": between, "afterTicks": end,
                  "beforeOwner": before, "afterOwner": after, "foregroundActivated": false])
        } catch { emit(resizeFailureFields(error).merging(["ok": false]) { _, new in new }); exit(2) }
    }
}
