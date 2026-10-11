import XCTest
import CmdyNative
@_spi(CmdyApp) @testable import CmdyCore

final class NativePublicationOwnershipTests: XCTestCase {
    private func withLine<T>(_ terminal: CmdyTerminal, row: Int,
                             _ body: (OpaquePointer) throws -> T) rethrows -> T {
        let line = cmdy_zig_buffer_line(terminal.normalBuffer.native, row)!
        defer { cmdy_zig_line_release(line) }
        return try body(line)
    }

    func testInternalPublicationDoesNotInstallPublicLineIdentity() {
        let terminal = CmdyTerminal(cols: 80, rows: 4)
        terminal.feed(text: "published é🧑‍💻")
        withLine(terminal, row: 0) { XCTAssertNil(cmdy_zig_line_swift_context($0)) }
        let first = terminal.captureTerminalSnapshot(extraScreens: 0)
        withLine(terminal, row: 0) { XCTAssertNil(cmdy_zig_line_swift_context($0)) }
        XCTAssertEqual(first.lines[0].cells[0].scalar, 112)
        let exposed = terminal.normalBuffer.liveLine(0)
        withLine(terminal, row: 0) { XCTAssertNotNil(cmdy_zig_line_swift_context($0)) }
        let second = terminal.captureTerminalSnapshot(extraScreens: 0)
        XCTAssertTrue(terminal.normalBuffer.liveLine(0) === exposed)
        XCTAssertEqual(second.lines[0].cells, first.lines[0].cells)
        XCTAssertEqual(second.lines[0].version, exposed.version)
    }

    func testReleasedPublicationAllowsPreviouslyVisibleHistoryToCompact() {
        let terminal = CmdyTerminal(cols: 80, rows: 4)
        terminal.feed(text: "retained first\r\n")
        // Deferred blank tails produce independent snapshots. Materialize the
        // source first so this fixture actually exercises shared row storage.
        withLine(terminal, row: 0) { XCTAssertEqual(cmdy_zig_line_prepare_read($0), 0) }
        var held: CoreTerminalSnapshot? = terminal.captureTerminalSnapshot(extraScreens: 0)
        terminal.feed(text: (0..<200).map { "later-\($0)\r\n" }.joined())
        withLine(terminal, row: 0) { XCTAssertNil(cmdy_zig_line_swift_context($0)) }
        withExtendedLifetime(held) {
            let protected = terminal.compactHistory(startingAt: 0, maximumRows: 1)
            XCTAssertEqual(protected.visited, 1)
            XCTAssertEqual(protected.compacted, 0, "published storage is still shared")
        }
        held = nil
        withLine(terminal, row: 0) { line in
            XCTAssertEqual(cmdy_zig_line_prepare_read(line), 0)
            var count = 0
            XCTAssertNotNil(cmdy_zig_line_cells(line, &count))
        }
        let released = terminal.compactHistory(startingAt: 0, maximumRows: 1)
        XCTAssertEqual(released.compacted, 1)
        withLine(terminal, row: 0) { line in
            var count = 0
            XCTAssertNil(cmdy_zig_line_cells(line, &count))
        }
        XCTAssertEqual(terminal.scrollbackLineText(row: 0), "retained first")
    }
}
