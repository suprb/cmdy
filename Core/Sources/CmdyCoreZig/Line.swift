import Foundation
import CmdyNative

struct OrdinaryUnicodeCell {
    let scalar: UInt32
    let width: Int8
}

public enum LineRenderMode: Equatable, Sendable {
    case single, doubleWidth, doubledTop, doubledDown
}

@inline(__always) func nativeColor(_ color: CellColor) -> UInt32 {
    switch color {
    case .defaultColor: return 0
    case .defaultInverted: return 0x0300_0000
    case .ansi256(let n): return 0x0100_0000 | UInt32(n)
    case .trueColor(let r, let g, let b):
        return 0x0200_0000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
    }
}

@inline(__always) func swiftColor(_ word: UInt32) -> CellColor {
    switch word >> 24 {
    case 1: return .ansi256(UInt8(truncatingIfNeeded: word))
    case 2:
        return .trueColor(UInt8(truncatingIfNeeded: word >> 16),
                          UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word))
    case 3: return .defaultInverted
    default: return .defaultColor
    }
}

@inline(__always) func nativeCell(_ cell: Cell) -> CmdyZigCell {
    var value = CmdyZigCell()
    value.scalar = cell.scalar
    value.width = cell.width
    value.link_id = cell.linkId
    value.fg = nativeColor(cell.attribute.fg)
    value.bg = nativeColor(cell.attribute.bg)
    value.style = cell.attribute.style.rawValue
    value.underline_kind = cell.attribute.underlineKind.rawValue
    value.underline_present = cell.attribute.underlineColor == nil ? 0 : 1
    value.underline_color = cell.attribute.underlineColor.map(nativeColor) ?? 0
    return value
}

@inline(__always) func swiftAttribute(_ value: CmdyZigCell) -> CellAttribute {
    CellAttribute(fg: swiftColor(value.fg), bg: swiftColor(value.bg),
                  style: CellStyle(rawValue: value.style),
                  underlineKind: UnderlineKind(rawValue: value.underline_kind) ?? .none,
                  underlineColor: value.underline_present == 0 ? nil : swiftColor(value.underline_color))
}

@inline(__always) func swiftCell(_ value: CmdyZigCell, extras: UnsafePointer<UInt32>?,
                                count: Int, present: Bool) -> Cell {
    Cell(scalar: value.scalar,
         clusterExtras: present ? Array(UnsafeBufferPointer(start: extras, count: count)) : nil,
         width: value.width, attribute: swiftAttribute(value), linkId: value.link_id)
}

@inline(__always) func withNativeExtras<T>(_ cell: Cell,
    _ body: (UnsafePointer<UInt32>?, Int, UInt8) -> T) -> T {
    if let extras = cell.clusterExtras {
        return extras.withUnsafeBufferPointer { body($0.baseAddress, $0.count, 1) }
    }
    return body(nil, 0, 0)
}

/// The row's storage, metadata and mutations are owned by the Zig engine.
/// An associated wrapper keeps Swift reference identity while a native owner
/// exists; when that owner disappears, ownership transfers to this wrapper.
public final class Line {
    let native: OpaquePointer
    private var ownsNative = false

    private static let lifetimeCallback: @convention(c) (UnsafeMutableRawPointer?, UInt8) -> Void = { context, event in
        guard let context else { return }
        let reference = Unmanaged<Line>.fromOpaque(context)
        let line = reference.takeUnretainedValue()
        if event == 0 {
            line.ownsNative = true
            reference.release()
        } else {
            _ = reference.retain()
            line.ownsNative = false
        }
    }

    private init(retained native: OpaquePointer) {
        self.native = native
        let context = Unmanaged.passRetained(self).toOpaque()
        checkedNative(cmdy_zig_line_associate(native, context, Self.lifetimeCallback))
        withExtendedLifetime(self) { cmdy_zig_line_release(native) }
    }

    static func wrapping(retained native: OpaquePointer) -> Line {
        if let context = cmdy_zig_line_swift_context(native) {
            let line = Unmanaged<Line>.fromOpaque(context).takeUnretainedValue()
            withExtendedLifetime(line) { cmdy_zig_line_release(native) }
            return line
        }
        return Line(retained: native)
    }

    deinit {
        precondition(ownsNative)
        checkedNative(cmdy_zig_line_disassociate(native, Unmanaged.passUnretained(self).toOpaque()))
        cmdy_zig_line_release(native)
    }

    public convenience init(cols: Int, fill: Cell = Cell()) {
        precondition(cols >= 0)
        var value = nativeCell(fill)
        let handle = withNativeExtras(fill) {
            cmdy_zig_line_create(cols, &value, $0, $1, $2)
        }
        guard let handle else { preconditionFailure("Cannot allocate CMDY native row") }
        self.init(retained: handle)
    }

