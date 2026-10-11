// Public native process, TTY, window, and ScreenCaptureKit ownership guards.
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

struct ScrollProcessIdentity: PinnedAncestryEndpoint, Sendable {
    let pid: Int32, parentPID: UInt32, uid: UInt32
    let startSeconds: UInt64, startMicroseconds: UInt64
    let executable: String
}

func scrollIdentity(_ pid: Int32) -> ScrollProcessIdentity? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard withUnsafeMutablePointer(to: &info, {
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
    }) == size else { return nil }
    var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard bytes.withUnsafeMutableBytes({ proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }) > 0 else { return nil }
    return ScrollProcessIdentity(pid: pid, parentPID: info.pbi_ppid, uid: info.pbi_uid,
        startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec,
        executable: URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath().path)
}

func scrollSameProcess(_ value: ScrollProcessIdentity?, _ original: ScrollProcessIdentity) -> Bool {
    guard let value else { return false }
    return value.pid == original.pid && value.uid == original.uid
        && value.startSeconds == original.startSeconds && value.startMicroseconds == original.startMicroseconds
        && value.executable == original.executable
}

private func scrollKernelExecutable(_ pid: Int32) -> String? {
    // WindowServer's BSD accounting record is not readable by this user, but
    // its public proc_pidpath is. Do not confuse an unavailable accounting
    // record with an unverified or name-only cursor owner.
    var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard bytes.withUnsafeMutableBytes({ proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }) > 0 else { return nil }
    return URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath().path
}

func scrollDescendant(_ pid: Int32, of ancestor: Int32) -> Bool {
    var candidate = pid
    var seen = Set<Int32>()
    for _ in 0..<32 {
        guard candidate > 1, seen.insert(candidate).inserted, let info = scrollIdentity(candidate) else { return false }
        if info.parentPID == UInt32(ancestor) { return true }
        candidate = Int32(info.parentPID)
    }
    return false
}

func scrollStampCreatedEvent(_ event: CGEvent) {
    // CGEventTimestamp uses nanoseconds since boot, not raw Mach ticks.
    // Constructed wheel events can otherwise retain a zero timestamp.
    event.timestamp = scrollNS(mach_absolute_time())
}

func scrollNS(_ ticks: UInt64) -> UInt64 {
    var base = mach_timebase_info_data_t()
    mach_timebase_info(&base)
    return ticks / UInt64(base.denom) * UInt64(base.numer)
        + ticks % UInt64(base.denom) * UInt64(base.numer) / UInt64(base.denom)
}

func scrollClock() -> [String: UInt64] {
    ["wallNS": UInt64(Date().timeIntervalSince1970 * 1e9),
     "absoluteTicks": mach_absolute_time(), "continuousTicks": mach_continuous_time()]
}

func scrollEnvironment() -> [String: Any] {
    ["lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
     "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
     "os": ProcessInfo.processInfo.operatingSystemVersionString]
}

func scrollRequire(_ value: Bool, _ message: String) throws {
    if !value { throw ScrollProbeError(message) }
}

final class ScrollOwnership: @unchecked Sendable {
    let app: ScrollProcessIdentity, worker: ScrollProcessIdentity
    let initialAncestry: [String: Any]
    let ttyPath: String, windowID: UInt32, displayID: UInt32
    private let lock = NSLock()
    private var failures: [[String: Any]] = []
    private var boundViewportTop: Double?
    private var lastAcceptedChrome: [ScrollObservedWindow]?
    private var acceptedChrome: [[String: Any]] = []

    init(appPID: Int32, workerPID: Int32, ttyPath: String, windowID: UInt32,
         displayID: UInt32, executable: String, executableSHA256: String) throws {
        guard let app = scrollIdentity(appPID), let worker = scrollIdentity(workerPID),
              app.uid == getuid(), worker.uid == getuid(),
              scrollDescendant(appPID, of: getppid()),
              app.executable == URL(fileURLWithPath: executable).resolvingSymlinksInPath().path,
              scrollHash(try Data(contentsOf: URL(fileURLWithPath: app.executable), options: .mappedIfSafe)) == executableSHA256,
              ttyPath.range(of: "^/dev/ttys[0-9]+$", options: .regularExpression) != nil else {
            throw ScrollProbeError("observer requires the controller's pinned app and descendant fixture")
        }
        let ancestry = observeRepeatedKernelAncestry(app: app, worker: worker, expectedUID: getuid(),
                                                    fullLookup: scrollIdentity)
        guard ancestry.proof != nil else {
            let raw = try JSONSerialization.data(withJSONObject: ancestry.evidence, options: [.sortedKeys])
            throw ScrollProbeError("initial owned ancestry proof failed: " + String(decoding: raw, as: UTF8.self))
        }
        initialAncestry = ancestry.evidence
        self.app = app; self.worker = worker; self.ttyPath = ttyPath
        self.windowID = windowID; self.displayID = displayID
    }

