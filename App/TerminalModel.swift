import Foundation
import CmdyKit
import CmdyCore
import CmdyPTY

/// Main-thread event sink for a pane's worker-owned terminal model.
@MainActor
protocol TerminalModelObserver: AnyObject {
    func terminalModel(_ model: TerminalModel, didPublish snapshot: CoreTerminalSnapshot)
    func terminalModel(_ model: TerminalModel, didSetTitle title: String)
    func terminalModel(_ model: TerminalModel, didSetCurrentDirectory directory: String?)
    func terminalModelDidBell(_ model: TerminalModel)
    func terminalModel(_ model: TerminalModel, didRequestNotification title: String, body: String)
    func terminalModel(_ model: TerminalModel, didRequestClipboardCopy content: Data)
    func terminalModel(_ model: TerminalModel, didSend data: [UInt8])
    func terminalModel(_ model: TerminalModel, processTerminated exitCode: Int32?)
}

struct TerminalViewportUpdate {
    let before: Int
    let after: Int
    let snapshot: CoreTerminalSnapshot?
}

/// Owns one mutable VT model and its PTY on a dedicated serial queue. AppKit
/// never reads `CmdyTerminal` directly; rendering consumes immutable
/// snapshots and cold API operations synchronise through this object.
final class TerminalModel: @unchecked Sendable {
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let terminal: CmdyTerminal
    private let snapshotLock = NSLock()
    private var publishedSnapshot: CoreTerminalSnapshot
    private var publishedSnapshotGeneration: UInt64 = 0
    private var snapshotScheduled = false
    private var pixelWidth = 0
    private var pixelHeight = 0

    private(set) var viewportSnapshotReuseCountForTesting = 0
    private(set) var viewportSnapshotCaptureCountForTesting = 0

    weak var observer: TerminalModelObserver?

    lazy var process: LocalProcess = LocalProcess(delegate: self, dispatchQueue: queue)

    init(cols: Int, rows: Int) {
        queue = DispatchQueue(label: "com.cmdy.model.\(UUID().uuidString)",
                              qos: .userInteractive)
        terminal = CmdyTerminal(cols: cols, rows: rows)
        publishedSnapshot = terminal.captureTerminalSnapshot(consumeDamage: false)
        queue.setSpecific(key: queueKey, value: 1)
        terminal.delegate = self
    }

    var snapshot: CoreTerminalSnapshot {
        snapshotLock.lock()
        let value = publishedSnapshot
        snapshotLock.unlock()
        return value
    }

    /// Store a capture and return its generation. Main-queue deliveries check
    /// this before notifying the view so a pre-resize callback cannot replace a
    /// newer, synchronously installed resize snapshot.
    @discardableResult
    private func storePublishedSnapshot(_ snapshot: CoreTerminalSnapshot) -> UInt64 {
        snapshotLock.lock()
        publishedSnapshot = snapshot
        publishedSnapshotGeneration &+= 1
        let generation = publishedSnapshotGeneration
        snapshotLock.unlock()
        return generation
    }

    private func publicationIsCurrent(_ generation: UInt64) -> Bool {
        snapshotLock.lock()
        let current = publishedSnapshotGeneration == generation
        snapshotLock.unlock()
        return current
    }

