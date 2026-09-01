import AppKit
import CmdyGPU
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Metal
import MetalKit
import QuartzCore

private enum FixtureError: Error, CustomStringConvertible {
    case argument(String)
    case unavailable(String)
    case render(String)
    case output(String)

    var description: String {
        switch self {
        case .argument(let value): "argument error: \(value)"
        case .unavailable(let value): "unavailable: \(value)"
        case .render(let value): "render error: \(value)"
        case .output(let value): "output error: \(value)"
        }
    }
}

private let fixtureWidthPoints = 312
private let fixtureHeightPoints = 216
private let fixtureRows = 8
private let fixtureColumns = 24
private let fixtureCellSize = CGSize(width: 12, height: 24)
private let underlineStyleKey = NSAttributedString.Key("SwiftTermUnderlineStyle")

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat,
                   _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

private let foreground = color(0.88, 0.91, 0.95)
private let background = color(0.035, 0.045, 0.065)
private let red = color(0.96, 0.28, 0.34)
private let green = color(0.31, 0.88, 0.58)
private let blue = color(0.28, 0.58, 0.98)
private let yellow = color(0.98, 0.78, 0.25)
private let violet = color(0.73, 0.45, 0.98)
private let cyan = color(0.25, 0.86, 0.91)

private struct FixtureDefinition {
    let name: String
    let covers: [String]
    let lines: [Int: ViewLineInfo]
    let lineModes: [Int: RenderLineMode]
    let cursorRow: Int
    let cursorColumn: Int
    let cursorHidden: Bool
    let cursorStyle: RenderCursorStyle
    let cursorFocused: Bool
    let cursorCell: NSAttributedString?
    let textRenderingMode: TextRenderingMode
    let contentXOrigin: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let leftInset: CGFloat
    let scrollOffset: CGPoint
    let kittyPlacements: [KittyPlacementSpec]
    let kittyPayloads: [UInt32: KittyImagePayload]
    let kittyLiveIds: Set<UInt32>
    let needsImageWarmup: Bool

    init(name: String,
         covers: [String],
         lines: [Int: ViewLineInfo],
         lineModes: [Int: RenderLineMode] = [:],
         cursorRow: Int = 0,
         cursorColumn: Int = 0,
         cursorHidden: Bool = true,
         cursorStyle: RenderCursorStyle = .steadyBlock,
         cursorFocused: Bool = true,
         cursorCell: NSAttributedString? = nil,
         textRenderingMode: TextRenderingMode = .current,
         contentXOrigin: CGFloat = 8,
         topInset: CGFloat = 12,
         bottomInset: CGFloat = 12,
         leftInset: CGFloat = 0,
         scrollOffset: CGPoint = .zero,
         kittyPlacements: [KittyPlacementSpec] = [],
         kittyPayloads: [UInt32: KittyImagePayload] = [:],
         kittyLiveIds: Set<UInt32> = [],
         needsImageWarmup: Bool = false) {
        self.name = name
        self.covers = covers.sorted()
        self.lines = lines
        self.lineModes = lineModes
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.cursorHidden = cursorHidden
        self.cursorStyle = cursorStyle
        self.cursorFocused = cursorFocused
        self.cursorCell = cursorCell
        self.textRenderingMode = textRenderingMode
        self.contentXOrigin = contentXOrigin
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.leftInset = leftInset
        self.scrollOffset = scrollOffset
        self.kittyPlacements = kittyPlacements
        self.kittyPayloads = kittyPayloads
        self.kittyLiveIds = kittyLiveIds
        self.needsImageWarmup = needsImageWarmup
    }
}

@MainActor
private final class FixtureSource: MetalRenderSource {
    private(set) var fixture: FixtureDefinition
    private(set) var scale: CGFloat
    private var dirtyRows: ClosedRange<Int>?
    let normalFont: NSFont

    init(fixture: FixtureDefinition, scale: CGFloat, font: NSFont) {
        self.fixture = fixture
        self.scale = scale
        normalFont = font
        dirtyRows = 0...(fixtureRows - 1)
    }

    func install(_ fixture: FixtureDefinition, scale: CGFloat) {
        self.fixture = fixture
        self.scale = scale
        dirtyRows = 0...(fixtureRows - 1)
    }

    func captureGrid() -> GridSnapshot {
        GridSnapshot(
            rows: fixtureRows,
            cols: fixtureColumns,
            bufferLineCount: fixtureRows,
            retainedRowOrigin: 0,
            displayTopRow: 0,
            liveTopRow: 0,
            cursorRow: fixture.cursorRow,
            cursorCol: fixture.cursorColumn,
            cursorHidden: fixture.cursorHidden,
            cursorStyle: fixture.cursorStyle,
            isAlternateBuffer: false)
    }

    func lineInfo(forRow row: Int) -> ViewLineInfo {
        fixture.lines[row] ?? ViewLineInfo(segments: [], images: nil)
    }

    func lineRenderMode(forRow row: Int) -> RenderLineMode {
        fixture.lineModes[row] ?? .single
    }

    func lineVersion(forRow row: Int) -> UInt64 {
        UInt64(row + 1)
    }

    func cursorCellAttributedString() -> NSAttributedString? {
        fixture.cursorCell
    }

    var kittyStamp: KittyCacheStamp {
        KittyCacheStamp(
            imagesCount: fixture.kittyPayloads.count,
            placementsCount: fixture.kittyPlacements.count,
            nextImageId: (fixture.kittyPayloads.keys.max() ?? 0) + 1,
            nextPlacementId: (fixture.kittyPlacements.map(\.placementId).max() ?? 0) + 1)
    }

    func kittyVirtualPlacements(alternateBuffer: Bool) -> [KittyPlacementSpec] {
        alternateBuffer ? [] : fixture.kittyPlacements
    }

    func kittyImagePayload(imageId: UInt32) -> KittyImagePayload? {
        fixture.kittyPayloads[imageId]
    }

    var kittyLiveImageIds: Set<UInt32> { fixture.kittyLiveIds }
    var viewBounds: CGRect {
        CGRect(x: 0, y: 0,
               width: fixtureWidthPoints,
               height: fixtureHeightPoints)
    }
    func backingScaleFactor() -> CGFloat { scale }
    var cellSize: CGSize { fixtureCellSize }
    func underlinePosition() -> CGFloat { -2 }
    func underlineThickness() -> CGFloat { 1 }
    var contentXOrigin: CGFloat { fixture.contentXOrigin }
    var topContentInset: CGFloat { fixture.topInset }
    var bottomContentInset: CGFloat { fixture.bottomInset }
    var leftContentInset: CGFloat { fixture.leftInset }
    var scrollContentOffset: CGPoint { fixture.scrollOffset }
    func getImageScale() -> CGFloat { 1 }
    var nativeForegroundColor: NSColor { foreground }
    var nativeBackgroundColor: NSColor { background }
    var caretColor: NSColor { yellow }
    var caretTextColor: NSColor? { background }
    var caretFocused: Bool { fixture.cursorFocused }
    var antiAliasCustomBlockGlyphs: Bool { false }
    var metalBufferingMode: MetalBufferingMode { .perRowPersistent }

