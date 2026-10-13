import AppKit
@_spi(CmdyApp) import CmdyCore
import CmdyNative
@_spi(CmdyApp) import CmdyGPU

private func shapeObject(_ value: AnyObject) -> UnsafeRawPointer {
    UnsafeRawPointer(Unmanaged.passUnretained(value).toOpaque())
}
private func shapeBorrowed<T: AnyObject>(_ pointer: UnsafeRawPointer?) -> T {
    precondition(pointer != nil, "Missing native shaping value")
    return Unmanaged<T>.fromOpaque(pointer!).takeUnretainedValue()
}
private func shapeRetained<T: AnyObject>(_ pointer: UnsafeRawPointer?) -> T {
    precondition(pointer != nil, "Cannot allocate native shaping value")
    return Unmanaged<T>.fromOpaque(pointer!).takeRetainedValue()
}
private final class CmdyNativeShapingStyle {
    let handle: OpaquePointer
    init(retained: OpaquePointer) { handle = retained }
    deinit { cmdy_shape_style_free(handle) }
}

/// Platform values projected from the native library's immutable shaping style.
/// Color resolution and exact style identity are owned by Zig.
struct CmdyShapingStyle: Equatable {
    private let storage: CmdyNativeShapingStyle
    fileprivate var native: OpaquePointer { storage.handle }
    fileprivate init(borrowed: OpaquePointer) {
        storage = CmdyNativeShapingStyle(retained: cmdy_shape_style_retain(borrowed)!)
    }
    init(palette: [NSColor], normalFont: NSFont, boldFont: NSFont,
         italicFont: NSFont, boldItalicFont: NSFont, foreground: NSColor,
         background: NSColor, selectionBackground: NSColor, failedRows: Set<Int>,
         failedForeground: NSColor, failedBackground: NSColor) {
        let palettePointers = palette.map { Optional(shapeObject($0)) }
        let rows = Array(failedRows)
        var input = CmdyShapeStyleInput()
        input.fonts = (shapeObject(normalFont), shapeObject(boldFont),
                       shapeObject(italicFont), shapeObject(boldItalicFont))
        input.colors = (shapeObject(foreground), shapeObject(background),
                        shapeObject(selectionBackground), shapeObject(failedForeground),
                        shapeObject(failedBackground))
        input.palette_count = palettePointers.count
        input.failed_row_count = rows.count
        let handle = withExtendedLifetime((palette, normalFont, boldFont, italicFont,
            boldItalicFont, foreground, background, selectionBackground, failedForeground, failedBackground)) {
            palettePointers.withUnsafeBufferPointer { colors in
                rows.withUnsafeBufferPointer { rows in
                    input.palette = colors.baseAddress
                    input.failed_rows = rows.baseAddress
                    return cmdy_shape_style_create(&input)
                }
            }
        }
        guard let handle else { preconditionFailure("Cannot allocate native shaping style") }
        storage = CmdyNativeShapingStyle(retained: handle)
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        withExtendedLifetime((lhs, rhs)) { cmdy_shape_style_equal(lhs.native, rhs.native) != 0 }
    }
    private func object<T: AnyObject>(_ group: UInt8, _ index: Int) -> T {
        withExtendedLifetime(storage) { shapeBorrowed(cmdy_shape_style_object(native, group, index)) }
    }
    var palette: [NSColor] { (0..<cmdy_shape_style_count(native, 0)).map { object(0, $0) } }
    var normalFont: NSFont { object(1, 0) }
    var boldFont: NSFont { object(1, 1) }
    var italicFont: NSFont { object(1, 2) }
    var boldItalicFont: NSFont { object(1, 3) }
    var foreground: NSColor { object(2, 0) }
    var background: NSColor { object(2, 1) }
    var selectionBackground: NSColor { object(2, 2) }
    var failedForeground: NSColor { object(2, 3) }
    var failedBackground: NSColor { object(2, 4) }
    var failedRows: Set<Int> {
        Set(UnsafeBufferPointer(start: cmdy_shape_style_failed_rows(native), count: cmdy_shape_style_count(native, 3)))
    }
}

