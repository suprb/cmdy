import AppKit
import ProductIdentity
import CmdyKit

/// A single reusable window that shows AI responses (streamed in as plain text).
final class AIResponseWindow {
    nonisolated(unsafe) static let shared = AIResponseWindow()

    private var window: NSWindow?
    private var textView: NSTextView?

    func show(title: String, body: String) {
        let w = ensureWindow()
        w.title = title
        if let tv = textView {
            tv.string = body
            tv.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func ensureWindow() -> NSWindow {
        if let w = window { return w }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        w.title = "\(ProductIdentity.current.displayName) AI"
        w.center()
        w.isReleasedWhenClosed = false

        let scroll = NSScrollView(frame: w.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let tv = NSTextView(frame: scroll.bounds)
        tv.autoresizingMask = [.width]
        tv.isEditable = false
        tv.isRichText = false
        tv.drawsBackground = true
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textContainerInset = NSSize(width: 12, height: 12)
        scroll.documentView = tv

        w.contentView?.addSubview(scroll)
        window = w
        textView = tv
        return w
    }
}