    func failureEvidence() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return failures }
    func chromeEvidence() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return acceptedChrome }
    func recordWindowChange(actual: ScrollWindowProof, expected: ScrollWindowProof) {
        let actualValue = try? JSONSerialization.jsonObject(with: scrollCanonicalJSON(actual))
        let expectedValue = try? JSONSerialization.jsonObject(with: scrollCanonicalJSON(expected))
        lock.lock()
        failures.append(["phase": "window-geometry", "checkedTicks": mach_absolute_time(),
                         "actual": actualValue ?? [:], "expected": expectedValue ?? [:]])
        lock.unlock()
    }
    private func fail(_ evidence: [String: Any], _ message: String) throws -> Never {
        lock.lock(); failures.append(evidence.merging(["error": message], uniquingKeysWith: { _, new in new })); lock.unlock()
        throw ScrollProbeError(message)
    }

    func window(viewportTop requestedViewportTop: Double? = nil) throws -> ScrollWindowProof {
        let current = scrollIdentity(app.pid)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        // Never read titles, arbitrary application names, or unrelated pixels.
        let owned = all.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == app.pid
            && ($0[kCGWindowLayer as String] as? Int) == 0 }
        var record: [String: Any] = ["phase": "window", "checkedTicks": mach_absolute_time(),
            "appPID": app.pid, "frontmostPID": frontmost, "processIdentityValid": scrollSameProcess(current, app)]
        let windows: [[String: Any]] = owned.map { value in
            ["windowID": value[kCGWindowNumber as String] ?? 0,
             "ownerPID": value[kCGWindowOwnerPID as String] ?? 0,
             "alpha": value[kCGWindowAlpha as String] ?? 0,
             "onScreen": value[kCGWindowIsOnscreen as String] ?? false,
             "bounds": value[kCGWindowBounds as String] ?? [:]]
        }
        record["windows"] = windows
        guard scrollSameProcess(current, app), frontmost == app.pid else {
            try fail(record, "owned app/window/focus/display guard failed")
        }
        lock.lock()
        let previousTop = boundViewportTop
        lock.unlock()
        if let previousTop, let requestedViewportTop, previousTop != requestedViewportTop {
            try fail(record, "raster-derived viewport boundary changed")
        }
        let viewportTop = requestedViewportTop ?? previousTop
        if let viewportTop { record["rasterDerivedViewportTop"] = viewportTop }
        var observed: [ScrollObservedWindow] = []
        let admission: ScrollWindowGeometryAdmission
        do {
            observed = try all.map { value in
                guard let id = value[kCGWindowNumber as String] as? UInt32,
                      let owner = value[kCGWindowOwnerPID as String] as? Int32,
                      let layer = value[kCGWindowLayer as String] as? Int,
                      let alpha = value[kCGWindowAlpha as String] as? Double,
                      let onScreen = value[kCGWindowIsOnscreen as String] as? Bool,
                      let raw = value[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: raw) else {
                    throw ScrollWindowGeometryFailure("incomplete visible-window metadata")
                }
                return ScrollObservedWindow(windowID: id, ownerPID: owner, layer: layer,
                    alpha: alpha, onScreen: onScreen, bounds: bounds)
            }
            let excludedCursors = observed.filter { item in
                item.layer == Int(CGWindowLevelForKey(.cursorWindow))
                    && scrollIsCaptureExcludedCursor(layer: item.layer, ownerExecutable: scrollKernelExecutable(item.ownerPID))
            }
            if !excludedCursors.isEmpty {
                record["captureExcludedSystemCursor"] = try JSONSerialization.jsonObject(with: scrollCanonicalJSON(excludedCursors))
            }
            let protected = observed.filter { item in !excludedCursors.contains(item) }
            admission = try scrollAdmitWindowGeometry(protected, appPID: app.pid,
                windowID: windowID, viewportTop: viewportTop)
        } catch {
            record["visibleWindowGeometry"] = try? JSONSerialization.jsonObject(with: scrollCanonicalJSON(observed))
            try fail(record, String(describing: error))
        }
        let bounds = admission.main.bounds
        guard CGDisplayIsActive(displayID) != 0, CGDisplayBounds(displayID).contains(bounds) else {
            try fail(record, "owned main window is not wholly on the pinned display")
        }
        lock.lock()
        if lastAcceptedChrome != admission.chrome || boundViewportTop != viewportTop {
            guard acceptedChrome.count < 4096 else {
                lock.unlock()
                try fail(record, "bounded owned-chrome geometry chronology overflow")
            }
            acceptedChrome.append([
                "checkedTicks": mach_absolute_time(),
                "rasterDerivedViewportTop": viewportTop.map { $0 as Any } ?? NSNull(),
                "windows": (try? JSONSerialization.jsonObject(with: scrollCanonicalJSON(admission.chrome))) ?? []])
            lastAcceptedChrome = admission.chrome
        }
        boundViewportTop = viewportTop
        lock.unlock()
        return ScrollWindowProof(appPID: app.pid, windowID: windowID, frontmostPID: frontmost,
            x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height,
            processStartSeconds: app.startSeconds, processStartMicroseconds: app.startMicroseconds, displayID: displayID)
    }

    func tty(phase: String) throws -> [String: Any] {
        var record: [String: Any] = ["phase": phase, "status": "invalid", "startedTicks": mach_absolute_time(),
            "workerPID": worker.pid, "appPID": app.pid, "ttyPath": ttyPath]
        let same = scrollSameProcess(scrollIdentity(worker.pid), worker)
        record["processIdentityValid"] = same
        let ancestry = observeRepeatedKernelAncestry(app: app, worker: worker, expectedUID: getuid(),
                                                    fullLookup: scrollIdentity)
        record["ancestry"] = ancestry.evidence
        record["workerIsDescendant"] = ancestry.proof != nil
        guard same, record["workerIsDescendant"] as? Bool == true else { try fail(record, "owned worker identity changed") }
        errno = 0
        let fd = open(ttyPath, O_RDONLY | O_NOCTTY | O_NONBLOCK | O_NOFOLLOW)
        record["openResult"] = fd >= 0 ? 0 : -1; record["openErrno"] = fd >= 0 ? 0 : errno
        guard fd >= 0 else { try fail(record, "cannot open owned TTY") }
        defer { close(fd) }
        var size = winsize(), device = stat(), info = proc_bsdinfo()
        errno = 0
        let result = ioctl(fd, TIOCGWINSZ, &size)
        record["windowSizeResult"] = result; record["windowSizeErrno"] = result == 0 ? 0 : errno
        record["columns"] = Int(size.ws_col); record["rows"] = Int(size.ws_row)
        errno = 0
        let externalGroup = tcgetpgrp(fd)
        record["externalTCGetPGRP"] = externalGroup
        record["externalTCGetPGRPErrno"] = externalGroup >= 0 ? 0 : errno
        // An external observer does not own the controlling TTY. ENOTTY above
        // is retained, not treated as missing worker-foreground proof.
        let statResult = fstat(fd, &device)
        let infoResult = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(worker.pid, PROC_PIDTBSDINFO, 0, $0, Int32(MemoryLayout<proc_bsdinfo>.size))
        }
        let deviceID = UInt32(bitPattern: device.st_rdev)
        record["fstatResult"] = statResult; record["openedDeviceID"] = deviceID
        record["openedDeviceIsCharacter"] = (device.st_mode & S_IFMT) == S_IFCHR
        record["processInfoResult"] = infoResult; record["processInfoExpectedBytes"] = MemoryLayout<proc_bsdinfo>.size
        record["workerUID"] = info.pbi_uid; record["observerUID"] = getuid()
        record["workerProcessGroupID"] = info.pbi_pgid; record["workerForegroundProcessGroupID"] = info.e_tpgid
        record["workerControllingDeviceID"] = info.e_tdev
        guard result == 0, size.ws_col == 120, size.ws_row == 36,
              statResult == 0, (device.st_mode & S_IFMT) == S_IFCHR,
              infoResult == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_uid == getuid(),
              info.pbi_pid == UInt32(worker.pid), info.e_tdev == deviceID,
              info.pbi_pgid > 0, info.e_tpgid == info.pbi_pgid else {
            try fail(record, "owned TTY grid/device/foreground proof failed")
        }
        record["status"] = "valid"; record["finishedTicks"] = mach_absolute_time()
        return record
    }
}