    @inline(__always)
    private func sync<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return operation()
        }
        return queue.sync(execute: operation)
    }

    @inline(__always)
    private func async(_ operation: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            operation()
        } else {
            queue.async(execute: operation)
        }
    }

    private func scheduleSnapshot() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !snapshotScheduled else { return }
        snapshotScheduled = true
        // A one-millisecond window folds parser callbacks from the same PTY
        // burst into one COW row capture without adding a visible frame delay.
        queue.asyncAfter(deadline: .now() + .milliseconds(1)) { [weak self] in
            guard let self else { return }
            guard self.snapshotScheduled else { return }
            self.snapshotScheduled = false
            self.publishSnapshot()
        }
    }

    private func publishSnapshot() {
        dispatchPrecondition(condition: .onQueue(queue))
        let snapshot = terminal.captureTerminalSnapshot()
        let generation = storePublishedSnapshot(snapshot)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.publicationIsCurrent(generation) else { return }
            self.observer?.terminalModel(self, didPublish: snapshot)
        }
    }

    /// Resize and return a matching immutable capture in the same worker turn.
    /// Live resize must never draw old grid dimensions into new view bounds.
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) -> CoreTerminalSnapshot {
        sync {
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            terminal.resize(cols: cols, rows: rows)
            let snapshot = terminal.captureTerminalSnapshot()
            storePublishedSnapshot(snapshot)
            return snapshot
        }
    }

    func updatePixelSize(width: Int, height: Int) {
        sync {
            pixelWidth = width
            pixelHeight = height
        }
    }

    func startProcess(executable: String, args: [String], environment: [String]?,
                      currentDirectory: String?) {
        sync {
            process.startProcess(executable: executable, args: args, environment: environment,
                                 execName: String?.none, currentDirectory: currentDirectory)
        }
    }

    func terminate() { sync { process.terminate() } }
    var shellPid: pid_t { sync { process.shellPid } }
    var childFileDescriptor: Int32 { sync { process.childfd } }

    func send(_ bytes: [UInt8]) {
        async { [process] in process.send(data: bytes[...]) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.observer?.terminalModel(self, didSend: bytes)
        }
    }

    func feed(text: String) {
        sync { terminal.feed(text: text) }
    }

    func markViewportDirty() {
        sync {
            terminal.markViewportDirty()
            scheduleSnapshot()
        }
    }

    @discardableResult
    func scrollViewport(to row: Int) -> TerminalViewportUpdate {
        sync {
            let before = terminal.currentTopRow
            let hadPendingSnapshot = snapshotScheduled
            terminal.scrollViewport(to: row)
            let after = terminal.currentTopRow
            guard after != before else {
                return TerminalViewportUpdate(before: before, after: after, snapshot: nil)
            }
            // Scrolling changes the grid origin but not its rows. Publish the
            // coherent viewport now so the renderer never combines the new
            // pixel offset with the previous yDisp for one flashing frame.
            snapshotScheduled = false
            let snapshot = viewportSnapshot(hadPendingSnapshot: hadPendingSnapshot)
            storePublishedSnapshot(snapshot)
            return TerminalViewportUpdate(before: before, after: after, snapshot: snapshot)
        }
    }

    @discardableResult
    func scrollViewport(lines: Int) -> TerminalViewportUpdate {
        sync {
            let before = terminal.currentTopRow
            let hadPendingSnapshot = snapshotScheduled
            terminal.scrollViewport(lines: lines)
            let after = terminal.currentTopRow
            guard after != before else {
                return TerminalViewportUpdate(before: before, after: after, snapshot: nil)
            }
            snapshotScheduled = false
            let snapshot = viewportSnapshot(hadPendingSnapshot: hadPendingSnapshot)
            storePublishedSnapshot(snapshot)
            return TerminalViewportUpdate(before: before, after: after, snapshot: snapshot)
        }
    }

    /// Most wheel turns only change yDisp. The published snapshot already
    /// owns a screen of immutable rows on either side, so reuse those rows
    /// until the visible viewport approaches that captured edge. A pending
    /// parser publication or dirty snapshot always takes the coherent full
    /// capture path.
    private func viewportSnapshot(
        hadPendingSnapshot: Bool
    ) -> CoreTerminalSnapshot {
        let grid = terminal.captureCoreGrid()
        let current = snapshot
        let fringe = max(2, min(8, grid.rows))
        let requiredFirst = max(0, grid.displayTopRow - fringe)
        let requiredLast = min(
            grid.bufferLineCount - 1,
            grid.displayTopRow + grid.rows - 1 + fringe)
        let capturedLast = current.firstLineRow + current.lines.count - 1
        let compatible = current.grid.rows == grid.rows
            && current.grid.cols == grid.cols
            && current.grid.bufferLineCount == grid.bufferLineCount
            && current.grid.retainedRowOrigin == grid.retainedRowOrigin
            && current.grid.isAlternateBuffer == grid.isAlternateBuffer

        if !hadPendingSnapshot,
           current.dirtyRows == nil,
           compatible,
           current.firstLineRow <= requiredFirst,
           capturedLast >= requiredLast {
            viewportSnapshotReuseCountForTesting &+= 1
            return current.projectingViewport(onto: grid)
        }

        viewportSnapshotCaptureCountForTesting &+= 1
        return terminal.captureTerminalSnapshot()
    }

    func searchAll(_ term: String, options: TermSearchOptions) -> [TerminalSearchHit] {
        sync {
            terminal.searchAll(term, spec: .init(caseSensitive: options.caseSensitive,
                                                 regex: options.regex))
        }
    }

    func lineSnapshot(absolute row: Int) -> CoreLineSnapshot? {
        sync {
            guard let line = terminal.lineForDiff(absolute: row) else { return nil }
            let images = (line.images ?? []).map {
                CoreLineImageSnapshot(renderIdentity: $0.renderIdentity,
                                      payload: $0.payload,
                                      pixelWidth: $0.pixelWidth,
                                      pixelHeight: $0.pixelHeight,
                                      col: $0.col,
                                      kittyIsKitty: $0.kittyIsKitty,
                                      kittyImageId: $0.kittyImageId,
                                      kittyPlacementId: $0.kittyPlacementId,
                                      kittyZIndex: $0.kittyZIndex,
                                      kittyPixelOffsetX: $0.kittyPixelOffsetX,
                                      kittyPixelOffsetY: $0.kittyPixelOffsetY)
            }
            return CoreLineSnapshot(cells: line.cells, isWrapped: line.isWrapped,
                                    renderMode: line.renderMode, images: images,
                                    version: line.version)
        }
    }

    func linkURI(id: UInt16) -> String? {
        sync { terminal.linkURI(id: id) }
    }

    func sendMouseEvent(button: Int, pressed: Bool, motion: Bool,
                        modifiers: CmdyTerminal.MouseModifiers,
                        col: Int, row: Int) {
        sync {
            _ = terminal.sendMouseEvent(button: button, pressed: pressed, motion: motion,
                                        modifiers: modifiers, col: col, row: row)
        }
    }

    var coreGrid: CoreGridSnapshot { sync { terminal.captureCoreGrid() } }
    var applicationCursorKeys: Bool { sync { terminal.applicationCursorKeys } }
    var bracketedPaste: Bool { sync { terminal.bracketedPaste } }
    var focusReporting: Bool { sync { terminal.focusReporting } }
    var mouseMode: MouseMode { sync { terminal.mouseMode } }
    var mouseProtocol: MouseProtocolEncoding { sync { terminal.mouseProtocol } }
    var kittyKeyboardFlags: Int { sync { terminal.kittyKeyboardFlags } }
    var isAlternateBuffer: Bool { sync { terminal.isAlternateBuffer } }

    func lineForDiff(absolute row: Int) -> CoreLineSnapshot? {
        lineSnapshot(absolute: row)
    }
}

