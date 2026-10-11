import AppKit
import CmdyKit

/// A view accepting file/folder drags (the window content view, and — via
/// TerminalPane — each pane). On drop it reports the dropped paths so the owner
/// can insert them (shell-escaped) at the cursor.
class DropView: NSView {
    var onDropPaths: (([String]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasFileURLs(sender) ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasFileURLs(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = fileURLs(sender), !urls.isEmpty else { return false }
        onDropPaths?(urls.map { $0.path })
        return true
    }

    private func hasFileURLs(_ sender: NSDraggingInfo) -> Bool {
        (fileURLs(sender)?.isEmpty == false)
    }
    private func fileURLs(_ sender: NSDraggingInfo) -> [URL]? {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }
}

/// Fills shell regions which are not already painted by an owned Metal pane.
/// The opaque path keeps the existing backing-layer fill. Translucent panes
/// each supply their own background alpha, so the shell excludes their bounds.
final class TerminalBackgroundContainerView: DropView {
    var backgroundFillColor = NSColor.clear {
        didSet {
            layer?.backgroundColor = backgroundFillColor.alphaComponent >= 1
                ? backgroundFillColor.cgColor : NSColor.clear.cgColor
            needsDisplay = true
        }
    }
    var backgroundExclusionViews: (() -> [NSView])?

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clear(dirtyRect)
        guard backgroundFillColor.alphaComponent > 0,
              backgroundFillColor.alphaComponent < 1 else { return }
        for view in backgroundExclusionViews?() ?? [] {
            guard view.isDescendant(of: self), !view.isHiddenOrHasHiddenAncestor else { continue }
            let owned = convert(view.bounds, from: view).intersection(bounds)
            guard !owned.isEmpty else { continue }
            // Intersect complements separately so overlapping pane bounds never
            // reintroduce a fill through an even-odd overlap.
            let complement = CGMutablePath()
            complement.addRect(bounds)
            complement.addRect(owned)
            context.addPath(complement)
            context.clip(using: .evenOdd)
        }
        backgroundFillColor.setFill()
        dirtyRect.fill()
    }
}
