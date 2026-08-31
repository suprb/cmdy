import XCTest
@testable import CmdyCore

/// The engine-native conformance suite: blocks, reflow, replay — the specs
/// the app's --reflow-test proved against SwiftTerm, restated against
/// CmdyCore's own structures (TDD per the plan's risk table).
final class CoreEngineTests: XCTestCase {

    private func makeTerminal(cols: Int = 80, rows: Int = 24) -> CmdyTerminal {
        CmdyTerminal(cols: cols, rows: rows)
    }

    private func feedBlocks(_ term: CmdyTerminal, count: Int, filler: String) {
        for i in 1...count {
            term.feed(text: "\u{1b}]133;A\u{7}")
            term.feed(text: "PROMPT\(i)> \u{1b}]133;B\u{7}cmd\(i)\r\n\u{1b}]133;C\u{7}")
            term.feed(text: filler + "\r\n\u{1b}]133;D;0\u{7}")
        }
    }

    private func misanchored(_ term: CmdyTerminal) -> [String] {
        term.blocks.blocks.compactMap { block in
            let text = term.scrollbackLineText(row: block.promptRow) ?? ""
            return text.contains("PROMPT\(block.index)>") ? nil
                : "block \(block.index) -> row \(block.promptRow): '\(text.prefix(30))'"
        }
    }

    // MARK: Blocks

    func testBlocksRecordPromptCommandExit() {
        let term = makeTerminal()
        term.feed(text: "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}make\r\n\u{1b}]133;C\u{7}building…\r\n\u{1b}]133;D;2\u{7}")
        XCTAssertEqual(term.blocks.blocks.count, 1)
        let block = term.blocks.blocks[0]
        XCTAssertEqual(block.exitCode, 2)
        XCTAssertFalse(block.running)
        XCTAssertNotNil(block.endRow)
        XCTAssertEqual(block.inputStart?.col, 2)
    }

    func testHostMessageInsertedAtOSCCommandBoundaryBeforeNextPrompt() {
        let term = makeTerminal(cols: 80, rows: 8)
        term.setCommandFinishedHostMessageProvider { command, output, exit in
            XCTAssertEqual(command, "missing-tool")
            XCTAssertEqual(output, "failure")
            XCTAssertEqual(exit, 127)
            return "The command could not be found."
        }

        term.feed(text: "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}missing-tool\r\n"
            + "\u{1b}]133;C\u{7}failure\r\n\u{1b}]133;D;127\u{7}"
            + "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")

        XCTAssertEqual(term.scrollbackLineText(row: 1), "failure")
        XCTAssertEqual(term.scrollbackLineText(row: 2), "The command could not be found.")
        XCTAssertEqual(term.scrollbackLineText(row: 3), "$ ")
        XCTAssertTrue(term.lineForDiff(absolute: 2)?.cells.first?.attribute.style.contains(.dim) == true)
        XCTAssertFalse(term.lineForDiff(absolute: 3)?.cells.first?.attribute.style.contains(.dim) == true)
    }

    func testHostMessageProviderDoesNoWorkForSuccessfulCommands() {
        let term = makeTerminal(cols: 80, rows: 8)
        var calls = 0
        term.setCommandFinishedHostMessageProvider { _, _, _ in
            calls += 1
            return "unexpected"
        }

        term.feed(text: "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}true\r\n"
            + "\u{1b}]133;C\u{7}\u{1b}]133;D;0\u{7}\u{1b}]133;A\u{7}$ ")

        XCTAssertEqual(calls, 0)
        XCTAssertFalse((0..<term.bufferLineCount).contains {
            term.scrollbackLineText(row: $0) == "unexpected"
        })
    }

