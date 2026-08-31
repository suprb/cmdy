import CoreGraphics

/// At very small heights the title strip consumes most of the usable window.
/// Collapse it based on the stable outer frame instead of terminal row count,
/// which can remain clamped to one row while the user is still resizing.
enum WindowChromeLayout {
    static let compactHeight: CGFloat = 104

    static func isCompact(windowHeight: CGFloat) -> Bool {
        windowHeight < compactHeight
    }

    /// Smallest outer window height that still exposes one complete content
    /// row once compact chrome has been removed. Terminal/editor controllers
    /// already reserve `contentMargin` once at the top and once at the bottom.
    static func minimumWindowHeight(rowHeight: CGFloat,
                                    contentMargin: CGFloat,
                                    backingScale: CGFloat) -> CGFloat {
        let scale = max(1, backingScale)
        let raw = max(1, rowHeight) + max(0, contentMargin) * 2
        return ceil(raw * scale) / scale
    }
}
