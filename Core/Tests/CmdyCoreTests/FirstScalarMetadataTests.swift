import Foundation
import XCTest
@testable import CmdyCore

final class FirstScalarMetadataTests: XCTestCase {
    func testEveryScalarEmojiPropertyMatchesRuntimeOnMissAndBothCacheHits() {
        let terminal = CmdyTerminal(cols: 1, rows: 1)
        let separator: UnicodeScalar = "\u{200D}"
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = UnicodeScalar(value) else { continue }
            let expected = scalar.properties.isEmoji
            XCTAssertEqual(terminal.emojiPropertyForClustering(scalar), expected, "miss \(value)")
            XCTAssertEqual(terminal.emojiPropertyForClustering(scalar), expected, "newest \(value)")
            XCTAssertFalse(terminal.emojiPropertyForClustering(separator))
            XCTAssertEqual(terminal.emojiPropertyForClustering(scalar), expected, "previous \(value)")
        }
    }

    func testEmojiPropertyCacheEvictionAndTerminalIndependence() {
        let terminals = [CmdyTerminal(cols: 2, rows: 1), CmdyTerminal(cols: 2, rows: 1)]
        let values: [UInt32] = [0, 1, 0x23, 0x2A, 0x30, 0x39, 0xA9, 0x301,
                               0x200D, 0x2764, 0x4E00, 0xFE0F, 0x10000,
                               0x1F1FA, 0x1F3FD, 0x1F469, 0x1F4BB, 0x10FFFF]
        for pass in 0..<64 {
            for (index, value) in values.enumerated() {
                for (offset, terminal) in terminals.enumerated() {
                    let scalar = UnicodeScalar(values[(index + pass + offset) % values.count])!
                    XCTAssertEqual(terminal.emojiPropertyForClustering(scalar), scalar.properties.isEmoji)
                    let other = UnicodeScalar(value)!
                    XCTAssertEqual(terminal.emojiPropertyForClustering(other), other.properties.isEmoji)
                }
            }
        }
    }

    func testContainedFirstBasePreservesOwnerStateAndRetainedRows() {
        let moves = ["", "\u{1B}[1D", "\u{1B}[1C", "\u{1B}[1A",
                     "\u{1B}[2;2H", "\u{1B}M", "\u{1B}[1L",
                     "\u{1B}[?7l", "\u{1B}[4h",
                     "\u{1B}[?69h\u{1B}[2;4s"]
        for columns in [1, 2, 4, 9, 65, 66] {
            for move in moves {
                for base in ["α", "界", "αβ❤", "界👩", "é#"] {
                    let actual = CmdyTerminal(cols: columns, rows: 4, scrollback: 8)
                    let expected = CmdyTerminal(cols: columns, rows: 4, scrollback: 8)
                    expected.parser.batchesOrdinaryUnicode = false
                    let segments = ["界A\u{301}❤\u{FE0F}\r\nxy\r\n1234",
                                    move, base, "\u{FE0F}\u{200D}💻\u{301}",
                                    "\u{1B}[?7h\u{1B}[4l\u{1B}[?69l\r\n",
                                    "\u{1B}[?1049h" + base + "\u{FE0E}",
                                    "\u{1B}[?1049l\u{1B}[2b\u{FE0F}"]
                    for segment in segments {
                        let retained = actual.captureTerminalSnapshot(consumeDamage: false)
                        let cells = retained.lines.map(\.cells)
                        let versions = retained.lines.map(\.version)
                        actual.feed(text: segment); expected.feed(text: segment)
                        equivalent(actual, expected, "\(columns) \(move.debugDescription) \(base) \(segment.debugDescription)")
                        XCTAssertEqual(retained.lines.map(\.cells), cells)
                        XCTAssertEqual(retained.lines.map(\.version), versions)
                    }
                }
            }
        }
    }

    func testFirstScalarAdmissionRetainsEmojiKeycapAndFollowerBoundaries() {
        let cases: [(String, Bool)] = [
            ("α", true), ("界", true), ("é", true),
            ("#", true), ("*", true), ("0", true),
            ("❤", false), ("👩", false), ("🇺", false),
            ("\u{301}", false), ("\u{200D}", false),
            ("\u{FE0E}", false), ("\u{FE0F}", false),
            ("\u{E0100}", false), ("\u{85}", false),
        ]
        for (first, mayBatch) in cases {
            let actual = CmdyTerminal(cols: 20, rows: 3)
            let expected = CmdyTerminal(cols: 20, rows: 3)
            let text = first + "βγ"
            let bytes = [UInt8](repeating: 0xFF, count: 3) + Array(text.utf8) + [0xFF]
            let consumed = actual.parserPrintOrdinaryUnicode(
                bytes[3..<(bytes.count - 1)], first: first.unicodeScalars.first!,
                firstByteCount: first.utf8.count)
            let expectedCount = mayBatch ? text.utf8.count : first.utf8.count
            XCTAssertEqual(consumed, expectedCount, first.debugDescription)
            let printed = mayBatch ? text : first
            for scalar in printed.unicodeScalars { expected.parserPrint(scalar) }
            equivalent(actual, expected, first.debugDescription)
            for suffix in ["\u{FE0F}", "\u{200D}💻", "\u{301}Z"] {
                actual.feed(text: suffix)
                expected.parser.batchesOrdinaryUnicode = false
                expected.feed(text: suffix)
                equivalent(actual, expected, first.debugDescription + suffix.debugDescription)
            }
        }
    }

    func testFactsDoNotCarryAcrossSuccessiveCallsOrTerminalInstances() {
        let pairs = [(CmdyTerminal(cols: 7, rows: 3), CmdyTerminal(cols: 7, rows: 3)),
                     (CmdyTerminal(cols: 3, rows: 4), CmdyTerminal(cols: 3, rows: 4))]
        for (_, expected) in pairs { expected.parser.batchesOrdinaryUnicode = false }
        let segments = ["αβ", "❤\u{FE0F}\u{200D}", "💻", "\u{301}",
                        "界\u{1B}[?7l", "👩\u{200D}", "A", "\u{FE0F}",
                        "\u{1B}[?7h\r\n", "\u{85}βγ", "🇺🇸", "é\u{301}"]
        for index in 0..<segments.count {
            for (pairIndex, pair) in pairs.enumerated() {
                let text = segments[(index + pairIndex * 3) % segments.count]
                pair.0.feed(text: text); pair.1.feed(text: text)
                equivalent(pair.0, pair.1, "terminal \(pairIndex), segment \(index)")
            }
        }
    }

    func testFirstScalarKeepsNestedMetadataAndPostCallbackBufferSeparate() {
        func exercise(_ optimizedFirst: Bool) -> ReentryRun {
            let run = ReentryRun()
            run.terminal.feed(text: "aaaa\r\nbbbb\r\ncccc")
            run.terminal.delegate = run.observer
            run.terminal.blocks.onChange = { [weak run] in
                guard let run, !run.reentered else { return }
                run.reentered = true
                run.observer.events.append("block-before-nested-feed")
                // The outer non-emoji scalar was classified before wrapping.
                // Its scroll callback starts a nested first-emoji print on a
                // different active buffer. Neither classification may cache
                // a terminal/line owner or leak into the other invocation.
                run.terminal.feed(text: "\u{1B}[?1049h\u{1B}[H❤\u{FE0F}\u{1B}[6n")
                run.retained = run.terminal.captureTerminalSnapshot(consumeDamage: false)
                run.observer.events.append("block-after-nested-feed")
            }
            if optimizedFirst {
                let bytes = Array("α".utf8)
                XCTAssertEqual(run.terminal.parserPrintOrdinaryUnicode(
                    bytes[...], first: "α", firstByteCount: bytes.count), bytes.count)
            } else {
                run.terminal.parserPrint("α")
            }
            XCTAssertTrue(run.reentered)
            XCTAssertTrue(run.terminal.isAlternateBuffer)
            return run
        }
        let actual = exercise(true), expected = exercise(false)
        XCTAssertEqual(actual.observer.events, expected.observer.events)
        equivalent(actual.terminal, expected.terminal, "first-scalar scroll callback")
        let before = actual.retained?.lines.map(\.cells)
        let versions = actual.retained?.lines.map(\.version)
        expected.terminal.parser.batchesOrdinaryUnicode = false
        for suffix in ["\u{200D}💻", "\u{FE0E}", "βγ\u{301}"] {
            actual.terminal.feed(text: suffix); expected.terminal.feed(text: suffix)
            equivalent(actual.terminal, expected.terminal, suffix.debugDescription)
        }
        XCTAssertEqual(actual.retained?.lines.map(\.cells), before)
        XCTAssertEqual(actual.retained?.lines.map(\.version), versions)
    }

    func testFirstScalarPreservesSnapshotDirtyRowAndSingleMutationVersion() {
        let actual = CmdyTerminal(cols: 8, rows: 3)
        let expected = CmdyTerminal(cols: 8, rows: 3)
        actual.feed(text: "seed\u{1B}[2;1H"); expected.feed(text: "seed\u{1B}[2;1H")
        _ = actual.consumeDirtyRows(); _ = expected.consumeDirtyRows()
        let retained = actual.captureTerminalSnapshot(consumeDamage: false)
        let cells = retained.lines.map(\.cells), versions = retained.lines.map(\.version)
        let bytes = Array("α".utf8)
        // Versions are globally issued, not counters on an individual row.
        // A fresh witness is the final issued stamp immediately before each
        // singleton print; no setup/snapshot construction occurs in between.
        let nextActualVersion = Line(cols: 1).version &+ 1
        let consumed = actual.parserPrintOrdinaryUnicode(bytes[...], first: "α", firstByteCount: bytes.count)
        XCTAssertEqual(consumed, bytes.count)
        let nextExpectedVersion = Line(cols: 1).version &+ 1
        expected.parserPrint("α")
        equivalent(actual, expected, "single first scalar")
        XCTAssertEqual(actual.dirtyRowSpan, 1...1)
        XCTAssertEqual(actual.buffer.liveLine(1).version, nextActualVersion)
        XCTAssertEqual(expected.buffer.liveLine(1).version, nextExpectedVersion)
        XCTAssertEqual(retained.lines.map(\.cells), cells)
        XCTAssertEqual(retained.lines.map(\.version), versions)
    }

    func testNegativeWidthFirstScalarStillInvalidatesPreviousCluster() {
        for rejected in ["\u{80}", "\u{85}", "\u{9F}"] {
            for prefix in ["e\u{301}", "👩\u{200D}", "❤\u{FE0F}"] {
                let actual = CmdyTerminal(cols: 8, rows: 3)
                let expected = CmdyTerminal(cols: 8, rows: 3)
                actual.feed(text: prefix); expected.feed(text: prefix)
                _ = actual.consumeDirtyRows(); _ = expected.consumeDirtyRows()
                let bytes = Array(rejected.utf8)
                let scalar = rejected.unicodeScalars.first!
                XCTAssertEqual(actual.parserPrintOrdinaryUnicode(bytes[...], first: scalar, firstByteCount: bytes.count), bytes.count)
                expected.parserPrint(scalar)
                equivalent(actual, expected, rejected.debugDescription)
                XCTAssertNotNil(actual.dirtyRowSpan)
                expected.parser.batchesOrdinaryUnicode = false
                for suffix in ["\u{301}", "\u{FE0F}", "💻"] {
                    actual.feed(text: suffix); expected.feed(text: suffix)
                    equivalent(actual, expected, prefix + rejected.debugDescription + suffix)
                }
            }
        }
    }

    private func equivalent(_ actual: CmdyTerminal, _ expected: CmdyTerminal, _ context: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.isAlternateBuffer, expected.isAlternateBuffer, context, file: file, line: line)
        XCTAssertEqual(actual.currentAttribute, expected.currentAttribute, context, file: file, line: line)
        XCTAssertEqual(actual.dirtyRowSpan, expected.dirtyRowSpan, context, file: file, line: line)
        for (a, b) in [(actual.normalBuffer, expected.normalBuffer), (actual.altBuffer, expected.altBuffer)] {
            XCTAssertEqual([a.cols, a.rows, a.x, a.y, a.yBase, a.yDisp, a.lineCount, a.droppedLines],
                           [b.cols, b.rows, b.x, b.y, b.yBase, b.yDisp, b.lineCount, b.droppedLines],
                           context, file: file, line: line)
            XCTAssertEqual(a.wrapPending, b.wrapPending, context, file: file, line: line)
            XCTAssertEqual(a.lines.map(\.cells), b.lines.map(\.cells), context, file: file, line: line)
            XCTAssertEqual(a.lines.map(\.isWrapped), b.lines.map(\.isWrapped), context, file: file, line: line)
            XCTAssertEqual(a.lines.map(\.wrapStyle), b.lines.map(\.wrapStyle), context, file: file, line: line)
            XCTAssertEqual(a.lines.map(\.renderMode), b.lines.map(\.renderMode), context, file: file, line: line)
        }
    }

    private final class ReentryRun {
        let terminal = CmdyTerminal(cols: 4, rows: 3, scrollback: 0)
        let observer = Observer()
        var reentered = false
        var retained: CoreTerminalSnapshot?
    }

    private final class Observer: CmdyTerminalDelegate {
        var events: [String] = []
        func contentChanged(_ terminal: CmdyTerminal) { events.append("content:\(terminal.isAlternateBuffer):\(terminal.cursorColumn)") }
        func send(_ terminal: CmdyTerminal, data: ArraySlice<UInt8>) { events.append("send:\(Array(data))") }
        func setTitle(_ terminal: CmdyTerminal, title: String) {}
        func setCurrentDirectory(_ terminal: CmdyTerminal, directory: String?) {}
        func bell(_ terminal: CmdyTerminal) { events.append("bell") }
        func clipboardCopy(_ terminal: CmdyTerminal, content: Data) {}
        func willReflow(_ terminal: CmdyTerminal) { events.append("willReflow") }
        func didReflow(_ terminal: CmdyTerminal) { events.append("didReflow") }
    }
}
