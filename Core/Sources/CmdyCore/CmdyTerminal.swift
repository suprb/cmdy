import Foundation

/// Host-facing events. The engine never touches a clock, a file, or a view:
/// everything observable leaves through here (which is what makes byte-log
/// replay deterministic).
public protocol CmdyTerminalDelegate: AnyObject {
    /// Write bytes back to the process (DA/DSR/DECRQM reports, mouse…).
    func send(_ terminal: CmdyTerminal, data: ArraySlice<UInt8>)
    func setTitle(_ terminal: CmdyTerminal, title: String)
    /// OSC 7 — raw "file://host/path" string as sent by the shell.
    func setCurrentDirectory(_ terminal: CmdyTerminal, directory: String?)
    func bell(_ terminal: CmdyTerminal)
    /// OSC 52 — clipboard write request (policy-gated by the host).
    func clipboardCopy(_ terminal: CmdyTerminal, content: Data)
    /// The screen changed; the host schedules a repaint.
    func contentChanged(_ terminal: CmdyTerminal)
    /// Buffer geometry is about to / did rewrap (block anchors hook these).
    func willReflow(_ terminal: CmdyTerminal)
    func didReflow(_ terminal: CmdyTerminal)
    /// The engine's clock: injected so replay stays deterministic.
    func now(_ terminal: CmdyTerminal) -> Double
    /// OSC 9 / OSC 777;notify — the process asks for the user's attention
    /// (agents ring this when they are blocked on input).
    func notify(_ terminal: CmdyTerminal, title: String, body: String)
}

public extension CmdyTerminalDelegate {
    func now(_ terminal: CmdyTerminal) -> Double { 0 }
    func notify(_ terminal: CmdyTerminal, title: String, body: String) {}
}

/// cmdy's VT engine. UTF-8 only, modern-xterm semantics, blocks and
/// insets native, every input byte recordable. Platform-free by law.
public final class CmdyTerminal: VTParserDelegate {

    public weak var delegate: CmdyTerminalDelegate?

    // Screens
    let normalBuffer: ScreenBuffer
    let altBuffer: ScreenBuffer
    public internal(set) var isAlternateBuffer = false {
        willSet {
            if newValue != isAlternateBuffer {
                captureReverseIndexBufferDeparture()
            }
        }
        didSet {
            if oldValue != isAlternateBuffer {
                bufferActivationSerial &+= 1
            }
        }
    }
    var buffer: ScreenBuffer { isAlternateBuffer ? altBuffer : normalBuffer }

    // Pen
    public internal(set) var currentAttribute = CellAttribute.empty
    var eraseAttribute: CellAttribute {
        CellAttribute(fg: .defaultColor, bg: currentAttribute.bg,
                      style: currentAttribute.style.intersection([]),
                      underlineKind: .none, underlineColor: nil)
    }

    // Modes
    public internal(set) var applicationCursorKeys = false     // DECCKM
    public internal(set) var originMode = false                // DECOM
    public internal(set) var autoWrap = true                   // DECAWM
    public internal(set) var insertMode = false                // IRM
    public internal(set) var lineFeedMode = false              // LNM
    public internal(set) var cursorHidden = false              // DECTCEM off
    public internal(set) var reverseVideo = false              // DECSCNM
    public internal(set) var bracketedPaste = false            // 2004
    public internal(set) var focusReporting = false            // 1004
    public internal(set) var cursorBlink = true                // ?12
    public internal(set) var cursorStyle: TermCursorShape = .blinkBlock
    public internal(set) var mouseMode: MouseMode = .off
    public internal(set) var mouseProtocol: MouseProtocolEncoding = .x10
    public internal(set) var synchronizedUpdates = false       // 2026
    public internal(set) var allow80To132 = true                // xterm ?40
    public internal(set) var marginMode = false                 // DECLRMM ?69
    public internal(set) var reverseWraparound = false           // xterm ?45

    var usingMargins: Bool { originMode && marginMode }

    // Kitty keyboard protocol flag stacks (per buffer, xterm-style).
    var kittyKeyboardStackNormal: [Int] = []
    var kittyKeyboardStackAlt: [Int] = []
    public var kittyKeyboardFlags: Int {
        (isAlternateBuffer ? kittyKeyboardStackAlt : kittyKeyboardStackNormal).last ?? 0
    }

    // Title stack (XTWINOPS 22/23)
    public internal(set) var title = ""
    var titleStack: [String] = []

    // OSC 8 links
    var linkTable: [String] = []       // id-1 indexed
    var activeLinkId: UInt16 = 0

    // Blocks (OSC 133) — native structure
    public let blocks = BlockTracker()
    var blocksDroppedLineCheckpoint = 0
    var commandFinishedHostMessageProvider: ((String, String, Int32?) -> String?)?
    private var isWritingHostMessage = false

    // Graphics
    public let kittyGraphics = KittyGraphicsStore()
    var sixelDecoder: SixelDecoder?
    var dcsKind: DCSKind = .none
    var decrqssBuffer: [UInt8] = []
    var kittyChunkControl: KittyControl?
    var kittyChunkData: [UInt8] = []
    var inlineImagePayloadBytes = 0

    enum DCSKind { case none, sixel, xtgettcap, decrqss, other }

    // Damage: absolute-row span touched since the last consumeDirtyRows().
    var dirtyRowSpan: ClosedRange<Int>?

    struct MarginDeleteVirtualCell: Hashable {
        let row: Int
        let column: Int
    }

    struct MarginDeleteGeneration {
        var witnessLine: Line
        let retainedBottomRow: Int
        var virtualCells: [MarginDeleteVirtualCell: CellAttribute]
        var virtualContentCells: [MarginDeleteVirtualCell: Cell]
    }
    var marginDeleteGenerations: [MarginDeleteGeneration] = []

    // Replay
    public internal(set) var recorder: SessionRecorder?

    // Charset (declared non-goal: UTF-8 only; SO/SI tracked but inert)
    var glLevel = 0

    let parser = VTParser()

    public init(cols: Int, rows: Int, scrollback: Int = 10_000) {
        normalBuffer = ScreenBuffer(cols: cols, rows: rows, hasScrollback: true,
                                    maxScrollback: scrollback)
        // The reference alt buffer's ring holds rows+1 lines: it grows by
        // exactly one on the first full-screen scroll (yBase parks at 1)
        // and recycles thereafter — scrollback capacity 1, faithfully.
        altBuffer = ScreenBuffer(cols: cols, rows: rows, hasScrollback: true,
                                 maxScrollback: 1)
        // The reference's startup soft-reset widens the CURRENT (normal)
        // buffer's margins; the alt buffer keeps marginRight == 0 until a
        // soft reset runs while it is active. Faithfully mirrored.
        normalBuffer.marginLeft = 0
        normalBuffer.marginRight = cols - 1
        parser.delegate = self
    }

    // MARK: - Feeding

    public func feed(_ bytes: ArraySlice<UInt8>) {
        recorder?.record(bytes)
        parser.feed(bytes)
        synchronizeBlockRowsToScrollback()
        delegate?.contentChanged(self)
    }

    public func feed(_ bytes: [UInt8]) { feed(bytes[...]) }

    public func feed(text: String) { feed(Array(text.utf8)[...]) }

    /// Host-owned text that belongs in scrollback but not in the PTY byte
    /// stream. OSC callbacks run while the parser is consuming a chunk, so
    /// this writes cells directly instead of recursively feeding the parser.
    public func insertHostMessage(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isAlternateBuffer else { return }

        let savedAttribute = currentAttribute
        let savedLink = activeLinkId
        let savedHostMessageState = isWritingHostMessage
        currentAttribute = CellAttribute(style: .dim)
        activeLinkId = 0
        isWritingHostMessage = true
        defer {
            currentAttribute = savedAttribute
            activeLinkId = savedLink
            isWritingHostMessage = savedHostMessageState
        }

        func newline() {
            executeControl(0x0D)
            executeControl(0x0A)
        }
        func softWrap() {
            let buf = buffer
            buf.x = 0
            if buf.y >= buf.scrollBottom {
                engineScrollUp(markNewWrapped: true)
            } else {
                buf.y += 1
                buf.liveLine(buf.y).isWrapped = true
            }
            buf.liveLine(buf.y).wrapStyle = .words
        }
        func printWord(_ scalars: [UnicodeScalar]) {
            guard !scalars.isEmpty else { return }
            let width = scalars.reduce(0) { partial, scalar in
                partial + max(0, UnicodeUtil.columnWidth(rune: scalar))
            }
            if width < buffer.cols, buffer.x > 0, buffer.x + width > buffer.cols {
                softWrap()
            }
            for scalar in scalars { printScalar(scalar) }
        }
        if buffer.x != 0 { newline() }
        var word: [UnicodeScalar] = []
        for scalar in message.unicodeScalars {
            if scalar == "\n" {
                printWord(word)
                word.removeAll(keepingCapacity: true)
                newline()
            } else if scalar == "\r" {
                printWord(word)
                word.removeAll(keepingCapacity: true)
                executeControl(0x0D)
            } else if CharacterSet.whitespaces.contains(scalar) {
                printWord(word)
                word.removeAll(keepingCapacity: true)
                printScalar(scalar)
            } else {
                word.append(scalar)
            }
        }
        printWord(word)
        newline()
        markAllDirty()
        delegate?.contentChanged(self)
    }

    public func setCommandFinishedHostMessageProvider(
        _ provider: ((String, String, Int32?) -> String?)?) {
        commandFinishedHostMessageProvider = provider
    }

    /// Attach a recorder; every byte fed from now on lands in the log.
    public func startRecording(_ recorder: SessionRecorder) {
        self.recorder = recorder
    }

    func sendResponse(_ text: String) {
        delegate?.send(self, data: ArraySlice(Array(text.utf8)))
    }

    // MARK: - Geometry / public accessors (the TerminalEngine dialect)

    public var cols: Int { buffer.cols }
    public var rows: Int { buffer.rows }
    public var bufferLineCount: Int { buffer.lineCount }
    public var currentTopRow: Int { buffer.yDisp }
    public var liveScreenTopRow: Int { buffer.yBase }
    public var scrollbackDroppedLines: Int { normalBuffer.droppedLines }
    public var scrollInvariantCursorRow: Int { buffer.yBase + buffer.y }
    public var cursorColumn: Int { buffer.x }
    public var cursorRow: Int { buffer.y }

    public func isBufferRowWrapped(_ row: Int) -> Bool {
        buffer.line(absolute: row)?.isWrapped ?? false
    }

    public func scrollbackLineText(row: Int) -> String? {
        buffer.line(absolute: row)?.trimmedText()
    }

    public func scrollbackLineTexts(rows: ClosedRange<Int>) -> [String] {
        rows.map { buffer.line(absolute: $0)?.trimmedText() ?? "" }
    }

    /// Plain text for a terminal-cell range. Wide-character continuation cells
    /// are skipped instead of being mistaken for String character indexes.
    /// The range is clipped to meaningful row content, matching the existing
    /// right-trimmed line accessor.
    public func scrollbackLineText(row: Int, columns: Range<Int>) -> String? {
        guard let line = buffer.line(absolute: row) else { return nil }
        let cells = line.cells
        let lower = max(0, min(columns.lowerBound, cells.count))
        let upper = max(lower, min(columns.upperBound, line.trimmedLength, cells.count))
        var text = ""
        for cell in cells[lower..<upper] {
            if cell.width == 0 { continue }
            text += cell.scalar == 0 ? " " : cell.text
        }
        return text
    }

    public var kittyImageCount: Int { kittyGraphics.imagesById.count }

    public var linesWithImagesCount: Int {
        var count = 0
        for line in buffer.lines where !(line.images?.isEmpty ?? true) { count += 1 }
        return count
    }

    public var mouseModeDescription: String { "\(mouseMode)" }

    /// Move the viewport (wheel / scrollbar). Clamped; `0 ≤ yDisp ≤ yBase`.
    public func scrollViewport(to row: Int) {
        let clamped = max(0, min(row, buffer.yBase))
        guard clamped != buffer.yDisp else { return }
        buffer.yDisp = clamped
        delegate?.contentChanged(self)
    }

    public func scrollViewport(lines: Int) {
        scrollViewport(to: buffer.yDisp + lines)
    }

    // MARK: - OSC handler hook (app registers 133 today; API-compatible)

    var oscHandlers: [Int: (ArraySlice<UInt8>) -> Void] = [:]

    public func registerOscHandler(code: Int, handler: @escaping (ArraySlice<UInt8>) -> Void) {
        oscHandlers[code] = handler
    }

    /// Keep native block coordinates local to the retained normal buffer.
    /// Synchronizing once per parser chunk amortizes pruning across bursts;
    /// OSC 133 synchronizes before creating a new anchor within that chunk.
    func synchronizeBlockRowsToScrollback() {
        let dropped = normalBuffer.droppedLines
        guard dropped >= blocksDroppedLineCheckpoint else {
            blocksDroppedLineCheckpoint = dropped
            return
        }
        let delta = dropped - blocksDroppedLineCheckpoint
        if delta > 0 { blocks.rebase(droppedLines: delta) }
        blocksDroppedLineCheckpoint = dropped
    }

    // MARK: - VTParserDelegate

    public func parserPrint(_ scalar: UnicodeScalar) {
        printScalar(scalar)
        markDirty(absoluteRow: buffer.yBase + buffer.y)
    }

    public func parserPrintASCII(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }

        // Insert mode and horizontal margins reshape cells rather than merely
        // replacing them. Keep those uncommon paths on the scalar oracle.
        guard autoWrap, !insertMode, !marginMode, buffer.x >= 0 else {
            for byte in bytes { parserPrint(UnicodeScalar(byte)) }
            return
        }

        let preservesDisplacedReverseIndexOwner =
            reverseIndexOwnerRefreshIsDisplaced()
        let suppressRelocationAfterCursorUp = pendingCursorUpMoved
        pendingCursorUpMoved = false
        let advancedFromNoWrapParkedPosition = noWrapParkedAfterPrint
        noWrapParkedAfterPrint = false
        let buf = buffer
        var source = bytes.startIndex
        while source < bytes.endIndex {
            let right = buf.cols - 1
            let beganFromPendingOwner =
                buf.wrapPending && buf.x > right
            let pendingOwnerWasCurrent: Bool
            if beganFromPendingOwner {
                pendingOwnerWasCurrent =
                    pendingWrapOwnerStillOccupiesDeparture()
            } else {
                pendingOwnerWasCurrent =
                    !advancedFromNoWrapParkedPosition
            }
            var advancedToFreshRow = false
            if buf.x > right {
                buf.x = 0
                buf.wrapPending = false
                advancedToFreshRow = true
                if buf.y >= buf.scrollBottom {
                    let remaining = bytes.distance(from: source, to: bytes.endIndex)
                    if remaining >= buf.cols, buf.canAppendFullScreenScrollbackLine {
                        let end = bytes.index(source, offsetBy: buf.cols)
                        let line = Line(fullASCII: bytes[source..<end],
                                        attribute: currentAttribute,
                                        linkId: activeLinkId,
                                        isWrapped: true)
                        buf.appendFullScreenScrollbackLine(line)
                        let absoluteRow = buf.yBase + buf.y
                        buf.x = buf.cols
                        lastWrite = (row: absoluteRow, x: buf.cols - 1,
                                     cols: buf.cols, rows: buf.rows)
                        markDirty(absoluteRow: absoluteRow)
                        buf.wrapPending = true
                        source = end
                        continue
                    }
                    let establishesWholeRowWrapAtBottom =
                        buf.y == buf.scrollBottom
                    engineScrollUp(markNewWrapped: true,
                                   clearNewLine: remaining < buf.cols)
                    if establishesWholeRowWrapAtBottom {
                        let destination = buf.liveLine(buf.scrollBottom)
                        clearActiveMarginReflowBoundary(from: destination)
                        clearSupersededKittyDisplayReflowState(
                            from: destination)
                    }
                } else {
                    buf.y += 1
                    let destination = buf.liveLine(buf.y)
                    if beganFromPendingOwner {
                        // The fast ASCII path bypasses
                        // advanceForPendingWrap. A real whole-row continuation
                        // supersedes the destination witness. If that witness
                        // is the exposed-row claim, the preceding hard
                        // boundary still groups the incoming continuation;
                        // otherwise the immediate successor claim belongs to
                        // the same consumed destination boundary.
                        let destinationWasClaimed =
                            hasKittyDisplayReflowClaim(on: destination)
                        clearSupersededKittyDisplayReflowState(
                            from: destination)
                        if !destinationWasClaimed {
                            if buf.y + 1 < buf.rows {
                                clearSupersededKittyDisplayReflowState(
                                    from: buf.liveLine(buf.y + 1))
                            }
                        }
                    }
                    destination.isWrapped = true
                    clearActiveMarginReflowBoundary(from: destination)
                }
            }

            let available = right - buf.x + 1
            guard available > 0 else {
                // Defensive fallback for an externally-corrupted cursor.
                parserPrint(UnicodeScalar(bytes[source]))
                source = bytes.index(after: source)
                continue
            }
            let count = min(available, bytes.distance(from: source, to: bytes.endIndex))
            let end = bytes.index(source, offsetBy: count)
            let startColumn = buf.x
            let absoluteRow = buf.yBase + buf.y
            let line = buf.liveLine(buf.y)
            line.writeASCII(bytes[source..<end], at: startColumn,
                            attribute: currentAttribute, linkId: activeLinkId)

            buf.x += count
            buf.wrapPending = buf.x > right
            lastWrite = (row: absoluteRow, x: startColumn + count - 1,
                         cols: buf.cols, rows: buf.rows)
            // Only the first byte written after a wrap owns that transition.
            // If this bulk segment contains more bytes, the final ASCII base
            // was written later on the row and must not inherit the first
            // byte's relocation provenance.
            lastPrintAdvancedToFreshRow =
                advancedToFreshRow && count == 1 &&
                !(suppressRelocationAfterCursorUp &&
                    source == bytes.startIndex)
            lastPrintAdvancedFromCurrentPendingOwner =
                lastPrintAdvancedToFreshRow && pendingOwnerWasCurrent
            markDirty(absoluteRow: absoluteRow)
            source = end
        }

