import Foundation
import CmdyNative

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


/// Native macOS-facing facade. Parsing, terminal state and storage live in Zig.
public final class CmdyTerminal: VTParserDelegate {
    let nativeOwner: NativeEngineOwner
    let normalBuffer: ScreenBuffer
    let altBuffer: ScreenBuffer
    let parser: VTParser
    public let blocks: BlockTracker
    public let kittyGraphics: KittyGraphicsStore
    public weak var delegate: CmdyTerminalDelegate?
    var oscHandlers: [Int: (ArraySlice<UInt8>) -> Void] = [:]
    var commandFinishedHostMessageProvider: ((String, String, Int32?) -> String?)?
    public internal(set) var recorder: SessionRecorder? {
        didSet { setNativeInt(17, recorder == nil ? 0 : 1) }
    }
    var buffer: ScreenBuffer { isAlternateBuffer ? altBuffer : normalBuffer }
    private var handle: OpaquePointer { nativeOwner.handle }
    private func nativeInt(_ field: UInt32) -> Int { cmdy_zig_terminal_get_int(handle, field) }
    private func setNativeInt(_ field: UInt32, _ value: Int) { checkedNative(cmdy_zig_terminal_set_int(handle, field, value)) }

    public init(cols: Int, rows: Int, scrollback: Int = 10_000) {
        let owner = NativeEngineOwner(cols: cols, rows: rows, scrollback: scrollback)
        nativeOwner = owner
        normalBuffer = ScreenBuffer(native: OpaquePointer(cmdy_zig_terminal_buffer(owner.handle, 1)!), owner: owner)
        altBuffer = ScreenBuffer(native: OpaquePointer(cmdy_zig_terminal_buffer(owner.handle, 2)!), owner: owner)
        parser = VTParser(native: OpaquePointer(cmdy_zig_terminal_parser(owner.handle)!), owner: owner)
        blocks = BlockTracker(native: OpaquePointer(cmdy_zig_terminal_blocks(owner.handle)!), owner: owner)
        kittyGraphics = KittyGraphicsStore(native: OpaquePointer(cmdy_zig_terminal_graphics(owner.handle)!), owner: owner)
        parser.delegate = self
        parser.onDelegateChanged = { [weak self] parser in
            guard let self else { return }
            var route = CmdyZigParserDelegateRoute(context: parser.nativeContext,
                event: VTParser.nativeCallback, use_external: parser.delegate === self ? 0 : 1)
            checkedNative(cmdy_zig_terminal_set_parser_delegate(self.handle, &route))
        }
        var host = CmdyZigHost(context: Unmanaged.passUnretained(self).toOpaque(), event: { context, event in
            guard let context, let event else { return }
            let terminal = Unmanaged<CmdyTerminal>.fromOpaque(context).takeUnretainedValue()
            terminal.receive(event.pointee)
        }, now: { context in
            guard let context else { return 0 }
            let terminal = Unmanaged<CmdyTerminal>.fromOpaque(context).takeUnretainedValue()
            return terminal.delegate?.now(terminal) ?? 0
        })
        checkedNative(cmdy_zig_terminal_set_host(owner.handle, &host))
    }

    deinit {
        checkedNative(cmdy_zig_terminal_set_host(handle, nil))
        checkedNative(cmdy_zig_terminal_set_parser_delegate(handle, nil))
    }

    /// Representation-only work for an idle serial owner. It changes neither
    /// terminal contents nor revisions and does not publish a new frame.
    @_spi(CmdyApp)
    public func compactHistory(startingAt absoluteRow: Int, maximumRows: Int)
        -> (nextAbsoluteRow: Int, visited: Int, compacted: Int, complete: Bool) {
        var result = CmdyZigHistoryMaintenance()
        checkedNative(cmdy_zig_buffer_compact_history(
            OpaquePointer(cmdy_zig_terminal_buffer(handle, 1)!), absoluteRow, max(0, maximumRows), &result))
        return (result.next_absolute_row, result.visited, result.compacted, result.complete != 0)
    }