    func consumeDirtyRows() -> ClosedRange<Int>? {
        defer { dirtyRows = nil }
        return dirtyRows
    }

    var activityKeypressTime: Double { 0 }
    var activityTypingRate: Float { 0 }
}

@MainActor
private final class FixtureImage: RenderableCellImage {
    let image: NSImage
    let pixelWidth: Int
    let pixelHeight: Int
    let col: Int
    let kittyIsKitty = false
    let kittyImageId: UInt32? = nil
    let kittyZIndex: Int
    let kittyPixelOffsetX: Int
    let kittyPixelOffsetY: Int

    init(image: NSImage,
         pixelWidth: Int,
         pixelHeight: Int,
         col: Int,
         zIndex: Int,
         pixelOffsetX: Int,
         pixelOffsetY: Int) {
        self.image = image
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.col = col
        kittyZIndex = zIndex
        kittyPixelOffsetX = pixelOffsetX
        kittyPixelOffsetY = pixelOffsetY
    }
}

private struct FixtureIndex: Codable {
    let schemaVersion: Int
    let contract: String
    let pixelFormat: String
    let coordinateOrigin: String
    let drawablePixelFormat: String
    let outputColorSpace: String
    let fontPostScriptName: String
    let fontPointSize: Double
    let fixtures: [FixtureIndexEntry]
}

private struct PublicInputDescriptor: Codable {
    let schemaVersion: Int
    let records: [PublicInputRecord]
}

private struct PublicInputRecord: Codable {
    let key: String
    let value: String
}

private struct FixtureIndexEntry: Codable {
    let name: String
    let scale: Int
    let width: Int
    let height: Int
    let rawRGBA: String
    let png: String
    let covers: [String]
    let textRenderingMode: String
    let shaderMode: Int
    let expectedSnappedScrollY: Double
    let publicInput: PublicInputDescriptor
}

@MainActor
private func attributed(_ text: String,
                        font: NSFont,
                        attributes: [NSAttributedString.Key: Any] = [:])
    -> NSAttributedString {
    var resolved: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: foreground,
        .ligature: 0,
    ]
    for (key, value) in attributes { resolved[key] = value }
    return NSAttributedString(string: text, attributes: resolved)
}

private func boundaries(for text: String) -> [Int] {
    var result = [0]
    var offset = 0
    for character in text {
        offset += String(character).utf16.count
        result.append(offset)
    }
    return result
}

private func segment(_ text: NSAttributedString,
                     column: Int,
                     columnWidth: Int = 1,
                     characterCount: Int? = nil,
                     explicitBoundaries: [Int]? = nil) -> ViewLineSegment {
    let count = characterCount ?? text.string.count
    return ViewLineSegment(
        column: column,
        columnWidth: columnWidth,
        characterCount: count,
        attributedString: text,
        cellUTF16Boundaries: explicitBoundaries ?? boundaries(for: text.string))
}

private func encoded(_ value: String) -> String {
    Data(value.utf8).base64EncodedString()
}

private func floating(_ value: Double) -> String {
    let raw = String(value.bitPattern, radix: 16)
    return String(repeating: "0", count: 16 - raw.count) + raw
}

private func pointValue(_ value: CGPoint) -> String {
    "x=\(floating(Double(value.x)));y=\(floating(Double(value.y)))"
}

private func sizeValue(_ value: CGSize) -> String {
    "w=\(floating(Double(value.width)));h=\(floating(Double(value.height)))"
}

private func rectValue(_ value: CGRect) -> String {
    "x=\(floating(Double(value.origin.x)));y=\(floating(Double(value.origin.y)));" +
        "w=\(floating(Double(value.width)));h=\(floating(Double(value.height)))"
}

private func colorValue(_ value: NSColor) throws -> String {
    guard let converted = value.usingColorSpace(.sRGB) else {
        throw FixtureError.output("fixture color cannot be converted to sRGB")
    }
    return "srgb:r=\(floating(Double(converted.redComponent)));" +
        "g=\(floating(Double(converted.greenComponent)));" +
        "b=\(floating(Double(converted.blueComponent)));" +
        "a=\(floating(Double(converted.alphaComponent)))"
}

private func fontValue(_ value: NSFont) -> String {
    let bounds = value.boundingRectForFont
    let advance = value.maximumAdvancement
    return "postscript=\(encoded(value.fontName));family=\(encoded(value.familyName ?? ""));" +
        "pointSize=\(floating(Double(value.pointSize)));" +
        "ascender=\(floating(Double(value.ascender)));" +
        "descender=\(floating(Double(value.descender)));" +
        "leading=\(floating(Double(value.leading)));" +
        "capHeight=\(floating(Double(value.capHeight)));" +
        "xHeight=\(floating(Double(value.xHeight)));" +
        "boundingRect=\(rectValue(bounds));maximumAdvance=\(sizeValue(advance))"
}

private func attributeValue(_ value: Any) throws -> String {
    if let font = value as? NSFont { return "font:\(fontValue(font))" }
    if let color = value as? NSColor { return "color:\(try colorValue(color))" }
    if let number = value as? NSNumber {
        return "number:type=\(String(cString: number.objCType));" +
            "decimal=\(number.stringValue);doubleBits=\(floating(number.doubleValue))"
    }
    throw FixtureError.output(
        "unsupported attributed-string input type \(String(reflecting: type(of: value)))")
}

private func attributedInputRecords(_ value: NSAttributedString,
                                    prefix: String) throws -> [PublicInputRecord] {
    var records = [
        PublicInputRecord(key: "\(prefix).utf8", value: Data(value.string.utf8).base64EncodedString()),
        PublicInputRecord(key: "\(prefix).utf16Length", value: String(value.length)),
    ]
    var failure: Error?
    var runIndex = 0
    value.enumerateAttributes(
        in: NSRange(location: 0, length: value.length),
        options: []) { attributes, range, stop in
        let runPrefix = "\(prefix).run.\(runIndex)"
        records.append(PublicInputRecord(
            key: "\(runPrefix).range", value: "\(range.location):\(range.length)"))
        for key in attributes.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            do {
                let normalized = try attributeValue(attributes[key] as Any)
                records.append(PublicInputRecord(
                    key: "\(runPrefix).attribute.\(encoded(key.rawValue))",
                    value: normalized))
            } catch {
                failure = error
                stop.pointee = true
                return
            }
        }
        runIndex += 1
    }
    if let failure { throw failure }
    records.append(PublicInputRecord(
        key: "\(prefix).runCount", value: String(runIndex)))
    return records
}

private func cursorStyleValue(_ value: RenderCursorStyle) -> String {
    switch value {
    case .blinkBlock: "blink-block"
    case .steadyBlock: "steady-block"
    case .blinkUnderline: "blink-underline"
    case .steadyUnderline: "steady-underline"
    case .blinkBar: "blink-bar"
    case .steadyBar: "steady-bar"
    }
}

private func lineModeValue(_ value: RenderLineMode) -> String {
    switch value {
    case .single: "single"
    case .doubleWidth: "double-width"
    case .doubledTop: "double-height-upper"
    case .doubledDown: "double-height-lower"
    }
}

