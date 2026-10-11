// Generated-file transport ownership. Pure validation; no native queries.
import Foundation
import CoreGraphics

enum HistoryProofScope: String, Codable {
    case fileTransport = "generated-file-transport-v2"
}

func historyValidateScope(_ scope: HistoryProofScope?, operation: String) throws {
    try resizeRequire(["inspect", "post-key", "observe"].contains(operation), "unknown history operation")
    try resizeRequire(operation != "observe" || scope == nil,
                      "file-transport proof cannot authorize a visual observation")
}

/// This proves an owned foreground on-screen window and stable geometry for
/// a public file action. It deliberately makes NO composed-visibility claim.
struct HistoryFileWindowProof: Encodable {
    let schemaVersion = 2
    let proofScope = HistoryProofScope.fileTransport
    let visualVisibilityVerified = false
    let identity: ResizeProcessIdentity
    let windowID: UInt32, displayID: UInt32
    let bounds: ResizeBounds
    let foregroundPID: Int32
    let onScreen: Bool
    let alpha: Double
    let queriedTicks: UInt64
}

func historyFileWindowProof(_ raw: [[String: Any]], expected: ResizeProcessIdentity,
                           current: ResizeProcessIdentity, observerUID: UInt32,
                           foregroundPID: Int32, windowID: UInt32, displayID: UInt32,
                           displayBounds: CGRect, displayActive: Bool,
                           queriedTicks: UInt64) throws -> HistoryFileWindowProof {
    try resizeRequire(current == expected && expected.uid == observerUID,
                      "file-transport process lifetime changed")
    try resizeRequire(foregroundPID == expected.pid, "file-transport app is not foreground")
    // Ownership and the one-window set must still be unambiguous. Other
    // windows' pixels/alpha are not evidence about the exported file's bytes.
    let identifiers = raw.compactMap { $0[kCGWindowNumber as String] as? UInt32 }
    try resizeRequire(!raw.isEmpty && raw.count <= 4096 && identifiers.count == raw.count
        && identifiers.allSatisfy { $0 > 0 } && Set(identifiers).count == raw.count
        && raw.allSatisfy { ($0[kCGWindowOwnerPID as String] as? Int32).map { $0 > 0 } == true
            && $0[kCGWindowLayer as String] as? Int != nil }, "incomplete file-transport window ownership metadata")
    let owned = raw.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == expected.pid
        && ($0[kCGWindowLayer as String] as? Int) == 0 }
    try resizeRequire(owned.count == 1, "file-transport requires one owned on-screen window")
    guard let window = owned.first,
          (window[kCGWindowNumber as String] as? UInt32) == windowID,
          window[kCGWindowIsOnscreen as String] as? Bool == true,
          let alpha = window[kCGWindowAlpha as String] as? Double, alpha.isFinite, (0.999...1).contains(alpha),
          let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
          let bounds = CGRect(dictionaryRepresentation: dictionary) else {
        throw ResizeFailure("file-transport owned window identity/opacity/geometry differs")
    }
    func finite(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }
    try resizeRequire(displayID > 0 && displayActive && finite(displayBounds) && finite(bounds)
        && displayBounds.contains(bounds) && queriedTicks > 0, "file-transport window is off the pinned display or has invalid geometry/clock")
    return HistoryFileWindowProof(identity: current, windowID: windowID, displayID: displayID,
        bounds: ResizeBounds(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
        foregroundPID: foregroundPID, onScreen: true, alpha: alpha, queriedTicks: queriedTicks)
}
