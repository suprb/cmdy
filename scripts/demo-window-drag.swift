import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

guard CommandLine.arguments.count == 3,
      let sourceNumber = UInt32(CommandLine.arguments[1]),
      let targetNumber = UInt32(CommandLine.arguments[2])
else {
    fail("usage: demo-window-drag <source-window-number> <target-window-number>")
}

func bounds(for windowNumber: UInt32) -> CGRect? {
    guard let rows = CGWindowListCopyWindowInfo(
        [.optionIncludingWindow], CGWindowID(windowNumber)) as? [[String: Any]]
    else { return nil }
    for row in rows {
        guard let raw = row[kCGWindowBounds as String] as? NSDictionary else {
            continue
        }
        var rect = CGRect.zero
        if CGRectMakeWithDictionaryRepresentation(raw, &rect) {
            return rect
        }
    }
    return nil
}

guard let source = bounds(for: sourceNumber) else {
    fail("source window \(sourceNumber) was not found")
}
guard let target = bounds(for: targetNumber) else {
    fail("target window \(targetNumber) was not found")
}

// CGWindow coordinates and CGEvent mouse coordinates both use the display's
// upper-left origin. Start in cmdy's native title band, then dwell inside the
// destination long enough for the live grid preview before releasing.
// The toolbar controls are packed across the right half of narrow grid
// windows. Grab the quiet title-band area near the left instead of the
// midpoint, which can land directly on an icon.
let start = CGPoint(
    x: source.minX + min(132, max(92, source.width * 0.22)),
    y: source.minY + 16)
let end = CGPoint(x: target.midX, y: target.midY)
let steps = 96

func post(_ type: CGEventType, at point: CGPoint) {
    guard let event = CGEvent(
        mouseEventSource: nil,
        mouseType: type,
        mouseCursorPosition: point,
        mouseButton: .left)
    else { fail("could not create mouse event") }
    event.post(tap: .cghidEventTap)
}

CGWarpMouseCursorPosition(start)
usleep(420_000)
post(.leftMouseDown, at: start)
usleep(180_000)
for step in 1...steps {
    let progress = CGFloat(step) / CGFloat(steps)
    // Ease the move slightly so the captured gesture reads as a deliberate
    // native drag instead of an automated cursor jump.
    let eased = progress * progress * (3 - 2 * progress)
    let point = CGPoint(
        x: start.x + (end.x - start.x) * eased,
        y: start.y + (end.y - start.y) * eased)
    post(.leftMouseDragged, at: point)
    usleep(18_000)
}
// Hold over the destination so the native grid preview has time to appear in
// the recording before committing the reorder.
usleep(520_000)
post(.leftMouseUp, at: end)
usleep(900_000)

// Treat a drag that left the source in the same slot as a real failure. The
// shell driver can then retry instead of silently recording a dead gesture.
guard let moved = bounds(for: sourceNumber),
      hypot(moved.midX - source.midX, moved.midY - source.midY) > 24 else {
    fail("source window did not leave its original grid slot")
}
let display = CGDisplayBounds(CGMainDisplayID())
CGWarpMouseCursorPosition(CGPoint(x: display.maxX - 2, y: display.minY + 1))