private func bufferingModeValue(_ value: MetalBufferingMode) -> String {
    switch value {
    case .perRowPersistent: "per-row-persistent"
    case .perFrameAggregated: "per-frame-aggregated"
    }
}

private var runnerArchitecture: String {
#if arch(arm64)
    "arm64"
#elseif arch(x86_64)
    "x86_64"
#else
    "unknown"
#endif
}

@MainActor
private func makePublicInputDescriptor(fixture: FixtureDefinition,
                                       source: FixtureSource,
                                       view: MTKView,
                                       window: NSWindow,
                                       renderer: MetalTerminalRenderer)
    throws -> PublicInputDescriptor {
    var records: [PublicInputRecord] = []
    func add(_ key: String, _ value: String) {
        records.append(PublicInputRecord(key: key, value: value))
    }
    func addInteger(_ key: String, _ value: some BinaryInteger) {
        add(key, String(value))
    }
    func addFloat(_ key: String, _ value: CGFloat) {
        add(key, floating(Double(value)))
    }

    add("fixture.name", fixture.name)
    add("fixture.covers", fixture.covers.joined(separator: ","))
    add("runtime.architecture", runnerArchitecture)
    add("runtime.view.bounds", rectValue(view.bounds))
    add("runtime.view.frame", rectValue(view.frame))
    add("runtime.view.drawableSize", sizeValue(view.drawableSize))
    addInteger("runtime.view.colorPixelFormat", view.colorPixelFormat.rawValue)
    addInteger("runtime.view.sampleCount", view.sampleCount)
    add("runtime.view.framebufferOnly", String(view.framebufferOnly))
    add("runtime.view.autoResizeDrawable", String(view.autoResizeDrawable))
    add("runtime.view.colorSpace", view.colorspace?.name as String? ?? "nil")
    add("runtime.view.clearColor",
        "r=\(floating(view.clearColor.red));g=\(floating(view.clearColor.green));" +
        "b=\(floating(view.clearColor.blue));a=\(floating(view.clearColor.alpha))")
    addFloat("runtime.window.backingScaleFactor", window.backingScaleFactor)
    addFloat("runtime.layer.contentsScale", view.layer?.contentsScale ?? 0)
    addFloat("runtime.drawableScale.x", view.drawableSize.width / view.bounds.width)
    addFloat("runtime.drawableScale.y", view.drawableSize.height / view.bounds.height)

    addInteger("renderer.shaderMode", renderer.shaderMode)
    add("renderer.textRenderingMode", renderer.textRenderingMode.rawValue)
    add("renderer.smoothCursorEnabled", String(renderer.smoothCursorEnabled))
    add("renderer.smoothScrollEnabled", String(renderer.smoothScrollEnabled))
    add("renderer.hostCursorHidden", String(renderer.hostCursorHidden))
    add("renderer.cursorGlideSpeed", floating(Double(renderer.cursorGlideSpeed)))
    add("renderer.cursorGlideMaxDistance", floating(Double(renderer.cursorGlideMaxDistance)))

    let snapshot = source.captureGrid()
    addInteger("source.grid.rows", snapshot.rows)
    addInteger("source.grid.columns", snapshot.cols)
    addInteger("source.grid.bufferLineCount", snapshot.bufferLineCount)
    addInteger("source.grid.retainedRowOrigin", snapshot.retainedRowOrigin)
    addInteger("source.grid.displayTopRow", snapshot.displayTopRow)
    addInteger("source.grid.liveTopRow", snapshot.liveTopRow)
    addInteger("source.grid.cursorRow", snapshot.cursorRow)
    addInteger("source.grid.cursorColumn", snapshot.cursorCol)
    add("source.grid.cursorHidden", String(snapshot.cursorHidden))
    add("source.grid.cursorStyle", cursorStyleValue(snapshot.cursorStyle))
    add("source.grid.isAlternateBuffer", String(snapshot.isAlternateBuffer))
    add("source.viewBounds", rectValue(source.viewBounds))
    addFloat("source.backingScaleFactor", source.backingScaleFactor())
    add("source.cellSize", sizeValue(source.cellSize))
    add("source.normalFont", fontValue(source.normalFont))
    addFloat("source.underlinePosition", source.underlinePosition())
    addFloat("source.underlineThickness", source.underlineThickness())
    addFloat("source.contentXOrigin", source.contentXOrigin)
    addFloat("source.topContentInset", source.topContentInset)
    addFloat("source.bottomContentInset", source.bottomContentInset)
    addFloat("source.leftContentInset", source.leftContentInset)
    add("source.scrollContentOffset", pointValue(source.scrollContentOffset))
    addFloat("source.imageScale", source.getImageScale())
    add("source.nativeForegroundColor", try colorValue(source.nativeForegroundColor))
    add("source.nativeBackgroundColor", try colorValue(source.nativeBackgroundColor))
    add("source.caretColor", try colorValue(source.caretColor))
    if let caretTextColor = source.caretTextColor {
        add("source.caretTextColor", try colorValue(caretTextColor))
    } else {
        add("source.caretTextColor", "nil")
    }
    add("source.caretFocused", String(source.caretFocused))
    add("source.antiAliasCustomBlockGlyphs", String(source.antiAliasCustomBlockGlyphs))
    add("source.metalBufferingMode", bufferingModeValue(source.metalBufferingMode))
    add("source.dirtyRowsBeforeDraw", "0...\(fixtureRows - 1)")
    add("source.activityKeypressTime", floating(source.activityKeypressTime))
    add("source.activityTypingRate", floating(Double(source.activityTypingRate)))

    if let cursorCell = source.cursorCellAttributedString() {
        records.append(contentsOf: try attributedInputRecords(
            cursorCell, prefix: "source.cursorCell"))
    } else {
        add("source.cursorCell", "nil")
    }

    let stamp = source.kittyStamp
    addInteger("source.kittyStamp.imagesCount", stamp.imagesCount)
    addInteger("source.kittyStamp.placementsCount", stamp.placementsCount)
    addInteger("source.kittyStamp.nextImageId", stamp.nextImageId)
    addInteger("source.kittyStamp.nextPlacementId", stamp.nextPlacementId)
    let placements = source.kittyVirtualPlacements(alternateBuffer: false)
    addInteger("source.kittyPlacementCount", placements.count)
    for (index, placement) in placements.enumerated() {
        let prefix = "source.kittyPlacement.\(index)"
        addInteger("\(prefix).imageId", placement.imageId)
        addInteger("\(prefix).placementId", placement.placementId)
        addInteger("\(prefix).columns", placement.cols)
        addInteger("\(prefix).rows", placement.rows)
        addInteger("\(prefix).pixelOffsetX", placement.pixelOffsetX)
        addInteger("\(prefix).pixelOffsetY", placement.pixelOffsetY)
    }
    add("source.kittyLiveImageIds",
        source.kittyLiveImageIds.sorted().map(String.init).joined(separator: ","))
    for imageId in source.kittyLiveImageIds.sorted() {
        guard let payload = source.kittyImagePayload(imageId: imageId) else {
            add("source.kittyPayload.\(imageId)", "nil")
            continue
        }
        switch payload {
        case .png(let data):
            add("source.kittyPayload.\(imageId)",
                "png:\(data.base64EncodedString())")
        case .rgba(let bytes, let width, let height):
            add("source.kittyPayload.\(imageId)",
                "rgba:\(width)x\(height):\(Data(bytes).base64EncodedString())")
        }
    }

    for row in 0..<snapshot.rows {
        let rowPrefix = "source.line.\(row)"
        let info = source.lineInfo(forRow: row)
        add("\(rowPrefix).mode", lineModeValue(source.lineRenderMode(forRow: row)))
        addInteger("\(rowPrefix).version", source.lineVersion(forRow: row))
        addInteger("\(rowPrefix).segmentCount", info.segments.count)
        for (segmentIndex, segment) in info.segments.enumerated() {
            let prefix = "\(rowPrefix).segment.\(segmentIndex)"
            addInteger("\(prefix).column", segment.column)
            addInteger("\(prefix).columnWidth", segment.columnWidth)
            addInteger("\(prefix).characterCount", segment.characterCount)
            addInteger("\(prefix).columnSpan", segment.columnSpan)
            add("\(prefix).cellUTF16Boundaries",
                segment.cellUTF16Boundaries?.map(String.init).joined(separator: ",") ?? "nil")
            records.append(contentsOf: try attributedInputRecords(
                segment.attributedString, prefix: "\(prefix).attributedString"))
        }

        let images = info.images ?? []
        addInteger("\(rowPrefix).imageCount", images.count)
        for (imageIndex, image) in images.enumerated() {
            let prefix = "\(rowPrefix).image.\(imageIndex)"
            addInteger("\(prefix).pixelWidth", image.pixelWidth)
            addInteger("\(prefix).pixelHeight", image.pixelHeight)
            addInteger("\(prefix).column", image.col)
            add("\(prefix).kittyIsKitty", String(image.kittyIsKitty))
            add("\(prefix).kittyImageId", image.kittyImageId.map(String.init) ?? "nil")
            addInteger("\(prefix).kittyZIndex", image.kittyZIndex)
            addInteger("\(prefix).kittyPixelOffsetX", image.kittyPixelOffsetX)
            addInteger("\(prefix).kittyPixelOffsetY", image.kittyPixelOffsetY)
            add("\(prefix).pointSize", sizeValue(image.image.size))
            guard let cgImage = image.image.cgImage(
                forProposedRect: nil, context: nil, hints: nil),
                  let providerData = cgImage.dataProvider?.data else {
                throw FixtureError.output("fixture image has no canonical CGImage payload")
            }
            addInteger("\(prefix).cg.width", cgImage.width)
            addInteger("\(prefix).cg.height", cgImage.height)
            addInteger("\(prefix).cg.bitsPerComponent", cgImage.bitsPerComponent)
            addInteger("\(prefix).cg.bitsPerPixel", cgImage.bitsPerPixel)
            addInteger("\(prefix).cg.bytesPerRow", cgImage.bytesPerRow)
            addInteger("\(prefix).cg.bitmapInfo", cgImage.bitmapInfo.rawValue)
            addInteger("\(prefix).cg.alphaInfo", cgImage.alphaInfo.rawValue)
            add("\(prefix).cg.colorSpace", cgImage.colorSpace?.name as String? ?? "nil")
            add("\(prefix).cg.providerBytes",
                Data(providerData as Data).base64EncodedString())
        }

        addInteger("\(rowPrefix).kittyPlaceholderCount", info.kittyPlaceholders.count)
        for (index, placeholder) in info.kittyPlaceholders.enumerated() {
            let prefix = "\(rowPrefix).kittyPlaceholder.\(index)"
            addInteger("\(prefix).row", placeholder.row)
            addInteger("\(prefix).column", placeholder.col)
            addInteger("\(prefix).imageId", placeholder.imageId)
            addInteger("\(prefix).placementId", placeholder.placementId)
            addInteger("\(prefix).placeholderRow", placeholder.placeholderRow)
            addInteger("\(prefix).placeholderColumn", placeholder.placeholderCol)
            addInteger("\(prefix).msb", placeholder.msb)
        }

        addInteger("\(rowPrefix).blockElementCount", info.blockElements.count)
        for (index, item) in info.blockElements.enumerated() {
            let prefix = "\(rowPrefix).blockElement.\(index)"
            addInteger("\(prefix).column", item.column)
            addInteger("\(prefix).columnWidth", item.columnWidth)
            addInteger("\(prefix).codePoint", item.codePoint)
            add("\(prefix).foregroundColor", try colorValue(item.foregroundColor))
            addInteger("\(prefix).rectCount", item.rects.count)
            for (rectIndex, rect) in item.rects.enumerated() {
                add("\(prefix).rect.\(rectIndex)",
                    "x0=\(rect.x0);x1=\(rect.x1);y0=\(rect.y0);y1=\(rect.y1);" +
                    "alpha=\(floating(Double(rect.alpha.rawValue)))")
            }
        }

        addInteger("\(rowPrefix).boxDrawingCount", info.boxDrawings.count)
        for (index, item) in info.boxDrawings.enumerated() {
            let prefix = "\(rowPrefix).boxDrawing.\(index)"
            addInteger("\(prefix).column", item.column)
            addInteger("\(prefix).columnWidth", item.columnWidth)
            addInteger("\(prefix).codePoint", item.codePoint)
            add("\(prefix).foregroundColor", try colorValue(item.foregroundColor))
        }
    }

    records.sort { $0.key < $1.key }
    guard Set(records.map(\.key)).count == records.count else {
        throw FixtureError.output("public input descriptor contains duplicate keys")
    }
    return PublicInputDescriptor(schemaVersion: 1, records: records)
}