extension TerminalModel: TerminalEngine {
    var cols: Int { sync { terminal.cols } }
    var rows: Int { sync { terminal.rows } }
    var scrollInvariantCursorRow: Int { sync { terminal.scrollInvariantCursorRow } }
    var cursorColumn: Int { sync { terminal.cursorColumn } }
    var bufferLineCount: Int { sync { terminal.bufferLineCount } }
    var currentTopRow: Int { sync { terminal.currentTopRow } }
    var liveScreenTopRow: Int { sync { terminal.liveScreenTopRow } }
    var scrollbackDroppedLines: Int { sync { terminal.scrollbackDroppedLines } }
    var isCurrentBufferAlternate: Bool { sync { terminal.isAlternateBuffer } }

    func isBufferRowWrapped(_ row: Int) -> Bool {
        sync { terminal.isBufferRowWrapped(row) }
    }

    func scrollbackLineText(row: Int) -> String? {
        sync { terminal.scrollbackLineText(row: row) }
    }

    func scrollbackLineTexts(rows: ClosedRange<Int>) -> [String] {
        sync { terminal.scrollbackLineTexts(rows: rows) }
    }

    func scrollbackLineText(row: Int, columns: Range<Int>) -> String? {
        sync { terminal.scrollbackLineText(row: row, columns: columns) }
    }