/// The host establishes AppKit's drawing appearance; native state owns lazy
/// frame preparation, resolved style comparison and row revision eligibility.
@MainActor
final class CmdySnapshotRowContext {
    private let native = cmdy_shape_context_create()!
    private var frozenStyle: (revision: UInt64, value: NativeRowStyle)?
    deinit { cmdy_shape_context_free(native) }
    func beginFrame() { cmdy_shape_context_begin(native) }
    func style(_ makeStyle: @autoclosure () -> CmdyShapingStyle,
               appearance: NSAppearance? = nil) -> CmdyShapingStyle {
        if let cached = cmdy_shape_context_style(native) { return CmdyShapingStyle(borrowed: cached) }
        let original = makeStyle()
        var result: OpaquePointer?
        let resolve = { result = cmdy_shape_context_set(self.native, original.native) }
        if let appearance { appearance.performAsCurrentDrawingAppearance(resolve) } else { resolve() }
        return CmdyShapingStyle(borrowed: result!)
    }
    func revision(snapshot: CoreTerminalSnapshot, absoluteRow: Int,
                  style makeStyle: @autoclosure () -> CmdyShapingStyle,
                  appearance: NSAppearance? = nil) -> SnapshotRowRevision? {
        guard let line = snapshot.line(absolute: absoluteRow), line.version != 0,
              line.images.isEmpty, snapshot.kittyImages.isEmpty, snapshot.kittyPlacements.isEmpty else { return nil }
        _ = style(makeStyle(), appearance: appearance)
        var context: UInt64 = 0
        guard cmdy_shape_context_revision(native, line.version, 0, &context) != 0 else { return nil }
        return SnapshotRowRevision(content: line.version, context: context)
    }

    func deferredRow(snapshot: CoreTerminalSnapshot, absoluteRow: Int,
                     style makeStyle: @autoclosure () -> CmdyShapingStyle,
                     appearance: NSAppearance?, parameters: NativeRowCaptureParameters) throws -> DeferredRenderRow? {
        guard let line = snapshot.line(absolute: absoluteRow) else { return nil }
        let frozen = try nativeStyle(makeStyle(), appearance: appearance)
        return try line.withNativeLine {
            try DeferredRenderRow(nativeLine: $0, sourceRow: absoluteRow,
                style: frozen, parameters: parameters, images: line.images.map(CmdyCellImage.wrap))
        }
    }

    func nativeStyle(_ makeStyle: @autoclosure () -> CmdyShapingStyle,
                     appearance: NSAppearance?) throws -> NativeRowStyle {
        let current = style(makeStyle(), appearance: appearance)
        var revision: UInt64 = 0
        precondition(cmdy_shape_context_revision(native, 1, 0, &revision) != 0)
        if frozenStyle?.revision != revision {
            // The context has already resolved all colors under the appearance.
            // Capture a separate native style instead of sharing its UI refs.
            frozenStyle = (revision, try withExtendedLifetime(current) {
                try NativeRowStyle(nativeStyle: current.native)
            })
        }
        return frozenStyle!.value
    }
}