    public convenience init(cells: [Cell], isWrapped: Bool) {
        self.init(cols: cells.count)
        for index in cells.indices { self[index] = cells[index] }
        self.isWrapped = isWrapped
    }

    convenience init(fullASCII bytes: ArraySlice<UInt8>, attribute: CellAttribute,
                     linkId: UInt16, isWrapped: Bool) {
        self.init(ascii: bytes, cols: bytes.count, fill: Cell(), attribute: attribute,
                  linkId: linkId, isWrapped: isWrapped)
    }

    convenience init(ascii bytes: ArraySlice<UInt8>, cols: Int, fill: Cell,
                     attribute: CellAttribute, linkId: UInt16, isWrapped: Bool) {
        precondition(bytes.count <= cols)
        self.init(cols: cols, fill: fill)
        writeASCII(bytes, at: 0, attribute: attribute, linkId: linkId)
        self.isWrapped = isWrapped
    }

    public var count: Int { cmdy_zig_line_count(native) }
    public var version: UInt64 { cmdy_zig_line_version(native) }
    @inline(__always) func bumpVersion() { cmdy_zig_line_touch(native) }

    public var isWrapped: Bool {
        get { cmdy_zig_line_metadata(native, 0) != 0 }
        set { checkedNative(cmdy_zig_line_set_metadata(native, 0, newValue ? 1 : 0)) }
    }
    enum WrapStyle { case cells, words }
    var wrapStyle: WrapStyle {
        get { cmdy_zig_line_metadata(native, 1) == 0 ? .cells : .words }
        set { checkedNative(cmdy_zig_line_set_metadata(native, 1, newValue == .cells ? 0 : 1)) }
    }
    public var renderMode: LineRenderMode {
        get {
            switch cmdy_zig_line_metadata(native, 2) {
            case 1: return .doubleWidth
            case 2: return .doubledTop
            case 3: return .doubledDown
            default: return .single
            }
        }
        set {
            let value: Int32
            switch newValue {
            case .single: value = 0
            case .doubleWidth: value = 1
            case .doubledTop: value = 2
            case .doubledDown: value = 3
            }
            checkedNative(cmdy_zig_line_set_metadata(native, 2, value))
        }
    }

    public var images: [LineImage]? {
        get {
            let count = cmdy_zig_line_image_count(native)
            guard count >= 0 else { return nil }
            return (0..<count).map {
                guard let image = cmdy_zig_line_image_get(native, $0) else {
                    preconditionFailure("Missing native image")
                }
                return LineImage.wrapping(retained: image)
            }
        }
        set {
            let handles = newValue?.map { Optional($0.native) } ?? []
            withExtendedLifetime(newValue) {
                handles.withUnsafeBufferPointer {
                    checkedNative(cmdy_zig_line_set_images(native, $0.baseAddress, $0.count, newValue == nil ? 0 : 1))
                }
            }
        }
    }

    public var cells: [Cell] {
        Self.copyCells(from: native)
    }

    static func copyCells(from native: OpaquePointer) -> [Cell] {
        checkedNative(cmdy_zig_line_prepare_read(native))
        var count = 0, extraCount = 0
        let storage = cmdy_zig_line_cells(native, &count)
        let extras = cmdy_zig_line_extras(native, &extraCount)
        precondition(count == cmdy_zig_line_count(native) && (count == 0 || storage != nil))
        return Array(unsafeUninitializedCapacity: count) { result, initialized in
            for index in 0..<count {
                let stored = storage![index]
                let present = stored.cluster_offset != UInt32.max
                let n = Int(stored.cluster_count)
                let start = Int(stored.cluster_offset)
                precondition(n == 0 || (present && start <= extraCount && n <= extraCount - start))
                let first = n == 0 ? nil : extras!.advanced(by: start)
                result.baseAddress!.advanced(by: index).initialize(to:
                    swiftCell(stored.cell, extras: first, count: n, present: present))
            }
            initialized = count
        }
    }

    public subscript(index: Int) -> Cell {
        get {
            var value = CmdyZigCell(), extras: UnsafePointer<UInt32>?, count = 0, present: UInt8 = 0
            checkedNative(cmdy_zig_line_read(native, index, &value, &extras, &count, &present))
            return swiftCell(value, extras: extras, count: count, present: present != 0)
        }
        set {
            var value = nativeCell(newValue)
            withNativeExtras(newValue) {
                checkedNative(cmdy_zig_line_set(native, index, &value, $0, $1, $2))
            }
        }
    }

    func scalarAndWidth(at index: Int) -> (scalar: UInt32, width: Int8) {
        var value = CmdyZigCell(), extras: UnsafePointer<UInt32>?, count = 0, present: UInt8 = 0
        checkedNative(cmdy_zig_line_read(native, index, &value, &extras, &count, &present))
        return (value.scalar, value.width)
    }

