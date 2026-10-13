import Foundation
import CmdyKit
@_spi(CmdyApp) import CmdyCore
@_spi(CmdyApp) import CmdyPTY

/// Main-thread event sink for a pane's worker-owned terminal model.
@MainActor
protocol TerminalModelObserver: AnyObject {
    func terminalModel(_ model: TerminalModel, didPublish snapshot: CoreTerminalSnapshot,
                       damage: SnapshotPublicationDamage)
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
    var damage: SnapshotPublicationDamage? = nil
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
    // Called only on the terminal queue, after releasing snapshotLock.
    private var renderPublication: (@Sendable (CoreTerminalSnapshot, UInt64) -> Bool)?
    private var renderAcceptedGeneration: UInt64 = 0 // protected by snapshotLock
    private var publications = SnapshotPublicationMailbox()
    private var reflowEpoch: UInt64 = 0
    private var publicationScheduler = SnapshotPublicationScheduler()
    private var historyMaintenance = HistoryMaintenanceScheduler()
    private var pendingCaptureTraceStarted: UInt64 = 0
    private var traceInputSequence = 0 // terminal-queue owned, diagnostic only
    // Explicit synthetic-fixture opt-in. Log three background colors, never
    // terminal text. Normal traces do not inspect or project any extra cells.
    private static let traceMarkerRow = CmdyPerformanceTrace.enabled
        ? ProcessInfo.processInfo.environment["CMDY_TRACE_MARKER_ROW"].flatMap(Int.init) : nil
    private var processingPTYOutput = false
    private var ptyOutputContinues = false
    /// FIONREAD, _IOR('f', 127, int); Swift cannot import the macro.
    private static let fionread: UInt = 0x4004_667f
    /// The macOS PTY output queue's high-water mark: one read never exceeds it.
    private static let ptyOutputChunk = 1024
    private var pixelWidth = 0
    private var pixelHeight = 0

    private(set) var viewportSnapshotReuseCountForTesting = 0
    private(set) var viewportSnapshotCaptureCountForTesting = 0

    weak var observer: TerminalModelObserver? {
        didSet {
            cancelKeyboardInteraction()
            snapshotLock.lock()
            publications.discardPending()
            snapshotLock.unlock()
        }
    }

    lazy var process: LocalProcess = LocalProcess(delegate: self, serialQueue: queue)

    init(cols: Int, rows: Int) {
        queue = DispatchQueue(label: "com.cmdy.model.\(UUID().uuidString)",
                              qos: .userInteractive)
        terminal = CmdyTerminal(cols: cols, rows: rows)
        publishedSnapshot = terminal.captureTerminalSnapshot(consumeDamage: false)
        publishedSnapshot.modelPublicationGeneration = 1
        queue.setSpecific(key: queueKey, value: 1)
        terminal.delegate = self
    }

    var snapshot: CoreTerminalSnapshot {
        snapshotLock.lock()
        let value = publishedSnapshot
        snapshotLock.unlock()
        return value
    }

    func setRenderPublication(_ callback: (@Sendable (CoreTerminalSnapshot, UInt64) -> Bool)?) {
        sync {
            snapshotLock.lock()
            renderAcceptedGeneration = 0
            snapshotLock.unlock()
            renderPublication = callback
            publishToRenderer(publishedSnapshot)
        }
    }
    private func publishToRenderer(_ snapshot: CoreTerminalSnapshot) {
        let traceStarted = CmdyPerformanceTrace.now()
        let accepted = renderPublication?(snapshot, publishedSnapshotGeneration) ?? false
        CmdyPerformanceTrace.record(event: "model.renderPublication", started: traceStarted,
            fields: ["model": Int(bitPattern: ObjectIdentifier(self)),
                     "generation": Int(truncatingIfNeeded: snapshot.modelPublicationGeneration),
                     "input": traceInputSequence, "accepted": accepted ? 1 : 0])
        snapshotLock.lock()
        if accepted { renderAcceptedGeneration = snapshot.modelPublicationGeneration }
        else if renderPublication == nil { renderAcceptedGeneration = 0 }
        snapshotLock.unlock()
    }
    func wasPublishedToRenderer(_ snapshot: CoreTerminalSnapshot) -> Bool {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return snapshot.modelPublicationGeneration != 0 && snapshot.modelPublicationGeneration <= renderAcceptedGeneration
    }

    private var hasPendingPublication: Bool {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return publications.pending != nil
    }

