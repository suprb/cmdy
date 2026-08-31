import XCTest
@testable import CmdyCore

final class CorePlaceholderTests: XCTestCase {
    func testCellBlank() {
        let c = Cell()
        XCTAssertEqual(c.text, "")
        XCTAssertEqual(c.character, " ")
    }

    func testPublishedSnapshotDetachesFromLaterParserWrites() {
        let terminal = CmdyTerminal(cols: 8, rows: 3)
        terminal.feed(text: "abc")
        let first = terminal.captureTerminalSnapshot(extraScreens: 0)
        terminal.feed(text: "\rXYZ")
        let second = terminal.captureTerminalSnapshot(extraScreens: 0)

        XCTAssertEqual(first.line(absolute: 0)?.cells.prefix(3).map(\.text), ["a", "b", "c"])
        XCTAssertEqual(second.line(absolute: 0)?.cells.prefix(3).map(\.text), ["X", "Y", "Z"])
        XCTAssertLessThanOrEqual(first.lines.count, first.grid.rows)
    }

    func testViewportGridReplacementKeepsImmutableCapturedRows() {
        let terminal = CmdyTerminal(cols: 8, rows: 3)
        for index in 0..<12 {
            terminal.feed(text: "line\(index)\r\n")
        }
        terminal.scrollViewport(to: max(0, terminal.currentTopRow - 1))
        let captured = terminal.captureTerminalSnapshot(extraScreens: 1)
        terminal.scrollViewport(lines: -1)
        let replacementGrid = terminal.captureCoreGrid()
        let replaced = captured.projectingViewport(onto: replacementGrid)

        XCTAssertEqual(replaced.grid.displayTopRow, replacementGrid.displayTopRow)
        XCTAssertEqual(replaced.firstLineRow, captured.firstLineRow)
        XCTAssertEqual(replaced.lines.count, captured.lines.count)
        XCTAssertEqual(
            replaced.line(absolute: replacementGrid.displayTopRow)?.cells,
            captured.line(absolute: replacementGrid.displayTopRow)?.cells)
        XCTAssertNil(replaced.dirtyRows)
    }

    func testKittyPlaceholderDecodesIdsAndDiacritics() {
        var decoder = KittyUnicodePlaceholderDecoder()
        let attribute = CellAttribute(fg: .ansi256(42),
                                      underlineColor: .trueColor(1, 2, 3))
        let cell = Cell(scalar: 0x10EEEE,
                        clusterExtras: [0x0305, 0x030D, 0x030E],
                        attribute: attribute)
        let decoded = decoder.decode(cell, absoluteRow: 9, column: 4)

        XCTAssertEqual(decoded, KittyUnicodePlaceholder(
            row: 9, col: 4, imageId: 0x0200002A, placementId: 0x010203,
            placeholderRow: 0, placeholderCol: 1, msb: 2))
    }

    func testKittyPlaceholderInheritsOmittedColumnAndMSB() {
        var decoder = KittyUnicodePlaceholderDecoder()
        let attribute = CellAttribute(fg: .ansi256(42))
        let first = Cell(scalar: 0x10EEEE,
                         clusterExtras: [0x030D, 0x0305, 0x030E],
                         attribute: attribute)
        let next = Cell(scalar: 0x10EEEE, attribute: attribute)

        XCTAssertEqual(decoder.decode(first, absoluteRow: 3, column: 7)?.placeholderCol, 0)
        let inherited = decoder.decode(next, absoluteRow: 3, column: 8)
        XCTAssertEqual(inherited?.placeholderRow, 1)
        XCTAssertEqual(inherited?.placeholderCol, 1)
        XCTAssertEqual(inherited?.msb, 2)
        XCTAssertEqual(inherited?.imageId, 0x0200002A)
    }
}
