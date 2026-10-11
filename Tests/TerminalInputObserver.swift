// Synthetic key -> first matching WindowServer frame, for an explicitly owned
// terminal window. This is not a physical keyboard-to-photon measurement.
// Build: swiftc -O -parse-as-library Tests/TerminalInputObserver.swift -o observer
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Darwin

private struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private func markerColor(_ sequence: Int) -> (Int, Int, Int) {
    (48 + (sequence % 16) * 11, 48 + ((sequence / 16) % 16) * 11, 211)
}

private struct CaptureTimebase: Codable {
    let numer: UInt32
    let denom: UInt32

    static func current() throws -> CaptureTimebase {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0, info.denom > 0 else {
            throw ProbeError("Mach timebase is unavailable")
        }
        return CaptureTimebase(numer: info.numer, denom: info.denom)
    }

    func milliseconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(numer) / Double(denom) / 1_000_000
    }
}

private struct FrameMatch: Codable {
    let displayTicks: UInt64
    let callbackTicks: UInt64
    let matchingPixels: Int
}

private struct CaptureRegion: Codable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private final class FrameObserver: NSObject, SCStreamOutput, SCStreamDelegate,
                                   @unchecked Sendable {
    private let region: CaptureRegion
    private let localMarker: Bool
    private let lock = NSLock()
    private var sequence = 0
    private var afterTicks: UInt64 = 0
    private var matched: FrameMatch?
    private var error: String?
    private var completeFrames = 0

    init(region: CaptureRegion, localMarker: Bool) {
        self.region = region
        self.localMarker = localMarker
    }

    func expect(_ sequence: Int, after ticks: UInt64) {
        lock.lock()
        self.sequence = sequence
        afterTicks = ticks
        matched = nil
        lock.unlock()
    }

    func result() throws -> FrameMatch? {
        lock.lock()
        defer { lock.unlock() }
        if let error { throw ProbeError(error) }
        return matched
    }

    func frameCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return completeFrames
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        self.error = error.localizedDescription
        lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let status = info[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let display = info[.displayTime] as? NSNumber,
              let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        let callback = mach_absolute_time()
        lock.lock()
        completeFrames += 1
        let expectedSequence = sequence
        let after = afterTicks
        let alreadyMatched = matched != nil
        lock.unlock()
        guard !alreadyMatched, display.uint64Value > after else { return }

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              let address = CVPixelBufferGetBaseAddress(pixels) else { return }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let data = address.assumingMemoryBound(to: UInt8.self)
        let (red, green, blue) = markerColor(expectedSequence)
        var matches = 0
        func matchesColor(x: Int, y: Int) -> Bool {
            let offset = y * stride + x * 4
            return abs(Int(data[offset]) - blue) <= 3
                && abs(Int(data[offset + 1]) - green) <= 3
                && abs(Int(data[offset + 2]) - red) <= 3
                && data[offset + 3] >= 250
        }
        if localMarker {
            // A local marker changes eight cells on one row. Require a solid
            // patch spanning at least three scanlines and 64 pixels inside
            // the declared probe pane; a stray matching pixel cannot pass.
            let x0 = max(0, Int(Double(width) * region.x))
            let x1 = min(width, Int(Double(width) * (region.x + region.width)))
            let y0 = max(0, Int(Double(height) * region.y))
            let y1 = min(height, Int(Double(height) * (region.y + region.height)))
            var matchingRows = 0
            for y in y0..<y1 {
                var run = 0
                var longestRun = 0
                for x in x0..<x1 {
                    run = matchesColor(x: x, y: y) ? run + 1 : 0
                    longestRun = max(longestRun, run)
                }
                if longestRun >= 8 {
                    matches += longestRun
                    matchingRows += 1
                }
                if matchingRows >= 3 && matches >= 64 { break }
            }
            guard matchingRows >= 3, matches >= 64 else { return }
        } else {
            // Whole-grid mode deliberately exercises full-row rebuilding.
            // Most of the pane interior must carry the expected color.
            for row in 1...15 {
                let y = min(height - 1, Int(Double(height) * (region.y + region.height * Double(row) / 16)))
                for col in 1...15 {
                    let x = min(width - 1, Int(Double(width) * (region.x + region.width * Double(col) / 16)))
                    if matchesColor(x: x, y: y) { matches += 1 }
                }
            }
            guard matches >= 170 else { return }
        }
        lock.lock()
        if self.sequence == expectedSequence, afterTicks == after, matched == nil {
            matched = FrameMatch(displayTicks: display.uint64Value,
                                 callbackTicks: callback, matchingPixels: matches)
        }
        lock.unlock()
    }
}

