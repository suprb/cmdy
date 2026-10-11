// Pure scope and window proof checks. No public/native queries are made.
import Foundation
import CoreGraphics

@main enum HistoryScopeTests {
    static func main() throws {
        let app = ResizeProcessIdentity(pid: 42, parentPID: 41, uid: 501, startSeconds: 1,
            startMicroseconds: 2, executable: "/generated/app")
        let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        func window(_ id: UInt32, pid: Int32, layer: Int, bounds: CGRect) -> [String: Any] {
            [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
             kCGWindowLayer as String: layer, kCGWindowAlpha as String: 1.0,
             kCGWindowIsOnscreen as String: true, kCGWindowBounds as String: bounds.dictionaryRepresentation]
        }
        let main = window(10, pid: 42, layer: 0, bounds: CGRect(x: 120, y: 120, width: 1040, height: 655))
        // Same geometry classes as the retained failure. PIDs are generated;
        // the proof never assigns any privilege to an owner or OS layer.
        let cursor = window(11, pid: 8, layer: 2147483630, bounds: CGRect(x: 663, y: 674, width: 23, height: 22))
        let overlay = window(12, pid: 9, layer: 21, bounds: display)
        var passed = 0
        func proof(_ raw: [[String: Any]], current: ResizeProcessIdentity? = nil,
                   foreground: Int32 = 42, active: Bool = true) throws -> HistoryFileWindowProof {
            try historyFileWindowProof(raw, expected: app, current: current ?? app, observerUID: 501,
                foregroundPID: foreground, windowID: 10, displayID: 1, displayBounds: display,
                displayActive: active, queriedTicks: 100)
        }
        func accepts(_ raw: [[String: Any]]) throws {
            let value = try proof(raw)
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
            precondition(encoded["occluded"] == nil && encoded["visualVisibilityVerified"] as? Bool == false)
            precondition(encoded["schemaVersion"] as? Int == 2 && encoded["proofScope"] as? String == "generated-file-transport-v2")
            precondition(value.onScreen && value.foregroundPID == 42 && value.identity == app)
            // Existing visual native type must reject this disjoint shape.
            do { _ = try JSONDecoder().decode(ResizeWindowProof.self, from: JSONEncoder().encode(value)); fatalError("file proof decoded as visual") }
            catch { }
            passed += 1
        }
        func rejects(_ raw: [[String: Any]], foreground: Int32 = 42, active: Bool = true) {
            do { _ = try proof(raw, foreground: foreground, active: active); fatalError("invalid file ownership accepted") }
            catch { passed += 1 }
        }
        try accepts([main]); try accepts([cursor, overlay, main]); try accepts([overlay, main])
        let arbitrary = window(13, pid: 999, layer: 500, bounds: display)
        try accepts([arbitrary, main]) // Proof scope, not an OS process allowlist.
        for raw in [[cursor, main], [overlay, main], [arbitrary, main]] {
            do {
                _ = try resizeCheckWindowGeometry(raw, appPID: 42, windowID: 10, displayID: 1,
                    displayBounds: display, displayActive: true, queryStartedTicks: 99, queryFinishedTicks: 100)
                fatalError("visual guard weakened")
            } catch let failure as ResizeWindowGeometryFailure {
                precondition(failure.evidence.blockingWindowIndices == [0]); passed += 1
            }
        }
        rejects([main], foreground: 99); rejects([main], active: false); rejects([])
        rejects([main, window(14, pid: 42, layer: 0, bounds: display)])
        rejects([main, main])
        for key in [kCGWindowNumber, kCGWindowOwnerPID, kCGWindowLayer, kCGWindowAlpha,
                    kCGWindowBounds, kCGWindowIsOnscreen] {
            var bad = main; bad.removeValue(forKey: key as String); rejects([bad])
        }
        for (key, value) in [(kCGWindowAlpha, 0.5 as Any), (kCGWindowAlpha, Double.nan as Any),
                             (kCGWindowIsOnscreen, false as Any)] {
            var bad = main; bad[key as String] = value; rejects([bad])
        }
        rejects([window(10, pid: 42, layer: 0, bounds: CGRect(x: -1, y: 120, width: 1040, height: 655))])
        let replaced = ResizeProcessIdentity(pid: 42, parentPID: 41, uid: 501, startSeconds: 2,
            startMicroseconds: 2, executable: "/generated/app")
        do { _ = try proof([main], current: replaced); fatalError("replaced app admitted") }
        catch { passed += 1 }
        for operation in ["inspect", "post-key"] {
            try historyValidateScope(.fileTransport, operation: operation); passed += 1
            try historyValidateScope(nil, operation: operation); passed += 1
        }
        try historyValidateScope(nil, operation: "observe"); passed += 1
        do { try historyValidateScope(.fileTransport, operation: "observe"); fatalError("file scope authorized capture") }
        catch { passed += 1 }
        do { _ = try JSONDecoder().decode(HistoryProofScope.self, from: Data("\"unknown\"".utf8)); fatalError("unknown scope admitted") }
        catch { passed += 1 }
        print("History scope: \(passed) checks passed; native queries/actions: 0")
    }
}