        if let byte = bytes.last {
            finishPrintReverseIndexOwnerRefresh(
                preservingDisplacedOwner:
                    preservesDisplacedReverseIndexOwner,
                printedOwnerRow: lastWrite.row,
                printedOwnerColumn: lastWrite.x)
            backwardColumnAttachmentWitness = nil
            lastPrintedScalar = UnicodeScalar(byte)
            presentationSelectorAuthority = .available
            refreshPendingWrapOwnerWitnessFromLastCluster()
        }
    }

    public func parserPrintASCIIAndCRLF(_ bytes: ArraySlice<UInt8>) {
        parserPrintASCII(bytes)
        let beforeRow = buffer.yBase + buffer.y
        let beforeBase = buffer.yBase
        executeControl(0x0D)
        executeControl(0x0A)
        markControlDamage(beforeRow: beforeRow, beforeBase: beforeBase)
    }

    public func parserPrintASCIILines(_ bytes: ArraySlice<UInt8>) {
        var index = bytes.startIndex
        var alreadyWritten = false

        while index < bytes.endIndex {
            let contentStart = index
            while index < bytes.endIndex, bytes[index] >= 0x20, bytes[index] <= 0x7E {
                index = bytes.index(after: index)
            }
            let contentEnd = index
            guard contentEnd > contentStart else { return }
            guard index < bytes.endIndex else { return }
            index = bytes.index(after: index) // CR
            guard index < bytes.endIndex else { return }
            index = bytes.index(after: index) // LF

            if !alreadyWritten { parserPrintASCII(bytes[contentStart..<contentEnd]) }
            alreadyWritten = false

            let nextStart = index
            var nextEnd = nextStart
            while nextEnd < bytes.endIndex,
                  bytes[nextEnd] >= 0x20, bytes[nextEnd] <= 0x7E {
                nextEnd = bytes.index(after: nextEnd)
            }
            let hasNext = nextEnd > nextStart
                && nextEnd < bytes.endIndex && bytes[nextEnd] == 0x0D

            let beforeRow = buffer.yBase + buffer.y
            let beforeBase = buffer.yBase
            executeControl(0x0D)
            let canAppendPopulatedLine = hasNext && autoWrap && !insertMode && !marginMode
                && buffer.y == buffer.scrollBottom
                && buffer.canScrollFullScreenIntoScrollback
                && bytes.distance(from: nextStart, to: nextEnd) <= buffer.cols
            if canAppendPopulatedLine {
                let nextBytes = bytes[nextStart..<nextEnd]
                let preservesDisplacedReverseIndexOwner =
                    reverseIndexOwnerRefreshIsDisplaced()
                buffer.scrollUpPopulatedASCII(
                    nextBytes, fill: Cell.blank(attribute: eraseAttribute),
                    attribute: currentAttribute, linkId: activeLinkId)
                buffer.x = nextBytes.count
                let absoluteRow = buffer.yBase + buffer.y
                lastWrite = (row: absoluteRow, x: max(0, nextBytes.count - 1),
                             cols: buffer.cols, rows: buffer.rows)
                if let byte = nextBytes.last {
                    finishPrintReverseIndexOwnerRefresh(
                        preservingDisplacedOwner:
                            preservesDisplacedReverseIndexOwner,
                        printedOwnerRow: lastWrite.row,
                        printedOwnerColumn: lastWrite.x)
                    backwardColumnAttachmentWitness = nil
                    lastPrintedScalar = UnicodeScalar(byte)
                    presentationSelectorAuthority = .available
                }
                markDirty(absoluteRow: absoluteRow)
                markControlDamage(beforeRow: beforeRow, beforeBase: beforeBase)
                index = nextStart
                alreadyWritten = true
            } else {
                executeControl(0x0A)
                markControlDamage(beforeRow: beforeRow, beforeBase: beforeBase)
            }
        }
    }

    public func parserExecute(_ byte: UInt8) {
        let beforeRow = buffer.yBase + buffer.y
        let beforeBase = buffer.yBase
        executeControl(byte)
        markControlDamage(beforeRow: beforeRow, beforeBase: beforeBase)
    }

    private func markControlDamage(beforeRow: Int, beforeBase: Int) {
        let scrolled = buffer.yBase - beforeBase
        if scrolled > 0 && scrolled < buffer.rows {
            // A plain scroll (LF at the bottom, before scrollback fills): the
            // surviving rows keep their content — the renderer re-places them via
            // the draw-time scroll shift instead of rebuilding the whole screen.
            // Only the newly-revealed bottom rows are dirty. (Once scrollback is
            // full, trim cancels the yBase bump so scrolled==0 → the else branch,
            // which also marks just the bottom.)
            markDirty(absoluteRows: (buffer.yBase + buffer.rows - scrolled)...(buffer.yBase + buffer.rows - 1))
        } else if scrolled != 0 {
            markAllDirty()                  // scrolled a screenful+ (or reverse)
        } else {
            markDirty(absoluteRow: beforeRow)
            markDirty(absoluteRow: buffer.yBase + buffer.y)
        }
    }

    public func parserCSI(final: UInt8, params: [Int], collect: [UInt8]) {
        let beforeRow = buffer.yBase + buffer.y
        dispatchCSI(final: final, params: params, collect: collect)
        // Row-shifting / screen-clearing commands invalidate broadly. But NOT
        // every one is whole-screen — being precise here matters now that a
        // scroll no longer rebuilds the grid: the shell toggles bracketed-paste
        // (CSI ?2004h/l) and erases-below (CSI 0J) around EVERY prompt redraw,
        // so blanket markAllDirty made holding Return rebuild the whole screen.
        let cursorRow = buffer.yBase + buffer.y
        let screenTop = buffer.yBase
        let screenBottom = buffer.yBase + buffer.rows - 1
        // These marks are a PERF hint only — Line.version drives correctness (a
        // row whose cells changed is rebuilt even if unmarked), so we can mark
        // precisely without risking stale rows.
        switch final {
        case UInt8(ascii: "L"), UInt8(ascii: "M"),
             UInt8(ascii: "S"), UInt8(ascii: "T"), UInt8(ascii: "r"),
             UInt8(ascii: "p"):
            markAllDirty()                              // genuinely reshuffle rows
        case UInt8(ascii: "J"):
            // Erase in display: 0/none = cursor→end, 1 = start→cursor, 2/3 = all.
            switch params.first ?? 0 {
            case 2, 3: markAllDirty()
            case 1:    markDirty(absoluteRows: screenTop...max(screenTop, cursorRow))
            default:   markDirty(absoluteRows: min(cursorRow, screenBottom)...screenBottom)
            }
        case UInt8(ascii: "h"), UInt8(ascii: "l"):
            // Only whole-surface modes repaint: DECCOLM (3), reverse-video (5),
            // alt-screen (47/1047/1049). Per-keystroke togglers the shell emits
            // around every prompt (bracketed paste 2004, cursor 25, mouse,
            // autowrap) change no cell — marking all made holding Return crawl.
            if params.contains(where: { [3, 5, 47, 1047, 1049].contains($0) }) {
                markAllDirty()
            } else {
                markDirty(absoluteRow: beforeRow)
                markDirty(absoluteRow: cursorRow)
            }
        default:
            markDirty(absoluteRow: beforeRow)
            markDirty(absoluteRow: cursorRow)
        }
    }

    public func parserESC(final: UInt8, collect: [UInt8]) {
        let beforeBase = buffer.yBase
        dispatchESC(final: final, collect: collect)
        if buffer.yBase != beforeBase || final == UInt8(ascii: "c")
            || final == UInt8(ascii: "8") || final == UInt8(ascii: "M")
            || final == UInt8(ascii: "D") || final == UInt8(ascii: "E")
            || final == UInt8(ascii: "6") || final == UInt8(ascii: "9") {
            markAllDirty()
        } else {
            markDirty(absoluteRow: buffer.yBase + buffer.y)
        }
    }

    public func parserOSC(code: Int, payload: ArraySlice<UInt8>) {
        dispatchOSC(code: code, payload: payload)
    }

    public func parserDCSHook(final: UInt8, params: [Int], collect: [UInt8]) {
        dcsHook(final: final, params: params, collect: collect)
    }

    public func parserDCSPut(_ bytes: ArraySlice<UInt8>) {
        dcsPut(bytes)
    }

    public func parserDCSUnhook() {
        dcsUnhook()
    }

    public func parserAPC(_ bytes: ArraySlice<UInt8>) {
        let buf = buffer
        let rawColumn = buf.x
        let sourceRow = buf.y
        let sourceLine = buf.liveLine(sourceRow)
        let result = handleAPCResult(bytes)
        applyKittyLineGeneration(result, sourceLine: sourceLine)
        guard result.shouldApplyDisplayLineMotion else { return }

        // The graphics handler performs decoding, storage, and placement. Its
        // historical cursor move is deliberately replaced here with the
        // terminal's Kitty row rule, using the pre-control cursor and stored
        // horizontal gate. This also covers successful actions whose public
        // cursor would otherwise be unchanged, so a row-delta heuristic is
        // insufficient.
        buf.x = rawColumn
        buf.y = sourceRow
        applyKittyDisplayLineMotion(
            display: result.display,
            sourceLine: sourceLine)
    }

    private func applyKittyLineGeneration(
        _ result: KittyAPCResult,
        sourceLine: Line
    ) {
        let preservedDisplay: (
            line: Line, key: KittyAPCResult.PlacementKey
        )? = result.display.flatMap {
            guard !$0.isVirtual else { return nil }
            return (line: sourceLine,
                    key: KittyAPCResult.PlacementKey(
                        imageId: $0.imageId, placementId: $0.placementId))
        }

        let retiredImageIds = Set(
            result.committedTransmissionImageId.map { [$0] } ?? [])
        if !retiredImageIds.isEmpty || !result.removedPlacementKeys.isEmpty {
            stripKittyLineGenerationImages(
                withImageIds: retiredImageIds,
                placementKeys: result.removedPlacementKeys,
                preserving: preservedDisplay)
        }
    }

    private func stripKittyLineGenerationImages(
        withImageIds retiredImageIds: Set<UInt32>,
        placementKeys retiredKeys: Set<KittyAPCResult.PlacementKey>,
        preserving display: (line: Line, key: KittyAPCResult.PlacementKey)?
    ) {
        for screen in [normalBuffer, altBuffer] {
            for line in screen.lines {
                guard let images = line.images else { continue }
                let retained = images.filter { image in
                    guard image.kittyIsKitty,
                          let imageId = image.kittyImageId,
                          let placementId = image.kittyPlacementId else {
                        return true
                    }
                    let key = KittyAPCResult.PlacementKey(
                        imageId: imageId, placementId: placementId)
                    if let display,
                       display.line === line,
                       display.key == key {
                        return true
                    }
                    return !retiredImageIds.contains(imageId) &&
                        !retiredKeys.contains(key)
                }
                if retained.count != images.count {
                    line.images = retained.isEmpty ? nil : retained
                }
            }
        }
        pruneKittyDisplayReflowImages()
        markAllDirty()
    }

    private func applyKittyDisplayLineMotion(
        display: KittyAPCResult.Display?,
        sourceLine: Line
    ) {
        let buf = buffer
        let oldYBase = buf.yBase
        let oldAbsoluteRow = oldYBase + buf.y
        let exposedBlank = Cell.blank(attribute: eraseAttribute)
        let storedColumnIsEligible =
            (buf.marginLeft...buf.marginRight).contains(buf.x)
        var mutatedRows = false

        if buf.y == buf.scrollBottom {
            if storedColumnIsEligible {
                if hasNarrowMargins {
                    let destination = buf.scrollBottom > buf.scrollTop
                        ? buf.liveLine(buf.scrollBottom - 1)
                        : nil
                    let carriesWrappedGeneration =
                        destination?.isWrapped == true
                    let carriesVirtualDeleteGeneration =
                        marginDeleteGenerations.contains { generation in
                            generation.witnessLine === sourceLine
                        }
                    // Even when the copied destination is not part of a
                    // wrapped generation, the placement marker remains on
                    // the old bottom Line object.  It is transient sizing
                    // metadata, not meaningful text extent: a later RI/home
                    // followed by a row shrink may discard that empty Line.
                    // Register it for the same suspend/restore pass used by
                    // wrapped placement generations; surviving rows regain
                    // the image after sizing, while a trimmed row does not
                    // extend the line store merely because it held a marker.
                    recordKittyDisplayReflowImage(display, on: sourceLine)
                    if carriesWrappedGeneration, let destination {
                        recordKittyDisplayReflowBoundaries(
                            endingAt: destination,
                            in: buf,
                            row: buf.scrollBottom - 1)
                        recordKittyDisplayReflowImageTransfer(
                            display,
                            from: sourceLine,
                            to: destination)
                    }
                    scrollNarrowSlices(
                        direction: .towardTop,
                        fill: exposedBlank,
                        exposedRowWrapped: false,
                        // A generation ending immediately above the exposed
                        // row uses the dedicated Kitty boundary/claim model.
                        // Otherwise this is an ordinary partial-slice copy:
                        // any disconnected prewrapped destination it mutates
                        // keeps the same hard reflow boundary as LF/IND.
                        hardenPrewrappedDestinations:
                            !carriesWrappedGeneration)
                    if carriesWrappedGeneration {
                        if carriesVirtualDeleteGeneration, let destination {
                            // The slice copy can make a previously blank
                            // wrapped member of this placement generation
                            // meaningful when an earlier partial DL retained
                            // that hidden row generation. Reconcile only that
                            // generation against the post-copy cells while
                            // retaining its pre-copy boundaries.
                            recordKittyDisplayReflowBoundaries(
                                endingAt: destination,
                                in: buf,
                                row: buf.scrollBottom - 1)
                        }
                        if let destination {
                            recordKittyDisplayClippedTopReflowRank(
                                endingAt: destination,
                                in: buf,
                                row: buf.scrollBottom - 1)
                        }
                        recordKittyDisplayReflowClaim(
                            on: buf.liveLine(buf.scrollBottom))
                    }
                } else if buf.scrollTop == 0 && !buf.hasScrollback {
                    // The reference generates a retained row even on the
                    // alternate buffer. ScreenBuffer's ordinary alternate
                    // scroll rotates in place, so insert this terminal-owned
                    // Kitty row explicitly at the region boundary.
                    let viewportWasAtBottom = buf.yDisp == buf.yBase
                    var retainedLines = buf.lines
                    let insertion = min(
                        retainedLines.count,
                        max(0, buf.yBase + buf.scrollBottom + 1))
                    retainedLines.insert(
                        Line(cols: buf.cols, fill: exposedBlank), at: insertion)
                    buf.replaceLines(retainedLines)
                    buf.yBase += 1
                    if viewportWasAtBottom { buf.yDisp = buf.yBase }
                } else {
                    // Direct ScreenBuffer motion intentionally leaves semantic
                    // block anchors untouched for Kitty placement.
                    buf.scrollUp(fill: exposedBlank)
                }
                // A partial horizontal-margin placement scroll only replaces
                // slices inside the existing Line objects. Keep the same
                // hidden IL/DL row generation that ordinary partial-margin
                // scrolling preserves; a later line edit can still source a
                // virtual row from it. Whole-width motion recycles row
                // identity and must retire the generation as before.
                if !hasNarrowMargins {
                    marginDeleteGenerations.removeAll(keepingCapacity: true)
                }
                mutatedRows = true
            }
        } else if buf.y < buf.rows - 1 {
            buf.y += 1
        }

        buf.x = 0
        buf.wrapPending = false
        noWrapParkedAfterPrint = false
        // A successful display action is cursor motion even though graphics
        // placement itself does not print a cell.  Keep a selector-sensitive
        // owner on its original Line, while recording the cursor's new
        // logical row so a later width-changing selector preserves the same
        // horizontal offset as ordinary IND/LF/RI motion.
        recordSelectorOwnerVerticalMotion(from: oldAbsoluteRow)

        if mutatedRows {
            let dirtyLower = oldYBase + buf.scrollTop
            let dirtyUpper = max(
                oldYBase + buf.scrollBottom,
                buf.yBase + buf.scrollBottom)
            markDirty(absoluteRows: dirtyLower...dirtyUpper)
        }
        markDirty(absoluteRow: oldAbsoluteRow)
        markDirty(absoluteRow: buf.yBase + buf.y)
    }

    private func recordKittyDisplayReflowImage(
        _ display: KittyAPCResult.Display?,
        on line: Line
    ) {
        guard let display, !display.isVirtual,
              let images = line.images else { return }
        for image in images where image.kittyIsKitty &&
            image.kittyImageId == display.imageId &&
            image.kittyPlacementId == display.placementId {
            if !kittyDisplayReflowImages.contains(where: { $0 === image }) {
                kittyDisplayReflowImages.append(image)
            }
        }
    }

    /// A placement-driven rectangular scroll carries the bottom source slice
    /// into the preceding physical Line without rotating Line objects.  The
    /// destination remains a real logical separator even if the image is
    /// later retransmitted or deleted.  Preserve the nonempty rows of its
    /// incoming wrapped generation as well, because their physical boundaries
    /// are otherwise lost when the image-free cell slices are reflowed.
    private func recordKittyDisplayReflowBoundaries(
        endingAt destination: Line,
        in screen: ScreenBuffer,
        row destinationRow: Int
    ) {
        var firstRow = destinationRow
        while firstRow > 0, screen.liveLine(firstRow).isWrapped {
            firstRow -= 1
        }
        // The dedicated Kitty boundary/claim pair below owns the contiguous
        // generation ending at `destination`.  A partial-slice copy can also
        // cross older, disconnected soft-wrap rows earlier in the active
        // scroll region.  Those Line identities remain physical separators
        // for the next width reflow, even when their cells are later erased.
        // Record only rows before this placement generation: hardening the
        // destination generation itself would duplicate its Kitty claim and
        // retain blank upper rows that the reference legitimately coalesces.
        if screen.scrollTop < firstRow {
            for row in screen.scrollTop..<firstRow {
                let line = screen.liveLine(row)
                guard line.isWrapped,
                      !activeMarginReflowBoundaries.contains(where: {
                          $0.line === line
                      }) else { continue }
                activeMarginReflowBoundaries.append(
                    ActiveMarginReflowBoundary(line: line))
            }
        }
        // Reaching the live top while it is still wrapped means the logical
        // generation began in scrollback. That first visible row is only a
        // clipped continuation, so it must not become a persistent hard
        // boundary. Rows below it are fully observed members of the copied
        // generation.
        let clippedLiveTop = firstRow == 0 && destinationRow > 0 &&
            screen.liveLine(firstRow).isWrapped
        let firstObservedRow = clippedLiveTop ? 1 : firstRow
        guard firstObservedRow <= destinationRow else { return }
        for row in firstObservedRow...destinationRow {
            let line = screen.liveLine(row)
            guard row == destinationRow || line.usedLength > 0 else { continue }
            if !kittyDisplayReflowBoundaries.contains(where: {
                $0.line === line
            }) {
                kittyDisplayReflowBoundaries.append(
                    KittyDisplayReflowBoundary(line: line))
            }
        }
    }

    /// The copied slice can introduce a narrow cell into a wrapped generation
    /// whose first visible row is clipped by scrollback. That row remains a
    /// soft continuation during ordinary editing, but its physical rank is
    /// observable at the next width reflow. Keep a separate one-shot witness
    /// instead of promoting it to a persistent Kitty boundary.
    private func recordKittyDisplayClippedTopReflowRank(
        endingAt destination: Line,
        in screen: ScreenBuffer,
        row destinationRow: Int
    ) {
        // Only a scroll that reaches the physical live top can make that
        // clipped continuation's rank part of the placement generation.
        // An inset vertical region copies its own bottom slice without
        // owning the wrapped rows above `scrollTop`; hardening live row zero
        // in that case creates an extra logical row on the next reflow.
        guard screen === normalBuffer, screen.scrollTop == 0,
              destinationRow > 0 else { return }
        var firstRow = destinationRow
        while firstRow > 0, screen.liveLine(firstRow).isWrapped {
            firstRow -= 1
        }
        guard firstRow == 0, screen.liveLine(0).isWrapped,
              (firstRow...destinationRow).contains(where: { row in
                  let line = screen.liveLine(row)
                  return line.cells.prefix(line.usedLength).contains {
                      $0.width == 1
                  }
              }) else { return }
        let line = screen.liveLine(0)
        if !kittyDisplayClippedTopReflowRanks.contains(where: {
            $0.line === line
        }) {
            kittyDisplayClippedTopReflowRanks.append(
                KittyDisplayClippedTopReflowRank(line: line))
        }
    }

    /// Keep graphics placement attached to its graphics-owned Line until an
    /// actual width reflow.  A same-column row resize must observe the
    /// original placement row, while width reflow treats the image as part of
    /// the rectangular slice copied into `destination`.
    private func recordKittyDisplayReflowImageTransfer(
        _ display: KittyAPCResult.Display?,
        from source: Line,
        to destination: Line
    ) {
        guard let display, !display.isVirtual,
              source !== destination,
              let images = source.images else { return }
        for image in images where image.kittyIsKitty &&
            image.kittyImageId == display.imageId &&
            image.kittyPlacementId == display.placementId {
            if !kittyDisplayReflowImages.contains(where: { $0 === image }) {
                kittyDisplayReflowImages.append(image)
            }
            if !kittyDisplayReflowImageTransfers.contains(where: {
                $0.image === image
            }) {
                kittyDisplayReflowImageTransfers.append(
                    KittyDisplayReflowImageTransfer(
                        image: image,
                        source: source,
                        destination: destination,
                        successor: buffer.scrollBottom + 1 < buffer.rows
                            ? buffer.liveLine(buffer.scrollBottom + 1)
                            : nil))
            }
        }
    }

    /// The exposed bottom row is virtual until later content, cursor state, or
    /// a semantic anchor makes it observable.  Reflow preserves its physical
    /// rank relative to the preceding row without turning any copied
    /// destination row into a hard logical boundary.
    private func recordKittyDisplayReflowClaim(on line: Line) {
        guard !kittyDisplayReflowClaims.contains(where: {
            $0.line === line
        }) else { return }
        kittyDisplayReflowClaims.append(
            KittyDisplayReflowClaim(line: line))
    }

    func materializeKittyDisplayReflowImageTransfers(in screen: ScreenBuffer) {
        let transfers = kittyDisplayReflowImageTransfers.filter { transfer in
            screen.lines.contains(where: { $0 === transfer.destination })
        }
        for transfer in transfers {
            guard let source = screen.lines.first(where: { line in
                line.images?.contains(where: { $0 === transfer.image }) == true
            }), source !== transfer.destination else { continue }
            let retained = source.images?.filter { $0 !== transfer.image }
            source.images = retained?.isEmpty == false ? retained : nil
            if transfer.destination.images?.contains(where: {
                $0 === transfer.image
            }) != true {
                transfer.destination.images =
                    (transfer.destination.images ?? []) + [transfer.image]
            }
        }
        kittyDisplayReflowImageTransfers.removeAll { transfer in
            screen.lines.contains(where: { $0 === transfer.destination })
        }
    }

    /// Height-only trimming may temporarily remove the physical Lines that
    /// carry a Kitty placement generation.  The generation remains latent and
    /// becomes observable again on a later width reflow, so restore its
    /// source/destination pair just before that reflow.  The frozen behavior
    /// establishes this for a generation created at the physical bottom;
    /// internal-region successors remain ordinary live Line anchors.
    func reactivateKittyDisplayReflowLines(in screen: ScreenBuffer) {
        var lines = screen.lines
        var changed = false
        for transfer in kittyDisplayReflowImageTransfers
        where transfer.successor == nil {
            if !lines.contains(where: { $0 === transfer.destination }) {
                lines.append(transfer.destination)
                changed = true
            }
            if !lines.contains(where: { $0 === transfer.source }) {
                lines.append(transfer.source)
                changed = true
            }
        }
        if changed { screen.replaceLines(lines) }
    }

    struct SuspendedKittyDisplayReflowImage {
        let image: LineImage
        let line: Line
    }

    /// A placement that already performed terminal-owned row motion must not
    /// make its old Line object extend the text buffer during a later resize.
    /// Remove only these tracked placement markers while sizing; callers put
    /// surviving images back on the mapped Line after the cell topology is
    /// settled.
    func suspendKittyDisplayReflowImages(
        in screen: ScreenBuffer,
        materializingTransfers: Bool
    ) -> [SuspendedKittyDisplayReflowImage] {
        if materializingTransfers {
            materializeKittyDisplayReflowImageTransfers(in: screen)
        }
        var suspended: [SuspendedKittyDisplayReflowImage] = []
        for image in kittyDisplayReflowImages {
            guard let line = screen.lines.first(where: { line in
                line.images?.contains(where: { $0 === image }) == true
            }) else { continue }
            let retained = line.images?.filter { $0 !== image }
            line.images = retained?.isEmpty == false ? retained : nil
            suspended.append(
                SuspendedKittyDisplayReflowImage(image: image, line: line))
        }
        return suspended
    }

    func restoreKittyDisplayReflowImages(
        _ suspended: [SuspendedKittyDisplayReflowImage],
        toSurvivingLinesIn screen: ScreenBuffer
    ) {
        for entry in suspended {
            if entry.line.images?.contains(where: {
                $0 === entry.image
            }) != true {
                entry.line.images = (entry.line.images ?? []) + [entry.image]
            }
        }
    }

    func pruneKittyDisplayReflowImages() {
        let screens = [normalBuffer, altBuffer]
        kittyDisplayReflowImages.removeAll { image in
            if kittyDisplayReflowImageTransfers.contains(where: {
                $0.image === image
            }) {
                return false
            }
            return !screens.contains { screen in
                screen.lines.contains { line in
                    line.images?.contains(where: { $0 === image }) == true
                }
            }
        }
        kittyDisplayReflowImageTransfers.removeAll { transfer in
            !kittyDisplayReflowImages.contains(where: {
                $0 === transfer.image
            })
        }
    }

    // MARK: - Printing (mirrors the reference engine exactly: the wrap-
    // pending state IS x == cols; wide stubs carry the constant (D,I)
    // attribute; overwriting half a wide char leaves the orphan in place)

    /// The scalar REP (CSI b) repeats.
    var lastPrintedScalar: UnicodeScalar?

    /// The last cell written (absolute row, x, and the geometry it was
    /// written under) — the combining/emoji merge target.
    var lastWrite: (row: Int, x: Int, cols: Int, rows: Int) = (0, 0, -1, -1)

    /// DECAWM-off can leave the cursor parked just beyond a stored right edge
    /// after printing. DECFI can also consume a real pending wrap while
    /// leaving that same physical one-past coordinate in place. Both differ
    /// from explicitly moving a settled cursor to the same column.
    var noWrapParkedAfterPrint = false

    /// CUU preserves wrap-pending.  When it actually moves that pending
    /// cursor upward, the next ordinary base may wrap forward again, but that
    /// landed base owns its cell and is not eligible for VS16 relocation. The
    /// same rule applies to a physical-edge cursor parked by DECAWM-off.
    var pendingCursorUpMoved = false

    /// A relative horizontal command that actually advances the cursor keeps
    /// the last-written grapheme as the variation-selector owner.  If VS16
    /// subsequently widens that owner, the cursor keeps its relative offset
    /// by advancing one more physical column.  The witness records historical
    /// progress: later reverse motion changes the current owner-relative
    /// offset, and a clamped/no-op command leaves the earlier progress intact.
    private var selectorOwnerAdvancedByRelativeMotion = false

    /// Absolute positioning can return the visible cursor to the row before
    /// a base that wrapped through an active margin. The base still owns a
    /// later selector; if it relocates back to that row, its expanded width
    /// advances the saved logical cursor offset too.
    private var selectorRelocationTracksWidthChange = false

    /// A real relative move can settle the cursor on the physical right edge
    /// before VS16 widens an earlier cell. The resulting pending wrap is a
    /// settled continuation point: the next printable may wrap, but its own
    /// selector must not relocate it back into the vacated edge cell.
    private var selectorExpansionSettledPhysicalPending:
        (row: Int, cols: Int, rows: Int)?

    /// A narrow-margin print can begin at a settled physical column to the
    /// right of the stored margin and wrap into the margin on the next row.
    /// A following VS16 expands that new-row cluster in place; it must not use
    /// the older relocation rule that returns ordinary wrapped clusters to a
    /// blank cell on the preceding row.
    private var lastPrintWrappedFromRightOfMargin = false

    /// Relocation of a later VS16 is only available when the base scalar
    /// itself advanced onto a fresh wrapped row.  A row may already be marked
    /// wrapped because of older content; printing a new base there must not
    /// inherit that older wrap transition.
    private var lastPrintAdvancedToFreshRow = false

    /// A pending wrap remembers the actual Line and lead cell that armed the
    /// exclusive-right cursor. Row and slice edits may move or clip that owner
    /// while leaving the public pending coordinate unchanged. The next base
    /// may still wrap normally, but its selector must not relocate through the
    /// stale pre-edit departure cell.
    private struct PendingWrapOwnerWitness {
        let line: Line
        let leadColumn: Int
        let scalar: UInt32
        let width: Int8
        let clusterExtras: [UInt32]?
        let cols: Int
        let rows: Int
    }
    private var pendingWrapOwnerWitness: PendingWrapOwnerWitness?

    /// The most recent base advanced from a pending owner that still occupied
    /// the departure Line and lead coordinate when wrapping began. Width-only
    /// overflow wraps do not need a historical owner and set this normally.
    private var lastPrintAdvancedFromCurrentPendingOwner = false

    /// Rectangular scrolling at a configured vertical-region bottom exposes
    /// only a horizontal slice of that row.  Each exposed row remains a hard
    /// logical boundary for a later full-buffer reflow even after more
    /// printing, cursor movement, erasure, styling, or margin-mode changes.
    /// Retaining the row object makes every witness follow its storage
    /// identity without coupling it to the transient cursor or last-write
    /// state.
    struct ActiveMarginReflowBoundary {
        let line: Line
    }
    var activeMarginReflowBoundaries: [ActiveMarginReflowBoundary] = []

    struct KittyDisplayReflowClaim {
        let line: Line
    }
    var kittyDisplayReflowClaims: [KittyDisplayReflowClaim] = []
    struct KittyDisplayReflowBoundary {
        let line: Line
    }
    var kittyDisplayReflowBoundaries: [KittyDisplayReflowBoundary] = []
    struct KittyDisplayClippedTopReflowRank {
        let line: Line
    }
    var kittyDisplayClippedTopReflowRanks: [
        KittyDisplayClippedTopReflowRank
    ] = []
    struct KittyDisplayReflowImageTransfer {
        let image: LineImage
        let source: Line
        let destination: Line
        let successor: Line?
    }
    var kittyDisplayReflowImages: [LineImage] = []
    var kittyDisplayReflowImageTransfers: [KittyDisplayReflowImageTransfer] = []

    private struct DisplacedCell {
        let row: Int
        let column: Int
        let cols: Int
        let rows: Int
        let cell: Cell
    }

    private enum BackwardColumnAttachmentWitnessPhase {
        case activeShift
        case dormantCoordinate
        case dormantAfterShift
    }

    private struct BackwardColumnAttachmentWitness {
        let row: Int
        let column: Int
        let cols: Int
        let rows: Int
        let scalar: UnicodeScalar
        let isAlternateBuffer: Bool
        let phase: BackwardColumnAttachmentWitnessPhase
    }

    /// DECBI preserves the logical attachment coordinate of a valid prior
    /// printable while boundary insertions move cells away from it. ICH can
    /// leave the coordinate dormant after clipping its owner. A later DECBI
    /// reactivates either witness when a real lead cell reaches the coordinate.
    private var normalBackwardColumnAttachmentWitness:
        BackwardColumnAttachmentWitness?
    private var alternateBackwardColumnAttachmentWitness:
        BackwardColumnAttachmentWitness?
    private var backwardColumnAttachmentWitness:
        BackwardColumnAttachmentWitness? {
        get {
            isAlternateBuffer
                ? alternateBackwardColumnAttachmentWitness
                : normalBackwardColumnAttachmentWitness
        }
        set {
            if isAlternateBuffer {
                alternateBackwardColumnAttachmentWitness = newValue
            } else {
                normalBackwardColumnAttachmentWitness = newValue
            }
        }
    }

    func clearBackwardColumnAttachmentWitness() {
        normalBackwardColumnAttachmentWitness = nil
        alternateBackwardColumnAttachmentWitness = nil
    }

    /// The cell replaced by `lastWrite`, retained only long enough for a
    /// variation-selector relocation to restore the source coordinate.
    private var lastWriteDisplacedCell: DisplacedCell?

    /// The constant attribute wide-char stubs and insert-mode fills carry.
    static let stubAttribute = CellAttribute(fg: .defaultColor, bg: .defaultInverted)

    private enum ScalarClusterRole {
        case ordinary
        case zeroWidth
        case joiner
        case textVariation
        case emojiVariation
        case variation
        case regionalIndicator
    }

    /// Presentation selectors have a narrower lifetime than grapheme
    /// attachment itself. Combining marks and joiners can keep accepting
    /// grapheme content while suspending selector authority; a completed
    /// eligible ZWJ sequence can restore it. A consumed selector is blocked
    /// until such a sequence completes. At the physical no-wrap edge, a
    /// rejected intrinsically-wide scalar is state-neutral for a validated
    /// presentation-bearing owner; other rejected-wide paths retain their
    /// narrower restoration rules.
    private enum PresentationSelectorAuthority {
        case unavailable
        case available
        case suspended
        case blocked
    }

    private var presentationSelectorAuthority:
        PresentationSelectorAuthority = .unavailable

    /// A physical-edge no-wrap rejection is publicly inert. This witness
    /// distinguishes a later repeated rejection after exactly one joiner from
    /// a cluster that was already incomplete before its first rejection.
    private struct RejectedWidePresentationOwnerWitness {
        let line: Line
        let leadColumn: Int
        let cell: Cell
        let cols: Int
        let rows: Int
        let isAlternateBuffer: Bool
    }
    private var rejectedWidePresentationOwnerWitness:
        RejectedWidePresentationOwnerWitness?

    private struct LastCluster {
        let row: Int
        let leadColumn: Int
        let cell: Cell
        let line: Line
        let cursorFollowsLead: Bool
    }

    private struct ReverseIndexOwnerRefresh {
        let absoluteRow: Int
        let leadColumn: Int
        let line: Line
        let scalar: UInt32
        let width: Int8
        let clusterExtras: [UInt32]?
        let selectorAuthority: PresentationSelectorAuthority
        let selectorOwnerAdvancedByRelativeMotion: Bool
        let selectorRelocationTracksWidthChange: Bool
        let activationSerial: UInt64
        let cols: Int
        let rows: Int
        let isAlternateBuffer: Bool
    }
    private struct ReverseIndexBufferDepartureOwner {
        let absoluteRow: Int
        let leadColumn: Int
        let activationSerial: UInt64
        let cols: Int
        let rows: Int
        let isAlternateBuffer: Bool
    }
    private var bufferActivationSerial: UInt64 = 0
    private var reverseIndexBufferDepartureOwner:
        ReverseIndexBufferDepartureOwner?
    private var normalReverseIndexOwnerRefreshWitness:
        ReverseIndexOwnerRefresh?
    private var alternateReverseIndexOwnerRefreshWitness:
        ReverseIndexOwnerRefresh?
    private var reverseIndexOwnerRefreshWitness: ReverseIndexOwnerRefresh? {
        get {
            isAlternateBuffer
                ? alternateReverseIndexOwnerRefreshWitness
                : normalReverseIndexOwnerRefreshWitness
        }
        set {
            if isAlternateBuffer {
                alternateReverseIndexOwnerRefreshWitness = newValue
            } else {
                normalReverseIndexOwnerRefreshWitness = newValue
            }
        }
    }

    /// IL can move the current owner out of its saved coordinate while
    /// leaving a blank there. Unlike RI restoration, a zero-width follower
    /// alone cannot revive it: an upward row rotation must first bring a real
    /// lead back into the coordinate. Keep this separate from the RI witness
    /// so unrelated DECFI/RI activity cannot make the dormant owner current.
    private struct InsertLineOwnerRefresh {
        let absoluteRow: Int
        let leadColumn: Int
        let cell: Cell
        let cols: Int
        let rows: Int
        let isAlternateBuffer: Bool
    }
    private var normalInsertLineOwnerRefreshWitness:
        InsertLineOwnerRefresh?
    private var alternateInsertLineOwnerRefreshWitness:
        InsertLineOwnerRefresh?
    private var insertLineOwnerRefreshWitness: InsertLineOwnerRefresh? {
        get {
            isAlternateBuffer
                ? alternateInsertLineOwnerRefreshWitness
                : normalInsertLineOwnerRefreshWitness
        }
        set {
            if isAlternateBuffer {
                alternateInsertLineOwnerRefreshWitness = newValue
            } else {
                normalInsertLineOwnerRefreshWitness = newValue
            }
        }
    }

    func clearActiveReverseIndexOwnerRefreshWitness() {
        reverseIndexOwnerRefreshWitness = nil
        reverseIndexBufferDepartureOwner = nil
        insertLineOwnerRefreshWitness = nil
    }

    private func reverseIndexOwnerRefreshIsDisplaced() -> Bool {
        let buf = buffer
        // A one-row RI rectangle recycles and clears the only Line; there is
        // no displaced generation that can return after a later upward
        // scroll, even if a replacement happens to use the same scalar.
        guard buf.scrollTop < buf.scrollBottom else { return false }
        guard let refresh = reverseIndexOwnerRefreshWitness,
              refresh.activationSerial == bufferActivationSerial,
              refresh.cols == buf.cols,
              refresh.rows == buf.rows,
              refresh.isAlternateBuffer == isAlternateBuffer,
              let line = buf.line(absolute: refresh.absoluteRow),
              refresh.leadColumn >= 0,
              refresh.leadColumn < line.count else {
            return false
        }
        let cell = line[refresh.leadColumn]
        return cell.scalar != refresh.scalar ||
            cell.width != refresh.width ||
            cell.clusterExtras != refresh.clusterExtras
    }

    private func finishPrintReverseIndexOwnerRefresh(
        preservingDisplacedOwner: Bool,
        printedOwnerRow: Int,
        printedOwnerColumn: Int
    ) {
        insertLineOwnerRefreshWitness = nil
        reverseIndexBufferDepartureOwner = nil
        // Preserve the historical owner only while it is still displaced.
        // A temporary replacement at that exact coordinate may disappear and
        // reveal the historical owner again. A successful base elsewhere is
        // instead authoritative even while the old Line remains displaced.
        // A print can also advance/scroll the grid and return that Line to the
        // saved coordinate; once that happens, the old witness is consumed.
        let printedAtRefreshCoordinate =
            reverseIndexOwnerRefreshWitness.map { refresh in
                printedOwnerRow == refresh.absoluteRow &&
                    printedOwnerColumn == refresh.leadColumn
            } ?? false
        if !preservingDisplacedOwner ||
           !printedAtRefreshCoordinate ||
           !reverseIndexOwnerRefreshIsDisplaced() {
            reverseIndexOwnerRefreshWitness = nil
        }
    }

    func clearReverseIndexOwnerRefreshWitnesses() {
        normalReverseIndexOwnerRefreshWitness = nil
        alternateReverseIndexOwnerRefreshWitness = nil
        reverseIndexBufferDepartureOwner = nil
        normalInsertLineOwnerRefreshWitness = nil
        alternateInsertLineOwnerRefreshWitness = nil
    }

    private func reverseIndexOwnerRefreshSnapshot(
        absoluteRow: Int,
        leadColumn: Int,
        line: Line,
        cell: Cell,
        selectorAuthority: PresentationSelectorAuthority,
        selectorOwnerAdvancedByRelativeMotion: Bool,
        selectorRelocationTracksWidthChange: Bool
    ) -> ReverseIndexOwnerRefresh {
        let buf = buffer
        return ReverseIndexOwnerRefresh(
            absoluteRow: absoluteRow,
            leadColumn: leadColumn,
            line: line,
            scalar: cell.scalar,
            width: cell.width,
            clusterExtras: cell.clusterExtras,
            selectorAuthority: selectorAuthority,
            selectorOwnerAdvancedByRelativeMotion:
                selectorOwnerAdvancedByRelativeMotion,
            selectorRelocationTracksWidthChange:
                selectorRelocationTracksWidthChange,
            activationSerial: bufferActivationSerial,
            cols: buf.cols,
            rows: buf.rows,
            isAlternateBuffer: isAlternateBuffer)
    }

    private func rebaseActiveReverseIndexOwnerRefreshWitness(
        allowCrossActivation: Bool = false,
        allowCoordinateChange: Bool = false
    ) {
        let buf = buffer
        guard let refresh = reverseIndexOwnerRefreshWitness,
              allowCrossActivation ||
                refresh.activationSerial == bufferActivationSerial,
              refresh.cols == buf.cols,
              refresh.rows == buf.rows,
              refresh.isAlternateBuffer == isAlternateBuffer,
              let cluster = validatedLastCluster() else { return }
        if !allowCoordinateChange,
           (lastWrite.row != refresh.absoluteRow ||
            cluster.leadColumn != refresh.leadColumn) {
            return
        }
        reverseIndexOwnerRefreshWitness = reverseIndexOwnerRefreshSnapshot(
            absoluteRow: lastWrite.row,
            leadColumn: cluster.leadColumn,
            line: cluster.line,
            cell: cluster.cell,
            selectorAuthority: presentationSelectorAuthority,
            selectorOwnerAdvancedByRelativeMotion:
                selectorOwnerAdvancedByRelativeMotion,
            selectorRelocationTracksWidthChange:
                selectorRelocationTracksWidthChange)
    }

    private func captureReverseIndexBufferDeparture() {
        // A line rotation can move the retained owner before the screen is
        // deactivated. Ordinary prints clear this witness, so while it is
        // still live the validated global cluster is the authoritative
        // departure coordinate even when it differs from the original one.
        rebaseActiveReverseIndexOwnerRefreshWitness(
            allowCoordinateChange: true)
        let buf = buffer
        guard let cluster = validatedLastCluster(),
              cluster.cell.scalar != 0 else {
            reverseIndexBufferDepartureOwner = nil
            return
        }
        reverseIndexBufferDepartureOwner = ReverseIndexBufferDepartureOwner(
            absoluteRow: buf.yBase + cluster.row,
            leadColumn: cluster.leadColumn,
            activationSerial: bufferActivationSerial,
            cols: buf.cols,
            rows: buf.rows,
            isAlternateBuffer: isAlternateBuffer)
    }

    func printScalar(_ scalar: UnicodeScalar) {
        let width = UnicodeUtil.columnWidth(rune: scalar)
        guard width >= 0 else {
            invalidateClusterContinuation()
            return
        }

        let role = Self.clusterRole(for: scalar, configuredWidth: width)
        let restoredReverseIndexOwner = role != .ordinary &&
            restoreReverseIndexOwnerRefreshWitnessForFollower()
        if role != .ordinary,
           appendToLastCluster(scalar, role: role, configuredWidth: width) {
            rebaseActiveReverseIndexOwnerRefreshWitness()
            return
        }
        if role == .emojiVariation {
            return
        }
        if role == .ordinary,
           appendOrdinaryAfterJoiner(scalar, configuredWidth: width) {
            rebaseActiveReverseIndexOwnerRefreshWitness()
            return
        }

        guard width > 0 else {
            invalidateClusterContinuation(
                preservingDormantBackwardColumnAttachmentWitness: true)
            return
        }
        if restoredReverseIndexOwner {
            // An incompatible positive-width follower starts a new cluster;
            // it must not leave the restored RI owner available to intercept
            // the next scalar in that new cluster.
            clearActiveReverseIndexOwnerRefreshWitness()
        }
        insertPrintedCell(scalar, width: min(2, width))
    }

    private static func clusterRole(
        for scalar: UnicodeScalar,
        configuredWidth: Int
    ) -> ScalarClusterRole {
        switch scalar.value {
        case 0x200D:
            return .joiner
        case 0xFE0E:
            return .textVariation
        case 0xFE0F:
            return .emojiVariation
        case 0xE0100...0xE01EF:
            return .variation
        default:
            if UnicodeUtil.isRegionalIndicator(scalar) {
                return .regionalIndicator
            }
            return configuredWidth == 0 ? .zeroWidth : .ordinary
        }
    }

    private static func isEmojiZWJComponent(_ scalar: UnicodeScalar) -> Bool {
        guard scalar.properties.isEmoji else { return false }
        switch scalar.value {
        case 0x23, 0x2A, 0x30...0x39:
            return false
        default:
            return true
        }
    }

    private func appendOrdinaryAfterJoiner(
        _ scalar: UnicodeScalar,
        configuredWidth: Int
    ) -> Bool {
        guard let cluster = validatedLastCluster(),
              let extras = cluster.cell.clusterExtras,
              extras.last == 0x200D,
              extras.dropLast().last != 0x200D,
              Self.isEmojiZWJComponent(scalar),
              let lead = UnicodeScalar(cluster.cell.scalar),
              !UnicodeUtil.isRegionalIndicator(lead),
              !extras.contains(0x20E3),
              Self.isEmojiZWJComponent(lead) else {
            return false
        }
        let canRestoreSelectorAuthority =
            presentationSelectorAuthority == .suspended ||
            presentationSelectorAuthority == .blocked ||
            presentationSelectorAuthority == .unavailable
        let restoresSelectorAuthority =
            canRestoreSelectorAuthority &&
            UnicodeUtil.isEmojiVs16Base(rune: scalar)
        let appended = append(
            scalar, to: cluster,
            requestedWidth: Int(cluster.cell.width))
        if appended, restoresSelectorAuthority {
            presentationSelectorAuthority = .available
        }
        return appended
    }

    private func appendToLastCluster(
        _ scalar: UnicodeScalar,
        role: ScalarClusterRole,
        configuredWidth: Int
    ) -> Bool {
        guard let cluster = validatedLastCluster() else { return false }

        switch role {
        case .regionalIndicator:
            let extras = cluster.cell.clusterExtras ?? []
            guard UnicodeUtil.isRegionalIndicator(
                UnicodeScalar(cluster.cell.scalar) ?? UnicodeScalar(0)!),
                !extras.contains(0x200D)
            else { return false }
            let alreadyPaired = extras.contains { value in
                guard let scalar = UnicodeScalar(value) else { return false }
                return UnicodeUtil.isRegionalIndicator(scalar)
            }
            guard !alreadyPaired else { return false }
            return append(scalar, to: cluster, requestedWidth: 2)

        case .emojiVariation:
            guard presentationSelectorAuthority == .available else {
                return true
            }
            guard let lead = UnicodeScalar(cluster.cell.scalar) else { return false }
            guard lead.properties.isEmoji else { return false }
            if Self.hasTrailingPresentationSelector(cluster.cell) {
                presentationSelectorAuthority = .blocked
                return true
            }
            let expandsTextPresentation = UnicodeUtil.isEmojiVs16Base(rune: lead)
            guard expandsTextPresentation || cluster.cell.width == 2 else { return false }
            if cluster.cell.width == 2,
               !expandsTextPresentation,
               !Self.hasCompletedZWJSequence(cluster.cell) {
                // Fixed-width emoji and regional-indicator clusters already
                // have their presentation width.  A bare selector is consumed
                // without becoming part of that cluster; completed ZWJ emoji
                // remain selector-sensitive.
                presentationSelectorAuthority = .blocked
                return true
            }
            let cursorRemainsBeyondOwner =
                cluster.row == buffer.y &&
                buffer.x > cluster.leadColumn + Int(cluster.cell.width)
            let followsRelativeMotion = expandsTextPresentation &&
                selectorOwnerAdvancedByRelativeMotion &&
                cursorRemainsBeyondOwner
            let sameRowStrictlyLeft =
                cluster.row == buffer.y &&
                buffer.x < cluster.leadColumn
            let verticallyRelocated = cluster.row != buffer.y
            let repositionedStrictlyLeft = expandsTextPresentation &&
                selectorRelocationTracksWidthChange &&
                sameRowStrictlyLeft
            let relocationTracksWidthChange = expandsTextPresentation &&
                selectorRelocationTracksWidthChange &&
                (lastPrintAdvancedToFreshRow || sameRowStrictlyLeft ||
                    verticallyRelocated || cursorRemainsBeyondOwner)
            selectorOwnerAdvancedByRelativeMotion = false
            selectorRelocationTracksWidthChange = false
            if repositionedStrictlyLeft {
                // The selector still updates the captured glyph, but the
                // cursor now owns a distinct logical position. Drop saved
                // continuation ownership before applying the width change so
                // later followers cannot revive the glyph behind the cursor.
                invalidateClusterContinuation()
            }
            if expandsTextPresentation,
               !repositionedStrictlyLeft,
               relocateVS16ClusterToBlankPendingDestination(
                scalar, cluster: cluster,
                cursorTracksWidthChange: relocationTracksWidthChange) {
                presentationSelectorAuthority = .blocked
                return true
            }
            let width = expandsTextPresentation ? 2 : Int(cluster.cell.width)
            let settledAtLead = expandsTextPresentation &&
                cluster.cell.width == 1 &&
                cluster.row == buffer.y &&
                buffer.x == cluster.leadColumn &&
                cluster.leadColumn < buffer.cols - 1
            let selectorStartedAtPhysicalRight =
                cluster.row == buffer.y &&
                buffer.x == buffer.cols - 1 &&
                !buffer.wrapPending
            let appended = append(
                scalar, to: cluster, requestedWidth: width,
                cursorTracksWidthChange:
                    followsRelativeMotion || relocationTracksWidthChange ||
                    repositionedStrictlyLeft)
            if appended, settledAtLead {
                buffer.x += 1
                buffer.wrapPending =
                    buffer.x > printingColumns(for: cluster.leadColumn).upperBound
            }
            if appended,
               cluster.cell.width == 1,
               followsRelativeMotion,
               selectorStartedAtPhysicalRight,
               autoWrap {
                let geometry = printingColumns(for: cluster.leadColumn)
                if geometry.upperBound == buffer.cols - 1,
                   buffer.x == buffer.cols,
                   buffer.wrapPending {
                    selectorExpansionSettledPhysicalPending = (
                        row: buffer.yBase + buffer.y,
                        cols: buffer.cols,
                        rows: buffer.rows)
                }
            }
            if appended {
                presentationSelectorAuthority = .blocked
            }
            return appended

        case .textVariation:
            guard presentationSelectorAuthority == .available else {
                return true
            }
            guard let lead = UnicodeScalar(cluster.cell.scalar),
                  lead.properties.isEmoji else { return false }
            if Self.hasTrailingPresentationSelector(cluster.cell) {
                presentationSelectorAuthority = .blocked
                return true
            }
            if cluster.cell.width == 2,
               !Self.hasCompletedZWJSequence(cluster.cell),
               !UnicodeUtil.isEmojiVs16Base(rune: lead) {
                presentationSelectorAuthority = .blocked
                return true
            }
            let appended = append(scalar, to: cluster, requestedWidth: 1)
            if appended {
                presentationSelectorAuthority = .blocked
            }
            return appended

        case .joiner, .variation, .zeroWidth:
            let appended = append(
                scalar, to: cluster,
                requestedWidth: max(1, Int(cluster.cell.width)))
            if appended, presentationSelectorAuthority == .available {
                presentationSelectorAuthority = .suspended
            }
            return appended

        case .ordinary:
            return false
        }
    }

    private static func hasCompletedZWJSequence(_ cell: Cell) -> Bool {
        let extras = cell.clusterExtras ?? []
        return extras.lastIndex(of: 0x200D)
            .map { $0 < extras.count - 1 } ?? false
    }

    private static func hasTrailingPresentationSelector(_ cell: Cell) -> Bool {
        guard let value = cell.clusterExtras?.last else { return false }
        return value == 0xFE0E || value == 0xFE0F
    }

    private static func selectorAuthority(
        for cell: Cell
    ) -> PresentationSelectorAuthority {
        let extras = cell.clusterExtras ?? []
        if extras.isEmpty {
            return .available
        }
        if extras.last == 0xFE0E || extras.last == 0xFE0F {
            return .blocked
        }
        if hasCompletedZWJSequence(cell) {
            if let last = extras.last.flatMap({ UnicodeScalar($0) }),
               UnicodeUtil.isEmojiVs16Base(rune: last) {
                return .available
            }
        }
        return .suspended
    }

    private func relocateVS16ClusterToBlankPendingDestination(
        _ scalar: UnicodeScalar,
        cluster: LastCluster,
        cursorTracksWidthChange: Bool
    ) -> Bool {
        let buf = buffer
        let geometry = printingColumns(for: cluster.leadColumn)
        let sourceAbsoluteRow = buf.yBase + cluster.row
        let overwroteWideLead = lastWriteDisplacedCell.map { displaced in
            displaced.row == sourceAbsoluteRow &&
                displaced.column == cluster.leadColumn &&
                displaced.cols == buf.cols &&
                displaced.rows == buf.rows &&
                displaced.cell.width == 2
        } ?? false
        let nextPhysicalColumn = cluster.leadColumn + 1
        let expansionIntersectsWideCell =
            nextPhysicalColumn < buf.cols &&
            cluster.line[nextPhysicalColumn].width != 1
        guard !lastPrintWrappedFromRightOfMargin,
              lastPrintAdvancedToFreshRow,
              lastPrintAdvancedFromCurrentPendingOwner,
              !overwroteWideLead,
              !expansionIntersectsWideCell,
              cluster.cell.width == 1,
              cluster.leadColumn == geometry.lowerBound,
              cluster.row > 0,
              cluster.cursorFollowsLead,
              cluster.line.isWrapped else { return false }

        let destination = buf.liveLine(cluster.row - 1)
        let destinationColumn = geometry.upperBound
        let destinationCell = destination[destinationColumn]
        guard destinationCell.scalar == 0,
              destinationCell.clusterExtras == nil,
              destinationCell.width == 1,
              destinationCell.linkId == 0 else { return false }

        var relocated = cluster.cell
        var extras = relocated.clusterExtras ?? []
        extras.append(scalar.value)
        relocated.clusterExtras = extras
        relocated.width = 1

        destination[destinationColumn] = relocated
        if let displaced = lastWriteDisplacedCell,
           displaced.row == sourceAbsoluteRow,
           displaced.column == cluster.leadColumn,
           displaced.cols == buf.cols,
           displaced.rows == buf.rows {
            cluster.line[cluster.leadColumn] = displaced.cell
        } else {
            cluster.line[cluster.leadColumn] = Cell.blank(attribute: cluster.cell.attribute)
        }
        cluster.line.isWrapped = false
        buf.y = cluster.row - 1
        buf.x = destinationColumn + 1 + (cursorTracksWidthChange ? 1 : 0)
        buf.wrapPending = true
        lastWrite = (
            row: buf.yBase + buf.y, x: destinationColumn,
            cols: buf.cols, rows: buf.rows)
        lastWriteDisplacedCell = nil
        refreshPendingWrapOwnerWitness(
            line: destination,
            leadColumn: destinationColumn)
        markDirty(absoluteRow: buf.yBase + cluster.row)
        markDirty(absoluteRow: buf.yBase + buf.y)
        return true
    }

    private func validatedLastCluster() -> LastCluster? {
        let buf = buffer
        guard lastWrite.rows == buf.rows,
              lastWrite.cols == buf.cols,
              lastWrite.x >= 0,
              lastWrite.x < buf.cols,
              let expectedScalar = lastPrintedScalar,
              let line = buf.line(absolute: lastWrite.row) else {
            return nil
        }

        var lead = lastWrite.x
        while lead > 0, line[lead].width == 0 {
            lead -= 1
        }
        let cell = line[lead]
        guard cell.width > 0,
              cell.scalar == expectedScalar.value else {
            return nil
        }
        return LastCluster(
            row: lastWrite.row - buf.yBase,
            leadColumn: lead, cell: cell, line: line,
            cursorFollowsLead: lastWrite.row == buf.yBase + buf.y
                && buf.x == lead + Int(cell.width))
    }

    private func refreshPendingWrapOwnerWitness(
        line: Line,
        leadColumn: Int
    ) {
        let buf = buffer
        guard buf.wrapPending,
              leadColumn >= 0,
              leadColumn < buf.cols,
              line === buf.liveLine(buf.y) else {
            pendingWrapOwnerWitness = nil
            return
        }
        let cell = line[leadColumn]
        let geometry = printingColumns(for: leadColumn)
        guard cell.scalar != 0,
              cell.width > 0,
              buf.x > geometry.upperBound else {
            pendingWrapOwnerWitness = nil
            return
        }
        pendingWrapOwnerWitness = PendingWrapOwnerWitness(
            line: line,
            leadColumn: leadColumn,
            scalar: cell.scalar,
            width: cell.width,
            clusterExtras: cell.clusterExtras,
            cols: buf.cols,
            rows: buf.rows)
    }

    private func refreshPendingWrapOwnerWitnessFromLastCluster() {
        guard let cluster = validatedLastCluster() else {
            pendingWrapOwnerWitness = nil
            return
        }
        refreshPendingWrapOwnerWitness(
            line: cluster.line,
            leadColumn: cluster.leadColumn)
    }

    private func pendingWrapOwnerStillOccupiesDeparture() -> Bool {
        let buf = buffer
        let geometry = printingColumns(for: buf.x)
        guard buf.wrapPending,
              let witness = pendingWrapOwnerWitness,
              witness.cols == buf.cols,
              witness.rows == buf.rows,
              witness.leadColumn >= 0,
              witness.leadColumn < buf.cols,
              geometry.contains(witness.leadColumn),
              witness.line === buf.liveLine(buf.y) else {
            return false
        }
        let cell = witness.line[witness.leadColumn]
        return cell.scalar == witness.scalar &&
            cell.width == witness.width &&
            cell.clusterExtras == witness.clusterExtras
    }

    private func append(
        _ scalar: UnicodeScalar,
        to cluster: LastCluster,
        requestedWidth: Int,
        cursorTracksWidthChange: Bool = false
    ) -> Bool {
        var cell = cluster.cell
        var extras = cell.clusterExtras ?? []
        extras.append(scalar.value)
        cell.clusterExtras = extras

        let geometry = printingColumns(for: cluster.leadColumn)
        let physicalColumns = 0...(buffer.cols - 1)
        let targetWidth = min(2, max(1, requestedWidth))
        let oldWidth = Int(cell.width)
        var appliedWidth = oldWidth
        if targetWidth == 2, cluster.leadColumn < physicalColumns.upperBound {
            appliedWidth = 2
        } else if targetWidth == 1 {
            appliedWidth = 1
        }
        cell.width = Int8(appliedWidth)
        cluster.line[cluster.leadColumn] = cell

        if appliedWidth > oldWidth {
            clearGlyphIntersecting(
                column: cluster.leadColumn + 1, in: cluster.line,
                bounds: physicalColumns)
            cluster.line[cluster.leadColumn + 1] = Cell(
                scalar: 0, width: 0,
                attribute: cell.attribute, linkId: cell.linkId)
        }
        // Presentation-width shrink changes the lead cell's logical width
        // without rewriting the already materialized continuation.  That
        // continuation remains a zero-width stub for both direct eligible
        // emoji and completed joined clusters.

        let delta = appliedWidth - oldWidth
        if delta != 0,
           cluster.cursorFollowsLead || cursorTracksWidthChange {
            buffer.x += delta
            buffer.wrapPending = buffer.x > geometry.upperBound
        } else if delta < 0,
                  buffer.wrapPending,
                  cluster.row == buffer.y,
                  geometry.lowerBound == geometry.upperBound,
                  geometry.upperBound == physicalColumns.upperBound,
                  cluster.leadColumn == geometry.lowerBound,
                  buffer.x == geometry.upperBound + 1 {
            // A wide cluster printed through a one-column range at the
            // physical right edge has only its lead materialized.  If a
            // selector later shrinks it, the cursor returns to that physical
            // cell instead of keeping the clipped wide-cell pending column.
            buffer.x = geometry.upperBound
            buffer.wrapPending = false
        }
        refreshPendingWrapOwnerWitness(
            line: cluster.line,
            leadColumn: cluster.leadColumn)
        markDirty(absoluteRow: buffer.yBase + cluster.row)
        return true
    }

    private func insertPrintedCell(_ scalar: UnicodeScalar, width: Int) {
        let cell = Cell(
            scalar: scalar.value, width: Int8(width),
            attribute: currentAttribute, linkId: activeLinkId)
        insertCellDirect(cell)
    }

    private func invalidateClusterContinuation(
        preservingDormantBackwardColumnAttachmentWitness: Bool = false
    ) {
        let dormantBackwardWitness =
            preservingDormantBackwardColumnAttachmentWitness &&
            backwardColumnAttachmentWitness?.phase != .activeShift
                ? backwardColumnAttachmentWitness
                : nil
        lastPrintedScalar = nil
        presentationSelectorAuthority = .unavailable
        lastWriteDisplacedCell = nil
        backwardColumnAttachmentWitness = dormantBackwardWitness
        lastPrintWrappedFromRightOfMargin = false
        lastPrintAdvancedToFreshRow = false
        lastPrintAdvancedFromCurrentPendingOwner = false
        selectorOwnerAdvancedByRelativeMotion = false
        selectorRelocationTracksWidthChange = false
        selectorExpansionSettledPhysicalPending = nil
        if !buffer.wrapPending {
            pendingWrapOwnerWitness = nil
        }
    }

    func recordSelectorOwnerRelativeForwardMotion(from oldX: Int) {
        guard validatedLastCluster() != nil else {
            clearSelectorOwnerRelativeForwardMotion()
            return
        }
        guard buffer.x > oldX else { return }
        selectorOwnerAdvancedByRelativeMotion = true
        selectorRelocationTracksWidthChange = true
    }

    /// Reverse cursor motion composes with an earlier forward displacement.
    /// Landing back at the owner's ordinary post-write position needs no
    /// special correction (`cursorFollowsLead` handles it), while moving
    /// strictly left of the retained lead establishes the relocation witness.
    /// A boundary no-op preserves the prior history.
    func recordSelectorOwnerRelativeBackwardMotion(from oldX: Int, oldY: Int) {
        guard let cluster = validatedLastCluster() else {
            clearSelectorOwnerRelativeForwardMotion()
            return
        }
        guard buffer.x != oldX || buffer.y != oldY else { return }
        if cluster.row == buffer.y {
            if buffer.x < cluster.leadColumn {
                selectorRelocationTracksWidthChange = true
            } else if buffer.x <= cluster.leadColumn + Int(cluster.cell.width) {
                // Returning to the owner or its ordinary post-write position
                // consumes any earlier offset correction. If the cursor is
                // still farther right, keep the prior absolute/relative
                // displacement so a later width change composes with it.
                selectorRelocationTracksWidthChange = false
            }
        }
    }

    func recordSelectorOwnerAbsoluteMotion(from oldX: Int, oldY: Int) {
        // An absolute command that resolves to the current coordinate is a
        // motion no-op and cannot erase an earlier owner-relative trajectory.
        guard buffer.x != oldX || buffer.y != oldY else { return }
        selectorOwnerAdvancedByRelativeMotion = false
        guard let cluster = validatedLastCluster() else {
            selectorRelocationTracksWidthChange = false
            return
        }
        // A cursor command can land exactly on the owner's actual leading
        // cell after that owner wrapped through a stored margin.  The normal
        // settled-at-lead path already applies the width delta there; arming
        // relocation tracking as well would advance the cursor twice.
        selectorRelocationTracksWidthChange =
            cluster.row != buffer.y || cluster.leadColumn != buffer.x
    }

    /// Vertical cursor motion keeps a prior selector-sensitive owner alive.
    /// If that owner later grows, the cursor retains its logical offset by
    /// advancing through the same width delta even though it is now on a
    /// different row.  Compare absolute rows so a full-screen index scroll
    /// counts as motion while a clamped CUU/CUD/RI remains a no-op.
    func recordSelectorOwnerVerticalMotion(from oldAbsoluteRow: Int) {
        guard buffer.yBase + buffer.y != oldAbsoluteRow else { return }
        selectorOwnerAdvancedByRelativeMotion = false
        selectorRelocationTracksWidthChange =
            validatedLastCluster() != nil
    }

    func recordSelectorOwnerStrictLeftReposition(from oldX: Int, oldY: Int) {
        guard buffer.x != oldX || buffer.y != oldY else { return }
        selectorOwnerAdvancedByRelativeMotion = false
        guard let cluster = validatedLastCluster() else {
            selectorRelocationTracksWidthChange = false
            return
        }
        // CR changes only the current row's horizontal position.  When the
        // selector owner lives on a different historical row, preserve the
        // width-trajectory established by the earlier vertical motion.
        guard cluster.row == buffer.y else { return }
        guard buffer.x < cluster.leadColumn else {
            selectorRelocationTracksWidthChange = false
            return
        }
        selectorRelocationTracksWidthChange = true
    }

    func clearSelectorOwnerRelativeForwardMotion() {
        selectorOwnerAdvancedByRelativeMotion = false
        selectorRelocationTracksWidthChange = false
    }

    /// Cell deletion preserves the combining owner by absolute coordinate,
    /// not by the identity of a source cell shifted into a new column.  When
    /// the edit covers that coordinate, the post-edit occupant becomes the
    /// owner only when it is a real lead cell; an exposed blank or wide-cell
    /// continuation invalidates the continuation target.
    func preservingClusterOwnerCoordinateThroughCellEdit(
        row: Int,
        columns: ClosedRange<Int>,
        preserveBackwardAttachmentCoordinateOnInvalidation: Bool = false,
        _ edit: () -> Void
    ) {
        _ = preservingClusterOwnerCoordinateThroughCellEdit(
            rows: row...row,
            columns: columns,
            preserveBackwardAttachmentCoordinateOnInvalidation:
                preserveBackwardAttachmentCoordinateOnInvalidation,
            edit)
    }

    /// A forward column-index shift keeps the logical attachment coordinate
    /// fixed while a new cell moves into that coordinate.  Refresh the owner
    /// from the post-edit occupant across every affected row: a real lead
    /// becomes the new extender target, while an exposed blank or wide-cell
    /// continuation clears normal attachment. ICH, its inverse DCH, and
    /// repeated DECFI may opt into retaining that now-empty coordinate as a
    /// dormant shift witness.
    /// Returning whether the saved coordinate was handled lets the caller
    /// retain its older tail-cell fallback only for histories without an
    /// affected current coordinate.
    @discardableResult
    func preservingClusterOwnerCoordinateThroughCellEdit(
        rows: ClosedRange<Int>,
        columns: ClosedRange<Int>,
        refreshSelectorMotion: Bool = false,
        preserveBackwardAttachmentCoordinateOnInvalidation: Bool = false,
        preserveLineRotationOwnerOnInvalidation: Bool = false,
        refreshLineRotationOwnerAtSavedCoordinate: Bool = false,
        _ edit: () -> Void
    ) -> Bool {
        let owner = lastWrite
        let ownerVisibleRow = owner.row - buffer.yBase
        let ownerIsAffected = lastPrintedScalar != nil &&
            owner.rows == buffer.rows &&
            owner.cols == buffer.cols &&
            rows.contains(ownerVisibleRow) &&
            columns.contains(owner.x)
        let displacedLineOwnerRefresh: InsertLineOwnerRefresh?
        if preserveLineRotationOwnerOnInvalidation,
           ownerIsAffected,
           let cluster = validatedLastCluster() {
            displacedLineOwnerRefresh = InsertLineOwnerRefresh(
                absoluteRow: owner.row,
                leadColumn: cluster.leadColumn,
                cell: cluster.cell,
                cols: buffer.cols,
                rows: buffer.rows,
                isAlternateBuffer: isAlternateBuffer)
        } else {
            displacedLineOwnerRefresh = nil
        }
        let dormantLineRotationWitness: InsertLineOwnerRefresh?
        if refreshLineRotationOwnerAtSavedCoordinate,
           let witness = insertLineOwnerRefreshWitness,
           witness.cols == buffer.cols,
           witness.rows == buffer.rows,
           witness.isAlternateBuffer == isAlternateBuffer,
           rows.contains(witness.absoluteRow - buffer.yBase),
           columns.contains(witness.leadColumn) {
            dormantLineRotationWitness = witness
        } else {
            dormantLineRotationWitness = nil
        }
        let dormantRefreshWitness: BackwardColumnAttachmentWitness?
        if preserveBackwardAttachmentCoordinateOnInvalidation,
           let witness = backwardColumnAttachmentWitness,
           witness.phase != .activeShift,
           witness.cols == buffer.cols,
           witness.rows == buffer.rows,
           witness.isAlternateBuffer == isAlternateBuffer,
           rows.contains(witness.row - buffer.yBase),
           columns.contains(witness.column) {
            dormantRefreshWitness = witness
        } else {
            dormantRefreshWitness = nil
        }
        let dormantBackwardWitness: BackwardColumnAttachmentWitness?
        if preserveBackwardAttachmentCoordinateOnInvalidation,
           backwardColumnAttachmentWitness?.phase != .activeShift,
           let cluster = validatedLastCluster(),
           rows.contains(cluster.row),
           columns.contains(cluster.leadColumn),
           let scalar = lastPrintedScalar {
            dormantBackwardWitness = BackwardColumnAttachmentWitness(
                row: owner.row,
                column: cluster.leadColumn,
                cols: buffer.cols,
                rows: buffer.rows,
                scalar: scalar,
                isAlternateBuffer: isAlternateBuffer,
                phase: .dormantCoordinate)
        } else {
            dormantBackwardWitness = nil
        }

        edit()
        let refreshedOwner: (row: Int, x: Int, cols: Int, rows: Int)?
        if ownerIsAffected {
            refreshedOwner = owner
        } else if let witness = dormantRefreshWitness {
            refreshedOwner = (
                row: witness.row, x: witness.column,
                cols: witness.cols, rows: witness.rows)
        } else if let witness = dormantLineRotationWitness {
            refreshedOwner = (
                row: witness.absoluteRow, x: witness.leadColumn,
                cols: witness.cols, rows: witness.rows)
        } else {
            refreshedOwner = nil
        }
        guard let refreshedOwner else { return false }
        guard let line = buffer.line(absolute: refreshedOwner.row),
              refreshedOwner.x >= 0, refreshedOwner.x < line.count,
              line[refreshedOwner.x].width > 0,
              line[refreshedOwner.x].scalar != 0,
              let scalar = UnicodeScalar(line[refreshedOwner.x].scalar) else {
            invalidateClusterContinuation(
                preservingDormantBackwardColumnAttachmentWitness: true)
            lastWrite = (0, 0, -1, -1)
            if ownerIsAffected, let dormantBackwardWitness {
                backwardColumnAttachmentWitness = dormantBackwardWitness
            } else if let dormantRefreshWitness {
                // Repeated ICH keeps probing the same clipped owner
                // coordinate. Blank and continuation occupants leave it
                // dormant until a later shift brings in a real lead.
                backwardColumnAttachmentWitness = dormantRefreshWitness
            }
            if let displacedLineOwnerRefresh {
                // IL can move a real owner away from its saved coordinate and
                // leave a blank there. A later upward line rotation may
                // return that generation, but an unrelated follower or
                // horizontal shift cannot reactivate it on its own.
                insertLineOwnerRefreshWitness =
                    displacedLineOwnerRefresh
            }
            return true
        }

        let cell = line[refreshedOwner.x]
        insertLineOwnerRefreshWitness = nil
        let cursorAdvancedBeyondOwner =
            refreshedOwner.row == buffer.yBase + buffer.y &&
            buffer.x > refreshedOwner.x + Int(cell.width)
        backwardColumnAttachmentWitness = nil
        lastPrintedScalar = scalar
        presentationSelectorAuthority = Self.selectorAuthority(for: cell)
        lastWrite = refreshedOwner
        lastWriteDisplacedCell = nil
        lastPrintWrappedFromRightOfMargin = false
        lastPrintAdvancedToFreshRow = false
        lastPrintAdvancedFromCurrentPendingOwner = false
        if refreshSelectorMotion {
            selectorOwnerAdvancedByRelativeMotion = cursorAdvancedBeyondOwner
            selectorRelocationTracksWidthChange = cursorAdvancedBeyondOwner
        } else if dormantRefreshWitness != nil {
            // ICH can make the fixed owner coordinate dormant, and an inverse
            // DCH can later repopulate it while the cursor remains elsewhere.
            // Reconstruct the cursor's logical offset from the restored
            // coordinate so a width-changing selector composes with that
            // round trip instead of treating the cursor as owner-local.
            let cursorAbsoluteRow = buffer.yBase + buffer.y
            selectorOwnerAdvancedByRelativeMotion =
                cursorAbsoluteRow == refreshedOwner.row &&
                cursorAdvancedBeyondOwner
            selectorRelocationTracksWidthChange =
                cursorAbsoluteRow != refreshedOwner.row ||
                buffer.x < refreshedOwner.x || cursorAdvancedBeyondOwner
        }
        return true
    }

    func trackingClusterOwnerThroughBackwardColumnShift(
        rows: ClosedRange<Int>,
        columns: ClosedRange<Int>,
        _ shift: () -> Void
    ) {
        let buf = buffer
        if let witness = backwardColumnAttachmentWitness {
            let hasCurrentGeometry = witness.cols == buf.cols &&
                witness.rows == buf.rows &&
                witness.isAlternateBuffer == isAlternateBuffer &&
                columns.contains(witness.column) &&
                rows.contains(witness.row - buf.yBase)
            let stillCurrent = hasCurrentGeometry &&
                (witness.phase != .activeShift ||
                    (witness.row == lastWrite.row &&
                        witness.column == lastWrite.x &&
                        witness.scalar == lastPrintedScalar))
            if !stillCurrent {
                backwardColumnAttachmentWitness = nil
            }
        }

        if backwardColumnAttachmentWitness == nil,
           let cluster = validatedLastCluster(),
           rows.contains(cluster.row),
           columns.contains(cluster.leadColumn),
           let scalar = lastPrintedScalar {
            backwardColumnAttachmentWitness = BackwardColumnAttachmentWitness(
                row: lastWrite.row,
                column: cluster.leadColumn,
                cols: buf.cols,
                rows: buf.rows,
                scalar: scalar,
                isAlternateBuffer: isAlternateBuffer,
                phase: .activeShift)
        }

        if backwardColumnAttachmentWitness == nil,
           let witness = insertLineOwnerRefreshWitness,
           witness.cols == buf.cols,
           witness.rows == buf.rows,
           witness.isAlternateBuffer == isAlternateBuffer,
           rows.contains(witness.absoluteRow - buf.yBase),
           columns.contains(witness.leadColumn),
           let scalar = UnicodeScalar(witness.cell.scalar) {
            // IL can leave the prior attachment coordinate blank. DECBI is
            // allowed to reactivate that lineage only from the cell generated
            // or shifted into the same saved coordinate.
            backwardColumnAttachmentWitness = BackwardColumnAttachmentWitness(
                row: witness.absoluteRow,
                column: witness.leadColumn,
                cols: witness.cols,
                rows: witness.rows,
                scalar: scalar,
                isAlternateBuffer: witness.isAlternateBuffer,
                phase: .dormantCoordinate)
        }

        shift()

        guard let witness = backwardColumnAttachmentWitness,
              witness.cols == buf.cols,
              witness.rows == buf.rows,
              witness.isAlternateBuffer == isAlternateBuffer,
              let line = buf.line(absolute: witness.row),
              witness.column >= 0,
              witness.column < line.count else { return }
        let cell = line[witness.column]
        let isRealLead = cell.width > 0 && cell.scalar != 0
        guard isRealLead,
              let scalar = UnicodeScalar(cell.scalar) else {
            let dormantWitness = BackwardColumnAttachmentWitness(
                row: witness.row,
                column: witness.column,
                cols: witness.cols,
                rows: witness.rows,
                scalar: witness.scalar,
                isAlternateBuffer: witness.isAlternateBuffer,
                phase: .dormantAfterShift)
            invalidateClusterContinuation()
            lastWrite = (0, 0, -1, -1)
            backwardColumnAttachmentWitness = dormantWitness
            return
        }

        if let lineWitness = insertLineOwnerRefreshWitness,
           lineWitness.absoluteRow == witness.row,
           lineWitness.leadColumn == witness.column,
           lineWitness.cols == witness.cols,
           lineWitness.rows == witness.rows,
           lineWitness.isAlternateBuffer == witness.isAlternateBuffer {
            insertLineOwnerRefreshWitness = nil
        }

        lastPrintedScalar = scalar
        presentationSelectorAuthority = Self.selectorAuthority(for: cell)
        lastWrite = (
            row: witness.row, x: witness.column,
            cols: witness.cols, rows: witness.rows)
        lastWriteDisplacedCell = nil
        lastPrintWrappedFromRightOfMargin = false
        lastPrintAdvancedToFreshRow = false
        lastPrintAdvancedFromCurrentPendingOwner = false
        // The shift replaces the scalar at the same logical owner
        // coordinate. Preserve the cursor trajectory already measured
        // against that coordinate so a later width-changing selector composes
        // with movement that happened before DECBI.
        selectorExpansionSettledPhysicalPending = nil
        backwardColumnAttachmentWitness = BackwardColumnAttachmentWitness(
            row: witness.row,
            column: witness.column,
            cols: witness.cols,
            rows: witness.rows,
            scalar: scalar,
            isAlternateBuffer: witness.isAlternateBuffer,
            phase: .activeShift)
    }

    func retainForwardColumnShiftTail(
        _ tail: Cell,
        sourceColumn: Int,
        destinationColumn: Int,
        row: Int,
        minimumColumn: Int
    ) {
        let currentInsertLineWitness = insertLineOwnerRefreshWitness.flatMap {
            witness in
            witness.cols == buffer.cols &&
                witness.rows == buffer.rows &&
                witness.isAlternateBuffer == isAlternateBuffer
                ? witness
                : nil
        }
        if currentInsertLineWitness != nil {
            // IL may have vacated an owner coordinate on another row.  A
            // DECFI shift may reactivate it only from the real cell landing
            // at that exact saved coordinate.  Never replace the dormant
            // lineage with an arbitrary physical-suffix tail.
            return
        }
        let unaffectedHistoricalOwnerIsStillValid =
            lastPrintedScalar != nil &&
            lastWrite.rows == buffer.rows &&
            lastWrite.cols == buffer.cols &&
            lastWrite.row != buffer.yBase + row &&
            validatedLastCluster() != nil
        if unaffectedHistoricalOwnerIsStillValid {
            // The coordinate-refresh helper has already established that the
            // retained owner lies outside DECFI's shifted row rectangle. A
            // cell shifted on another row, whether blank or stale content, is
            // not a replacement write and cannot discard that owner.
            return
        }
        let ownerIsCurrentWrite = lastPrintedScalar != nil &&
            lastWrite.rows == buffer.rows &&
            lastWrite.cols == buffer.cols &&
            lastWrite.row == buffer.yBase + row
        if ownerIsCurrentWrite, lastWrite.x < minimumColumn {
            return
        }
        let sourceWasCurrentWrite = lastWrite.rows == buffer.rows &&
            lastWrite.cols == buffer.cols &&
            lastWrite.row == buffer.yBase + row &&
            lastWrite.x == sourceColumn
        let returnsInsertLineOwnerCoordinate =
            currentInsertLineWitness.map { witness in
                witness.absoluteRow == buffer.yBase + row &&
                    witness.leadColumn == destinationColumn
            } ?? false
        let destinationIsContiguous: Bool
        if returnsInsertLineOwnerCoordinate {
            // In a one-row or partial-slice IL generation the saved owner can
            // return from the physical suffix while the preceding active
            // cells are still blank. Exact-coordinate return, rather than
            // textual contiguity, is the ownership proof in that case.
            destinationIsContiguous = true
        } else if destinationColumn == 0 {
            destinationIsContiguous = true
        } else if destinationColumn > 0, destinationColumn < buffer.cols {
            let predecessor = buffer.liveLine(row)[destinationColumn - 1]
            destinationIsContiguous = predecessor.scalar != 0 || predecessor.width == 0
        } else {
            destinationIsContiguous = false
        }
        guard !sourceWasCurrentWrite,
              destinationIsContiguous,
              destinationColumn >= minimumColumn,
              destinationColumn >= 0,
              destinationColumn < buffer.cols,
              tail.width == 1,
              tail.scalar != 0,
              let scalar = UnicodeScalar(tail.scalar) else {
            invalidateClusterContinuation()
            lastWrite = (0, 0, -1, -1)
            return
        }
        backwardColumnAttachmentWitness = nil
        if returnsInsertLineOwnerCoordinate {
            insertLineOwnerRefreshWitness = nil
        }
        lastPrintedScalar = scalar
        presentationSelectorAuthority = Self.selectorAuthority(for: tail)
        lastWrite = (
            row: buffer.yBase + row,
            x: destinationColumn,
            cols: buffer.cols,
            rows: buffer.rows)
        lastWriteDisplacedCell = nil
    }

    func insertCellDirect(_ source: Cell) {
        let buf = buffer
        let advancedFromNoWrapParkedPosition = noWrapParkedAfterPrint
        if preservesPresentationOwnerAcrossRejectedWide(
            source, in: buf
        ) {
            return
        }
        let preservesDisplacedReverseIndexOwner =
            reverseIndexOwnerRefreshIsDisplaced()
        let suppressRelocationAfterCursorUp = pendingCursorUpMoved
        let suppressRelocationAfterSettledSelector =
            selectorExpansionSettledPhysicalPending.map { witness in
                witness.row == buf.yBase + buf.y &&
                    witness.cols == buf.cols &&
                    witness.rows == buf.rows &&
                    buf.x == buf.cols &&
                    buf.wrapPending &&
                    autoWrap
            } ?? false
        selectorExpansionSettledPhysicalPending = nil
        pendingCursorUpMoved = false
        lastPrintWrappedFromRightOfMargin = false
        lastPrintAdvancedToFreshRow = false
        lastPrintAdvancedFromCurrentPendingOwner = false
        guard buf.cols > 0, buf.rows > 0,
              let scalar = UnicodeScalar(source.scalar) else {
            invalidateClusterContinuation()
            return
        }

        buf.y = min(buf.rows - 1, max(0, buf.y))
        var columns = printingColumns(for: buf.x)
        let startedSettledRightOfMargin = marginMode && autoWrap &&
            !buf.wrapPending && buf.x > columns.upperBound && buf.x < buf.cols
        var advancedToFreshRow = false
        var advancedAtScrollBottom = false
        let width = min(2, max(1, Int(source.width)))
        if !autoWrap, width == 2, buf.x > columns.upperBound {
            restoreClusterContinuationAfterRejectedWide()
            return
        }
        noWrapParkedAfterPrint = false
        if buf.x < columns.lowerBound {
            buf.x = columns.lowerBound
        }

        // A pending column belongs to the horizontal geometry that armed it.
        // If a later margin change makes that one-past position addressable,
        // the pending wrap is stale: consume it and print at the now-physical
        // column. A follower that still cannot fit will take the ordinary
        // width-overflow wrap below and establish fresh row topology.
        if buf.wrapPending, buf.x <= columns.upperBound {
            buf.wrapPending = false
        }

        let beganFromPendingOwner =
            buf.wrapPending && buf.x > columns.upperBound
        let pendingOwnerWasCurrent: Bool
        if beganFromPendingOwner {
            pendingOwnerWasCurrent = pendingWrapOwnerStillOccupiesDeparture()
        } else {
            // A DECAWM-off print can park one cell beyond the edge without
            // setting `wrapPending`. If ICH subsequently exposes a blank at
            // that departure coordinate, re-enabling autowrap still advances
            // the next base, but its selector cannot relocate through the
            // removed parked owner. When the owner was not removed, the
            // occupied destination independently prevents relocation.
            pendingOwnerWasCurrent = !advancedFromNoWrapParkedPosition
        }

        if buf.wrapPending || buf.x > columns.upperBound {
            if autoWrap {
                advancedAtScrollBottom = advanceForPendingWrap(columns: columns)
                columns = printingColumns(for: buf.x)
                advancedToFreshRow = true
            } else {
                buf.x = columns.upperBound
                buf.wrapPending = false
            }
        }

        var clippedWideLead = false
        if width == 2, buf.x == columns.upperBound {
            if columns.count == 1, advancedToFreshRow {
                clippedWideLead = buf.x == buf.cols - 1
            } else {
                guard autoWrap else {
                    buf.wrapPending = false
                    restoreClusterContinuationAfterRejectedWide()
                    return
                }
                advancedAtScrollBottom =
                    advanceForPendingWrap(columns: columns) || advancedAtScrollBottom
                columns = printingColumns(for: buf.x)
                advancedToFreshRow = true
                clippedWideLead = columns.count == 1 && buf.x == buf.cols - 1
            }
        }

        let leadColumn = min(columns.upperBound, max(columns.lowerBound, buf.x))
        let spillsPastSingleColumnMargin = width == 2 &&
            columns.count == 1 && advancedToFreshRow && leadColumn < buf.cols - 1
        let glyphBounds = spillsPastSingleColumnMargin
            ? 0...(buf.cols - 1)
            : columns
        let physicalWidth = clippedWideLead ? 1 : width
        guard leadColumn + physicalWidth - 1 <= glyphBounds.upperBound else {
            invalidateClusterContinuation()
            return
        }

        let line = buf.liveLine(buf.y)
        var displacedCell = line[leadColumn]
        if insertMode {
            let insertionRightMargin = marginMode
                ? buf.marginRight
                : glyphBounds.upperBound
            line.insertCells(
                at: leadColumn, count: physicalWidth,
                rightMargin: insertionRightMargin,
                fill: Cell.blank(attribute: eraseAttribute))
            // Cell insertion may push an already-clipped wide lead through an
            // internal horizontal margin and leave it at the physical edge.
            // A width-two lead cannot begin in the final physical column, so
            // the reference sanitizes that orphan even when the insertion's
            // active right boundary is earlier.  A lead clipped at an internal
            // margin remains intact until a later shift actually moves it to
            // the physical edge.
            if line[buf.cols - 1].width == 2 {
                line[buf.cols - 1] = Cell.blank(attribute: Self.stubAttribute)
            }
            displacedCell = line[leadColumn]
        } else {
            clearGlyphIntersecting(column: leadColumn, in: line, bounds: glyphBounds)
            if physicalWidth == 2 {
                clearGlyphIntersecting(column: leadColumn + 1, in: line, bounds: glyphBounds)
            }
        }

        var cell = source
        cell.width = Int8(width)
        line[leadColumn] = cell
        if physicalWidth == 2 {
            line[leadColumn + 1] = Cell(
                scalar: 0, width: 0, attribute: Self.stubAttribute)
        }

        rejectedWidePresentationOwnerWitness = nil
        finishPrintReverseIndexOwnerRefresh(
            preservingDisplacedOwner: preservesDisplacedReverseIndexOwner,
            printedOwnerRow: buf.yBase + buf.y,
            printedOwnerColumn: leadColumn)
        backwardColumnAttachmentWitness = nil
        lastPrintedScalar = scalar
        presentationSelectorAuthority = .available
        lastWrite = (
            row: buf.yBase + buf.y, x: leadColumn,
            cols: buf.cols, rows: buf.rows)
        selectorOwnerAdvancedByRelativeMotion = false
        selectorRelocationTracksWidthChange = false
        lastWriteDisplacedCell = DisplacedCell(
            row: buf.yBase + buf.y, column: leadColumn,
            cols: buf.cols, rows: buf.rows, cell: displacedCell)
        lastPrintWrappedFromRightOfMargin =
            startedSettledRightOfMargin && advancedToFreshRow
        lastPrintAdvancedToFreshRow =
            advancedToFreshRow &&
            !suppressRelocationAfterCursorUp &&
            !suppressRelocationAfterSettledSelector
        lastPrintAdvancedFromCurrentPendingOwner =
            advancedToFreshRow && pendingOwnerWasCurrent
        if advancedAtScrollBottom, hasNarrowMargins {
            // A partial-width scroll replaces cell slices while retaining the
            // physical Line objects.  A row that was already a soft-wrapped
            // continuation now has mixed provenance, so its old whole-row
            // link becomes a persistent hard boundary.  An unwrapped row has
            // no link to invalidate and may acquire a legitimate soft wrap
            // later.  The exposed bottom is marked wrapped by the scroll and
            // is therefore hardened here as well.
            for row in buf.scrollTop...buf.scrollBottom {
                let affectedLine = buf.liveLine(row)
                if affectedLine.isWrapped,
                   !activeMarginReflowBoundaries.contains(where: {
                    $0.line === affectedLine
                }) {
                    activeMarginReflowBoundaries.append(
                        ActiveMarginReflowBoundary(line: affectedLine))
                }
            }
        }
        let nextColumn = leadColumn + physicalWidth
        if nextColumn > columns.upperBound {
            buf.x = nextColumn
            buf.wrapPending = autoWrap
        } else {
            buf.x = nextColumn
            buf.wrapPending = false
        }
        refreshPendingWrapOwnerWitness(
            line: line,
            leadColumn: leadColumn)
        noWrapParkedAfterPrint = !autoWrap &&
            buf.x > columns.upperBound
        markDirty(absoluteRow: buf.yBase + buf.y)
    }

    private func preservesPresentationOwnerAcrossRejectedWide(
        _ source: Cell,
        in buf: ScreenBuffer
    ) -> Bool {
        let columns = printingColumns(for: buf.x)
        guard !autoWrap,
              buf.cols > 0,
              buf.rows > 0,
              buf.x >= columns.upperBound,
              buf.x <= buf.cols,
              source.width == 2,
              source.clusterExtras?.isEmpty != false,
              let rejectedScalar = UnicodeScalar(source.scalar),
              UnicodeUtil.columnWidth(rune: rejectedScalar) == 2,
              let cluster = validatedLastCluster(),
              let extras = cluster.cell.clusterExtras,
              extras.contains(where: { $0 == 0xFE0E || $0 == 0xFE0F }) else {
            return false
        }

        if Self.isCompletePresentationOwner(cluster.cell) {
            rejectedWidePresentationOwnerWitness =
                RejectedWidePresentationOwnerWitness(
                    line: cluster.line,
                    leadColumn: cluster.leadColumn,
                    cell: cluster.cell,
                    cols: buf.cols,
                    rows: buf.rows,
                    isAlternateBuffer: isAlternateBuffer)
            return true
        }

        guard extras.last == 0x200D else { return false }
        var ownerBeforeJoiner = cluster.cell
        ownerBeforeJoiner.clusterExtras = Array(extras.dropLast())

        if let witness = rejectedWidePresentationOwnerWitness,
           witness.cols == buf.cols,
           witness.rows == buf.rows,
           witness.isAlternateBuffer == isAlternateBuffer,
           witness.line === cluster.line,
           witness.leadColumn == cluster.leadColumn,
           witness.cell == ownerBeforeJoiner {
            return true
        }

        return lastWriteDisplacedCell.map { displaced in
            displaced.row == lastWrite.row &&
                displaced.column == cluster.leadColumn &&
                displaced.cols == buf.cols &&
                displaced.rows == buf.rows &&
                Self.isCompletePresentationOwner(displaced.cell) &&
                displaced.cell == ownerBeforeJoiner
        } ?? false
    }

    private static func isCompletePresentationOwner(_ cell: Cell) -> Bool {
        guard cell.width > 0,
              let lead = UnicodeScalar(cell.scalar),
              UnicodeUtil.columnWidth(rune: lead) == 1,
              UnicodeUtil.isEmojiVs16Base(rune: lead),
              isEmojiZWJComponent(lead),
              let extras = cell.clusterExtras,
              extras.contains(where: { $0 == 0xFE0E || $0 == 0xFE0F }),
              extras.last != 0x200D else {
            return false
        }
        return true
    }

    private func restoreClusterContinuationAfterRejectedWide() {
        let buf = buffer
        let priorAuthority = presentationSelectorAuthority
        if priorAuthority == .suspended || priorAuthority == .blocked {
            presentationSelectorAuthority = .unavailable
        }
        guard lastPrintedScalar == nil,
              lastWrite.rows == buf.rows,
              lastWrite.cols == buf.cols,
              lastWrite.x >= 0,
              lastWrite.x < buf.cols,
              let line = buf.line(absolute: lastWrite.row) else { return }

        // Rejection restoration owns the saved coordinate, not an arbitrary
        // wide lead immediately to its left.  RI can rotate a continuation
        // into a displaced narrow owner's old coordinate; adopting that lead
        // would let a later joiner mutate unrelated historical content.
        let lead = lastWrite.x
        guard line[lead].width > 0,
              let scalar = UnicodeScalar(line[lead].scalar) else { return }
        lastPrintedScalar = scalar
        presentationSelectorAuthority = priorAuthority == .available
            ? .available
            : .unavailable
    }

    private func printingColumns(for column: Int) -> ClosedRange<Int> {
        let buf = buffer
        if marginMode, column >= buf.marginLeft {
            return buf.marginLeft...buf.marginRight
        }
        return 0...(buf.cols - 1)
    }

    @discardableResult
    private func advanceForPendingWrap(columns: ClosedRange<Int>) -> Bool {
        let buf = buffer
        let consumedPendingWrap = buf.wrapPending
        let beganFromSettledExterior =
            !consumedPendingWrap && buf.x > columns.upperBound
        let advancedAtScrollBottom = buf.y == buf.scrollBottom
        let establishesWholeRowWrapAtBottom =
            advancedAtScrollBottom && !hasNarrowMargins &&
            buf.x >= columns.upperBound
        // A pending owner below a valid vertical region is still coupled to
        // that region's upward-scroll generation. Reuse the existing region
        // scroll while leaving the physical cursor row unchanged: a top-zero
        // region retains the below-region suffix in history, while an inset
        // region rotates without history. At an inset physical bottom the
        // reference instead keeps the ordinary in-place branch.
        let scrollsRegionForPendingOwnerBelowBottom =
            buf.wrapPending &&
            pendingWrapOwnerStillOccupiesDeparture() &&
            buf.scrollTop < buf.scrollBottom &&
            buf.y > buf.scrollBottom &&
            (buf.scrollTop == 0 || buf.y < buf.rows - 1)
        // A settled print from the physical right column, strictly below the
        // vertical region and to the right of an active internal margin,
        // wraps horizontally in place. Before writing, the reference scrolls
        // the stored rectangle once but leaves the physical cursor row alone.
        // This is distinct from pending wrap and from a no-wrap parked cursor.
        let scrollsStoredRegionBeforeInPlaceWrap =
            marginMode && autoWrap && !buf.wrapPending &&
            buf.marginRight < buf.cols - 1 &&
            buf.x == buf.cols - 1 &&
            buf.y > buf.scrollBottom

        if scrollsRegionForPendingOwnerBelowBottom {
            engineScrollUp()
        } else if scrollsStoredRegionBeforeInPlaceWrap {
            engineScrollUp(markNewWrapped: true)
        } else if buf.y == buf.scrollBottom {
            engineScrollUp(markNewWrapped: true)
            buf.y = buf.scrollBottom
            // A prior rectangular scroll can leave a hard reflow boundary on
            // the Line object recycled into the exposed bottom. Once changed
            // horizontal geometry makes this a whole-row wrap, that new
            // bottom destination owns a fresh soft continuation. Clear its
            // old witness after the row rotation; boundaries that moved upward
            // with retained Line objects remain valid.
            if establishesWholeRowWrapAtBottom {
                let destination = buf.liveLine(buf.scrollBottom)
                clearActiveMarginReflowBoundary(from: destination)
                clearSupersededKittyDisplayReflowState(from: destination)
            }
        } else if buf.y < buf.rows - 1 {
            let departure = buf.liveLine(buf.y)
            buf.y += 1
            let destination = buf.liveLine(buf.y)
            if consumedPendingWrap {
                if hasNarrowMargins {
                    // Under unchanged rectangular geometry, the incoming
                    // continuation supersedes the exact destination witness.
                    // The other rows in the placement generation remain
                    // meaningful through a later width reflow.
                    clearSupersededKittyDisplayReflowState(from: destination)
                } else {
                    // With rectangular geometry disabled, a whole-row
                    // continuation supersedes its destination witness. A
                    // destination claim merges under the preceding boundary;
                    // a destination boundary consumes its immediate successor
                    // claim as the other half of that generation.
                    let destinationWasClaimed =
                        hasKittyDisplayReflowClaim(on: destination)
                    clearSupersededKittyDisplayReflowState(from: destination)
                    if !destinationWasClaimed {
                        if buf.y + 1 < buf.rows {
                            clearSupersededKittyDisplayReflowState(
                                from: buf.liveLine(buf.y + 1))
                        }
                    }
                }
            } else if hasKittyDisplayReflowClaim(on: destination) {
                if hasNarrowMargins && !beganFromSettledExterior {
                    // A wide glyph overflowing exactly at the active right
                    // edge is a real continuation of the departure Line. A
                    // content-bearing or semantic departure keeps its
                    // captured generation's hard separator meaningful, so
                    // consume the destination claim. If the departure is
                    // empty and unreferenced, retire any marker on it and
                    // retain the now-materialized destination as the
                    // separator instead.
                    if isEffectiveKittyDisplayReflowDeparture(
                        departure, in: buf) {
                        clearSupersededKittyDisplayReflowState(
                            from: destination)
                    } else {
                        clearKittyDisplayReflowBoundary(from: departure)
                        demoteKittyDisplayReflowClaimToBoundary(
                            on: destination)
                    }
                } else {
                    // A margin contraction can put a settled cursor beyond
                    // the new right edge. Advancing from there consumes the
                    // copied hard boundary on the departure Line. The
                    // exposed-row claim is no longer virtual once content
                    // arrives, so retain that real separator as a boundary
                    // without its stronger rank claim. Full-width wide
                    // overflow follows the same physical-row topology.
                    clearKittyDisplayReflowBoundary(from: departure)
                    demoteKittyDisplayReflowClaimToBoundary(on: destination)
                }
            } else {
                clearSupersededKittyDisplayReflowState(from: destination)
            }
            destination.isWrapped = true
            // Unlike a rectangular bottom scroll, this is a genuine incoming
            // whole-row wrap.  It establishes fresh soft topology for the
            // destination and supersedes any older hard-boundary witness that
            // belonged to a previous partial-slice replacement.
            clearActiveMarginReflowBoundary(from: destination)
        }
        buf.x = columns.lowerBound
        buf.wrapPending = false
        invalidateClusterContinuation()
        return advancedAtScrollBottom
    }

    private func clearActiveMarginReflowBoundary(from line: Line) {
        activeMarginReflowBoundaries.removeAll { boundary in
            boundary.line === line
        }
    }

    private func clearSupersededKittyDisplayReflowState(from line: Line) {
        kittyDisplayReflowBoundaries.removeAll { boundary in
            boundary.line === line
        }
        kittyDisplayClippedTopReflowRanks.removeAll { rank in
            rank.line === line
        }
        kittyDisplayReflowClaims.removeAll { claim in
            claim.line === line
        }
    }

    private func hasKittyDisplayReflowClaim(on line: Line) -> Bool {
        kittyDisplayReflowClaims.contains { claim in
            claim.line === line
        }
    }

    private func isEffectiveKittyDisplayReflowDeparture(
        _ line: Line,
        in screen: ScreenBuffer
    ) -> Bool {
        if line.usedLength > 0 { return true }
        guard screen === normalBuffer,
              let row = screen.lines.firstIndex(where: { $0 === line }) else {
            return false
        }
        return blocks.blocks.contains {
            $0.promptRow == row || $0.commandRow == row
        }
    }

    private func clearKittyDisplayReflowBoundary(from line: Line) {
        kittyDisplayReflowBoundaries.removeAll { boundary in
            boundary.line === line
        }
    }

    private func demoteKittyDisplayReflowClaimToBoundary(on line: Line) {
        guard hasKittyDisplayReflowClaim(on: line) else { return }
        kittyDisplayReflowClaims.removeAll { claim in
            claim.line === line
        }
        if !kittyDisplayReflowBoundaries.contains(where: { boundary in
            boundary.line === line
        }) {
            kittyDisplayReflowBoundaries.append(
                KittyDisplayReflowBoundary(line: line))
        }
    }

    func clearKittyDisplayReflowClaims(in screen: ScreenBuffer) {
        kittyDisplayReflowClaims.removeAll { claim in
            screen.lines.contains(where: { $0 === claim.line })
        }
        kittyDisplayReflowBoundaries.removeAll { boundary in
            screen.lines.contains(where: { $0 === boundary.line })
        }
        kittyDisplayClippedTopReflowRanks.removeAll { rank in
            screen.lines.contains(where: { $0 === rank.line })
        }
        pruneKittyDisplayReflowImages()
    }

    func retireKittyDisplayReflowClaimDisplacedFromBottom(
        _ previousBottom: Line,
        in screen: ScreenBuffer
    ) {
        guard !screen.lines.contains(where: { $0 === previousBottom }) ||
            screen.liveLine(screen.scrollBottom) !== previousBottom else {
            return
        }
        kittyDisplayReflowClaims.removeAll { $0.line === previousBottom }
        kittyDisplayReflowImageTransfers.removeAll {
            $0.source === previousBottom
        }
    }

    private func clearGlyphIntersecting(
        column: Int,
        in line: Line,
        bounds: ClosedRange<Int>
    ) {
        guard bounds.contains(column), column >= 0, column < line.count else { return }
        let blank = Cell.blank(attribute: eraseAttribute)
        let cell = line[column]
        if cell.width == 0 {
            line[column] = blank
        } else if cell.width == 2 {
            line[column] = blank
        }
    }

    private struct BackspacePlan {
        let x: Int
        let y: Int
        let clearWrappedRow: Int?
    }

    private struct BackspaceGeometry {
        let screenColumns: ClosedRange<Int>
        let verticalClamp: ClosedRange<Int>
        let leftBoundary: Int
        let rightBoundary: Int
        let scrollTop: Int
        let scrollBottom: Int
        let marginMode: Bool
        let reverse: Bool

        func plan(
            x rawX: Int,
            y rawY: Int,
            pendingWrap: Bool
        ) -> BackspacePlan {
            let y = min(verticalClamp.upperBound, max(verticalClamp.lowerBound, rawY))

            // A pending position created at an internal right margin can
            // remain inside the physical screen. Resolve that retained
            // coordinate against the geometry active now: while it is still
            // outside the right bound, each BS takes one physical step toward
            // that bound (a selector expansion can leave it two cells out);
            // once a geometry change makes it addressable, the first BS takes
            // the ordinary one-cell step. Reverse-wrap does not alter this
            // pending-coordinate decision. Physical-edge pending remains one
            // past the screen and follows the traditional branch below.
            if pendingWrap, rawX <= screenColumns.upperBound {
                if rawX > rightBoundary {
                    return BackspacePlan(
                        x: max(rightBoundary, rawX - 1),
                        y: y, clearWrappedRow: nil)
                }
                return BackspacePlan(
                    x: max(leftBoundary, rawX - 1),
                    y: y,
                    clearWrappedRow: nil)
            }
            // A selector can widen an edge cell until the pending cursor is
            // physically beyond the screen, even when DECLRMM's right edge
            // sits one or more columns earlier. At that point BS follows the
            // physical-edge rule: ordinary mode steps left from the physical
            // edge, while reverse-wrap lands on that edge. The stored margin
            // must not be applied a second time after the physical clamp.
            if pendingWrap, rawX > screenColumns.upperBound {
                return BackspacePlan(
                    x: reverse
                        ? screenColumns.upperBound
                        : max(screenColumns.lowerBound,
                              screenColumns.upperBound - 1),
                    y: y,
                    clearWrappedRow: nil)
            }
            if pendingWrap, reverse {
                return BackspacePlan(
                    x: rightBoundary, y: y, clearWrappedRow: nil)
            }

            let logicalX = pendingWrap ? min(rawX, rightBoundary) : rawX
            let x: Int
            if reverse, !pendingWrap,
               logicalX == screenColumns.upperBound + 1 {
                x = logicalX
            } else {
                x = min(screenColumns.upperBound, max(screenColumns.lowerBound, logicalX))
            }

            if marginMode, x < leftBoundary {
                guard reverse else {
                    return BackspacePlan(x: max(0, x - 1), y: y, clearWrappedRow: nil)
                }
                if y < scrollTop, verticalClamp.lowerBound < scrollTop {
                    guard y > verticalClamp.lowerBound else {
                        return BackspacePlan(x: x, y: y, clearWrappedRow: nil)
                    }
                    return BackspacePlan(
                        x: rightBoundary, y: y - 1, clearWrappedRow: y)
                }
                return wrappedPlan(fromY: y)
            }

            if x > leftBoundary {
                return BackspacePlan(x: x - 1, y: y, clearWrappedRow: nil)
            }

            guard reverse else {
                return BackspacePlan(x: x, y: y, clearWrappedRow: nil)
            }

            // Absolute cursor addressing can leave the cursor above a custom
            // scrolling region.  In that physical prefix, reverse wraparound
            // walks the physical rows and stops at the screen top rather than
            // cycling through the scrolling region.  Origin mode clamps through
            // `verticalClamp` first, so it still cycles region-top to bottom.
            if y < scrollTop, verticalClamp.lowerBound < scrollTop {
                guard y > verticalClamp.lowerBound else {
                    return BackspacePlan(x: x, y: y, clearWrappedRow: nil)
                }
                return BackspacePlan(
                    x: rightBoundary, y: y - 1, clearWrappedRow: y)
            }

            return wrappedPlan(fromY: y)
        }

        private func wrappedPlan(fromY y: Int) -> BackspacePlan {
            let destinationRow: Int
            let wrappedRowToClear: Int?
            if y == scrollTop {
                destinationRow = scrollBottom
                wrappedRowToClear = nil
            } else if y > scrollTop {
                destinationRow = y - 1
                wrappedRowToClear = y
            } else {
                destinationRow = scrollBottom
                wrappedRowToClear = destinationRow == y ? nil : destinationRow
            }
            return BackspacePlan(
                x: rightBoundary, y: destinationRow,
                clearWrappedRow: wrappedRowToClear)
        }
    }

    func executeControl(_ byte: UInt8) {
        switch byte {
        case 0x00:
            break
        case 0x07:
            delegate?.bell(self)
        case 0x08:
            performBackspace()
        case 0x09:
            let oldX = buffer.x
            buffer.x = buffer.nextTabStop(
                from: buffer.x, marginMode: marginMode)
            buffer.wrapPending = false
            recordSelectorOwnerRelativeForwardMotion(from: oldX)
        case 0x0A, 0x0B, 0x0C:
            if lineFeedMode { carriageReturn() }
            lineFeed()
        case 0x0D:
            carriageReturn()
        case 0x0E:
            glLevel = 1
        case 0x0F:
            glLevel = 0
        case 0x84:
            indexLineFeed()
        case 0x85:
            carriageReturn()
            indexLineFeed()
        case 0x88:
            buffer.setTabStop(at: buffer.x)
        case 0x8D:
            reverseLineFeed()
        default:
            break
        }
    }

    private func carriageReturn() {
        let buf = buffer
        let oldX = buf.x
        let oldY = buf.y
        buf.x = marginMode && buf.x >= buf.marginLeft ? buf.marginLeft : 0
        buf.wrapPending = false
        noWrapParkedAfterPrint = false
        recordSelectorOwnerStrictLeftReposition(from: oldX, oldY: oldY)
    }

    var hasNarrowMargins: Bool {
        marginMode && (buffer.marginLeft > 0 || buffer.marginRight < buffer.cols - 1)
    }

    private func performBackspace() {
        let buf = buffer
        guard buf.cols > 0, buf.rows > 0 else { return }
        let oldX = buf.x
        let oldY = buf.y

        let verticalClamp = originMode
            ? buf.scrollTop...buf.scrollBottom
            : 0...(buf.rows - 1)
        let usesHorizontalBounds = hasNarrowMargins
        let geometry = BackspaceGeometry(
            screenColumns: 0...(buf.cols - 1),
            verticalClamp: verticalClamp,
            leftBoundary: usesHorizontalBounds ? buf.marginLeft : 0,
            rightBoundary: usesHorizontalBounds ? buf.marginRight : buf.cols - 1,
            scrollTop: buf.scrollTop,
            scrollBottom: buf.scrollBottom,
            marginMode: usesHorizontalBounds,
            reverse: reverseWraparound)
        let plan = geometry.plan(
            x: buf.x,
            y: buf.y,
            pendingWrap: buf.wrapPending)

        buf.x = plan.x
        buf.y = plan.y
        buf.wrapPending = false
        recordSelectorOwnerRelativeBackwardMotion(from: oldX, oldY: oldY)
        // With DECLRMM active, reverse-wrap BS is motion inside the current
        // horizontal geometry.  It does not turn the departed soft-wrapped
        // continuation into a hard reflow boundary, even when the stored
        // margins span the full screen.  Once DECLRMM is hidden, BS resumes
        // whole-row semantics and clears that link as before.
        if let row = plan.clearWrappedRow, !marginMode {
            buf.liveLine(row).isWrapped = false
            markDirty(absoluteRow: buf.yBase + row)
        }
    }

    private enum ScrollSliceDirection {
        case towardTop
        case towardBottom
    }

    func engineScrollUp(
        markNewWrapped: Bool = false,
        clearNewLine: Bool = true,
        hardenPrewrappedDestinations: Bool = false
    ) {
        let buf = buffer
        let fill = Cell.blank(attribute: eraseAttribute)
        let preservesMarginDeleteGeneration = hasNarrowMargins

        if preservesMarginDeleteGeneration {
            scrollNarrowSlices(
                direction: .towardTop,
                fill: fill,
                exposedRowWrapped: markNewWrapped,
                hardenPrewrappedDestinations: hardenPrewrappedDestinations)
        } else {
            // A whole-screen scroll into scrollback preserves the identity and
            // contents of every retained row. Line versions plus the caller's
            // control damage cover the newly exposed edge, so a full viewport
            // mark here would defeat the renderer's absolute-row cache. Keep
            // the conservative mark for interior-region rotations.
            let scrollsWholeViewport = buf.canScrollFullScreenIntoScrollback
            buf.scrollUp(
                fill: fill,
                markNewWrapped: markNewWrapped,
                clearRecycledLine: clearNewLine)
            synchronizeBlockRowsToScrollback()
            if !scrollsWholeViewport { markViewportDirty() }
        }
        // A full-width scroll recycles row identity, so hidden virtual slots
        // from the departed delete generation must not follow it. A partial
        // horizontal-margin scroll only replaces slices inside the existing
        // Line objects; both the historical blank attributes and nonblank
        // virtual cells remain addressable at their original coordinates.
        if !preservesMarginDeleteGeneration {
            marginDeleteGenerations.removeAll(keepingCapacity: true)
        }
        invalidateClusterContinuation()
    }

    func engineScrollDown(hardenPrewrappedDestinations: Bool = false) {
        let buf = buffer
        let fill = Cell.blank(attribute: eraseAttribute)
        let rotatedBottomWitness = !hasNarrowMargins &&
            buf.scrollBottom == buf.rows - 1
            ? buf.liveLine(buf.rows - 1)
            : nil

        if hasNarrowMargins {
            scrollNarrowSlices(
                direction: .towardBottom,
                fill: fill,
                exposedRowWrapped: false,
                hardenPrewrappedDestinations: hardenPrewrappedDestinations)
        } else {
            buf.scrollDown(fill: fill)
            markViewportDirty()
        }
        if let rotatedBottomWitness {
            rebindMarginDeleteGenerationWitnesses(
                afterRotating: rotatedBottomWitness)
        }
        invalidateClusterContinuation()
    }

    func rebindMarginDeleteGenerationWitnesses(afterRotating oldBottom: Line) {
        let buf = buffer
        guard buf.scrollBottom == buf.rows - 1 else { return }
        let currentBottom = buf.liveLine(buf.rows - 1)
        guard currentBottom !== oldBottom else { return }

        // Full-width RI, IL, DL, and SU rotate the Line object guarding hidden
        // margin-mode rows away from the physical bottom without scrolling
        // that virtual generation into history. Keep the generation attached
        // to its physical-bottom coordinate by adopting the replacement Line
        // identity. Partial slices retain Line identity and LF/IND explicitly
        // retire the generation in engineScrollUp.
        for index in marginDeleteGenerations.indices
        where marginDeleteGenerations[index].witnessLine === oldBottom {
            marginDeleteGenerations[index].witnessLine = currentBottom
        }
    }

    private func scrollNarrowSlices(
        direction: ScrollSliceDirection,
        fill: Cell,
        exposedRowWrapped: Bool,
        hardenPrewrappedDestinations: Bool = false
    ) {
        let buf = buffer
        guard buf.scrollTop <= buf.scrollBottom,
              buf.marginLeft <= buf.marginRight else {
            return
        }

        let rows = Array(buf.scrollTop...buf.scrollBottom)
        let columns = buf.marginLeft...buf.marginRight
        // A rectangular scroll overwrites every cell in the active slice.
        // Kitty markers remain attached to their renderer-owned Line objects,
        // so any marker whose placement column is overwritten becomes stale
        // sizing metadata even when its Line is an intermediate destination,
        // not only the outgoing edge. Register those markers for the existing
        // suspend/remap lifecycle. Full-row motion carries Line identity and
        // never enters this helper.
        // RI can normalize from a freshly printed real owner on its top row.
        // Whether that owner is inside or immediately left of the stored
        // slice, it makes the reverse-scroll generation real and the old
        // placement-only extent elsewhere in the affected rows no longer
        // sizes the buffer.
        // Absolute cursor addressing invalidates the cluster, matching the
        // reference's boundary between this case and a merely parked cursor.
        let retiresOutsideSliceKittyExtent: Bool = {
            guard direction == .towardBottom,
                  let cluster = validatedLastCluster() else { return false }
            return cluster.row == buf.scrollTop
        }()
        for row in rows {
            if let images = buf.liveLine(row).images {
                for image in images where image.kittyIsKitty &&
                    (columns.contains(image.col) ||
                        retiresOutsideSliceKittyExtent) &&
                    !kittyDisplayReflowImages.contains(where: { $0 === image }) {
                    kittyDisplayReflowImages.append(image)
                }
            }
        }
        if hardenPrewrappedDestinations {
            let destinationRows: ArraySlice<Int> = direction == .towardTop
                ? rows.dropLast()
                : rows.dropFirst()
            for row in destinationRows {
                let line = buf.liveLine(row)
                if line.isWrapped,
                   !activeMarginReflowBoundaries.contains(where: {
                    $0.line === line
                   }) {
                    activeMarginReflowBoundaries.append(
                        ActiveMarginReflowBoundary(line: line))
                }
            }
        }
        let snapshots = rows.map { row in
            Array(buf.liveLine(row).cells[columns])
        }

        for (destination, row) in rows.enumerated() {
            let source = direction == .towardTop
                ? destination + 1
                : destination - 1
            let line = buf.liveLine(row)
            if snapshots.indices.contains(source) {
                for (offset, cell) in snapshots[source].enumerated() {
                    line[columns.lowerBound + offset] = cell
                }
            } else {
                line.fillColumns(columns, with: fill)
            }
        }

        let exposedRow = direction == .towardTop
            ? rows[rows.count - 1]
            : rows[0]
        buf.liveLine(exposedRow).isWrapped = exposedRowWrapped
        let dirty = (buf.yBase + buf.scrollTop)...(buf.yBase + buf.scrollBottom)
        markDirty(absoluteRows: dirty)
    }

    /// LF, IND, and RI retain the last-written coordinate even when their row
    /// transform moves the cell away from it.  A following combining mark can
    /// therefore still attach after cursor-only movement/no-op, while the
    /// ordinary last-cluster validation rejects a coordinate whose contents
    /// were shifted.  The scroll engines invalidate this state for their other
    /// callers, so retain it narrowly around these three controls.
    private func preservingLineMotionClusterState(_ operation: () -> Void) {
        let retainedScalar = lastPrintedScalar
        let retainedSelectorAuthority = presentationSelectorAuthority
        let retainedDisplacedCell = lastWriteDisplacedCell
        let retainedWrappedFromRight = lastPrintWrappedFromRightOfMargin
        let retainedAdvancedToFreshRow = lastPrintAdvancedToFreshRow
        let retainedAdvancedFromCurrentPendingOwner =
            lastPrintAdvancedFromCurrentPendingOwner
        operation()
        lastPrintedScalar = retainedScalar
        presentationSelectorAuthority = retainedSelectorAuthority
        lastWriteDisplacedCell = retainedDisplacedCell
        lastPrintWrappedFromRightOfMargin = retainedWrappedFromRight
        lastPrintAdvancedToFreshRow = retainedAdvancedToFreshRow
        lastPrintAdvancedFromCurrentPendingOwner =
            retainedAdvancedFromCurrentPendingOwner
    }

    /// A top-boundary RI rotates a surviving row into every destination below
    /// the exposed top edge.  If that rotation replaces the valid cached
    /// owner at its fixed coordinate, later grapheme extenders attach to the
    /// replacement lead rather than to the scalar that occupied the coordinate
    /// before the rotation.  Other line motions retain their existing cached
    /// identity, and continuations never become owners on their own.
    private func crossedActivationAllowsReverseIndexOwnerRefresh(
        _ refresh: ReverseIndexOwnerRefresh
    ) -> Bool {
        let buf = buffer
        guard !isAlternateBuffer else { return false }
        let isHistorical = refresh.absoluteRow < buf.yBase
        guard let departure = reverseIndexBufferDepartureOwner,
              departure.activationSerial &+ 1 == bufferActivationSerial,
              departure.cols == buf.cols,
              departure.rows == buf.rows,
              departure.isAlternateBuffer != isAlternateBuffer else {
            // An empty or width-zero-only visit preserves a live normal owner,
            // but does not revive an owner that had already entered history.
            return !isHistorical
        }
        // A real owner from the other screen expires live-screen attachment.
        // A historical normal owner survives only when that foreign owner was
        // established at the exact coordinate the history owner still uses.
        return isHistorical &&
            departure.absoluteRow == refresh.absoluteRow &&
            departure.leadColumn == refresh.leadColumn
    }

    /// A real print in the other buffer leaves its absolute owner coordinate
    /// behind when the original buffer is reactivated. If that coordinate is
    /// now in the reactivated buffer's history, the cell occupying it becomes
    /// attachment owner. This is coordinate adoption: no nearest/oldest-row
    /// search is performed, and a blank or wide continuation cannot become an
    /// owner merely because it shares the coordinate.
    private func crossedActivationHistoricalOwnerRefresh()
        -> ReverseIndexOwnerRefresh?
    {
        let buf = buffer
        guard let departure = reverseIndexBufferDepartureOwner,
              departure.activationSerial &+ 1 == bufferActivationSerial,
              departure.cols == buf.cols,
              departure.rows == buf.rows,
              departure.isAlternateBuffer != isAlternateBuffer,
              departure.absoluteRow < buf.yBase,
              let line = buf.line(absolute: departure.absoluteRow),
              departure.leadColumn >= 0,
              departure.leadColumn < line.count else {
            return nil
        }
        let cell = line[departure.leadColumn]
        guard cell.width > 0, cell.scalar != 0 else { return nil }
        return reverseIndexOwnerRefreshSnapshot(
            absoluteRow: departure.absoluteRow,
            leadColumn: departure.leadColumn,
            line: line,
            cell: cell,
            selectorAuthority: Self.selectorAuthority(for: cell),
            selectorOwnerAdvancedByRelativeMotion: false,
            selectorRelocationTracksWidthChange:
                departure.absoluteRow != buf.yBase + buf.y)
    }

    private func expireCrossedReverseIndexOwnerRefresh() {
        let preservePendingOwner = pendingWrapOwnerStillOccupiesDeparture()
        reverseIndexOwnerRefreshWitness = nil
        lastPrintedScalar = nil
        presentationSelectorAuthority = .unavailable
        lastWrite = (row: 0, x: 0, cols: -1, rows: -1)
        lastWriteDisplacedCell = nil
        lastPrintWrappedFromRightOfMargin = false
        lastPrintAdvancedToFreshRow = false
        lastPrintAdvancedFromCurrentPendingOwner = false
        selectorOwnerAdvancedByRelativeMotion = false
        selectorRelocationTracksWidthChange = false
        selectorExpansionSettledPhysicalPending = nil
        if !preservePendingOwner {
            pendingWrapOwnerWitness = nil
        }
    }

    private func reverseIndexOwnerRefreshCandidate()
        -> ReverseIndexOwnerRefresh?
    {
        let buf = buffer
        let columns = hasNarrowMargins
            ? buf.marginLeft...buf.marginRight
            : 0...(buf.cols - 1)
        rebaseActiveReverseIndexOwnerRefreshWitness()
        if let refresh = reverseIndexOwnerRefreshWitness {
            // A later RI cannot infer a new owner from continuation state left
            // by another buffer activation.  The follower path below performs
            // the independently observed cross-screen restoration instead.
            guard refresh.activationSerial == bufferActivationSerial else {
                return nil
            }
            if refresh.cols == buf.cols,
               refresh.rows == buf.rows,
               refresh.isAlternateBuffer == isAlternateBuffer,
               (buf.yBase + buf.scrollTop...buf.yBase + buf.scrollBottom)
                .contains(refresh.absoluteRow),
               columns.contains(refresh.leadColumn) {
                return refresh
            }
        }
        if let cluster = validatedLastCluster(),
           (buf.scrollTop...buf.scrollBottom).contains(cluster.row),
           columns.contains(cluster.leadColumn) {
            let refresh = reverseIndexOwnerRefreshSnapshot(
                absoluteRow: lastWrite.row,
                leadColumn: cluster.leadColumn,
                line: cluster.line,
                cell: cluster.cell,
                selectorAuthority: presentationSelectorAuthority,
                selectorOwnerAdvancedByRelativeMotion:
                    selectorOwnerAdvancedByRelativeMotion,
                selectorRelocationTracksWidthChange:
                    selectorRelocationTracksWidthChange)
            reverseIndexOwnerRefreshWitness = refresh
            return refresh
        }
        return nil
    }

    @discardableResult
    private func restoreReverseIndexOwnerRefreshWitnessForFollower() -> Bool {
        let buf = buffer
        var refresh = reverseIndexOwnerRefreshWitness
        if let historicalRefresh = crossedActivationHistoricalOwnerRefresh() {
            reverseIndexOwnerRefreshWitness = historicalRefresh
            refresh = historicalRefresh
        }
        guard let refresh,
              refresh.cols == buf.cols,
              refresh.rows == buf.rows,
              refresh.isAlternateBuffer == isAlternateBuffer else {
            return false
        }
        let crossedActivation =
            refresh.activationSerial != bufferActivationSerial
        if crossedActivation,
           !crossedActivationAllowsReverseIndexOwnerRefresh(refresh) {
            expireCrossedReverseIndexOwnerRefresh()
            return false
        }
        guard let line = buf.line(absolute: refresh.absoluteRow),
              line === refresh.line,
              refresh.leadColumn >= 0,
              refresh.leadColumn < line.count else {
            if crossedActivation {
                expireCrossedReverseIndexOwnerRefresh()
            }
            return false
        }
        let cell = line[refresh.leadColumn]
        guard cell.scalar == refresh.scalar,
              cell.width == refresh.width,
              cell.clusterExtras == refresh.clusterExtras,
              let scalar = UnicodeScalar(cell.scalar) else {
            if crossedActivation {
                expireCrossedReverseIndexOwnerRefresh()
            }
            return false
        }

        backwardColumnAttachmentWitness = nil
        lastPrintedScalar = scalar
        presentationSelectorAuthority = refresh.selectorAuthority
        lastWrite = (
            row: refresh.absoluteRow,
            x: refresh.leadColumn,
            cols: buf.cols,
            rows: buf.rows)
        lastWriteDisplacedCell = nil
        lastPrintWrappedFromRightOfMargin = false
        lastPrintAdvancedToFreshRow = false
        lastPrintAdvancedFromCurrentPendingOwner = false
        selectorOwnerAdvancedByRelativeMotion =
            refresh.selectorOwnerAdvancedByRelativeMotion
        selectorRelocationTracksWidthChange =
            refresh.selectorRelocationTracksWidthChange ||
            refresh.absoluteRow != buf.yBase + buf.y
        selectorExpansionSettledPhysicalPending = nil
        pendingWrapOwnerWitness = nil
        rebaseActiveReverseIndexOwnerRefreshWitness(
            allowCrossActivation: true)
        return true
    }

    private func refreshOwnerAfterTopReverseIndex(
        _ refresh: ReverseIndexOwnerRefresh
    ) {
        let buf = buffer
        guard let line = buf.line(absolute: refresh.absoluteRow),
              refresh.leadColumn >= 0,
              refresh.leadColumn < line.count else {
            return
        }
        let cell = line[refresh.leadColumn]
        guard cell.width > 0, cell.scalar != 0 else {
            return
        }
        let contentChanged = cell.scalar != refresh.scalar ||
            cell.width != refresh.width ||
            cell.clusterExtras != refresh.clusterExtras
        guard contentChanged,
              let scalar = UnicodeScalar(cell.scalar) else { return }

        backwardColumnAttachmentWitness = nil
        lastPrintedScalar = scalar
        presentationSelectorAuthority = Self.selectorAuthority(for: cell)
        lastWrite = (
            row: refresh.absoluteRow,
            x: refresh.leadColumn,
            cols: buf.cols,
            rows: buf.rows)
        lastWriteDisplacedCell = nil
        lastPrintWrappedFromRightOfMargin = false
        lastPrintAdvancedToFreshRow = false
        lastPrintAdvancedFromCurrentPendingOwner = false
        selectorOwnerAdvancedByRelativeMotion = false
        selectorRelocationTracksWidthChange =
            refresh.absoluteRow != buf.yBase + buf.y
        selectorExpansionSettledPhysicalPending = nil
        pendingWrapOwnerWitness = nil
        let tracksWidthChange =
            refresh.absoluteRow != buf.yBase + buf.y
        reverseIndexOwnerRefreshWitness = reverseIndexOwnerRefreshSnapshot(
            absoluteRow: refresh.absoluteRow,
            leadColumn: refresh.leadColumn,
            line: line,
            cell: cell,
            selectorAuthority: Self.selectorAuthority(for: cell),
            selectorOwnerAdvancedByRelativeMotion: false,
            selectorRelocationTracksWidthChange: tracksWidthChange)
    }

    private struct ForwardLineScrollOwner {
        let absoluteRow: Int
        let visibleRow: Int
        let leadColumn: Int
        let cell: Cell
        let cols: Int
        let rows: Int
        let isAlternateBuffer: Bool
    }

    private func forwardLineScrollOwnerCandidate()
        -> ForwardLineScrollOwner?
    {
        let buf = buffer
        guard let cluster = validatedLastCluster() else { return nil }
        return ForwardLineScrollOwner(
            absoluteRow: lastWrite.row,
            visibleRow: cluster.row,
            leadColumn: cluster.leadColumn,
            cell: cluster.cell,
            cols: buf.cols,
            rows: buf.rows,
            isAlternateBuffer: isAlternateBuffer)
    }

    private func refreshOwnerAfterForwardLineScroll(
        _ owner: ForwardLineScrollOwner
    ) {
        let buf = buffer
        let columns = hasNarrowMargins
            ? buf.marginLeft...buf.marginRight
            : 0...(buf.cols - 1)
        guard owner.cols == buf.cols,
              owner.rows == buf.rows,
              owner.isAlternateBuffer == isAlternateBuffer,
              (buf.scrollTop...buf.scrollBottom).contains(owner.visibleRow),
              columns.contains(owner.leadColumn),
              let line = buf.line(absolute: owner.absoluteRow),
              owner.leadColumn >= 0,
              owner.leadColumn < line.count else {
            return
        }
        let cell = line[owner.leadColumn]
        if !isAlternateBuffer, cell.width == 0 {
            invalidateClusterContinuation()
            return
        }
        let contentChanged = cell.scalar != owner.cell.scalar ||
            cell.width != owner.cell.width ||
            cell.clusterExtras != owner.cell.clusterExtras
        // A normal-buffer row rotation replaces the semantic owner at this
        // coordinate even when the incoming lead is byte-identical. Rebind
        // it so a later presentation-width change follows the scrolled
        // cursor trajectory. Alternate-buffer rotations retain their prior
        // content-identity behavior.
        guard (contentChanged || !isAlternateBuffer),
              cell.width > 0,
              cell.scalar != 0,
              let scalar = UnicodeScalar(cell.scalar) else {
            return
        }

        clearActiveReverseIndexOwnerRefreshWitness()
        backwardColumnAttachmentWitness = nil
        lastPrintedScalar = scalar
        presentationSelectorAuthority = Self.selectorAuthority(for: cell)
        lastWrite = (
            row: owner.absoluteRow, x: owner.leadColumn,
            cols: buf.cols, rows: buf.rows)
        lastWriteDisplacedCell = nil
        lastPrintWrappedFromRightOfMargin = false
        lastPrintAdvancedToFreshRow = false
        lastPrintAdvancedFromCurrentPendingOwner = false
        let cursorAbsoluteRow = buf.yBase + buf.y
        let cursorBeyondOwner = cursorAbsoluteRow == owner.absoluteRow &&
            buf.x > owner.leadColumn + Int(cell.width)
        selectorOwnerAdvancedByRelativeMotion = cursorBeyondOwner
        selectorRelocationTracksWidthChange =
            cursorAbsoluteRow != owner.absoluteRow || cursorBeyondOwner
        selectorExpansionSettledPhysicalPending = nil
        pendingWrapOwnerWitness = nil
    }

    /// IL leaves a coordinate dormant when its prior owner is shifted away
    /// and the inserted row exposes a blank.  Only a later upward row
    /// rotation can reactivate that coordinate.  Adopt whichever real lead
    /// the rotation brings back; cursor-only and horizontal operations leave
    /// the dormant witness inert.
    func refreshInsertLineOwnerAfterUpwardLineRotation() {
        let buf = buffer
        guard let witness = insertLineOwnerRefreshWitness,
              witness.cols == buf.cols,
              witness.rows == buf.rows,
              witness.isAlternateBuffer == isAlternateBuffer,
              let line = buf.line(absolute: witness.absoluteRow),
              witness.leadColumn >= 0,
              witness.leadColumn < line.count else {
            return
        }
        let cell = line[witness.leadColumn]
        guard cell.width > 0, cell.scalar != 0,
              let scalar = UnicodeScalar(cell.scalar) else { return }

        clearActiveReverseIndexOwnerRefreshWitness()
        backwardColumnAttachmentWitness = nil
        lastPrintedScalar = scalar
        presentationSelectorAuthority = Self.selectorAuthority(for: cell)
        lastWrite = (
            row: witness.absoluteRow, x: witness.leadColumn,
            cols: buf.cols, rows: buf.rows)
        lastWriteDisplacedCell = nil
        lastPrintWrappedFromRightOfMargin = false
        lastPrintAdvancedToFreshRow = false
        lastPrintAdvancedFromCurrentPendingOwner = false
        let cursorAbsoluteRow = buf.yBase + buf.y
        let cursorBeyondOwner = cursorAbsoluteRow == witness.absoluteRow &&
            buf.x > witness.leadColumn + Int(cell.width)
        selectorOwnerAdvancedByRelativeMotion = cursorBeyondOwner
        selectorRelocationTracksWidthChange =
            cursorAbsoluteRow != witness.absoluteRow || cursorBeyondOwner
        selectorExpansionSettledPhysicalPending = nil
        pendingWrapOwnerWitness = nil
    }

    private func consumeLineMotionEdgeState(normalizePhysicalColumn: Bool) {
        let buf = buffer
        if normalizePhysicalColumn, buf.x >= buf.cols {
            buf.x = buf.cols - 1
        }
        buf.wrapPending = false
        noWrapParkedAfterPrint = false
    }

    func lineFeed() {
        let buf = buffer
        let oldAbsoluteRow = buf.yBase + buf.y
        let owner = forwardLineScrollOwnerCandidate()
        var scrolled = false
        // LF deliberately tests the raw pending/parked column.  A physical
        // one-past-edge cursor is outside the stored horizontal gate even
        // though it is normalized after the operation.
        let eligibleAtRawColumn =
            (buf.marginLeft...buf.marginRight).contains(buf.x)

        preservingLineMotionClusterState {
            if buf.y == buf.scrollBottom {
                if eligibleAtRawColumn {
                    scrolled = true
                    engineScrollUp(hardenPrewrappedDestinations: true)
                }
            } else if buf.y < buf.rows - 1 {
                buf.y += 1
            }
        }

        consumeLineMotionEdgeState(normalizePhysicalColumn: true)
        recordSelectorOwnerVerticalMotion(from: oldAbsoluteRow)
        if scrolled, let owner {
            refreshOwnerAfterForwardLineScroll(owner)
        } else if scrolled {
            refreshInsertLineOwnerAfterUpwardLineRotation()
        }
        markDirty(absoluteRow: oldAbsoluteRow)
        markDirty(absoluteRow: buf.yBase + buf.y)
    }

    func indexLineFeed() {
        let buf = buffer
        if originMode {
            buf.y = min(buf.scrollBottom, max(buf.scrollTop, buf.y))
        }
        let oldAbsoluteRow = buf.yBase + buf.y
        let owner = forwardLineScrollOwnerCandidate()
        var scrolled = false
        // IND normalizes before applying the stored-margin gate.  Stored
        // margins remain the gate while DECLRMM is hidden; engineScrollUp()
        // then chooses stored columns (active) or full physical rows (hidden).
        consumeLineMotionEdgeState(normalizePhysicalColumn: true)
        let eligible = (buf.marginLeft...buf.marginRight).contains(buf.x)

        preservingLineMotionClusterState {
            if buf.y >= buf.scrollBottom {
                if eligible {
                    scrolled = true
                    engineScrollUp(hardenPrewrappedDestinations: true)
                }
            } else {
                buf.y += 1
            }
        }

        recordSelectorOwnerVerticalMotion(from: oldAbsoluteRow)
        if scrolled, let owner {
            refreshOwnerAfterForwardLineScroll(owner)
        } else if scrolled {
            refreshInsertLineOwnerAfterUpwardLineRotation()
        }
        markDirty(absoluteRow: oldAbsoluteRow)
        markDirty(absoluteRow: buf.yBase + buf.y)
    }

    private func advanceOneRow() {
        let buf = buffer
        let oldRow = buf.y

        if buf.y == buf.scrollBottom {
            engineScrollUp()
            buf.y = buf.scrollBottom
        } else if buf.y < buf.rows - 1 {
            buf.y += 1
        }

        buf.wrapPending = false
        invalidateClusterContinuation()
        markDirty(absoluteRow: buf.yBase + oldRow)
        markDirty(absoluteRow: buf.yBase + buf.y)
    }

    func reverseLineFeed() {
        let buf = buffer
        if originMode {
            buf.y = min(buf.scrollBottom, max(buf.scrollTop, buf.y))
        }
        let oldAbsoluteRow = buf.yBase + buf.y
        // RI, like IND, normalizes before checking the persistent stored
        // horizontal gate.  Only an exact scroll-top cursor invokes the
        // reverse rectangle transform; rows below it simply move upward.
        consumeLineMotionEdgeState(normalizePhysicalColumn: true)
        let eligible = (buf.marginLeft...buf.marginRight).contains(buf.x)
        var ownerRefresh: ReverseIndexOwnerRefresh?

        preservingLineMotionClusterState {
            if buf.y == buf.scrollTop {
                if eligible {
                    ownerRefresh = reverseIndexOwnerRefreshCandidate()
                    engineScrollDown(hardenPrewrappedDestinations: true)
                }
            } else if buf.y > 0 {
                buf.y -= 1
            }
        }
        recordSelectorOwnerVerticalMotion(from: oldAbsoluteRow)
        if let ownerRefresh {
            refreshOwnerAfterTopReverseIndex(ownerRefresh)
        }
        markDirty(absoluteRow: oldAbsoluteRow)
        markDirty(absoluteRow: buf.yBase + buf.y)
    }

}

