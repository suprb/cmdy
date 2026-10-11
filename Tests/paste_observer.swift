// Full-width response observer. Runtime requires a separately authorized GUI slot.
import AppKit
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit

private struct PasteSpec: Codable {
    let appPID: Int32, workerPID: Int32
    let windowID: UInt32, displayID: UInt32
    let executable: String, executableSHA256: String
    let ttyPath: String, socketPath: String, token: String
    let requestedFPS: Int
    let timeoutSeconds: Double
}

private struct PasteActionError: Error, CustomStringConvertible {
    let description: String
    let evidence: [String: Any]
}

private func object<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: scrollCanonicalJSON(value), options: [.fragmentsAllowed])
}

private func writeNew(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    // O_EXCL protects a previous result even if another writer appears after
    // the initial preflight. Failure reports have a distinct, also-new path.
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw ScrollProbeError("cannot create new observer evidence") }
    defer { close(fd) }
    try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ScrollProbeError("observer evidence write failed") }
            offset += count
        }
    }
}

private func workerControl(_ spec: PasteSpec, _ command: String = "probe") throws -> [String: Any] {
    let path = Array(spec.socketPath.utf8CString)
    var address = sockaddr_un()
    guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ScrollProbeError("private worker socket path is too long") }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { target in
        path.withUnsafeBytes { source in target.copyBytes(from: source) }
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ScrollProbeError("cannot create fixture control socket") }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noPipe: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { throw ScrollProbeError("cannot connect to owned fixture") }
    var request = try JSONSerialization.data(withJSONObject: ["command": command, "token": spec.token])
    request.append(10)
    try request.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ScrollProbeError("fixture control write failed") }
            offset += count
        }
    }
    var response = Data(), bytes = [UInt8](repeating: 0, count: 1024)
    while response.last != 10 && response.count < 4096 {
        let count = recv(fd, &bytes, min(bytes.count, 4096 - response.count), 0)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw ScrollProbeError("fixture control response incomplete") }
        response.append(contentsOf: bytes.prefix(count))
    }
    guard response.last == 10,
          let reply = try JSONSerialization.jsonObject(with: response) as? [String: Any],
          reply["ok"] as? Bool == true, reply["status"] as? String == "prepared",
          reply["unexpectedInputBytes"] as? Int == 0,
          let grid = reply["grid"] as? [String: Any], grid["columns"] as? Int == 120, grid["rows"] as? Int == 36 else {
        throw ScrollProbeError("fixture grid/silence proof failed")
    }
    return reply
}