    func appendClusterScalar(_ scalar: UInt32, at column: Int, width: Int8) {
        checkedNative(cmdy_zig_line_append_scalar(native, column, scalar, width))
    }

    func writeASCII(_ bytes: ArraySlice<UInt8>, at column: Int,
                    attribute: CellAttribute, linkId: UInt16) {
        guard column >= 0, column <= count, bytes.count <= count - column, !bytes.isEmpty else { return }
        var pen = nativeCell(Cell(attribute: attribute, linkId: linkId))
        bytes.withUnsafeBufferPointer {
            checkedNative(cmdy_zig_line_write_ascii(native, column, $0.baseAddress, $0.count, &pen))
        }
    }

    func writeOrdinaryUnicode(_ cells: UnsafeBufferPointer<OrdinaryUnicodeCell>, at column: Int,
                              columns: Int, attribute: CellAttribute, linkId: UInt16,
                              eraseAttribute: CellAttribute, stubAttribute: CellAttribute) {
        precondition(!cells.isEmpty && column >= 0 && columns >= 0 && column <= count && columns <= count - column)
        precondition(cells.reduce(0) { $0 + Int($1.width) } == columns)
        let values = cells.map { source -> CmdyZigScalar in
            var value = CmdyZigScalar()
            value.scalar = source.scalar
            value.width = source.width
            return value
        }
        var pen = nativeCell(Cell(attribute: attribute, linkId: linkId))
        var stub = nativeCell(Cell(width: 0, attribute: stubAttribute))
        values.withUnsafeBufferPointer {
            checkedNative(cmdy_zig_line_write_unicode(native, column, $0.baseAddress, $0.count, &pen, &stub))
        }
    }

    func reset(fill: Cell, isWrapped: Bool = false) {
        var value = nativeCell(fill)
        withNativeExtras(fill) {
            checkedNative(cmdy_zig_line_reset(native, &value, $0, $1, $2, isWrapped ? 1 : 0))
        }
    }
    func resetDeferred(fill: Cell, isWrapped: Bool = false) { reset(fill: fill, isWrapped: isWrapped) }
    func resetMetadata(isWrapped: Bool = false) {
        cmdy_zig_line_reset_metadata(native, isWrapped ? 1 : 0)
    }

    public func resize(to cols: Int, fill: Cell) {
        var value = nativeCell(fill)
        withNativeExtras(fill) {
            checkedNative(cmdy_zig_line_resize(native, cols, &value, $0, $1, $2))
        }
    }
    public func fill(with cell: Cell, from start: Int = 0, to end: Int? = nil) {
        var value = nativeCell(cell)
        withNativeExtras(cell) {
            checkedNative(cmdy_zig_line_fill(native, start, end ?? count, &value, $0, $1, $2))
        }
    }
    public func insertCells(at pos: Int, count n: Int, rightMargin: Int? = nil, fill: Cell) {
        edit(at: pos, count: n, rightMargin: rightMargin, fill: fill, insert: true)
    }
    public func deleteCells(at pos: Int, count n: Int, rightMargin: Int? = nil, fill: Cell) {
        edit(at: pos, count: n, rightMargin: rightMargin, fill: fill, insert: false)
    }
    private func edit(at pos: Int, count n: Int, rightMargin: Int?, fill: Cell, insert: Bool) {
        var value = nativeCell(fill)
        withNativeExtras(fill) {
            checkedNative(cmdy_zig_line_edit(native, pos, n, rightMargin ?? (count - 1), insert ? 1 : 0, &value, $0, $1, $2))
        }
    }
    public func copyColumns(from src: Line, in range: ClosedRange<Int>) {
        withExtendedLifetime(src) {
            checkedNative(cmdy_zig_line_copy_columns(native, src.native, range.lowerBound, range.upperBound))
        }
    }
    public func fillColumns(_ range: ClosedRange<Int>, with cell: Cell) {
        let before = version
        fill(with: cell, from: range.lowerBound, to: range.upperBound == Int.max ? Int.max : range.upperBound + 1)
        if version == before { bumpVersion() }
    }

    public var usedLength: Int { cmdy_zig_line_used_length(native, 0) }
    public var trimmedLength: Int { cmdy_zig_line_used_length(native, 1) }
    public func trimmedText() -> String {
        let length = min(trimmedLength, count)
        guard length > 0 else { return "" }
        // Character conversion is deliberately Swift's public value semantics,
        // including malformed scalars and the first grapheme in raw extras.
        var text = ""
        for index in 0..<length {
            let cell = self[index]
            text += cell.scalar == 0 ? " " : cell.text
        }
        return text
    }
    public func clone() -> Line {
        guard let copy = cmdy_zig_line_clone(native) else {
            preconditionFailure("Cannot clone CMDY native row")
        }
        return Line.wrapping(retained: copy)
    }
}
