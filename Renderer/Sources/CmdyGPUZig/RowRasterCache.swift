import AppKit
import CoreGraphics
import CoreText
import Foundation
import Metal
import CmdyNative

struct IndependentSolidRect {
    var rect: CGRect // row-local device pixels, y-down
    var color: SIMD4<Float>

    /// Join only exactly adjacent rectangles in their existing paint order.
    /// Pixel alignment can make fractional-width cells overlap; merging those
    /// would change repeated alpha blending even when their colors match.
    static func appendCoalescing(_ solid: Self, to output: inout [Self]) {
        var next = CmdyRenderSolid(rect: CmdyRenderRect(solid.rect), color: CmdyRenderColor(solid.color))
        if let last = output.last {
            var previous = CmdyRenderSolid(rect: CmdyRenderRect(last.rect), color: CmdyRenderColor(last.color))
            if cmdy_render_solid_merge(&previous, &next) != 0 {
                output[output.count - 1].rect = previous.rect.cgRect
                return
            }
        }
        output.append(solid)
    }
}

struct IndependentTintSpan {
    var rect: CGRect // row-local device pixels, y-down
    var glyphEnvelope: CGRect? = nil
    var replacedByAtlas = false
    var color: SIMD4<Float>
}

struct IndependentColorTile {
    var rect: CGRect // row-local device pixels, y-down
    var width: Int
    var height: Int
    var bytes: [UInt8]
}

struct IndependentGlyphSeed {
    let font: CTFont
    let glyph: CGGlyph
    let rect: CGRect // tight row-local device-pixel bitmap bounds, y-down
    let color: SIMD4<Float>
}

struct IndependentAtlasGlyphDraw {
    let rect: CGRect // tight row-local device-pixel bitmap bounds, y-down
    let atlasRect: CGRect // glyph content in full-atlas pixels
    let color: SIMD4<Float>
}

final class WeakRenderableImage: @unchecked Sendable {
    weak var object: AnyObject?

    init(_ image: any RenderableCellImage) {
        object = image
    }

    @MainActor
    var value: (any RenderableCellImage)? {
        object as? any RenderableCellImage
    }
}

struct IndependentRowImage {
    let image: WeakRenderableImage
    let col: Int
    let zIndex: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let pixelOffsetX: Int
    let pixelOffsetY: Int
    let kittyImageId: UInt32?
    let kittyIsKitty: Bool
}

struct IndependentRowKey: Hashable {
    let absoluteRow: Int
    let version: UInt64
    let lineMode: RenderLineMode
    let cols: Int
    let widthPx: Int
    let heightPx: Int
    let scaleBits: UInt64
    let fontName: String
    let fontSizeBits: UInt64
    let alternateBuffer: Bool
    let kittyStamp: KittyCacheStamp
    let foreground: UInt64
    let background: UInt64
    let preset: TextRenderingMode
    let antialiasBlocks: Bool
    let bufferingMode: MetalBufferingMode
}

/// Pixel-identical text rows may occur at many absolute scrollback positions
/// (prompts, diagnostics, progress output). Their terminal identities remain
/// distinct, but their immutable raster payload does not need to be rebuilt or
/// stored more than once. Images and procedural glyph rows retain identity-
/// keyed entries because their external payloads have stronger semantics.
struct IndependentSharedTextAttributeRunKey: Hashable {
    let location: Int
    let length: Int
    private(set) var font: NSFont?
    private(set) var foreground: NSColor?
    private(set) var background: NSColor?
    private(set) var selectionBackground: NSColor?
    private(set) var cmdySelectionBackground: NSColor?
    private(set) var underlineColor: NSColor?
    private(set) var cmdyUnderlineColor: NSColor?
    private(set) var strikethroughColor: NSColor?
    private(set) var ligature: Int?
    private(set) var kernBits: UInt64?
    private(set) var underlineStyle: Int?
    private(set) var cmdyUnderlineStyle: Int?
    private(set) var strikethroughStyle: Int?

