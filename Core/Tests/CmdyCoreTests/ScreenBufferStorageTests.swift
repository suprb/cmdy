import XCTest
@testable import CmdyCore

final class ScreenBufferStorageTests: XCTestCase {
    private final class WeakImageReference {
        weak var value: LineImage?
        init(_ value: LineImage?) { self.value = value }
    }

    func testCappedScrollbackKeepsLogicalRowsAndBoundsDeferredPrefix() {
        let rows = 4
        let scrollback = 32
        let scrollCount = 10_000
        let buffer = ScreenBuffer(cols: 8, rows: rows, hasScrollback: true,
                                  maxScrollback: scrollback)

        for value in 0..<scrollCount {
            buffer.scrollUp(fill: Cell())
            write("L\(value)", to: buffer.liveLine(rows - 1))
        }

        XCTAssertEqual(buffer.lineCount, rows + scrollback)
        XCTAssertEqual(buffer.lines.count, buffer.lineCount)
        XCTAssertEqual(buffer.yBase, scrollback)
        XCTAssertEqual(buffer.yDisp, scrollback)
        XCTAssertEqual(buffer.droppedLines, scrollCount - scrollback)

        let firstRetainedValue = scrollCount - rows - scrollback
        let retainedLines = buffer.lines
        for row in 0..<buffer.lineCount {
            let expected = "L\(firstRetainedValue + row)"
            XCTAssertEqual(buffer.line(absolute: row)?.trimmedText(), expected,
                           "logical row \(row) changed across prefix trims")
            XCTAssertTrue(retainedLines[row] === buffer.line(absolute: row),
                          "the public snapshot must preserve logical indexing")
        }

        // Compaction happens once the dead prefix reaches max(64, live rows).
        // Between compactions, no more than that many dead slots may remain.
        XCTAssertLessThan(buffer.deferredTrimmedLineCount, max(64, buffer.lineCount))
        XCTAssertLessThan(buffer.backingLineSlotCount,
                          buffer.lineCount + max(64, buffer.lineCount))
    }

    func testClearScrollbackAfterDeferredTrimsKeepsLiveScreen() {
        let rows = 3
        let buffer = ScreenBuffer(cols: 8, rows: rows, hasScrollback: true,
                                  maxScrollback: 5)

        for value in 0..<80 {
            buffer.scrollUp(fill: Cell())
            write("L\(value)", to: buffer.liveLine(rows - 1))
        }
        let liveBefore = (0..<rows).map { buffer.liveLine($0).trimmedText() }
        let droppedBeforeClear = buffer.droppedLines

        buffer.clearScrollback()

        XCTAssertEqual(buffer.lineCount, rows)
        XCTAssertEqual(buffer.yBase, 0)
        XCTAssertEqual(buffer.yDisp, 0)
        XCTAssertEqual(buffer.droppedLines, droppedBeforeClear + 5)
        XCTAssertEqual((0..<rows).map { buffer.liveLine($0).trimmedText() }, liveBefore)
    }

    func testRetainedRowOriginStabilizesSurvivingLineAcrossCapTrim() {
        let buffer = ScreenBuffer(cols: 8, rows: 3, hasScrollback: true,
                                  maxScrollback: 2)
        for value in 0..<3 {
            buffer.scrollUp(fill: Cell())
            write("L\(value)", to: buffer.liveLine(2))
        }

        let survivingLine = buffer.line(absolute: 1)
        let stableRowBefore = buffer.droppedLines + 1
        let originBefore = buffer.droppedLines

        buffer.scrollUp(fill: Cell())
        write("next", to: buffer.liveLine(2))

        XCTAssertEqual(buffer.droppedLines, originBefore + 1)
        XCTAssertTrue(buffer.line(absolute: 0) === survivingLine)
        XCTAssertEqual(buffer.droppedLines, stableRowBefore,
                       "origin + rebased local row must stay stable")

        let terminal = CmdyTerminal(cols: 8, rows: 3, scrollback: 2)
        for value in 0..<20 { terminal.feed(text: "L\(value)\r\n") }
        XCTAssertGreaterThan(terminal.scrollbackDroppedLines, 0)
        XCTAssertEqual(terminal.captureCoreGrid().retainedRowOrigin,
                       terminal.scrollbackDroppedLines)
    }

    func testTrimReleasesDroppedLinePayloadBeforePrefixCompaction() {
        let buffer = ScreenBuffer(cols: 212, rows: 2, hasScrollback: true,
                                  maxScrollback: 1)
        buffer.scrollUp(fill: Cell())       // Fill the three-row capacity.

        var image: LineImage? = LineImage(
            payload: .rgba(bytes: [0, 0, 0, 0], width: 1, height: 1),
            pixelWidth: 1, pixelHeight: 1, col: 0)
        buffer.line(absolute: 0)?.images = image.map { [$0] }
        let droppedPayload = WeakImageReference(image)
        XCTAssertNotNil(droppedPayload.value)
        image = nil

        buffer.scrollUp(fill: Cell())       // Trim one row, but do not compact.

        XCTAssertGreaterThan(buffer.deferredTrimmedLineCount, 0)
        XCTAssertNil(droppedPayload.value,
                     "a recycled/deferred row must release its dropped image payload")
        XCTAssertEqual(buffer.lineCount, 3)
    }

    func testDeferredClearPreservesSequentialAndDisjointASCIIWrites() {
        let line = Line(cols: 8, fill: Cell(scalar: UInt32(UInt8(ascii: "x"))))
        line.resetDeferred(fill: Cell())
        let first = Array("ab".utf8)
        let second = Array("cd".utf8)
        line.writeASCII(first[...], at: 0, attribute: .bufferDefault, linkId: 0)
        line.writeASCII(second[...], at: 2, attribute: .bufferDefault, linkId: 0)
        XCTAssertEqual(line.cells.map(\.scalar), [97, 98, 99, 100, 0, 0, 0, 0])

        line.resetDeferred(fill: Cell())
        let tail = Array("YZ".utf8)
        line.writeASCII(first[...], at: 0, attribute: .bufferDefault, linkId: 0)
        line.writeASCII(tail[...], at: 5, attribute: .bufferDefault, linkId: 0)
        XCTAssertEqual(line.cells.map(\.scalar), [97, 98, 0, 0, 0, 89, 90, 0])
    }

    private func write(_ text: String, to line: Line) {
        line.fill(with: Cell())
        for (column, scalar) in text.unicodeScalars.prefix(line.count).enumerated() {
            line[column] = Cell(scalar: scalar.value, width: 1)
        }
    }
}
