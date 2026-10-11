import Foundation
import XCTest
@testable import CmdyCore

final class LineOwnedClusterAppendTests: XCTestCase {
    // Swift cells and arrays are value projections of native rows. Their
    // temporary addresses and reserved capacity do not describe row storage;
    // Core/Zig/cluster_append_tests.zig checks that storage directly.
    private func prepared(_ seed: String = "e\u{301}", columns: Int = 32) -> CmdyTerminal {
        let terminal = CmdyTerminal(cols: columns, rows: 3)
        terminal.feed(text: seed)
        return terminal
    }

    func testExistingExtrasAndJoinedFollowersPreserveCellValues() {
        for (seed, followers) in [
            ("e\u{301}", ["\u{308}", "\u{305}", "\u{E0100}"]),
            ("\u{2764}\u{FE0F}\u{200D}", ["\u{1F525}", "\u{200D}", "\u{1F525}"]),
        ] {
            let terminal = prepared(seed)
            let line = terminal.buffer.liveLine(0)
            var expected = line[0]
            for follower in followers {
                terminal.feed(text: follower)
                expected.clusterExtras!.append(contentsOf: follower.unicodeScalars.map(\.value))
                XCTAssertEqual(line[0], expected)
            }
        }
    }

    func testRetainedSnapshotCellAndExtrasKeepOriginalValues() {
        for kind in 0..<4 {
            let terminal = prepared()
            let line = terminal.buffer.liveLine(0)
            let alias: Any
            switch kind {
            case 0: alias = terminal.captureTerminalSnapshot(consumeDamage: false)
            case 1: alias = line.cells
            case 2: alias = line[0]
            default: alias = line[0].clusterExtras!
            }
            withExtendedLifetime(alias) {
                terminal.feed(text: "\u{308}")
                XCTAssertEqual(line[0].clusterExtras, [0x301, 0x308])
                switch kind {
                case 0:
                    let snapshot = alias as! CoreTerminalSnapshot
                    XCTAssertEqual(snapshot.line(absolute: 0)?.cells[0].clusterExtras, [0x301])
                case 1: XCTAssertEqual((alias as! [Cell])[0].clusterExtras, [0x301])
                case 2: XCTAssertEqual((alias as! Cell).clusterExtras, [0x301])
                default: XCTAssertEqual(alias as! [UInt32], [0x301])
                }
            }
        }
    }

    func testPendingAndReverseIndexWitnessesPreserveClusterValues() {
        let pending = CmdyTerminal(cols: 1, rows: 3)
        pending.feed(text: "e\u{301}")
        XCTAssertTrue(pending.buffer.wrapPending)
        let pendingLine = pending.buffer.liveLine(0)
        pending.feed(text: "\u{308}")
        XCTAssertEqual(pendingLine[0].clusterExtras, [0x301, 0x308])
        XCTAssertTrue(pending.buffer.wrapPending)

        let reverse = CmdyTerminal(cols: 1, rows: 3)
        reverse.feed(text: "e\u{301}A\u{1B}M\u{1B}M")
        let rotated = reverse.buffer.liveLine(1)
        XCTAssertEqual(rotated[0].scalar, 0x65)
        XCTAssertEqual(rotated[0].clusterExtras, [0x301])
        reverse.feed(text: "\u{308}")
        XCTAssertEqual(rotated[0].clusterExtras, [0x301, 0x308])
        XCTAssertEqual(reverse.buffer.x, 0)
        XCTAssertEqual(reverse.buffer.y, 0)
    }

    func testFirstAllocationGrowthAndOneRowVersionPerFollower() {
        let terminal = CmdyTerminal(cols: 10, rows: 2)
        terminal.feed(text: "e")
        let line = terminal.buffer.liveLine(0)
        XCTAssertNil(line[0].clusterExtras)
        for count in 1...300 {
            _ = terminal.consumeDirtyRows()
            let before = line.version
            terminal.feed(text: "\u{301}")
            XCTAssertEqual(line[0].clusterExtras?.count, count)
            XCTAssertEqual(line[0].clusterExtras?.last, 0x301)
            XCTAssertEqual(line.version, before + 1)
            XCTAssertEqual(terminal.consumeDirtyRows(), 0...0)
            XCTAssertEqual(terminal.buffer.x, 1)
        }
        XCTAssertEqual(line[0].clusterExtras, Array(repeating: UInt32(0x301), count: 300))
    }