    private static func bytes(_ pointer: UnsafePointer<UInt8>?, _ count: Int) -> [UInt8] {
        guard count > 0, let pointer else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }
    private func receive(_ event: CmdyZigEvent) {
        let bytes = Self.bytes(event.bytes, event.length)
        switch event.kind {
        case 1: delegate?.send(self, data: bytes[...])
        case 2: delegate?.setTitle(self, title: String(decoding: bytes, as: UTF8.self))
        case 3: delegate?.setCurrentDirectory(self, directory: event.bytes == nil ? nil : String(decoding: bytes, as: UTF8.self))
        case 4: delegate?.bell(self)
        case 5: delegate?.clipboardCopy(self, content: Data(bytes))
        case 6: delegate?.contentChanged(self)
        case 7: delegate?.willReflow(self)
        case 8: delegate?.didReflow(self)
        case 9: delegate?.notify(self, title: String(decoding: bytes, as: UTF8.self),
                                body: String(decoding: Self.bytes(event.bytes2, event.length2), as: UTF8.self))
        case 10: oscHandlers[event.argument]?(bytes[...])
        case 11: blocks.publishNativeChange()
        case 12:
            if let object = event.object { blocks.publishNativeCommandFinished(native: OpaquePointer(object)) }
        case 13: recorder?.record(bytes[...])
        case 14:
            if let provider = commandFinishedHostMessageProvider,
               let message = provider(String(decoding: bytes, as: UTF8.self),
                    String(decoding: Self.bytes(event.bytes2, event.length2), as: UTF8.self), Int32(event.argument)) {
                insertHostMessage(message)
            }
        default: break
        }
    }
    public internal(set) var isAlternateBuffer: Bool {
        get { nativeInt(1) != 0 }
        set { setNativeInt(1, newValue ? 1 : 0) }
    }
    public internal(set) var applicationCursorKeys: Bool {
        get { nativeInt(2) != 0 }
        set { setNativeInt(2, newValue ? 1 : 0) }
    }
    public internal(set) var originMode: Bool {
        get { nativeInt(3) != 0 }
        set { setNativeInt(3, newValue ? 1 : 0) }
    }
    public private(set) var autoWrap: Bool {
        get { nativeInt(4) != 0 }
        set { setNativeInt(4, newValue ? 1 : 0) }
    }
    public private(set) var insertMode: Bool {
        get { nativeInt(5) != 0 }
        set { setNativeInt(5, newValue ? 1 : 0) }
    }
    public internal(set) var lineFeedMode: Bool {
        get { nativeInt(6) != 0 }
        set { setNativeInt(6, newValue ? 1 : 0) }
    }
    public internal(set) var cursorHidden: Bool {
        get { nativeInt(7) != 0 }
        set { setNativeInt(7, newValue ? 1 : 0) }
    }
    public internal(set) var reverseVideo: Bool {
        get { nativeInt(8) != 0 }
        set { setNativeInt(8, newValue ? 1 : 0) }
    }
    public internal(set) var bracketedPaste: Bool {
        get { nativeInt(9) != 0 }
        set { setNativeInt(9, newValue ? 1 : 0) }
    }
    public internal(set) var focusReporting: Bool {
        get { nativeInt(10) != 0 }
        set { setNativeInt(10, newValue ? 1 : 0) }
    }
    public internal(set) var cursorBlink: Bool {
        get { nativeInt(11) != 0 }
        set { setNativeInt(11, newValue ? 1 : 0) }
    }
    public internal(set) var synchronizedUpdates: Bool {
        get { nativeInt(12) != 0 }
        set { setNativeInt(12, newValue ? 1 : 0) }
    }
    public internal(set) var allow80To132: Bool {
        get { nativeInt(13) != 0 }
        set { setNativeInt(13, newValue ? 1 : 0) }
    }
    public private(set) var marginMode: Bool {
        get { nativeInt(14) != 0 }
        set { setNativeInt(14, newValue ? 1 : 0) }
    }
    public internal(set) var reverseWraparound: Bool {
        get { nativeInt(15) != 0 }
        set { setNativeInt(15, newValue ? 1 : 0) }
    }