public enum TermCursorShape: Equatable, Sendable {
    case blinkBlock, steadyBlock, blinkUnderline, steadyUnderline, blinkBar, steadyBar
}

/// Mouse tracking modes, ordered by capability.
public enum MouseMode: Equatable, Sendable, CustomStringConvertible {
    case off
    case x10               // ?9 press only
    case vt200             // ?1000 press+release
    case buttonEvent       // ?1002 + drag
    case anyEvent          // ?1003 + motion
    public var description: String {
        switch self {
        case .off: return "off"
        case .x10: return "x10"
        case .vt200: return "vt200"
        case .buttonEvent: return "buttonEventTracking"
        case .anyEvent: return "anyEvent"
        }
    }
}

public enum MouseProtocolEncoding: Equatable, Sendable {
    case x10               // legacy bytes
    case utf8              // ?1005
    case sgr               // ?1006
    case urxvt             // ?1015
}

extension CmdyTerminal {
    /// Raw line access for the differential harness and adapters.
    public func lineForDiff(absolute row: Int) -> Line? {
        buffer.line(absolute: row)
    }
}

// MARK: - Surface-facing snapshot + damage helpers

/// The grid scalars a renderer needs per pass, engine-native (the surface
/// converts to its renderer's type — Core stays render-agnostic).
public struct CoreGridSnapshot: Sendable {
    public let rows: Int
    public let cols: Int
    public let bufferLineCount: Int
    /// Cumulative rows discarded before local buffer row 0. Local engine
    /// coordinates still rebase; renderers can add this to obtain a stable row.
    public let retainedRowOrigin: Int
    public let displayTopRow: Int
    public let liveTopRow: Int
    public let cursorRow: Int
    public let cursorCol: Int
    public let cursorHidden: Bool
    public let cursorStyle: TermCursorShape
    public let isAlternateBuffer: Bool
}

