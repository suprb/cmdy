// Pure first-visible chronology. Pixel matching and process launch are separate.
import Foundation

let startupProtocol = "startup-full-generated-viewport-v5"
let startupMetric = "native-spawn-to-first-complete-generated-viewport"
let startupForegroundMethod = "system-wide-AXFocusedApplication-bracketed-PID"

struct StartupAccessibilityFront: Codable {
    let startedTicks: UInt64, finishedTicks: UInt64
    let queryStatus: Int, pidStatus: Int, timeoutStatus: Int
    let trusted: Bool
    let pid: Int32
}
struct StartupForegroundDiagnostic: Codable {
    let before: StartupAccessibilityFront
    let cocoaPID: Int32
    let cocoaTicks: UInt64
    let after: StartupAccessibilityFront
    let queriedTicks: UInt64
    func observedPID() -> Int32 {
        guard before.startedTicks > 0 && before.startedTicks <= before.finishedTicks
            && before.finishedTicks <= cocoaTicks && cocoaTicks <= after.startedTicks
            && after.startedTicks <= after.finishedTicks && after.finishedTicks <= queriedTicks
            && queriedTicks <= UInt64(Int64.max), before.pid > 0 && before.pid == after.pid,
            [before, after].allSatisfy({ $0.trusted && $0.queryStatus == 0
                && $0.pidStatus == 0 && $0.timeoutStatus == 0 }) else { return -1 }
        return before.pid
    }
}

/// Optional top-level values encode as JSON null, which is a valid fragment.
func startupJSONValue<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
}

func startupWriteReport(_ report: [String: Any], to output: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    try data.write(to: output, options: .withoutOverwriting)
}

/// Owned cleanup always finishes before diagnostic encoding or disk output.
/// Encoding failure retains the original error and actual cleanup result.
@MainActor func startupFinalizeReport(
    _ initial: [String: Any], cleanup: () async -> [String: Any],
    appendDiagnostics: (inout [String: Any]) throws -> Void,
    write: ([String: Any]) throws -> Void
) async throws -> [String: Any] {
    var base = initial
    let ended = await cleanup()
    base["cleanup"] = ended
    if ended["appReaped"] as? Bool != true || ended["workerGone"] as? Bool != true {
        base["status"] = "invalid"
        base["cleanupError"] = "owned processes not both absent"
    }
    var result = base
    do {
        try appendDiagnostics(&result)
    } catch {
        result = base
        result["status"] = "invalid"
        result["serializationError"] = String(describing: error)
    }
    try write(result)
    return result
}

struct StartupStatus: Codable {
    let status: Int
    let displayTicks: UInt64?
    let callbackTicks: UInt64
}

struct StartupFrame: Codable {
    let displayTicks: UInt64, callbackTicks: UInt64, checkedTicks: UInt64
    let stage: String
    let before: ResizeWindowProof?
    let after: ResizeWindowProof?
    let proofSHA256: String?
}

struct StartupObservation {
    let displayBounds: ResizeBounds
    let targetColumns: Int
    let targetRows: Int
    init(displayBounds: ResizeBounds, targetColumns: Int = 98, targetRows: Int = 29) {
        self.displayBounds = displayBounds
        self.targetColumns = targetColumns
        self.targetRows = targetRows
    }
    private(set) var frames: [StartupFrame] = []
    private(set) var statuses: [StartupStatus] = []
    private(set) var proofs: [String: StartupGridProof] = [:]
    private(set) var first: StartupFrame?
    private(set) var latest: StartupFrame?
    private(set) var settledSince: UInt64?
    private var settledRaster: StartupGridRaster?
    private(set) var prelaunch: StartupFrame?
    private(set) var launchBefore: UInt64?
    private(set) var launchAfter: UInt64?
    private(set) var app: ResizeProcessIdentity?

