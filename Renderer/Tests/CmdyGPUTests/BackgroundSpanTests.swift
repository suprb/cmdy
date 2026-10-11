import AppKit
import XCTest
@testable import CmdyGPU

@MainActor
final class BackgroundSpanTests: XCTestCase {
    func testFragmentedASCIIAndBlankCellsMatchUncachedRasterExactly() throws {
        let menlo = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14))
        let italic = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 28),
                                                  toHaveTrait: .italicFontMask)
        let alphabet = String((32...126).map { Character(UnicodeScalar($0)!) })
        for font in [menlo, italic] {
            for text in [String(repeating: " ", count: 98), alphabet + alphabet] {
                let segments = text.enumerated().map { index, character in
                    segment(String(character), column: index, attributes: [
                        .font: font,
                        .foregroundColor: NSColor(srgbRed: CGFloat(index % 5) / 5,
                                                   green: 0.7, blue: 0.4, alpha: 0.8),
                        .backgroundColor: NSColor(srgbRed: CGFloat(index % 97) / 97,
                                                   green: 0.2, blue: 0.6, alpha: 0.4),
                        .underlineStyle: index % 3 == 0 ? NSUnderlineStyle.double.rawValue : 0,
                        .strikethroughStyle: index % 4 == 0 ? NSUnderlineStyle.single.rawValue : 0,
                    ])
                }
                let info = ViewLineInfo(segments: segments, images: nil)
                for scale: CGFloat in [1, 2] {
                    for cellWidth: CGFloat in [7.25, 12] {
                        let cached = try rasterize(info, cols: text.count, scale: scale,
                                                   cellWidth: cellWidth, asciiCaching: true)
                        let fresh = try rasterize(info, cols: text.count, scale: scale,
                                                  cellWidth: cellWidth, asciiCaching: false)
                        assertRasterEqual(cached, fresh)
                        XCTAssertEqual(cached.tintSpans.count, text.count)
                        XCTAssertFalse(cached.backgrounds.isEmpty)
                        XCTAssertFalse(cached.decorations.isEmpty)
                    }
                }
            }
        }
    }

    func testSegmentCacheInvalidatesForFontsAndUnmodeledShapingAttributes() throws {
        let menlo = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14))
        let large = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 28),
                                                 toHaveTrait: .italicFontMask)
        let styles: [[NSAttributedString.Key: Any]] = [
            [.font: menlo], [.font: large], [.font: menlo],
            [.font: menlo, .baselineOffset: 5],
            [.font: menlo, .baselineOffset: -3],
            [.font: menlo, .strokeWidth: -4, .strokeColor: NSColor.orange],
            [.font: menlo, .obliqueness: 0.3],
            [.font: menlo, .cmdySelectionBackground: NSColor.blue,
             .underlineColor: NSColor.orange, .underlineStyle: NSUnderlineStyle.single.rawValue],
            [.font: menlo, .selectionBackgroundColor: NSColor.red,
             .strikethroughColor: NSColor.cyan, .strikethroughStyle: NSUnderlineStyle.double.rawValue],
            [.font: menlo],
        ]
        let info = ViewLineInfo(segments: styles.enumerated().map { index, attrs in
            segment("f f", column: index * 3, attributes: attrs)
        }, images: nil)
        for scale: CGFloat in [1, 2] {
            for cellWidth: CGFloat in [7.25, 12] {
                assertRasterEqual(
                    try rasterize(info, cols: styles.count * 3, scale: scale,
                                  cellWidth: cellWidth, asciiCaching: true),
                    try rasterize(info, cols: styles.count * 3, scale: scale,
                                  cellWidth: cellWidth, asciiCaching: false))
            }
        }
    }

    func testRepeatedEmptyGlyphMatchesGeneralPixelsAndPaintState() throws {
        let fonts = [
            try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14)),
            NSFontManager.shared.convert(NSFont.systemFont(ofSize: 28),
                                         toHaveTrait: .italicFontMask),
        ]
        for font in fonts {
            for text in [String(repeating: " ", count: 120), "f  f     X   ", "   +--+    "] {
                for scale: CGFloat in [1, 2] {
                    for cellWidth: CGFloat in [6, 7.25, 12] {
                        let info = ViewLineInfo(segments: [segment(text, column: 0, attributes: [
                            .font: font,
                            .foregroundColor: NSColor.green.withAlphaComponent(0.7),
                            .backgroundColor: NSColor.red.withAlphaComponent(0.4),
                            .selectionBackgroundColor: NSColor.blue.withAlphaComponent(0.3),
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                            .underlineColor: NSColor.orange,
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        ])], images: nil)
                        let cached = try rasterize(info, cols: text.utf16.count, scale: scale,
                                                   cellWidth: cellWidth, asciiCaching: true)
                        let general = try rasterize(info, cols: text.utf16.count, scale: scale,
                                                    cellWidth: cellWidth, asciiCaching: false)
                        assertRasterEqual(cached, general)
                        XCTAssertFalse(cached.backgrounds.isEmpty)
                        XCTAssertFalse(cached.decorations.isEmpty)
                        XCTAssertEqual(cached.tintSpans.count, text.utf16.count)
                        if text.allSatisfy({ $0 == " " }) {
                            XCTAssertFalse(cached.coverage.contains { $0 != 0 })
                            XCTAssertTrue(cached.glyphSeeds.isEmpty)
                            XCTAssertTrue(cached.tintSpans.allSatisfy { $0.glyphEnvelope == nil })
                        }
                    }
                }
            }
        }
    }

    func testRepeatedBlankCoverageCannotEraseNeighboringOverhang() throws {
        let font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 28),
                                                toHaveTrait: .italicFontMask)
        let info = ViewLineInfo(segments: [segment("f    ", column: 0,
                                                  attributes: [.font: font])], images: nil)
        for scale: CGFloat in [1, 2] {
            let cached = try rasterize(info, cols: 5, scale: scale,
                                       cellWidth: 6, asciiCaching: true)
            let general = try rasterize(info, cols: 5, scale: scale,
                                        cellWidth: 6, asciiCaching: false)
            assertRasterEqual(cached, general)
            let neighbor = Int(6 * scale)..<Int(12 * scale)
            XCTAssertTrue((0..<cached.height).contains { y in
                neighbor.contains { x in cached.coverage[y * cached.width + x] != 0 }
            })
        }
    }

    private func assertRasterEqual(_ actual: IndependentCPURow, _ expected: IndependentCPURow,
                                   file: StaticString = #filePath, line: UInt = #line) {
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
        for (left, right) in zip(actual.glyphSeeds, expected.glyphSeeds) {
            XCTAssertTrue(CFEqual(left.font, right.font), file: file, line: line)
        }
        XCTAssertEqual(actual.colorTiles.count, expected.colorTiles.count, file: file, line: line)
    }

    func testUniformASCIIBackgroundBecomesOneSpanAtBothScales() throws {
        for scale: CGFloat in [1, 2] {
            let info = ViewLineInfo(segments: [segment(
                String(repeating: " ", count: 120), column: 0,
                attributes: [.backgroundColor: NSColor.red.withAlphaComponent(0.4)])], images: nil)
            let cached = try rasterize(info, cols: 120, scale: scale, asciiCaching: true)
            let general = try rasterize(info, cols: 120, scale: scale, asciiCaching: false)
            XCTAssertEqual(cached.backgrounds.count, 1)
            XCTAssertEqual(cached.backgrounds.first?.rect,
                           CGRect(x: 0, y: 0, width: 120 * 12 * scale, height: 24 * scale))
            XCTAssertEqual(cached.backgrounds.map(\.rect), general.backgrounds.map(\.rect))
            XCTAssertEqual(cached.backgrounds.map(\.color), general.backgrounds.map(\.color))
            XCTAssertEqual(cached.coverage, general.coverage)
        }
    }

    func testUnicodeCellWidthsAndSelectedAttributeBoundariesArePreserved() throws {
        let red = NSColor.red.withAlphaComponent(0.4)
        let blue = NSColor.blue.withAlphaComponent(0.5)
        let info = ViewLineInfo(segments: [
            segment("e\u{301}", column: 0, attributes: [.backgroundColor: red], boundaries: [0, 2]),
            segment("中", column: 1, attributes: [.backgroundColor: red], columnWidth: 2),
            segment(" ", column: 3, attributes: [.backgroundColor: red,
                                                 .cmdySelectionBackground: blue]),
            segment(" ", column: 4, attributes: [.backgroundColor: red,
                                                 .selectionBackgroundColor: blue]),
            segment(" ", column: 5, attributes: [.backgroundColor: red]),
        ], images: nil)
        let row = try rasterize(info)
        XCTAssertEqual(row.backgrounds.map(\.rect), [
            CGRect(x: 0, y: 0, width: 36, height: 24),
            CGRect(x: 36, y: 0, width: 24, height: 24),
            CGRect(x: 60, y: 0, width: 12, height: 24),
        ])
        XCTAssertEqual(row.backgrounds.map(\.color), [
            IndependentRowRasterizer.rgba(red), IndependentRowRasterizer.rgba(blue),
            IndependentRowRasterizer.rgba(red),
        ])
    }

    func testOverlapsGapsDifferentRowsAndDifferentColorsAreNeverMerged() {
        let red = SIMD4<Float>(1, 0, 0, 0.4)
        let blue = SIMD4<Float>(0, 0, 1, 0.4)
        let input = [
            solid(x: 0, width: 9, color: red),
            solid(x: 8, width: 9, color: red), // outward pixel alignment overlaps
            solid(x: 18, width: 8, color: red), // gap
            solid(x: 26, width: 8, color: blue),
            IndependentSolidRect(rect: CGRect(x: 34, y: 1, width: 8, height: 23), color: blue),
            solid(x: 8, width: 8, color: blue), // source paint order is not sorted
        ]
        let actual = coalesced(input)
        XCTAssertEqual(actual.count, input.count)
        assertPaintStacksEqual(input, actual, width: 48, height: 26)
    }

    func testFractionalCellsKeepRepeatedAlphaAtOutwardRoundedEdges() throws {
        let info = ViewLineInfo(segments: [segment("    ", column: 0,
            attributes: [.backgroundColor: NSColor.red.withAlphaComponent(0.4)])], images: nil)
        let row = try rasterize(info, cellWidth: 7.25)
        XCTAssertEqual(row.backgrounds.count, 4)
        XCTAssertEqual(row.backgrounds.map(\.rect), (0..<4).map {
            let left = (CGFloat($0) * 7.25).rounded(.down)
            let right = (CGFloat($0 + 1) * 7.25).rounded(.up)
            return CGRect(x: left, y: 0, width: right - left, height: 24)
        })
    }

    func testCoalescedBackgroundMatchesPerCellPaintingThroughSelectionAndDECModes() {
        for scale: CGFloat in [1, 2] {
            let width: CGFloat = 8 * scale
            let height: CGFloat = 24 * scale
            let input = (0..<8).map {
                IndependentSolidRect(rect: CGRect(x: CGFloat($0) * width, y: 0,
                                                  width: width, height: height),
                                     color: SIMD4<Float>(0.7, 0.1, 0.2, 0.4))
            }
            let merged = coalesced(input)
            XCTAssertEqual(merged.count, 1)
            for mode: RenderLineMode in [.single, .doubleWidth, .doubledTop, .doubledDown] {
                for selection in [nil, CGRect(x: width * 2, y: 0, width: width * 3, height: height)] {
                    func transformed(_ rows: [IndependentSolidRect]) -> [IndependentSolidRect] {
                        rows.flatMap { row in
                            MetalTerminalRenderer.backgroundFragments(row.rect, excluding: selection).map {
                                IndependentSolidRect(rect: MetalTerminalRenderer.lineModeRect(
                                    $0, displayIndex: 0, mode: mode, xOrigin: 3.25,
                                    yOrigin: 2.25, cellHeight: height), color: row.color)
                            }
                        }
                    }
                    assertPaintStacksEqual(transformed(input), transformed(merged),
                                          width: Int(width * 16 + 8), height: Int(height + 8))
                }
            }
        }
    }

    private func solid(x: CGFloat, width: CGFloat, color: SIMD4<Float>) -> IndependentSolidRect {
        IndependentSolidRect(rect: CGRect(x: x, y: 0, width: width, height: 24), color: color)
    }

    private func coalesced(_ input: [IndependentSolidRect]) -> [IndependentSolidRect] {
        var output: [IndependentSolidRect] = []
        for solid in input { IndependentSolidRect.appendCoalescing(solid, to: &output) }
        return output
    }

    /// Equal ordered source colors at every sample imply equal compositing,
    /// including translucent overlap. Sampling avoids shared rectangle edges.
    private func assertPaintStacksEqual(_ expected: [IndependentSolidRect],
                                        _ actual: [IndependentSolidRect], width: Int, height: Int,
                                        file: StaticString = #filePath, line: UInt = #line) {
        for y in 0..<height {
            for x in 0..<width {
                let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                let expectedColors = expected.filter { $0.rect.contains(point) }.map(\.color)
                let actualColors = actual.filter { $0.rect.contains(point) }.map(\.color)
                if expectedColors != actualColors {
                    XCTFail("Paint order differs at \(point)", file: file, line: line)
                    return
                }
            }
        }
    }

    private func segment(_ text: String, column: Int,
                         attributes: [NSAttributedString.Key: Any],
                         boundaries: [Int]? = nil, columnWidth: Int = 1) -> ViewLineSegment {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.white,
        ].merging(attributes, uniquingKeysWith: { _, value in value }))
        let cells = boundaries ?? Array(0...attributed.length)
        return ViewLineSegment(column: column, columnWidth: columnWidth,
            characterCount: cells.count - 1, attributedString: attributed,
            cellUTF16Boundaries: cells)
    }

    private func rasterize(_ info: ViewLineInfo, cols: Int = 16, scale: CGFloat = 1,
                           cellWidth: CGFloat = 12, asciiCaching: Bool = true) throws -> IndependentCPURow {
        try XCTUnwrap(IndependentRowRasterizer.rasterize(
            info: info, cols: cols, width: Int((CGFloat(cols) * cellWidth * scale).rounded(.up)),
            height: Int(24 * scale), cellWidth: cellWidth * scale,
            cellHeight: 24 * scale, scale: scale,
            normalFont: .monospacedSystemFont(ofSize: 14 * scale, weight: .regular),
            nativeForeground: .white, underlinePosition: -2, underlineThickness: 1,
            preset: .current, antialiasBlocks: true, asciiCaching: asciiCaching))
    }
}
