// Pure calibrated full-width generated-cell matcher + serial observation state.
// Every target cell is observed. This fixture does not test glyph rendering. The native runtime
// is resize_observer.swift; synthetic tests do not start that runtime.
import CoreMedia
import CoreVideo
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit

struct ResizeRGB: Codable, Equatable {
    let red: Int, green: Int, blue: Int
}

struct ResizeDisplayModeSignature: Codable, Equatable {
    let modeID: UInt32
    let flags: UInt32
    let width: Int, height: Int
    let pixelWidth: Int, pixelHeight: Int
    let refreshRate: Double
    let rotation: Double

    func validate() throws {
        try resizeRequire(width > 0 && height > 0 && pixelWidth > 0 && pixelHeight > 0
            && refreshRate.isFinite && refreshRate >= 0 && rotation == 0,
            "invalid or unsupported pinned display mode")
    }

    func requireUnchanged(_ current: Self) throws {
        try validate(); try current.validate()
        try resizeRequire(self == current, "pinned display mode/refresh/rotation changed")
    }

    static func read(_ displayID: UInt32) throws -> Self {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            throw ResizeFailure("pinned display mode is unavailable")
        }
        let value = Self(modeID: UInt32(bitPattern: mode.ioDisplayModeID), flags: mode.ioFlags,
            width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate,
            rotation: CGDisplayRotation(displayID))
        try value.validate()
        return value
    }
}

struct ResizeRasterCalibration: Codable {
    let fixtureVersion: Int
    let columns: Int, rows: Int
    let outerBounds: ResizeBounds
    let displayBounds: ResizeBounds
    let displayMode: ResizeDisplayModeSignature
    let captureWidth: Int, captureHeight: Int
    let xWithinWindowPixels: Double
    let yWithinWindowPixels: Double
    let cellWidthPixels: Double
    let rowPitchPixels: Double
    let rowSampleOffsets: [Double]
    let colors: [ResizeRGB] // sixteen digit classes + start/end sentinel
    let tolerance: Int
    let discoveryEvidenceSHA256: String

    func validate() throws {
        try displayMode.validate()
        try resizeRequire(fixtureVersion == resizeFixtureVersion, "wrong resize fixture version")
        try resizeRequire([(120, 36), (132, 40)].contains { $0.0 == columns && $0.1 == rows },
                          "unsupported calibrated grid")
        try resizeRequire(captureWidth == displayMode.pixelWidth && captureHeight == displayMode.pixelHeight
            && [outerBounds.x, outerBounds.y, outerBounds.width, outerBounds.height,
                displayBounds.x, displayBounds.y, displayBounds.width, displayBounds.height].allSatisfy(\.isFinite)
            && outerBounds.width > 0 && outerBounds.height > 0
            && displayBounds.width > 0 && displayBounds.height > 0
            && displayBounds.rectangle.contains(outerBounds.rectangle)
            && cellWidthPixels.isFinite && rowPitchPixels.isFinite
            && cellWidthPixels >= 3 && rowPitchPixels >= 3
            && xWithinWindowPixels.isFinite && yWithinWindowPixels.isFinite
            && xWithinWindowPixels >= 0 && yWithinWindowPixels >= 0,
            "invalid raster scale/origin")
        try resizeRequire(colors.count == 18 && tolerance == 3
            && rowSampleOffsets.count == 3
            && rowSampleOffsets.allSatisfy { $0.isFinite && $0 >= 1 && $0 < rowPitchPixels - 1 }
            && rowSampleOffsets[0] < rowSampleOffsets[1] && rowSampleOffsets[1] < rowSampleOffsets[2],
            "invalid fixed palette/sample geometry")
        let sx = Double(captureWidth) / displayBounds.width
        let sy = Double(captureHeight) / displayBounds.height
        try resizeRequire(xWithinWindowPixels + Double(columns) * cellWidthPixels <= outerBounds.width * sx
            && yWithinWindowPixels + Double(rows) * rowPitchPixels <= outerBounds.height * sy + 1,
            "entire target grid does not fit the owned window")
        for index in colors.indices {
            let color = colors[index]
            try resizeRequire([color.red, color.green, color.blue].allSatisfy { (0...255).contains($0) },
                              "invalid calibrated sRGB color")
            for other in colors.dropFirst(index + 1) {
                let distance = max(abs(color.red - other.red), abs(color.green - other.green),
                                   abs(color.blue - other.blue))
                try resizeRequire(distance > tolerance * 4, "ambiguous calibrated color classes")
            }
        }
        try resizeRequire(discoveryEvidenceSHA256.count == 64
            && discoveryEvidenceSHA256.allSatisfy { "0123456789abcdef".contains($0) },
            "missing unpooled geometry discovery proof")
    }
}