    public internal(set) var currentAttribute: CellAttribute {
        get { var value = CmdyZigCell(); cmdy_zig_terminal_get_pen(handle, &value); return swiftAttribute(value) }
        set { var value = nativeCell(Cell(attribute: newValue)); checkedNative(cmdy_zig_terminal_set_pen(handle, &value)) }
    }
    var eraseAttribute: CellAttribute { CellAttribute(fg: .defaultColor, bg: currentAttribute.bg) }
    var usingMargins: Bool { originMode && marginMode }
    var activeLinkId: UInt16 {
        get { UInt16(nativeInt(22)) }
        set { setNativeInt(22, Int(newValue)) }
    }
    var glLevel: Int { get { nativeInt(18) } set { setNativeInt(18, newValue) } }
    var blocksDroppedLineCheckpoint: Int { get { nativeInt(24) } set { setNativeInt(24, newValue) } }
    public var kittyKeyboardFlags: Int { nativeInt(23) }
    public internal(set) var cursorStyle: TermCursorShape {
        get { Self.cursorShapes[nativeInt(19)] }
        set { setNativeInt(19, Self.cursorShapes.firstIndex(of: newValue)!) }
    }
    public internal(set) var mouseMode: MouseMode {
        get { Self.mouseModes[nativeInt(20)] }
        set { setNativeInt(20, Self.mouseModes.firstIndex(of: newValue)!) }
    }
    public internal(set) var mouseProtocol: MouseProtocolEncoding {
        get { Self.mouseProtocols[nativeInt(21)] }
        set { setNativeInt(21, Self.mouseProtocols.firstIndex(of: newValue)!) }
    }
    private static let cursorShapes: [TermCursorShape] = [.blinkBlock, .steadyBlock, .blinkUnderline, .steadyUnderline, .blinkBar, .steadyBar]
    private static let mouseModes: [MouseMode] = [.off, .x10, .vt200, .buttonEvent, .anyEvent]
    private static let mouseProtocols: [MouseProtocolEncoding] = [.x10, .utf8, .sgr, .urxvt]
    public internal(set) var title: String {
        get { var count = 0; let ptr = cmdy_zig_terminal_title(handle, &count); return String(decoding: Self.bytes(ptr, count), as: UTF8.self) }
        set { Array(newValue.utf8).withUnsafeBufferPointer { checkedNative(cmdy_zig_terminal_set_title(handle, $0.baseAddress, $0.count)) } }
    }
    func setAutoWrapMode(_ enabled: Bool) { autoWrap = enabled }
    func setInsertMode(_ enabled: Bool) { insertMode = enabled }
    func setMarginMode(_ enabled: Bool) { marginMode = enabled }
    public func setCursorStyle(_ style: TermCursorShape) { cursorStyle = style }
    var lastPrintedScalar: UnicodeScalar? {
        let scalar = nativeInt(28)
        return scalar < 0 ? nil : UnicodeScalar(UInt32(scalar))
    }
    var lastWrite: (row: Int, x: Int, cols: Int, rows: Int) {
        (nativeInt(29), nativeInt(30), nativeInt(31), nativeInt(32))
    }
    var noWrapParkedAfterPrint: Bool { nativeInt(33) != 0 }
    var pendingCursorUpMoved: Bool { nativeInt(34) != 0 }
    var linkTable: [String] { (0..<nativeInt(35)).map { linkURI(id: UInt16($0 + 1)) ?? "" } }
    var decrqssBuffer: [UInt8] {
        var count = 0
        let bytes = cmdy_zig_terminal_decrqss(handle, &count)
        return Self.bytes(bytes, count)
    }
    static let stubAttribute = CellAttribute(fg: .defaultColor, bg: .defaultInverted)
    func emojiPropertyForClustering(_ scalar: UnicodeScalar) -> Bool {
        cmdy_zig_scalar_property(scalar.value, 3) != 0
    }