    mutating func status(_ item: StartupStatus) throws {
        try resizeRequire(statuses.count < 2000 && (0...5).contains(item.status)
            && item.status != 3 && item.status != 5
            && item.callbackTicks > 0 && item.callbackTicks <= UInt64(Int64.max)
            && item.callbackTicks >= (statuses.last?.callbackTicks ?? 0)
            && (item.displayTicks ?? 0) <= UInt64(Int64.max)
            && (item.status != 0 || (item.displayTicks ?? 0) > 0), "invalid startup capture status/clock")
        if let first, item.callbackTicks >= first.callbackTicks || (item.displayTicks ?? 0) >= first.displayTicks {
            try resizeRequire(item.status == 0 || item.status == 1, "capture blank/restart after first viewport")
        }
        statuses.append(item)
    }

    func prelaunchReady(at tick: UInt64) -> Bool {
        guard launchBefore == nil, let prelaunch else { return false }
        return max(prelaunch.displayTicks, prelaunch.checkedTicks) < tick
    }

    mutating func launch(before: UInt64, after: UInt64, identity: ResizeProcessIdentity) throws {
        guard let prelaunch else { throw ResizeFailure("no complete capture before app launch") }
        try resizeRequire(launchBefore == nil && before > 0 && before <= after
            && after <= UInt64(Int64.max) && prelaunch.displayTicks < before
            && prelaunch.checkedTicks < before, "capture was not armed before native spawn")
        launchBefore = before; launchAfter = after; app = identity
    }

    mutating func receive(_ frame: StartupFrame, proof: StartupGridProof? = nil) throws {
        try resizeRequire(frames.count < 2000 && frame.displayTicks > 0
            && frame.callbackTicks > 0 && frame.checkedTicks >= frame.callbackTicks
            && max(frame.displayTicks, frame.checkedTicks) <= UInt64(Int64.max)
            && frame.displayTicks >= (frames.last?.displayTicks ?? 0)
            && frame.callbackTicks >= (frames.last?.callbackTicks ?? 0), "startup frame clock/order invalid")
        frames.append(frame)
        guard let launchBefore else {
            try resizeRequire(frame.stage == "prelaunch" && frame.before == nil && frame.after == nil
                && frame.proofSHA256 == nil && proof == nil, "prelaunch pixels/ownership were inspected")
            prelaunch = frame
            return
        }
        guard frame.displayTicks >= launchBefore else {
            try resizeRequire(frame.proofSHA256 == nil && proof == nil, "stale composed frame supplied a viewport")
            return
        }
        if let proof {
            guard let before = frame.before, let after = frame.after, let app else {
                throw ResizeFailure("complete viewport lacks app/window ownership")
            }
            try proof.witness.validate()
            try proof.raster.validate(columns: proof.witness.columns, rows: proof.witness.rows)
            let key = gridHash(try gridCanonical(proof))
            try resizeRequire(proofs.count < 8 || proofs[key] != nil, "startup proof bound exceeded")
            // A subsequent ownership/geometry failure must retain the generated
            // pixels that triggered it. The invalid receipt still cannot qualify.
            proofs[key] = proof
            try resizeRequire(frame.stage == "complete-generated" && frame.proofSHA256 == key
                && frame.callbackTicks >= launchBefore && before.identity == app && after.identity == app
                && before.windowID == after.windowID && before.displayID == after.displayID
                && !before.occluded && !after.occluded
                && before.foregroundPID == app.pid && after.foregroundPID == app.pid
                && frame.callbackTicks <= before.queriedTicks && before.queriedTicks <= after.queriedTicks
                && after.queriedTicks <= frame.checkedTicks,
                "first viewport ownership/clock/proof differs")
            let raster = proof.raster
            let sx = Double(raster.width) / displayBounds.width
            let sy = Double(raster.height) / displayBounds.height
            for bounds in [before.bounds, after.bounds] {
                try resizeRequire(displayBounds.rectangle.contains(bounds.rectangle)
                    && Double(raster.xEdges.first!) > ceil((bounds.x - displayBounds.x) * sx)
                    && Double(raster.yEdges.first!) > ceil((bounds.y - displayBounds.y) * sy)
                    && Double(raster.xEdges.last!) < floor((bounds.x + bounds.width - displayBounds.x) * sx)
                    && Double(raster.yEdges.last!) < floor((bounds.y + bounds.height - displayBounds.y) * sy),
                    "complete viewport perimeter touches or leaves a bracketing owned crop")
            }
            if let first, let previous = proofs[first.proofSHA256!] {
                try resizeRequire(before.windowID == first.before!.windowID
                    && before.displayID == first.before!.displayID && proof.witness == previous.witness,
                    "startup viewport grid/generation/identity changed after first")
            } else {
                first = frame
                // A complete but wrong first viewport invalidates this launch.
                // Never select a later resize or repaint as its replacement.
                try resizeRequire(proof.witness.columns == targetColumns && proof.witness.rows == targetRows
                    && proof.witness.frameKind == 1, "first complete viewport has the wrong initial grid")
            }
            if before.bounds != after.bounds {
                settledSince = nil
                settledRaster = nil
            } else if settledSince == nil || latest?.after?.bounds != before.bounds
                || !proof.raster.agrees(with: settledRaster!) {
                settledSince = max(frame.displayTicks, frame.checkedTicks)
                settledRaster = proof.raster
            }
            latest = frame
        } else {
            try resizeRequire(frame.stage != "complete-generated" && frame.proofSHA256 == nil,
                              "producer supplied a complete flag without observed pixels")
            if first != nil { throw ResizeFailure("incomplete capture after first complete viewport") }
        }
    }

