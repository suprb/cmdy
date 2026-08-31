import AppKit
import CoreGraphics
import CoreText
import Foundation
import Metal

struct IndependentSolidRect {
    var rect: CGRect // row-local device pixels, y-down
    var color: SIMD4<Float>
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

private struct IndependentFrozenGlyphGeometry {
    let font: CTFont
    let glyph: CGGlyph
    let quartzRect: CGRect
}

private struct IndependentFrozenGlyphClip {
    let envelope: CGRect
    let glyphs: [IndependentFrozenGlyphGeometry]
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

struct IndependentColorLayer {
    let texture: MTLTexture
    let rect: CGRect
}

struct IndependentRowCacheEntry {
    let key: IndependentRowKey
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

@MainActor
enum IndependentRowRasterizer {
    static func rasterize(info: ViewLineInfo,
                          cols: Int,
                          width: Int,
                          height: Int,
                          cellWidth: CGFloat,
                          cellHeight: CGFloat,
                          scale: CGFloat,
                          normalFont: NSFont,
                          nativeForeground: NSColor,
                          underlinePosition: CGFloat,
                          underlineThickness: CGFloat,
                          preset: TextRenderingMode,
                          antialiasBlocks: Bool,
                          asciiCaching: Bool = true) -> IndependentCPURow? {
        guard cols > 0, width > 0, height > 0,
              width <= 32_768, height <= 2_048,
              width <= Int.max / height else { return nil }
        guard let coverageContext = CGContext(data: nil,
                                              width: width,
                                              height: height,
                                              bitsPerComponent: 8,
                                              bytesPerRow: width,
                                              space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }
        coverageContext.setFillColor(CGColor(gray: 0, alpha: 1))
        coverageContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        coverageContext.setAllowsAntialiasing(true)
        coverageContext.setShouldAntialias(true)
        coverageContext.textMatrix = .identity

        var row = IndependentCPURow(coverage: [], colorTiles: [],
                                    backgrounds: [], tintSpans: [], glyphSeeds: [],
                                    decorations: [], images: [],
                                    kittyPlaceholders: info.kittyPlaceholders,
                                    width: width, height: height)
        for segment in info.segments {
            rasterize(segment: segment, in: coverageContext, row: &row,
                      width: width, height: height,
                      cellWidth: cellWidth, cellHeight: cellHeight,
                      scale: scale,
                      normalFont: normalFont,
                      nativeForeground: nativeForeground,
                      underlinePosition: underlinePosition * scale,
                      underlineThickness: underlineThickness * scale,
                      preset: preset, asciiCaching: asciiCaching)
        }

        let white = NSColor.white
        let boxThickness = terminalBoxStrokeThickness(
            underlineThickness: underlineThickness,
            scale: scale)
        for item in info.boxDrawings {
            let x = CGFloat(item.column) * cellWidth
            let w = CGFloat(max(1, item.columnWidth)) * cellWidth
            coverageContext.saveGState()
            coverageContext.clip(to: CGRect(x: x, y: 0, width: w, height: cellHeight))
            coverageContext.translateBy(x: 0, y: cellHeight)
            coverageContext.scaleBy(x: 1, y: -1)
            BoxDrawingRenderer.draw(codePoint: item.codePoint,
                                    in: coverageContext,
                                    cellOrigin: CGPoint(x: x, y: 0),
                                    cellSize: CGSize(width: w / scale,
                                                     height: cellHeight / scale),
                                    scale: scale,
                                    color: white,
                                    baseThicknessPx: boxThickness)
            coverageContext.restoreGState()
            row.tintSpans.append(IndependentTintSpan(
                rect: CGRect(x: x, y: 0, width: w, height: cellHeight),
                color: rgba(item.foregroundColor)))
        }

        for item in info.blockElements {
            let baseX = CGFloat(item.column) * cellWidth
            let spanWidth = CGFloat(max(1, item.columnWidth)) * cellWidth
            for element in item.rects {
                let rect = CGRect(
                    x: baseX + CGFloat(element.x0) / 8 * spanWidth,
                    y: CGFloat(element.y0) / 8 * cellHeight,
                    width: CGFloat(element.x1 - element.x0) / 8 * spanWidth,
                    height: CGFloat(element.y1 - element.y0) / 8 * cellHeight)
                var color = rgba(item.foregroundColor)
                color.w *= terminalBlockCoverage(
                    alpha: element.alpha,
                    preset: preset)
                row.decorations.append(IndependentSolidRect(rect: pixelAligned(rect),
                                                              color: color))
            }
        }

        row.images = (info.images ?? []).map { image in
            IndependentRowImage(image: WeakRenderableImage(image),
                                col: image.col,
                                zIndex: image.kittyZIndex,
                                pixelWidth: image.pixelWidth,
                                pixelHeight: image.pixelHeight,
                                pixelOffsetX: image.kittyPixelOffsetX,
                                pixelOffsetY: image.kittyPixelOffsetY,
                                kittyImageId: image.kittyImageId,
                                kittyIsKitty: image.kittyIsKitty)
        }

        guard let data = coverageContext.data else { return nil }
        row.coverage = Array(UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self),
            count: width * height))
        return row
    }

