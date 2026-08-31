import XCTest
@testable import CmdyCore

/// Damage spans are performance contracts for the row-texture cache. Cell
/// versions remain the correctness fallback, but ordinary scrolling must not
/// label every retained row dirty.
final class CoreDamageTrackingTests: XCTestCase {
    private func terminalAtBottom() -> CmdyTerminal {
        let terminal = CmdyTerminal(cols: 8, rows: 4, scrollback: 64)
        terminal.feed(text: "a\r\nb\r\nc\r\nd")
        XCTAssertEqual(terminal.liveScreenTopRow, 0)
        XCTAssertEqual(terminal.scrollInvariantCursorRow, 3)
        _ = terminal.consumeDirtyRows()
        return terminal
    }

    func testBottomCRLFDamagesOnlyTheExposedEdge() {
        let terminal = terminalAtBottom()
        let oldBottom = terminal.liveScreenTopRow + terminal.rows - 1

        terminal.feed(text: "\r\n")

        XCTAssertEqual(terminal.liveScreenTopRow, 1)
        XCTAssertEqual(terminal.consumeDirtyRows(), oldBottom...(oldBottom + 1))
    }

    func testRepeatedBottomCRLFNeverDamagesAWholeViewport() throws {
        let terminal = terminalAtBottom()

        for step in 1...20 {
            let oldBottom = terminal.liveScreenTopRow + terminal.rows - 1
            terminal.feed(text: "\r\n")

            let damage = try XCTUnwrap(terminal.consumeDirtyRows())
            XCTAssertEqual(terminal.liveScreenTopRow, step)
            XCTAssertEqual(damage, oldBottom...(oldBottom + 1), "step \(step)")
            XCTAssertLessThan(damage.count, terminal.rows, "step \(step)")
        }
    }

    func testFullDisplayEraseStillDamagesTheWholeViewport() {
        let terminal = terminalAtBottom()

        terminal.feed(text: "\u{1b}[2J")

        let top = terminal.currentTopRow
        XCTAssertEqual(terminal.consumeDirtyRows(), top...(top + terminal.rows - 1))
    }
}