    /// Synchronous resize/scroll callers install this value before returning to
    /// the main run loop. Their cache invalidation owns any superseded damage.
    @discardableResult
    private func storeSynchronousSnapshot(
        _ snapshot: inout CoreTerminalSnapshot, publishRenderer: Bool = true
    ) -> SnapshotPublicationDamage {
        snapshotLock.lock()
        publishedSnapshotGeneration &+= 1
        snapshot.modelPublicationGeneration = publishedSnapshotGeneration + 1
        publishedSnapshot = snapshot
        let damage = publications.replaceSynchronously(snapshot, reflowEpoch: reflowEpoch)
        snapshotLock.unlock()
        if publishRenderer { publishToRenderer(snapshot) }
        return damage
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

    private func scheduleSnapshot(fromPTYOutput: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        let previous = publicationScheduler.pending?.generation
        let service = publicationScheduler.request(
            at: ProcessInfo.processInfo.systemUptime, fromPTYOutput: fromPTYOutput,
            outputContinues: fromPTYOutput && ptyOutputContinues)
        if publicationScheduler.pending?.generation != previous {
            pendingCaptureTraceStarted = CmdyPerformanceTrace.now()
        }
        if let service { enqueueCaptureService(service) }
    }

    private func scheduleHistoryMaintenance(restart: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        if let service = historyMaintenance.request(restart: restart) {
            enqueueHistoryMaintenance(service)
        }
    }

    private func enqueueHistoryMaintenance(_ service: HistoryMaintenanceScheduler.Service) {
        queue.asyncAfter(deadline: .now() + service.delay) { [weak self] in
            guard let self else { return }
            let action = self.historyMaintenance.fire(service)
            if let next = action.enqueue { self.enqueueHistoryMaintenance(next) }
            guard let batch = action.batch else { return }
            let result = self.terminal.compactHistory(
                startingAt: batch.startingAt,
                maximumRows: HistoryMaintenanceScheduler.maximumRows)
            if let next = self.historyMaintenance.finish(
                batch, nextAbsoluteRow: result.nextAbsoluteRow, complete: result.complete) {
                self.enqueueHistoryMaintenance(next)
            }
        }
    }

    private func enqueueCaptureService(_ service: SnapshotPublicationScheduler.Service) {
        let operation: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let action = self.publicationScheduler.fire(
                service, at: ProcessInfo.processInfo.systemUptime)
            if let next = action.enqueue { self.enqueueCaptureService(next) }
            guard let capture = action.capture else { return }
            CmdyPerformanceTrace.record(event: "model.snapshotWait",
                                        started: self.pendingCaptureTraceStarted,
                                        fields: ["expedited": capture.kind == .immediate ? 1 : 0])
            self.publishSnapshot()
        }
        switch service.kind {
        case .immediate:
            // Do not use async(_:): it runs inline on the worker queue. The
            // parser and all callbacks in this drain must finish before capture.
            queue.async(execute: operation)
        case .delayed:
            let delay = max(0, service.readyAt - ProcessInfo.processInfo.systemUptime)
            queue.asyncAfter(deadline: .now() + delay, execute: operation)
        }
    }