    private static func rasterize(segment: ViewLineSegment,
                                  in coverageContext: CGContext,
                                  row: inout IndependentCPURow,
                                  width: Int,
                                  height: Int,
                                  cellWidth: CGFloat,
                                  cellHeight: CGFloat,
                                  scale: CGFloat,
                                  normalFont: NSFont,
                                  nativeForeground: NSColor,
                                  underlinePosition: CGFloat,
                                  underlineThickness: CGFloat,
                                  preset: TextRenderingMode,
                                  asciiCaching: Bool) {
        guard segment.characterCount > 0, segment.columnWidth > 0,
              segment.attributedString.length > 0 else { return }
        let boundaries = cellBoundaries(for: segment)
        guard boundaries.count == segment.characterCount + 1 else { return }
        if asciiCaching, rasterizeCachedMonospacedASCII(
            segment: segment, boundaries: boundaries,
            in: coverageContext, row: &row,
            width: width, height: height,
            cellWidth: cellWidth, cellHeight: cellHeight,
            scale: scale, normalFont: normalFont,
            nativeForeground: nativeForeground,
            underlinePosition: underlinePosition,
            underlineThickness: underlineThickness,
            preset: preset) {
            return
        }
        let naturalBoundaries = TerminalCellIndexMap(
            text: segment.attributedString.string).boundaries

        for cell in 0..<segment.characterCount {
            let lower = boundaries[cell]
            let upper = boundaries[cell + 1]
            guard lower >= 0, upper >= lower,
                  upper <= segment.attributedString.length else { continue }
            let terminalColumn = segment.column + cell * segment.columnWidth
            let x = CGFloat(terminalColumn) * cellWidth
            let spanWidth = CGFloat(segment.columnWidth) * cellWidth
            guard x < CGFloat(width), x + spanWidth > 0 else { continue }

            let attributes = segment.attributedString.attributes(
                at: min(lower, segment.attributedString.length - 1),
                effectiveRange: nil)
            if let background = selectionOrBackground(attributes) {
                row.backgrounds.append(IndependentSolidRect(
                    rect: pixelAligned(CGRect(x: x, y: 0,
                                              width: spanWidth,
                                              height: cellHeight)),
                    color: rgba(background)))
            }
            guard upper > lower else { continue }
            let font: NSFont
            if let attributedFont = attributes[.font] as? NSFont {
                font = NSFont(descriptor: attributedFont.fontDescriptor,
                              size: attributedFont.pointSize * scale) ?? normalFont
            } else {
                font = normalFont
            }
            let foreground = (attributes[.foregroundColor] as? NSColor)
                ?? nativeForeground
            let rect = CGRect(x: x, y: 0, width: spanWidth, height: cellHeight)
            if let glyphRange = glyphRange(
                forCell: cell,
                explicitBoundaries: boundaries,
                naturalBoundaries: naturalBoundaries) {
                let attributed = segment.attributedString.attributedSubstring(
                    from: glyphRange)
                if isColorGlyphText(attributed.string, font: font) {
                    if let tile = colorTile(for: attributed, font: font,
                                            gridFont: normalFont,
                                            width: max(1, Int(spanWidth.rounded())),
                                            height: height,
                                            globalRect: rect,
                                            scale: scale,
                                            preset: preset) {
                        row.colorTiles.append(tile)
                    }
                } else {
                    let glyphResult = drawCoverage(
                        attributed, font: font,
                        gridFont: normalFont,
                        in: coverageContext, rect: rect,
                        rowHeight: CGFloat(height), scale: scale,
                        preset: preset,
                        foreground: rgba(foreground))
                    row.tintSpans.append(IndependentTintSpan(
                        rect: rect, glyphEnvelope: glyphResult.envelope,
                        replacedByAtlas: true,
                        color: rgba(foreground)))
                    row.glyphSeeds.append(contentsOf: glyphResult.glyphs)
                }
            }

            addDecorations(attributes: attributes, font: font,
                           foreground: foreground, rect: rect,
                           rowHeight: CGFloat(height),
                           scale: scale,
                           underlinePosition: underlinePosition,
                           underlineThickness: underlineThickness,
                           to: &row.decorations)
        }
    }

