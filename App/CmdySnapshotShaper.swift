import AppKit
import ImageIO
import CmdyCore
import CmdyGPU

/// Immutable inputs used while converting one captured terminal generation to
/// renderer values.  Keeping these values together makes row shaping a pure
/// operation: it never reaches back into the mutable terminal model.
struct CmdyShapingStyle {
    let palette: [NSColor]
    let normalFont: NSFont
    let boldFont: NSFont
    let italicFont: NSFont
    let boldItalicFont: NSFont
    let foreground: NSColor
    let background: NSColor
    let selectionBackground: NSColor
    let failedRows: Set<Int>
    let failedForeground: NSColor
    let failedBackground: NSColor
}

/// Clean-room snapshot-to-render-value conversion.  All decisions in this
/// type come from SHAPING_SURFACE_CONTRACT.md and the public CmdyGPU seam.
@MainActor
enum CmdySnapshotShaper {
    private struct RunKey: Equatable {
        let attribute: CellAttribute
        let selected: Bool
        let failed: Bool
        let columnWidth: Int
    }

    private struct PendingRun {
        let key: RunKey
        let column: Int
        var text = ""
        var boundaries = [0]
        var cellCount = 0
    }

    static func lineInfo(
        snapshot: CoreTerminalSnapshot,
        absoluteRow: Int,
        style: CmdyShapingStyle,
        selectedColumns: ClosedRange<Int>?
    ) -> ViewLineInfo {
        guard let line = snapshot.line(absolute: absoluteRow) else {
            return ViewLineInfo(segments: [], images: nil)
        }

        let failed = style.failedRows.contains(absoluteRow)
        let lastRepresentedIndex = line.cells.indices.last { index in
            let cell = line.cells[index]
            guard cell.width != 0 else { return false }
            let width = max(1, Int(cell.width))
            let selected = selectedColumns.map {
                rangesOverlap($0, index...(index + width - 1))
            } ?? false
            return failed || selected || cell.scalar != 0
                || cell.attribute != .bufferDefault
        }
        guard let lastRepresentedIndex else {
            return ViewLineInfo(
                segments: [],
                images: wrappedImages(line.images),
                kittyPlaceholders: [],
                blockElements: [],
                boxDrawings: [])
        }

        var segments: [ViewLineSegment] = []
        var blockElements: [BlockElementRenderItem] = []
        var boxDrawings: [BoxDrawingRenderItem] = []
        var placeholders: [KittyPlaceholderCell] = []
        var decoder = KittyUnicodePlaceholderDecoder()
        var pending: PendingRun?

        func flushPending() {
            guard let run = pending, run.cellCount > 0 else {
                pending = nil
                return
            }
            let rendered = NSAttributedString(
                string: run.text,
                attributes: attributes(
                    for: run.key.attribute,
                    selected: run.key.selected,
                    failed: run.key.failed,
                    style: style))
            segments.append(ViewLineSegment(
                column: run.column,
                columnWidth: run.key.columnWidth,
                characterCount: run.cellCount,
                attributedString: rendered,
                cellUTF16Boundaries: run.boundaries))
            pending = nil
        }

        for column in 0...lastRepresentedIndex {
            let cell = line.cells[column]
            guard cell.width != 0 else { continue }
            let width = max(1, Int(cell.width))
            let selected = selectedColumns.map {
                rangesOverlap($0, column...(column + width - 1))
            } ?? false
            let key = RunKey(attribute: cell.attribute, selected: selected,
                             failed: failed, columnWidth: width)

            let placeholder = decoder.decode(
                cell, absoluteRow: absoluteRow, column: column)
            let scalar = cell.scalar
            let proceduralForeground = resolvedColors(
                for: cell.attribute, failed: failed, style: style).foreground
            let displayText: String
            if let placeholder {
                placeholders.append(KittyPlaceholderCell(
                    row: placeholder.row,
                    col: placeholder.col,
                    imageId: placeholder.imageId,
                    placementId: placeholder.placementId,
                    placeholderRow: placeholder.placeholderRow,
                    placeholderCol: placeholder.placeholderCol,
                    msb: placeholder.msb))
                displayText = " "
            } else if scalar == 0x10EEEE {
                // Malformed placeholder metadata is still private protocol
                // data; never leak the private-use scalar into CoreText.
                displayText = " "
            } else if let rects = BlockElementMapping.rects(for: scalar) {
                blockElements.append(BlockElementRenderItem(
                    column: column, columnWidth: width,
                    codePoint: scalar, rects: rects,
                    foregroundColor: proceduralForeground))
                displayText = " "
            } else if scalar >= UInt32(BoxDrawingRenderer.lowerBoundary),
                      scalar <= UInt32(BoxDrawingRenderer.upperBoundary) {
                boxDrawings.append(BoxDrawingRenderItem(
                    column: column, columnWidth: width,
                    codePoint: scalar,
                    foregroundColor: proceduralForeground))
                displayText = " "
            } else {
                decoder.reset()
                displayText = cellText(cell)
            }

            if pending?.key != key {
                flushPending()
                pending = PendingRun(key: key, column: column)
            }
            if var run = pending {
                run.text.append(displayText)
                run.cellCount += 1
                run.boundaries.append(run.text.utf16.count)
                pending = run
            }
        }
        flushPending()

        return ViewLineInfo(
            segments: segments,
            images: wrappedImages(line.images),
            kittyPlaceholders: placeholders,
            blockElements: blockElements,
            boxDrawings: boxDrawings)
    }