@MainActor
private func textStylesFixture(font: NSFont) -> FixtureDefinition {
    let bold = NSFont(name: "Menlo-Bold", size: font.pointSize) ?? font
    let italic = NSFont(name: "Menlo-Italic", size: font.pointSize) ?? font
    let lines: [Int: ViewLineInfo] = [
        0: ViewLineInfo(segments: [segment(attributed(
            "DEFAULT ASCII 012345", font: font), column: 0)], images: nil),
        1: ViewLineInfo(segments: [segment(attributed(
            "BOLD RED", font: bold, attributes: [.foregroundColor: red]), column: 0)],
            images: nil),
        2: ViewLineInfo(segments: [segment(attributed(
            "ITALIC EXPLICIT BG", font: italic,
            attributes: [.foregroundColor: yellow, .backgroundColor: blue]), column: 0)],
            images: nil),
        3: ViewLineInfo(segments: [segment(attributed(
            "SELECTED CELLS", font: font,
            attributes: [.selectionBackgroundColor: violet]), column: 0)], images: nil),
        4: ViewLineInfo(segments: [segment(attributed(
            "DIM ALPHA", font: font,
            attributes: [.foregroundColor: foreground.withAlphaComponent(0.45)]), column: 0)],
            images: nil),
        5: ViewLineInfo(segments: [segment(attributed(
            "INVERSE", font: font,
            attributes: [.foregroundColor: background, .backgroundColor: foreground]), column: 0)],
            images: nil),
        6: ViewLineInfo(segments: [segment(attributed(
            "STRIKE", font: font,
            attributes: [.foregroundColor: cyan,
                         .strikethroughStyle: NSNumber(value: NSUnderlineStyle.single.rawValue),
                         .strikethroughColor: red]), column: 0)], images: nil),
    ]
    return FixtureDefinition(
        name: "ascii-styles-backgrounds",
        covers: ["ascii", "styled-text", "default-background",
                 "explicit-background", "selection-background", "strike-through"],
        lines: lines)
}