struct ScrollRasterFrame: Codable, Sendable {
    let displayTicks: UInt64, callbackTicks: UInt64, windowQueryFinishedTicks: UInt64
    let window: ScrollWindowProof
    let firstRow: Int?
    let checkedPixels: Int
    let canonicalRowsSHA256: String?
}

final class ScrollRasterObservation: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let ownership: ScrollOwnership, fixture: ScrollFixture, expectedWindow: ScrollWindowProof
    private let lock = NSLock()
    private var geometry: ScrollRasterGeometry?
    private var records: [ScrollRasterFrame] = []
    private var failure: String?
    private var generation: UInt64 = 0, after: UInt64 = 0
    private var completeFrames = 0
    private var captureChronology = ScrollCaptureChronology()

    init(ownership: ScrollOwnership, fixture: ScrollFixture, expectedWindow: ScrollWindowProof) {
        self.ownership = ownership; self.fixture = fixture; self.expectedWindow = expectedWindow
    }
    func arm(after: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw ScrollProbeError(failure) }
        generation += 1; self.after = after; records.removeAll(keepingCapacity: true)
    }
    func state() throws -> (ScrollRasterGeometry?, [ScrollRasterFrame], Int) {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw ScrollProbeError(failure) }
        return (geometry, records, completeFrames)
    }
    func retained() -> (ScrollRasterGeometry?, [ScrollRasterFrame], Int, String?) {
        lock.lock(); defer { lock.unlock() }; return (geometry, records, completeFrames, failure)
    }
    func captureStatuses() -> [ScrollCaptureStatusRecord] {
        lock.lock(); defer { lock.unlock() }; return captureChronology.records
    }
    private func fail(_ text: String) { lock.lock(); if failure == nil { failure = text }; lock.unlock() }
    func stream(_ stream: SCStream, didStopWithError error: Error) { fail("capture stopped: \(error.localizedDescription)") }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        lock.lock()
        let callback = mach_absolute_time()
        let statusGeneration = generation, statusCutoff = after
        lock.unlock()
        let attachments = sample.isValid
            ? CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]] : nil
        let metadata = attachments?.first
        let status = metadata?[.status] as? Int
        let display = metadata?[.displayTime] as? NSNumber
        let pixels = sample.isValid ? CMSampleBufferGetImageBuffer(sample) : nil
        lock.lock()
        do {
            try captureChronology.append(ScrollCaptureStatusRecord(callbackTicks: callback,
                displayTicks: display?.uint64Value, statusRaw: status, sampleIsValid: sample.isValid,
                hasImageBuffer: pixels != nil, generation: statusGeneration, armedAfterTicks: statusCutoff))
        } catch {
            if failure == nil { failure = String(describing: error) }
            lock.unlock(); return
        }
        lock.unlock()
        // Preserve revision 02 admission. Status evidence is collected before
        // filtering so a future unpooled pilot can establish actual idle behavior.
        guard sample.isValid, status == SCFrameStatus.complete.rawValue,
              let display, let pixels else { return }
        lock.lock()
        let currentGeneration = generation, cutoff = after, existing = geometry
        lock.unlock()
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
            do { calibrated = try ScrollRaster.calibrate(bytes: bytes, bytesPerRow: stride, width: width, height: height, fixture: fixture) }
            catch { fail(String(describing: error)); return }
        }
        let decoded = calibrated.flatMap { ScrollRaster.decode(bytes: bytes, bytesPerRow: stride, geometry: $0, fixture: fixture) }
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
        let record = ScrollRasterFrame(displayTicks: display.uint64Value, callbackTicks: callback,
            windowQueryFinishedTicks: queried, window: window, firstRow: decoded?.0,
            checkedPixels: decoded?.1 ?? 0,
            canonicalRowsSHA256: decoded.map { fixture.viewports[$0.0].canonicalRowsSHA256 })
        lock.lock(); defer { lock.unlock() }
        completeFrames += 1
        guard generation == currentGeneration else { return }
        guard records.count < 4096 else { failure = "bounded per-event frame chronology overflow"; return }
        if geometry == nil { geometry = calibrated }
        records.append(record)
    }
}

