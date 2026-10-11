import XCTest
@testable import CmdyCore

final class LineMetadataGenerationTests: XCTestCase {
    private final class WeakImageReference {
        weak var value: LineImage?
        init(_ value: LineImage?) { self.value = value }
    }

    func testPublicMetadataAssignmentsKeepInvalidatingTheRow() {
        let line = Line(cols: 4)
        var version = line.version
        line.isWrapped = true
        XCTAssertGreaterThan(line.version, version)
        version = line.version
        line.isWrapped = true
        XCTAssertGreaterThan(line.version, version)
        version = line.version
        line.renderMode = .doubleWidth
        XCTAssertGreaterThan(line.version, version)
        version = line.version
        line.images = []
        XCTAssertGreaterThan(line.version, version)
        version = line.version
        let image = LineImage(payload: .rgba(bytes: [0, 0, 0, 0], width: 1, height: 1),
                              pixelWidth: 1, pixelHeight: 1, col: 0)
        line.images?.append(image)
        XCTAssertGreaterThan(line.version, version)
        XCTAssertTrue(line.images?.first === image)
        version = line.version
        line.images?.removeAll()
        XCTAssertGreaterThan(line.version, version)
        XCTAssertEqual(line.images?.count, 0)
    }

    func testRecyclingClearsMetadataAndReleasesImageWithoutChangingSnapshot() {
        let terminal = CmdyTerminal(cols: 4, rows: 2)
        terminal.feed(text: "old")
        let line = terminal.buffer.liveLine(0)
        line.isWrapped = true
        line.wrapStyle = .words
        line.renderMode = .doubleWidth
        var image: LineImage? = LineImage(
            payload: .rgba(bytes: [1, 2, 3, 255], width: 1, height: 1),
            pixelWidth: 1, pixelHeight: 1, col: 2)
        let releasedImage = WeakImageReference(image)
        line.images = image.map { [$0] }
        image = nil
        let snapshot = terminal.captureTerminalSnapshot(extraScreens: 0)
        let version = line.version
        let fill = Cell.blank(attribute: CellAttribute(bg: .ansi256(6)))

        line.resetDeferred(fill: fill)

        XCTAssertGreaterThan(line.version, version)
        XCTAssertFalse(line.isWrapped)
        XCTAssertEqual(line.wrapStyle, .cells)
        XCTAssertEqual(line.renderMode, .single)
        XCTAssertNil(line.images)
        XCTAssertNil(releasedImage.value)
        XCTAssertEqual(line[0], fill)
        XCTAssertEqual(line.cells, Array(repeating: fill, count: 4))
        let captured = snapshot.line(absolute: 0)
        XCTAssertEqual(captured?.cells.map(\.scalar), [111, 108, 100, 0])
        XCTAssertEqual(captured?.isWrapped, true)
        XCTAssertEqual(captured?.renderMode, .doubleWidth)
        XCTAssertEqual(captured?.images.first?.col, 2)
        XCTAssertEqual(captured?.version, version)
    }

    func testMetadataResetAndFullOverwriteKeepFreshGlobalGenerations() {
        let first = Line(cols: 4)
        let second = Line(cols: 4)
        first.resetMetadata(isWrapped: true)
        let firstVersion = first.version
        second.resetMetadata(isWrapped: true)
        XCTAssertGreaterThan(second.version, firstVersion)
        XCTAssertTrue(first.isWrapped)
        XCTAssertTrue(second.isWrapped)

        first.resetMetadata(isWrapped: true)
        XCTAssertGreaterThan(first.version, second.version,
                             "recycling identical metadata still needs a fresh row identity")
        let resetVersion = first.version
        let beforeWrite = first.cells
        first.writeASCII(Array("next".utf8)[...], at: 0,
                         attribute: .bufferDefault, linkId: 0)
        XCTAssertGreaterThan(first.version, resetVersion)
        XCTAssertEqual(first.cells.map(\.scalar), [110, 101, 120, 116])
        XCTAssertEqual(beforeWrite, Array(repeating: Cell(), count: 4))
    }
}
