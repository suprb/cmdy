// CPU-only generated BGRA/state tests. No NSApplication, screen capture, AX
// mutation, terminal process, window creation or UI permission request.
import CoreVideo
import Darwin
import Foundation

private func crc32(_ value: String) -> UInt32 {
    var crc: UInt32 = 0xffffffff
    for byte in value.utf8 {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
    }
    return ~crc
}
private func word(_ sequence: UInt32, _ columns: Int, _ rows: Int, _ row: Int) -> String {
    let payload = "0123456789abcdef0123456789abcdef"
        + String(format: "%08x%04x%04x%04x", sequence, columns, rows, row)
    return payload + String(format: "%08x", crc32(payload))
}
private func displayMode(modeID: UInt32 = 7, flags: UInt32 = 0,
                         width: Int = 640, height: Int = 400,
                         pixelWidth: Int = 640, pixelHeight: Int = 400,
                         refreshRate: Double = 60, rotation: Double = 0) -> ResizeDisplayModeSignature {
    ResizeDisplayModeSignature(modeID: modeID, flags: flags, width: width, height: height,
        pixelWidth: pixelWidth, pixelHeight: pixelHeight, refreshRate: refreshRate, rotation: rotation)
}
private func expectation(sequence: UInt32 = 5, columns: Int = 120, rows: Int = 36,
                         originX: Double = 10, displayWidth: Double = 640) -> ResizeFrameExpectation {
    let colors = (0..<16).map { ResizeRGB(red: 36 + ($0 % 4) * 48, green: 36 + ($0 / 4) * 48, blue: 212) }
        + [ResizeRGB(red: 242, green: 36, blue: 36), ResizeRGB(red: 36, green: 242, blue: 36)]
    let geometry = ResizeRasterCalibration(fixtureVersion: resizeFixtureVersion, columns: columns, rows: rows,
        outerBounds: ResizeBounds(x: 20, y: 20, width: 600, height: 350),
        displayBounds: ResizeBounds(x: 0, y: 0, width: displayWidth, height: 400),
        displayMode: displayMode(),
        captureWidth: 640, captureHeight: 400,
        xWithinWindowPixels: originX, yWithinWindowPixels: 10,
        cellWidthPixels: 4, rowPitchPixels: 8, rowSampleOffsets: [1.5, 3.5, 5.5],
        colors: colors, tolerance: 3, discoveryEvidenceSHA256: String(repeating: "0", count: 64))
    return ResizeFrameExpectation(nonce: "0123456789abcdef0123456789abcdef", sequence: sequence,
                                 words: (0..<rows).map { word(sequence, columns, rows, $0) }, calibration: geometry)
}
private func pixels(_ expected: ResizeFrameExpectation, missingRow: Int? = nil,
                    duplicateRow: Int? = nil, widthScale: Double = 1,
                    heightScale: Double = 1, colorShift: Int = 0,
                    corruptCell: (row: Int, column: Int)? = nil) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    try resizeRequire(CVPixelBufferCreate(kCFAllocatorDefault, 640, 400,
        kCVPixelFormatType_32BGRA, nil, &result) == kCVReturnSuccess, "fixture allocation failed")
    guard let result else { throw ResizeFailure("fixture is missing") }
    CVPixelBufferLockBaseAddress(result, [])
    defer { CVPixelBufferUnlockBaseAddress(result, []) }
    let stride = CVPixelBufferGetBytesPerRow(result)
    guard let address = CVPixelBufferGetBaseAddress(result) else { throw ResizeFailure("fixture bytes missing") }
    let data = address.assumingMemoryBound(to: UInt8.self)
    memset(address, 0, stride * 400)
    for y in 0..<400 { for x in 0..<640 { data[y * stride + x * 4 + 3] = 255 } }
    for row in 0..<expected.calibration.rows where row != missingRow {
        let wordIndex = row == duplicateRow ? max(0, row - 1) : row
        let classes = resizeCellClasses(word: expected.words[wordIndex], columns: expected.calibration.columns)
        for (column, index) in classes.enumerated() {
            let changed = corruptCell.map { $0.row == row && $0.column == column } ?? false
            let color = expected.calibration.colors[changed ? (index + 1) % 16 : index]
            let x0 = 30 + Int(floor(Double(column) * 4 * widthScale))
            let x1 = 30 + Int(floor(Double(column + 1) * 4 * widthScale))
            let y0 = 30 + Int(floor(Double(row) * 8 * heightScale))
            let y1 = 30 + Int(floor(Double(row + 1) * 8 * heightScale))
            for y in max(0, y0)..<min(400, y1) {
                for x in max(0, x0)..<min(640, x1) {
                    let i = y * stride + x * 4
                    data[i] = UInt8(clamping: color.blue + colorShift)
                    data[i + 1] = UInt8(clamping: color.green + colorShift)
                    data[i + 2] = UInt8(clamping: color.red + colorShift)
                }
            }
        }
    }
    return result
}
private func proof(_ ticks: UInt64, bounds: ResizeBounds? = nil) -> ResizeWindowProof {
    ResizeWindowProof(identity: ResizeProcessIdentity(pid: 123, parentPID: 122, uid: 501, startSeconds: 100,
        startMicroseconds: 10, executable: "/owned/generated-fixture"),
        windowID: 456, displayID: 1,
        bounds: bounds ?? ResizeBounds(x: 20, y: 20, width: 600, height: 350),
        foregroundPID: 123, occluded: false, queriedTicks: ticks)
}
private func frame(_ display: UInt64, callback: UInt64? = nil, matching: Bool = true) -> ResizeFrameRecord {
    let callback = callback ?? display + 10
    return ResizeFrameRecord(displayTicks: display, callbackTicks: callback,
        checkedTicks: callback + 10, matching: matching,
        before: proof(callback + 1), after: proof(callback + 10))
}
private func ticksAfter(_ value: UInt64, nanoseconds: UInt64) -> UInt64 {
    var base = mach_timebase_info_data_t(); mach_timebase_info(&base)
    return value + nanoseconds * UInt64(base.denom) / UInt64(base.numer) + 1
}
private func laterTicks(_ value: UInt64) -> UInt64 {
    ticksAfter(value, nanoseconds: 60_000_000)
}