    /// Ordinary shell output is overwhelmingly one-byte ASCII in a single
    /// fixed-width attribute run. The general path creates a fresh attributed
    /// substring and CoreText line for every terminal cell so Unicode clusters
    /// stay exact; repeating that work for 98 ASCII cells dominates a fast
    /// scroll. Prepare each distinct ASCII glyph once per segment, then reuse
    /// its immutable line while retaining the original per-cell draw, clip,
    /// tint, background, and decoration path. This deliberately does not use
    /// `CTFontDrawGlyphs`: Core Graphics can rasterize a multi-glyph call
    /// differently at fractional insets. Complex text continues through the
    /// general path unchanged.
    private static func rasterizeCachedMonospacedASCII(
        segment: ViewLineSegment,
        boundaries: [Int],
        in context: CGContext,
        row: inout IndependentCPURow,
        width: Int,
        height: Int,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        scale: CGFloat,
        normalFont: NSFont,
        nativeForeground: NSColor,
        underlinePosition: CGFloat,
        underlineThickness: CGFloat,
        preset: TextRenderingMode
    ) -> Bool {
        let attributed = segment.attributedString
        let cellCount = segment.characterCount
        guard segment.columnWidth == 1,
              attributed.length == cellCount,
              boundaries.elementsEqual(0...cellCount),
              attributed.string.unicodeScalars.allSatisfy({
                  $0.value >= 0x20 && $0.value <= 0x7E
              }) else { return false }

        var effectiveRange = NSRange()
        let attributes = attributed.attributes(
            at: 0, effectiveRange: &effectiveRange)
        guard effectiveRange.location == 0,
              effectiveRange.length == attributed.length else { return false }

        let terminalColumn = segment.column
        let x = CGFloat(terminalColumn) * cellWidth
        let spanWidth = CGFloat(cellCount) * cellWidth
        guard x >= 0, x + spanWidth <= CGFloat(width) else { return false }

        let font: NSFont
        if let attributedFont = attributes[.font] as? NSFont {
            font = NSFont(
                descriptor: attributedFont.fontDescriptor,
                size: attributedFont.pointSize * scale) ?? normalFont
        } else {
            font = normalFont
        }
        let foreground = (attributes[.foregroundColor] as? NSColor)
            ?? nativeForeground
        let foregroundRGBA = rgba(foreground)
        let characters = Array(attributed.string.utf16)
        var lineCache: [UInt16: CTLine] = [:]
        lineCache.reserveCapacity(min(cellCount, 95))

        for index in 0..<cellCount {
            let rect = CGRect(
                x: x + CGFloat(index) * cellWidth, y: 0,
                width: cellWidth, height: cellHeight)
            if let background = selectionOrBackground(attributes) {
                row.backgrounds.append(IndependentSolidRect(
                    rect: pixelAligned(rect), color: rgba(background)))
            }
            let codeUnit = characters[index]
            let line: CTLine
            if let cached = lineCache[codeUnit] {
                line = cached
            } else {
                let source = attributed.attributedSubstring(
                    from: NSRange(location: index, length: 1))
                let prepared = coverageLine(source, font: font)
                lineCache[codeUnit] = prepared
                line = prepared
            }
            let glyphResult = drawCoverage(
                line, gridFont: normalFont,
                in: context, rect: rect,
                rowHeight: CGFloat(height), scale: scale,
                preset: preset, foreground: foregroundRGBA)
            row.tintSpans.append(IndependentTintSpan(
                rect: rect, glyphEnvelope: glyphResult.envelope,
                replacedByAtlas: true, color: foregroundRGBA))
            row.glyphSeeds.append(contentsOf: glyphResult.glyphs)
            addDecorations(
                attributes: attributes, font: font,
                foreground: foreground, rect: rect,
                rowHeight: CGFloat(height), scale: scale,
                underlinePosition: underlinePosition,
                underlineThickness: underlineThickness,
                to: &row.decorations)
        }
        return true
    }