    init?(range: NSRange, attributes: [NSAttributedString.Key: Any]) {
        var value = CmdyRenderAttributeKey()
        let dictionary = attributes as NSDictionary
        guard cmdy_render_attribute_key(Unmanaged.passUnretained(dictionary).toOpaque(), &value) != 0 else { return nil }
        location = range.location
        length = range.length
        func object<T: AnyObject>(_ pointer: UnsafeRawPointer?) -> T? {
            pointer.map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as! T }
        }
        font = object(value.objects.0)
        foreground = object(value.objects.1)
        background = object(value.objects.2)
        selectionBackground = object(value.objects.3)
        cmdySelectionBackground = object(value.objects.4)
        underlineColor = object(value.objects.5)
        cmdyUnderlineColor = object(value.objects.6)
        strikethroughColor = object(value.objects.7)
        ligature = value.present & (1 << 8) != 0 ? Int(value.integers.0) : nil
        underlineStyle = value.present & (1 << 9) != 0 ? Int(value.integers.1) : nil
        cmdyUnderlineStyle = value.present & (1 << 10) != 0 ? Int(value.integers.2) : nil
        strikethroughStyle = value.present & (1 << 11) != 0 ? Int(value.integers.3) : nil
        kernBits = value.present & (1 << 12) != 0 ? value.kern_bits : nil
    }
}

struct IndependentSharedTextSegmentKey: Hashable {
    let column: Int
    let columnWidth: Int
    let characterCount: Int
    let string: String
    let attributeRuns: [IndependentSharedTextAttributeRunKey]
    let cellUTF16Boundaries: [Int]?

    init?(_ segment: ViewLineSegment) {
        column = segment.column
        columnWidth = segment.columnWidth
        characterCount = segment.characterCount
        string = segment.attributedString.string
        cellUTF16Boundaries = segment.cellUTF16Boundaries
        var runs: [IndependentSharedTextAttributeRunKey] = []
        var valid = true
        let full = NSRange(location: 0, length: segment.attributedString.length)
        segment.attributedString.enumerateAttributes(
            in: full, options: []
        ) { attributes, range, stop in
            guard let key = IndependentSharedTextAttributeRunKey(
                range: range, attributes: attributes) else {
                valid = false
                stop.pointee = true
                return
            }
            runs.append(key)
        }
        guard valid else { return nil }
        attributeRuns = runs
    }
}

/// Raster inputs whose exact values are not carried by the terminal row key.
/// Pixel dimensions round cell geometry; underline metrics and fallback font
/// details may change independently of a row's terminal version.
struct IndependentRowRasterInputs: Hashable {
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let scale: CGFloat
    let normalFont: NSFont
    let foreground: SIMD4<Float>
    let underlinePosition: CGFloat
    let underlineThickness: CGFloat
}

struct IndependentSharedTextRowKey: Hashable {
    private final class Storage {
        let handle: OpaquePointer
        init(taking handle: OpaquePointer) { self.handle = handle }
        deinit { cmdy_render_text_key_free(handle) }
    }
    private let storage: Storage
    private let context: IndependentRowKey
    let rasterInputs: IndependentRowRasterInputs?
    private static func context(_ key: IndependentRowKey) -> IndependentRowKey {
        IndependentRowKey(absoluteRow: 0, version: 0, lineMode: key.lineMode,
                          cols: key.cols, widthPx: key.widthPx, heightPx: key.heightPx,
                          scaleBits: key.scaleBits, fontName: key.fontName, fontSizeBits: key.fontSizeBits,
                          alternateBuffer: key.alternateBuffer, kittyStamp: key.kittyStamp,
                          foreground: key.foreground, background: key.background, preset: key.preset,
                          antialiasBlocks: key.antialiasBlocks, bufferingMode: key.bufferingMode)
    }
    @MainActor
    init?(info: ViewLineInfo, rowKey: IndependentRowKey, rasterInputs: IndependentRowRasterInputs) {
        guard info.images?.isEmpty != false, info.kittyPlaceholders.isEmpty,
              info.blockElements.isEmpty, info.boxDrawings.isEmpty else { return nil }
        let rgba = rasterInputs.foreground
        let foreground = NSColor(deviceRed: CGFloat(rgba.x), green: CGFloat(rgba.y),
                                 blue: CGFloat(rgba.z), alpha: CGFloat(rgba.w))
        guard let handle = IndependentRowRasterizer.withNativeInput(
            info: info, cols: rowKey.cols, width: rowKey.widthPx, height: rowKey.heightPx,
            cellWidth: rasterInputs.cellWidth, cellHeight: rasterInputs.cellHeight,
            scale: rasterInputs.scale, normalFont: rasterInputs.normalFont,
            nativeForeground: foreground, underlinePosition: rasterInputs.underlinePosition,
            underlineThickness: rasterInputs.underlineThickness, preset: rowKey.preset,
            antialiasBlocks: rowKey.antialiasBlocks, { cmdy_render_text_key_create($0) }) else { return nil }
        storage = Storage(taking: handle)
        context = Self.context(rowKey)
        self.rasterInputs = rasterInputs
    }
    /// The native cache owns the key; the projected immutable value retains it.
    init(nativeKey: OpaquePointer, rowKey: IndependentRowKey, rasterInputs: IndependentRowRasterInputs? = nil) {
        storage = Storage(taking: cmdy_render_text_key_retain(nativeKey)!)
        context = Self.context(rowKey)
        self.rasterInputs = rasterInputs
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.context == rhs.context && cmdy_render_text_key_equal(lhs.storage.handle, rhs.storage.handle) != 0
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(context)
        hasher.combine(cmdy_render_text_key_hash(storage.handle))
    }
}