@main
private struct ResizeSyntheticTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) throws {
            try resizeRequire(value, name); checks += 1; print("PASS " + name)
        }
        func rejects(_ name: String, _ body: () throws -> Void) throws {
            do { try body() } catch { checks += 1; print("PASS " + name); return }
            throw ResizeFailure(name + " unexpectedly accepted")
        }
        let expected = expectation()
        let pinnedMode = expected.calibration.displayMode
        try pinnedMode.requireUnchanged(displayMode())
        try check(true, "identical display mode signature stays pinned")
        for (name, changed) in [
            ("mode identifier", displayMode(modeID: 8)), ("mode flags", displayMode(flags: 1)),
            ("logical width", displayMode(width: 600)), ("logical height", displayMode(height: 380)),
            ("pixel width", displayMode(pixelWidth: 600)), ("pixel height", displayMode(pixelHeight: 380)),
            ("same-resolution refresh rate", displayMode(refreshRate: 120)),
            ("same-resolution rotation", displayMode(rotation: 180)),
            ("nonfinite refresh rate", displayMode(refreshRate: .nan)),
            ("negative refresh rate", displayMode(refreshRate: -1))
        ] {
            try rejects("display pin rejects changed \(name)") { try pinnedMode.requireUnchanged(changed) }
        }
        let correct = try pixels(expected)
        try check(try resizeMatches(correct, expected: expected, window: expected.calibration.outerBounds), "all 36 rows match")
        let observed = try resizeObservedCellClasses(correct, calibration: expected.calibration, window: expected.calibration.outerBounds)
        try check(observed?.count == 120 * 36 && observed.map(resizeDigest) == resizeCellClassesDigest(expected),
                  "observed pixel classes reproduce every-cell digest")
        let larger = expectation(columns: 132, rows: 40)
        try check(try resizeMatches(pixels(larger), expected: larger, window: larger.calibration.outerBounds), "all 40 rows match")
        for context in [expected, larger] {
            for column in [61, context.calibration.columns / 2 + 7, context.calibration.columns - 2,
                           context.calibration.columns - 1] {
                let corrupt = try pixels(context, corruptCell: (context.calibration.rows - 1, column))
                let decoded = try resizeObservedCellClasses(corrupt, calibration: context.calibration, window: context.calibration.outerBounds)
                try check(decoded != nil && decoded.map(resizeDigest) != resizeCellClassesDigest(context),
                          "pixel decoder preserves actual changed class at column \(column)")
                try check(!(try resizeMatches(corrupt, expected: context, window: context.calibration.outerBounds)),
                          "full-width corruption rejected at \(context.calibration.columns)x\(context.calibration.rows) column \(column)")
            }
        }
        let checked = [frame(100), frame(200)]
        let statuses = checked.map { ResizeStatusRecord(status: 0, callbackTicks: $0.callbackTicks, displayTicks: $0.displayTicks) }
        try resizeValidateFrameCoverage(checked, statuses)
        try check(true, "complete capture status and checked frame have exact coverage")
        try rejects("missing checked complete frame rejected") {
            try resizeValidateFrameCoverage(Array(checked.dropFirst()), statuses)
        }
        try rejects("missing complete status rejected") {
            try resizeValidateFrameCoverage(checked, Array(statuses.dropFirst()))
        }
        try rejects("duplicate checked frame and complete status rejected") {
            try resizeValidateFrameCoverage([checked[0], checked[0]], [statuses[0], statuses[0]])
        }
        try check(!(try resizeMatches(pixels(expectation(sequence: 4)), expected: expected,
            window: expected.calibration.outerBounds)), "stale sequence fails")
        try check(!(try resizeMatches(pixels(expected, missingRow: 35), expected: expected,
            window: expected.calibration.outerBounds)), "missing final row fails")
        try check(!(try resizeMatches(pixels(expected, duplicateRow: 20), expected: expected,
            window: expected.calibration.outerBounds)), "duplicated row ordinal fails")
        try check(!(try resizeMatches(pixels(expected, widthScale: 1.1), expected: expected,
            window: expected.calibration.outerBounds)), "scaled stale width fails")
        try check(!(try resizeMatches(pixels(expected, heightScale: 1.1), expected: expected,
            window: expected.calibration.outerBounds)), "scaled stale height fails")
        try check(!(try resizeMatches(correct, expected: expectation(originX: 14),
            window: expected.calibration.outerBounds)), "wrong crop fails")
        try check(!(try resizeMatches(pixels(expected, colorShift: 4), expected: expected,
            window: expected.calibration.outerBounds)), "color outside fixed tolerance fails")
        try rejects("zero display scale rejected") { try expectation(displayWidth: 0).calibration.validate() }
        try rejects("wrong native target rejected") {
            _ = try resizeMatches(correct, expected: expected,
                window: ResizeBounds(x: 20, y: 20, width: 599, height: 350))
        }
        var state = ResizeObservationState()
        try state.begin(at: 100)
        try state.receive(frame(90))
        try check(state.firstCompleteMatch == nil, "preaction frame cannot complete event")
        try state.receive(frame(140))
        try state.actionReturned(at: 180)
        try state.receive(frame(200))
        // firstCompleteMatch stores the record, not just a derived latency.
        try check(state.firstCompleteMatch?.displayTicks == 140, "later correct frame cannot replace first")
        let finished = laterTicks(220)
        let report = try state.result(at: finished, target: expected.calibration.outerBounds,
                                      finalProof: proof(finished))
        try check(report["frameMinusRequestReturnNS"]! < 0, "display before AX return uses signed offset")
        try check(report["requestToFrameNS"] == (try resizeSignedNS(140, 100)), "endpoint remains first frame")
        try rejects("later incorrect complete frame fails stability") { try state.receive(frame(250, matching: false)) }
        var clocks = ResizeObservationState()
        try clocks.begin(at: 100); try clocks.receive(frame(150))
        try rejects("regressing display clock rejected") { try clocks.receive(frame(140)) }
        try check(try resizeSignedNS(1, 2) < 0, "signed conversion does not take absolute latency")
        try rejects("unrepresentable signed clock is rejected without a precondition trap") {
            _ = try resizeSignedNS(UInt64.max, 0)
        }
        var future = ResizeObservationState()
        try future.begin(at: 100)
        try future.receive(frame(180, callback: 150))
        try future.actionReturned(at: 190)
        try future.receive(frame(230, callback: 210))
        let futureFinished = laterTicks(230)
        let futureReport = try future.result(at: futureFinished, target: expected.calibration.outerBounds,
                                              finalProof: proof(futureFinished))
        try check(futureReport["captureCallbackLagNS"] == (try resizeSignedNS(150, 180))
            && futureReport["captureCallbackLagNS"]! < 0, "future display preserves exact negative callback lag")
        try check(future.firstCompleteMatch?.displayTicks == 180
            && futureReport["requestToFrameNS"] == (try resizeSignedNS(180, 100)),
            "future display endpoint is neither clamped nor replaced")
        var futureBoundary = ResizeObservationState()
        try futureBoundary.begin(at: 100); try futureBoundary.actionReturned(at: 190)
        try futureBoundary.receive(frame(ticksAfter(150, nanoseconds: 25_000_000), callback: 150))
        let tooSoon = laterTicks(150)
        try rejects("stability waits 50ms after display as well as callback") {
            _ = try futureBoundary.result(at: tooSoon, target: expected.calibration.outerBounds, finalProof: proof(tooSoon))
        }
        try future.receive(frame(futureFinished + 1, callback: 250))
        try rejects("later display outside final validation invalidates even the retained first endpoint") {
            _ = try future.result(at: futureFinished, target: expected.calibration.outerBounds,
                                  finalProof: proof(futureFinished))
        }
        var invalidClocks = ResizeObservationState()
        try invalidClocks.begin(at: 100)
        try rejects("oversized SCK display ticks rejected") { try invalidClocks.receive(frame(UInt64.max, callback: 150)) }
        try rejects("future display with pre-request matching callback rejected") {
            try invalidClocks.receive(frame(180, callback: 90))
        }
        var callbackOrder = ResizeObservationState()
        try callbackOrder.begin(at: 100); try callbackOrder.receive(frame(140, callback: 180))
        try rejects("regressing callback clock rejected independently of display order") {
            try callbackOrder.receive(frame(150, callback: 170))
        }
        try callbackOrder.actionReturned(at: 190)
        let lateValidation = ticksAfter(100, nanoseconds: 3_100_000_000)
        try rejects("event validation cannot outlive its 3 second watchdog") {
            _ = try callbackOrder.result(at: lateValidation, target: expected.calibration.outerBounds,
                                         finalProof: proof(lateValidation))
        }
        let unchanged = [ResizeStatusRecord(status: 0, callbackTicks: 100, displayTicks: 90),
                         ResizeStatusRecord(status: 1, callbackTicks: 200, displayTicks: 90)]
        try resizeValidateStatuses(unchanged, firstDisplay: 90, firstCallback: 100)
        try check(true, "idle preserves correct static repaint without another complete frame")
        try resizeValidateStatuses([ResizeStatusRecord(status: 2, callbackTicks: 80, displayTicks: 70)] + unchanged,
                                   firstDisplay: 90, firstCallback: 100)
        try check(true, "pre-first blank is retained without replacing endpoint")
        for status in [2, 3, 4, 5] {
            try rejects("post-first SCK status \(status) invalidates stability even before AX return") {
                try resizeValidateStatuses(unchanged + [ResizeStatusRecord(status: status, callbackTicks: 210, displayTicks: 205)],
                                           firstDisplay: 90, firstCallback: 100)
            }
        }
        for status in [2, 4] {
            try rejects("earlier callback status \(status) with overlapping display invalidates stability") {
                try resizeValidateStatuses([ResizeStatusRecord(status: status, callbackTicks: 80, displayTicks: 95)] + unchanged,
                                           firstDisplay: 90, firstCallback: 100)
            }
        }
        for display in [nil, UInt64(0), UInt64(89)] {
            try resizeValidateStatuses([ResizeStatusRecord(status: 2, callbackTicks: 80, displayTicks: display)] + unchanged,
                                       firstDisplay: 90, firstCallback: 100, validatedAt: 220)
        }
        try check(true, "blank statuses wholly before both first-frame clocks remain admitted")
        try rejects("one missing first-frame boundary clock rejected") {
            try resizeValidateStatuses(unchanged, firstDisplay: nil, firstCallback: 100)
        }
        try rejects("positive future status clock beyond final validation rejected") {
            try resizeValidateStatuses(unchanged + [ResizeStatusRecord(status: 1, callbackTicks: 210, displayTicks: 240)],
                                       firstDisplay: 90, firstCallback: 100, validatedAt: 220)
        }
        try rejects("unknown oversized status clock rejected before signed conversion") {
            try resizeValidateStatuses([ResizeStatusRecord(status: 1, callbackTicks: 210, displayTicks: UInt64.max)],
                                       firstDisplay: nil, firstCallback: nil)
        }
        print("WORD " + word(5, 120, 36, 0))
        print("ALL PASS \(checks)")
    }
}
