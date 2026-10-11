import XCTest
@testable import CmdyCore

final class ContainedASCIIRunTests: XCTestCase {
    func testContainedExactFitAndCrossRowRunsMatchOriginalBulkState() {
        for columns in [1, 2, 7, 17, 120] {
            for start in Set([0, max(0, columns - 2), columns - 1, columns, columns + 1]) {
                for count in Set([0, 1, max(0, columns - start), max(1, columns - start + 1), columns * 2 + 3]) {
                    let (actual, expected) = pair(columns: columns)
                    for terminal in [actual, expected] {
                        terminal.feed(text: String(repeating: "seed界e\u{301}\r\n", count: 12))
                        terminal.feed(text: "\u{1B}[38;2;11;22;33;48;5;4;4:3m\u{1B}]8;;https://example.invalid/fixture\u{1B}\\")
                        terminal.buffer.x = start
                        terminal.buffer.wrapPending = start >= columns
                        _ = terminal.consumeDirtyRows()
                    }
                    let text = (0..<count).map { UInt8(0x20 + $0 % 95) }
                    let padded = [UInt8](repeating: 0x1B, count: 3) + text + [0x1B]
                    let bytes = padded[3..<(3 + count)]
                    let context = "columns \(columns), start \(start), count \(count)"
                    compareWrite(actual, expected, bytes, context)
                    for tail in ["\u{301}", "\u{FE0F}", "\r\nZ\u{FE0E}"] {
                        actual.feed(text: tail); expected.feed(text: tail)
                        equivalent(actual, expected, context + " after " + tail.debugDescription)
                    }
                }
            }
        }
    }

    func testAddressableStalePendingDoesNotAdvanceAndKeepsFollowerOwnership() {
        for start in [0, 1, 5, 6] {
            for count in [1, 7 - start] {
                let (actual, expected) = pair(columns: 7)
                for terminal in [actual, expected] {
                    terminal.feed(text: "rowzero\r\nsecond\r\nthird\u{1B}[2;1H")
                    terminal.buffer.x = start
                    terminal.buffer.wrapPending = true
                    _ = terminal.consumeDirtyRows()
                }
                let beforeTop = actual.buffer.yBase
                let beforeRow = actual.buffer.y
                compareWrite(actual, expected, Array(String(repeating: "7", count: count).utf8)[...],
                             "stale pending start \(start), count \(count)")
                XCTAssertEqual(actual.buffer.yBase, beforeTop)
                XCTAssertEqual(actual.buffer.y, beforeRow)
                XCTAssertEqual(actual.buffer.x, start + count)
                XCTAssertEqual(actual.buffer.wrapPending, start + count == 7)
                XCTAssertEqual(actual.dirtyRowSpan, (beforeTop + beforeRow)...(beforeTop + beforeRow))
                for text in ["\u{FE0F}", "\u{301}", "\u{1B}[1A\u{FE0E}", "\u{200D}💻"] {
                    actual.feed(text: text); expected.feed(text: text)
                    equivalent(actual, expected, text.debugDescription)
                }
            }
        }
    }

    func testUnusualModesAndInteriorScrollUseOriginalTransitions() {
        let modes = ["\u{1B}[?7l", "\u{1B}[4h", "\u{1B}[?69h\u{1B}[2;5s",
                     "\u{1B}[2;3r\u{1B}[?6h", "\u{1B}[?1049h",
                     "\u{1B}[?69h\u{1B}[2;5s\u{1B}[?69l"]
        for mode in modes {
            for count in [1, 3, 7, 20] {
                let (actual, expected) = pair(columns: 7)
                for terminal in [actual, expected] {
                    terminal.feed(text: "A界e\u{301}B\r\nC界D\r\nE界F\r\nG界H")
                    terminal.feed(text: mode + "\u{1B}[3;2H")
                }
                compareWrite(actual, expected, Array(String(repeating: "x", count: count).utf8)[...],
                             mode.debugDescription + ", count \(count)")
                for text in ["\u{301}\u{FE0F}", "\u{1B}M\u{FE0E}", "\u{1B}[?1049l\r\nY"] {
                    actual.feed(text: text); expected.feed(text: text)
                    equivalent(actual, expected, mode.debugDescription + text.debugDescription)
                }
            }
        }
    }

