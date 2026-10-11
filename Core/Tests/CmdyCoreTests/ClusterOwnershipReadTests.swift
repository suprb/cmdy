import XCTest
@testable import CmdyCore

final class ClusterOwnershipReadTests: XCTestCase {
    func testCombiningFindsLeadingCellBehindContinuationAfterCarriageReturn() {
        for coalesced in [false, true] {
            let terminal = CmdyTerminal(cols: 6, rows: 2)
            terminal.parser.coalescesPrintableASCII = coalesced
            terminal.feed(text: "\u{1B}[31mX界")
            let line = terminal.buffer.liveLine(0)
            let lead = line[1]
            // A cell edit moves the same semantic owner left, leaving the
            // recorded last-write coordinate on its wide continuation.
            line[0] = lead
            line[1] = Cell(width: 0, attribute: lead.attribute)
            line[2] = Cell()

            terminal.feed(text: "\r\u{0301}")

            XCTAssertEqual(line[0], Cell(scalar: lead.scalar, clusterExtras: [0x0301],
                                        width: 2, attribute: lead.attribute))
            XCTAssertEqual(line[1].width, 0)
            XCTAssertNil(line[1].clusterExtras)
            XCTAssertEqual(terminal.cursorColumn, 0)
        }
    }

    func testCombiningRejectsContinuationWithoutMatchingLeadingScalar() {
        let terminal = CmdyTerminal(cols: 6, rows: 2)
        terminal.feed(text: "X界")
        let line = terminal.buffer.liveLine(0)
        line[0] = Cell(scalar: 0x4E2D, width: 2)
        line[1] = Cell(width: 0)
        line[2] = Cell()
        terminal.feed(text: "\r\u{0301}")
        XCTAssertEqual(line[0], Cell(scalar: 0x4E2D, width: 2))
        XCTAssertEqual(line[1], Cell(width: 0))

        let zero = CmdyTerminal(cols: 3, rows: 1)
        zero.feed(text: "A")
        zero.buffer.liveLine(0)[0] = Cell(width: 0)
        zero.feed(text: "\r\u{0301}")
        XCTAssertEqual(zero.buffer.liveLine(0)[0], Cell(width: 0))
    }
}