    func testHostMessageWordWrapStaysFlushLeftAcrossResize() {
        let term = makeTerminal(cols: 77, rows: 8)
        let message = "The command whats the clock? exited with status 1. The available output does not identify one certain cause; inspect the final diagnostic lines before changing anything."
        term.insertHostMessage(message)

        for width in [77, 76, 61, 90, 76] {
            term.resize(cols: width, rows: 8)
            let lines = (0..<term.bufferLineCount)
                .compactMap { term.scrollbackLineText(row: $0) }
                .filter { !$0.isEmpty }
            XCTAssertFalse(lines.isEmpty, "width \(width) lost the host message")
            XCTAssertTrue(lines.allSatisfy { !$0.hasPrefix(" ") },
                          "width \(width) indented a continuation: \(lines)")
            XCTAssertEqual(lines.joined(), message,
                           "width \(width) changed host-message text")
        }
    }

    func testSparseViewportDoesNotTurnBlankTailIntoScrollbackDuringReflow() {
        let term = makeTerminal(cols: 49, rows: 39)
        term.feed(text: "/ % la\r\nzsh: command not found: la\r\n"
            + "/ % asd\r\nzsh: command not found: asd\r\n")
        term.insertHostMessage(
            "The shell could not find asd. It may not be installed, or its executable directory may be missing from PATH.")
        for _ in 0..<7 { term.feed(text: "/ %\r\n") }

        XCTAssertEqual(term.liveScreenTopRow, 0)
        XCTAssertEqual(term.currentTopRow, 0)
        for geometry in [(71, 32), (92, 31), (49, 39)] {
            term.resize(cols: geometry.0, rows: geometry.1)
            XCTAssertEqual(term.liveScreenTopRow, 0,
                           "\(geometry) converted blank tail rows into scrollback")
            XCTAssertEqual(term.currentTopRow, 0,
                           "\(geometry) moved the tail-following viewport")
            XCTAssertEqual(term.scrollbackLineText(row: 0), "/ % la")
        }
    }

    func testHostMessageProviderReceivesTheCompleteWrappedCommand() {
        let term = makeTerminal(cols: 18, rows: 8)
        let expected = "cmdy_inline_missing_command_xyz"
        var captured = ""
        var capturedOutput = ""
        term.setCommandFinishedHostMessageProvider { command, output, _ in
            captured = command
            capturedOutput = output
            return nil
        }

        term.feed(text: "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}\(expected)\r\n"
            + "\u{1b}]133;C\u{7}zsh: command not found: \(expected)\r\n"
            + "\u{1b}]133;D;127\u{7}")

        XCTAssertEqual(captured, expected)
        XCTAssertTrue(capturedOutput.contains(expected))
    }

    func testBlankReturnDoesNotRepeatThePreviousFailureHelp() {
        let term = makeTerminal(cols: 80, rows: 8)
        var calls = 0
        term.setCommandFinishedHostMessageProvider { _, _, _ in
            calls += 1
            return "one explanation"
        }
        term.feed(text: "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}missing\r\n"
            + "\u{1b}]133;C\u{7}not found\r\n\u{1b}]133;D;127\u{7}"
            + "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")
        XCTAssertEqual(calls, 1)

        // A blank Return runs precmd (D then A) but never preexec (C).
        term.feed(text: "\r\n\u{1b}]133;D;127\u{7}"
            + "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")

        XCTAssertEqual(calls, 1)
        let transcript = (0..<term.bufferLineCount)
            .compactMap { term.scrollbackLineText(row: $0) }
            .joined(separator: "\n")
        XCTAssertEqual(transcript.components(separatedBy: "one explanation").count - 1, 1)
    }

    func testBlocksRebaseOnScrollbackTrim() {
        let term = CmdyTerminal(cols: 20, rows: 3, scrollback: 4)
        var stream = "\u{1b}]133;A\u{7}OLD> \u{1b}]133;B\u{7}old\r\n"
        for i in 0..<20 { stream += "spam \(i)\r\n" }
        stream += "\u{1b}]133;D;0\u{7}\u{1b}]133;A\u{7}NEW> \u{1b}]133;B\u{7}new"

        // One parser feed trims the old block before creating the new one.
        // The marker hook must synchronize the origin at that boundary, and
        // feed completion must apply any later trims exactly once.
        term.feed(text: stream)

        XCTAssertGreaterThan(term.scrollbackDroppedLines, 0)
        XCTAssertEqual(term.blocks.blocks.count, 1)
        let block = try! XCTUnwrap(term.blocks.blocks.first)
        XCTAssertTrue(term.scrollbackLineText(row: block.promptRow)?.contains("NEW>") == true)
        XCTAssertEqual(block.inputStart?.row, block.promptRow)
    }

