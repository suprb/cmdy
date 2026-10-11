import Foundation
import CmdyNative

/// A view of the Zig grid and scrollback. Retained rows keep their own native
/// ownership and can outlive this view or the terminal that produced it.
public final class ScreenBuffer {
    let native: OpaquePointer
    private let owner: AnyObject?

    init(native: OpaquePointer, owner: AnyObject) {
        self.native = native
        self.owner = owner
    }

    public init(cols: Int, rows: Int, hasScrollback: Bool, maxScrollback: Int = 10_000) {
        guard let handle = cmdy_zig_buffer_create(cols, rows, hasScrollback ? 1 : 0, maxScrollback) else {
            preconditionFailure("Cannot allocate CMDY native screen")
        }
        native = handle
        owner = nil
    }

    deinit { if owner == nil { cmdy_zig_buffer_free(native) } }

    @inline(__always) private func readField(_ field: UInt32) -> Int {
        cmdy_zig_buffer_get(native, field)
    }
    @inline(__always) private func writeField(_ field: UInt32, _ value: Int) {
        checkedNative(cmdy_zig_buffer_set(native, field, value))
    }
    public var x: Int { get { readField(0) } set { writeField(0, newValue) } }
    public var y: Int { get { readField(1) } set { writeField(1, newValue) } }
    public var yBase: Int { get { readField(2) } set { writeField(2, newValue) } }
    public var yDisp: Int { get { readField(3) } set { writeField(3, newValue) } }
    public var cols: Int { readField(4) }
    public var rows: Int { readField(5) }
    public var maxScrollback: Int { get { readField(6) } set { writeField(6, newValue) } }
    public var scrollTop: Int { get { readField(7) } set { writeField(7, newValue) } }
    public var scrollBottom: Int { get { readField(8) } set { writeField(8, newValue) } }
    public var marginLeft: Int { get { readField(9) } set { writeField(9, newValue) } }
    public var marginRight: Int { get { readField(10) } set { writeField(10, newValue) } }
    public var wrapPending: Bool { get { readField(11) != 0 } set { writeField(11, newValue ? 1 : 0) } }
    public var droppedLines: Int { readField(12) }
    public var hasScrollback: Bool { readField(13) != 0 }
    public var lineCount: Int { readField(14) }
    var backingLineSlotCount: Int { readField(15) }
    var deferredTrimmedLineCount: Int { readField(16) }

    public var lines: [Line] { (0..<lineCount).map { line(absolute: $0)! } }

    public func absoluteRow(_ r: Int) -> Int { yBase + r }
    public func line(absolute row: Int) -> Line? {
        guard let handle = cmdy_zig_buffer_line(native, row) else { return nil }
        return Line.wrapping(retained: handle)
    }
    public func liveLine(_ r: Int) -> Line {
        guard let line = line(absolute: absoluteRow(r)) else {
            preconditionFailure("live row \(r) out of range")
        }
        return line
    }
    func lineAutovivified(absolute row: Int) -> Line? {
        guard let handle = cmdy_zig_buffer_ghost_line(native, row) else { return nil }
        return Line.wrapping(retained: handle)
    }
    var overflowLines: [Int: Line] {
        let count = cmdy_zig_buffer_ghost_keys(native, nil, 0)
        guard count > 0 else { return [:] }
        var keys = [Int](repeating: 0, count: count)
        keys.withUnsafeMutableBufferPointer {
            precondition(cmdy_zig_buffer_ghost_keys(native, $0.baseAddress, $0.count) == count)
        }
        return Dictionary(uniqueKeysWithValues: keys.map { ($0, lineAutovivified(absolute: $0)!) })
    }
    func clearOverflowLines() { cmdy_zig_buffer_clear_ghosts(native) }

    public struct SavedCursor {
        public var x = 0
        public var y = 0
        public var attribute = CellAttribute.empty
        public var wrapPending = false
        public var originMode = false
        public var autoWrap = false
        public var marginMode = false
        public var reverseWraparound = false
    }
    public var savedCursor: SavedCursor? {
        get {
            var value = CmdyZigSavedCursor()
            let status = cmdy_zig_buffer_saved_cursor(native, &value)
            precondition(status >= 0)
            guard status != 0 else { return nil }
            var result = SavedCursor()
            result.x = value.x
            result.y = value.y
            result.attribute = swiftAttribute(value.attribute)
            result.wrapPending = value.wrap_pending != 0
            result.originMode = value.origin_mode != 0
            result.autoWrap = value.auto_wrap != 0
            result.marginMode = value.margin_mode != 0
            result.reverseWraparound = value.reverse_wraparound != 0
            return result
        }
        set {
            guard let cursor = newValue else {
                checkedNative(cmdy_zig_buffer_set_saved_cursor(native, nil))
                return
            }
            var value = CmdyZigSavedCursor()
            value.x = cursor.x
            value.y = cursor.y
            value.attribute = nativeCell(Cell(attribute: cursor.attribute))
            value.wrap_pending = cursor.wrapPending ? 1 : 0
            value.origin_mode = cursor.originMode ? 1 : 0
            value.auto_wrap = cursor.autoWrap ? 1 : 0
            value.margin_mode = cursor.marginMode ? 1 : 0
            value.reverse_wraparound = cursor.reverseWraparound ? 1 : 0
            checkedNative(cmdy_zig_buffer_set_saved_cursor(native, &value))
        }
    }