    func testReverseIndexCursorUpAndSelectorProvenanceMatchBulkOracle() {
        let histories = [
            "\u{1B}[1;1H❤\u{FE0F}\u{1B}M",
            "\u{1B}[2;4r\u{1B}[2;1H👩\u{200D}💻\u{1B}M",
            "\u{1B}[2;2H7\u{FE0F}\u{1B}[1A",
            "\u{1B}[1;7H7\u{FE0F}",
            "\u{1B}[?7l\u{1B}[2;7HZ\u{1B}[?7h",
            "\u{1B}[2;1H❤\u{1B}[1L\u{1B}[1S",
            "\u{1B}[?69h\u{1B}[2;5s\u{1B}[2;5H7\u{FE0F}\u{1B}[?69l",
            "\u{1B}[1;1H❤\u{1B}[?1049h\u{1B}[?1049l"
        ]
        let tails = ["\u{301}", "\u{FE0E}", "\u{FE0F}", "\u{200D}💻", "\u{E0100}",
                     "\u{1B}[1D\u{FE0F}", "\u{1B}[1A\u{301}", "\u{1B}M\u{FE0F}"]
        for history in histories {
            for tail in tails {
                for text in ["7", "#A", "12345678"] {
                    let (actual, expected) = pair(columns: 7)
                    for terminal in [actual, expected] {
                        terminal.feed(text: "old界e\u{301}\r\nnext界\r\nlast界\r\nend")
                        terminal.feed(text: history)
                    }
                    compareWrite(actual, expected, Array(text.utf8)[...], history.debugDescription + text)
                    for following in [tail, "\u{1B}[1C\u{FE0E}\u{301}", "\u{1B}[1L\u{1B}[1M\u{FE0F}"] {
                        actual.feed(text: following); expected.feed(text: following)
                        equivalent(actual, expected, history.debugDescription + text + following.debugDescription)
                    }
                }
            }
        }
    }

    func testRetainedSnapshotsRowMetadataAndImagesSurviveContainedOverwrite() {
        let (actual, expected) = pair(columns: 17)
        for terminal in [actual, expected] {
            terminal.feed(text: "界e\u{301}界e\u{308}\u{1B}[1;2H")
            let row = terminal.buffer.liveLine(0)
            row.isWrapped = true
            row.wrapStyle = .words
            row.renderMode = .doubleWidth
            row.images = [LineImage(payload: .rgba(bytes: [1, 2, 3, 255], width: 1, height: 1),
                                    pixelWidth: 1, pixelHeight: 1, col: 4)]
            _ = terminal.consumeDirtyRows()
        }
        let before = actual.captureTerminalSnapshot(consumeDamage: false)
        let oldCells = detachedCells(before)
        let oldVersions = before.lines.map(\.version)
        let oldImage = before.lines[0].images[0].renderIdentity
        compareWrite(actual, expected, Array("abc".utf8)[...], "metadata and snapshot")
        XCTAssertEqual(actual.dirtyRowSpan, 0...0)
        XCTAssertTrue(actual.buffer.liveLine(0).isWrapped)
        XCTAssertEqual(actual.buffer.liveLine(0).wrapStyle, .words)
        XCTAssertEqual(actual.buffer.liveLine(0).renderMode, .doubleWidth)
        XCTAssertEqual(actual.buffer.liveLine(0).images?.first?.renderIdentity, oldImage)
        for text in ["\u{301}", "\u{FE0F}", String(repeating: "scroll\r\n", count: 15)] {
            actual.feed(text: text); expected.feed(text: text)
            equivalent(actual, expected, text.debugDescription)
        }
        XCTAssertEqual(before.lines.map(\.cells), oldCells)
        XCTAssertEqual(before.lines.map(\.version), oldVersions)
        XCTAssertEqual(before.lines[0].images[0].col, 4)
        XCTAssertEqual(before.lines[0].images[0].renderIdentity, oldImage)
    }