private struct KeySample: Codable {
    let sequence: Int
    let postBeforeTicks: UInt64
    let postAfterTicks: UInt64
    let validationFinishedTicks: UInt64
    let frame: FrameMatch
    let eventToFrameMs: Double
    let captureCallbackLagMs: Double
}

private func keySample(sequence: Int, before: UInt64, after: UInt64,
                       frame: FrameMatch, validated: UInt64,
                       timebase: CaptureTimebase) throws -> KeySample {
    guard timebase.numer > 0, timebase.denom > 0,
          before > 0, before <= after, after <= validated,
          frame.displayTicks > before, frame.displayTicks <= validated,
          frame.callbackTicks >= before, frame.callbackTicks <= validated else {
        throw ProbeError("capture clock ordering or timebase is invalid")
    }
    // Display time is a WindowServer event timestamp. Its ordering relative
    // to callback delivery is not guaranteed. Preserve the first match and
    // subtract unsigned ticks before converting, keeping the offset's sign.
    let lag = frame.callbackTicks >= frame.displayTicks
        ? timebase.milliseconds(frame.callbackTicks - frame.displayTicks)
        : -timebase.milliseconds(frame.displayTicks - frame.callbackTicks)
    return KeySample(sequence: sequence, postBeforeTicks: before, postAfterTicks: after,
        validationFinishedTicks: validated, frame: frame,
        eventToFrameMs: timebase.milliseconds(frame.displayTicks - before),
        captureCallbackLagMs: lag)
}