    // MARK: Reflow — the --reflow-test scenarios, engine-native

    func testAnchorsSurviveNarrowingReflow() {
        let term = makeTerminal()
        let filler = String(repeating: "x", count: term.cols * 2 + 7)
        feedBlocks(term, count: 30, filler: filler)
        XCTAssertEqual(term.blocks.blocks.count, 30)
        XCTAssertTrue(misanchored(term).isEmpty, "before resize: \(misanchored(term).first ?? "")")

        term.resize(cols: 62, rows: 24)          // narrower -> rewrap
        XCTAssertTrue(misanchored(term).isEmpty, "after narrowing: \(misanchored(term).first ?? "")")

        term.resize(cols: 112, rows: 24)         // wider -> rewrap again
        XCTAssertTrue(misanchored(term).isEmpty, "after widening: \(misanchored(term).first ?? "")")
    }

    func testSparseContentSurvivesGrowingRows() {
        let term = CmdyTerminal(cols: 70, rows: 18)
        feedBlocks(term, count: 4, filler: "out")
        XCTAssertTrue(misanchored(term).isEmpty)
        // Rows explode (zoom out): blank tail padding must not shift anchors.
        term.resize(cols: 70, rows: 44)
        XCTAssertTrue(misanchored(term).isEmpty, "\(misanchored(term).first ?? "")")
        // Taller AND narrower in one go.
        term.resize(cols: 50, rows: 60)
        XCTAssertTrue(misanchored(term).isEmpty, "\(misanchored(term).first ?? "")")
    }

    func testCursorRidesReflow() {
        let term = makeTerminal()
        term.feed(text: String(repeating: "a", count: 150))   // wraps onto row 1
        let textBefore = term.scrollbackLineText(row: 0)! + term.scrollbackLineText(row: 1)!
        term.resize(cols: 40, rows: 24)
        var textAfter = ""
        for r in 0..<term.bufferLineCount where term.isBufferRowWrapped(r) || r == 0 {
            textAfter += term.scrollbackLineText(row: r) ?? ""
        }
        XCTAssertEqual(textBefore.trimmingCharacters(in: .whitespaces),
                       textAfter.trimmingCharacters(in: .whitespaces))
        // Cursor sits right after the 150th 'a' in the rewrapped geometry:
        // logical offset 150 → row 3, col 30 at width 40.
        XCTAssertEqual(term.scrollInvariantCursorRow, 3)
        XCTAssertEqual(term.cursorColumn, 30)
    }

    func testWideCharsNeverSplitAcrossReflow() {
        let term = makeTerminal(cols: 21, rows: 10)
        term.feed(text: String(repeating: "日", count: 30))
        term.resize(cols: 20, rows: 10)
        for r in 0..<term.bufferLineCount {
            guard let line = term.lineForDiff(absolute: r) else { continue }
            // A lead cell in the last column would split the pair.
            if line.cells.last?.width == 2 {
                XCTFail("wide char split at row \(r)")
            }
        }
    }

    func testCellRangeTextDoesNotTreatWideCharactersAsTwoStringIndexes() {
        let term = makeTerminal(cols: 12, rows: 4)
        term.feed(text: "$ 日abc")

        XCTAssertEqual(term.scrollbackLineText(row: 0, columns: 2..<7), "日abc")
        XCTAssertEqual(term.scrollbackLineText(row: 0, columns: 4..<7), "abc")
    }