@MainActor
private func unicodeFixture(font: NSFont) -> FixtureDefinition {
    let emojiFont = NSFont(name: "AppleColorEmoji", size: font.pointSize) ?? font
    let combining = "e\u{301}"
    let zwj = "👩‍💻"
    let emoji = "😀"
    let cjk = "漢字"
    let jamo = "\u{1100}\u{1161}X"

    func label(_ value: String, row: Int) -> ViewLineInfo {
        ViewLineInfo(segments: [segment(attributed(value, font: font,
                                                   attributes: [.foregroundColor: cyan]),
                                                column: 0)], images: nil)
    }

    var lines: [Int: ViewLineInfo] = [
        0: label("COMBINING", row: 0),
        1: label("EMOJI ZWJ", row: 1),
        2: label("COLOR EMOJI", row: 2),
        3: label("CJK WIDE", row: 3),
        4: label("JAMO CELLS", row: 4),
    ]
    lines[0]?.segments.append(segment(
        attributed(combining, font: font, attributes: [.foregroundColor: yellow]),
        column: 14, characterCount: 1,
        explicitBoundaries: [0, combining.utf16.count]))
    lines[1]?.segments.append(segment(
        attributed(zwj, font: emojiFont), column: 14, columnWidth: 2,
        characterCount: 1, explicitBoundaries: [0, zwj.utf16.count]))
    lines[2]?.segments.append(segment(
        attributed(emoji, font: emojiFont), column: 14, columnWidth: 2,
        characterCount: 1, explicitBoundaries: [0, emoji.utf16.count]))
    lines[3]?.segments.append(segment(
        attributed(cjk, font: font, attributes: [.foregroundColor: green]),
        column: 14, columnWidth: 2, characterCount: 2,
        explicitBoundaries: [0, 1, 2]))
    lines[4]?.segments.append(segment(
        attributed(jamo, font: font, attributes: [.foregroundColor: violet]),
        column: 14, characterCount: 3,
        explicitBoundaries: [0, 1, 2, 3]))

    return FixtureDefinition(
        name: "unicode-clusters",
        covers: ["combining-text", "emoji-zwj", "color-emoji",
                 "cjk-wide-cells", "adjacent-jamo-cells", "explicit-utf16-boundaries"],
        lines: lines)
}

private func cursorName(_ style: RenderCursorStyle) -> String {
    switch style {
    case .blinkBlock: "blink-block"
    case .steadyBlock: "steady-block"
    case .blinkUnderline: "blink-underline"
    case .steadyUnderline: "steady-underline"
    case .blinkBar: "blink-bar"
    case .steadyBar: "steady-bar"
    }
}

@MainActor
private func cursorFixture(_ style: RenderCursorStyle,
                           font: NSFont) -> FixtureDefinition {
    let name = cursorName(style)
    let text = "CURSOR STYLE  X"
    let line = ViewLineInfo(
        segments: [segment(attributed(text, font: font,
                                     attributes: [.foregroundColor: green]), column: 0)],
        images: nil)
    return FixtureDefinition(
        name: "cursor-\(name)",
        covers: ["cursor.\(name)", "cursor-focused", "cursor-cell-recolor"],
        lines: [3: line],
        cursorRow: 3,
        cursorColumn: 14,
        cursorHidden: false,
        cursorStyle: style,
        cursorFocused: true,
        cursorCell: attributed("X", font: font,
                               attributes: [.foregroundColor: green]))
}

@MainActor
private func underlineFixture(font: NSFont) -> FixtureDefinition {
    let styles: [(String, RenderUnderlineStyle, NSColor)] = [
        ("NONE", .none, foreground),
        ("SINGLE", .single, red),
        ("DOUBLE", .double, green),
        ("CURLY", .curly, blue),
        ("DOTTED", .dotted, yellow),
        ("DASHED", .dashed, violet),
    ]
    var lines: [Int: ViewLineInfo] = [:]
    for (row, entry) in styles.enumerated() {
        let value = attributed(
            "\(entry.0) UNDERLINE", font: font,
            attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                underlineStyleKey: NSNumber(value: entry.1.rawValue),
                .underlineColor: entry.2,
            ])
        lines[row] = ViewLineInfo(segments: [segment(value, column: 0)], images: nil)
    }
    return FixtureDefinition(
        name: "underline-styles",
        covers: styles.map { "underline.\($0.0.lowercased())" },
        lines: lines)
}

@MainActor
private func boxDrawingFixture() -> FixtureDefinition {
    var lines: [Int: ViewLineInfo] = [:]
    for row in 0..<8 {
        let items = (0..<16).map { column in
            let codePoint = UInt32(0x2500 + row * 16 + column)
            return BoxDrawingRenderItem(
                column: column,
                columnWidth: 1,
                codePoint: codePoint,
                foregroundColor: row.isMultiple(of: 2) ? foreground : cyan)
        }
        lines[row] = ViewLineInfo(segments: [], images: nil, boxDrawings: items)
    }
    return FixtureDefinition(
        name: "box-drawing-full-grid",
        covers: ["box-drawing.U+2500-U+257F", "box-drawing.full-range"],
        lines: lines,
        contentXOrigin: 8,
        topInset: 12,
        bottomInset: 12)
}

@MainActor
private func blockElementFixture() -> FixtureDefinition {
    var lines: [Int: ViewLineInfo] = [:]
    for row in 0..<2 {
        let items = (0..<16).compactMap { column -> BlockElementRenderItem? in
            let codePoint = UInt32(0x2580 + row * 16 + column)
            guard let rects = BlockElementMapping.rects(for: codePoint) else { return nil }
            return BlockElementRenderItem(
                column: column,
                columnWidth: 1,
                codePoint: codePoint,
                rects: rects,
                foregroundColor: row == 0 ? green : violet)
        }
        lines[row + 3] = ViewLineInfo(segments: [], images: nil, blockElements: items)
    }
    return FixtureDefinition(
        name: "block-elements-full-grid",
        covers: ["block-elements.U+2580-U+259F", "block-elements.full-range"],
        lines: lines)
}