    /// Explicit engine cells remain the source of terminal placement, but the
    /// frozen renderer still lets CoreText shape a Unicode grapheme spanning
    /// adjacent explicit boundaries. The composed glyph is clipped to and
    /// tinted by the first cell; continuation cells contribute no glyph.
    private static func glyphRange(
        forCell cell: Int,
        explicitBoundaries: [Int],
        naturalBoundaries: [Int]
    ) -> NSRange? {
        guard cell >= 0, cell + 1 < explicitBoundaries.count else { return nil }
        let lower = explicitBoundaries[cell]
        let upper = explicitBoundaries[cell + 1]
        guard upper > lower else { return nil }

        for pair in zip(naturalBoundaries, naturalBoundaries.dropFirst()) {
            let naturalLower = pair.0
            let naturalUpper = pair.1
            guard lower >= naturalLower, lower < naturalUpper else { continue }
            if lower > naturalLower { return nil }
            let glyphUpper = max(upper, naturalUpper)
            return NSRange(location: lower, length: glyphUpper - lower)
        }
        return NSRange(location: lower, length: upper - lower)
    }

    private static func cellBoundaries(for segment: ViewLineSegment) -> [Int] {
        if let explicit = segment.cellUTF16Boundaries { return explicit }
        let map = TerminalCellIndexMap(text: segment.attributedString.string)
        var result = map.boundaries
        if result.count > segment.characterCount + 1 {
            result = Array(result.prefix(segment.characterCount))
            result.append(segment.attributedString.length)
        } else {
            while result.count < segment.characterCount + 1 {
                result.append(segment.attributedString.length)
            }
        }
        return result
    }

    private static func drawCoverage(_ source: NSAttributedString,
                                     font: NSFont,
                                     gridFont: NSFont,
                                     in context: CGContext,
                                     rect: CGRect,
                                     rowHeight: CGFloat,
                                     scale: CGFloat,
                                     preset: TextRenderingMode,
                                     foreground: SIMD4<Float>)
        -> (envelope: CGRect?, glyphs: [IndependentGlyphSeed]) {
        drawCoverage(
            coverageLine(source, font: font), gridFont: gridFont,
            in: context, rect: rect, rowHeight: rowHeight,
            scale: scale, preset: preset, foreground: foreground)
    }

    private static func coverageLine(
        _ source: NSAttributedString,
        font: NSFont
    ) -> CTLine {
        let text = NSMutableAttributedString(attributedString: source)
        let full = NSRange(location: 0, length: text.length)
        let shapingFont = terminalGridShapingFont(font as CTFont)
        text.addAttributes([.font: shapingFont,
                            .foregroundColor: NSColor.white,
                            .ligature: 0,
                            .kern: 0], range: full)
        text.removeAttribute(.backgroundColor, range: full)
        text.removeAttribute(.underlineStyle, range: full)
        text.removeAttribute(.strikethroughStyle, range: full)
        return CTLineCreateWithAttributedString(text)
    }

    private static func drawCoverage(_ line: CTLine,
                                     gridFont: NSFont,
                                     in context: CGContext,
                                     rect: CGRect,
                                     rowHeight: CGFloat,
                                     scale: CGFloat,
                                     preset: TextRenderingMode,
                                     foreground: SIMD4<Float>)
        -> (envelope: CGRect?, glyphs: [IndependentGlyphSeed]) {
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let baseline = gridBaseline(rowHeight: rowHeight, font: gridFont,
                                    scale: scale,
                                    snapsToDevicePixel: preset.snapsY)
        let x = terminalCellTextOrigin(
            cellMinX: rect.minX,
            cellWidth: rect.width,
            lineWidth: lineWidth)
        context.saveGState()
        let clip = clipToFrozenGlyphBitmaps(
            line: line, origin: CGPoint(x: x, y: baseline), in: context)
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
        guard let clip else { return (nil, []) }
        func yDown(_ value: CGRect) -> CGRect {
            CGRect(x: value.minX,
                   y: rowHeight - value.maxY,
                   width: value.width,
                   height: value.height)
        }
        return (
            yDown(clip.envelope),
            clip.glyphs.map {
                IndependentGlyphSeed(font: $0.font, glyph: $0.glyph,
                                     rect: yDown($0.quartzRect),
                                     color: foreground)
            })
    }