/// Immutable row data published from a terminal worker to a renderer. Cells
/// are value types, so taking this copy detaches subsequent parser mutations
/// through Swift's copy-on-write storage.
public struct CoreLineSnapshot: Sendable {
    public let cells: [Cell]
    public let isWrapped: Bool
    public let renderMode: LineRenderMode
    public let images: [CoreLineImageSnapshot]
    public let version: UInt64

    public init(cells: [Cell], isWrapped: Bool, renderMode: LineRenderMode,
                images: [CoreLineImageSnapshot], version: UInt64) {
        self.cells = cells
        self.isWrapped = isWrapped
        self.renderMode = renderMode
        self.images = images
        self.version = version
    }
}

/// Immutable form of a line image. `LineImage` itself is mutable during
/// reflow, so renderer snapshots must not retain the live object.
public struct CoreLineImageSnapshot: Sendable {
    public let renderIdentity: UUID
    public let payload: LineImage.Payload
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let col: Int
    public let kittyIsKitty: Bool
    public let kittyImageId: UInt32?
    public let kittyPlacementId: UInt32?
    public let kittyZIndex: Int
    public let kittyPixelOffsetX: Int
    public let kittyPixelOffsetY: Int

    public init(renderIdentity: UUID, payload: LineImage.Payload,
                pixelWidth: Int, pixelHeight: Int,
                col: Int, kittyIsKitty: Bool, kittyImageId: UInt32?,
                kittyPlacementId: UInt32?, kittyZIndex: Int,
                kittyPixelOffsetX: Int, kittyPixelOffsetY: Int) {
        self.renderIdentity = renderIdentity
        self.payload = payload
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.col = col
        self.kittyIsKitty = kittyIsKitty
        self.kittyImageId = kittyImageId
        self.kittyPlacementId = kittyPlacementId
        self.kittyZIndex = kittyZIndex
        self.kittyPixelOffsetX = kittyPixelOffsetX
        self.kittyPixelOffsetY = kittyPixelOffsetY
    }
}

