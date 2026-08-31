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