    func testBulkScrollbackTextMatchesIndividualRowExtraction() {
        let term = makeTerminal(cols: 12, rows: 4)
        term.feed(text: "alpha\r\nbeta\r\n日abc\r\nomega")
        let rows = 0...(term.bufferLineCount + 2)

        XCTAssertEqual(
            term.scrollbackLineTexts(rows: rows),
            rows.map { term.scrollbackLineText(row: $0) ?? "" })
    }

    // MARK: Replay

    func testReplayIsDeterministic() {
        let recorder = SessionRecorder(cols: 80, rows: 24)
        let term = makeTerminal()
        term.startRecording(recorder)
        feedBlocks(term, count: 5, filler: String(repeating: "z", count: 100))
        term.feed(text: "\u{1b}[31mred\u{1b}[0m 日本語 \u{1b}[1;5H over")
        let data = recorder.serialize()

        let log = try! SessionReplay.load(data)
        let replayA = SessionReplay.replay(log)
        let replayB = SessionReplay.replay(log)

        XCTAssertEqual(replayA.bufferLineCount, term.bufferLineCount)
        XCTAssertEqual(replayA.scrollInvariantCursorRow, term.scrollInvariantCursorRow)
        XCTAssertEqual(replayA.cursorColumn, term.cursorColumn)
        for r in 0..<term.bufferLineCount {
            XCTAssertEqual(replayA.scrollbackLineText(row: r), term.scrollbackLineText(row: r), "row \(r)")
            XCTAssertEqual(replayB.scrollbackLineText(row: r), term.scrollbackLineText(row: r), "row \(r)")
        }
        XCTAssertEqual(replayA.blocks.blocks.count, term.blocks.blocks.count)
    }

    // MARK: Parser edges

    func testSplitEscapeAcrossFeeds() {
        let term = makeTerminal()
        term.feed(text: "\u{1b}")
        term.feed(text: "[31mred")
        XCTAssertEqual(term.scrollbackLineText(row: 0), "red")
        XCTAssertEqual(term.lineForDiff(absolute: 0)?.cells[0].attribute.fg, .ansi256(1))
    }

    func testSplitUTF8AcrossFeeds() {
        let term = makeTerminal()
        let bytes = Array("日".utf8)
        term.feed([bytes[0]])
        term.feed([bytes[1], bytes[2]])
        XCTAssertEqual(term.scrollbackLineText(row: 0), "日 ")
    }

    func testOSCTitleAcrossChunkedFeeds() {
        let term = makeTerminal()
        term.feed(text: "\u{1b}]0;my ")
        term.feed(text: "title\u{7}")
        XCTAssertEqual(term.title, "my title")
    }
}

// MARK: - Corpus replay (the oracle's inheritance)

