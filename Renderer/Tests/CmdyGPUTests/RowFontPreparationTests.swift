import AppKit
import CoreText
import XCTest
@testable import CmdyGPU

@MainActor
final class RowFontPreparationTests: XCTestCase {
    func testRepeatedASCIIAndUnicodeKeepExactRasterAtBothScales() throws {
        let font = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14))
        for text in ["aabb ..  ff", "ée\u{301}中가", "🙂👨‍💻☀️"] {
            let info = ViewLineInfo(segments: [
                segment(text, column: 0, font: font),
                segment(text, column: 20, font: font),
            ], images: nil)
            for scale: CGFloat in [1, 2] {
                for asciiCaching in [false, true] {
                    try assertMatchesFresh(info, scale: scale, asciiCaching: asciiCaching)
                }
            }
        }
    }

    func testMixedFontsAndAttributeBoundariesKeepExactRaster() throws {
        let regular = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14))
        let italic = NSFontManager.shared.convert(
            NSFont.systemFont(ofSize: 22), toHaveTrait: .italicFontMask)
        let text = NSMutableAttributedString(string: "f中g中X🙂Y🙂", attributes: paint(font: regular))
        text.addAttributes(paint(font: italic), range: NSRange(location: 2, length: 2))
        text.removeAttribute(.font, range: NSRange(location: 4, length: 1))
        text.addAttribute(.font, value: "invalid-font-falls-back", range: NSRange(location: 7, length: 1))
        let info = ViewLineInfo(segments: [ViewLineSegment(
            column: 0, columnWidth: 1, characterCount: text.string.count,
            attributedString: text,
            cellUTF16Boundaries: TerminalCellIndexMap(text: text.string).boundaries)], images: nil)
        for scale: CGFloat in [1, 2] {
            try assertMatchesFresh(info, scale: scale, asciiCaching: true)
        }
    }

    func testExplicitCellBoundariesAndFallbackFontsKeepExactRaster() throws {
        let font = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14))
        let fixtures: [(String, [Int])] = [
            ("e\u{301}X", [0, 1, 2, 3]),
            ("☀️X", [0, 1, 2, 3]),
            ("👨‍💻X", [0, 2, 3, 5, 6]),
            ("가X", [0, 1, 2, 3]),
        ]
        for (text, boundaries) in fixtures {
            let info = ViewLineInfo(segments: [ViewLineSegment(
                column: 0, columnWidth: 2, characterCount: boundaries.count - 1,
                attributedString: NSAttributedString(string: text, attributes: paint(font: font)),
                cellUTF16Boundaries: boundaries)], images: nil)
            for scale: CGFloat in [1, 2] {
                try assertMatchesFresh(info, scale: scale, asciiCaching: true)
            }
        }
    }

    func testFontPreparationDoesNotPersistAcrossRowsOrScaleChanges() throws {
        let font = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14))
        let info = ViewLineInfo(segments: [segment("a中🙂a中🙂", column: 0, font: font)], images: nil)
        for scale: CGFloat in [1, 2, 1] {
            try assertMatchesFresh(info, scale: scale, asciiCaching: true)
        }
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