struct ScrollStability: Codable {
    let first: ScrollRasterFrame
    let lastCorrectDisplayTicks: UInt64
    let laterCorrectDistinctFrames: Int
    let validationFinishedTicks: UInt64
}

// Display timestamp ordering is independent from callback ordering. Retain the
// earliest complete target frame, and invalidate any later wrong viewport.
func scrollStable(_ frames: [ScrollRasterFrame], target: Int, now: UInt64,
                  earliestMustPersist: Bool = true) throws -> ScrollStability? {
    let ordered = frames.sorted { $0.displayTicks < $1.displayTicks }
    var seen: [UInt64: Int] = [:]
    for frame in ordered {
        let row = frame.firstRow ?? -1
        if let previous = seen[frame.displayTicks], previous != row {
            throw ScrollProbeError("conflicting viewports share one WindowServer timestamp")
        }
        seen[frame.displayTicks] = row
    }
    guard let first = ordered.first(where: { $0.firstRow == target }) else { return nil }
    let wrongAfter = ordered.contains { $0.displayTicks > first.displayTicks && $0.firstRow != target }
    if wrongAfter {
        if earliestMustPersist { throw ScrollProbeError("viewport changed after its first complete target frame") }
        return nil
    }
    let later = Set(ordered.filter { $0.firstRow == target && $0.displayTicks > first.displayTicks }.map(\.displayTicks))
    guard let last = later.max(), later.count >= 2, now >= last,
          scrollNS(last - first.displayTicks) >= 250_000_000 else { return nil }
    return ScrollStability(first: first, lastCorrectDisplayTicks: last,
        laterCorrectDistinctFrames: later.count, validationFinishedTicks: now)
}
