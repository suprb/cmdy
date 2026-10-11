import XCTest
@testable import CmdyCore

final class ASCIILineInitializationTests: XCTestCase {
    private let textAttribute = CellAttribute(
        fg: .trueColor(7, 8, 9), bg: .ansi256(6), style: [.bold, .italic],
        underlineKind: .curly, underlineColor: .trueColor(10, 11, 12))

    func testASCIIRowInitializersPreserveTextAndEveryFillField() {
        let fillAttribute = CellAttribute(fg: .defaultInverted, bg: .trueColor(1, 2, 3),
                                          style: [.inverse, .underline],
                                          underlineKind: .double, underlineColor: .ansi256(5))
        let fills = [Cell(), Cell(scalar: 0x754C, width: 2, attribute: fillAttribute, linkId: 29),
                     Cell(scalar: 0, width: 0, attribute: fillAttribute, linkId: 29),
                     Cell(scalar: 101, clusterExtras: [], attribute: fillAttribute, linkId: 29),
                     Cell(scalar: 101, clusterExtras: [0x301, 0x308], attribute: fillAttribute, linkId: 29)]
        for columns in [0, 1, 17, 120, 212] {
            for count in Set([0, min(1, columns), min(7, columns), columns]) {
                let textBytes: [UInt8] = (0..<count).map { UInt8(32 + $0 % 95) }
                var storage = [UInt8](repeating: 0, count: 3)
                storage.append(contentsOf: textBytes)
                storage.append(0)
                let bytes = storage[3..<(3 + count)]
                let expectedText = bytes.map { Cell(scalar: UInt32($0), attribute: textAttribute, linkId: 17) }
                let full = Line(fullASCII: bytes, attribute: textAttribute, linkId: 17, isWrapped: true)
                XCTAssertEqual(full.cells, expectedText)
                XCTAssertEqual(full.count, count)
                XCTAssertTrue(full.isWrapped)
                for fill in fills {
                    let line = Line(ascii: bytes, cols: columns, fill: fill,
                                    attribute: textAttribute, linkId: 17, isWrapped: false)
                    let expected = expectedText + Array(repeating: fill, count: columns - count)
                    let version = line.version
                    XCTAssertEqual(line.cells, expected)
                    XCTAssertEqual((0..<line.count).map { line[$0] }, expected)
                    XCTAssertEqual(line.version, version)
                    XCTAssertFalse(line.isWrapped)
                }
            }
        }
    }

    func testClusterTailOverwriteDetachesSnapshotAndReleasesOnlyReplacedExtras() {
        let fill = Cell(scalar: 101, clusterExtras: [0x301],
                        attribute: CellAttribute(bg: .ansi256(4)), linkId: 12)
        let line = Line(ascii: Array("AB".utf8)[...], cols: 7, fill: fill,
                        attribute: textAttribute, linkId: 17, isWrapped: true)
        let snapshot = CoreLineSnapshot(cells: line.cells, isWrapped: line.isWrapped,
                                        renderMode: line.renderMode, images: [], version: line.version)
        let savedCells = snapshot.cells
        let savedVersion = snapshot.version
        line.writeASCII(Array("xy".utf8)[...], at: 2, attribute: .bufferDefault, linkId: 0)
        XCTAssertEqual(line[2], Cell(scalar: 120))
        XCTAssertEqual(line[3], Cell(scalar: 121))
        XCTAssertEqual(line[4], fill)
        var copiedFill = line[4]
        copiedFill.clusterExtras?.append(0x308)
        XCTAssertEqual(line[4], fill)
        XCTAssertEqual(copiedFill.clusterExtras, [0x301, 0x308])
        XCTAssertNotEqual(line.version, savedVersion)
        XCTAssertEqual(snapshot.cells, savedCells)
        XCTAssertEqual(snapshot.version, savedVersion)
        XCTAssertEqual(snapshot.cells[2], fill)
        line.resetDeferred(fill: Cell())
        line.writeASCII(Array("recycle".utf8)[...], at: 0, attribute: .bufferDefault, linkId: 0)
        XCTAssertEqual(line.cells.map(\.scalar), Array("recycle".utf8).map(UInt32.init))
        XCTAssertTrue(line.cells.allSatisfy { $0.clusterExtras == nil })
        XCTAssertEqual(snapshot.cells, savedCells)
    }

    func testFilledScrollbackMixedASCIIAndClustersMatchesScalarOracle() {
        let prefill = (0..<80).map { "seed\($0) e\u{301} 界\r\n" }.joined()
        let payload = Array(("\u{1B}[31;44m" + String(repeating: "abcdefg\r\n", count: 35)
            + "e\u{301}😀\rREPLACE\u{1B}[K\r\n"
            + String(repeating: "AB界e\u{308}\r\n", count: 30)
            + "\u{1B}[0m" + String(repeating: "1234567\r\n", count: 30)).utf8)
        for columns in [7, 17, 120] {
            let expected = CmdyTerminal(cols: columns, rows: 4, scrollback: 9)
            expected.parser.coalescesPrintableASCII = false
            expected.feed(text: prefill)
            expected.feed(payload[...])
            for chunk in [1, 7, 78, 1024, payload.count] {
                let actual = CmdyTerminal(cols: columns, rows: 4, scrollback: 9)
                actual.feed(text: prefill)
                XCTAssertGreaterThan(actual.scrollbackDroppedLines, 0)
                for offset in stride(from: 0, to: payload.count, by: chunk) {
                    actual.feed(payload[offset..<min(payload.count, offset + chunk)])
                }
                XCTAssertEqual(actual.bufferLineCount, expected.bufferLineCount)
                XCTAssertEqual(actual.scrollbackDroppedLines, expected.scrollbackDroppedLines)
                XCTAssertEqual(actual.cursorColumn, expected.cursorColumn)
                XCTAssertEqual(actual.scrollInvariantCursorRow, expected.scrollInvariantCursorRow)
                XCTAssertEqual(actual.currentAttribute, expected.currentAttribute)
                for row in 0..<actual.bufferLineCount {
                    let a = actual.lineForDiff(absolute: row)!
                    let b = expected.lineForDiff(absolute: row)!
                    XCTAssertEqual(a.cells, b.cells, "cols \(columns), chunk \(chunk), row \(row)")
                    XCTAssertEqual(a.isWrapped, b.isWrapped)
                }
            }
        }
    }
}
