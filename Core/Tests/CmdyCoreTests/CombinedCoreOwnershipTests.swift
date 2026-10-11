import Foundation
import XCTest
@testable import CmdyCore

final class CombinedCoreOwnershipTests: XCTestCase {
    func testOwnedControlReentryKeepsBuffersAliveAndSnapshotIndependentAfterOwnerRelease() throws {
        let owner = ExternalOwner()
        owner.terminal = CmdyTerminal(cols: 4, rows: 3, scrollback: 0)
        let state = Observation()
        state.terminal = owner.terminal
        state.normal = owner.terminal?.normalBuffer
        state.alternate = owner.terminal?.altBuffer
        let observer = Observer(state: state)

        // Finish setup before observing callbacks. Raw CR/LF below will trim
        // this capped screen and invoke BlockTracker from inside parserExecute.
        owner.terminal?.feed(text: "a\r\nb\r\nc")
        owner.terminal?.delegate = observer
        owner.terminal?.blocks.onChange = { [weak owner, state] in
            guard !state.releasedExternalOwner else { return }
            state.releasedExternalOwner = true
            owner?.terminal = nil

            // State stores only weak engine/buffer references. The active
            // owned feed must keep its receiver and both numeric owners alive.
            guard let terminal = state.terminal else {
                return XCTFail("terminal expired during its owned control callback")
            }
            XCTAssertTrue(terminal.normalBuffer === state.normal)
            XCTAssertTrue(terminal.altBuffer === state.alternate)
            XCTAssertEqual(terminal.normalBuffer.cols, 4)
            XCTAssertEqual(terminal.normalBuffer.rows, 3)

            terminal.feed(text: "\u{1B}[He\u{301}")
            state.snapshot = terminal.captureTerminalSnapshot(consumeDamage: false)
            let beforeVersion = terminal.buffer.liveLine(0).version
            _ = terminal.consumeDirtyRows()
            terminal.feed(text: "\u{308}")
            XCTAssertEqual(terminal.buffer.liveLine(0)[0].clusterExtras, [0x301, 0x308])
            XCTAssertEqual(state.snapshot?.line(absolute: 0)?.cells[0].clusterExtras, [0x301])
            XCTAssertEqual(terminal.buffer.liveLine(0).version, beforeVersion + 1)
            XCTAssertEqual(terminal.consumeDirtyRows(), 0...0)
            XCTAssertEqual([terminal.buffer.x, terminal.buffer.y], [1, 0])
        }

        autoreleasepool {
            // The remaining SGR/ASCII must execute after the callback releases
            // the external owner. No strong test-side terminal local survives.
            owner.terminal?.feed(text: "\r\n\u{1B}[32mX")
        }

        XCTAssertTrue(state.releasedExternalOwner)
        XCTAssertNil(owner.terminal)
        XCTAssertNil(state.terminal)
        XCTAssertNil(state.normal)
        XCTAssertNil(state.alternate)
        XCTAssertEqual(state.contentChanges, 3)
        XCTAssertEqual(state.clusterCounts, [1, 2, 2])
        XCTAssertEqual(state.finalCursor, [2, 0, 4, 3])
        XCTAssertEqual(state.finalScalar, 0x58)
        XCTAssertEqual(state.finalExtras, [0x301, 0x308])
        XCTAssertEqual(state.finalForeground, .ansi256(2))

        // The snapshot retains copied row data, never a ScreenBuffer owner or
        // a mutable alias to the line's newly appended cluster array.
        let snapshot = try XCTUnwrap(state.snapshot)
        XCTAssertEqual(snapshot.line(absolute: 0)?.cells[0].scalar, 0x65)
        XCTAssertEqual(snapshot.line(absolute: 0)?.cells[0].clusterExtras, [0x301])
        XCTAssertNotEqual(snapshot.line(absolute: 0)?.cells[1].scalar, 0x58)
        withExtendedLifetime(observer) {}
    }

    private final class ExternalOwner {
        var terminal: CmdyTerminal?
    }

    private final class Observation {
        weak var terminal: CmdyTerminal?
        weak var normal: ScreenBuffer?
        weak var alternate: ScreenBuffer?
        var releasedExternalOwner = false
        var snapshot: CoreTerminalSnapshot?
        var contentChanges = 0
        var clusterCounts: [Int] = []
        var finalCursor: [Int] = []
        var finalScalar: UInt32?
        var finalExtras: [UInt32]?
        var finalForeground: CellColor?
    }

    private final class Observer: CmdyTerminalDelegate {
        let state: Observation
        init(state: Observation) { self.state = state }
        func contentChanged(_ terminal: CmdyTerminal) {
            XCTAssertTrue(terminal === state.terminal)
            XCTAssertTrue(terminal.buffer === state.normal)
            state.contentChanges += 1
            state.clusterCounts.append(terminal.buffer.liveLine(0)[0].clusterExtras?.count ?? 0)
            state.finalCursor = [terminal.buffer.x, terminal.buffer.y,
                                 terminal.buffer.cols, terminal.buffer.rows]
            let scalar = terminal.buffer.liveLine(0)[1].scalar
            if scalar == 0x58 {
                state.finalScalar = scalar
                state.finalExtras = terminal.buffer.liveLine(0)[0].clusterExtras
                state.finalForeground = terminal.currentAttribute.fg
            }
        }
        func send(_ terminal: CmdyTerminal, data: ArraySlice<UInt8>) {}
        func setTitle(_ terminal: CmdyTerminal, title: String) {}
        func setCurrentDirectory(_ terminal: CmdyTerminal, directory: String?) {}
        func bell(_ terminal: CmdyTerminal) {}
        func clipboardCopy(_ terminal: CmdyTerminal, content: Data) {}
        func willReflow(_ terminal: CmdyTerminal) {}
        func didReflow(_ terminal: CmdyTerminal) {}
    }
}