    func testFreshPublicCellMutationIsValidatedAndMetadataPreserved() {
        let terminal = prepared()
        let line = terminal.buffer.liveLine(0)
        var edited = line[0]
        edited.clusterExtras = [0x305]
        edited.attribute.style = [.bold, .italic]
        edited.linkId = 37
        line[0] = edited
        terminal.feed(text: "\u{308}")
        var expected = edited
        expected.clusterExtras = [0x305, 0x308]
        XCTAssertEqual(line[0], expected)

        line[0] = Cell(scalar: 0x78, clusterExtras: [0x302])
        terminal.feed(text: "\u{301}")
        XCTAssertEqual(line[0], Cell(scalar: 0x78, clusterExtras: [0x302]))
        line.resize(to: 0, fill: Cell())
        terminal.feed(text: "\u{301}")
        XCTAssertEqual(line.count, 0)
    }

    func testDeferredClusterFillAndASCIITailOverwritePreserveCOW() {
        for retainClone in [false, true] {
            let terminal = CmdyTerminal(cols: 32, rows: 3)
            terminal.feed(text: "e")
            let line = terminal.buffer.liveLine(0)
            let fill = Cell(scalar: 0x65, clusterExtras: [0x305], linkId: 7)
            line.fill(with: fill)
            let clone = retainClone ? line.clone() : nil
            terminal.feed(text: "\u{308}")
            XCTAssertEqual(line[0], Cell(scalar: 0x65, clusterExtras: [0x305, 0x308], linkId: 7))
            XCTAssertTrue(line.cells.dropFirst().allSatisfy { $0 == fill })
            if let clone { XCTAssertTrue(clone.cells.allSatisfy { $0 == fill }) }
            terminal.feed(text: "\r" + String(repeating: "x", count: 32))
            XCTAssertTrue(line.cells.allSatisfy { $0.scalar == 0x78 && $0.clusterExtras == nil })
            if let clone { XCTAssertTrue(clone.cells.allSatisfy { $0 == fill }) }
        }
    }

    func testSelectorExpansionAndShrinkPreserveStubAndOldSnapshot() {
        let terminal = CmdyTerminal(cols: 8, rows: 2)
        terminal.feed(text: "\u{1B}[1m\u{1B}]8;;https://fixture.invalid\u{1B}\\\u{2764}")
        let line = terminal.buffer.liveLine(0)
        let original = terminal.captureTerminalSnapshot(consumeDamage: false)
        terminal.feed(text: "\u{FE0F}")
        XCTAssertEqual(line[0].width, 2)
        XCTAssertEqual(line[0].clusterExtras, [0xFE0F])
        XCTAssertEqual(line[1].width, 0)
        XCTAssertEqual(line[1].attribute, line[0].attribute)
        XCTAssertEqual(line[1].linkId, line[0].linkId)
        XCTAssertEqual(terminal.buffer.x, 2)
        XCTAssertEqual(original.line(absolute: 0)?.cells[0].width, 1)
        XCTAssertNil(original.line(absolute: 0)?.cells[0].clusterExtras)

        let shrink = CmdyTerminal(cols: 8, rows: 2)
        shrink.feed(text: "\u{1F600}\u{200D}\u{2764}\u{FE0E}")
        XCTAssertEqual(shrink.buffer.liveLine(0)[0].clusterExtras, [0x200D, 0x2764, 0xFE0E])
        XCTAssertEqual(shrink.buffer.liveLine(0)[0].width, 1)
        XCTAssertEqual(shrink.buffer.liveLine(0)[1].width, 0)
        XCTAssertEqual(shrink.buffer.x, 1)
    }

    func testContentCallbackReentrySeesCompletedLineMutation() {
        let terminal = prepared()
        let observer = Observer()
        terminal.delegate = observer
        var reentered = false
        observer.onChange = { terminal in
            guard !reentered else { return }
            reentered = true
            XCTAssertEqual(terminal.buffer.liveLine(0)[0].clusterExtras, [0x301, 0x308])
            terminal.feed(text: "\u{305}")
        }
        terminal.feed(text: "\u{308}")
        XCTAssertEqual(observer.changes, 2)
        XCTAssertEqual(terminal.buffer.liveLine(0)[0].clusterExtras, [0x301, 0x308, 0x305])
    }

    private final class Observer: CmdyTerminalDelegate {
        var changes = 0
        var onChange: ((CmdyTerminal) -> Void)?
        func contentChanged(_ terminal: CmdyTerminal) { changes += 1; onChange?(terminal) }
        func send(_ terminal: CmdyTerminal, data: ArraySlice<UInt8>) {}
        func setTitle(_ terminal: CmdyTerminal, title: String) {}
        func setCurrentDirectory(_ terminal: CmdyTerminal, directory: String?) {}
        func bell(_ terminal: CmdyTerminal) {}
        func clipboardCopy(_ terminal: CmdyTerminal, content: Data) {}
        func willReflow(_ terminal: CmdyTerminal) {}
        func didReflow(_ terminal: CmdyTerminal) {}
    }
}