    static func cursorString(
        snapshot: CoreTerminalSnapshot,
        style: CmdyShapingStyle,
        caretColor: NSColor,
        caretTextColor: NSColor?
    ) -> NSAttributedString? {
        let grid = snapshot.grid
        guard let line = snapshot.line(absolute: grid.cursorRow),
              grid.cursorCol >= 0, grid.cursorCol < line.cells.count else {
            return nil
        }
        let cell = line.cells[grid.cursorCol]
        let bold = cell.attribute.style.contains(.bold)
        let italic = cell.attribute.style.contains(.italic)
        let font = fontVariant(bold: bold, italic: italic, style: style)
        return NSAttributedString(string: cellText(cell), attributes: [
            .font: font,
            .foregroundColor: caretTextColor ?? style.foreground,
            .backgroundColor: caretColor,
            .ligature: 0,
        ])
    }

    static func attributes(
        for attribute: CellAttribute,
        selected: Bool,
        failed: Bool,
        style: CmdyShapingStyle
    ) -> [NSAttributedString.Key: Any] {
        let colors = resolvedColors(for: attribute, failed: failed, style: style)
        let bold = attribute.style.contains(.bold)
        let italic = attribute.style.contains(.italic)
        var result: [NSAttributedString.Key: Any] = [
            .font: fontVariant(bold: bold, italic: italic, style: style),
            .foregroundColor: colors.foreground,
            .ligature: 0,
        ]

        if colors.hasExplicitBackground || failed {
            result[.backgroundColor] = colors.background
        }
        if selected {
            result[.selectionBackgroundColor] = style.selectionBackground
        }
        if attribute.style.contains(.underline) {
            let kind = attribute.underlineKind == .none
                ? UnderlineKind.single : attribute.underlineKind
            result[.underlineStyle] = NSUnderlineStyle.single.rawValue
            result[CmdyUnderlineStyleKey] = RenderUnderlineStyle(
                rawValue: kind.rawValue)?.rawValue ?? RenderUnderlineStyle.single.rawValue
            let underline = attribute.underlineColor.map {
                mapColor($0, role: .foreground, bold: bold,
                         invertedDefault: false, style: style)
            } ?? colors.foreground
            result[.underlineColor] = underline
        }
        if attribute.style.contains(.crossedOut) {
            result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            result[.strikethroughColor] = colors.foreground
        }
        return result
    }

    static func mapColor(
        _ color: CellColor,
        isForeground: Bool,
        isBold: Bool,
        style: CmdyShapingStyle
    ) -> NSColor {
        mapColor(color, role: isForeground ? .foreground : .background,
                 bold: isBold, invertedDefault: false, style: style)
    }

    static func needsExplicitBackground(_ attribute: CellAttribute) -> Bool {
        attribute.bg != .defaultColor
            || attribute.style.contains(.inverse)
    }

    private enum ColorRole: Equatable { case foreground, background }

    private struct ResolvedColors {
        let foreground: NSColor
        let background: NSColor
        let hasExplicitBackground: Bool
    }