extension CoreEngineTests {
    func testCoalescedASCIIPathMatchesScalarOracle() {
        let bulk = CmdyTerminal(cols: 17, rows: 6, scrollback: 30)
        let scalar = CmdyTerminal(cols: 17, rows: 6, scrollback: 30)
        let chunked = CmdyTerminal(cols: 17, rows: 6, scrollback: 30)
        scalar.parser.coalescesPrintableASCII = false

        var stream = String(repeating: "abc XYZ 123 ", count: 40)
        stream += "\r\nplain one\r\nplain two\r\nplain three\r\n"
        stream += "\r\n\u{1b}[31;44mcolored ASCII\u{1b}[0m\r\n"
        stream += "e\u{301} cafe \u{1F469}\u{200D}\u{1F4BB} plain\r\n"
        stream += "\u{1b}[4hINSERT\u{1b}[4l"
        stream += "\u{1b}[?69h\u{1b}[3;14sMARGIN\u{1b}[?69l"
        stream += "\u{1b}[?7lNO-WRAP-OVERWRITE\u{1b}[?7h"
        stream += "\u{1b}]133;A\u{7}PROMPT> \u{1b}]133;B\u{7}echo ok"

        let padded = [UInt8]([0x00, 0x00]) + Array(stream.utf8) + [0x00, 0x00]
        let payload = padded[2..<(padded.count - 2)]
        bulk.feed(payload)
        scalar.feed(payload)
        var chunkStart = payload.startIndex
        let chunkSizes = [1, 2, 3, 7, 31, 5, 64]
        var chunkNumber = 0
        while chunkStart < payload.endIndex {
            let count = min(chunkSizes[chunkNumber % chunkSizes.count],
                            payload.distance(from: chunkStart, to: payload.endIndex))
            let chunkEnd = payload.index(chunkStart, offsetBy: count)
            chunked.feed(payload[chunkStart..<chunkEnd])
            chunkStart = chunkEnd
            chunkNumber += 1
        }

        XCTAssertEqual(bulk.bufferLineCount, scalar.bufferLineCount)
        XCTAssertEqual(chunked.bufferLineCount, scalar.bufferLineCount)
        XCTAssertEqual(bulk.liveScreenTopRow, scalar.liveScreenTopRow)
        XCTAssertEqual(bulk.currentTopRow, scalar.currentTopRow)
        XCTAssertEqual(bulk.scrollbackDroppedLines, scalar.scrollbackDroppedLines)
        XCTAssertEqual(bulk.scrollInvariantCursorRow, scalar.scrollInvariantCursorRow)
        XCTAssertEqual(bulk.cursorColumn, scalar.cursorColumn)
        XCTAssertEqual(chunked.cursorColumn, scalar.cursorColumn)
        XCTAssertEqual(bulk.currentAttribute, scalar.currentAttribute)
        XCTAssertEqual(bulk.blocks.blocks.count, scalar.blocks.blocks.count)
        XCTAssertEqual(bulk.consumeDirtyRows(), scalar.consumeDirtyRows())

        for row in 0..<bulk.bufferLineCount {
            let bulkLine = try! XCTUnwrap(bulk.lineForDiff(absolute: row))
            let scalarLine = try! XCTUnwrap(scalar.lineForDiff(absolute: row))
            XCTAssertEqual(bulkLine.cells, scalarLine.cells, "cell mismatch at row \(row)")
            let chunkedLine = try! XCTUnwrap(chunked.lineForDiff(absolute: row))
            XCTAssertEqual(chunkedLine.cells, scalarLine.cells,
                           "chunked cell mismatch at row \(row)")
            XCTAssertEqual(bulkLine.isWrapped, scalarLine.isWrapped, "wrap mismatch at row \(row)")
            XCTAssertEqual(chunkedLine.isWrapped, scalarLine.isWrapped,
                           "chunked wrap mismatch at row \(row)")
            XCTAssertEqual(bulkLine.renderMode, scalarLine.renderMode,
                           "render mode mismatch at row \(row)")
        }
    }

    /// Every minimized fuzz divergence ever found (Tests/corpus/regressions)
    /// plus the recorded sessions, replayed through CmdyCore: must not
    /// crash and must be byte-for-byte deterministic across two runs. The
    /// SwiftTerm oracle that first judged these is gone; determinism and
    /// the differential fixtures' history are the contract now.
    func testCorpusReplaysAreDeterministic() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CmdyCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // repo
            .appendingPathComponent("Tests/corpus")
        let fm = FileManager.default
        var replayed = 0

        func snapshot(_ bytes: [UInt8], cols: Int, rows: Int) -> String {
            let t = CmdyTerminal(cols: cols, rows: rows)
            t.feed(bytes)
            var out = "\(t.cursorColumn),\(t.scrollInvariantCursorRow),\(t.bufferLineCount)|"
            for r in max(0, t.bufferLineCount - rows)..<t.bufferLineCount {
                out += (t.scrollbackLineText(row: r) ?? "") + "\n"
            }
            return out
        }