    public func feed(_ bytes: ArraySlice<UInt8>) {
        withExtendedLifetime(self) {
            bytes.withUnsafeBufferPointer { checkedNative(cmdy_zig_terminal_feed(handle, $0.baseAddress, $0.count)) }
        }
    }
    public func feed(_ bytes: [UInt8]) { feed(bytes[...]) }
    public func feed(text: String) { feed(Array(text.utf8)) }
    public func insertHostMessage(_ text: String) {
        Array(text.utf8).withUnsafeBufferPointer { checkedNative(cmdy_zig_terminal_host_message(handle, $0.baseAddress, $0.count)) }
    }
    public func resize(cols: Int, rows: Int) { checkedNative(cmdy_zig_terminal_resize(handle, cols, rows)) }
    public func startRecording(_ recorder: SessionRecorder) { self.recorder = recorder }
    public func setCommandFinishedHostMessageProvider(_ provider: ((String, String, Int32?) -> String?)?) {
        commandFinishedHostMessageProvider = provider
        setNativeInt(27, provider == nil ? 0 : 1)
    }
    public func registerOscHandler(code: Int, handler: @escaping (ArraySlice<UInt8>) -> Void) { oscHandlers[code] = handler }
    public func linkURI(id: UInt16) -> String? {
        var count = 0
        guard let ptr = cmdy_zig_terminal_link(handle, id, &count) else { return nil }
        return String(decoding: Self.bytes(ptr, count), as: UTF8.self)
    }
    public var cols: Int { buffer.cols }
    public var rows: Int { buffer.rows }
    public var bufferLineCount: Int { buffer.lineCount }
    public var currentTopRow: Int { buffer.yDisp }
    public var liveScreenTopRow: Int { buffer.yBase }
    public var scrollbackDroppedLines: Int { normalBuffer.droppedLines }
    public var scrollInvariantCursorRow: Int { buffer.yBase + buffer.y }
    public var cursorColumn: Int { buffer.x }
    public var cursorRow: Int { buffer.y }
    public var kittyImageCount: Int { kittyGraphics.imagesById.count }
    public var linesWithImagesCount: Int { buffer.lines.filter { !($0.images?.isEmpty ?? true) }.count }
    public var mouseModeDescription: String { "\(mouseMode)" }
    public func isBufferRowWrapped(_ row: Int) -> Bool { buffer.line(absolute: row)?.isWrapped ?? false }
    public func scrollbackLineText(row: Int) -> String? { buffer.line(absolute: row)?.trimmedText() }
    public func scrollbackLineTexts(rows: ClosedRange<Int>) -> [String] { rows.map { scrollbackLineText(row: $0) ?? "" } }
    public func scrollbackLineText(row: Int, columns: Range<Int>) -> String? {
        guard let line = buffer.line(absolute: row) else { return nil }
        let cells = line.cells
        let lower = max(0, min(columns.lowerBound, cells.count))
        let upper = max(lower, min(columns.upperBound, line.trimmedLength, cells.count))
        var text = ""
        for cell in cells[lower..<upper] where cell.width != 0 { text += cell.scalar == 0 ? " " : cell.text }
        return text
    }
    public func scrollViewport(to row: Int) { checkedNative(cmdy_zig_terminal_scroll_viewport(handle, row)) }
    public func scrollViewport(lines: Int) { scrollViewport(to: buffer.yDisp + lines) }
    public func lineForDiff(absolute row: Int) -> Line? { buffer.line(absolute: row) }
    var dirtyRowSpan: ClosedRange<Int>? {
        get { var value = CmdyZigSpan(); return cmdy_zig_terminal_dirty(handle, 0, &value) == 0 ? nil : value.first...value.last }
        set {
            if let newValue { var span = CmdyZigSpan(first: newValue.lowerBound, last: newValue.upperBound); cmdy_zig_terminal_set_dirty(handle, &span) }
            else { cmdy_zig_terminal_set_dirty(handle, nil) }
        }
    }
    public func consumeDirtyRows() -> ClosedRange<Int>? {
        var value = CmdyZigSpan()
        return cmdy_zig_terminal_dirty(handle, 1, &value) == 0 ? nil : value.first...value.last
    }
    func markDirty(absoluteRow row: Int) {
        dirtyRowSpan = dirtyRowSpan.map { min($0.lowerBound, row)...max($0.upperBound, row) } ?? row...row
    }
    func markDirty(absoluteRows range: ClosedRange<Int>) { markDirty(absoluteRow: range.lowerBound); markDirty(absoluteRow: range.upperBound) }
    func markAllDirty() { cmdy_zig_terminal_mark_viewport(handle) }
    public func markViewportDirty() { markAllDirty() }

