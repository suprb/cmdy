import XCTest
@_spi(CmdyApp) @testable import CmdyCore

final class IdleHistoryMaintenanceTests: XCTestCase {
    private func fill(_ terminal: CmdyTerminal, count: Int) {
        // A non-ASCII scalar forces dense storage; carriage return and the
        // ASCII overwrite restore the exact original line text. This keeps
        // the conversion assertions meaningful when plain rows start compact.
        terminal.feed(text: (0..<count).map { "\u{00E9}\rline-\($0)\r\n" }.joined())
    }

    @discardableResult
    private func finish(_ terminal: CmdyTerminal, startingAt start: Int = 0) -> Int {
        var cursor = start
        var compacted = 0
        for _ in 0..<1000 {
            let result = terminal.compactHistory(startingAt: cursor, maximumRows: 32)
            XCTAssertLessThanOrEqual(result.visited, 32)
            XCTAssertLessThanOrEqual(result.compacted, result.visited)
            compacted += result.compacted
            if result.complete { return compacted }
            XCTAssertGreaterThan(result.nextAbsoluteRow, cursor)
            cursor = result.nextAbsoluteRow
        }
        XCTFail("Bounded history maintenance did not finish")
        return compacted
    }

    func testSwiftBridgeBoundsWorkAndPreservesLiveSnapshotAndHistoryText() {
        let terminal = CmdyTerminal(cols: 80, rows: 4, scrollback: 256)
        fill(terminal, count: 200)
        let live = terminal.captureTerminalSnapshot(extraScreens: 0)
        let expectedCells = live.lines.map(\.cells)
        let expectedVersions = live.lines.map(\.version)
        let zero = terminal.compactHistory(startingAt: 0, maximumRows: -1)
        XCTAssertEqual(zero.visited, 0)
        XCTAssertEqual(zero.compacted, 0)
        XCTAssertFalse(zero.complete)
        let first = terminal.compactHistory(startingAt: 0, maximumRows: Int.max)
        XCTAssertLessThanOrEqual(first.visited, 64)
        XCTAssertGreaterThan(first.compacted, 0)
        XCTAssertGreaterThan(finish(terminal, startingAt: first.nextAbsoluteRow), 0)
        XCTAssertEqual(live.lines.map(\.cells), expectedCells)
        XCTAssertEqual(live.lines.map(\.version), expectedVersions)
        for index in 0..<200 {
            XCTAssertEqual(terminal.scrollbackLineText(row: index), "line-\(index)")
        }
        XCTAssertEqual(terminal.scrollbackLineText(row: 200), "")
        XCTAssertEqual(finish(terminal), 0)
    }

    func testPublishedHistoryRemainsImmutableAfterMaintenanceAndResumedRichOutput() {
        let terminal = CmdyTerminal(cols: 80, rows: 4, scrollback: 256)
        fill(terminal, count: 100)
        terminal.scrollViewport(to: 0)
        let retained = terminal.captureTerminalSnapshot(extraScreens: 1)
        let expectedCells = retained.lines.map(\.cells)
        let expectedVersions = retained.lines.map(\.version)
        terminal.scrollViewport(to: terminal.normalBuffer.yBase)
        XCTAssertGreaterThan(finish(terminal), 0)
        terminal.feed(text: "\u{1b}[31mé🧑‍💻\u{1b}[0m\r\n")
        terminal.resize(cols: 40, rows: 6)
        XCTAssertEqual(retained.lines.map(\.cells), expectedCells)
        XCTAssertEqual(retained.lines.map(\.version), expectedVersions)
        let text = terminal.scrollbackLineTexts(
            rows: 0...(terminal.normalBuffer.lineCount - 1)).joined(separator: "\n")
        XCTAssertTrue(text.contains("é🧑‍💻"))
    }

    func testAlreadyCompactASCIIHistoryNeedsNoConversionAndKeepsSnapshots() {
        let terminal = CmdyTerminal(cols: 80, rows: 4, scrollback: 256)
        terminal.feed(text: (0..<100).map { "line-\($0)\r\n" }.joined())
        let retained = terminal.captureTerminalSnapshot(extraScreens: 1)
        let cells = retained.lines.map(\.cells)
        let versions = retained.lines.map(\.version)
        XCTAssertEqual(finish(terminal), 0)
        XCTAssertEqual(retained.lines.map(\.cells), cells)
        XCTAssertEqual(retained.lines.map(\.version), versions)
        for index in 0..<100 {
            XCTAssertEqual(terminal.scrollbackLineText(row: index), "line-\(index)")
        }
    }

    func testAbsoluteCursorClampsAfterHistoryDropsAndClear() {
        let terminal = CmdyTerminal(cols: 80, rows: 4, scrollback: 16)
        fill(terminal, count: 80)
        XCTAssertGreaterThan(terminal.scrollbackDroppedLines, 0)
        let result = terminal.compactHistory(startingAt: Int.min, maximumRows: 1)
        XCTAssertEqual(result.visited, 1)
        XCTAssertGreaterThan(result.nextAbsoluteRow, terminal.scrollbackDroppedLines)
        let cursor = result.nextAbsoluteRow
        fill(terminal, count: 100)
        XCTAssertGreaterThan(terminal.scrollbackDroppedLines, cursor)
        _ = finish(terminal, startingAt: cursor)
        let beyond = terminal.compactHistory(startingAt: Int.max, maximumRows: 32)
        XCTAssertEqual(beyond.visited, 0)
        XCTAssertTrue(beyond.complete)
        terminal.normalBuffer.clearScrollback()
        let empty = terminal.compactHistory(startingAt: cursor, maximumRows: 32)
        XCTAssertEqual(empty.visited, 0)
        XCTAssertTrue(empty.complete)
    }

    func testNormalHistoryMaintenancePreservesAlternateScreen() {
        let terminal = CmdyTerminal(cols: 80, rows: 4, scrollback: 256)
        fill(terminal, count: 100)
        terminal.feed(text: "\u{1b}[?1049hALT é🧑‍💻")
        let alternate = terminal.captureTerminalSnapshot(extraScreens: 0)
        XCTAssertTrue(alternate.grid.isAlternateBuffer)
        let expected = alternate.lines.map(\.cells)
        XCTAssertGreaterThan(finish(terminal), 0)
        let after = terminal.captureTerminalSnapshot(extraScreens: 0)
        XCTAssertTrue(after.grid.isAlternateBuffer)
        XCTAssertEqual(after.lines.map(\.cells), expected)
        terminal.feed(text: "\u{1b}[?1049l")
        XCTAssertEqual(terminal.scrollbackLineText(row: 0), "line-0")
        XCTAssertEqual(terminal.scrollbackLineText(row: 99), "line-99")
    }
}
