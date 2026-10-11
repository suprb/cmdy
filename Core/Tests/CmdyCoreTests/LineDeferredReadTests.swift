import XCTest
@testable import CmdyCore

final class LineDeferredReadTests: XCTestCase {
    func testDeferredFillReadsPreserveAttributesBoundsAndVersion() {
        let fill = Cell.blank(attribute: CellAttribute(bg: .trueColor(12, 34, 56)))
        let line = Line(cols: 8, fill: Cell(scalar: 120))
        line.resetDeferred(fill: fill)
        let version = line.version

        XCTAssertEqual((0..<line.count).map { line[$0] }, Array(repeating: fill, count: 8))
        for index in [Int.min, -1, line.count, Int.max] {
            XCTAssertEqual(line[index], Cell(), "out-of-range reads keep the default cell")
        }
        XCTAssertEqual(line.version, version)
        XCTAssertEqual(line.cells, Array(repeating: fill, count: 8))
        XCTAssertEqual(line.version, version, "materializing logical contents is not a mutation")

        let empty = Line(cols: 0)
        empty.resetDeferred(fill: fill)
        XCTAssertEqual(empty[0], Cell())
    }

    func testReadsBetweenASCIIWritesPreserveFilledGapsAndWrittenCells() {
        let fill = Cell.blank(attribute: CellAttribute(bg: .ansi256(4)))
        let attribute = CellAttribute(fg: .ansi256(2), style: .bold)
        let line = Line(cols: 10, fill: Cell(scalar: 120))
        line.resetDeferred(fill: fill)
        line.writeASCII(Array("ab".utf8)[...], at: 2, attribute: attribute, linkId: 7)
        let version = line.version

        XCTAssertEqual(line[0], fill)
        XCTAssertEqual(line[2], Cell(scalar: 97, attribute: attribute, linkId: 7))
        XCTAssertEqual(line[9], fill)
        XCTAssertEqual(line.version, version)

        // A following write can extend the populated range; a cursor jump
        // must preserve the logical blanks between separated writes.
        line.writeASCII(Array("cd".utf8)[...], at: 4, attribute: attribute, linkId: 7)
        XCTAssertEqual(line[5], Cell(scalar: 100, attribute: attribute, linkId: 7))
        XCTAssertEqual(line[6], fill)
        line.writeASCII(Array("Y".utf8)[...], at: 8, attribute: attribute, linkId: 7)

        var expected = Array(repeating: fill, count: 10)
        for (offset, byte) in "abcd".utf8.enumerated() {
            expected[offset + 2] = Cell(scalar: UInt32(byte), attribute: attribute, linkId: 7)
        }
        expected[8] = Cell(scalar: 89, attribute: attribute, linkId: 7)
        XCTAssertEqual((0..<line.count).map { line[$0] }, expected)
        XCTAssertEqual(line.cells, expected)
    }

    func testDeferredClusterFillReadsRemainIndependentValues() {
        let fill = Cell(scalar: 101, clusterExtras: [0x0301],
                        attribute: CellAttribute(fg: .ansi256(3)), linkId: 9)
        let line = Line(cols: 4, fill: Cell(scalar: 120))
        line.fill(with: fill)
        let version = line.version
        var read = line[1]
        read.clusterExtras?.append(0x0308)

        XCTAssertEqual(line[1], fill)
        XCTAssertEqual(line[4], Cell())
        XCTAssertEqual(line.version, version)
        line.writeASCII(Array("a".utf8)[...], at: 1, attribute: .bufferDefault, linkId: 0)
        XCTAssertEqual(line.cells, [fill, Cell(scalar: 97), fill, fill])
        XCTAssertEqual(read.clusterExtras, [0x0301, 0x0308])
    }

    func testDeferredReadsAndLaterWritesPreservePublishedSnapshots() {
        let original = Cell(scalar: 120)
        let line = Line(cols: 8, fill: original)
        let first = snapshot(line)
        let firstVersion = first.version
        let fill = Cell.blank(attribute: CellAttribute(bg: .ansi256(5)))
        line.resetDeferred(fill: fill)
        XCTAssertEqual(line[7], fill)
        line.writeASCII(Array("ab".utf8)[...], at: 2, attribute: .bufferDefault, linkId: 0)
        XCTAssertEqual(line[2], Cell(scalar: 97))
        let second = snapshot(line)
        let secondVersion = second.version

        line.resetDeferred(fill: Cell())
        let resetVersion = line.version
        XCTAssertEqual(line[2], Cell())
        XCTAssertEqual(line.version, resetVersion)
        line[6] = Cell(scalar: 81)

        XCTAssertEqual(first.cells, Array(repeating: original, count: 8))
        XCTAssertEqual(first.version, firstVersion)
        XCTAssertEqual(second.cells, [fill, fill, Cell(scalar: 97), Cell(scalar: 98),
                                     fill, fill, fill, fill])
        XCTAssertEqual(second.version, secondVersion)
        XCTAssertEqual(line.cells, [Cell(), Cell(), Cell(), Cell(), Cell(), Cell(),
                                   Cell(scalar: 81), Cell()])
        XCTAssertNotEqual(line.version, resetVersion)
    }

    private func snapshot(_ line: Line) -> CoreLineSnapshot {
        CoreLineSnapshot(cells: line.cells, isWrapped: line.isWrapped,
                         renderMode: line.renderMode, images: [], version: line.version)
    }
}
