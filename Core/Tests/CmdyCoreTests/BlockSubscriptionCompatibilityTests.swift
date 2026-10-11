import Foundation
import XCTest
@testable import CmdyCore

final class BlockSubscriptionCompatibilityTests: XCTestCase {
    private final class ReleaseAction {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        deinit { action() }
    }
    private func closureHolding(_ object: ReleaseAction) -> () -> Void {
        { withExtendedLifetime(object) {} }
    }

    func testNilSubscriptionStillRebasesPrunesAndPreservesRetainedAliases() {
        let terminal = CmdyTerminal(cols: 5, rows: 2, scrollback: 0)
        terminal.feed(text: "\u{1B}]133;A\u{7}\u{1B}]133;C\u{7}")
        let block = terminal.blocks.blocks[0]
        let snapshot = terminal.captureTerminalSnapshot(consumeDamage: false)
        terminal.feed(text: "a\r\nb\r\nc\r\nd")
        XCTAssertLessThan(block.promptRow, 0)
        XCTAssertTrue(terminal.blocks.blocks.isEmpty)
        XCTAssertEqual(snapshot.grid.rows, 2)
        XCTAssertEqual(snapshot.line(absolute: 0)?.cells[0].scalar, 0)
        var changes = 0
        terminal.blocks.onChange = { changes += 1 }
        terminal.feed(text: "\u{1B}]133;B\u{7}")
        XCTAssertEqual(changes, 1, "An unmatched marker still notifies when subscribed")
    }

    func testPublicGetterSetterKeyPathAndInoutWriteback() {
        let terminal = CmdyTerminal(cols: 8, rows: 2)
        let path: ReferenceWritableKeyPath<BlockTracker, (() -> Void)?> = \.onChange
        var calls = 0
        terminal.blocks[keyPath: path] = { calls += 1 }
        terminal.blocks[keyPath: path]?()
        func replace(_ callback: inout (() -> Void)?, _ replacement: @escaping () -> Void) {
            callback = replacement
        }
        replace(&terminal.blocks.onChange, { calls += 10 })
        terminal.feed(text: "\u{1B}]133;B\u{7}")
        XCTAssertEqual(calls, 11)
        terminal.blocks[keyPath: path] = nil
        terminal.feed(text: "\u{1B}]133;B\u{7}")
        XCTAssertEqual(calls, 11)
    }

    func testCallbackReplacementRemovalAndNestedFeedUseCurrentSubscription() {
        let terminal = CmdyTerminal(cols: 8, rows: 2)
        var events: [String] = []
        terminal.blocks.onChange = { [weak terminal] in
            events.append("first")
            terminal?.blocks.onChange = { [weak terminal] in
                events.append("replacement")
                terminal?.blocks.onChange = nil
                terminal?.feed(text: "\u{1B}]133;B\u{7}")
            }
            terminal?.feed(text: "\u{1B}]133;B\u{7}")
        }
        terminal.feed(text: "\u{1B}]133;B\u{7}\u{1B}]133;B\u{7}")
        XCTAssertEqual(events, ["first", "replacement"])
    }

    func testOldClosureDestructionReentersAfterNewCallbackIsPublished() {
        let terminal = CmdyTerminal(cols: 8, rows: 2)
        var events: [String] = []
        terminal.blocks.onChange = closureHolding(ReleaseAction { [weak terminal] in
            events.append("release")
            terminal?.feed(text: "\u{1B}]133;B\u{7}")
        })
        terminal.blocks.onChange = { events.append("new") }
        XCTAssertEqual(events, ["release", "new"])
        terminal.blocks.onChange = closureHolding(ReleaseAction { [weak terminal] in
            events.append("nil-release")
            XCTAssertNil(terminal?.blocks.onChange)
            terminal?.feed(text: "\u{1B}]133;B\u{7}")
        })
        terminal.blocks.onChange = nil
        XCTAssertEqual(events, ["release", "new", "nil-release"])
    }

    func testOSCRegistrationAndResetTakeEffectWithinSameFeed() {
        let terminal = CmdyTerminal(cols: 8, rows: 2)
        var changes = 0
        terminal.registerOscHandler(code: 133) { [weak terminal] _ in
            terminal?.blocks.onChange = { changes += 1 }
        }
        terminal.feed(text: "\u{1B}]133;B\u{7}\u{1B}]133;B\u{7}")
        XCTAssertEqual(changes, 1)
        terminal.feed(text: "\u{1B}c\u{1B}]133;B\u{7}")
        XCTAssertEqual(changes, 3, "Reset does not erase callback registration")
        terminal.blocks.onChange = nil
        terminal.feed(text: "\u{1B}c")
        XCTAssertEqual(changes, 3)
    }

    func testRetainedTrackerOutlivesTerminalWithoutRetainingItsFacade() {
        var terminal: CmdyTerminal? = CmdyTerminal(cols: 8, rows: 2)
        weak var weakTerminal = terminal
        let tracker = terminal!.blocks
        var changes = 0
        terminal = nil
        XCTAssertNil(weakTerminal)
        tracker.onChange = { changes += 1 }
        tracker.promptEnded(row: 0, col: 0)
        tracker.reset()
        tracker.onChange = nil
        tracker.reset()
        XCTAssertEqual(changes, 2)
    }

    func testStandaloneTrackerKeepsDirectCallbackBehavior() {
        let tracker = BlockTracker()
        var changes = 0
        tracker.onChange = { changes += 1 }
        tracker.promptEnded(row: 0, col: 0)
        tracker.rebase(droppedLines: 2)
        tracker.reset()
        XCTAssertEqual(changes, 3)
        tracker.onChange = nil
        tracker.reset()
        XCTAssertEqual(changes, 3)
    }

    func testCommandFinishedRemainsDeliveredWithOnChangeNil() {
        let terminal = CmdyTerminal(cols: 8, rows: 2)
        var finished: TerminalBlock?
        terminal.blocks.onCommandFinished = { finished = $0 }
        terminal.feed(text: "\u{1B}]133;A\u{7}\u{1B}]133;C\u{7}x\u{1B}]133;D;0\u{7}")
        XCTAssertEqual(finished?.exitCode, 0)
        XCTAssertEqual(finished?.running, false)
        XCTAssertNil(terminal.blocks.onChange)
    }
}
