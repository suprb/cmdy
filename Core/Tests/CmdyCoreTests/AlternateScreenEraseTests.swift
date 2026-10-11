import XCTest
@testable import CmdyCore

final class AlternateScreenEraseTests: XCTestCase {
    func testClearAfterThreeMegabyteAlternateOutputLeavesLastLiveRowBlank() {
        for chunk in [1024, 65536] {
            let terminal = CmdyTerminal(cols: 120, rows: 36, scrollback: 10_000)
            terminal.feed(text: "\u{1B}[?1049h")
            let payload = [UInt8](repeating: 65, count: 3_000_000)
            for offset in stride(from: 0, to: payload.count, by: chunk) {
                terminal.feed(payload[offset..<min(payload.count, offset + chunk)])
            }
            let before = terminal.captureTerminalSnapshot()
            terminal.feed(text: "\u{1B}[2J\u{1B}[H")
            let rows = (1...35).map { String(format: "row-%05d", $0) }
            terminal.feed(text: rows.map { $0 + "\r\n" }.joined())
            XCTAssertTrue(terminal.isAlternateBuffer)
            // Alternate storage intentionally retains one predecessor row;
            // only yBase..<yBase+rows belongs to the live screen.
            XCTAssertEqual(terminal.bufferLineCount, 37)
            XCTAssertEqual(terminal.buffer.yBase, 1)
            XCTAssertEqual(terminal.lineForDiff(absolute: 0)!.trimmedText(),
                           String(repeating: "A", count: 120))
            XCTAssertEqual(terminal.cursorRow, 35)
            XCTAssertEqual(terminal.cursorColumn, 0)
            for row in 0..<36 {
                let line = terminal.lineForDiff(absolute: terminal.buffer.yBase + row)!
                XCTAssertEqual(line.trimmedText(), row < 35 ? rows[row] : "", "chunk \(chunk), row \(row)")
                XCTAssertFalse(line.isWrapped)
                if row == 35 { XCTAssertTrue(line.cells.allSatisfy { $0.scalar == 0 }) }
            }
            XCTAssertTrue(before.lines.contains { $0.cells.contains { $0.scalar == 65 } },
                          "the captured pre-erase snapshot must retain its output")
        }
    }
}
