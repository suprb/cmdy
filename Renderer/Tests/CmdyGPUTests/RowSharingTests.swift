import AppKit
import MetalKit
import XCTest
@testable import CmdyGPU

@MainActor
final class RowSharingTests: XCTestCase {
    func testIdenticalDirtyRowsRebuildOnceAndKeepSeparateTerminalKeys() throws {
        let renderer = try makeRenderer()
        var previousTexture: MTLTexture?
        for color in [NSColor.red, .blue] {
            let rebuilt = MetalTerminalRenderer.rowsRebuilt
            let reused = MetalTerminalRenderer.rowsReused
            // Keep visible ink in this residency test. Fully blank coverage
            // is intentionally allocation-free (see EmptyCoverageTests).
            let info = line("A" + String(repeating: " ", count: 119),
                            attributes: [.backgroundColor: color])
            let entries = try (0..<36).map { row in
                // The second pass changes content without changing version:
                // dirty must still force a fresh content-key comparison.
                try resolve(renderer, info: info, row: row, cols: 120)
            }
            let texture = try XCTUnwrap(entries.first?.coverageTexture)
            XCTAssertEqual(MetalTerminalRenderer.rowsRebuilt - rebuilt, 1)
            XCTAssertEqual(MetalTerminalRenderer.rowsReused - reused, 35)
            XCTAssertEqual(entries.map(\.key.absoluteRow), Array(0..<36))
            XCTAssertTrue(entries.allSatisfy { $0.coverageTexture === texture })
            XCTAssertFalse(texture === previousTexture)
            XCTAssertEqual(renderer.rowCacheAllocatedBytesForTesting,
                           texture.allocatedSize)
            XCTAssertEqual(entries[0].backgrounds.first?.color,
                           IndependentRowRasterizer.rgba(color))
            previousTexture = texture
        }
    }