struct ResizeFrameExpectation: Codable {
    let nonce: String
    let sequence: UInt32
    let words: [String] // Exact 60-hex words generated by the frozen protocol.
    let calibration: ResizeRasterCalibration
    // Runtime regenerates these from nonce+sequence+target, never manual words.
}

func resizeSignedNS(_ end: UInt64, _ start: UInt64) throws -> Int64 {
    try resizeRequire(end <= UInt64(Int64.max) && start <= UInt64(Int64.max), "invalid signed clock ticks")
    var base = mach_timebase_info_data_t()
    mach_timebase_info(&base)
    try resizeRequire(base.numer > 0 && base.denom > 0, "invalid mach clock timebase")
    let value = end >= start ? end - start : start - end
    let whole = (value / UInt64(base.denom)).multipliedReportingOverflow(by: UInt64(base.numer))
    let remainder = value % UInt64(base.denom) * UInt64(base.numer) / UInt64(base.denom)
    let sum = whole.partialValue.addingReportingOverflow(remainder)
    try resizeRequire(!whole.overflow && !sum.overflow && sum.partialValue <= UInt64(Int64.max),
                      "signed clock conversion exceeds bound")
    let ns = sum.partialValue
    return end >= start ? Int64(ns) : -Int64(ns)
}

func resizeObservedCellClasses(_ pixels: CVPixelBuffer, calibration geometry: ResizeRasterCalibration,
                               window: ResizeBounds) throws -> Data? {
    try geometry.validate()
    try resizeRequire(window == geometry.outerBounds, "matching frame has wrong native bounds")
    guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
          CVPixelBufferGetWidth(pixels) == geometry.captureWidth,
          CVPixelBufferGetHeight(pixels) == geometry.captureHeight else {
        throw ResizeFailure("capture format/resolution differs from calibration")
    }
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    guard let address = CVPixelBufferGetBaseAddress(pixels) else { return nil }
    let data = address.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixels)
    let sx = Double(geometry.captureWidth) / geometry.displayBounds.width
    let sy = Double(geometry.captureHeight) / geometry.displayBounds.height
    let windowX = (window.x - geometry.displayBounds.x) * sx
    let windowY = (window.y - geometry.displayBounds.y) * sy
    let minX = Int(ceil(windowX)), minY = Int(ceil(windowY))
    let maxX = Int(floor(windowX + window.width * sx))
    let maxY = Int(floor(windowY + window.height * sy))
    try resizeRequire(minX >= 0 && minY >= 0 && maxX <= geometry.captureWidth
        && maxY <= geometry.captureHeight && minX < maxX && minY < maxY,
        "owned crop is not wholly inside display pixels")
    let originX = windowX + geometry.xWithinWindowPixels
    let originY = windowY + geometry.yWithinWindowPixels
    var observed = Data(capacity: geometry.rows * geometry.columns)
    for row in 0..<geometry.rows {
        for column in 0..<geometry.columns {
            let x = Int(floor(originX + (Double(column) + 0.5) * geometry.cellWidthPixels))
            var observedClass: Int?
            for offset in geometry.rowSampleOffsets {
                let y = Int(floor(originY + Double(row) * geometry.rowPitchPixels + offset))
                for delta in -1...1 {
                    guard x + delta >= minX, x + delta < maxX, y >= minY, y < maxY else { return nil }
                    let i = y * stride + (x + delta) * 4
                    guard data[i + 3] >= 250 else { return nil }
                    func matches(_ color: ResizeRGB) -> Bool {
                        abs(Int(data[i]) - color.blue) <= geometry.tolerance
                            && abs(Int(data[i + 1]) - color.green) <= geometry.tolerance
                            && abs(Int(data[i + 2]) - color.red) <= geometry.tolerance
                    }
                    if let observedClass {
                        guard matches(geometry.colors[observedClass]) else { return nil }
                    } else {
                        // Infer the first class from actual pixels, independently
                        // of the nonce, expected row word or expected cell index.
                        guard let index = geometry.colors.firstIndex(where: matches) else { return nil }
                        observedClass = index
                    }
                }
            }
            guard let observedClass else { return nil }
            observed.append(UInt8(observedClass))
        }
    }
    return observed
}

