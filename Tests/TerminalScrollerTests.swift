import AppKit

@main
struct TerminalScrollerTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroller = TerminalScroller(frame: NSRect(x: 0, y: 0, width: 16, height: 400))
        window.contentView?.addSubview(scroller)
        scroller.scrollerStyle = .legacy
        scroller.updateGeometry(position: 1, proportion: 0.1)
        precondition(scroller.doubleValue == 1 && scroller.knobProportion == 0.1)
        scroller.display()
        for _ in 0..<10_000 { scroller.updateGeometry(position: 1, proportion: 0.1) }
        precondition(!scroller.needsDisplay, "unchanged terminal output invalidated the knob")
        print("PASS unchanged geometry stays clean through 10000 publications")

        scroller.updateGeometry(position: 0.25, proportion: 0.1)
        precondition(scroller.needsDisplay && scroller.doubleValue == 0.25)
        scroller.display()
        scroller.updateGeometry(position: 0.25, proportion: 0.5)
        precondition(scroller.needsDisplay && scroller.knobProportion == 0.5)
        print("PASS scrolling and viewport-size changes invalidate with exact new values")

        // Native knob tracking can mutate the value between output callbacks.
        scroller.doubleValue = 0.75
        scroller.display()
        scroller.updateGeometry(position: 0.25, proportion: 0.5)
        precondition(scroller.doubleValue == 0.25 && scroller.needsDisplay)
        scroller.display()
        scroller.updateGeometry(position: 0.25, proportion: 0.5)
        precondition(!scroller.needsDisplay)
        print("PASS native tracking changes reconcile without stale cached geometry")
    }
}