/// This facade marshals native row results into the existing renderer contract.
/// The native shaper reads the immutable engine row directly, without a Swift
/// cell array, and owns run grouping, text, procedural glyphs and attributes.
@MainActor
enum CmdySnapshotShaper {
    static func lineInfo(snapshot: CoreTerminalSnapshot, absoluteRow: Int,
                         style: CmdyShapingStyle, selectedColumns: ClosedRange<Int>?) -> ViewLineInfo {
        let started = CmdyPerformanceTrace.now()
        guard let line = snapshot.line(absolute: absoluteRow) else {
            CmdyPerformanceTrace.record(event: "shaper.missingLine", started: started, fields: ["row": absoluteRow])
            return ViewLineInfo(segments: [], images: nil)
        }
        let result = withExtendedLifetime(style) {
            line.withNativeLine {
                cmdy_shape_line(OpaquePointer($0), absoluteRow, style.native,
                    selectedColumns == nil ? 0 : 1, selectedColumns?.lowerBound ?? 0, selectedColumns?.upperBound ?? 0)
            }
        }
        guard let result else { preconditionFailure("Cannot allocate native shaped row") }
        defer { cmdy_shape_result_free(result) }
        var view = CmdyShapeView()
        cmdy_shape_result_view(result, &view)
        let segments = UnsafeBufferPointer(start: view.segments, count: view.segment_count).map { item in
            ViewLineSegment(column: item.column, columnWidth: item.column_width,
                characterCount: item.character_count, attributedString: shapeBorrowed(item.attributed_string),
                cellUTF16Boundaries: Array(UnsafeBufferPointer(start: item.boundaries, count: item.boundary_count)))
        }
        let blocks = UnsafeBufferPointer(start: view.blocks, count: view.block_count).map { item in
            var raw = item.rects
            let rects = withUnsafeBytes(of: &raw) { bytes in
                Array(bytes.bindMemory(to: CmdyRenderBlockRect.self).prefix(item.rect_count)).map {
                    BlockElementRect(native: $0)
                }
            }
            return BlockElementRenderItem(column: item.column, columnWidth: item.column_width,
                codePoint: item.code_point, rects: rects, foregroundColor: shapeBorrowed(item.foreground))
        }
        let boxes = UnsafeBufferPointer(start: view.boxes, count: view.box_count).map { item in
            BoxDrawingRenderItem(column: item.column, columnWidth: item.column_width,
                codePoint: item.code_point, foregroundColor: shapeBorrowed(item.foreground))
        }
        let placeholders = UnsafeBufferPointer(start: view.placeholders, count: view.placeholder_count).map { item in
            KittyPlaceholderCell(row: item.row, col: item.col, imageId: item.image_id,
                placementId: item.placement_id, placeholderRow: item.placeholder_row,
                placeholderCol: item.placeholder_col, msb: item.msb)
        }
        CmdyPerformanceTrace.record(event: view.represented_columns == 0 ? "shaper.emptyLine" : "shaper.line",
            started: started, fields: ["row": absoluteRow,
                "columns": view.represented_columns == 0 ? line.nativeCellCount : view.represented_columns,
                "segments": segments.count, "blocks": blocks.count, "boxes": boxes.count])
        return ViewLineInfo(segments: segments, images: line.images.isEmpty ? nil : line.images.map(CmdyCellImage.wrap),
            kittyPlaceholders: placeholders, blockElements: blocks, boxDrawings: boxes)
    }
    static func cursorString(snapshot: CoreTerminalSnapshot, style: CmdyShapingStyle,
                             caretColor: NSColor, caretTextColor: NSColor?) -> NSAttributedString? {
        guard let line = snapshot.line(absolute: snapshot.grid.cursorRow) else { return nil }
        return withExtendedLifetime((style, caretColor, caretTextColor)) {
            line.withNativeLine { pointer in
                guard let result = cmdy_shape_cursor(OpaquePointer(pointer), snapshot.grid.cursorCol,
                    style.native, shapeObject(caretColor), caretTextColor.map(shapeObject)) else { return nil }
                return shapeRetained(result)
            }
        }
    }
    static func attributes(for attribute: CellAttribute, selected: Bool, failed: Bool,
                           style: CmdyShapingStyle) -> [NSAttributedString.Key: Any] {
        var cell = nativeAttribute(attribute)
        let dict: NSDictionary = withExtendedLifetime(style) {
            shapeRetained(cmdy_shape_attributes(&cell, selected ? 1 : 0, failed ? 1 : 0, style.native))
        }
        return dict as! [NSAttributedString.Key: Any]
    }
    static func mapColor(_ color: CellColor, isForeground: Bool, isBold: Bool, style: CmdyShapingStyle) -> NSColor {
        withExtendedLifetime(style) {
            shapeRetained(cmdy_shape_map_color(colorWord(color), isForeground ? 1 : 0, isBold ? 1 : 0, style.native))
        }
    }
    static func needsExplicitBackground(_ attribute: CellAttribute) -> Bool {
        var cell = nativeAttribute(attribute)
        return cmdy_shape_explicit_background(&cell) != 0
    }
    private static func colorWord(_ color: CellColor) -> UInt32 {
        switch color {
        case .defaultColor: return 0
        case .defaultInverted: return 0x03000000
        case .ansi256(let n): return 0x01000000 | UInt32(n)
        case .trueColor(let r, let g, let b): return 0x02000000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
        }
    }
    private static func nativeAttribute(_ attribute: CellAttribute) -> CmdyZigCell {
        var cell = CmdyZigCell()
        cell.fg = colorWord(attribute.fg); cell.bg = colorWord(attribute.bg)
        cell.style = attribute.style.rawValue; cell.underline_kind = attribute.underlineKind.rawValue
        cell.underline_present = attribute.underlineColor == nil ? 0 : 1
        cell.underline_color = attribute.underlineColor.map(colorWord) ?? 0
        return cell
    }
}