@main private enum PasteObserverMain {
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("Paste observer: \(error)\n", stderr); exit(1) }
    }

    @MainActor private static func run() async throws {
        let args = CommandLine.arguments
        try scrollRequire(args.count == 5 && args[1] == "--spec" && args[3] == "--output",
                          "usage: paste-observer --spec SPEC_JSON --output NEW_RESULT_JSON")
        let output = URL(fileURLWithPath: args[4]), failureOutput = URL(fileURLWithPath: args[4] + ".failure.json")
        try scrollRequire(!FileManager.default.fileExists(atPath: output.path)
            && !FileManager.default.fileExists(atPath: failureOutput.path), "refusing to overwrite observer evidence")
        let specBytes = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let spec = try JSONDecoder().decode(PasteSpec.self, from: specBytes)
        try scrollRequire(spec.requestedFPS == 120 && (1...10).contains(spec.timeoutSeconds),
                          "invalid capture cadence/timeout")
        let fixture = try PasteFixture(token: spec.token)
        let ownership = try ScrollOwnership(appPID: spec.appPID, workerPID: spec.workerPID, ttyPath: spec.ttyPath,
            windowID: spec.windowID, displayID: spec.displayID, executable: spec.executable,
            executableSHA256: spec.executableSHA256)
        let client = PasteAppleEventClient(pid: spec.appPID)
        let beforeClock = scrollClock(), beforeEnvironment = scrollEnvironment()
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        var report: [String: Any] = ["schemaVersion": 2, "benchmarkKind": "paste", "status": "invalid",
            "metric": "public-apple-event-paste-insertion-to-first-complete-response-viewport",
            "specSHA256": scrollHash(specBytes), "token": spec.token, "grid": [120, 36], "barcodeColumns": 120,
            "controllerPID": getppid(), "appIdentity": try object(ownership.app), "workerIdentity": try object(ownership.worker),
            "initialAncestry": ownership.initialAncestry, "executableSHA256": spec.executableSHA256,
            "clockBefore": beforeClock, "timebase": ["numer": timebase.numer, "denom": timebase.denom],
            "environmentBefore": beforeEnvironment, "postMatchGuardNS": 250_000_000,
            "samples": [], "warmups": [], "captureStatusSchema": 1,
            "captureStatusLimit": ScrollCaptureChronology.limit,
            "ownedChromeGeometrySchema": 1, "ownedChromeGeometryLimit": 4096]
        var observation: PasteRasterObservation?, capture: SCStream?
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            try scrollRequire(CGPreflightScreenCaptureAccess(),
                              "existing capture access is required; observer never opens a permission prompt")
            report["ttyBefore"] = try ownership.tty(phase: "before-capture")
            report["fixtureBefore"] = try workerControl(spec)
            let window = try ownership.window()
            report["windowBefore"] = try object(window)
            try client.preflight()
            let query = try terminalQuery(client)
            report["terminalQueryBefore"] = query
            let terminalID = query["terminalID"] as! String
            let shareable = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let owned = shareable.windows.first(where: { $0.windowID == spec.windowID
                && $0.owningApplication?.processID == spec.appPID && $0.isOnScreen }) else {
                throw ScrollProbeError("owned window is unavailable to ScreenCaptureKit")
            }
            let filter = SCContentFilter(desktopIndependentWindow: owned)
            let scale = Double(filter.pointPixelScale)
            try scrollRequire(scale.isFinite && scale >= 1 && scale <= 4
                && filter.contentRect.width == window.width && filter.contentRect.height == window.height,
                "native capture content rectangle differs from the owned window")
            let config = SCStreamConfiguration()
            config.width = Int((filter.contentRect.width * scale).rounded())
            config.height = Int((filter.contentRect.height * scale).rounded())
            config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
            config.queueDepth = 8; config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.showsCursor = false; config.capturesAudio = false; config.ignoreShadowsSingleWindow = true
            let observer = PasteRasterObservation(ownership: ownership, fixture: fixture, expectedWindow: window)
            observation = observer
            let stream = SCStream(filter: filter, configuration: config, delegate: observer)
            capture = stream
            try stream.addStreamOutput(observer, type: .screen,
                sampleHandlerQueue: observer.sampleQueue)
            report["capture"] = ["kind": "owned-window", "requestedFPS": 120, "pointPixelScale": scale,
                "width": config.width, "height": config.height, "ignoreShadowsSingleWindow": true,
                "colorSpace": "sRGB", "pixelFormat": "BGRA", "queueDepth": 8]
            let captureStart = try observer.arm(); report["captureStartTicks"] = captureStart
            try await stream.startCapture()
            report["initial"] = try await waitExpected(observer, stream: stream, target: 964, after: captureStart, timeout: spec.timeoutSeconds)
            let geometry = try observer.state().0!
            try scrollRequire(geometry.width == config.width && geometry.height == config.height,
                              "capture raster differs from requested native pixel resolution")
            report["geometry"] = try object(geometry)
            report["offProbe"] = try await action(spec, ownership, observer, stream, client,
                terminalID: terminalID, sequence: 0)
            try await restartCapture(observer, stream: stream, sourceRow: 963, timeout: spec.timeoutSeconds)
            let enableBefore = try observer.arm()
            let enabled = try workerControl(spec, "enable-bracketed")
            report["enableBracketed"] = ["startedTicks": enableBefore, "control": enabled,
                "finishedTicks": mach_absolute_time()]
            report["enabledViewport"] = try await waitExpected(observer, stream: stream, target: 962,
                after: enableBefore, timeout: spec.timeoutSeconds)
            var warmups: [[String: Any]] = [], samples: [[String: Any]] = []
            for sequence in 1...42 {
                var value = try await action(spec, ownership, observer, stream, client, terminalID: terminalID, sequence: sequence)
                value["warmup"] = sequence <= 2
                if sequence <= 2 { warmups.append(value); report["warmups"] = warmups }
                else { samples.append(value); report["samples"] = samples }
            }
            report["ttyAfter"] = try ownership.tty(phase: "after-events")
            report["fixtureAfter"] = try workerControl(spec)
            report["terminalQueryAfter"] = try terminalQuery(client, expected: terminalID)
            let afterWindow = try ownership.window()
            report["windowAfter"] = try object(afterWindow)
            try scrollRequire(afterWindow == window, "window changed by the end of paste measurement")
            capture = nil // waitExpected stopped and drained the last epoch.
            report["captureStatuses"] = try object(observer.captureStatuses())
            let afterClock = scrollClock(), afterEnvironment = scrollEnvironment()
            try validateClockInterval(beforeClock, afterClock)
            try scrollRequire(NSDictionary(dictionary: beforeEnvironment).isEqual(to: afterEnvironment),
                              "native environment changed during paste observation")
            report["clockAfter"] = afterClock; report["environmentAfter"] = afterEnvironment
            report["permissions"] = client.permissions
            report["ownedChromeGeometry"] = ownership.chromeEvidence()
            report["ownershipFailures"] = ownership.failureEvidence()
            report["completeFrameCount"] = try observer.state().2
            report["status"] = "valid"
            try writeNew(report, to: output)
        } catch {
            if let capture { try? await capture.stopCapture() }
            report["error"] = String(describing: error)
            if let failure = error as? PasteActionError { report["failedAction"] = failure.evidence }
            report["permissions"] = client.permissions
            report["clockAfter"] = scrollClock(); report["environmentAfter"] = scrollEnvironment()
            report["ownedChromeGeometry"] = ownership.chromeEvidence(); report["ownershipFailures"] = ownership.failureEvidence()
            if let observation {
                let retained = observation.retained()
                report["retainedFrames"] = try? object(retained.1); report["completeFrameCount"] = retained.2
                report["observationFailure"] = retained.3
                report["captureStatuses"] = try? object(observation.captureStatuses())
                if let geometry = retained.0 { report["geometry"] = try? object(geometry) }
            }
            try writeNew(report, to: failureOutput)
            throw error
        }
    }

    private static func terminalQuery(_ client: PasteAppleEventClient, expected: String? = nil) throws -> [String: Any] {
        let started = mach_absolute_time()
        let id = try client.soleTerminalID()
        try scrollRequire(expected == nil || expected == id, "owned terminal ID changed")
        return ["startedTicks": started, "finishedTicks": mach_absolute_time(), "terminalID": id, "terminalCount": 1,
                "eventClass": UInt32(kAECoreSuite), "eventID": UInt32(kAEGetData), "targetPID": client.pid,
                "sendOptions": PasteAppleEvent.sendOptions.rawValue]
    }

    private static func validateClockInterval(_ before: [String: UInt64], _ after: [String: UInt64]) throws {
        try scrollRequire(before.allSatisfy { after[$0.key, default: 0] > $0.value }, "native/wall clock did not progress")
        let absolute = scrollNS(after["absoluteTicks"]! - before["absoluteTicks"]!)
        let continuous = scrollNS(after["continuousTicks"]! - before["continuousTicks"]!)
        let wall = after["wallNS"]! - before["wallNS"]!
        try scrollRequire(abs(Double(absolute) - Double(continuous)) <= 5_000_000
            && abs(Double(wall) - Double(absolute)) <= 100_000_000, "sleep or wall/absolute clock discontinuity")
    }

    @MainActor private static func restartCapture(_ observation: PasteRasterObservation,
        stream: SCStream, sourceRow: Int, timeout: Double) async throws {
        // Restart/warm capture outside the timed dispatch. Require a fresh
        // complete source viewport before beginning the next generation.
        let before = mach_absolute_time()
        try await stream.startCapture()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            let (_, frames, _) = try observation.state()
            if frames.contains(where: { $0.callbackTicks > before && $0.firstRow == sourceRow }) { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw ScrollProbeError("restarted capture did not reproduce the complete source viewport")
    }

    @MainActor private static func waitExpected(_ observation: PasteRasterObservation,
        stream: SCStream, target: Int, after: UInt64, timeout: Double) async throws -> [String: Any] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            let (_, frames, _) = try observation.state()
            if try pasteStable(frames, statuses: observation.captureStatuses(), target: target,
                               after: after, now: mach_absolute_time()) != nil {
                // A status can arrive before its pixel decoding is complete.
                // Stop delivery, drain the serial decoder, then validate the
                // entire epoch again. No first-frame or persistence check is
                // skipped, and the independent raw reader remains unchanged.
                try await stream.stopCapture()
                let (completeFrames, statuses, finish) = try observation.finishedState()
                guard let stable = try pasteStable(completeFrames, statuses: statuses, target: target,
                    after: after, now: finish) else {
                    throw ScrollProbeError("final drained capture does not satisfy the paste guard")
                }
                return ["status": "valid", "afterTicks": after, "targetFirstRow": target,
                        "stability": try object(stable), "frames": try object(completeFrames)]
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw ScrollProbeError("first complete full-width paste response and guard were not observed")
    }

    @MainActor private static func action(_ spec: PasteSpec, _ ownership: ScrollOwnership,
        _ observation: PasteRasterObservation, _ stream: SCStream, _ client: PasteAppleEventClient,
        terminalID: String, sequence: Int) async throws -> [String: Any] {
        var result: [String: Any] = ["status": "invalid", "sequence": sequence, "bracketed": sequence > 0]
        do {
            result["ttyBefore"] = try ownership.tty(phase: "before-event")
            result["fixtureBefore"] = try workerControl(spec)
            let windowBefore = try ownership.window()
            try scrollRequire(windowBefore == observation.expectedWindow, "window changed before paste")
            result["windowBefore"] = try object(windowBefore)
            try client.preflight()
            result["terminalQueryBefore"] = try terminalQuery(client, expected: terminalID)
            result["armControl"] = try workerControl(spec, "arm-\(sequence)")
            let text = pastePayload(spec.token, sequence)
            let data = Data(text.utf8)
            let prepared = try PasteAppleEvent.input(pid: spec.appPID, terminalID: terminalID, text: text)
            result["payloadBytes"] = data.count; result["payloadSHA256"] = scrollHash(data)
            let sourceRow = sequence == 0 ? 964 : sequence == 1 ? 962 : sequence - 2
            try await restartCapture(observation, stream: stream, sourceRow: sourceRow, timeout: spec.timeoutSeconds)
            // Payload generation, descriptor construction, and target discovery
            // are outside the interval. Native dispatch itself is included.
            let before = try observation.arm()
            _ = try client.dispatch(prepared, timeout: spec.timeoutSeconds)
            let after = mach_absolute_time()
            result["event"] = ["eventBeforeTicks": before, "eventAfterTicks": after,
                "eventClass": PasteAppleEvent.eventClass, "eventID": PasteAppleEvent.eventID,
                "targetKeyword": PasteAppleEvent.targetKey, "terminalClass": PasteAppleEvent.terminalClass,
                "terminalID": terminalID, "targetPID": spec.appPID,
                "addressDescriptorType": UInt32(typeKernelProcessID), "keyForm": UInt32(formUniqueID),
                "sendOptions": PasteAppleEvent.sendOptions.rawValue, "replyErrorNumber": 0]
            let target = sequence == 0 ? 963 : sequence - 1
            result.merge(try await waitExpected(observation, stream: stream, target: target, after: before, timeout: spec.timeoutSeconds),
                         uniquingKeysWith: { _, new in new })
            result["ttyAfter"] = try ownership.tty(phase: "after-event")
            let probe = try workerControl(spec)
            try scrollRequire(probe["offProbeVerified"] as? Bool == true && probe["receivedBytes"] as? Int == 0
                && probe["armedSequence"] is NSNull
                && probe["acceptedPastes"] as? Int == sequence, "worker did not exactly verify the dispatched paste")
            result["fixtureAfter"] = probe
            result["terminalQueryAfter"] = try terminalQuery(client, expected: terminalID)
            let windowAfter = try ownership.window()
            try scrollRequire(windowAfter == windowBefore, "window changed during paste")
            result["windowAfter"] = try object(windowAfter)
            return result
        } catch {
            result["frames"] = try? object(observation.retained().1)
            result["error"] = String(describing: error)
            throw PasteActionError(description: String(describing: error), evidence: result)
        }
    }
}
