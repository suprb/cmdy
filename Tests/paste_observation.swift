// Paste capture records, with 120-column response decoding.
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

struct PasteRasterFrame: Codable, Sendable {
    let displayTicks: UInt64, callbackTicks: UInt64, windowQueryFinishedTicks: UInt64
    let window: ScrollWindowProof
    let firstRow: Int?
    let checkedPixels: Int
    let canonicalRowsSHA256: String?
    let observedCellClasses: Data?
}

// Native capture can continuously service a dispatch source on sampleQueue.
// Arming must not wait for that queue to become idle. The lock makes the epoch
// change atomic; a decoder already in flight can only publish to its own epoch.
class PasteRasterState: NSObject, @unchecked Sendable {
    let sampleQueue = DispatchQueue(label: "cmdy.paste-observer", qos: .userInteractive)
    private let lock = NSLock()
    private var geometry: PasteRasterGeometry?
    private var records: [PasteRasterFrame] = []
    private var failure: String?
    private var generation: UInt64 = 0, after: UInt64 = 0
    private var completeFrames = 0
    private var captureChronology = ScrollCaptureChronology()

    func arm() throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw ScrollProbeError(failure) }
        let boundary = mach_absolute_time()
        generation += 1; after = boundary; records.removeAll(keepingCapacity: true)
        return boundary
    }
    func callbackEpoch() -> (ticks: UInt64, generation: UInt64, after: UInt64, geometry: PasteRasterGeometry?) {
        lock.lock(); defer { lock.unlock() }
        return (mach_absolute_time(), generation, after, geometry)
    }
    func captureStatus(_ record: ScrollCaptureStatusRecord) -> Bool {
        lock.lock(); defer { lock.unlock() }
        do { try captureChronology.append(record); return true }
        catch { if failure == nil { failure = String(describing: error) }; return false }
    }
    @discardableResult
    func append(_ record: PasteRasterFrame, epoch: UInt64, calibrated: PasteRasterGeometry?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        completeFrames += 1
        guard generation == epoch, record.displayTicks > after else { return false }
        guard records.count < 4096 else { failure = "bounded per-event frame chronology overflow"; return false }
        if geometry == nil { geometry = calibrated }
        records.append(record)
        return true
    }
    /// Call only after stopCapture has completed. Drain every pending decoder
    /// before taking the final evidence snapshot and guard-end timestamp.
    func finishedState() throws -> ([PasteRasterFrame], [ScrollCaptureStatusRecord], UInt64) {
        try sampleQueue.sync {
            lock.lock(); defer { lock.unlock() }
            if let failure { throw ScrollProbeError(failure) }
            return (records, captureChronology.records, mach_absolute_time())
        }
    }
    func state() throws -> (PasteRasterGeometry?, [PasteRasterFrame], Int) {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw ScrollProbeError(failure) }
        return (geometry, records, completeFrames)
    }
    func retained() -> (PasteRasterGeometry?, [PasteRasterFrame], Int, String?) {
        lock.lock(); defer { lock.unlock() }; return (geometry, records, completeFrames, failure)
    }
    func captureStatuses() -> [ScrollCaptureStatusRecord] {
        lock.lock(); defer { lock.unlock() }; return captureChronology.records
    }
    func fail(_ text: String) { lock.lock(); if failure == nil { failure = text }; lock.unlock() }
}