    func stabilityReady(at tick: UInt64) throws -> Bool {
        guard let first, let settledSince else { return false }
        return try resizeSignedNS(tick, max(first.displayTicks, first.callbackTicks)) >= 1_000_000_000
            && resizeSignedNS(tick, settledSince) >= 200_000_000
    }

    func captureClocksReady(at tick: UInt64) -> Bool {
        statuses.allSatisfy { max($0.callbackTicks, $0.displayTicks ?? 0) <= tick }
            && frames.allSatisfy { max($0.displayTicks, $0.checkedTicks) <= tick }
    }

    func validateStatuses(finished: UInt64? = nil) throws {
        let complete = statuses.filter { $0.status == 0 }
        try resizeRequire(complete.count == frames.count, "startup status/frame coverage differs")
        var keys = Set<String>()
        for (status, frame) in zip(complete, frames) {
            let key = "\(frame.displayTicks):\(frame.callbackTicks)"
            try resizeRequire(status.displayTicks == frame.displayTicks && status.callbackTicks == frame.callbackTicks
                && keys.insert(key).inserted, "startup complete status/frame ordering or duplication differs")
        }
        for item in statuses {
            if let first, item.callbackTicks >= first.callbackTicks || (item.displayTicks ?? 0) >= first.displayTicks {
                try resizeRequire(item.status == 0 || item.status == 1, "capture blank/restart after first viewport")
            }
            if let finished {
                try resizeRequire(max(item.callbackTicks, item.displayTicks ?? 0) <= finished,
                                  "capture clock outside final validation")
            }
        }
    }

    func result(at finished: UInt64, final: ResizeWindowProof) throws -> [String: Int64] {
        guard let first, let latest, let start = launchBefore, let returned = launchAfter, let app else {
            throw ResizeFailure("launch lacks a complete first generated viewport")
        }
        try validateStatuses(finished: final.queriedTicks)
        let lastClock = max(returned, frames.reduce(0) { max($0, max($1.displayTicks, $1.checkedTicks)) })
        try resizeRequire(final.identity == app && final.windowID == first.before!.windowID
            && final.displayID == first.before!.displayID && final.bounds == latest.after!.bounds
            && final.foregroundPID == app.pid && !final.occluded
            && final.queriedTicks >= lastClock && final.queriedTicks <= finished
            && finished <= UInt64(Int64.max)
            && (try stabilityReady(at: finished))
            && (try resizeSignedNS(finished, start)) <= 15_000_000_000,
            "startup final ownership/stability/deadline differs")
        return ["launchToFrameNS": try resizeSignedNS(first.displayTicks, start),
            "launchCallNS": try resizeSignedNS(returned, start),
            "frameMinusLaunchReturnNS": try resizeSignedNS(first.displayTicks, returned),
            "captureCallbackLagNS": try resizeSignedNS(first.callbackTicks, first.displayTicks)]
    }
}