// Pure clock regression checks. This entry point does not initialize AppKit,
// request permissions, start capture, post input or inspect any application.
private func clockSelfTest() throws {
    let timebase = CaptureTimebase(numer: 125, denom: 3)
    var checks = 0
    func expect(_ condition: Bool) throws {
        guard condition else { throw ProbeError("clock self-test failed") }
        checks += 1
    }
    func make(_ before: UInt64, _ after: UInt64, _ display: UInt64,
              _ callback: UInt64, _ validated: UInt64,
              _ base: CaptureTimebase = CaptureTimebase(numer: 125, denom: 3),
              sequence: Int = 1) throws -> KeySample {
        try keySample(sequence: sequence, before: before, after: after,
            frame: FrameMatch(displayTicks: display, callbackTicks: callback, matchingPixels: 200),
            validated: validated, timebase: base)
    }
    let negative = try make(1000, 1010, 1120, 1100, 1140)
    let positive = try make(2000, 2050, 2180, 2200, 2220, sequence: 2)
    let equal = try make(3000, 3010, 3120, 3120, 3140, sequence: 3)
    let high = UInt64.max - 1000
    let large = try make(high, high + 10, high + 200, high + 197, high + 210, sequence: 4)
    try expect(negative.eventToFrameMs == 0.005 && negative.captureCallbackLagMs < 0)
    try expect(positive.captureCallbackLagMs == -negative.captureCallbackLagMs)
    try expect(equal.captureCallbackLagMs == 0)
    try expect(large.captureCallbackLagMs == -0.000125 && large.eventToFrameMs > 0)
    let invalid: [[UInt64]] = [
        [0, 10, 120, 110, 140], [100, 99, 120, 115, 140],
        [100, 141, 120, 115, 140], [100, 110, 99, 115, 140],
        [100, 110, 100, 115, 140], [100, 110, 141, 115, 140],
        [100, 110, 120, 99, 140], [100, 110, 120, 141, 140]
    ]
    for values in invalid {
        var rejected = false
        do { _ = try make(values[0], values[1], values[2], values[3], values[4]) }
        catch { rejected = true }
        try expect(rejected)
    }
    for base in [CaptureTimebase(numer: 0, denom: 3), CaptureTimebase(numer: 125, denom: 0)] {
        var rejected = false
        do { _ = try make(100, 110, 120, 115, 140, base) }
        catch { rejected = true }
        try expect(rejected)
    }
    let samples = try JSONSerialization.jsonObject(with: JSONEncoder().encode([negative, positive, equal, large]))
    let report: [String: Any] = ["schemaVersion": 3, "clockSource": "mach_absolute_time",
        "timebase": ["numer": timebase.numer, "denom": timebase.denom], "samples": samples]
    let data = try JSONSerialization.data(withJSONObject: ["ok": true, "checks": checks,
        "syntheticClockReport": report], options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

@main
private enum TerminalInputObserver {
    @MainActor
    static func main() async {
        do {
            if Array(CommandLine.arguments.dropFirst()) == ["--self-test-clock"] {
                try clockSelfTest()
                return
            }
            try await run()
        }
        catch {
            fputs("Input observer: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        var args: [String: String] = [:]
        let words = Array(CommandLine.arguments.dropFirst())
        guard words.count.isMultiple(of: 2) else {
            throw ProbeError("usage: observer --pid PID --window ID --output FILE [--samples 40] [--fps 120] [--region x,y,width,height] [--marker-mode full-screen|local-row]")
        }
        for index in stride(from: 0, to: words.count, by: 2) {
            guard ["--pid", "--window", "--output", "--samples", "--fps", "--region", "--marker-mode"].contains(words[index]),
                  args[words[index]] == nil else { throw ProbeError("unknown or repeated argument") }
            args[words[index]] = words[index + 1]
        }
        guard let rawPID = args["--pid"], let pid = Int32(rawPID), pid > 0,
              let rawWindow = args["--window"], let windowID = UInt32(rawWindow),
              let output = args["--output"] else { throw ProbeError("pid, window and output are required") }
        let count = Int(args["--samples"] ?? "40") ?? 0
        let fps = Int(args["--fps"] ?? "120") ?? 0
        guard (5...200).contains(count), (30...120).contains(fps) else {
            throw ProbeError("samples must be 5...200 and fps 30...120")
        }
        let coordinates = (args["--region"] ?? "0.2,0.25,0.6,0.6")
            .split(separator: ",").compactMap { Double($0) }
        guard coordinates.count == 4, coordinates.allSatisfy(\.isFinite),
              coordinates[0] >= 0, coordinates[1] >= 0,
              coordinates[2] > 0, coordinates[3] > 0,
              coordinates[0] + coordinates[2] <= 1,
              coordinates[1] + coordinates[3] <= 1 else {
            throw ProbeError("region must be a positive normalized rectangle inside the owned window")
        }
        let markerMode = args["--marker-mode"] ?? "full-screen"
        guard ["full-screen", "local-row"].contains(markerMode) else {
            throw ProbeError("marker-mode must be full-screen or local-row")
        }
        let region = CaptureRegion(x: coordinates[0], y: coordinates[1],
                                   width: coordinates[2], height: coordinates[3])
        guard !FileManager.default.fileExists(atPath: output) else {
            throw ProbeError("refusing to replace existing evidence")
        }
        // Initialize the AppKit/WindowServer connection without creating a
        // window or activating this observer application.
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard CGPreflightScreenCaptureAccess(), CGPreflightPostEventAccess() else {
            throw ProbeError("existing Screen Recording and event-posting access are required; no permission prompt was opened")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: {
            $0.windowID == windowID && $0.owningApplication?.processID == pid
                && $0.isOnScreen
        }) else { throw ProbeError("the requested on-screen window is not owned by the requested PID") }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw ProbeError("the benchmark app must already be foreground")
        }

        let config = SCStreamConfiguration()
        config.width = 640
        config.height = max(64, Int(640 * window.frame.height / max(1, window.frame.width)))
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        let observer = FrameObserver(region: region, localMarker: markerMode == "local-row")
        observer.expect(0, after: 0)
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                              configuration: config, delegate: observer)
        try stream.addStreamOutput(observer, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "cmdy.input-frame-observer", qos: .userInteractive))
        try await stream.startCapture()

        func waitForFrame() async throws -> FrameMatch {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let result = try observer.result() { return result }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            throw ProbeError("no complete frame with the expected marker arrived within 5 seconds")
        }

        var samples: [KeySample] = []
        do {
            _ = try await waitForFrame()
            let timebase = try CaptureTimebase.current()
            let process = ProcessInfo.processInfo
            let initialPower = process.isLowPowerModeEnabled
            let initialThermal = process.thermalState.rawValue
            let source = CGEventSource(stateID: .privateState)
            for sequence in 1...count {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                    throw ProbeError("focus changed during measurement; result is invalid")
                }
                guard process.isLowPowerModeEnabled == initialPower,
                      process.thermalState.rawValue == initialThermal else {
                    throw ProbeError("power or thermal policy changed during measurement; result is invalid")
                }
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                    throw ProbeError("could not create key events")
                }
                var character: UniChar = 97
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
                up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
                let before = mach_absolute_time()
                observer.expect(sequence, after: before)
                down.postToPid(pid)
                up.postToPid(pid)
                let after = mach_absolute_time()
                let frame = try await waitForFrame()
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      process.isLowPowerModeEnabled == initialPower,
                      process.thermalState.rawValue == initialThermal else {
                    throw ProbeError("focus or power policy changed while awaiting the frame; result is invalid")
                }
                let validated = mach_absolute_time()
                samples.append(try keySample(sequence: sequence, before: before, after: after,
                    frame: frame, validated: validated, timebase: timebase))
                // Vary the spacing to avoid sampling only one phase of vsync.
                try await Task.sleep(nanoseconds: UInt64(70 + sequence * 17 % 61) * 1_000_000)
            }
            try await stream.stopCapture()
            let encoder = JSONEncoder()
            let raw = try JSONSerialization.jsonObject(with: encoder.encode(samples))
            let sorted = samples.map(\.eventToFrameMs).sorted()
            func percentile(_ p: Double) -> Double {
                sorted[min(sorted.count - 1, Int(ceil(p * Double(sorted.count))) - 1)]
            }
            let report: [String: Any] = [
                "schemaVersion": 3, "markerMode": markerMode,
                "clockSource": "mach_absolute_time",
                "timebase": ["numer": timebase.numer, "denom": timebase.denom],
                "metric": "synthetic-key-to-WindowServer-frame",
                "limitations": ["Not physical keyboard-to-photon latency", "Includes a scaled ScreenCaptureKit observer", "Display/capture cadence limits resolution", "Single in-flight synthetic key; raw TTY color responder"],
                "pid": pid, "windowID": windowID,
                "capture": ["width": config.width, "height": config.height, "requestedFPS": fps, "completeFrames": observer.frameCount(), "region": ["x": region.x, "y": region.y, "width": region.width, "height": region.height]],
                "environment": ["lowPowerMode": initialPower, "thermalState": initialThermal, "os": process.operatingSystemVersionString],
                "summaryMs": ["median": percentile(0.5), "p95": percentile(0.95), "max": sorted.last!],
                "samples": raw,
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
            print(String(data: data, encoding: .utf8)!)
        } catch {
            try? await stream.stopCapture()
            // Preserve partial observations for diagnosis, never as a valid
            // distribution or a substitute for a completed comparison.
            let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(samples))
            let failure: [String: Any] = ["valid": false, "error": String(describing: error),
                                          "pid": pid, "windowID": windowID, "samples": raw]
            let data = try JSONSerialization.data(withJSONObject: failure, options: [.prettyPrinted, .sortedKeys])
            try? data.write(to: URL(fileURLWithPath: output + ".failure.json"), options: .withoutOverwriting)
            throw error
        }
    }
}