@MainActor
private func lineModesFixture(font: NSFont) -> FixtureDefinition {
    let single = ViewLineInfo(segments: [segment(attributed(
        "SINGLE WIDTH", font: font, attributes: [.foregroundColor: foreground]),
        column: 0)], images: nil)
    let double = ViewLineInfo(segments: [segment(attributed(
        "DOUBLE WIDE", font: font, attributes: [.foregroundColor: cyan]),
        column: 0)], images: nil)
    let doubleHeight = ViewLineInfo(segments: [segment(attributed(
        "DOUBLE HIGH", font: font, attributes: [.foregroundColor: yellow]),
        column: 0)], images: nil)
    return FixtureDefinition(
        name: "line-modes",
        covers: ["line-mode.single", "line-mode.double-width",
                 "line-mode.double-height-upper", "line-mode.double-height-lower"],
        lines: [0: single, 2: double, 4: doubleHeight, 5: doubleHeight],
        lineModes: [0: .single, 2: .doubleWidth,
                    4: .doubledTop, 5: .doubledDown])
}

private func rgbaImage(width: Int, height: Int,
                       first: (UInt8, UInt8, UInt8),
                       second: (UInt8, UInt8, UInt8)) throws -> NSImage {
    var bytes = [UInt8]()
    bytes.reserveCapacity(width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let value = ((x / 2) + (y / 2)).isMultiple(of: 2) ? first : second
            bytes.append(value.0)
            bytes.append(value.1)
            bytes.append(value.2)
            bytes.append(255)
        }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent) else {
        throw FixtureError.output("could not construct deterministic fixture image")
    }
    return NSImage(cgImage: image, size: CGSize(width: width, height: height))
}

private func checkerBytes(width: Int, height: Int) -> [UInt8] {
    var bytes = [UInt8]()
    bytes.reserveCapacity(width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let on = ((x / 2) + (y / 2)).isMultiple(of: 2)
            bytes.append(on ? 245 : 35)
            bytes.append(on ? 95 : 210)
            bytes.append(on ? 35 : 245)
            bytes.append(255)
        }
    }
    return bytes
}

@MainActor
private func imagesFixture(font: NSFont) throws -> FixtureDefinition {
    let under = FixtureImage(
        image: try rgbaImage(width: 8, height: 8,
                             first: (230, 40, 40), second: (45, 45, 190)),
        pixelWidth: 84, pixelHeight: 20, col: 0, zIndex: -2,
        pixelOffsetX: 0, pixelOffsetY: 2)
    let zero = FixtureImage(
        image: try rgbaImage(width: 8, height: 8,
                             first: (35, 220, 85), second: (10, 75, 45)),
        pixelWidth: 84, pixelHeight: 20, col: 0, zIndex: 0,
        pixelOffsetX: 0, pixelOffsetY: 2)
    let over = FixtureImage(
        image: try rgbaImage(width: 8, height: 8,
                             first: (245, 195, 35), second: (150, 45, 185)),
        pixelWidth: 84, pixelHeight: 20, col: 0, zIndex: 3,
        pixelOffsetX: 0, pixelOffsetY: 2)
    let kittyId: UInt32 = 91
    let placementId: UInt32 = 17
    let placeholder = KittyPlaceholderCell(
        row: 6, col: 13, imageId: kittyId, placementId: placementId,
        placeholderRow: 0, placeholderCol: 0, msb: 0)
    let textAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: foreground,
        .backgroundColor: color(0.08, 0.10, 0.14),
    ]
    let lines: [Int: ViewLineInfo] = [
        1: ViewLineInfo(segments: [segment(attributed(
            "NEGATIVE Z TEXT", font: font, attributes: textAttributes), column: 0)],
            images: [under]),
        3: ViewLineInfo(segments: [segment(attributed(
            "ZERO Z TEXT", font: font, attributes: textAttributes), column: 0)],
            images: [zero]),
        5: ViewLineInfo(segments: [segment(attributed(
            "POSITIVE Z TEXT", font: font, attributes: textAttributes), column: 0)],
            images: [over]),
        6: ViewLineInfo(segments: [segment(attributed(
            "KITTY PLACEHOLDER", font: font, attributes: [.foregroundColor: cyan]), column: 0)],
            images: nil,
            kittyPlaceholders: [placeholder]),
    ]
    return FixtureDefinition(
        name: "image-z-layers-kitty",
        covers: ["image.negative-z", "image.zero-z", "image.positive-z",
                 "image.text-composition", "kitty.placeholder", "kitty.rgba-payload"],
        lines: lines,
        kittyPlacements: [KittyPlacementSpec(
            imageId: kittyId, placementId: placementId,
            cols: 3, rows: 1, pixelOffsetX: 1, pixelOffsetY: 2)],
        kittyPayloads: [kittyId: .rgba(bytes: checkerBytes(width: 8, height: 8),
                                             width: 8, height: 8)],
        kittyLiveIds: [kittyId],
        needsImageWarmup: true)
}

@MainActor
private func insetsFixture(font: NSFont) -> FixtureDefinition {
    let explicit = color(0.16, 0.12, 0.28)
    var lines: [Int: ViewLineInfo] = [:]
    for row in 0..<fixtureRows {
        lines[row] = ViewLineInfo(
            segments: [segment(attributed(
                "CLIP ROW \(row) 0123456789", font: font,
                attributes: [.foregroundColor: row.isMultiple(of: 2) ? green : cyan,
                             .backgroundColor: explicit]), column: 0)],
            images: nil)
    }
    return FixtureDefinition(
        name: "insets-fractional-scroll",
        covers: ["inset.top", "inset.bottom", "inset.left",
                 "inset.hard-clipping", "scroll.fractional", "scroll.pixel-snapping"],
        lines: lines,
        cursorRow: 0,
        cursorColumn: 0,
        cursorHidden: false,
        cursorStyle: .steadyBar,
        cursorFocused: true,
        cursorCell: attributed("C", font: font),
        contentXOrigin: 7.25,
        topInset: 7.25,
        bottomInset: 16.5,
        leftInset: 5.5,
        scrollOffset: CGPoint(x: 0, y: 1.26))
}

@MainActor
private func presetFixture(_ mode: TextRenderingMode,
                           font: NSFont) -> FixtureDefinition {
    let combining = "A\u{301}"
    let emojiFont = NSFont(name: "AppleColorEmoji", size: font.pointSize) ?? font
    let lines: [Int: ViewLineInfo] = [
        1: ViewLineInfo(segments: [segment(attributed(
            "PRESET \(mode.rawValue)", font: font,
            attributes: [.foregroundColor: cyan, .backgroundColor: color(0.11, 0.09, 0.18)]),
            column: 0)], images: nil),
        3: ViewLineInfo(segments: [
            segment(attributed("Aa09!?", font: font,
                               attributes: [.foregroundColor: foreground]), column: 0),
            segment(attributed(combining, font: font,
                               attributes: [.foregroundColor: yellow]),
                    column: 8, characterCount: 1,
                    explicitBoundaries: [0, combining.utf16.count]),
            segment(attributed("😀", font: emojiFont), column: 12, columnWidth: 2,
                    characterCount: 1, explicitBoundaries: [0, 2]),
        ], images: nil),
        5: ViewLineInfo(segments: [segment(attributed(
            "UNDERLINE SAMPLE", font: font,
            attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                underlineStyleKey: NSNumber(value: RenderUnderlineStyle.curly.rawValue),
                .underlineColor: violet,
            ]), column: 0)], images: nil),
    ]
    return FixtureDefinition(
        name: "text-preset-\(mode.rawValue)",
        covers: ["text-rendering-mode.\(mode.rawValue)", "shader.mode-zero"],
        lines: lines,
        textRenderingMode: mode)
}

