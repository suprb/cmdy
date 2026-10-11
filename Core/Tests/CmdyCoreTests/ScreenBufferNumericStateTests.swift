import Foundation
import XCTest
import CmdyCore

final class ScreenBufferNumericStateTests: XCTestCase {
    private final class ReleaseState {
        var count = 0
        var observations: [[Int]] = []
        weak var buffer: ScreenBuffer?
    }

    // Public import deliberately exercises client key paths and writeback.
    func testPublicKeyPathsAndInoutDriveRegionScrollAndResize() {
        let buffer = ScreenBuffer(cols: 8, rows: 4, hasScrollback: false)
        for row in 0..<4 {
            buffer.liveLine(row)[0] = Cell(scalar: UInt32(65 + row), width: 1)
        }
        let top: ReferenceWritableKeyPath<ScreenBuffer, Int> = \.scrollTop
        let bottom: ReferenceWritableKeyPath<ScreenBuffer, Int> = \.scrollBottom
        buffer[keyPath: top] = 1
        buffer[keyPath: bottom] = 2
        func add(_ delta: Int, to value: inout Int) { value += delta }
        add(3, to: &buffer.x)
        add(1, to: &buffer.y)
        buffer[keyPath: \.wrapPending] = true
        buffer.scrollUp(fill: Cell())
        XCTAssertEqual((0..<4).map { buffer.liveLine($0).trimmedText() }, ["A", "C", "", "D"])
        XCTAssertEqual(buffer.x, 3)
        XCTAssertEqual(buffer.y, 1)
        XCTAssertTrue(buffer.wrapPending)
        buffer.resizeSimple(newCols: 10, newRows: 5, fill: Cell())
        XCTAssertEqual(buffer.cols, 10)
        XCTAssertEqual(buffer.rows, 5)
        XCTAssertEqual(buffer.scrollTop, 0)
        XCTAssertEqual(buffer.scrollBottom, 4)
        XCTAssertEqual(buffer.liveLine(3).trimmedText(), "D")
    }

    func testThrowingInoutWritesBackBeforeFollowingBufferOperation() {
        enum Expected: Error { case stop }
        let buffer = ScreenBuffer(cols: 8, rows: 3, hasScrollback: true, maxScrollback: 1)
        func update(_ value: inout Int) throws { value = 2; throw Expected.stop }
        XCTAssertThrowsError(try update(&buffer.y))
        XCTAssertEqual(buffer.y, 2)
        buffer.liveLine(buffer.y)[buffer.x] = Cell(scalar: 90, width: 1)
        XCTAssertEqual(buffer.liveLine(2).trimmedText(), "Z")
        buffer.resizeSimple(newCols: 8, newRows: 2, fill: Cell())
        XCTAssertEqual(buffer.y, 1)
        XCTAssertEqual(buffer.liveLine(1).trimmedText(), "Z")
    }

    func testRecycledImageDeallocatorObservesAndChangesLiveCoordinates() {
        let buffer = ScreenBuffer(cols: 8, rows: 2, hasScrollback: true, maxScrollback: 0)
        let state = ReleaseState()
        state.buffer = buffer
        attachImage(to: buffer.liveLine(0)) { [state] in
            state.count += 1
            guard let b = state.buffer else { return XCTFail("buffer expired inside scroll") }
            state.observations.append([b.cols, b.rows, b.lineCount, b.droppedLines, b.yBase, b.yDisp])
            b.x = 5
            b.y = 1
            b.marginLeft = 2
            b.wrapPending = true
        }
        XCTAssertEqual(state.count, 0)
        buffer.scrollUp(fill: Cell())
        XCTAssertEqual(state.count, 1)
        // The recycled slot has departed, but the replacement and dropped-row
        // accounting are published after releasing its image, as before.
        XCTAssertEqual(state.observations, [[8, 2, 1, 0, 0, 0]])
        XCTAssertEqual(buffer.lineCount, 2)
        XCTAssertEqual(buffer.droppedLines, 1)
        XCTAssertEqual(buffer.x, 5)
        XCTAssertEqual(buffer.y, 1)
        XCTAssertEqual(buffer.marginLeft, 2)
        XCTAssertTrue(buffer.wrapPending)
    }

    func testRetainedRowsAndImagePayloadOutliveBuffer() {
        let state = ReleaseState()
        var retained: [Line]? = nil
        autoreleasepool {
            var buffer: ScreenBuffer? = ScreenBuffer(cols: 8, rows: 2, hasScrollback: true)
            state.buffer = buffer
            attachImage(to: buffer!.liveLine(0)) { [state] in state.count += 1 }
            buffer!.liveLine(0)[0] = Cell(scalar: 81, width: 1)
            retained = buffer!.lines
            buffer = nil
        }
        XCTAssertNil(state.buffer)
        XCTAssertEqual(state.count, 0)
        XCTAssertEqual(retained?.first?.trimmedText(), "Q")
        retained = nil
        XCTAssertEqual(state.count, 1)
    }

    func testBufferDestructionReleasesEveryImageAndAllowsFreshBufferInDeallocator() {
        let state = ReleaseState()
        autoreleasepool {
            let buffer = ScreenBuffer(cols: 7, rows: 3, hasScrollback: true)
            state.buffer = buffer
            for row in 0..<3 {
                attachImage(to: buffer.liveLine(row)) { [state] in
                    state.count += 1
                    let fresh = ScreenBuffer(cols: 3, rows: 2, hasScrollback: false)
                    fresh.x = 1
                    fresh.liveLine(0)[fresh.x] = Cell(scalar: 88, width: 1)
                    XCTAssertEqual(fresh.liveLine(0).trimmedText(), " X")
                }
            }
        }
        XCTAssertNil(state.buffer)
        XCTAssertEqual(state.count, 3)
    }

    private func attachImage(to line: Line, onRelease: @escaping () -> Void) {
        // Large enough to force retained external Data storage, not inline data.
        let count = 4096
        let memory = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: count)
        let payload = Data(bytesNoCopy: memory, count: count, deallocator: .custom { memory, _ in
            memory.deallocate()
            onRelease()
        })
        line.images = [LineImage(payload: .png(payload), pixelWidth: 1, pixelHeight: 1, col: 0)]
    }
}
