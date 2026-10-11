// Private native action component. The SCStream runtime calls perform() once after its stream and the
// worker are armed; no process spawn or IPC is included in the metric start.
import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation

struct ResizeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}
func resizeRequire(_ condition: Bool, _ message: String) throws {
    if !condition { throw ResizeFailure(message) }
}

struct ResizeProcessIdentity: PinnedAncestryEndpoint {
    let pid: Int32
    let parentPID: UInt32
    let uid: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executable: String

    static func read(_ pid: Int32) throws -> Self {
        var info = proc_bsdinfo()
        let count = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(MemoryLayout<proc_bsdinfo>.size))
        }
        try resizeRequire(count == MemoryLayout<proc_bsdinfo>.size, "cannot inspect owned process start identity")
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let size = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        try resizeRequire(size > 0, "cannot inspect owned executable")
        return Self(pid: pid, parentPID: info.pbi_ppid, uid: info.pbi_uid, startSeconds: info.pbi_start_tvsec,
                    startMicroseconds: info.pbi_start_tvusec,
                    executable: URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path)
    }
}

struct ResizeBounds: Codable, Equatable, Sendable {
    let x: Double, y: Double, width: Double, height: Double
    var rectangle: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct ResizeObservedWindow: Codable, Equatable, Sendable {
    let index: Int
    let windowID: UInt32
    let ownerPID: Int32
    let layer: Int
    let alpha: Double
    let bounds: ResizeBounds
}

struct ResizeWindowGeometryEvidence: Codable, Equatable, Sendable {
    let appPID: Int32, windowID: UInt32, displayID: UInt32
    let queryStartedTicks: UInt64, queryFinishedTicks: UInt64
    let coordinateSpace: String, order: String
    let displayBounds: ResizeBounds?, displayActive: Bool
    let windowListCount: Int
    let windows: [ResizeObservedWindow]
    let invalidWindowIndices: [Int]
    let ownedWindowIndices: [Int]
    let blockingWindowIndices: [Int]
}

struct ResizeWindowGeometryFailure: Error, CustomStringConvertible {
    let description: String
    let evidence: ResizeWindowGeometryEvidence
}

/// Preserve geometry from the SAME query that refused admission. No later
/// query, title, application name, or unrelated pixel is a diagnostic input.
func resizeFailureFields(_ error: Error) -> [String: Any] {
    var result: [String: Any] = ["error": String(describing: error)]
    if let value = error as? ResizeWindowGeometryFailure {
        do {
            result["windowGeometry"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value.evidence))
        } catch {
            result["windowGeometryEncodingError"] = String(describing: error)
        }
    }
    return result
}

/// Pure interpretation of one CGWindowListCopyWindowInfo on-screen snapshot.
/// Both window and display bounds are CG global coordinates (upper-left
/// origin). Preserve the original complete outer-window overlap perimeter.
func resizeCheckWindowGeometry(_ raw: [[String: Any]], appPID: Int32,
                               windowID: UInt32, displayID: UInt32,
                               displayBounds: CGRect, displayActive: Bool,
                               queryStartedTicks: UInt64, queryFinishedTicks: UInt64) throws -> ResizeBounds {
    func finite(_ bounds: CGRect) -> Bool {
        [bounds.minX, bounds.minY, bounds.width, bounds.height, bounds.maxX, bounds.maxY].allSatisfy(\.isFinite)
            && bounds.width > 0 && bounds.height > 0
    }
    func rectangle(_ bounds: CGRect) -> ResizeBounds {
        ResizeBounds(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height)
    }
    var windows: [ResizeObservedWindow] = [], invalid: [Int] = []
    for (index, value) in raw.prefix(4096).enumerated() {
        guard let id = value[kCGWindowNumber as String] as? UInt32, id > 0,
              let owner = value[kCGWindowOwnerPID as String] as? Int32, owner > 0,
              let layer = value[kCGWindowLayer as String] as? Int,
              let alpha = value[kCGWindowAlpha as String] as? Double, alpha.isFinite, (0...1).contains(alpha),
              let dictionary = value[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary), finite(bounds) else {
            invalid.append(index); continue
        }
        windows.append(ResizeObservedWindow(index: index, windowID: id, ownerPID: owner,
            layer: layer, alpha: alpha, bounds: rectangle(bounds)))
    }
    let owned = windows.filter { $0.ownerPID == appPID && $0.layer == 0 }
    let main = windows.first { $0.windowID == windowID }
    let blockers = main.map { main in
        windows.filter { $0.index < main.index && $0.alpha > 0 && $0.bounds.rectangle.intersects(main.bounds.rectangle) }
            .map(\.index)
    } ?? []
    let evidence = ResizeWindowGeometryEvidence(appPID: appPID, windowID: windowID, displayID: displayID,
        queryStartedTicks: queryStartedTicks, queryFinishedTicks: queryFinishedTicks,
        coordinateSpace: "CG-global-upper-left", order: "front-to-back",
        displayBounds: finite(displayBounds) ? rectangle(displayBounds) : nil, displayActive: displayActive,
        windowListCount: raw.count, windows: windows, invalidWindowIndices: invalid,
        ownedWindowIndices: owned.map(\.index), blockingWindowIndices: blockers)
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ResizeWindowGeometryFailure(description: message, evidence: evidence) }
    }
    try require(raw.count <= 4096 && invalid.isEmpty && Set(windows.map(\.windowID)).count == windows.count,
                "incomplete or ambiguous visible-window metadata")
    try require(queryStartedTicks <= queryFinishedTicks, "window query clock reversed")
    try require(owned.count == 1, "expected exactly one visible owned window")
    guard let main else { throw ResizeWindowGeometryFailure(description: "pinned owned window absent", evidence: evidence) }
    try require(owned[0].windowID == windowID && main.alpha >= 0.999,
                "owned window identity/opacity/rectangle changed")
    try require(displayActive && finite(displayBounds) && displayBounds.contains(main.bounds.rectangle),
                "owned window is not wholly on the pinned display")
    try require(blockers.isEmpty, "another visible window occludes the owned crop")
    return main.bounds
}

