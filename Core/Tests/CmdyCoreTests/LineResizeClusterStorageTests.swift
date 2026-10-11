import XCTest
@testable import CmdyCore

final class LineResizeClusterStorageTests: XCTestCase {
    private let extrasCases: [[UInt32]] = [[], [0x0301, 0x0308]]
    private let fillAttribute = CellAttribute(
        fg: .trueColor(10, 20, 30), bg: .ansi256(4), style: .italic,
        underlineKind: .curly, underlineColor: .ansi256(7))
    private let writeAttribute = CellAttribute(
        fg: .ansi256(2), bg: .trueColor(80, 90, 100), style: .bold)

    func testASCIIClearsResizeFillExtrasWithoutChangingRetainedValues() {
        for extras in extrasCases {
            let original = Cell(scalar: 120)
            let fill = Cell(scalar: 101, clusterExtras: extras,
                            attribute: fillAttribute, linkId: 19)
            let line = Line(cols: 2, fill: original)
            let beforeGrowth = snapshot(line)
            line.resize(to: 4, fill: fill)
            let afterGrowth = snapshot(line)
            let retainedCell = line[2]
            let retainedExtras = line[2].clusterExtras
            let version = line.version

            line.writeASCII(Array("AB".utf8)[...], at: 2,
                            attribute: writeAttribute, linkId: 7)

            XCTAssertEqual(line.cells, [original, original,
                Cell(scalar: 65, attribute: writeAttribute, linkId: 7),
                Cell(scalar: 66, attribute: writeAttribute, linkId: 7)])
            XCTAssertNil(line[2].clusterExtras)
            XCTAssertNil(line[3].clusterExtras)
            XCTAssertNotEqual(line.version, version)
            XCTAssertEqual(beforeGrowth.cells, [original, original])
            XCTAssertEqual(afterGrowth.cells, [original, original, fill, fill])
            XCTAssertEqual(retainedCell, fill)
            XCTAssertEqual(retainedExtras, extras)
            XCTAssertEqual(fill.clusterExtras, extras)
        }
    }

    func testOrdinaryUnicodeClearsResizeFillExtrasAndKeepsWideStubGeometry() {
        for extras in extrasCases {
            let original = Cell(scalar: 120)
            let fill = Cell(scalar: 101, clusterExtras: extras,
                            attribute: fillAttribute, linkId: 19)
            let line = Line(cols: 1, fill: original)
            line.resize(to: 4, fill: fill)
            let retained = snapshot(line)
            let retainedCell = line[3]
            let values = [OrdinaryUnicodeCell(scalar: 0x754C, width: 2),
                          OrdinaryUnicodeCell(scalar: 0x00E9, width: 1)]
            let stubAttribute = CmdyTerminal.stubAttribute
            let version = line.version

            values.withUnsafeBufferPointer {
                line.writeOrdinaryUnicode($0, at: 1, columns: 3,
                    attribute: writeAttribute, linkId: 7,
                    eraseAttribute: .bufferDefault, stubAttribute: stubAttribute)
            }

            XCTAssertEqual(line.cells, [original,
                Cell(scalar: 0x754C, width: 2, attribute: writeAttribute, linkId: 7),
                Cell(scalar: 0, width: 0, attribute: stubAttribute),
                Cell(scalar: 0x00E9, width: 1, attribute: writeAttribute, linkId: 7)])
            XCTAssertNil(line[1].clusterExtras)
            XCTAssertNil(line[2].clusterExtras)
            XCTAssertNil(line[3].clusterExtras)
            XCTAssertNotEqual(line.version, version)
            XCTAssertEqual(retained.cells, [original, fill, fill, fill])
            XCTAssertEqual(retainedCell, fill)
        }
    }

    func testDeferredResetAfterGrowthCannotExposeOldExtrasThroughPartialWrite() {
        for extras in extrasCases {
            let fill = Cell(scalar: 101, clusterExtras: extras,
                            attribute: fillAttribute, linkId: 19)
            let line = Line(cols: 1, fill: Cell(scalar: 120))
            line.resize(to: 4, fill: fill)
            let retained = snapshot(line)
            let resetFill = Cell.blank(attribute: CellAttribute(bg: .ansi256(5)))

            line.resetDeferred(fill: resetFill, isWrapped: true)
            let resetVersion = line.version
            // Individual reads preserve the deferred path. A full cells read
            // here would materialize the baseline bug away before the write.
            XCTAssertEqual(line[0], resetFill)
            XCTAssertEqual(line[2], resetFill)
            XCTAssertEqual(line.version, resetVersion)
            line.writeASCII(Array("Q".utf8)[...], at: 2,
                            attribute: writeAttribute, linkId: 7)

            XCTAssertEqual(line[2], Cell(scalar: 81,
                attribute: writeAttribute, linkId: 7))
            XCTAssertNil(line[2].clusterExtras)
            XCTAssertEqual(line.cells, [resetFill, resetFill,
                Cell(scalar: 81, attribute: writeAttribute, linkId: 7), resetFill])
            XCTAssertTrue(line.isWrapped)
            XCTAssertNotEqual(line.version, resetVersion)
            XCTAssertEqual(retained.cells, [Cell(scalar: 120), fill, fill, fill])
        }
    }

    func testShrinkThenNilFillGrowthKeepsExistingClusterStorageConservative() {
        for extras in extrasCases {
            let fill = Cell(scalar: 101, clusterExtras: extras,
                            attribute: fillAttribute, linkId: 19)
            let line = Line(cols: 4, fill: fill)
            let retained = snapshot(line)
            line.resize(to: 2, fill: Cell())
            line.resize(to: 4, fill: Cell())
            // A nil appended fill must not clear knowledge of retained cells.
            line.writeASCII(Array("Z".utf8)[...], at: 1,
                            attribute: writeAttribute, linkId: 7)

            XCTAssertEqual(line.cells, [fill,
                Cell(scalar: 90, attribute: writeAttribute, linkId: 7), Cell(), Cell()])
            XCTAssertNil(line[1].clusterExtras)
            XCTAssertEqual(line[0].clusterExtras, extras)
            XCTAssertEqual(retained.cells, Array(repeating: fill, count: 4))
        }
    }

    func testUnusedResizeFillAndShrinkToEmptyKeepPublicValuesUnchanged() {
        for extras in extrasCases {
            let ignoredFill = Cell(scalar: 101, clusterExtras: extras,
                                   attribute: fillAttribute, linkId: 19)
            let original = Cell(scalar: 120)
            let line = Line(cols: 4, fill: original)
            let retained = snapshot(line)
            line.resize(to: 4, fill: ignoredFill)
            XCTAssertEqual(line.cells, Array(repeating: original, count: 4))
            line.resize(to: 2, fill: ignoredFill)
            XCTAssertEqual(line.cells, [original, original])
            line.resize(to: 0, fill: ignoredFill)
            XCTAssertEqual(line.cells, [])
            line.resize(to: 3, fill: Cell())
            line.writeASCII(Array("abc".utf8)[...], at: 0,
                            attribute: writeAttribute, linkId: 7)
            XCTAssertEqual(line.cells, "abc".utf8.map {
                Cell(scalar: UInt32($0), attribute: writeAttribute, linkId: 7)
            })
            XCTAssertEqual(retained.cells, Array(repeating: original, count: 4))
        }
    }

    private func snapshot(_ line: Line) -> CoreLineSnapshot {
        CoreLineSnapshot(cells: line.cells, isWrapped: line.isWrapped,
                         renderMode: line.renderMode, images: [], version: line.version)
    }
}
