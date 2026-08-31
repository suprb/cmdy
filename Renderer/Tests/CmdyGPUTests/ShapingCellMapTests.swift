import AppKit
import CoreText
import XCTest
@testable import CmdyGPU

final class ShapingCellMapTests: XCTestCase {
    func testContextualPeriodLigaturesAreDisabledForTerminalGrid() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fontURL = repository
            .appendingPathComponent("Kit/Sources/CmdyKit/Fonts/FragmentMono.ttf")
        var registrationError: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &registrationError)
        guard let font = NSFont(name: "FragmentMono-Regular", size: 28) else {
            throw XCTSkip("Fragment Mono test font unavailable")
        }

        var period: UniChar = 46
        var periodGlyph: CGGlyph = 0
        XCTAssertTrue(CTFontGetGlyphsForCharacters(
            font as CTFont, &period, &periodGlyph, 1))

        let cleanFont = terminalGridShapingFont(font as CTFont)
        for text in ["..", "...", "...."] {
            let attributed = NSAttributedString(
                string: text,
                attributes: [.font: cleanFont, .ligature: 0, .kern: 0])
            let line = CTLineCreateWithAttributedString(attributed)
            let glyphs = (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).flatMap { run in
                let count = CTRunGetGlyphCount(run)
                return [CGGlyph](unsafeUninitializedCapacity: count) { buffer, initialized in
                    CTRunGetGlyphs(run, CFRange(), buffer.baseAddress!)
                    initialized = count
                }
            }
            XCTAssertEqual(glyphs, Array(repeating: periodGlyph, count: text.count), text)
        }
    }

    func testCombiningClusterGlyphsStayInOneTerminalCell() {
        assertCoreTextMapping(cluster: "क्‍ष")
    }

    func testZWJClusterAndStyledASCIIHaveDistinctCellOffsets() {
        let cluster = "👨‍💻"
        assertCoreTextMapping(cluster: cluster)

        let text = cluster + "X"
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)])
        let asciiRange = NSRange(location: cluster.utf16.count, length: 1)
        attributed.addAttribute(.foregroundColor, value: NSColor.red, range: asciiRange)

        let map = TerminalCellIndexMap(text: text)
        var ranges: [Range<Int>] = []
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length),
            options: []) { _, range, _ in
                ranges.append(map.cellRange(forUTF16Range: range))
            }
        XCTAssertEqual(ranges, [0..<1, 1..<2])
    }

    func testExplicitJamoCellsRemainAddressableWhileUnicodeShapingMayCompose() {
        let leading = "ᄀ"
        let vowel = "ᅡ"
        XCTAssertEqual((leading + vowel).count, 1)
        let text = leading + vowel + "X"
        let boundaries = [0, leading.utf16.count,
                          leading.utf16.count + vowel.utf16.count,
                          text.utf16.count]
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)])
        attributed.addAttribute(.foregroundColor, value: NSColor.red,
                                range: NSRange(location: boundaries[2], length: 1))
        let segment = ViewLineSegment(column: 0, columnWidth: 1, characterCount: 3,
                                      attributedString: attributed,
                                      cellUTF16Boundaries: boundaries)
        XCTAssertEqual(segment.cellUTF16Boundaries, boundaries)

        let map = TerminalCellIndexMap(cellUTF16Boundaries: boundaries)
        XCTAssertEqual(map.cellCount, 3)
        XCTAssertEqual(map.cellIndex(forUTF16Offset: boundaries[0]), 0)
        XCTAssertEqual(map.cellIndex(forUTF16Offset: boundaries[1]), 1)
        XCTAssertEqual(map.cellIndex(forUTF16Offset: boundaries[2]), 2)

        var ranges: [Range<Int>] = []
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length),
            options: []) { _, range, _ in
                ranges.append(map.cellRange(forUTF16Range: range))
            }
        XCTAssertEqual(ranges, [0..<2, 2..<3])
    }

    private func assertCoreTextMapping(cluster: String,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        XCTAssertEqual(cluster.count, 1, file: file, line: line)
        let text = cluster + "X"
        let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .ligature: 0])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        let map = TerminalCellIndexMap(text: text)
        let asciiOffset = cluster.utf16.count
        var sawClusterGlyph = false
        var sawASCIIGlyph = false

        for run in CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetStringIndices(run, CFRange(), &indices)
            for index in indices where index != kCFNotFound {
                let cell = map.cellIndex(forUTF16Offset: Int(index))
                if index < asciiOffset {
                    sawClusterGlyph = true
                    XCTAssertEqual(cell, 0, file: file, line: line)
                } else {
                    sawASCIIGlyph = true
                    XCTAssertEqual(cell, 1, file: file, line: line)
                }
            }
        }
        XCTAssertTrue(sawClusterGlyph, file: file, line: line)
        XCTAssertTrue(sawASCIIGlyph, file: file, line: line)
    }
}
