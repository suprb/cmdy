import CmdyNative

/// Metadata encoded by one Kitty U+10EEEE Unicode placeholder cell.
public struct KittyUnicodePlaceholder: Equatable, Sendable {
    public let row: Int
    public let col: Int
    public let imageId: UInt32
    public let placementId: UInt32
    public let placeholderRow: Int
    public let placeholderCol: Int
    public let msb: Int
}

/// The small native state is stored by value, preserving independent decoder
/// copies. Decoding and the pinned diacritic table live in the Zig engine.
public struct KittyUnicodePlaceholderDecoder: Sendable {
    private var state = CmdyZigPlaceholderState()
    public init() {}
    public mutating func reset() { state = CmdyZigPlaceholderState() }
    public mutating func decode(_ cell: Cell, absoluteRow: Int, column: Int) -> KittyUnicodePlaceholder? {
        var value = CmdyZigPlaceholder()
        let decoded = withNativeExtras(cell) { marks, count, _ in
            cmdy_zig_placeholder_decode(&state, cell.scalar, nativeColor(cell.attribute.fg),
                cell.attribute.underlineColor.map(nativeColor) ?? 0, cell.attribute.underlineColor == nil ? 0 : 1,
                marks, count, absoluteRow, column, &value)
        }
        guard decoded != 0 else { return nil }
        return KittyUnicodePlaceholder(row: value.row, col: value.col, imageId: value.image_id,
            placementId: value.placement_id, placeholderRow: value.placeholder_row,
            placeholderCol: value.placeholder_col, msb: value.msb)
    }
}