    func testDirtyTextAndStylesRefreshWithUnchangedTerminalVersion() throws {
        let renderer = try makeRenderer()
        let original = try resolve(renderer, info: line("ABC"), row: 0)
        let cases: [ViewLineInfo] = [
            line("XYZ"),
            line("ABC", attributes: [.foregroundColor: NSColor.green]),
            line("ABC", attributes: [.backgroundColor: NSColor.red]),
            line("ABC", attributes: [.selectionBackgroundColor: NSColor.blue]),
            line("ABC", attributes: [.cmdySelectionBackground: NSColor.yellow]),
            line("ABC", attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue,
                                      .underlineColor: NSColor.orange]),
            line("ABC", attributes: [.cmdyUnderlineStyle: RenderUnderlineStyle.curly.rawValue,
                                      .cmdyUnderlineColor: NSColor.cyan]),
            line("ABC", attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                      .strikethroughColor: NSColor.magenta]),
            line("ABC", attributes: [.kern: 1.0]),
            line("ABC", attributes: [.font: NSFont.monospacedSystemFont(
                ofSize: 14, weight: .bold)]),
        ]
        for info in cases {
            let changed = try resolve(renderer, info: info, row: 0)
            let fresh = try resolve(makeRenderer(), info: info, row: 0)
            XCTAssertNotEqual(changed.sharedTextKey, original.sharedTextKey)
            XCTAssertFalse(changed.coverageTexture === original.coverageTexture)
            try assertPayloadEqual(changed, fresh)
        }
    }

    func testImagesProceduralGlyphsAndUnknownAttributesAreNotShared() throws {
        let renderer = try makeRenderer()
        let image = SharedRowTestImage()
        var imageInfo = line("A")
        imageInfo.images = [image]
        var kittyInfo = line("A")
        kittyInfo.kittyPlaceholders = [KittyPlaceholderCell(
            row: 0, col: 0, imageId: 1, placementId: 1,
            placeholderRow: 0, placeholderCol: 0, msb: 0)]
        var blockInfo = line("A")
        blockInfo.blockElements = [BlockElementRenderItem(
            column: 0, columnWidth: 1, codePoint: 0x2588,
            rects: [BlockElementRect(x0: 0, x1: 8, y0: 0, y1: 8)],
            foregroundColor: .white)]
        var boxInfo = line("A")
        boxInfo.boxDrawings = [BoxDrawingRenderItem(
            column: 0, columnWidth: 1, codePoint: 0x2500,
            foregroundColor: .white)]
        let unknown = line("A", attributes: [
            NSAttributedString.Key("cmdy.unmodeled"): "value",
        ])
        for info in [imageInfo, kittyInfo, blockInfo, boxInfo, unknown] {
            let rebuilt = MetalTerminalRenderer.rowsRebuilt
            let first = try resolve(renderer, info: info, row: 0)
            let second = try resolve(renderer, info: info, row: 1)
            let again = try resolve(renderer, info: info, row: 0)
            XCTAssertNil(first.sharedTextKey)
            XCTAssertNil(second.sharedTextKey)
            XCTAssertNil(again.sharedTextKey)
            XCTAssertFalse(first.coverageTexture === second.coverageTexture)
            XCTAssertFalse(first.coverageTexture === again.coverageTexture)
            XCTAssertEqual(MetalTerminalRenderer.rowsRebuilt - rebuilt, 3)
        }
    }

    func testDirtyDecorationAndCellMetricsCannotReuseRoundedGeometry() throws {
        let renderer = try makeRenderer()
        let info = line("ABC", attributes: [
            .backgroundColor: NSColor.blue,
            .cmdyUnderlineStyle: RenderUnderlineStyle.double.rawValue,
        ])
        let original = try resolve(renderer, info: info, row: 0)
        // Row key dimensions and version deliberately stay unchanged. These
        // inputs affect row-local rectangles even within the same pixel size.
        for (cellWidth, cellHeight, underlinePosition, underlineThickness) in [
            (CGFloat(12), CGFloat(24), CGFloat(-3), CGFloat(1)),
            (CGFloat(12), CGFloat(24), CGFloat(-2), CGFloat(2)),
            (CGFloat(11.99), CGFloat(24), CGFloat(-2), CGFloat(1)),
            (CGFloat(12), CGFloat(23.99), CGFloat(-2), CGFloat(1)),
        ] {
            let changed = try resolve(renderer, info: info, row: 0,
                cellWidth: cellWidth, cellHeight: cellHeight,
                underlinePosition: underlinePosition, underlineThickness: underlineThickness)
            let fresh = try resolve(makeRenderer(), info: info, row: 0,
                cellWidth: cellWidth, cellHeight: cellHeight,
                underlinePosition: underlinePosition, underlineThickness: underlineThickness)
            XCTAssertEqual(changed.key, original.key)
            XCTAssertNotEqual(changed.sharedTextKey, original.sharedTextKey)
            XCTAssertFalse(changed.coverageTexture === original.coverageTexture)
            try assertPayloadEqual(changed, fresh)
        }
    }

    func testSharedDirtyPayloadMatchesFreshRasterAcrossTextCorpusAndScales() throws {
        let corpus: [(String, [Int], Int)] = [
            ("ABC", [0, 1, 2, 3], 1),
            ("e\u{301}", [0, 2], 1),
            ("中", [0, 1], 2),
            ("🙂", [0, 2], 2),
            ("fi", [0, 1, 2], 1),
        ]
        for scale: CGFloat in [1, 2] {
            for (text, boundaries, columnWidth) in corpus {
                let renderer = try makeRenderer()
                let info = line(text, attributes: [
                    .foregroundColor: NSColor.cyan,
                    .backgroundColor: NSColor.red.withAlphaComponent(0.2),
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], boundaries: boundaries, columnWidth: columnWidth)
                let first = try resolve(renderer, info: info, row: 0, scale: scale)
                let shared = try resolve(renderer, info: info, row: 1, scale: scale)
                let fresh = try resolve(makeRenderer(), info: info, row: 1, scale: scale)
                XCTAssertTrue(first.coverageTexture === shared.coverageTexture)
                try assertPayloadEqual(shared, fresh)
            }
        }
    }

    func testSyntaxRunsKeepSharedPixelsAndRefreshChangedDecorationAliases() throws {
        for scale: CGFloat in [1, 2] {
            let renderer = try makeRenderer()
            let attributed = NSMutableAttributedString(string: "let value = 42", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor.white,
                .ligature: 0,
            ])
            attributed.addAttribute(.foregroundColor, value: NSColor.magenta,
                                    range: NSRange(location: 0, length: 3))
            attributed.addAttributes([
                .foregroundColor: NSColor.cyan,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .cmdyUnderlineStyle: RenderUnderlineStyle.curly.rawValue,
                .underlineColor: NSColor.red,
                .cmdyUnderlineColor: NSColor.blue,
            ], range: NSRange(location: 4, length: 5))
            attributed.addAttribute(.foregroundColor, value: NSColor.orange,
                                    range: NSRange(location: 12, length: 2))
            func info() -> ViewLineInfo {
                ViewLineInfo(segments: [ViewLineSegment(
                    column: 0, columnWidth: 1, characterCount: 14,
                    attributedString: NSAttributedString(attributedString: attributed),
                    cellUTF16Boundaries: Array(0...14))], images: nil)
            }
            let original = try resolve(renderer, info: info(), row: 0, scale: scale)
            let shared = try resolve(renderer, info: info(), row: 1, scale: scale)
            XCTAssertTrue(original.coverageTexture === shared.coverageTexture)
            try assertPayloadEqual(shared, resolve(makeRenderer(), info: info(), row: 1, scale: scale))

            attributed.addAttribute(.cmdyUnderlineColor, value: NSColor.green,
                                    range: NSRange(location: 4, length: 5))
            let changed = try resolve(renderer, info: info(), row: 1, scale: scale)
            XCTAssertNotEqual(changed.sharedTextKey, shared.sharedTextKey)
            XCTAssertFalse(changed.coverageTexture === shared.coverageTexture)
            try assertPayloadEqual(changed, resolve(makeRenderer(), info: info(), row: 1, scale: scale))
        }
    }

    private func makeRenderer() throws -> NativeRendererCacheHarness {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return try NativeRendererCacheHarness(
            view: MTKView(frame: .zero, device: device), source: MemoryRenderSource())
    }

    private func line(_ text: String,
                      attributes: [NSAttributedString.Key: Any] = [:],
                      boundaries: [Int]? = nil,
                      columnWidth: Int = 1) -> ViewLineInfo {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.white,
        ].merging(attributes, uniquingKeysWith: { _, replacement in replacement }))
        let cells = boundaries ?? Array(0...attributed.length)
        return ViewLineInfo(segments: [ViewLineSegment(
            column: 0, columnWidth: columnWidth, characterCount: cells.count - 1,
            attributedString: attributed, cellUTF16Boundaries: cells)], images: nil)
    }

    private func resolve(_ renderer: NativeRendererCacheHarness,
                         info: ViewLineInfo, row: Int,
                         cols: Int = 16,
                         scale: CGFloat = 1,
                         cellWidth: CGFloat = 12,
                         cellHeight: CGFloat = 24,
                         underlinePosition: CGFloat = -2,
                         underlineThickness: CGFloat = 1) throws -> IndependentRowCacheEntry {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let key = IndependentRowKey(
            absoluteRow: row, version: 1, lineMode: .single, cols: cols,
            widthPx: Int(CGFloat(cols) * 12 * scale), heightPx: Int(24 * scale),
            scaleBits: Double(scale).bitPattern, fontName: font.fontName,
            fontSizeBits: Double(font.pointSize).bitPattern, alternateBuffer: false,
            kittyStamp: KittyCacheStamp(imagesCount: 0, placementsCount: 0,
                                        nextImageId: 0, nextPlacementId: 0),
            foreground: IndependentRowRasterizer.packedColor(.white),
            background: IndependentRowRasterizer.packedColor(.black),
            preset: .current, antialiasBlocks: true, bufferingMode: .perRowPersistent)
        return try XCTUnwrap(renderer.resolveRowEntry(
            key: key, explicitlyDirty: true, info: info,
            scaledFont: NSFont(descriptor: font.fontDescriptor,
                               size: font.pointSize * scale)!,
            foreground: .white, underlinePosition: underlinePosition,
            underlineThickness: underlineThickness,
            cellWidth: cellWidth * scale, cellHeight: cellHeight * scale, scale: scale))
    }

    private func assertPayloadEqual(_ actual: IndependentRowCacheEntry,
                                    _ expected: IndependentRowCacheEntry,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) throws {
        XCTAssertEqual(try bytes(actual.coverageTexture), try bytes(expected.coverageTexture),
                       file: file, line: line)
        XCTAssertEqual(actual.backgrounds.map(\.rect), expected.backgrounds.map(\.rect),
                       file: file, line: line)
        XCTAssertEqual(actual.backgrounds.map(\.color), expected.backgrounds.map(\.color),
                       file: file, line: line)
        XCTAssertEqual(actual.tintSpans.map(\.rect), expected.tintSpans.map(\.rect),
                       file: file, line: line)
        XCTAssertEqual(actual.tintSpans.map(\.color), expected.tintSpans.map(\.color),
                       file: file, line: line)
        XCTAssertEqual(actual.decorations.map(\.rect), expected.decorations.map(\.rect),
                       file: file, line: line)
        XCTAssertEqual(actual.decorations.map(\.color), expected.decorations.map(\.color),
                       file: file, line: line)
        XCTAssertEqual(actual.atlasGlyphs.map(\.rect), expected.atlasGlyphs.map(\.rect),
                       file: file, line: line)
        XCTAssertEqual(actual.atlasGlyphs.map(\.color), expected.atlasGlyphs.map(\.color),
                       file: file, line: line)
        XCTAssertEqual(actual.colorLayers.map(\.rect), expected.colorLayers.map(\.rect),
                       file: file, line: line)
        for (actualLayer, expectedLayer) in zip(actual.colorLayers, expected.colorLayers) {
            XCTAssertEqual(try bytes(actualLayer.texture), try bytes(expectedLayer.texture),
                           file: file, line: line)
        }
    }

    private func bytes(_ possibleTexture: MTLTexture?) throws -> [UInt8] {
        guard let texture = possibleTexture else { return [] }
        let bytesPerPixel = texture.pixelFormat == .r8Unorm ? 1 : 4
        let stride = texture.width * bytesPerPixel
        var data = [UInt8](repeating: 0, count: stride * texture.height)
        data.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: stride,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                             mipmapLevel: 0)
        }
        return data
    }
}

private final class SharedRowTestImage: RenderableCellImage {
    let image = NSImage(size: CGSize(width: 8, height: 8))
    let pixelWidth = 8
    let pixelHeight = 8
    let col = 0
    let kittyIsKitty = false
    let kittyImageId: UInt32? = nil
    let kittyZIndex = 0
    let kittyPixelOffsetX = 0
    let kittyPixelOffsetY = 0
}
