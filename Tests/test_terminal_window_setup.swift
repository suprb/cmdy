// Generated observations only. No AppKit startup, AX query, capture or event.
import ApplicationServices
import Foundation

@main
struct WindowSetupTests {
    static func main() throws {
        let identity = WindowSetupIdentity(pid: 123, uid: 501, startSeconds: 45,
                                          startMicroseconds: 67, executable: "/owned/app")
        let ready = WindowSetupObservation(identity: identity, frontmostPID: 123,
            visibleWindowIDs: [91], axError: AXError.success.rawValue,
            axWindows: [7], axOwnerPIDs: [123])
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw NSError(domain: message, code: 1) }
            checks += 1
        }
        func exercise(_ values: [WindowSetupObservation<Int>], expectedError: String? = nil,
                      slowRead: Bool = false) throws -> [String: Any] {
            var clock = 0.0, reads = 0, resizeCalls = 0
            do {
                let (window, diagnostics) = try readySetupWindow(identity: identity, read: {
                    let value = values[min(reads, values.count - 1)]
                    reads += 1
                    if slowRead { clock += 1.1 }
                    return value
                }, sameWindow: ==, now: { clock }, pause: { clock += $0 })
                resizeCalls += 1
                try require(expectedError == nil, "invalid observation granted a resize")
                try require(window == 7 && resizeCalls == 1, "wrong resize target")
                try require(diagnostics["status"] as? String == "ready", "success diagnostics absent")
                return diagnostics
            } catch let error as WindowSetupFailure {
                try require(expectedError != nil && error.message.contains(expectedError!),
                            "wrong failure: \(error.message)")
                try require(resizeCalls == 0, "resize occurred before ownership readiness")
                try require(error.diagnostics["status"] as? String == "failed", "failure diagnostics absent")
                return error.diagnostics
            }
        }
        var nilList = ready; nilList.axWindows = nil; nilList.axOwnerPIDs = []
        var emptyList = ready; emptyList.axWindows = []; emptyList.axOwnerPIDs = []
        var pending = nilList; pending.axError = AXError.cannotComplete.rawValue
        var noValue = nilList; noValue.axError = AXError.noValue.rawValue
        let eventual = try exercise([nilList, emptyList, pending, noValue, ready, ready])
        let polls = eventual["polls"] as! [[String: Any]]
        try require(polls.count == 6, "pending AX polls not preserved")
        try require(polls[0]["axCount"] is NSNull && polls[1]["axCount"] as? Int == 0,
                    "nil and empty AX list diagnostics collapsed")
        try require(polls.last?["phase"] as? String == "before-resize", "final ownership recheck missing")
        try require(eventual["elapsedSeconds"] as? Double == 0.1, "unexpected polling schedule")
        let timeout = try exercise([emptyList], expectedError: "within two seconds")
        try require(timeout["elapsedSeconds"] as? Double == 2, "retry exceeded fixed deadline")
        try require((timeout["polls"] as! [[String: Any]]).count <= 81, "unbounded polling")
        var twoAX = ready; twoAX.axWindows = [7, 8]; twoAX.axOwnerPIDs = [123, 123]
        let multiple = try exercise([twoAX], expectedError: "exactly one owned AX window")
        try require((multiple["polls"] as! [[String: Any]]).count == 1, "multiple AX windows retried")
        var wrongOwner = ready; wrongOwner.axOwnerPIDs = [456]
        _ = try exercise([wrongOwner], expectedError: "does not belong")
        var exited = ready; exited.identity = nil
        _ = try exercise([nilList, exited], expectedError: "exited or changed identity")
        var replacement = ready
        replacement.identity = WindowSetupIdentity(pid: 123, uid: 501, startSeconds: 46,
                                                    startMicroseconds: 67, executable: "/owned/app")
        _ = try exercise([nilList, replacement], expectedError: "exited or changed identity")
        var focus = ready; focus.frontmostPID = 456
        _ = try exercise([nilList, focus], expectedError: "focus changed")
        var changedCG = ready; changedCG.visibleWindowIDs = [92]
        _ = try exercise([nilList, changedCG], expectedError: "window identity changed")
        var multipleCG = ready; multipleCG.visibleWindowIDs = [91, 92]
        _ = try exercise([multipleCG], expectedError: "exactly one visible owned window")
        var noCG = ready; noCG.visibleWindowIDs = []
        _ = try exercise([noCG], expectedError: "exactly one visible owned window")
        var denied = nilList; denied.axError = AXError.apiDisabled.rawValue
        _ = try exercise([denied], expectedError: "query failed")
        var changedAX = ready; changedAX.axWindows = [8]
        _ = try exercise([ready, changedAX], expectedError: "changed before resize")
        _ = try exercise([ready, nilList], expectedError: "changed before resize")
        _ = try exercise([ready, focus], expectedError: "focus changed")
        _ = try exercise([ready], expectedError: "exceeded two seconds", slowRead: true)
        // Exercise every free-space direction, including a display left of the
        // primary screen. These calls calculate geometry only; no cursor moves.
        let displays = [CGRect(x: 0, y: 0, width: 1728, height: 1117),
                        CGRect(x: -1728, y: -100, width: 1728, height: 1117)]
        for display in displays {
            for window in [CGRect(x: display.minX + 32, y: display.minY + 120, width: 1040, height: 769),
                           CGRect(x: display.minX + 500, y: display.minY, width: 1228, height: 1117),
                           CGRect(x: display.minX, y: display.minY + 400, width: 1728, height: 717),
                           CGRect(x: display.minX, y: display.minY, width: 1728, height: 700)] {
                let point = try pointerParkPoint(window: window, display: display)
                let clear = CGRect(x: point.x - 96, y: point.y - 96, width: 192, height: 192)
                try require(display.contains(clear), "pointer clearance escaped the display")
                try require(!window.intersects(clear), "pointer clearance overlaps the owned window")
            }
        }
        let display = displays[0]
        for window in [display, CGRect(x: 1, y: 1, width: 1726, height: 1115),
                       CGRect(x: -1, y: 120, width: 1040, height: 769),
                       CGRect(x: 32, y: 120, width: 0, height: 769),
                       CGRect(x: CGFloat.nan, y: 120, width: 1040, height: 769)] {
            do {
                _ = try pointerParkPoint(window: window, display: display)
                try require(false, "invalid geometry granted pointer placement")
            } catch is WindowSetupFailure { checks += 1 }
        }
        for clearance in [CGFloat.nan, CGFloat.infinity, 0, -1, 1000] {
            do {
                _ = try pointerParkPoint(window: CGRect(x: 32, y: 120, width: 1040, height: 769),
                                         display: display, clearance: clearance)
                try require(false, "invalid clearance granted pointer placement")
            } catch is WindowSetupFailure { checks += 1 }
        }
        let json = try JSONSerialization.data(withJSONObject: ["status": "passed", "checks": checks,
            "nativeQueries": 0, "resizeCallsAgainstRealWindows": 0], options: [.sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
}
