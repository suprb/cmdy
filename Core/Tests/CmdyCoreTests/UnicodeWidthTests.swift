import XCTest
@testable import CmdyCore

final class UnicodeWidthTests: XCTestCase {
    func testPinnedUnicodeMetadata() {
        XCTAssertEqual(GeneratedUnicodeWidthTables.unicodeVersion, "17.0.0")
        XCTAssertEqual(GeneratedUnicodeWidthParityOracle.unicodeVersion, "17.0.0")
        XCTAssertEqual(
            GeneratedUnicodeWidthParityOracle.sha256,
            "0a6c63c371d379dd5cf3c254b88945d29ce66fd471c90719003197488bb2047c")
        XCTAssertEqual(GeneratedUnicodeWidthTables.sourceDigests.count, 7)
        XCTAssertEqual(
            String(describing: GeneratedUnicodeWidthTables.sourceDigests[0].path),
            "ucd/UnicodeData.txt")
        XCTAssertEqual(
            String(describing: GeneratedUnicodeWidthTables.sourceDigests[0].sha256),
            "2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c")
    }

    func testEveryUnicodeScalarMatchesFrozenParityOracle() {
        var runIndex = 0
        var checked = 0
        var mismatches: [String] = []

        for value in UInt32(0)...UInt32(0x10FFFF) {
            while value > GeneratedUnicodeWidthParityOracle.runs[runIndex].upperBound {
                runIndex += 1
            }
            guard let scalar = UnicodeScalar(value) else { continue }
            checked += 1
            let expected = GeneratedUnicodeWidthParityOracle.runs[runIndex].width
            let actual = CmdyUnicodeWidthPolicy.columnWidth(of: scalar)
            if actual != expected, mismatches.count < 20 {
                mismatches.append(
                    String(format: "U+%04X expected %d, got %d", value, expected, actual))
            }
        }

        XCTAssertEqual(checked, 1_112_064)
        XCTAssertTrue(mismatches.isEmpty, mismatches.joined(separator: "\n"))
    }

    func testControlCombiningAndFormatWidths() {
        assertWidth("\0", 0)
        assertWidth("\u{0007}", -1)
        assertWidth("\u{007F}", -1)
        assertWidth("\u{009F}", -1)
        assertWidth("\u{00AD}", 1)      // printable soft hyphen compatibility
        assertWidth("\u{0600}", 0)      // format control
        assertWidth("\u{0301}", 0)      // nonspacing mark
        assertWidth("\u{093E}", 0)      // spacing combining mark
        assertWidth("\u{20DD}", 0)      // enclosing mark
        assertWidth("\u{2028}", 0)      // line separator
        assertWidth("\u{200D}", 0)      // ZWJ
        assertWidth("\u{2065}", 1)      // reserved compatibility point
        assertWidth("\u{FE0E}", 0)      // text variation selector
        assertWidth("\u{E0100}", 0)     // supplementary variation selector
        assertWidth("\u{1ACF}", 1)      // Unicode 17 combining compatibility freeze
    }

    func testCJKHangulAndHalfwidthWidths() {
        assertWidth("A", 1)
        assertWidth("日", 2)
        assertWidth("あ", 2)
        assertWidth("한", 2)
        assertWidth("\u{1100}", 2)      // Hangul leading jamo
        assertWidth("\u{115F}", 2)      // Hangul choseong filler
        assertWidth("\u{1161}", 0)      // conjoining Hangul vowel
        assertWidth("\u{11A8}", 0)      // conjoining Hangul trailing jamo
        assertWidth("\u{3164}", 2)      // Hangul filler
        assertWidth("\u{FFA0}", 1)      // halfwidth Hangul filler
        assertWidth("\u{FF01}", 2)      // fullwidth exclamation
        assertWidth("\u{FF66}", 1)      // halfwidth katakana
        assertWidth("\u{20000}", 2)     // supplementary CJK ideograph
    }

    func testEmojiPresentationWidthsAndVS16Bases() {
        assertWidth("\u{1F600}", 2)
        assertWidth("\u{1F1FA}", 2)
        assertWidth("\u{1F3FB}", 0)     // emoji modifier joins its base
        assertWidth("\u{2600}", 1)      // default text presentation
        assertWidth("#", 1)

        XCTAssertTrue(CmdyUnicodeWidthPolicy.isEmojiVS16Base("#"))
        XCTAssertTrue(CmdyUnicodeWidthPolicy.isEmojiVS16Base("\u{00A9}"))
        XCTAssertTrue(CmdyUnicodeWidthPolicy.isEmojiVS16Base("\u{2600}"))
        XCTAssertFalse(CmdyUnicodeWidthPolicy.isEmojiVS16Base("A"))
        XCTAssertTrue(CmdyUnicodeWidthPolicy.isRegionalIndicator("\u{1F1E6}"))
        XCTAssertTrue(CmdyUnicodeWidthPolicy.isRegionalIndicator("\u{1F1FF}"))
        XCTAssertFalse(CmdyUnicodeWidthPolicy.isRegionalIndicator("\u{1F1E5}"))
    }

    func testEastAsianAmbiguousPolicyIsNarrow() {
        for scalar: UnicodeScalar in ["\u{00A1}", "\u{00B7}", "\u{03A9}", "\u{2500}"] {
            XCTAssertTrue(CmdyUnicodeWidthPolicy.isEastAsianAmbiguous(scalar))
            XCTAssertEqual(CmdyUnicodeWidthPolicy.columnWidth(of: scalar), 1)
        }
    }

    func testTerminalClustersOccupyExpectedCells() throws {
        let terminal = CmdyTerminal(cols: 20, rows: 4)
        terminal.feed(text: "e\u{0301}☀\u{FE0F}🇺🇸X")

        let line = try XCTUnwrap(terminal.lineForDiff(absolute: 0))
        XCTAssertEqual(line[0].text, "e\u{0301}")
        XCTAssertEqual(line[0].width, 1)
        XCTAssertEqual(line[1].text, "☀\u{FE0F}")
        XCTAssertEqual(line[1].width, 2)
        XCTAssertEqual(line[2].width, 0)
        XCTAssertEqual(line[3].text, "🇺🇸")
        XCTAssertEqual(line[3].width, 2)
        XCTAssertEqual(line[4].width, 0)
        XCTAssertEqual(line[5].text, "X")
        XCTAssertEqual(terminal.cursorColumn, 6)
    }

    private func assertWidth(
        _ scalar: UnicodeScalar,
        _ expected: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            CmdyUnicodeWidthPolicy.columnWidth(of: scalar),
            expected,
            "U+\(String(scalar.value, radix: 16, uppercase: true))",
            file: file,
            line: line)
    }
}