    func testChunkedRealFeedMatchesScalarOracleAcrossWrapAndControls() {
        let text = "\u{1B}[31;44m" + String(repeating: "abc1234567890\r\n", count: 17)
            + "\u{1B}[0mA7\u{FE0F}\u{301}\r\n界e\u{301}\u{1B}[1A#\u{FE0E}"
            + "\u{1B}[?7l123456789012345\u{1B}[?7h\r\nend"
        let bytes = Array(text.utf8)
        for columns in [1, 7, 17, 120] {
            for chunk in [1, 2, 7, 31, 1024] {
                let (actual, expected) = pair(columns: columns)
                expected.parser.coalescesPrintableASCII = false
                expected.parser.batchesOrdinaryUnicode = false
                for start in stride(from: 0, to: bytes.count, by: chunk) {
                    let part = bytes[start..<min(bytes.count, start + chunk)]
                    actual.feed(part); expected.feed(part)
                    equivalent(actual, expected, "scalar oracle cols \(columns), chunk \(chunk), offset \(start)")
                }
            }
        }
    }

    func testContentCallbackReentrySeesCommittedContainedRun() {
        let (actual, expected) = pair(columns: 17)
        let observer = Observer()
        actual.delegate = observer
        observer.onChange = { terminal in
            guard observer.changes == 1 else { return }
            XCTAssertEqual(terminal.buffer.x, 3)
            XCTAssertEqual(terminal.buffer.liveLine(0).cells.prefix(3).map(\.scalar), [97, 98, 55])
            terminal.feed(text: "\u{FE0F}\u{301}\u{1B}[6n")
        }
        actual.feed(text: "ab7")
        expected.parserPrintASCIIWithTransitions(Array("ab7".utf8)[...])
        expected.feed(text: "\u{FE0F}\u{301}\u{1B}[6n")
        XCTAssertEqual(observer.changes, 2)
        XCTAssertEqual(observer.replies.count, 1)
        equivalent(actual, expected, "content callback reentry")
    }

    private func pair(columns: Int) -> (CmdyTerminal, CmdyTerminal) {
        (CmdyTerminal(cols: columns, rows: 4, scrollback: 7),
         CmdyTerminal(cols: columns, rows: 4, scrollback: 7))
    }

    private func compareWrite(_ actual: CmdyTerminal, _ expected: CmdyTerminal,
                              _ bytes: ArraySlice<UInt8>, _ context: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        equivalent(actual, expected, "before " + context, file: file, line: line)
        let snapshots = [actual, expected].map { $0.captureTerminalSnapshot(consumeDamage: false) }
        let savedCells = snapshots.map(detachedCells)
        let savedVersions = snapshots.map { $0.lines.map(\.version) }
        actual.parserPrintASCII(bytes)
        expected.parserPrintASCIIWithTransitions(bytes)
        equivalent(actual, expected, context, file: file, line: line)
        for index in snapshots.indices {
            XCTAssertEqual(snapshots[index].lines.map(\.cells), savedCells[index], context, file: file, line: line)
            XCTAssertEqual(snapshots[index].lines.map(\.version), savedVersions[index], context, file: file, line: line)
        }
    }

    private func detachedCells(_ snapshot: CoreTerminalSnapshot) -> [[Cell]] {
        snapshot.lines.map { row in row.cells.map { cell in
            Cell(scalar: cell.scalar, clusterExtras: cell.clusterExtras.map { $0.map { $0 } },
                 width: cell.width, attribute: cell.attribute, linkId: cell.linkId)
        } }
    }