/// Source-compatible image object. Identity cache, eviction and image decoding
/// are native; this object exposes the retained platform image to AppKit.
@MainActor
final class CmdyCellImage: @preconcurrency RenderableCellImage, EncodedRenderableCellImage {
    private static let releaseContext: @convention(c) (UnsafeMutableRawPointer?) -> Void = { pointer in
        if let pointer { Unmanaged<CmdyCellImage>.fromOpaque(pointer).release() }
    }
    static func wrap(_ source: CoreLineImageSnapshot) -> CmdyCellImage {
        var identity = source.renderIdentity.uuid
        return withUnsafeBytes(of: &identity) { raw in
            let bytes = raw.bindMemory(to: UInt8.self).baseAddress!
            if let context = cmdy_image_bridge_cached(bytes) {
                let cached = Unmanaged<CmdyCellImage>.fromOpaque(context).takeUnretainedValue()
                cached.col = source.col
                return cached
            }
            let wrapper = CmdyCellImage(source)
            let retained = Unmanaged.passRetained(wrapper).toOpaque()
            if cmdy_image_bridge_cache(bytes, retained, releaseContext) == 0 { releaseContext(retained) }
            return wrapper
        }
    }
    let renderIdentity: UUID
    let encodedPayload: KittyImagePayload
    private var decodedImage: NSImage?
    var image: NSImage {
        if let decodedImage { return decodedImage }
        let result = decodeImage()
        decodedImage = result
        return result
    }
    private func decodeImage() -> NSImage {
        switch encodedPayload {
        case .png(let data):
            return data.withUnsafeBytes {
                shapeRetained(cmdy_image_bridge_decode(0, $0.bindMemory(to: UInt8.self).baseAddress,
                    $0.count, 0, 0, pixelWidth, pixelHeight))
            }
        case .rgba(let bytes, let width, let height):
            return bytes.withUnsafeBufferPointer {
                shapeRetained(cmdy_image_bridge_decode(1, $0.baseAddress, $0.count,
                    width, height, pixelWidth, pixelHeight))
            }
        }
    }
    let pixelWidth: Int
    let pixelHeight: Int
    var col: Int
    let kittyIsKitty: Bool
    let kittyImageId: UInt32?
    let kittyZIndex: Int
    let kittyPixelOffsetX: Int
    let kittyPixelOffsetY: Int
    let kittyCellColumns: Int
    let kittyCellRows: Int
    let kittySourceRect: (x: Int, y: Int, width: Int, height: Int)
    private init(_ source: CoreLineImageSnapshot) {
        renderIdentity = source.renderIdentity
        pixelWidth = source.pixelWidth; pixelHeight = source.pixelHeight; col = source.col
        kittyIsKitty = source.kittyIsKitty; kittyImageId = source.kittyImageId
        kittyZIndex = source.kittyZIndex
        kittyPixelOffsetX = source.kittyPixelOffsetX; kittyPixelOffsetY = source.kittyPixelOffsetY
        let box = source.kittyDisplayBox
        kittyCellColumns = box.cellColumns; kittyCellRows = box.cellRows
        kittySourceRect = (box.sourceX, box.sourceY, box.sourceWidth, box.sourceHeight)
        switch source.payload {
        case .png(let data):
            encodedPayload = .png(data)
        case .rgba(let bytes, let width, let height):
            encodedPayload = .rgba(bytes: bytes, width: width, height: height)
        }
    }
}