public struct CoreKittyPlacementSnapshot: Sendable {
    public let imageId: UInt32
    public let placementId: UInt32
    public let col: Int
    public let row: Int
    public let cols: Int
    public let rows: Int
    public let zIndex: Int
    public let pixelOffsetX: Int
    public let pixelOffsetY: Int
    public let isVirtual: Bool
    public let isAlternateBuffer: Bool
}

public struct CoreKittyImageSnapshot: Sendable {
    public let id: UInt32
    public let payload: LineImage.Payload
    public let pixelWidth: Int
    public let pixelHeight: Int
}

/// Everything a frame and the input router need from one coherent parser
/// generation. Only a bounded window around the viewport is copied; search,
/// block export, and other cold whole-buffer operations stay on the model
/// queue.
public struct CoreTerminalSnapshot: Sendable {
    public let grid: CoreGridSnapshot
    public let firstLineRow: Int
    public let lines: [CoreLineSnapshot]
    public let dirtyRows: ClosedRange<Int>?

    public let applicationCursorKeys: Bool
    public let bracketedPaste: Bool
    public let focusReporting: Bool
    public let mouseMode: MouseMode
    public let mouseProtocol: MouseProtocolEncoding
    public let kittyKeyboardFlags: Int

    public let kittyPlacements: [CoreKittyPlacementSnapshot]
    public let kittyImages: [UInt32: CoreKittyImageSnapshot]
    public let kittyNextImageId: UInt32
    public let kittyNextPlacementId: UInt32