struct IndependentColorLayer {
    let texture: MTLTexture
    let rect: CGRect
}

struct IndependentRowCacheEntry {
    var key: IndependentRowKey
    let sharedTextKey: IndependentSharedTextRowKey?
    var snapshotRevision: SnapshotRowRevision? = nil
    let coverageTexture: MTLTexture?
    let colorLayers: [IndependentColorLayer]
    let backgrounds: [IndependentSolidRect]
    let tintSpans: [IndependentTintSpan]
    var atlasGlyphs: [IndependentAtlasGlyphDraw] = []
    let decorations: [IndependentSolidRect]
    let images: [IndependentRowImage]
    let kittyPlaceholders: [KittyPlaceholderCell]
    let width: Int
    let height: Int
    var lastUse: UInt64

    var allocatedBytes: Int {
        (coverageTexture?.allocatedSize ?? 0)
            + colorLayers.reduce(0) { $0 + $1.texture.allocatedSize }
    }
}

struct IndependentCPURow {
    var coverage: [UInt8]
    var colorTiles: [IndependentColorTile]
    var backgrounds: [IndependentSolidRect]
    var tintSpans: [IndependentTintSpan]
    var glyphSeeds: [IndependentGlyphSeed]
    var decorations: [IndependentSolidRect]
    var images: [IndependentRowImage]
    var kittyPlaceholders: [KittyPlaceholderCell]
    let width: Int
    let height: Int
}

// Native records have stable C layouts; these conversions only project values.
extension CmdyRenderRect {
    init(_ rect: CGRect) { self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height) }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
extension CmdyRenderColor {
    init(_ color: SIMD4<Float>) { self.init(r: color.x, g: color.y, b: color.z, a: color.w) }
    var simd: SIMD4<Float> { SIMD4(r, g, b, a) }
}

@MainActor
enum IndependentRowRasterizer {
    struct RowFonts {
        private final class Storage {
            let handle: OpaquePointer
            init(scale: CGFloat, normal: NSFont, caching: Bool) {
                handle = cmdy_render_fonts_create(scale, Unmanaged.passUnretained(normal).toOpaque(), caching ? 1 : 0)!
            }
            deinit { cmdy_render_fonts_free(handle) }
        }
        let scale: CGFloat
        let normal: NSFont
        let caching: Bool
        private let storage: Storage
        init(scale: CGFloat, normal: NSFont, caching: Bool) {
            self.scale = scale; self.normal = normal; self.caching = caching
            storage = Storage(scale: scale, normal: normal, caching: caching)
        }
        var scaledEntryCount: Int { cmdy_render_fonts_count(storage.handle, 0) }
        var shapingEntryCount: Int { cmdy_render_fonts_count(storage.handle, 1) }
        var hasAdditionalScaledStorage: Bool { cmdy_render_fonts_additional_storage(storage.handle, 0) != 0 }
        var hasAdditionalShapingStorage: Bool { cmdy_render_fonts_additional_storage(storage.handle, 1) != 0 }
        mutating func scaledFont(_ source: NSFont?) -> NSFont {
            let value = cmdy_render_fonts_scaled(storage.handle, source.map { Unmanaged.passUnretained($0).toOpaque() })!
            return Unmanaged<NSFont>.fromOpaque(value).takeRetainedValue()
        }
        mutating func shapingFont(_ source: NSFont) -> CTFont {
            let value = cmdy_render_fonts_shaping(storage.handle, Unmanaged.passUnretained(source).toOpaque())!
            return Unmanaged<CTFont>.fromOpaque(value).takeRetainedValue()
        }
    }

