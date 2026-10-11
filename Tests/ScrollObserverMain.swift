// swiftc -O -parse-as-library BenchKernelAncestry.swift ScrollNativeObservation.swift ScrollRaster.swift
//   ScrollWindowGeometry.swift ScrollObservationRuntime.swift ScrollObserverMain.swift -o scroll-observer
import AppKit
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit

private struct ScrollSpec: Codable {
    let mode: String
    let appPID: Int32, workerPID: Int32
    let windowID: UInt32, displayID: UInt32
    let executable: String, executableSHA256: String
    let ttyPath: String, socketPath: String, token: String
    let requestedFPS: Int
    let timeoutSeconds: Double
    let upwardRawDelta: Int32?, downwardRawDelta: Int32?
}

private struct ScrollActionError: Error, CustomStringConvertible {
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

private func workerProbe(_ spec: ScrollSpec) throws -> [String: Any] {
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
    let request = Data(("{\"command\":\"probe\",\"token\":\"\(spec.token)\"}\n").utf8)
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

@main
private enum ScrollObserverMain {
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("Scroll observer: \(error)\n", stderr); exit(1) }
    }

    @MainActor private static func run() async throws {
        let args = CommandLine.arguments
        try scrollRequire(args.count == 5 && args[1] == "--spec" && args[3] == "--output",
                          "usage: scroll-observer --spec SPEC_JSON --output NEW_RESULT_JSON")
        let output = URL(fileURLWithPath: args[4]), failureOutput = URL(fileURLWithPath: args[4] + ".failure.json")
        try scrollRequire(!FileManager.default.fileExists(atPath: output.path)
            && !FileManager.default.fileExists(atPath: failureOutput.path), "refusing to overwrite observer evidence")
        let specBytes = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let spec = try JSONDecoder().decode(ScrollSpec.self, from: specBytes)
        try scrollRequire(["calibrate", "measure"].contains(spec.mode) && spec.requestedFPS == 120
            && (1...10).contains(spec.timeoutSeconds), "invalid mode/capture cadence/timeout")
        if spec.mode == "measure" {
            try scrollRequire((1...10).contains(spec.upwardRawDelta ?? 0)
                && (-10 ... -1).contains(spec.downwardRawDelta ?? 0), "missing signed one-event mapping")
        }
        let fixture = try ScrollFixture(token: spec.token)
        let ownership = try ScrollOwnership(appPID: spec.appPID, workerPID: spec.workerPID, ttyPath: spec.ttyPath,
            windowID: spec.windowID, displayID: spec.displayID, executable: spec.executable,
            executableSHA256: spec.executableSHA256)
        let beforeClock = scrollClock(), beforeEnvironment = scrollEnvironment()
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        var report: [String: Any] = ["schemaVersion": 2, "benchmarkKind": "scroll", "status": "invalid",
            "mode": spec.mode, "metric": "synthetic-wheel-to-first-complete-three-row-viewport-frame",
            "specSHA256": scrollHash(specBytes), "token": spec.token, "grid": [120, 36],
            "controllerPID": getppid(),
            "appIdentity": try object(ownership.app), "workerIdentity": try object(ownership.worker),
            "initialAncestry": ownership.initialAncestry,
            "executableSHA256": spec.executableSHA256, "clockBefore": beforeClock,
            "timebase": ["numer": timebase.numer, "denom": timebase.denom], "environmentBefore": beforeEnvironment,
            "stabilityNS": 250_000_000, "samples": [], "warmups": [], "mappingAttempts": [],
            "captureStatusSchema": 1, "captureStatusLimit": ScrollCaptureChronology.limit,
            "ownedChromeGeometrySchema": 1, "ownedChromeGeometryLimit": 4096]
        var observation: ScrollRasterObservation?, capture: SCStream?
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            try scrollRequire(CGPreflightScreenCaptureAccess() && CGPreflightPostEventAccess(),
                              "existing capture/event access is required; observer never opens a permission prompt")
            report["ttyBefore"] = try ownership.tty(phase: "before-capture")
            report["fixtureBefore"] = try workerProbe(spec)
            let window = try ownership.window()
            report["windowBefore"] = try object(window)
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
            config.queueDepth = 8
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.showsCursor = false; config.capturesAudio = false
            config.ignoreShadowsSingleWindow = true
            let observer = ScrollRasterObservation(ownership: ownership, fixture: fixture, expectedWindow: window)
            observation = observer
            let stream = SCStream(filter: filter, configuration: config, delegate: observer)
            capture = stream
            try stream.addStreamOutput(observer, type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "cmdy.scroll-observer", qos: .userInteractive))
            report["capture"] = ["kind": "owned-window", "requestedFPS": 120, "pointPixelScale": scale,
                "width": config.width, "height": config.height, "ignoreShadowsSingleWindow": true,
                "colorSpace": "sRGB", "pixelFormat": "BGRA", "queueDepth": 8]
            let captureStart = mach_absolute_time()
            try observer.arm(after: captureStart)
            report["captureStartTicks"] = captureStart
            try await stream.startCapture()
            let initial = try await waitExpected(observer, target: 964, timeout: spec.timeoutSeconds)
            let geometry = try observer.state().0!
            try scrollRequire(geometry.width == config.width && geometry.height == config.height,
                              "capture raster differs from requested native pixel resolution")
            report["initial"] = initial
            report["geometry"] = try object(geometry)
            let location = CGPoint(x: window.x + Double(geometry.columnSamples[20][1]) / scale,
                y: window.y + Double(geometry.rowBands[18].lower + geometry.rowBands[18].upper) / (2 * scale))
            try scrollRequire(CGRect(x: window.x, y: window.y, width: window.width, height: window.height).contains(location),
                              "calibrated native event location leaves the owned window")
            var identifier: Int64 = 1
            if spec.mode == "calibrate" {
                var attempts: [[String: Any]] = []
                var mapping: [String: Any]?
                for delta: Int32 in 1...10 {
                    let up = try await action(spec, ownership, observer, location, delta: delta,
                        identifier: identifier, before: 964, target: nil); identifier += 1
                    attempts.append(up); report["mappingAttempts"] = attempts
                    let observed = up["afterFirstRow"] as! Int
                    try scrollRequire(observed <= 964, "positive native wheel did not move toward older rows")
                    let down = try await action(spec, ownership, observer, location, delta: -delta,
                        identifier: identifier, before: observed, target: nil); identifier += 1
                    attempts.append(down); report["mappingAttempts"] = attempts
                    try scrollRequire(down["afterFirstRow"] as? Int == 964,
                                      "calibration reverse event did not restore the exact generated viewport")
                    if observed == 961 {
                        mapping = ["upwardRawDelta": delta, "downwardRawDelta": -delta,
                                   "rowsPerEvent": 3, "units": "line", "isContinuous": false,
                                   "status": "valid-unpooled-calibration"]
                        break
                    }
                }
                guard let mapping else { throw ScrollProbeError("no bounded one-event three-row mapping exists") }
                report["mapping"] = mapping
            } else {
                var first = 964, warmups: [[String: Any]] = [], samples: [[String: Any]] = []
                for sequence in 0..<2 {
                    var value = try await action(spec, ownership, observer, location, delta: spec.upwardRawDelta!,
                        identifier: identifier, before: first, target: first - 3); identifier += 1
                    value["sequence"] = sequence; value["warmup"] = true
                    first -= 3; warmups.append(value); report["warmups"] = warmups
                }
                for sequence in 0..<40 {
                    let upward = sequence < 20, next = first + (upward ? -3 : 3)
                    var value = try await action(spec, ownership, observer, location,
                        delta: upward ? spec.upwardRawDelta! : spec.downwardRawDelta!,
                        identifier: identifier, before: first, target: next); identifier += 1
                    value["sequence"] = sequence; value["warmup"] = false
                    first = next; samples.append(value); report["samples"] = samples
                }
                report["mapping"] = ["upwardRawDelta": spec.upwardRawDelta!, "downwardRawDelta": spec.downwardRawDelta!,
                    "rowsPerEvent": 3, "units": "line", "isContinuous": false]
            }
            report["ttyAfter"] = try ownership.tty(phase: "after-events")
            report["fixtureAfter"] = try workerProbe(spec)
            let afterWindow = try ownership.window()
            report["windowAfter"] = try object(afterWindow)
            try scrollRequire(afterWindow == window, "window changed by the end of measurement")
            try await stream.stopCapture(); capture = nil
            let statuses = observer.captureStatuses()
            let afterClock = scrollClock(), afterEnvironment = scrollEnvironment()
            report["captureStatuses"] = try object(statuses)
            report["clockAfter"] = afterClock; report["environmentAfter"] = afterEnvironment
            try scrollRequire(NSDictionary(dictionary: beforeEnvironment).isEqual(to: afterEnvironment)
                && beforeEnvironment["thermalState"] as? Int == 0, "native thermal/low-power conditions changed")
            try validateClockInterval(beforeClock, afterClock)
            report["status"] = spec.mode == "calibrate" ? "valid-unpooled-calibration" : "valid"
            report["windowGuardFailures"] = ownership.failureEvidence()
            report["ownedChromeGeometry"] = ownership.chromeEvidence()
            try writeNew(report, to: output)
        } catch {
            if let capture { try? await capture.stopCapture() }
            let statuses = observation?.captureStatuses() ?? []
            report["error"] = String(describing: error)
            if let actionError = error as? ScrollActionError { report["pendingAction"] = actionError.evidence }
            report["clockAfter"] = scrollClock(); report["environmentAfter"] = scrollEnvironment()
            report["captureStatuses"] = try? object(statuses)
            report["windowGuardFailures"] = ownership.failureEvidence()
            report["ownedChromeGeometry"] = ownership.chromeEvidence()
            if let observation {
                let value = observation.retained()
                report["pendingFrames"] = try? object(value.1)
                report["completeFrameCount"] = value.2
                report["observationFailure"] = value.3
                if let geometry = value.0 { report["geometry"] = try? object(geometry) }
            }
            try writeNew(report, to: failureOutput)
            throw error
        }
    }

    private static func validateClockInterval(_ before: [String: UInt64], _ after: [String: UInt64]) throws {
        try scrollRequire(before.allSatisfy { after[$0.key, default: 0] > $0.value }, "native/wall clock did not progress")
        let absolute = scrollNS(after["absoluteTicks"]! - before["absoluteTicks"]!)
        let continuous = scrollNS(after["continuousTicks"]! - before["continuousTicks"]!)
        let wall = after["wallNS"]! - before["wallNS"]!
        try scrollRequire(abs(Double(absolute) - Double(continuous)) <= 5_000_000
            && abs(Double(wall) - Double(absolute)) <= 100_000_000, "sleep or wall/absolute clock discontinuity")
    }

    @MainActor private static func waitExpected(_ observation: ScrollRasterObservation,
        target: Int, timeout: Double) async throws -> [String: Any] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            let (_, frames, _) = try observation.state()
            if let stable = try scrollStable(frames, target: target, now: mach_absolute_time()) {
                return ["status": "valid", "stability": try object(stable), "frames": try object(frames)]
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw ScrollProbeError("first complete target viewport and stability were not observed")
    }

    @MainActor private static func waitMapping(_ observation: ScrollRasterObservation,
        timeout: Double) async throws -> [String: Any] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            let (_, frames, _) = try observation.state()
            let ordered = frames.sorted { $0.displayTicks < $1.displayTicks }
            if let last = ordered.last, let target = last.firstRow {
                // Mapping is explicitly unpooled: determine the final settled
                // distance, retaining every intermediate frame. Measured events
                // use waitExpected, which never moves an earlier target match.
                let lastWrong = ordered.lastIndex { $0.firstRow != target }
                let suffix = Array(ordered.dropFirst(lastWrong.map { $0 + 1 } ?? 0))
                if let stable = try scrollStable(suffix, target: target, now: mach_absolute_time()) {
                    return ["status": "valid-unpooled-mapping", "stability": try object(stable),
                            "frames": try object(frames), "afterFirstRow": target]
                }
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw ScrollProbeError("wheel mapping did not settle to a fully decoded generated viewport")
    }

    @MainActor private static func action(_ spec: ScrollSpec, _ ownership: ScrollOwnership,
        _ observation: ScrollRasterObservation, _ location: CGPoint, delta: Int32,
        identifier: Int64, before: Int, target: Int?) async throws -> [String: Any] {
        var result: [String: Any] = ["status": "invalid", "beforeFirstRow": before,
                                    "requestedRawDelta": delta, "sourceUserData": identifier]
        do {
        let ttyBefore = try ownership.tty(phase: "before-event"), fixtureBefore = try workerProbe(spec)
        result["ttyBefore"] = ttyBefore; result["fixtureBefore"] = fixtureBefore
        let windowBefore = try ownership.window()
        result["windowBefore"] = try object(windowBefore)
        if windowBefore != observation.expectedWindow {
            ownership.recordWindowChange(actual: windowBefore, expected: observation.expectedWindow)
        }
        try scrollRequire(windowBefore == observation.expectedWindow, "window changed before event")
        guard let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(scrollWheelEvent2Source: source, units: .line,
                  wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else {
            throw ScrollProbeError("cannot create discrete native wheel event")
        }
        event.location = location; event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: identifier)
        try scrollRequire(event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
                          "generated native wheel event is not discrete")
        scrollStampCreatedEvent(event)
        let postBefore = mach_absolute_time()
        try observation.arm(after: postBefore)
        // Scroll routing uses the native event location, not just the process
        // address (postToPid can leave the event without a target NSWindow).
        // Ownership and foreground are checked immediately above and below.
        event.post(tap: .cghidEventTap)
        let postAfter = mach_absolute_time()
        let posted = ScrollPostedEvent(rawDelta: delta, units: "line", isContinuous: false,
            eventBeforeTicks: postBefore, eventAfterTicks: postAfter, eventTimestamp: event.timestamp,
            x: location.x, y: location.y, sourceUserData: identifier)
        result["event"] = try object(posted)
        let observed = try await (target == nil
            ? waitMapping(observation, timeout: spec.timeoutSeconds)
            : waitExpected(observation, target: target!, timeout: spec.timeoutSeconds))
        result.merge(observed, uniquingKeysWith: { _, new in new })
        let ttyAfter = try ownership.tty(phase: "after-event"), fixtureAfter = try workerProbe(spec)
        let windowAfter = try ownership.window()
        if windowBefore != windowAfter { ownership.recordWindowChange(actual: windowAfter, expected: windowBefore) }
        try scrollRequire(windowBefore == windowAfter, "window changed during wheel event")
        result["event"] = try object(posted); result["beforeFirstRow"] = before
        result["afterFirstRow"] = target ?? result["afterFirstRow"]!
        result["rowsMoved"] = abs((result["afterFirstRow"] as! Int) - before)
        result["ttyBefore"] = ttyBefore; result["ttyAfter"] = ttyAfter
        result["fixtureBefore"] = fixtureBefore; result["fixtureAfter"] = fixtureAfter
        result["windowBefore"] = try object(windowBefore); result["windowAfter"] = try object(windowAfter)
        return result
        } catch {
            result["frames"] = try? object(observation.retained().1)
            result["error"] = String(describing: error)
            throw ScrollActionError(description: String(describing: error), evidence: result)
        }
    }
}