    public func line(absolute row: Int) -> CoreLineSnapshot? {
        let index = row - firstLineRow
        return index >= 0 && index < lines.count ? lines[index] : nil
    }
}

extension CmdyTerminal {
    public func captureCoreGrid() -> CoreGridSnapshot {
        let buf = buffer
        return CoreGridSnapshot(rows: buf.rows,
                                cols: buf.cols,
                                bufferLineCount: buf.lineCount,
                                retainedRowOrigin: buf.droppedLines,
                                displayTopRow: buf.yDisp,
                                liveTopRow: buf.yBase,
                                cursorRow: buf.yBase + buf.y,
                                cursorCol: buf.x,
                                cursorHidden: cursorHidden,
                                cursorStyle: cursorStyle,
                                isAlternateBuffer: isAlternateBuffer)
    }

    /// Capture a coherent, immutable viewport for publication to another
    /// thread. The extra screen above and below covers row-cache retention and
    /// the renderer's smooth-scroll fringe without copying the full history.
    public func captureTerminalSnapshot(extraScreens: Int = 1,
                                        consumeDamage: Bool = true) -> CoreTerminalSnapshot {
        let grid = captureCoreGrid()
        let fringe = max(0, grid.rows * extraScreens)
        let first = max(0, grid.displayTopRow - fringe)
        let last = min(grid.bufferLineCount - 1,
                       grid.displayTopRow + grid.rows - 1 + fringe)
        var capturedLines: [CoreLineSnapshot] = []
        if first <= last {
            capturedLines.reserveCapacity(last - first + 1)
            for row in first...last {
                guard let line = buffer.line(absolute: row) else { continue }
                let images = (line.images ?? []).map { image in
                    CoreLineImageSnapshot(renderIdentity: image.renderIdentity,
                                          payload: image.payload,
                                          pixelWidth: image.pixelWidth,
                                          pixelHeight: image.pixelHeight,
                                          col: image.col,
                                          kittyIsKitty: image.kittyIsKitty,
                                          kittyImageId: image.kittyImageId,
                                          kittyPlacementId: image.kittyPlacementId,
                                          kittyZIndex: image.kittyZIndex,
                                          kittyPixelOffsetX: image.kittyPixelOffsetX,
                                          kittyPixelOffsetY: image.kittyPixelOffsetY)
                }
                capturedLines.append(CoreLineSnapshot(cells: line.cells,
                                                      isWrapped: line.isWrapped,
                                                      renderMode: line.renderMode,
                                                      images: images,
                                                      version: line.version))
            }
        }

        let placements = kittyGraphics.placementsByKey.values.map { placement in
            CoreKittyPlacementSnapshot(imageId: placement.imageId,
                                       placementId: placement.placementId,
                                       col: placement.col,
                                       row: placement.row,
                                       cols: placement.cols,
                                       rows: placement.rows,
                                       zIndex: placement.zIndex,
                                       pixelOffsetX: placement.pixelOffsetX,
                                       pixelOffsetY: placement.pixelOffsetY,
                                       isVirtual: placement.isVirtual,
                                       isAlternateBuffer: placement.isAlternateBuffer)
        }
        let images = kittyGraphics.imagesById.mapValues { image in
            CoreKittyImageSnapshot(id: image.id,
                                   payload: image.payload,
                                   pixelWidth: image.pixelWidth,
                                   pixelHeight: image.pixelHeight)
        }
        return CoreTerminalSnapshot(
            grid: grid,
            firstLineRow: first,
            lines: capturedLines,
            dirtyRows: consumeDamage ? consumeDirtyRows() : dirtyRowSpan,
            applicationCursorKeys: applicationCursorKeys,
            bracketedPaste: bracketedPaste,
            focusReporting: focusReporting,
            mouseMode: mouseMode,
            mouseProtocol: mouseProtocol,
            kittyKeyboardFlags: kittyKeyboardFlags,
            kittyPlacements: placements,
            kittyImages: images,
            kittyNextImageId: kittyGraphics.nextImageId,
            kittyNextPlacementId: kittyGraphics.nextPlacementId)
    }

    /// The host wants a full repaint (theme flip, wake from occlusion).
    public func markViewportDirty() {
        markAllDirty()
    }
}