func resizeMatchingCellClasses(_ pixels: CVPixelBuffer, expected: ResizeFrameExpectation,
                               window: ResizeBounds) throws -> Data? {
    try resizeRequire(expected.words.count == expected.calibration.rows
        && expected.words.allSatisfy { $0.utf8.count == 60 && $0.allSatisfy { "0123456789abcdef".contains($0) } },
        "invalid expected every-row word table")
    guard let observed = try resizeObservedCellClasses(pixels, calibration: expected.calibration, window: window) else { return nil }
    let wanted = Data(expected.words.flatMap { resizeCellClasses(word: $0, columns: expected.calibration.columns).map(UInt8.init) })
    return observed == wanted ? observed : nil
}

func resizeMatches(_ pixels: CVPixelBuffer, expected: ResizeFrameExpectation,
                   window: ResizeBounds) throws -> Bool {
    try resizeMatchingCellClasses(pixels, expected: expected, window: window) != nil
}

struct ResizeFrameRecord: Codable {
    let displayTicks: UInt64
    let callbackTicks: UInt64
    let checkedTicks: UInt64
    let matching: Bool
    let before: ResizeWindowProof
    let after: ResizeWindowProof
    var observedCellClasses: Data? = nil
}

struct ResizeStatusRecord: Codable {
    let status: Int
    let callbackTicks: UInt64
    let displayTicks: UInt64?
}

func resizeValidateFrameCoverage(_ frames: [ResizeFrameRecord], _ statuses: [ResizeStatusRecord]) throws {
    let complete = statuses.filter { $0.status == SCFrameStatus.complete.rawValue }
    try resizeRequire(frames.count == complete.count && frames.count <= 500,
                      "complete frame/status coverage differs")
    var previous: (UInt64, UInt64)?
    for (frame, status) in zip(frames, complete) {
        try resizeRequire(frame.callbackTicks == status.callbackTicks && frame.displayTicks == status.displayTicks,
                          "complete frame/status order differs")
        if let previous {
            try resizeRequire(previous.0 != frame.callbackTicks || previous.1 != frame.displayTicks,
                              "duplicate complete frame/status pair")
        }
        previous = (frame.callbackTicks, frame.displayTicks)
    }
}