    private static func resolvedColors(
        for attribute: CellAttribute,
        failed: Bool,
        style: CmdyShapingStyle
    ) -> ResolvedColors {
        if failed {
            return ResolvedColors(
                foreground: style.failedForeground,
                background: style.failedBackground,
                hasExplicitBackground: true)
        }

        let inverse = attribute.style.contains(.inverse)
        let fgToken = inverse ? attribute.bg : attribute.fg
        let bgToken = inverse ? attribute.fg : attribute.bg
        let bold = attribute.style.contains(.bold)
        var foreground = mapColor(
            fgToken, role: .foreground, bold: bold,
            invertedDefault: inverse, style: style)
        let background = mapColor(
            bgToken, role: .background, bold: false,
            invertedDefault: inverse, style: style)
        if attribute.style.contains(.dim) {
            foreground = midpoint(foreground, background)
        }
        if attribute.style.contains(.invisible) {
            foreground = background
        }
        return ResolvedColors(
            foreground: foreground,
            background: background,
            hasExplicitBackground: inverse || bgToken != .defaultColor)
    }

    private static func mapColor(
        _ color: CellColor,
        role: ColorRole,
        bold: Bool,
        invertedDefault: Bool,
        style: CmdyShapingStyle
    ) -> NSColor {
        switch color {
        case .ansi256(let raw):
            var index = Int(raw)
            if role == .foreground, bold, index <= 6 { index += 8 }
            return style.palette.indices.contains(index)
                ? style.palette[index]
                : (role == .foreground ? style.foreground : style.background)
        case .trueColor(let red, let green, let blue):
            return NSColor(srgbRed: CGFloat(red) / 255,
                           green: CGFloat(green) / 255,
                           blue: CGFloat(blue) / 255,
                           alpha: 1)
        case .defaultColor:
            let native = role == .foreground ? style.foreground : style.background
            return invertedDefault ? complement(native) : native
        case .defaultInverted:
            let native = role == .foreground ? style.foreground : style.background
            return complement(native)
        }
    }

    private static func complement(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        return NSColor(srgbRed: 1 - rgb.redComponent,
                       green: 1 - rgb.greenComponent,
                       blue: 1 - rgb.blueComponent,
                       alpha: rgb.alphaComponent)
    }

    private static func midpoint(_ first: NSColor, _ second: NSColor) -> NSColor {
        guard let a = first.usingColorSpace(.sRGB),
              let b = second.usingColorSpace(.sRGB) else { return first }
        return NSColor(srgbRed: (a.redComponent + b.redComponent) / 2,
                       green: (a.greenComponent + b.greenComponent) / 2,
                       blue: (a.blueComponent + b.blueComponent) / 2,
                       alpha: (a.alphaComponent + b.alphaComponent) / 2)
    }

    private static func fontVariant(
        bold: Bool, italic: Bool, style: CmdyShapingStyle
    ) -> NSFont {
        switch (bold, italic) {
        case (true, true): return style.boldItalicFont
        case (true, false): return style.boldFont
        case (false, true): return style.italicFont
        case (false, false): return style.normalFont
        }
    }

    private static func cellText(_ cell: Cell) -> String {
        guard cell.scalar != 0, let first = Unicode.Scalar(cell.scalar) else {
            return " "
        }
        var result = String(first)
        for raw in cell.clusterExtras ?? [] {
            if let scalar = Unicode.Scalar(raw) { result.unicodeScalars.append(scalar) }
        }
        return result
    }

    private static func rangesOverlap(
        _ lhs: ClosedRange<Int>, _ rhs: ClosedRange<Int>
    ) -> Bool {
        lhs.lowerBound <= rhs.upperBound && rhs.lowerBound <= lhs.upperBound
    }

    private static func wrappedImages(
        _ images: [CoreLineImageSnapshot]
    ) -> [any RenderableCellImage]? {
        guard !images.isEmpty else { return nil }
        return images.map { CmdyCellImage.wrap($0) }
    }
}

/// Deterministic access ordering makes the fixed cache bound observable and
/// independent of ambient memory pressure.
private struct CmdyImageAccessCache<Key: Hashable, Value: AnyObject> {
    private let capacity: Int
    private var entries: [Key: Value] = [:]
    private var accessOrder: [Key] = []

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    mutating func value(for key: Key) -> Value? {
        guard let value = entries[key] else { return nil }
        recordAccess(to: key)
        return value
    }

    mutating func insert(_ value: Value, for key: Key) {
        let replacedExistingValue = entries.updateValue(value, forKey: key) != nil
        if replacedExistingValue {
            recordAccess(to: key)
            return
        }

        accessOrder.append(key)
        if entries.count > capacity {
            let leastRecentlyUsed = accessOrder.removeFirst()
            entries.removeValue(forKey: leastRecentlyUsed)
        }
    }