    private func dispatch(_ operation: UInt32, argument: Int = 0, params: [Int] = [], collect: [UInt8] = [], bytes: ArraySlice<UInt8> = []) {
        params.withUnsafeBufferPointer { ps in collect.withUnsafeBufferPointer { cs in bytes.withUnsafeBufferPointer { data in
            checkedNative(cmdy_zig_terminal_dispatch(handle, operation, argument, ps.baseAddress, ps.count, cs.baseAddress, cs.count, data.baseAddress, data.count))
        } } }
    }
    public func parserPrint(_ scalar: UnicodeScalar) { dispatch(1, argument: Int(scalar.value)) }
    public func parserPrintASCII(_ bytes: ArraySlice<UInt8>) { dispatch(2, bytes: bytes) }
    public func parserPrintASCIIAndCRLF(_ bytes: ArraySlice<UInt8>) { dispatch(3, bytes: bytes) }
    public func parserPrintASCIILines(_ bytes: ArraySlice<UInt8>) { dispatch(4, bytes: bytes) }
    public func parserExecute(_ byte: UInt8) { dispatch(5, argument: Int(byte)) }
    public func parserCSI(final: UInt8, params: [Int], collect: [UInt8]) { dispatch(6, argument: Int(final), params: params, collect: collect) }
    public func parserESC(final: UInt8, collect: [UInt8]) { dispatch(7, argument: Int(final), collect: collect) }
    public func parserOSC(code: Int, payload: ArraySlice<UInt8>) { dispatch(8, argument: code, bytes: payload) }
    public func parserDCSHook(final: UInt8, params: [Int], collect: [UInt8]) { dispatch(9, argument: Int(final), params: params, collect: collect) }
    public func parserDCSPut(_ bytes: ArraySlice<UInt8>) { dispatch(10, bytes: bytes) }
    public func parserDCSUnhook() { dispatch(11) }
    public func parserAPC(_ bytes: ArraySlice<UInt8>) { dispatch(12, bytes: bytes) }
    func fullReset() { dispatch(13) }
    func softReset() { dispatch(14) }
    func executeControl(_ byte: UInt8) { dispatch(15, argument: Int(byte)) }
    func synchronizeBlockRowsToScrollback() { dispatch(16) }
    func sendResponse(_ text: String) { dispatch(17, bytes: Array(text.utf8)[...]) }
    func parserPrintASCIIWithTransitions(_ bytes: ArraySlice<UInt8>) { dispatch(2, bytes: bytes) }
    func dispatchESC(final: UInt8, collect: [UInt8]) { dispatch(18, argument: Int(final), collect: collect) }
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
        let rowCount = max(0, last - first + 1)
        let nativeRows = NativeSnapshotRows(buffer: buffer.native, first: first, count: rowCount)
        var capturedLines: [CoreLineSnapshot] = []
        capturedLines.reserveCapacity(rowCount)
        for index in 0..<rowCount {
            nativeRows.withLine(at: index) { line in
                let imageCount = max(0, cmdy_zig_line_image_count(line))
                // Reuse the live attachment's existing immutable Swift payload
                // projection. Never install a Swift lifetime observer on the
                // native snapshot's detached image or recopy its pixel bytes.
                let imageSource = imageCount == 0 ? nil : cmdy_zig_buffer_line(buffer.native, first + index)
                defer { if let imageSource { cmdy_zig_line_release(imageSource) } }
                let images = (0..<imageCount).map { index in
                    guard let imageSource,
                          let handle = cmdy_zig_line_image_get(imageSource, index),
                          let frozen = cmdy_zig_line_image_get(line, index) else {
                        preconditionFailure("Missing native image")
                    }
                    defer { cmdy_zig_image_release(frozen) }
                    let image = LineImage.wrapping(retained: handle)
                    var info = CmdyZigImageInfo()
                    checkedNative(cmdy_zig_image_info(frozen, &info))
                    return CoreLineImageSnapshot(renderIdentity: nativeRenderIdentity(high: info.identity_high, low: info.identity_low),
                                          payload: image.payload,
                                          pixelWidth: info.pixel_width,
                                          pixelHeight: info.pixel_height,
                                          col: info.col,
                                          kittyIsKitty: info.is_kitty != 0,
                                          kittyImageId: info.has_image_id == 0 ? nil : info.image_id,
                                          kittyPlacementId: info.has_placement_id == 0 ? nil : info.placement_id,
                                          kittyZIndex: info.z_index,
                                          kittyPixelOffsetX: info.offset_x,
                                          kittyPixelOffsetY: info.offset_y)
                }
                capturedLines.append(CoreLineSnapshot(frozenNativeLine: line, images: images))
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
            nativeRows: nativeRows,
            nativeGraphics: NativeSnapshotGraphics(store: kittyGraphics.native),
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

}