@MainActor
private func allFixtures(font: NSFont) throws -> [FixtureDefinition] {
    var fixtures = [
        textStylesFixture(font: font),
        unicodeFixture(font: font),
    ]
    let cursorStyles: [RenderCursorStyle] = [
        .steadyBlock, .blinkBlock,
        .steadyUnderline, .blinkUnderline,
        .steadyBar, .blinkBar,
    ]
    fixtures.append(contentsOf: cursorStyles.map { cursorFixture($0, font: font) })
    fixtures.append(underlineFixture(font: font))
    fixtures.append(boxDrawingFixture())
    fixtures.append(blockElementFixture())
    fixtures.append(lineModesFixture(font: font))
    fixtures.append(try imagesFixture(font: font))
    fixtures.append(insetsFixture(font: font))
    fixtures.append(contentsOf: TextRenderingMode.allCases.map {
        presetFixture($0, font: font)
    })
    return fixtures
}

@MainActor
private func waitForVisibleWindow(_ window: NSWindow,
                                  timeout: TimeInterval = 3) async throws {
    let end = Date(timeIntervalSinceNow: timeout)
    while Date() < end {
        if window.occlusionState.contains(.visible) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.render("fixture window never became visible")
}

private func aligned(_ value: Int, to alignment: Int) -> Int {
    ((value + alignment - 1) / alignment) * alignment
}

private final class PresentationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var presented = false

    func markPresented() {
        lock.lock()
        presented = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return presented
    }
}

private func readDrawablePixels(_ drawable: any CAMetalDrawable,
                                device: MTLDevice) throws -> [UInt8] {
    try autoreleasepool {
        let texture = drawable.texture
        guard texture.pixelFormat == .bgra8Unorm
                || texture.pixelFormat == .bgra8Unorm_srgb else {
            throw FixtureError.render(
                "unexpected drawable pixel format \(texture.pixelFormat.rawValue)")
        }
        let rowBytes = texture.width * 4
        let alignedRowBytes = aligned(rowBytes, to: 256)
        let byteCount = alignedRowBytes * texture.height
        guard let buffer = device.makeBuffer(
                    length: byteCount, options: .storageModeShared),
              let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw FixtureError.render(
                "could not allocate drawable readback resources")
        }
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: texture.width, height: texture.height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: alignedRowBytes,
            destinationBytesPerImage: byteCount)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw FixtureError.render(
                "drawable readback failed: "
                + (commandBuffer.error?.localizedDescription
                   ?? "unknown Metal error"))
        }

        let source = buffer.contents().assumingMemoryBound(to: UInt8.self)
        var rgba = [UInt8](repeating: 0, count: rowBytes * texture.height)
        for y in 0..<texture.height {
            let sourceRow = source.advanced(by: y * alignedRowBytes)
            let destinationRow = y * rowBytes
            for x in 0..<texture.width {
                let sourceOffset = x * 4
                let destinationOffset = destinationRow + sourceOffset
                rgba[destinationOffset] = sourceRow[sourceOffset + 2]
                rgba[destinationOffset + 1] = sourceRow[sourceOffset + 1]
                rgba[destinationOffset + 2] = sourceRow[sourceOffset]
                rgba[destinationOffset + 3] = sourceRow[sourceOffset + 3]
            }
        }
        return rgba
    }
}