    private mutating func recordAccess(to key: Key) {
        if let previousIndex = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: previousIndex)
        }
        accessOrder.append(key)
    }
}

private struct CmdyCheckedPixelLayout {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let byteCount: Int

    init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        let (bytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (byteCount, imageOverflow) =
            bytesPerRow.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !imageOverflow else { return nil }

        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.byteCount = byteCount
    }
}

private enum CmdyImageDecoderStrategy {
    case png(Data)
    case rgba(Data, CmdyCheckedPixelLayout)

    init?(_ payload: LineImage.Payload) {
        switch payload {
        case .png(let data):
            self = .png(data)
        case .rgba(let bytes, let width, let height):
            guard let layout = CmdyCheckedPixelLayout(
                width: width, height: height),
                  bytes.count == layout.byteCount else {
                return nil
            }
            self = .rgba(Data(bytes), layout)
        }
    }

    func makeImage(sized size: NSSize) -> NSImage? {
        switch self {
        case .png(let data):
            let pngSignature: [UInt8] = [
                0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            ]
            guard data.starts(with: pngSignature),
                  let source = CGImageSourceCreateWithData(
                    data as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  let decoded = CGImageSourceCreateImageAtIndex(
                    source, 0, [
                        kCGImageSourceShouldCache: true,
                    ] as CFDictionary) else {
                return nil
            }
            return NSImage(cgImage: decoded, size: size)

        case .rgba(let data, let layout):
            guard let provider = CGDataProvider(data: data as CFData),
                  let decoded = CGImage(
                    width: layout.width,
                    height: layout.height,
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    bytesPerRow: layout.bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(
                        rawValue: CGImageAlphaInfo.last.rawValue),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: false,
                    intent: .defaultIntent) else {
                return nil
            }
            return NSImage(cgImage: decoded, size: size)
        }
    }

    static func transparentImage(sized size: NSSize) -> NSImage {
        let clearPixel = Data([0, 0, 0, 0])
        guard let provider = CGDataProvider(data: clearPixel as CFData),
              let decoded = CGImage(
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent) else {
            return NSImage(size: size)
        }
        return NSImage(cgImage: decoded, size: size)
    }
}

/// Identity-bearing image bridge.  The bounded cache preserves renderer
/// texture identity across immutable snapshot publications without retaining
/// an unbounded terminal history.
@MainActor
final class CmdyCellImage: @preconcurrency RenderableCellImage {
    private static var cache =
        CmdyImageAccessCache<UUID, CmdyCellImage>(capacity: 512)

    static func wrap(_ source: CoreLineImageSnapshot) -> CmdyCellImage {
        if let cached = cache.value(for: source.renderIdentity) {
            cached.col = source.col
            return cached
        }

        let wrapper = CmdyCellImage(source)
        cache.insert(wrapper, for: source.renderIdentity)
        return wrapper
    }

    let image: NSImage
    let pixelWidth: Int
    let pixelHeight: Int
    var col: Int
    let kittyIsKitty: Bool
    let kittyImageId: UInt32?
    let kittyZIndex: Int
    let kittyPixelOffsetX: Int
    let kittyPixelOffsetY: Int

    private init(_ source: CoreLineImageSnapshot) {
        pixelWidth = source.pixelWidth
        pixelHeight = source.pixelHeight
        col = source.col
        kittyIsKitty = source.kittyIsKitty
        kittyImageId = source.kittyImageId
        kittyZIndex = source.kittyZIndex
        kittyPixelOffsetX = source.kittyPixelOffsetX
        kittyPixelOffsetY = source.kittyPixelOffsetY
        image = Self.decode(
            source.payload,
            declaredWidth: source.pixelWidth,
            declaredHeight: source.pixelHeight)
    }

    private static func decode(
        _ payload: LineImage.Payload,
        declaredWidth: Int,
        declaredHeight: Int
    ) -> NSImage {
        let declaredSize = NSSize(
            width: CGFloat(max(0, declaredWidth)),
            height: CGFloat(max(0, declaredHeight)))
        guard let strategy = CmdyImageDecoderStrategy(payload),
              let image = strategy.makeImage(sized: declaredSize) else {
            return CmdyImageDecoderStrategy.transparentImage(
                sized: declaredSize)
        }
        return image
    }
}