func resizeValidateStatuses(_ records: [ResizeStatusRecord], firstDisplay: UInt64?, firstCallback: UInt64?,
                            validatedAt: UInt64? = nil) throws {
    try resizeRequire(records.count <= 500, "per-event SCK status bound exceeded")
    try resizeRequire((firstDisplay == nil) == (firstCallback == nil), "incomplete first-frame clock pair")
    for ticks in [firstDisplay, firstCallback, validatedAt].compactMap({ $0 }) {
        try resizeRequire(ticks > 0 && ticks <= UInt64(Int64.max), "invalid status boundary clock")
    }
    var previous: UInt64 = 0
    for record in records {
        try resizeRequire((SCFrameStatus.complete.rawValue...SCFrameStatus.stopped.rawValue).contains(record.status)
            && record.callbackTicks > 0 && record.callbackTicks <= UInt64(Int64.max)
            && record.callbackTicks >= previous, "unknown or unordered SCK status")
        previous = record.callbackTicks
        if let display = record.displayTicks {
            try resizeRequire(display <= UInt64(Int64.max), "invalid status display clock")
        }
        if record.status == SCFrameStatus.complete.rawValue {
            try resizeRequire((record.displayTicks ?? 0) > 0, "complete status lacks positive display clock")
        }
        if let validatedAt {
            try resizeRequire(record.callbackTicks <= validatedAt && (record.displayTicks ?? 0) <= validatedAt,
                              "status clocks are outside final validation")
        }
        try resizeRequire(record.status != SCFrameStatus.suspended.rawValue
            && record.status != SCFrameStatus.stopped.rawValue, "SCK suspended or stopped during event")
        if let firstDisplay, let firstCallback,
           record.callbackTicks >= firstCallback || (record.displayTicks ?? 0) >= firstDisplay {
            // Idle explicitly means unchanged pixels. It is not a new endpoint,
            // and it does not require another complete static-content frame.
            // An earlier callback can describe a later display time; neither
            // clock may hide blank/restarted capture during stability.
            try resizeRequire(record.status == SCFrameStatus.complete.rawValue
                || record.status == SCFrameStatus.idle.rawValue,
                "SCK became blank or restarted after first complete repaint")
        }
    }
}

// All access must occur on the single serial observer queue. This state never
// schedules redraws or changes the application. The runtime must bound/stop
// capture on timeout, stream failure, screen lock or ownership loss.
struct ResizeObservationState {
    private(set) var startTicks: UInt64?
    private(set) var actionReturnTicks: UInt64?
    private(set) var firstCompleteMatch: ResizeFrameRecord?
    private(set) var frames: [ResizeFrameRecord] = []
    private(set) var lastDisplayTicks: UInt64?

    var validationNotBeforeTicks: UInt64 {
        frames.reduce(actionReturnTicks ?? 0) { max($0, max($1.displayTicks, $1.checkedTicks)) }
    }

    mutating func begin(at ticks: UInt64) throws {
        try resizeRequire(startTicks == nil && ticks > 0 && ticks <= UInt64(Int64.max),
                          "one observer state needs one valid AX request clock")
        startTicks = ticks
    }

    mutating func actionReturned(at ticks: UInt64) throws {
        guard let startTicks else { throw ResizeFailure("action was not started") }
        try resizeRequire(actionReturnTicks == nil && ticks >= startTicks && ticks <= UInt64(Int64.max),
                          "invalid AX timestamp order")
        actionReturnTicks = ticks
    }

    mutating func receive(_ record: ResizeFrameRecord) throws {
        guard let startTicks else { return }
        try resizeRequire(frames.count < 500, "per-event frame metadata bound exceeded")
        try resizeRequire([record.displayTicks, record.callbackTicks, record.checkedTicks,
                           record.before.queriedTicks, record.after.queriedTicks]
            .allSatisfy { $0 > 0 && $0 <= UInt64(Int64.max) }, "invalid SCK clock ticks")
        try resizeRequire(record.callbackTicks <= record.before.queriedTicks
            && record.before.queriedTicks <= record.after.queriedTicks
            && record.after.queriedTicks <= record.checkedTicks
            && record.callbackTicks >= (frames.last?.callbackTicks ?? 0), "invalid signed SCK clock ordering")
        // displayTime and callback time share mach-absolute units but are not
        // ordered by the SDK. Preserve signed lag and enclose both at result().
        if let lastDisplayTicks {
            try resizeRequire(record.displayTicks >= lastDisplayTicks, "SCK display clock regressed")
        }
        lastDisplayTicks = record.displayTicks
        // A stream callback can deliver an older composed frame after action.
        // Preserve it as evidence, but never use it as this event's endpoint.
        var metadata = record
        metadata.observedCellClasses = nil
        frames.append(metadata)
        guard record.displayTicks >= startTicks else { return }
        try resizeRequire(record.before.identity == record.after.identity
            && record.before.windowID == record.after.windowID
            && record.before.displayID == record.after.displayID
            && record.before.foregroundPID == record.before.identity.pid
            && record.after.foregroundPID == record.after.identity.pid
            && !record.before.occluded && !record.after.occluded,
            "ownership changed around frame decode")
        if firstCompleteMatch != nil {
            try resizeRequire(record.matching, "correct first frame did not remain stable")
        } else if record.matching {
            try resizeRequire(record.callbackTicks >= startTicks && record.before.bounds == record.after.bounds,
                              "native bounds changed around first complete decode")
            firstCompleteMatch = record
            frames[frames.count - 1].observedCellClasses = record.observedCellClasses
        }
    }