struct ResizeWindowProof: Codable, Equatable {
    let identity: ResizeProcessIdentity
    let windowID: UInt32
    let displayID: UInt32
    let bounds: ResizeBounds
    let foregroundPID: Int32
    let occluded: Bool
    let queriedTicks: UInt64

    static func capture(identity expected: ResizeProcessIdentity, windowID: UInt32,
                        displayID: UInt32) throws -> Self {
        let current = try ResizeProcessIdentity.read(expected.pid)
        try resizeRequire(current == expected && current.uid == getuid(), "owned process identity changed")
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        try resizeRequire(foreground == expected.pid, "owned app is not foreground")
        let queryStarted = mach_absolute_time()
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                             kCGNullWindowID) as? [[String: Any]] ?? []
        let queryFinished = mach_absolute_time()
        let bounds = try resizeCheckWindowGeometry(raw, appPID: expected.pid, windowID: windowID,
            displayID: displayID, displayBounds: CGDisplayBounds(displayID), displayActive: CGDisplayIsActive(displayID) != 0,
            queryStartedTicks: queryStarted, queryFinishedTicks: queryFinished)
        return Self(identity: current, windowID: windowID, displayID: displayID,
                    bounds: bounds, foregroundPID: foreground, occluded: false, queriedTicks: mach_absolute_time())
    }
}

struct ResizeActionReceipt: Codable {
    let beforeTicks: UInt64
    let afterTicks: UInt64
    let axResult: Int32
    let axCallCount: Int
    let requestedBounds: ResizeBounds
    let beforeProof: ResizeWindowProof
    let afterProof: ResizeWindowProof?
    let error: String?
    var windowGeometryFailure: ResizeWindowGeometryEvidence? = nil
}

@MainActor
struct OwnedResizeAction {
    let identity: ResizeProcessIdentity
    let executableSHA256: String
    let windowID: UInt32
    let displayID: UInt32

    func preflight() throws {
        try resizeRequire(AXIsProcessTrusted(), "Accessibility is not already authorized")
        try resizeRequire(try ResizeProcessIdentity.read(identity.pid) == identity, "process lifetime changed")
        let actual = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: identity.executable)))
            .map { String(format: "%02x", $0) }.joined()
        try resizeRequire(actual == executableSHA256, "owned executable hash differs")
    }

    func perform(from source: ResizeBounds, to target: ResizeBounds) throws -> ResizeActionReceipt {
        // The runtime verifies binary contents once before/after the block.
        // Per-event identity/AX lookup stays outside the start timestamp.
        try resizeRequire(AXIsProcessTrusted(), "Accessibility is not already authorized")
        try resizeRequire(source.x == target.x && source.y == target.y
            && source != target && target.width.isFinite && target.height.isFinite
            && target.width >= 100 && target.height >= 100, "invalid one-size-only transition")
        let beforeProof = try ResizeWindowProof.capture(identity: identity,
            windowID: windowID, displayID: displayID)
        try resizeRequire(beforeProof.bounds == source, "source size does not match frozen calibration")
        let application = AXUIElementCreateApplication(identity.pid)
        var result: CFTypeRef?
        try resizeRequire(AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString,
            &result) == .success, "cannot query owned AX windows")
        guard let windows = result as? [AXUIElement], windows.count == 1 else {
            throw ResizeFailure("one owned AX window is required")
        }
        var size = CGSize(width: target.width, height: target.height)
        guard let value = AXValueCreate(.cgSize, &size) else { throw ResizeFailure("invalid AX size") }
        // Stream capture/decoding is already armed and buffers bounded metadata
        // until this receipt supplies the exact start, including a display frame
        // that may arrive before the synchronous AX call returns.
        let started = mach_absolute_time()
        let code = AXUIElementSetAttributeValue(windows[0], kAXSizeAttribute as CFString, value)
        let finished = mach_absolute_time()
        var afterProof: ResizeWindowProof?
        var windowFailure: ResizeWindowGeometryEvidence?
        var failure = code == .success ? nil : "single native AX size request failed"
        do {
            afterProof = try ResizeWindowProof.capture(identity: identity,
                windowID: windowID, displayID: displayID)
        } catch {
            windowFailure = (error as? ResizeWindowGeometryFailure)?.evidence
            failure = [failure, String(describing: error)].compactMap { $0 }.joined(separator: "; ")
        }
        // AX may return before target bounds settle. Retain that intermediate
        // state; complete matching frames must independently prove target bounds.
        return ResizeActionReceipt(beforeTicks: started, afterTicks: finished,
            axResult: code.rawValue, axCallCount: 1, requestedBounds: target,
            beforeProof: beforeProof, afterProof: afterProof, error: failure, windowGeometryFailure: windowFailure)
    }
}