    // Compare both complete buffers, not just visible text. Global row tokens
    // are checked for snapshot immutability above rather than equated across
    // independent engines. Private selector/owner state is observed by the
    // continuation, motion, buffer-switch and recycling probes in each test.
    private func equivalent(_ actual: CmdyTerminal, _ expected: CmdyTerminal, _ context: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.isAlternateBuffer, expected.isAlternateBuffer, context, file: file, line: line)
        XCTAssertEqual(actual.currentAttribute, expected.currentAttribute, context, file: file, line: line)
        XCTAssertEqual(actual.dirtyRowSpan, expected.dirtyRowSpan, context, file: file, line: line)
        XCTAssertEqual([actual.lastWrite.row, actual.lastWrite.x, actual.lastWrite.cols, actual.lastWrite.rows],
                       [expected.lastWrite.row, expected.lastWrite.x, expected.lastWrite.cols, expected.lastWrite.rows], context, file: file, line: line)
        XCTAssertEqual(actual.linkTable, expected.linkTable, context, file: file, line: line)
        XCTAssertEqual(actual.activeLinkId, expected.activeLinkId, context, file: file, line: line)
        XCTAssertEqual(actual.title, expected.title, context, file: file, line: line)
        XCTAssertEqual([actual.autoWrap, actual.insertMode, actual.marginMode, actual.originMode,
                        actual.lineFeedMode, actual.reverseWraparound, actual.cursorHidden,
                        actual.applicationCursorKeys, actual.bracketedPaste, actual.focusReporting,
                        actual.reverseVideo, actual.cursorBlink, actual.synchronizedUpdates],
                       [expected.autoWrap, expected.insertMode, expected.marginMode, expected.originMode,
                        expected.lineFeedMode, expected.reverseWraparound, expected.cursorHidden,
                        expected.applicationCursorKeys, expected.bracketedPaste, expected.focusReporting,
                        expected.reverseVideo, expected.cursorBlink, expected.synchronizedUpdates], context, file: file, line: line)
        XCTAssertEqual(actual.cursorStyle, expected.cursorStyle, context, file: file, line: line)
        XCTAssertEqual(actual.mouseMode, expected.mouseMode, context, file: file, line: line)
        XCTAssertEqual(actual.mouseProtocol, expected.mouseProtocol, context, file: file, line: line)
        for (a, b) in [(actual.normalBuffer, expected.normalBuffer), (actual.altBuffer, expected.altBuffer)] {
            XCTAssertEqual([a.cols, a.rows, a.x, a.y, a.yBase, a.yDisp, a.lineCount, a.droppedLines,
                            a.scrollTop, a.scrollBottom, a.marginLeft, a.marginRight, a.maxScrollback],
                           [b.cols, b.rows, b.x, b.y, b.yBase, b.yDisp, b.lineCount, b.droppedLines,
                            b.scrollTop, b.scrollBottom, b.marginLeft, b.marginRight, b.maxScrollback], context, file: file, line: line)
            XCTAssertEqual(a.wrapPending, b.wrapPending, context, file: file, line: line)
            XCTAssertEqual(a.tabStops, b.tabStops, context, file: file, line: line)
            XCTAssertEqual(a.overflowLines.keys.sorted(), b.overflowLines.keys.sorted(), context, file: file, line: line)
            for (first, second) in zip(a.lines, b.lines) {
                equivalentLine(first, second, context, file: file, line: line)
            }
            for key in a.overflowLines.keys {
                if let first = a.overflowLines[key], let second = b.overflowLines[key] {
                    equivalentLine(first, second, context, file: file, line: line)
                }
            }
        }
    }

    private func equivalentLine(_ a: Line, _ b: Line, _ context: String,
                                file: StaticString, line: UInt) {
        XCTAssertEqual(a.cells, b.cells, context, file: file, line: line)
        XCTAssertEqual(a.isWrapped, b.isWrapped, context, file: file, line: line)
        XCTAssertEqual(a.wrapStyle, b.wrapStyle, context, file: file, line: line)
        XCTAssertEqual(a.renderMode, b.renderMode, context, file: file, line: line)
        XCTAssertEqual(a.images?.map { [$0.col, $0.pixelWidth, $0.pixelHeight, $0.kittyZIndex] },
                       b.images?.map { [$0.col, $0.pixelWidth, $0.pixelHeight, $0.kittyZIndex] }, context, file: file, line: line)
    }

    private final class Observer: CmdyTerminalDelegate {
        var changes = 0
        var replies: [[UInt8]] = []
        var onChange: ((CmdyTerminal) -> Void)?
        func contentChanged(_ terminal: CmdyTerminal) { changes += 1; onChange?(terminal) }
        func send(_ terminal: CmdyTerminal, data: ArraySlice<UInt8>) { replies.append(Array(data)) }
        func setTitle(_ terminal: CmdyTerminal, title: String) {}
        func setCurrentDirectory(_ terminal: CmdyTerminal, directory: String?) {}
        func bell(_ terminal: CmdyTerminal) {}
        func clipboardCopy(_ terminal: CmdyTerminal, content: Data) {}
        func willReflow(_ terminal: CmdyTerminal) {}
        func didReflow(_ terminal: CmdyTerminal) {}
    }
}