    var kittyImageCount: Int { sync { terminal.kittyImageCount } }
    var linesWithImagesCount: Int {
        sync { terminal.linesWithImagesCount }
    }
    var mouseModeDescription: String { sync { terminal.mouseModeDescription } }

    func insertHostMessage(_ text: String) {
        sync { terminal.insertHostMessage(text) }
    }

    func setCommandFinishedHostMessageProvider(
        _ provider: ((String, String, Int32?) -> String?)?) {
        sync { terminal.setCommandFinishedHostMessageProvider(provider) }
    }

    func registerOscHandler(code: Int, handler: @escaping (ArraySlice<UInt8>) -> Void) {
        sync { terminal.registerOscHandler(code: code, handler: handler) }
    }

    func setCursorStyle(_ style: TermCursorStyle) {
        sync {
            let shape: TermCursorShape
            switch style {
            case .blinkBlock: shape = .blinkBlock
            case .steadyBlock: shape = .steadyBlock
            case .blinkUnderline: shape = .blinkUnderline
            case .steadyUnderline: shape = .steadyUnderline
            case .blinkBar: shape = .blinkBar
            case .steadyBar: shape = .steadyBar
            }
            terminal.setCursorStyle(shape)
            scheduleSnapshot()
        }
    }
}

extension TerminalModel: CmdyTerminalDelegate {
    func send(_ terminal: CmdyTerminal, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        process.send(data: bytes[...])
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.observer?.terminalModel(self, didSend: bytes)
        }
    }

    func setTitle(_ terminal: CmdyTerminal, title: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.observer?.terminalModel(self, didSetTitle: title)
        }
    }

    func setCurrentDirectory(_ terminal: CmdyTerminal, directory: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.observer?.terminalModel(self, didSetCurrentDirectory: directory)
        }
    }

    func bell(_ terminal: CmdyTerminal) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.observer?.terminalModelDidBell(self)
        }
    }

    func notify(_ terminal: CmdyTerminal, title: String, body: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.observer?.terminalModel(self, didRequestNotification: title, body: body)
        }
    }

    func clipboardCopy(_ terminal: CmdyTerminal, content: Data) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.observer?.terminalModel(self, didRequestClipboardCopy: content)
        }
    }

    func contentChanged(_ terminal: CmdyTerminal) { scheduleSnapshot() }
    func willReflow(_ terminal: CmdyTerminal) {}
    func didReflow(_ terminal: CmdyTerminal) {}
    func now(_ terminal: CmdyTerminal) -> Double { CFAbsoluteTimeGetCurrent() }
}

extension TerminalModel: LocalProcessDelegate {
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.observer?.terminalModel(self, processTerminated: exitCode)
        }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        dispatchPrecondition(condition: .onQueue(queue))
        terminal.feed(slice)
    }

    func getWindowSize() -> winsize {
        sync {
            var size = winsize()
            size.ws_col = UInt16(clamping: terminal.cols)
            size.ws_row = UInt16(clamping: terminal.rows)
            size.ws_xpixel = UInt16(clamping: pixelWidth)
            size.ws_ypixel = UInt16(clamping: pixelHeight)
            return size
        }
    }
}