    func result(at finishedTicks: UInt64, target: ResizeBounds,
                finalProof: ResizeWindowProof) throws -> [String: Int64] {
        guard let startTicks, let actionReturnTicks, let first = firstCompleteMatch else {
            throw ResizeFailure("no first complete repaint or completed AX request")
        }
        try resizeRequire(finishedTicks > 0 && finishedTicks <= UInt64(Int64.max)
            && finalProof.queriedTicks >= validationNotBeforeTicks && finalProof.queriedTicks <= finishedTicks,
            "frame/action clocks are outside final validation")
        try resizeRequire(try resizeSignedNS(finishedTicks, max(first.displayTicks, first.callbackTicks)) >= 50_000_000,
                          "50ms after both first-frame clocks has not completed")
        try resizeRequire(try resizeSignedNS(finishedTicks, startTicks) <= 3_000_000_000,
                          "bounded event validation exceeded 3 seconds")
        try resizeRequire(finalProof.bounds == target && first.before.bounds == target
            && finalProof.identity == first.before.identity
            && finalProof.windowID == first.before.windowID
            && finalProof.displayID == first.before.displayID
            && finalProof.foregroundPID == finalProof.identity.pid && !finalProof.occluded,
            "final native state is not the same owned calibrated target")
        return try ["requestToFrameNS": resizeSignedNS(first.displayTicks, startTicks),
                "requestReturnOffsetNS": resizeSignedNS(actionReturnTicks, startTicks),
                "frameMinusRequestReturnNS": resizeSignedNS(first.displayTicks, actionReturnTicks),
                "captureCallbackLagNS": resizeSignedNS(first.callbackTicks, first.displayTicks),
                "stabilityValidationNS": resizeSignedNS(finishedTicks, first.callbackTicks)]
    }
}

// Implemented SCStream runtime invariants (resize_observer.swift):
// 1. Load pinned calibration + process/window/display/source hashes; reject
//    arbitrary manual geometry or missing discovery/fresh-process evidence.
// 2. Start one native-resolution display stream, BGRA/sRGB, audio/cursor off,
//    queueDepth=3 and minimumFrameInterval=1/120; prearm before worker ACK.
// 3. Preserve .complete/.idle/suspended metadata; complete frames require a
//    UInt64 displayTime. Idle is not a new complete frame. Suspended is fatal.
// 4. For complete frames query strict owned proof before and after decoding.
//    Only call resizeMatches when exact calibrated target bounds are present.
//    Consume every complete frame on the same queue; never replace first match.
// 5. Worker arm ACK occurs outside measurement. Decode and retain bounded frame
//    metadata before AX begins. A main-actor one-shot action then publishes its
//    before/after ticks; initialize state and replay buffered records in order.
//    A frame can precede AX return and must not be dropped. Cross-queue ordering
//    needs a lock/serial protocol; never retain an unbounded CVPixelBuffer queue.
// 6. Continue capture 50ms after both first-match clocks, verify exact final real TTY grid,
//    then write metadata. Timeout at 3 seconds, fail closed and retain receipts.
// 7. No activation, crop adaptation, file writes, config mutation, AX fitting,
//    screenshot storage or process signaling is allowed within an event.
