import Foundation
import CoreGraphics

/// Background agent captures must not expose a companion window over whatever
/// application the user is currently working in. ScreenCaptureKit can capture
/// an offscreen window, so keep it ordered for Chromium rendering but park it
/// well outside every ordinary display.
public enum SidecarCapturePolicy {
    public static func shouldParkOffscreen(
        hostIsActive: Bool,
        sidecarIsActive: Bool
    ) -> Bool {
        !hostIsActive && !sidecarIsActive
    }

    public static func parkedFrame(
        for frame: CGRect,
        desktopBounds: CGRect
    ) -> CGRect {
        CGRect(
            x: desktopBounds.minX - frame.size.width + 1,
            y: desktopBounds.minY - frame.size.height + 1,
            width: frame.size.width,
            height: frame.size.height)
    }
}