    private func publishSnapshot() {
        dispatchPrecondition(condition: .onQueue(queue))
        let captureStarted = CmdyPerformanceTrace.now()
        var snapshot = terminal.captureTerminalSnapshot()
        let publicationStarted = CmdyPerformanceTrace.now()
        snapshotLock.lock()
        publishedSnapshotGeneration &+= 1
        snapshot.modelPublicationGeneration = publishedSnapshotGeneration + 1
        publishedSnapshot = snapshot
        let generation = publishedSnapshotGeneration
        let enqueueDelivery = publications.offer(
            snapshot, generation: generation, reflowEpoch: reflowEpoch,
            started: publicationStarted)
        snapshotLock.unlock()
        if let row = Self.traceMarkerRow, row >= 0, row < snapshot.grid.rows,
           let line = snapshot.line(absolute: snapshot.grid.displayTopRow + row) {
            let started = CmdyPerformanceTrace.now()
            let cells = line.cells
            func color(_ column: Int) -> Int {
                guard cells.indices.contains(column), case let .trueColor(r, g, b) = cells[column].attribute.bg else { return -1 }
                return (Int(r) << 16) | (Int(g) << 8) | Int(b)
            }
            CmdyPerformanceTrace.record(event: "model.fixtureMarker", started: started,
                fields: ["model": Int(bitPattern: ObjectIdentifier(self)), "input": traceInputSequence,
                         "generation": Int(truncatingIfNeeded: snapshot.modelPublicationGeneration),
                         "row": row, "leftRGB": color(0), "middleRGB": color(snapshot.grid.cols / 2),
                         "rightRGB": color(snapshot.grid.cols - 1)])
        }
        CmdyPerformanceTrace.record(event: "model.capture", started: captureStarted,
                                    fields: ["generation": Int(truncatingIfNeeded: generation),
                                             "renderGeneration": Int(truncatingIfNeeded: snapshot.modelPublicationGeneration),
                                             "model": Int(bitPattern: ObjectIdentifier(self)),
                                             "input": traceInputSequence,
                                             "cursorRow": snapshot.grid.cursorRow,
                                             "cursorCol": snapshot.grid.cursorCol])
        publishToRenderer(snapshot)
        guard enqueueDelivery else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshotLock.lock()
            let publication = self.publications.take()
            self.snapshotLock.unlock()
            guard let publication else { return }
            self.snapshotLock.lock()
            let current = self.publications.accepts(publication)
            self.snapshotLock.unlock()
            CmdyPerformanceTrace.record(event: "model.mainQueueWait", started: publication.started,
                                        fields: ["generation": Int(truncatingIfNeeded: publication.generation),
                                                 "current": current ? 1 : 0])
            guard current else { return }
            let deliveryStarted = CmdyPerformanceTrace.now()
            self.observer?.terminalModel(self, didPublish: publication.snapshot,
                                         damage: publication.damage)
            CmdyPerformanceTrace.record(event: "model.delivery", started: deliveryStarted,
                                        fields: ["generation": Int(truncatingIfNeeded: publication.generation)])
        }
    }

    /// Resize and return a matching immutable capture in the same worker turn.
    /// Live resize must never draw old grid dimensions into new view bounds.
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) -> CoreTerminalSnapshot {
        sync {
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            terminal.resize(cols: cols, rows: rows)
            scheduleHistoryMaintenance(restart: true)
            publicationScheduler.resetPendingCapture()
            var snapshot = terminal.captureTerminalSnapshot()
            storeSynchronousSnapshot(&snapshot)
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
            publicationScheduler.cancelUserInput()
            historyMaintenance.resume()
            scheduleHistoryMaintenance(restart: true)
            process.startProcess(executable: executable, args: args, environment: environment,
                                 execName: String?.none, currentDirectory: currentDirectory)
        }
    }

    func terminate() {
        sync {
            renderPublication = nil
            snapshotLock.lock()
            renderAcceptedGeneration = 0
            snapshotLock.unlock()
            publicationScheduler.resetPendingCapture()
            historyMaintenance.cancel()
            process.terminate()
        }
    }
    var shellPid: pid_t { sync { process.shellPid } }
    var childFileDescriptor: Int32 { sync { process.childfd } }

    /// Only committed terminal input carries response intent. Protocol replies,
    /// focus reports and other host sends keep the ordinary output policy.
    func sendUserInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let sentAt = ProcessInfo.processInfo.systemUptime
        let enqueued = CmdyPerformanceTrace.now()
        async { [self] in
            if CmdyPerformanceTrace.enabled { traceInputSequence &+= 1 }
            CmdyPerformanceTrace.record(event: "model.inputQueueWait", started: enqueued,
                fields: ["model": Int(bitPattern: ObjectIdentifier(self)), "input": traceInputSequence])
            let started = CmdyPerformanceTrace.now()
            publicationScheduler.noteUserInput(at: sentAt)
            historyMaintenance.noteActivity()
            process.send(data: bytes[...])
            CmdyPerformanceTrace.record(event: "model.inputWrite", started: started,
                fields: ["model": Int(bitPattern: ObjectIdentifier(self)), "input": traceInputSequence,
                         "bytes": bytes.count])
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.observer?.terminalModel(self, didSend: bytes)
        }
    }

    func cancelKeyboardInteraction() {
        async { [weak self] in self?.publicationScheduler.cancelUserInput() }
    }

    func send(_ bytes: [UInt8]) {
        async { [self] in
            historyMaintenance.noteActivity()
            process.send(data: bytes[...])
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.observer?.terminalModel(self, didSend: bytes)
        }
    }

    func feed(text: String) {
        sync {
            historyMaintenance.noteActivity()
            terminal.feed(text: text)
        }
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
            historyMaintenance.noteActivity()
            let before = terminal.currentTopRow
            let hadUndeliveredSnapshot = hasPendingPublication
            let hadPendingSnapshot = publicationScheduler.isScheduled || hadUndeliveredSnapshot
            terminal.scrollViewport(to: row)
            let after = terminal.currentTopRow
            guard after != before else {
                return TerminalViewportUpdate(before: before, after: after, snapshot: nil)
            }
            scheduleHistoryMaintenance(restart: true)
            // Scrolling changes the grid origin but not its rows. Publish the
            // coherent viewport now so the renderer never combines the new
            // pixel offset with the previous yDisp for one flashing frame.
            publicationScheduler.resetPendingCapture()
            var snapshot = viewportSnapshot(hadPendingSnapshot: hadPendingSnapshot)
            // The main-actor caller must install viewport and scroll-animation
            // state together. An immediate worker model publication here can
            // show the final viewport before the scroll control, then animate
            // away from that already-presented frame. The caller's source
            // invalidation requests a coherent host capture after the event.
            let damage = storeSynchronousSnapshot(&snapshot, publishRenderer: false)
            return TerminalViewportUpdate(before: before, after: after, snapshot: snapshot,
                                          damage: damage)
        }
    }

    @discardableResult
    func scrollViewport(lines: Int) -> TerminalViewportUpdate {
        sync {
            historyMaintenance.noteActivity()
            let before = terminal.currentTopRow
            let hadUndeliveredSnapshot = hasPendingPublication
            let hadPendingSnapshot = publicationScheduler.isScheduled || hadUndeliveredSnapshot
            terminal.scrollViewport(lines: lines)
            let after = terminal.currentTopRow
            guard after != before else {
                return TerminalViewportUpdate(before: before, after: after, snapshot: nil)
            }
            scheduleHistoryMaintenance(restart: true)
            publicationScheduler.resetPendingCapture()
            var snapshot = viewportSnapshot(hadPendingSnapshot: hadPendingSnapshot)
            let damage = storeSynchronousSnapshot(&snapshot, publishRenderer: false)
            return TerminalViewportUpdate(before: before, after: after, snapshot: snapshot,
                                          damage: damage)
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
                                      kittyPixelOffsetY: $0.kittyPixelOffsetY,
                                      kittyDisplayBox: $0.kittyDisplayBox)
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
            historyMaintenance.noteActivity()
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

    func scrollbackText() -> String {
        sync {
            let count = terminal.bufferLineCount
            guard count > 0 else { return "" }
            // The grid-shaped row accessor represents a wide-cell continuation
            // as a space. Export characters through the cell-aware accessor.
            let columns = 0..<terminal.cols
            return (0..<count).map { terminal.scrollbackLineText(row: $0, columns: columns) ?? "" }
                .joined(separator: "\n") + "\n"
        }
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

    func contentChanged(_ terminal: CmdyTerminal) {
        scheduleSnapshot(fromPTYOutput: processingPTYOutput)
        scheduleHistoryMaintenance()
    }
    func willReflow(_ terminal: CmdyTerminal) {
        reflowEpoch &+= 1
        scheduleHistoryMaintenance(restart: true)
    }
    func didReflow(_ terminal: CmdyTerminal) {}
    func now(_ terminal: CmdyTerminal) -> Double { CFAbsoluteTimeGetCurrent() }
}

extension TerminalModel: LocalProcessDelegate {
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        publicationScheduler.cancelUserInput()
        historyMaintenance.cancel()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.observer?.terminalModel(self, processTerminated: exitCode)
        }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        dispatchPrecondition(condition: .onQueue(queue))
        let started = CmdyPerformanceTrace.now()
        historyMaintenance.noteActivity()
        processingPTYOutput = true
        // A read that is one piece of a larger burst: output is still queued
        // in the PTY, or the read filled the PTY's output buffer (macOS hands
        // over at most that much at a time while the writer is blocked with
        // the rest). See SnapshotPublicationScheduler.request.
        var queued: Int32 = 0
        let descriptor = process.childfd
        ptyOutputContinues = slice.count >= Self.ptyOutputChunk
            || (descriptor >= 0 && ioctl(descriptor, Self.fionread, &queued) == 0 && queued > 0)
        defer { processingPTYOutput = false; ptyOutputContinues = false }
        terminal.feed(slice)
        if CmdyPerformanceTrace.enabled {
            CmdyPerformanceTrace.record(event: "model.feed", started: started,
                                        fields: ["bytes": slice.count,
                                                 "model": Int(bitPattern: ObjectIdentifier(self)),
                                                 "input": traceInputSequence])
        }
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