final class PasteRasterObservation: PasteRasterState, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let ownership: ScrollOwnership, fixture: PasteFixture, expectedWindow: ScrollWindowProof

    init(ownership: ScrollOwnership, fixture: PasteFixture, expectedWindow: ScrollWindowProof) {
        self.ownership = ownership; self.fixture = fixture; self.expectedWindow = expectedWindow
        super.init()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { fail("capture stopped: \(error.localizedDescription)") }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let epoch = callbackEpoch()
        let callback = epoch.ticks
        let attachments = sample.isValid
            ? CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]] : nil
        let metadata = attachments?.first
        let status = metadata?[.status] as? Int
        let display = metadata?[.displayTime] as? NSNumber
        let pixels = sample.isValid ? CMSampleBufferGetImageBuffer(sample) : nil
        guard captureStatus(ScrollCaptureStatusRecord(callbackTicks: callback,
                displayTicks: display?.uint64Value, statusRaw: status, sampleIsValid: sample.isValid,
                hasImageBuffer: pixels != nil, generation: epoch.generation, armedAfterTicks: epoch.after)) else { return }
        // Status chronology includes idle and error statuses; only complete
        // native buffers can acknowledge a full-width paste response.
        guard sample.isValid, status == SCFrameStatus.complete.rawValue,
              let display, let pixels else { return }
        let cutoff = epoch.after, existing = epoch.geometry
        guard display.uint64Value > cutoff else { return }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              existing == nil || (existing!.width == width && existing!.height == height) else {
            fail("capture raster changed after calibration"); return
        }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { fail("missing BGRA buffer"); return }
        let bytes = base.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pixels)
        var calibrated = existing
        if calibrated == nil {
            do { calibrated = try PasteRaster.calibrate(bytes: bytes, bytesPerRow: stride, width: width, height: height, fixture: fixture) }
            catch { fail(String(describing: error)); return }
        }
        let observedClasses = calibrated.map { PasteRaster.observedCellClasses(bytes: bytes, bytesPerRow: stride, geometry: $0) }
        let decoded = calibrated.flatMap { PasteRaster.decode(bytes: bytes, bytesPerRow: stride, geometry: $0, fixture: fixture) }
        // Discover the complete generated raster before classifying auxiliary
        // chrome. Only a full 36-row calibration can supply this boundary; a
        // size/name heuristic cannot excuse a second window over terminal cells.
        let viewportTop = calibrated.map {
            expectedWindow.y + Double($0.rowBands[0].lower) * expectedWindow.height / Double(height)
        }
        let window: ScrollWindowProof
        do {
            window = try ownership.window(viewportTop: viewportTop)
            guard window == expectedWindow else {
                ownership.recordWindowChange(actual: window, expected: expectedWindow)
                fail("owned window moved/resized during capture"); return
            }
        } catch { fail(String(describing: error)); return }
        let queried = mach_absolute_time()
        let record = PasteRasterFrame(displayTicks: display.uint64Value, callbackTicks: callback,
            windowQueryFinishedTicks: queried, window: window, firstRow: decoded?.0,
            checkedPixels: decoded?.1 ?? 0,
            canonicalRowsSHA256: decoded.map { fixture.viewports[$0.0].canonicalRowsSHA256 },
            observedCellClasses: observedClasses)
        append(record, epoch: epoch.generation, calibrated: calibrated)
    }
}

struct PasteStableFrame: Codable {
    let first: PasteRasterFrame
    let guardStartedTicks: UInt64
    let validationFinishedTicks: UInt64
    let laterCorrectDistinctFrames: Int
}

// Idle samples are retained as idle. A 250 ms observation guard cannot replace
// the actual first complete response frame, move its timestamp, or synthesize
// frame acknowledgements from timer ticks. Every complete frame in the guard
// must agree; blank/suspended/stopped/invalid samples fail closed.
func pasteStable(_ frames: [PasteRasterFrame], statuses: [ScrollCaptureStatusRecord],
                 target: Int, after: UInt64, now: UInt64) throws -> PasteStableFrame? {
    let ordered = frames.sorted { $0.displayTicks < $1.displayTicks }
    var seen: [UInt64: Int] = [:]
    for frame in ordered {
        try scrollRequire(frame.displayTicks > after, "paste frame predates its dispatch boundary")
        let row = frame.firstRow ?? -1
        if let previous = seen[frame.displayTicks], previous != row {
            throw ScrollProbeError("conflicting viewports share one WindowServer timestamp")
        }
        seen[frame.displayTicks] = row
    }
    guard let first = ordered.first(where: { $0.firstRow == target }) else { return nil }
    try scrollRequire(!ordered.contains { $0.displayTicks >= first.displayTicks && $0.firstRow != target },
                      "paste viewport regressed after its first complete response frame")
    for status in statuses where status.armedAfterTicks == after && status.callbackTicks >= first.callbackTicks {
        try scrollRequire(status.sampleIsValid && status.statusRaw != nil
            && [SCFrameStatus.complete.rawValue, SCFrameStatus.idle.rawValue].contains(status.statusRaw!),
            "paste capture became invalid, blank, suspended, restarted, or stopped during the response guard")
        if status.statusRaw == SCFrameStatus.complete.rawValue {
            try scrollRequire(status.hasImageBuffer && status.displayTicks != nil,
                              "complete paste capture status is missing its native raster/timestamp")
        }
    }
    let guardStarted = max(first.displayTicks, first.callbackTicks)
    guard now >= guardStarted, scrollNS(now - guardStarted) >= 250_000_000 else { return nil }
    let later = Set(ordered.filter { $0.firstRow == target && $0.displayTicks > first.displayTicks }.map(\.displayTicks))
    return PasteStableFrame(first: first, guardStartedTicks: guardStarted,
        validationFinishedTicks: now, laterCorrectDistinctFrames: later.count)
}