    public var tabStops: Set<Int> {
        let count = cmdy_zig_buffer_tab_stops(native, nil, 0)
        precondition(count >= 0)
        var values = [Int](repeating: 0, count: count)
        values.withUnsafeMutableBufferPointer {
            precondition(cmdy_zig_buffer_tab_stops(native, $0.baseAddress, $0.count) == count)
        }
        return Set(values)
    }
    public func resetTabStops() { checkedNative(cmdy_zig_buffer_reset_tabs(native)) }
    public func setTabStop(at col: Int) { checkedNative(cmdy_zig_buffer_set_tab(native, col)) }
    public func clearTabStop(at col: Int) { cmdy_zig_buffer_clear_tab(native, col) }
    public func clearAllTabStops() { cmdy_zig_buffer_clear_tabs(native) }
    public func nextTabStop(from col: Int, marginMode: Bool = false) -> Int {
        cmdy_zig_buffer_next_tab(native, col, marginMode ? 1 : 0)
    }
    public func previousTabStop(from col: Int) -> Int { cmdy_zig_buffer_previous_tab(native, col) }

    var canAppendFullScreenScrollbackLine: Bool {
        canScrollFullScreenIntoScrollback && lineCount - rows < maxScrollback
    }
    var canScrollFullScreenIntoScrollback: Bool {
        hasScrollback && scrollTop == 0 && scrollBottom == rows - 1
    }
    func appendFullScreenScrollbackLine(_ line: Line) {
        withExtendedLifetime(line) { checkedNative(cmdy_zig_buffer_append_line(native, line.native)) }
    }
    func scrollUpPopulatedASCII(_ bytes: ArraySlice<UInt8>, fill: Cell,
                                attribute: CellAttribute, linkId: UInt16) {
        precondition(canScrollFullScreenIntoScrollback && bytes.count <= cols)
        scrollUp(fill: fill)
        line(absolute: lineCount - 1)!.writeASCII(bytes, at: 0, attribute: attribute, linkId: linkId)
    }

    private func scroll(_ operation: UInt32, at: Int = 0, count: Int = 1,
                        fill: Cell, wrapped: Bool = false, clear: Bool = true) {
        var value = nativeCell(fill)
        withNativeExtras(fill) {
            checkedNative(cmdy_zig_buffer_scroll(native, operation, at, count, &value, $0, $1, $2,
                                                 wrapped ? 1 : 0, clear ? 1 : 0))
        }
    }
    public func scrollUp(fill: Cell, markNewWrapped: Bool = false, clearRecycledLine: Bool = true) {
        scroll(0, fill: fill, wrapped: markNewWrapped, clear: clearRecycledLine)
    }
    public func scrollUpRegionOnly(fill: Cell) { scroll(1, fill: fill) }
    public func scrollDown(fill: Cell) { scroll(2, fill: fill) }
    public func insertLines(at r: Int, count n: Int, fill: Cell) { scroll(3, at: r, count: n, fill: fill) }
    public func deleteLines(at r: Int, count n: Int, fill: Cell) { scroll(4, at: r, count: n, fill: fill) }
    func hardReset() { checkedNative(cmdy_zig_buffer_reset(native)) }
    public func clearScrollback() { cmdy_zig_buffer_clear_scrollback(native) }
    public func resizeSimple(newCols: Int, newRows: Int, fill: Cell) {
        checkedNative(cmdy_zig_buffer_resize(native, newCols, newRows))
    }
    func replaceLines(_ newLines: [Line]) {
        let handles = newLines.map { Optional($0.native) }
        withExtendedLifetime(newLines) {
            handles.withUnsafeBufferPointer {
                checkedNative(cmdy_zig_buffer_replace_lines(native, $0.baseAddress, $0.count))
            }
        }
    }
    func setGeometry(cols newCols: Int, rows newRows: Int) {
        checkedNative(cmdy_zig_buffer_set_geometry(native, newCols, newRows))
    }
    func noteDropped(_ n: Int) { cmdy_zig_buffer_note_dropped(native, n) }
}