@MainActor
private func captureFrame(view: MTKView,
                          renderer: MetalTerminalRenderer,
                          device: MTLDevice) async throws -> [UInt8] {
    let before = MetalTerminalRenderer.framesPresented
    let presentationDeadline = Date(timeIntervalSinceNow: 4)
    var capturedDrawable: (any CAMetalDrawable)?
    while Date() < presentationDeadline, capturedDrawable == nil {
        let attempt: ((any CAMetalDrawable), PresentationFlag)? = autoreleasepool {
            guard let drawable = view.currentDrawable else { return nil }
            let presented = PresentationFlag()
            drawable.addPresentedHandler { _ in presented.markPresented() }
            view.delegate = renderer
            view.draw()
            view.delegate = nil
            return (drawable, presented)
        }
        guard let (drawable, presented) = attempt else {
            view.releaseDrawables()
            try await Task.sleep(for: .milliseconds(10))
            continue
        }
        let attemptDeadline = Date(timeIntervalSinceNow: 0.25)
        while !presented.value, Date() < attemptDeadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        if presented.value {
            capturedDrawable = drawable
        } else {
            view.releaseDrawables()
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    guard capturedDrawable != nil else {
        throw FixtureError.render("renderer did not present a drawable")
    }

    let completionDeadline = Date(timeIntervalSinceNow: 2)
    while MetalTerminalRenderer.framesPresented <= before,
          Date() < completionDeadline {
        try await Task.sleep(for: .milliseconds(2))
    }
    guard MetalTerminalRenderer.framesPresented > before else {
        throw FixtureError.render("renderer did not complete a frame")
    }

    let rgba = try readDrawablePixels(capturedDrawable!, device: device)
    capturedDrawable = nil
    view.releaseDrawables()
    return rgba
}

private func caretColorScore(_ rgba: [UInt8]) -> Int {
    var score = 0
    for offset in stride(from: 0, to: rgba.count, by: 4) {
        let red = Int(rgba[offset])
        let green = Int(rgba[offset + 1])
        let blue = Int(rgba[offset + 2])
        let alpha = Int(rgba[offset + 3])
        if red >= 180, green >= 130, blue <= 150,
           red - blue >= 60, alpha >= 240 {
            // Frozen blinking cursors fade between their visible and hidden
            // phases. Occupancy alone ties a dim intermediate frame with the
            // fully visible frame, so rank qualifying pixels by brightness.
            score += red + green - blue
        }
    }
    return score
}

@MainActor
private func captureBlinkOnFrame(view: MTKView,
                                 renderer: MetalTerminalRenderer,
                                 device: MTLDevice,
                                 steadyTarget: [UInt8]?) async throws -> [UInt8] {
    // The durable reference corpus stores the historical fully-visible blink
    // phase. Reset public static-content pacing and activity before each
    // candidate sample so its activity-relative pulse presents that same
    // phase immediately. In forensic build-vs-build mode the frozen renderer
    // keeps its wall-clock epoch, so the complete-cycle nearest-frame search
    // remains useful diagnostic evidence.
    var selected: [UInt8]?
    var selectedScore = -1
    var selectedDistance = Int.max
    for attempt in 0..<25 {
        renderer.shaderMode = 0
        renderer.noteActivity()
        let frame = try await captureFrame(view: view, renderer: renderer,
                                           device: device)
        if let steadyTarget, steadyTarget.count == frame.count {
            let distance = zip(frame, steadyTarget).reduce(into: 0) {
                $0 += abs(Int($1.0) - Int($1.1))
            }
            if distance < selectedDistance {
                selected = frame
                selectedDistance = distance
            }
            if distance == 0 { return frame }
        } else {
            let score = caretColorScore(frame)
            if score > selectedScore {
                selected = frame
                selectedScore = score
            }
        }
        if attempt < 24 { try await Task.sleep(for: .milliseconds(50)) }
    }
    guard let selected else {
        throw FixtureError.render("blink capture produced no frames")
    }
    return selected
}

private func writePNG(rgba: [UInt8],
                      width: Int,
                      height: Int,
                      url: URL) throws {
    guard rgba.count == width * height * 4,
          let provider = CGDataProvider(data: Data(rgba) as CFData),
          let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil) else {
        throw FixtureError.output("could not create PNG at \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, [
        kCGImagePropertyPNGDictionary: [:] as CFDictionary,
    ] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw FixtureError.output("could not finalize PNG at \(url.path)")
    }
}

@MainActor
private func run(outputDirectory: URL) async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw FixtureError.unavailable("Metal device")
    }
    guard let font = NSFont(name: "Menlo-Regular", size: 14) else {
        throw FixtureError.unavailable("Menlo-Regular 14 pt")
    }
    let fixtures = try allFixtures(font: font)
    guard fixtures.count == 20, Set(fixtures.map(\.name)).count == 20 else {
        throw FixtureError.output("fixture inventory must contain 20 unique definitions")
    }

    try FileManager.default.createDirectory(
        at: outputDirectory, withIntermediateDirectories: true)
    let initial = fixtures[0]
    let source = FixtureSource(fixture: initial, scale: 1, font: font)
    let view = MTKView(
        frame: CGRect(x: 0, y: 0,
                      width: fixtureWidthPoints,
                      height: fixtureHeightPoints),
        device: device)
    view.autoResizeDrawable = false
    view.drawableSize = CGSize(width: fixtureWidthPoints,
                               height: fixtureHeightPoints)
    view.colorPixelFormat = .bgra8Unorm
    view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    view.framebufferOnly = false
    view.sampleCount = 1
    view.clearColor = MTLClearColorMake(0, 0, 0, 1)

    let window = NSWindow(
        contentRect: view.frame,
        styleMask: [.titled],
        backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    window.isOpaque = true
    window.backgroundColor = background
    window.contentView = view
    if let screen = NSScreen.screens.first {
        let x = screen.visibleFrame.maxX - CGFloat(fixtureWidthPoints) - 8
        let y = screen.visibleFrame.minY + 8
        window.setFrameOrigin(CGPoint(x: x, y: y))
    }

    let renderer = try MetalTerminalRenderer(view: view, source: source)
    // The oracle invokes the public delegate method itself so no AppKit display
    // callback can race the retained drawable used for exact readback.
    view.delegate = nil
    renderer.shaderMode = 0
    renderer.smoothCursorEnabled = false
    renderer.smoothScrollEnabled = true
    renderer.hostCursorHidden = false
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .transient]
    NSApplication.shared.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    try await waitForVisibleWindow(window)

    var indexEntries: [FixtureIndexEntry] = []
    for scaleInteger in [1, 2] {
        let scale = CGFloat(scaleInteger)
        let width = fixtureWidthPoints * scaleInteger
        let height = fixtureHeightPoints * scaleInteger
        view.drawableSize = CGSize(width: width, height: height)
        renderer.mtkView(view, drawableSizeWillChange: view.drawableSize)
        var steadyCursorFrames: [String: [UInt8]] = [:]

        for fixture in fixtures {
            source.install(fixture, scale: scale)
            renderer.shaderMode = 0
            renderer.textRenderingMode = fixture.textRenderingMode
            renderer.invalidateRowCache()
            try await Task.sleep(for: .milliseconds(30))

            let publicInput = try makePublicInputDescriptor(
                fixture: fixture,
                source: source,
                view: view,
                window: window,
                renderer: renderer)

            let blinks: Bool
            switch fixture.cursorStyle {
            case .blinkBlock, .blinkUnderline, .blinkBar:
                blinks = !fixture.cursorHidden && fixture.cursorFocused
            default:
                blinks = false
            }
            if fixture.needsImageWarmup {
                // Both implementations may construct image textures off the
                // draw path. Eight fully presented frames over two seconds
                // make readiness an observed condition rather than a single
                // timing guess.
                for _ in 0..<8 {
                    _ = try await captureFrame(view: view, renderer: renderer,
                                               device: device)
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            let blinkTargetName = fixture.name.replacingOccurrences(
                of: "cursor-blink-", with: "cursor-steady-")
            let rgba = if blinks {
                try await captureBlinkOnFrame(view: view, renderer: renderer,
                                              device: device,
                                              steadyTarget: steadyCursorFrames[blinkTargetName])
            } else {
                try await captureFrame(view: view, renderer: renderer,
                                       device: device)
            }
            if fixture.name.hasPrefix("cursor-steady-") {
                steadyCursorFrames[fixture.name] = rgba
            }
            guard rgba.count == width * height * 4 else {
                throw FixtureError.output("unexpected byte count for \(fixture.name)")
            }

            let stem = "s\(scaleInteger)__\(fixture.name)"
            let rawName = "\(stem).rgba"
            let pngName = "\(stem).png"
            try Data(rgba).write(to: outputDirectory.appendingPathComponent(rawName),
                                 options: .atomic)
            try writePNG(rgba: rgba, width: width, height: height,
                         url: outputDirectory.appendingPathComponent(pngName))
            let snapped = fixture.scrollOffset.y.rounded() / scale
            indexEntries.append(FixtureIndexEntry(
                name: fixture.name,
                scale: scaleInteger,
                width: width,
                height: height,
                rawRGBA: rawName,
                png: pngName,
                covers: fixture.covers,
                textRenderingMode: fixture.textRenderingMode.rawValue,
                shaderMode: 0,
                expectedSnappedScrollY: Double(snapped),
                publicInput: publicInput))
            FileHandle.standardError.write(Data(
                "captured \(stem) \(width)x\(height)\n".utf8))
        }
    }

    window.orderOut(nil)
    window.close()
    let index = FixtureIndex(
        schemaVersion: 2,
        contract: "docs/independence/CMDYGPU_CONTRACT.md#13",
        pixelFormat: "rgba8-unorm",
        coordinateOrigin: "top-left",
        drawablePixelFormat: "bgra8-unorm",
        outputColorSpace: "sRGB",
        fontPostScriptName: font.fontName,
        fontPointSize: Double(font.pointSize),
        fixtures: indexEntries)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(index)
    data.append(0x0A)
    try data.write(to: outputDirectory.appendingPathComponent("fixture-index.json"),
                   options: .atomic)
}

@main
private struct RendererPixelFixtureMain {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2, arguments[0] == "--output" else {
            FileHandle.standardError.write(Data(
                "renderer pixel fixture: argument error: usage: renderer-pixel-fixture --output DIRECTORY\n".utf8))
            Foundation.exit(1)
        }
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        Task { @MainActor in
            do {
                try await run(outputDirectory: output)
                Foundation.exit(0)
            } catch {
                FileHandle.standardError.write(Data(
                    "renderer pixel fixture: \(error)\n".utf8))
                Foundation.exit(1)
            }
        }
        application.run()
    }
}
