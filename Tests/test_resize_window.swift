// Pure generated window-list tests. No window/process/display APIs are called.
import Foundation
import CoreGraphics

@main enum ResizeWindowTests {
    static func main() throws {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        func window(_ id: UInt32 = 11, pid: Int32 = 9, layer: Int = 0, alpha: Double = 1,
                    x: Double = 120, y: Double = 120, width: Double = 100,
                    height: Double = 100) -> [String: Any] {
            [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
             kCGWindowLayer as String: layer, kCGWindowAlpha as String: alpha,
             kCGWindowBounds as String: CGRect(x: x, y: y, width: width, height: height).dictionaryRepresentation,
             kCGWindowName as String: "PRIVATE TITLE MUST NOT APPEAR", kCGWindowOwnerName as String: "PRIVATE APP"]
        }
        let main = window(10, pid: 42, width: 1040, height: 655)
        var passed = 0
        func check(_ raw: [[String: Any]], display: CGRect? = nil, active: Bool = true) throws -> ResizeBounds {
            try resizeCheckWindowGeometry(raw, appPID: 42, windowID: 10, displayID: 1,
                displayBounds: display ?? screen, displayActive: active, queryStartedTicks: 100, queryFinishedTicks: 101)
        }
        func accept(_ raw: [[String: Any]], display: CGRect? = nil) throws {
            _ = try check(raw, display: display); passed += 1
        }
        func reject(_ raw: [[String: Any]], blockers: [Int]? = nil, invalid: [Int] = [],
                    active: Bool = true, display: CGRect? = nil) throws {
            do { _ = try check(raw, display: display, active: active); fatalError("invalid geometry admitted") }
            catch let failure as ResizeWindowGeometryFailure {
                precondition(failure.evidence.invalidWindowIndices == invalid)
                if let blockers { precondition(failure.evidence.blockingWindowIndices == blockers) }
                precondition(failure.evidence.queryStartedTicks == 100 && failure.evidence.queryFinishedTicks == 101)
                precondition(failure.evidence.coordinateSpace == "CG-global-upper-left")
                precondition(failure.evidence.order == "front-to-back")
                let fields = resizeFailureFields(failure)
                let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
                let text = String(decoding: data, as: UTF8.self)
                precondition(!text.contains("PRIVATE") && fields["windowGeometry"] != nil)
                let detail = try JSONSerialization.data(withJSONObject: fields["windowGeometry"]!)
                let decoded = try JSONDecoder().decode(ResizeWindowGeometryEvidence.self, from: detail)
                precondition(decoded == failure.evidence)
                passed += 1
            }
        }
        try accept([main])
        try accept([main, window()]) // Behind cannot occlude, regardless of layer.
        try accept([main, window(layer: 105)])
        try accept([window(alpha: 0), main])
        try accept([window(x: 0, y: 0, width: 100, height: 100), main])
        try reject([window(), main], blockers: [0])
        try reject([window(layer: 105), main], blockers: [0])
        try reject([window(alpha: 0.001), main], blockers: [0])
        try reject([window(pid: 42, layer: 10), main], blockers: [0]) // No chrome exception.
        try reject([window(y: 125, height: 2), main], blockers: [0]) // Outer/title perimeter stays protected.
        try reject([window(), main, window(12)], blockers: [0]) // Exact ordered blocker index.
        try reject([window(), window(12), main], blockers: [0, 1])
        try reject([main, window(pid: 42)]) // Second owned layer-zero even behind.
        try reject([main, main]) // Duplicate ID, no z-order ambiguity allowed.
        try reject([window()]) // Pinned main absent.
        try reject([window(10, pid: 42, alpha: 0.5)])
        try reject([main], active: false)
        try reject([main], display: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        for key in [kCGWindowNumber, kCGWindowOwnerPID, kCGWindowLayer, kCGWindowAlpha, kCGWindowBounds] {
            var malformed = window(); malformed.removeValue(forKey: key as String)
            try reject([malformed, main], invalid: [0])
        }
        try reject([window(alpha: .nan), main], invalid: [0])
        try reject([window(alpha: 1.01), main], invalid: [0])
        try reject([window(width: 0), main], invalid: [0])
        try reject([window(width: .infinity), main], invalid: [0])
        // A display left of the primary keeps CG's negative global origin;
        // a speculative y flip would falsely admit this top-left blocker.
        let negative = window(10, pid: 42, x: -1600, y: -800, width: 1040, height: 655)
        let leftDisplay = CGRect(x: -1728, y: -900, width: 1728, height: 1117)
        try accept([negative], display: leftDisplay)
        try reject([window(x: -1600, y: -800), negative], blockers: [0], display: leftDisplay)
        try reject(Array(repeating: main, count: 4097))
        let other = resizeFailureFields(ResizeFailure("ordinary failure"))
        precondition(other.count == 1 && other["error"] as? String == "ordinary failure"); passed += 1
        print("Resize window geometry: \(passed) checks passed; native queries/actions: 0")
    }
}
