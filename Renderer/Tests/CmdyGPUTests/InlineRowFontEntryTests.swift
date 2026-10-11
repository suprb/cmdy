import AppKit
import CoreText
import XCTest
@testable import CmdyGPU

@MainActor
final class InlineRowFontEntryTests: XCTestCase {
    func testFirstExactIdentityUsesOnlyInlineEntries() throws {
        let source = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14))
        let normal = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 28))
        var cache = IndependentRowRasterizer.RowFonts(scale: 2, normal: normal, caching: true)
        XCTAssertEqual(cache.scaledEntryCount, 0)
        XCTAssertEqual(cache.shapingEntryCount, 0)
        XCTAssertFalse(cache.hasAdditionalScaledStorage)
        XCTAssertFalse(cache.hasAdditionalShapingStorage)
        let scaled = cache.scaledFont(source)
        let shaping = cache.shapingFont(scaled)
        for _ in 0..<8 {
            XCTAssertTrue(cache.scaledFont(source) === scaled)
            XCTAssertTrue(cache.shapingFont(scaled) === shaping)
        }
        XCTAssertEqual(cache.scaledEntryCount, 1)
        XCTAssertEqual(cache.shapingEntryCount, 1)
        XCTAssertFalse(cache.hasAdditionalScaledStorage)
        XCTAssertFalse(cache.hasAdditionalShapingStorage)
    }

    func testSecondIdentityAndLaterHitsKeepFirstEntries() throws {
        let first = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14))
        let second = try XCTUnwrap(NSFont(name: "Helvetica-Oblique", size: 22))
        let third = try XCTUnwrap(NSFont(name: "Menlo-Bold", size: 16))
        var cache = IndependentRowRasterizer.RowFonts(scale: 2, normal: first, caching: true)
        let a = cache.scaledFont(first), b = cache.scaledFont(second), c = cache.scaledFont(third)
        let x = cache.shapingFont(a), y = cache.shapingFont(b), z = cache.shapingFont(c)
        for _ in 0..<3 {
            XCTAssertTrue(cache.scaledFont(second) === b)
            XCTAssertTrue(cache.shapingFont(b) === y)
            XCTAssertTrue(cache.scaledFont(first) === a)
            XCTAssertTrue(cache.shapingFont(a) === x)
            XCTAssertTrue(cache.scaledFont(third) === c)
            XCTAssertTrue(cache.shapingFont(c) === z)
        }
        XCTAssertEqual(cache.scaledEntryCount, 3)
        XCTAssertEqual(cache.shapingEntryCount, 3)
        XCTAssertTrue(cache.hasAdditionalScaledStorage)
        XCTAssertTrue(cache.hasAdditionalShapingStorage)
    }

    func testDistinctSourceObjectsWithSameNameRemainDistinctKeys() throws {
        let (plain, transformed) = sameNameFonts()
        XCTAssertEqual(plain.fontName, transformed.fontName)
        XCTAssertEqual(plain.pointSize, transformed.pointSize)
        XCTAssertFalse(plain === transformed)
        var cache = IndependentRowRasterizer.RowFonts(scale: 2, normal: plain, caching: true)
        let a = cache.scaledFont(plain), b = cache.scaledFont(transformed)
        XCTAssertEqual(cache.scaledEntryCount, 2)
        XCTAssertTrue(cache.scaledFont(plain) === a)
        XCTAssertTrue(cache.scaledFont(transformed) === b)
        let x = cache.shapingFont(plain), y = cache.shapingFont(transformed)
        XCTAssertEqual(cache.shapingEntryCount, 2)
        XCTAssertTrue(cache.shapingFont(plain) === x)
        XCTAssertTrue(cache.shapingFont(transformed) === y)
    }

    func testBothTiersRetainOriginalSourceObjects() throws {
        let normal = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 28))
        var cache = IndependentRowRasterizer.RowFonts(scale: 2, normal: normal, caching: true)
        weak var firstSource: NSFont?
        weak var secondSource: NSFont?
        autoreleasepool {
            let (first, second) = sameNameFonts()
            firstSource = first
            secondSource = second
            _ = cache.scaledFont(first)
            _ = cache.scaledFont(second)
            _ = cache.shapingFont(first)
            _ = cache.shapingFont(second)
        }
        let first = try XCTUnwrap(firstSource)
        let second = try XCTUnwrap(secondSource)
        XCTAssertFalse(first === second)
        _ = cache.scaledFont(first)
        _ = cache.scaledFont(second)
        _ = cache.shapingFont(first)
        _ = cache.shapingFont(second)
        XCTAssertEqual(cache.scaledEntryCount, 2)
        XCTAssertEqual(cache.shapingEntryCount, 2)
    }

    func testMissingFontFallbackAndDisabledCachingAllocateNoEntries() throws {
        let source = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14))
        let normal = try XCTUnwrap(NSFont(name: "Helvetica", size: 28))
        var enabled = IndependentRowRasterizer.RowFonts(scale: 2, normal: normal, caching: true)
        XCTAssertTrue(enabled.scaledFont(nil) === normal)
        XCTAssertTrue(enabled.scaledFont(nil) === normal)
        XCTAssertEqual(enabled.scaledEntryCount, 0)
        XCTAssertFalse(enabled.hasAdditionalScaledStorage)
        var disabled = IndependentRowRasterizer.RowFonts(scale: 2, normal: normal, caching: false)
        for _ in 0..<3 {
            XCTAssertTrue(disabled.scaledFont(nil) === normal)
            let result = disabled.scaledFont(source)
            XCTAssertEqual(result.fontName, source.fontName)
            XCTAssertEqual(result.pointSize, 28)
            _ = disabled.shapingFont(result)
        }
        XCTAssertEqual(disabled.scaledEntryCount, 0)
        XCTAssertEqual(disabled.shapingEntryCount, 0)
        XCTAssertFalse(disabled.hasAdditionalScaledStorage)
        XCTAssertFalse(disabled.hasAdditionalShapingStorage)
    }

    func testNoNewLimitOnDistinctFonts() throws {
        let normal = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14))
        let sources = try (0..<64).map { index in
            try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 10 + CGFloat(index) / 4))
        }
        XCTAssertEqual(Set(sources.map(ObjectIdentifier.init)).count, 64)
        var cache = IndependentRowRasterizer.RowFonts(scale: 2, normal: normal, caching: true)
        let scaled = sources.map { cache.scaledFont($0) }
        let shaping = sources.map { cache.shapingFont($0) }
        for index in sources.indices.reversed() {
            XCTAssertTrue(cache.scaledFont(sources[index]) === scaled[index])
            XCTAssertTrue(cache.shapingFont(sources[index]) === shaping[index])
        }
        XCTAssertEqual(cache.scaledEntryCount, 64)
        XCTAssertEqual(cache.shapingEntryCount, 64)
    }

    func testFreshRowsKeepIndependentScaleAndFallback() throws {
        let source = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14))
        let normalA = try XCTUnwrap(NSFont(name: "Helvetica", size: 14))
        let normalB = try XCTUnwrap(NSFont(name: "Helvetica", size: 28))
        var a = IndependentRowRasterizer.RowFonts(scale: 1, normal: normalA, caching: true)
        var b = IndependentRowRasterizer.RowFonts(scale: 2, normal: normalB, caching: true)
        XCTAssertTrue(a.scaledFont(nil) === normalA)
        XCTAssertTrue(b.scaledFont(nil) === normalB)
        XCTAssertEqual(a.scaledFont(source).pointSize, 14)
        XCTAssertEqual(b.scaledFont(source).pointSize, 28)
        XCTAssertEqual(a.scaledEntryCount, 1)
        XCTAssertEqual(b.scaledEntryCount, 1)
    }


    func testWholeRowsKeepExactFreshBehaviorThroughBothTiers() throws {
        let (first, sameNameSecond) = sameNameFonts()
        let third = try XCTUnwrap(NSFont(name: "Helvetica-Oblique", size: 22))
        let sequence: [NSFont?] = [first, first, sameNameSecond, sameNameSecond,
                                   first, third, sameNameSecond, nil, first, nil]
        let segments = sequence.enumerated().map { index, font in
            var attributes = paint(font: font ?? first)
            if font == nil { attributes[.font] = "invalid-font-falls-back" }
            let string = "af中é"
            return ViewLineSegment(column: index * 4, columnWidth: 1, characterCount: 4,
                attributedString: NSAttributedString(string: string, attributes: attributes),
                cellUTF16Boundaries: TerminalCellIndexMap(text: string).boundaries)
        }
        let info = ViewLineInfo(segments: segments, images: nil)
        for scale: CGFloat in [1, 2] {
            for asciiCaching in [false, true] {
                try assertMatchesFresh(info, scale: scale, asciiCaching: asciiCaching)
            }
        }
    }

    private func sameNameFonts() -> (NSFont, NSFont) {
        let plain = CTFontCreateWithName("Menlo-Regular" as CFString, 14, nil) as NSFont
        var transform = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
        let transformed = CTFontCreateWithName("Menlo-Regular" as CFString, 14, &transform) as NSFont
        return (plain, transformed)
    }

    private func paint(font: NSFont) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.green.withAlphaComponent(0.7),
         .backgroundColor: NSColor.red.withAlphaComponent(0.4),
         .selectionBackgroundColor: NSColor.blue.withAlphaComponent(0.3),
         .underlineStyle: NSUnderlineStyle.single.rawValue,
         .underlineColor: NSColor.orange,
         .strikethroughStyle: NSUnderlineStyle.single.rawValue]
    }

    private func segment(_ text: String, column: Int, font: NSFont) -> ViewLineSegment {
        ViewLineSegment(column: column, columnWidth: 1, characterCount: text.count,
                        attributedString: NSAttributedString(string: text, attributes: paint(font: font)),
                        cellUTF16Boundaries: TerminalCellIndexMap(text: text).boundaries)
    }

    private func assertMatchesFresh(_ info: ViewLineInfo, scale: CGFloat,
                                    asciiCaching: Bool,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        func rasterize(caching: Bool) throws -> IndependentCPURow {
            try XCTUnwrap(IndependentRowRasterizer.rasterize(
                info: info, cols: 48, width: Int(48 * 9.25 * scale), height: Int(30 * scale),
                cellWidth: 9.25 * scale, cellHeight: 30 * scale, scale: scale,
                normalFont: NSFont.monospacedSystemFont(ofSize: 14 * scale, weight: .regular),
                nativeForeground: .white, underlinePosition: -2, underlineThickness: 1,
                preset: .current, antialiasBlocks: false,
                asciiCaching: asciiCaching, fontCaching: caching))
        }
        let actual = try rasterize(caching: true)
        let expected = try rasterize(caching: false)
        XCTAssertEqual(actual.coverage, expected.coverage, file: file, line: line)
        XCTAssertEqual(actual.backgrounds.map(\.rect), expected.backgrounds.map(\.rect), file: file, line: line)
        XCTAssertEqual(actual.backgrounds.map(\.color), expected.backgrounds.map(\.color), file: file, line: line)
        XCTAssertEqual(actual.decorations.map(\.rect), expected.decorations.map(\.rect), file: file, line: line)
        XCTAssertEqual(actual.decorations.map(\.color), expected.decorations.map(\.color), file: file, line: line)
        XCTAssertEqual(actual.tintSpans.map(\.rect), expected.tintSpans.map(\.rect), file: file, line: line)
        XCTAssertEqual(actual.tintSpans.map(\.glyphEnvelope), expected.tintSpans.map(\.glyphEnvelope), file: file, line: line)
        XCTAssertEqual(actual.tintSpans.map(\.color), expected.tintSpans.map(\.color), file: file, line: line)
        XCTAssertEqual(actual.glyphSeeds.map(\.glyph), expected.glyphSeeds.map(\.glyph), file: file, line: line)
        XCTAssertEqual(actual.glyphSeeds.map(\.rect), expected.glyphSeeds.map(\.rect), file: file, line: line)
        XCTAssertEqual(actual.glyphSeeds.map(\.color), expected.glyphSeeds.map(\.color), file: file, line: line)
        for (a, b) in zip(actual.glyphSeeds, expected.glyphSeeds) {
            // CoreText can return non-CFEqual fallback fonts even for two
            // unchanged fresh calls. Compare the atlas key and the exact
            // bitmap produced by the renderer's real glyph consumer instead.
            XCTAssertEqual(CTFontCopyPostScriptName(a.font) as String,
                           CTFontCopyPostScriptName(b.font) as String, file: file, line: line)
            XCTAssertEqual(CTFontGetSize(a.font), CTFontGetSize(b.font), file: file, line: line)
            XCTAssertEqual(CTFontGetMatrix(a.font), CTFontGetMatrix(b.font), file: file, line: line)
            XCTAssertEqual(CTFontGetSymbolicTraits(a.font), CTFontGetSymbolicTraits(b.font), file: file, line: line)
            let rasterizer = CoreTextGlyphRasterizer()
            let aBitmap = rasterizer.rasterize(font: a.font, glyph: a.glyph)
            let bBitmap = rasterizer.rasterize(font: b.font, glyph: b.glyph)
            XCTAssertEqual(aBitmap?.width, bBitmap?.width, file: file, line: line)
            XCTAssertEqual(aBitmap?.height, bBitmap?.height, file: file, line: line)
            XCTAssertEqual(aBitmap?.bearing, bBitmap?.bearing, file: file, line: line)
            XCTAssertEqual(aBitmap?.isColor, bBitmap?.isColor, file: file, line: line)
            XCTAssertEqual(aBitmap?.pixels, bBitmap?.pixels, file: file, line: line)
        }
        XCTAssertEqual(actual.colorTiles.map(\.rect), expected.colorTiles.map(\.rect), file: file, line: line)
        XCTAssertEqual(actual.colorTiles.map(\.bytes), expected.colorTiles.map(\.bytes), file: file, line: line)
    }
}