        if let regs = try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("regressions").path) {
            for entry in regs.sorted() where entry.hasSuffix(".bin") {
                let data = try Data(contentsOf: root.appendingPathComponent("regressions/\(entry)"))
                let bytes = [UInt8](data)
                XCTAssertEqual(snapshot(bytes, cols: 80, rows: 24),
                               snapshot(bytes, cols: 80, rows: 24),
                               "nondeterministic replay: \(entry)")
                replayed += 1
            }
        }
        if let sessions = try? fm.contentsOfDirectory(atPath: root.path) {
            for entry in sessions.sorted() where entry.hasSuffix(".term") {
                let data = try Data(contentsOf: root.appendingPathComponent(entry))
                let log = try SessionReplay.load(data)
                XCTAssertEqual(snapshot(log.allBytes, cols: log.cols, rows: log.rows),
                               snapshot(log.allBytes, cols: log.cols, rows: log.rows),
                               "nondeterministic replay: \(entry)")
                replayed += 1
            }
        }
        XCTAssertGreaterThan(replayed, 30, "corpus went missing — expected 31 regressions + 6 sessions")
    }
}

// MARK: - Search (the FindBar's engine path)

extension CoreEngineTests {
    func testSearchAllFindsPlainCaseAndWrappedHits() {
        let t = CmdyTerminal(cols: 10, rows: 5)
        // "needle" straddles the soft wrap of a 10-col row: "xxxxxxxxne" + "edle..."
        t.feed(Array("xxxxxxxxneedle here\r\nNEEDLE up\r\n".utf8))

        let plain = t.searchAll("needle", spec: .init())
        XCTAssertEqual(plain.count, 2, "case-insensitive should find both")
        XCTAssertEqual(plain.first, TerminalSearchHit(row: 0, col: 8, length: 6),
                       "wrapped hit anchors at the straddle start")

        let sensitive = t.searchAll("NEEDLE", spec: .init(caseSensitive: true))
        XCTAssertEqual(sensitive.count, 1)
        XCTAssertEqual(sensitive.first?.row, 2, "the upper-case hit sits on the row after the wrap pair")

        let rx = t.searchAll("ne+dle", spec: .init(regex: true))
        XCTAssertEqual(rx.count, 2, "regex path finds both spellings")

        XCTAssertTrue(t.searchAll("", spec: .init()).isEmpty)
        XCTAssertTrue(t.searchAll("[invalid", spec: .init(regex: true)).isEmpty,
                      "a bad regex fails soft, not fatally")
    }
}

// MARK: - Attention notifications (OSC 9 / OSC 777)

extension CoreEngineTests {
    private final class NotifyCatcher: CmdyTerminalDelegate {
        var caught: [(String, String)] = []
        func send(_ t: CmdyTerminal, data: ArraySlice<UInt8>) {}
        func setTitle(_ t: CmdyTerminal, title: String) {}
        func setCurrentDirectory(_ t: CmdyTerminal, directory: String?) {}
        func bell(_ t: CmdyTerminal) {}
        func clipboardCopy(_ t: CmdyTerminal, content: Data) {}
        func contentChanged(_ t: CmdyTerminal) {}
        func willReflow(_ t: CmdyTerminal) {}
        func didReflow(_ t: CmdyTerminal) {}
        func notify(_ t: CmdyTerminal, title: String, body: String) {
            caught.append((title, body))
        }
    }

    func testOSCNotificationsReachTheDelegate() {
        let t = CmdyTerminal(cols: 20, rows: 4)
        let catcher = NotifyCatcher()
        t.delegate = catcher

        t.feed(Array("\u{1b}]9;agent needs input\u{7}".utf8))
        t.feed(Array("\u{1b}]777;notify;Claude;waiting for approval\u{1b}\\".utf8))
        t.feed(Array("\u{1b}]777;other;ignored\u{7}".utf8))   // non-notify kind
        t.feed(Array("\u{1b}]9;\u{7}".utf8))                  // empty message
        t.feed(Array("\u{1b}]99;;build done\u{7}".utf8))      // kitty simple form

        XCTAssertEqual(catcher.caught.count, 3)
        XCTAssertEqual(catcher.caught[2].0, "build done")
        XCTAssertEqual(catcher.caught.first?.0, "agent needs input")
        XCTAssertEqual(catcher.caught[1].0, "Claude")
        XCTAssertEqual(catcher.caught[1].1, "waiting for approval")
    }
}