    private static func colorTile(for source: NSAttributedString,
                                  font: NSFont,
                                  gridFont: NSFont,
                                  width: Int,
                                  height: Int,
                                  globalRect: CGRect,
                                  scale: CGFloat,
                                  preset: TextRenderingMode) -> IndependentColorTile? {
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.textMatrix = .identity
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        let text = NSMutableAttributedString(attributedString: source)
        let full = NSRange(location: 0, length: text.length)
        text.addAttributes([.font: terminalGridShapingFont(font as CTFont),
                            .ligature: 0, .kern: 0], range: full)
        text.removeAttribute(.backgroundColor, range: full)
        text.removeAttribute(.underlineStyle, range: full)
        text.removeAttribute(.strikethroughStyle, range: full)
        let line = CTLineCreateWithAttributedString(text)
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let baseline = gridBaseline(rowHeight: CGFloat(height), font: gridFont,
                                    scale: scale,
                                    snapsToDevicePixel: preset.snapsY)
        let origin = CGPoint(
            x: terminalCellTextOrigin(cellMinX: 0,
                                      cellWidth: CGFloat(width),
                                      lineWidth: lineWidth),
            y: baseline)
        _ = clipToFrozenGlyphBitmaps(line: line, origin: origin, in: context)
        context.textPosition = origin
        CTLineDraw(line, context)
        guard let data = context.data else { return nil }
        let bytes = Array(UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self),
            count: width * height * 4))
        return IndependentColorTile(rect: CGRect(x: globalRect.minX, y: 0,
                                                 width: CGFloat(width),
                                                 height: CGFloat(height)),
                                    width: width, height: height, bytes: bytes)
    }

    /// The frozen atlas rasterizer allocates each glyph from the integer
    /// envelope of `CTFontGetBoundingRectsForGlyphs`. Drawing a whole line into
    /// a row-sized bitmap otherwise preserves CoreGraphics fringe pixels that
    /// the atlas never stored, and clips legitimate italic overhang at the cell
    /// boundary. Recreate the atlas envelopes while keeping the row cache.
    private static func clipToFrozenGlyphBitmaps(
        line: CTLine,
        origin: CGPoint,
        in context: CGContext
    ) -> IndependentFrozenGlyphClip? {
        var rectangles: [CGRect] = []
        var glyphRecords: [IndependentFrozenGlyphGeometry] = []
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let fontValue = attributes[kCTFontAttributeName] else { continue }
            let font = fontValue as! CTFont
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            for index in 0..<count {
                var glyph = glyphs[index]
                let bounds = CTFontGetBoundingRectsForGlyphs(
                    font, .default, &glyph, nil, 1)
                guard bounds.width > 0, bounds.height > 0,
                      bounds.width.isFinite, bounds.height.isFinite else { continue }
                let x0 = bounds.minX.rounded(.down)
                let y0 = bounds.minY.rounded(.down)
                let x1 = bounds.maxX.rounded(.up)
                let y1 = bounds.maxY.rounded(.up)
                let rectangle = CGRect(
                    x: origin.x + positions[index].x + x0,
                    y: origin.y + positions[index].y + y0,
                    width: x1 - x0,
                    height: y1 - y0)
                rectangles.append(rectangle)
                glyphRecords.append(IndependentFrozenGlyphGeometry(
                    font: font, glyph: glyph, quartzRect: rectangle))
            }
        }
        guard !rectangles.isEmpty else {
            context.clip(to: .zero)
            return nil
        }
        context.beginPath()
        for rectangle in rectangles { context.addRect(rectangle) }
        context.clip()
        let envelope = rectangles.dropFirst().reduce(rectangles[0]) { $0.union($1) }
        return IndependentFrozenGlyphClip(envelope: envelope,
                                          glyphs: glyphRecords)
    }

    private static func selectionOrBackground(
        _ attributes: [NSAttributedString.Key: Any]
    ) -> NSColor? {
        (attributes[.selectionBackgroundColor] as? NSColor)
            ?? (attributes[.cmdySelectionBackground] as? NSColor)
            ?? (attributes[.backgroundColor] as? NSColor)
    }

    private static func addDecorations(
        attributes: [NSAttributedString.Key: Any],
        font: NSFont,
        foreground: NSColor,
        rect: CGRect,
        rowHeight: CGFloat,
        scale: CGFloat,
        underlinePosition: CGFloat,
        underlineThickness: CGFloat,
        to output: inout [IndependentSolidRect]
    ) {
        let underline = resolvedUnderlineStyle(attributes)
        let underlineColor = (attributes[.cmdyUnderlineColor] as? NSColor)
            ?? (attributes[.underlineColor] as? NSColor)
            ?? foreground
        let ascent = CTFontGetAscent(font as CTFont)
        let baseline = gridBaseline(
            rowHeight: rowHeight, font: font, scale: scale,
            snapsToDevicePixel: false)
        let thickness = max(1, underlineThickness.rounded())
        let quartzY = baseline + underlinePosition
        let underlineY = max(0, min(rowHeight - thickness,
                                    rowHeight - quartzY - thickness))
        if underline != .none {
            let color = rgba(underlineColor)
            for underlineRect in terminalUnderlineRects(
                style: underline,
                rect: rect,
                underlineY: underlineY,
                thickness: thickness) {
                output.append(.init(rect: underlineRect, color: color))
            }
        }

        if let raw = attributes[.strikethroughStyle] as? NSNumber,
           raw.intValue != 0 {
            let y = rowHeight - (baseline + ascent * 0.36)
            let color = (attributes[.strikethroughColor] as? NSColor) ?? foreground
            output.append(.init(rect: terminalStrikethroughRect(
                rect: rect, y: y, scaledThickness: thickness),
                                color: rgba(color)))
        }
    }

    static func terminalStrikethroughRect(rect: CGRect,
                                          y: CGFloat,
                                          scaledThickness: CGFloat) -> CGRect {
        // The reference keeps strike-through at one device pixel while
        // preserving the center of the device-scaled font stroke.
        CGRect(x: rect.minX,
               y: y + max(0, scaledThickness - 1) / 2,
               width: rect.width,
               height: 1)
    }

    static func terminalUnderlineRects(style: RenderUnderlineStyle,
                                       rect: CGRect,
                                       underlineY: CGFloat,
                                       thickness: CGFloat) -> [CGRect] {
        guard style != .none, rect.width > 0, thickness > 0 else { return [] }
        // The legacy terminal renderer centers strokes on the underline
        // position. Keeping the fractional origin is important: expanding it
        // with floor/ceil makes a one-pixel stroke two pixels tall.
        let baseY = underlineY + thickness / 2
        func line(x: CGFloat, y: CGFloat, width: CGFloat) -> CGRect {
            CGRect(x: x, y: y,
                   width: min(width, max(0, rect.maxX - x)),
                   height: thickness)
        }

        switch style {
        case .none:
            return []
        case .single:
            return [line(x: rect.minX, y: baseY, width: rect.width)]
        case .double:
            return [line(x: rect.minX, y: baseY, width: rect.width),
                    line(x: rect.minX, y: baseY + thickness * 2,
                         width: rect.width)]
        case .dotted:
            var output: [CGRect] = []
            var x = rect.minX
            while x < rect.maxX {
                output.append(line(x: x, y: baseY, width: thickness))
                x += thickness * 3
            }
            return output
        case .dashed:
            var output: [CGRect] = []
            var x = rect.minX
            while x < rect.maxX {
                output.append(line(x: x, y: baseY, width: thickness * 2))
                x += thickness * 4
            }
            return output
        case .curly:
            var output: [CGRect] = []
            var x = rect.minX
            var phase = 0
            let offsets: [CGFloat] = [0, -thickness, 0, thickness]
            while x < rect.maxX {
                output.append(line(x: x, y: baseY + offsets[phase],
                                   width: thickness))
                x += thickness
                phase = (phase + 1) % offsets.count
            }
            return output
        }
    }

    static func terminalBlockCoverage(alpha: BlockAlpha,
                                      preset: TextRenderingMode) -> Float {
        // The reference first stores block coverage in an 8-bit mask, then
        // applies the same transfer curve as grayscale glyph coverage.
        let byte = (alpha.rawValue * 255).rounded()
        let quantized = Float(byte / 255)
        return pow(quantized, preset.coverageExponent)
    }

    static func terminalBoxStrokeThickness(underlineThickness: CGFloat,
                                           scale: CGFloat) -> Int {
        let scaled = max(1, Int((underlineThickness * scale).rounded()))
        return scaled * 2 - 1
    }

    private static func resolvedUnderlineStyle(
        _ attributes: [NSAttributedString.Key: Any]
    ) -> RenderUnderlineStyle {
        if let style = attributes[.cmdyUnderlineStyle] as? RenderUnderlineStyle {
            return style
        }
        if let raw = attributes[.cmdyUnderlineStyle] as? NSNumber,
           let style = RenderUnderlineStyle(rawValue: raw.uint8Value) {
            return style
        }
        guard let raw = attributes[.underlineStyle] as? NSNumber,
              raw.intValue != 0 else { return .none }
        let style = NSUnderlineStyle(rawValue: raw.intValue)
        if style.contains(.double) { return .double }
        if style.contains(.patternDot) { return .dotted }
        if style.contains(.patternDash) || style.contains(.patternDashDot)
            || style.contains(.patternDashDotDot) { return .dashed }
        return .single
    }

    private static func isColorGlyphText(_ text: String, font: NSFont) -> Bool {
        if font.familyName?.localizedCaseInsensitiveContains("emoji") == true { return true }
        return text.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation
                || (scalar.properties.isEmoji && scalar.value > 0x238C)
        }
    }

    static func rgba(_ color: NSColor) -> SIMD4<Float> {
        let value = color.usingColorSpace(.deviceRGB) ?? color
        return SIMD4(Float(value.redComponent), Float(value.greenComponent),
                     Float(value.blueComponent), Float(value.alphaComponent))
    }

    static func packedColor(_ color: NSColor) -> UInt64 {
        let value = rgba(color)
        let r = UInt64(max(0, min(65_535, Int(value.x * 65_535))))
        let g = UInt64(max(0, min(65_535, Int(value.y * 65_535))))
        let b = UInt64(max(0, min(65_535, Int(value.z * 65_535))))
        let a = UInt64(max(0, min(65_535, Int(value.w * 65_535))))
        return r ^ (g << 16) ^ (b << 32) ^ (a << 48)
    }

    static func centeredBaseline(rowHeight: CGFloat,
                                 ascent: CGFloat,
                                 descent: CGFloat,
                                 leading: CGFloat,
                                 snapsToDevicePixel: Bool) -> CGFloat {
        let fractionalDescent = descent - descent.rounded(.down)
        var baseline = (rowHeight - (ascent + descent + leading)) / 2
            + fractionalDescent
        if snapsToDevicePixel { baseline = baseline.rounded() }
        return baseline
    }

    static func gridBaseline(rowHeight: CGFloat,
                             font: NSFont,
                             scale: CGFloat = 1,
                             snapsToDevicePixel: Bool) -> CGFloat {
        let ctFont = font as CTFont
        let centered = centeredBaseline(
            rowHeight: rowHeight,
            ascent: CTFontGetAscent(ctFont),
            descent: CTFontGetDescent(ctFont),
            leading: CTFontGetLeading(ctFont),
            snapsToDevicePixel: snapsToDevicePixel)
        // A row texture is exactly one cell high. Centering alone can leave
        // less than a full descent below the baseline in ordinary 1.15x rows,
        // clipping every glyph at the bitmap edge. Match the surface's
        // point-rounded descent clearance, then convert back to device pixels.
        // Airier rows retain their centered placement.
        let safeScale = scale.isFinite && scale > 0 ? scale : 1
        let descentAndLeading = CTFontGetDescent(ctFont)
            + CTFontGetLeading(ctFont)
        let minimum = ceil(descentAndLeading / safeScale) * safeScale
        let baseline = min(rowHeight, max(centered, minimum))
        return snapsToDevicePixel ? baseline.rounded() : baseline
    }

    static func terminalCellTextOrigin(cellMinX: CGFloat,
                                       cellWidth: CGFloat,
                                       lineWidth: CGFloat) -> CGFloat {
        // Terminal columns have a fixed origin. Spare glyph advance belongs at
        // the trailing edge; centering it makes every cell drift right.
        _ = cellWidth
        _ = lineWidth
        return cellMinX
    }

    private static func pixelAligned(_ rect: CGRect) -> CGRect {
        let x0 = rect.minX.rounded(.down)
        let y0 = rect.minY.rounded(.down)
        let x1 = rect.maxX.rounded(.up)
        let y1 = rect.maxY.rounded(.up)
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0),
                      height: max(0, y1 - y0))
    }
}
