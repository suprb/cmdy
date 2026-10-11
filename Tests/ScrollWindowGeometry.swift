import Foundation
import CoreGraphics

struct ScrollObservedWindow: Codable, Equatable, Sendable {
    let windowID: UInt32
    let ownerPID: Int32
    let layer: Int
    let alpha: Double
    let onScreen: Bool
    let bounds: CGRect
}

struct ScrollWindowGeometryFailure: Error, CustomStringConvertible {
    let description: String
    init(_ value: String) { description = value }
}

struct ScrollWindowGeometryAdmission {
    let main: ScrollObservedWindow
    let chrome: [ScrollObservedWindow]
}

/// ScreenCaptureKit is explicitly configured with showsCursor=false. Exclude
/// only the system cursor at its documented level and kernel-resolved owner;
/// an arbitrary high-level overlay (or an app imitating that level) still fails.
func scrollIsCaptureExcludedCursor(layer: Int, ownerExecutable: String?) -> Bool {
    layer == Int(CGWindowLevelForKey(.cursorWindow))
        && ownerExecutable == "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"
}

/// The optional top is derived from all 36 contiguous generated row bands in
/// the captured main window. No title, process name, window-size heuristic,
/// or hard-coded chrome height grants an exception.
func scrollAdmitWindowGeometry(_ windows: [ScrollObservedWindow],
                               appPID: Int32, windowID: UInt32,
                               viewportTop: Double?) throws -> ScrollWindowGeometryAdmission {
    func finite(_ rectangle: CGRect) -> Bool {
        [rectangle.origin.x, rectangle.origin.y, rectangle.width, rectangle.height]
            .allSatisfy { $0.isFinite }
            && rectangle.width > 0 && rectangle.height > 0
    }
    guard windows.allSatisfy({ finite($0.bounds) && $0.alpha.isFinite && (0...1).contains($0.alpha) }),
          Set(windows.map(\.windowID)).count == windows.count,
          let index = windows.firstIndex(where: { $0.windowID == windowID }) else {
        throw ScrollWindowGeometryFailure("incomplete or ambiguous visible-window geometry")
    }
    let main = windows[index]
    guard main.ownerPID == appPID, main.layer == 0, main.onScreen,
          main.alpha >= 0.999, main.bounds.width > 100, main.bounds.height > 100 else {
        throw ScrollWindowGeometryFailure("owned main-window identity/opacity/rectangle changed")
    }
    if let top = viewportTop {
        guard top.isFinite, top > main.bounds.minY, top < main.bounds.maxY else {
            throw ScrollWindowGeometryFailure("invalid raster-derived viewport top")
        }
    }
    func isOwnedChrome(_ window: ScrollObservedWindow) -> Bool {
        guard let top = viewportTop else { return false }
        return window.ownerPID == appPID && window.windowID != windowID
            && main.bounds.contains(window.bounds) && window.bounds.maxY <= top
    }
    let otherOwned = windows.filter { $0.ownerPID == appPID && $0.onScreen && $0.windowID != windowID }
    guard otherOwned.allSatisfy(isOwnedChrome) else {
        throw ScrollWindowGeometryFailure("additional owned window is not wholly above the measured viewport")
    }
    // CG order is front to back. Keep the complete outer rectangle protected
    // against unrelated visible windows, including overlays above layer zero.
    // Owned chrome receives the same strictly raster-derived geometric test.
    for other in windows.prefix(index) where other.onScreen && other.alpha > 0 {
        if other.bounds.intersects(main.bounds) && !isOwnedChrome(other) {
            throw ScrollWindowGeometryFailure("another visible window occludes the owned crop")
        }
    }
    return ScrollWindowGeometryAdmission(main: main, chrome: otherOwned)
}