    static func withNativeInput<T>(
        info: ViewLineInfo, cols: Int, width: Int, height: Int,
        cellWidth: CGFloat, cellHeight: CGFloat, scale: CGFloat,
        normalFont: NSFont, nativeForeground: NSColor,
        underlinePosition: CGFloat, underlineThickness: CGFloat,
        preset: TextRenderingMode, antialiasBlocks: Bool,
        asciiCaching: Bool = true, fontCaching: Bool = true,
        _ body: (UnsafePointer<CmdyRenderRowInput>) -> T
    ) -> T {
        var normalizedStyles: [Bool] = []
        let attributedStrings = info.segments.map { segment -> NSAttributedString in
            var copy: NSMutableAttributedString?
            segment.attributedString.enumerateAttribute(.cmdyUnderlineStyle,
                in: NSRange(location: 0, length: segment.attributedString.length), options: []) { value, range, _ in
                if let style = value as? RenderUnderlineStyle {
                    if copy == nil { copy = NSMutableAttributedString(attributedString: segment.attributedString) }
                    copy!.addAttribute(.cmdyUnderlineStyle, value: style.rawValue, range: range)
                }
            }
            normalizedStyles.append(copy != nil)
            return copy ?? segment.attributedString
        }
        var boundaries: [Int] = []
        var boundaryOffsets: [Int] = []
        for segment in info.segments {
            boundaryOffsets.append(boundaries.count)
            boundaries.append(contentsOf: segment.cellUTF16Boundaries ?? [])
        }
        var blockRects: [CmdyRenderBlockRect] = []
        var blockOffsets: [Int] = []
        for block in info.blockElements {
            blockOffsets.append(blockRects.count)
            blockRects.append(contentsOf: block.rects.map { CmdyRenderBlockRect(x0: $0.x0, x1: $0.x1, y0: $0.y0, y1: $0.y1, alpha: $0.alpha.rawValue) })
        }
        return boundaries.withUnsafeBufferPointer { boundaryBuffer in
            blockRects.withUnsafeBufferPointer { blockBuffer in
                let segments = info.segments.enumerated().map { index, segment in
                    CmdyRenderTextSegment(
                        attributed_string: Unmanaged.passUnretained(attributedStrings[index]).toOpaque(),
                        column: segment.column, column_width: segment.columnWidth,
                        character_count: segment.characterCount,
                        boundaries: boundaryBuffer.baseAddress.map { $0.advanced(by: boundaryOffsets[index]) },
                        boundary_count: segment.cellUTF16Boundaries?.count ?? 0,
                        has_boundaries: segment.cellUTF16Boundaries == nil ? 0 : 1,
                        disable_sharing: normalizedStyles[index] ? 1 : 0)
                }
                let blocks = info.blockElements.enumerated().map { index, block in
                    CmdyRenderBlock(column: block.column, column_width: block.columnWidth,
                                    code_point: block.codePoint,
                                    rects: blockBuffer.baseAddress.map { $0.advanced(by: blockOffsets[index]) },
                                    rect_count: block.rects.count,
                                    foreground: Unmanaged.passUnretained(block.foregroundColor).toOpaque())
                }
                let boxes = info.boxDrawings.map { box in
                    CmdyRenderBox(column: box.column, column_width: box.columnWidth,
                                  code_point: box.codePoint,
                                  foreground: Unmanaged.passUnretained(box.foregroundColor).toOpaque())
                }
                return segments.withUnsafeBufferPointer { segmentBuffer in
                    blocks.withUnsafeBufferPointer { blocksBuffer in
                        boxes.withUnsafeBufferPointer { boxesBuffer in
                            var input = CmdyRenderRowInput(
                                segments: segmentBuffer.baseAddress, segment_count: segmentBuffer.count,
                                blocks: blocksBuffer.baseAddress, block_count: blocksBuffer.count,
                                boxes: boxesBuffer.baseAddress, box_count: boxesBuffer.count,
                                cols: cols, width: width, height: height,
                                cell_width: cellWidth, cell_height: cellHeight, scale: scale,
                                underline_position: underlinePosition, underline_thickness: underlineThickness,
                                normal_font: Unmanaged.passUnretained(normalFont).toOpaque(),
                                foreground: Unmanaged.passUnretained(nativeForeground).toOpaque(),
                                coverage_exponent: preset.coverageExponent, snaps_y: preset.snapsY ? 1 : 0,
                                antialias_blocks: antialiasBlocks ? 1 : 0,
                                ascii_caching: asciiCaching ? 1 : 0, font_caching: fontCaching ? 1 : 0)
                            return withExtendedLifetime((info, attributedStrings, normalFont, nativeForeground)) {
                                withUnsafePointer(to: &input, body)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Freeze the same normalized text input used by the synchronous renderer.
    /// The caller handles unsupported attributes explicitly; capture never
    /// discards them or borrows mutable host storage for a worker.
    static func captureNativeInput(
        info: ViewLineInfo, cols: Int, width: Int, height: Int,
        cellWidth: CGFloat, cellHeight: CGFloat, scale: CGFloat,
        normalFont: NSFont, nativeForeground: NSColor,
        underlinePosition: CGFloat, underlineThickness: CGFloat,
        preset: TextRenderingMode, antialiasBlocks: Bool,
        asciiCaching: Bool = true, fontCaching: Bool = true
    ) -> Result<CapturedRowInput, RowInputCaptureFailure> {
        withNativeInput(info: info, cols: cols, width: width, height: height,
            cellWidth: cellWidth, cellHeight: cellHeight, scale: scale,
            normalFont: normalFont, nativeForeground: nativeForeground,
            underlinePosition: underlinePosition, underlineThickness: underlineThickness,
            preset: preset, antialiasBlocks: antialiasBlocks,
            asciiCaching: asciiCaching, fontCaching: fontCaching) { CapturedRowInput.capture($0) }
    }

    static func rasterize(info: ViewLineInfo, cols: Int, width: Int, height: Int,
                          cellWidth: CGFloat, cellHeight: CGFloat, scale: CGFloat,
                          normalFont: NSFont, nativeForeground: NSColor,
                          underlinePosition: CGFloat, underlineThickness: CGFloat,
                          preset: TextRenderingMode, antialiasBlocks: Bool,
                          asciiCaching: Bool = true, fontCaching: Bool = true) -> IndependentCPURow? {
        withNativeInput(info: info, cols: cols, width: width, height: height,
                        cellWidth: cellWidth, cellHeight: cellHeight, scale: scale,
                        normalFont: normalFont, nativeForeground: nativeForeground,
                        underlinePosition: underlinePosition, underlineThickness: underlineThickness,
                        preset: preset, antialiasBlocks: antialiasBlocks,
                        asciiCaching: asciiCaching, fontCaching: fontCaching) { input in
            guard let handle = cmdy_render_row_create(input) else { return nil }
            defer { cmdy_render_row_free(handle) }
            var view = CmdyRenderRowView()
            cmdy_render_row_view(handle, &view)
            func solids(_ pointer: UnsafePointer<CmdyRenderSolid>?, _ count: Int) -> [IndependentSolidRect] {
                UnsafeBufferPointer(start: pointer, count: count).map { IndependentSolidRect(rect: $0.rect.cgRect, color: $0.color.simd) }
            }
            return IndependentCPURow(
                coverage: Array(UnsafeBufferPointer(start: view.coverage, count: view.coverage_count)),
                colorTiles: UnsafeBufferPointer(start: view.color_tiles, count: view.color_tile_count).map {
                    IndependentColorTile(rect: $0.rect.cgRect, width: $0.width, height: $0.height,
                                         bytes: Array(UnsafeBufferPointer(start: $0.bytes, count: $0.byte_count)))
                },
                backgrounds: solids(view.backgrounds, view.background_count),
                tintSpans: UnsafeBufferPointer(start: view.tints, count: view.tint_count).map {
                    IndependentTintSpan(rect: $0.rect.cgRect, glyphEnvelope: $0.has_envelope != 0 ? $0.envelope.cgRect : nil,
                                        replacedByAtlas: $0.replaced_by_atlas != 0, color: $0.color.simd)
                },
                glyphSeeds: UnsafeBufferPointer(start: view.glyphs, count: view.glyph_count).map {
                    IndependentGlyphSeed(font: Unmanaged<CTFont>.fromOpaque($0.font!).takeUnretainedValue(),
                                         glyph: $0.glyph, rect: $0.rect.cgRect, color: $0.color.simd)
                },
                decorations: solids(view.decorations, view.decoration_count),
                images: (info.images ?? []).map {
                    IndependentRowImage(image: WeakRenderableImage($0), col: $0.col, zIndex: $0.kittyZIndex,
                                        pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight,
                                        pixelOffsetX: $0.kittyPixelOffsetX, pixelOffsetY: $0.kittyPixelOffsetY,
                                        kittyImageId: $0.kittyImageId, kittyIsKitty: $0.kittyIsKitty)
                }, kittyPlaceholders: info.kittyPlaceholders, width: view.width, height: view.height)
        }
    }
    static func rgba(_ color: NSColor) -> SIMD4<Float> { cmdy_render_color(Unmanaged.passUnretained(color).toOpaque()).simd }
    static func packedColor(_ color: NSColor) -> UInt64 { cmdy_render_packed_color(Unmanaged.passUnretained(color).toOpaque()) }
    static func centeredBaseline(rowHeight: CGFloat, ascent: CGFloat, descent: CGFloat, leading: CGFloat, snapsToDevicePixel: Bool) -> CGFloat {
        cmdy_render_centered_baseline(rowHeight, ascent, descent, leading, snapsToDevicePixel ? 1 : 0)
    }
    static func gridBaseline(rowHeight: CGFloat, font: NSFont, scale: CGFloat = 1, snapsToDevicePixel: Bool) -> CGFloat {
        cmdy_render_grid_baseline(rowHeight, Unmanaged.passUnretained(font).toOpaque(), scale, snapsToDevicePixel ? 1 : 0)
    }
    static func terminalCellTextOrigin(cellMinX: CGFloat, cellWidth: CGFloat, lineWidth: CGFloat) -> CGFloat {
        cmdy_render_cell_text_origin(cellMinX, cellWidth, lineWidth)
    }
    static func terminalBlockCoverage(alpha: BlockAlpha, preset: TextRenderingMode) -> Float { cmdy_render_block_coverage(alpha.rawValue, preset.coverageExponent) }
    static func terminalBoxStrokeThickness(underlineThickness: CGFloat, scale: CGFloat) -> Int { cmdy_render_box_thickness(underlineThickness, scale) }
    static func terminalStrikethroughRect(rect: CGRect, y: CGFloat, scaledThickness: CGFloat) -> CGRect {
        cmdy_render_strikethrough(CmdyRenderRect(rect), y, scaledThickness).cgRect
    }
    static func terminalUnderlineRects(style: RenderUnderlineStyle, rect: CGRect, underlineY: CGFloat, thickness: CGFloat) -> [CGRect] {
        let count = cmdy_render_underlines(style.rawValue, CmdyRenderRect(rect), underlineY, thickness, nil, 0)
        var values = [CmdyRenderRect](repeating: CmdyRenderRect(), count: count)
        _ = cmdy_render_underlines(style.rawValue, CmdyRenderRect(rect), underlineY, thickness, &values, count)
        return values.map(\.cgRect)
    }
}
