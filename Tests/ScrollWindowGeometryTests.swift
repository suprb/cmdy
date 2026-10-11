import Foundation
import CoreGraphics

@main enum ScrollWindowGeometryTests {
    static func main() throws {
        let main = ScrollObservedWindow(windowID: 10, ownerPID: 42, layer: 0, alpha: 1,
            onScreen: true, bounds: CGRect(x: 120, y: 120, width: 1040, height: 655))
        func window(_ id: UInt32 = 11, pid: Int32 = 42, layer: Int = 0, alpha: Double = 1,
                    x: Double = 129, y: Double = 130, width: Double = 66,
                    height: Double = 20) -> ScrollObservedWindow {
            ScrollObservedWindow(windowID: id, ownerPID: pid, layer: layer, alpha: alpha,
                onScreen: true, bounds: CGRect(x: x, y: y, width: width, height: height))
        }
        var passed = 0
        func accepts(_ windows: [ScrollObservedWindow], top: Double? = 160,
                     chromeCount: Int = 0) throws {
            let value = try scrollAdmitWindowGeometry(windows, appPID: 42, windowID: 10, viewportTop: top)
            precondition(value.main == main && value.chrome.count == chromeCount)
            passed += 1
        }
        func rejects(_ windows: [ScrollObservedWindow], top: Double? = 160) {
            do {
                _ = try scrollAdmitWindowGeometry(windows, appPID: 42, windowID: 10, viewportTop: top)
                fatalError("accepted invalid window geometry")
            } catch { passed += 1 }
        }
        try accepts([main], top: nil)
        try accepts([window(), main], chromeCount: 1)
        try accepts([window(y: 140), main], chromeCount: 1) // Exact non-overlapping boundary.
        rejects([window(), main], top: nil)
        rejects([window(y: 140.001), main])
        rejects([window(x: 119), main])
        rejects([window(y: 119), main])
        rejects([window(width: 1040), main])
        rejects([window(pid: 9), main]) // Unrelated title-bar overlap is still rejected.
        rejects([window(pid: 9, layer: 105, x: 464, y: 227, width: 800, height: 600), main])
        try accepts([main, window(pid: 9, x: 464, y: 227, width: 800, height: 600)]) // Behind.
        try accepts([window(pid: 9, alpha: 0, x: 464, y: 227, width: 800, height: 600), main])
        rejects([main, window(y: 400)]) // Second owned content window is invalid even behind.
        rejects([window(10), main]) // Duplicate native identifier.
        rejects([window(width: 0), main])
        rejects([window(alpha: .nan), main])
        rejects([main], top: .infinity)
        rejects([main], top: 120)
        rejects([main], top: 775)
        rejects([window()]) // Pinned main window absent.
        let cursorLevel = Int(CGWindowLevelForKey(.cursorWindow))
        let server = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"
        precondition(scrollIsCaptureExcludedCursor(layer: cursorLevel, ownerExecutable: server))
        precondition(!scrollIsCaptureExcludedCursor(layer: cursorLevel, ownerExecutable: nil))
        precondition(!scrollIsCaptureExcludedCursor(layer: cursorLevel, ownerExecutable: "/synthetic/app"))
        precondition(!scrollIsCaptureExcludedCursor(layer: cursorLevel - 1, ownerExecutable: server))
        rejects([window(pid: 9, layer: cursorLevel), main]) // Without proven system ownership, still an occluder.
        passed += 4
        print("Scroll window geometry: \(passed) checks passed")
    }
}
