import XCTest
@testable import CmdyCore

final class ClusterGeometryReadTests: XCTestCase {
    func testProjectionPreservesDeferredFillAndRetainedRows() {
        let line = Line(cols: 8)
        let retained = line.cells
        let fill = Cell(scalar: 0x1F469, clusterExtras: [0x1F3FD, 0x200D, 0x1F4BB], width: 2)
        line.resetDeferred(fill: fill)
        let version = line.version
        for index in -2...10 {
            let geometry = line.scalarAndWidth(at: index)
            let cell = line[index]
            XCTAssertEqual(geometry.scalar, cell.scalar)
            XCTAssertEqual(geometry.width, cell.width)
        }
        XCTAssertEqual(line.version, version)
        XCTAssertEqual(retained, Array(repeating: Cell(), count: 8))
        XCTAssertEqual(line[0].clusterExtras, fill.clusterExtras)
    }

    func testProjectionTracksPartialWritesWideStubsAndResize() {
        let line = Line(cols: 8, fill: Cell(scalar: 0x4E2D, width: 2))
        line.resetDeferred(fill: Cell(scalar: 0x754C, width: 2))
        line.writeASCII(Array("ab".utf8)[...], at: 2, attribute: .bufferDefault, linkId: 0)
        func check() {
            let version = line.version
            for index in -1...(line.count + 1) {
                let geometry = line.scalarAndWidth(at: index)
                let cell = line[index]
                XCTAssertEqual(geometry.scalar, cell.scalar)
                XCTAssertEqual(geometry.width, cell.width)
            }
            XCTAssertEqual(line.version, version)
        }
        check()
        line[3] = Cell(width: 0)
        check()
        line.resize(to: 3, fill: Cell())
        check()
        line.resize(to: 10, fill: Cell(scalar: 0x2764, width: 1))
        check()
    }
}
