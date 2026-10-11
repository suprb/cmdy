import Foundation
import XCTest
import CmdyNative
@_spi(CmdyApp) @testable import CmdyCore

final class NativePublishedSnapshotTests: XCTestCase {
    func testSnapshotPublicationAndValueConstructionDoNotConsumeMutationVersions() {
        let terminal = CmdyTerminal(cols: 8, rows: 3)
        terminal.feed(text: "e\u{301}")
        let line = terminal.buffer.liveLine(0)
        let before = line.version
        let published = terminal.captureTerminalSnapshot(consumeDamage: false)
        let value = CoreLineSnapshot(cells: published.lines[0].cells, isWrapped: false,
                                     renderMode: .single, images: [], version: 0)
        XCTAssertEqual(line.version, before)
        XCTAssertEqual(value.version, 0)
        XCTAssertEqual(value.cells, published.lines[0].cells)
        value.withNativeLine { XCTAssertEqual(cmdy_zig_line_version(OpaquePointer($0)), 0) }
        terminal.feed(text: "\u{308}")
        XCTAssertEqual(line.version, before + 1)
        XCTAssertEqual(published.lines[0].cells[0].clusterExtras, [0x301])
    }

    func testPublishedRowsKeepCellsAndExtrasAfterOwnerMutatesAndDies() {
        var terminal: CmdyTerminal? = CmdyTerminal(cols: 12, rows: 3)
        terminal!.feed(text: "e\u{301}🧑‍💻!")
        let snapshot = terminal!.captureTerminalSnapshot(extraScreens: 0)
        let row = snapshot.lines[0]
        let expected = row.cells
        let version = row.version
        terminal!.feed(text: "\u{1b}[2Jreplacement")
        terminal!.resize(cols: 4, rows: 1)
        terminal = nil
        XCTAssertEqual(row.cells, expected)
        XCTAssertEqual(row.version, version)
        row.withNativeLine { raw in
            let native = OpaquePointer(raw)
            XCTAssertEqual(cmdy_zig_line_count(native), 12)
            var cell = CmdyZigCell(), extras: UnsafePointer<UInt32>?, count = 0, present: UInt8 = 0
            XCTAssertEqual(cmdy_zig_line_read(native, 0, &cell, &extras, &count, &present), 0)
            XCTAssertEqual(cell.scalar, 101)
            XCTAssertEqual(Array(UnsafeBufferPointer(start: extras, count: count)), [0x301])
        }
    }

    func testPublicValueInitializerFreezesNilEmptyAndOwnedClusters() {
        var cells = [Cell(scalar: 65), Cell(scalar: 66, clusterExtras: []),
                     Cell(scalar: 101, clusterExtras: [0x301, 0x302], width: 2), Cell(scalar: 0, width: 0)]
        let expected = cells
        let snapshot = CoreLineSnapshot(cells: cells, isWrapped: true, renderMode: .doubleWidth,
                                        images: [], version: 99)
        cells[2].clusterExtras = [0x303]
        XCTAssertEqual(snapshot.cells, expected)
        XCTAssertEqual(snapshot.nativeCellCount, 4)
        XCTAssertTrue(snapshot.isWrapped)
        XCTAssertEqual(snapshot.renderMode, .doubleWidth)
        XCTAssertEqual(snapshot.version, 99)
    }

    func testConcurrentReadPublicationUsesImmutableNativeRows() {
        let terminal = CmdyTerminal(cols: 80, rows: 4)
        terminal.feed(text: String(repeating: "😀é ", count: 50))
        let rows = terminal.captureTerminalSnapshot().lines
        let expected = rows.map(\.cells)
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            for (row, cells) in zip(rows, expected) { XCTAssertEqual(row.cells, cells) }
        }
    }
}
