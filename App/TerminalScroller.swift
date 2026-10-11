import AppKit

/// Native AppKit scrolling and hit behavior without a permanent gutter.
/// Only the system-drawn scrubber is visible over the terminal surface.
final class TerminalScroller: NSScroller {
    var onInteraction: (() -> Void)?

    /// Content publication can change terminal cells without moving the knob.
    /// Keep AppKit invalidation tied to a real geometry change.
    func updateGeometry(position: Double, proportion: CGFloat) {
        guard doubleValue != position || knobProportion != proportion else { return }
        if knobProportion != proportion { knobProportion = proportion }
        if doubleValue != position { doubleValue = position }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawKnob()
    }

    override func mouseEntered(with event: NSEvent) {
        onInteraction?()
        super.mouseEntered(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        onInteraction?()
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }
}
