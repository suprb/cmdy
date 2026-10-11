import XCTest
import CmdyCore
@testable import ModelProbe

final class SnapshotPublicationMailboxTests: XCTestCase {
    func testTakenDamageIsNotInvalidatedByAYoungerAsynchronousPublication() throws {
        let terminal = CmdyTerminal(cols: 20, rows: 20)
        _ = terminal.captureTerminalSnapshot()
        var mailbox = SnapshotPublicationMailbox()
        terminal.feed(text: "A")
        XCTAssertTrue(mailbox.offer(terminal.captureTerminalSnapshot(), generation: 1,
                                    reflowEpoch: 0, started: 10))
        let first = try XCTUnwrap(mailbox.take())
        terminal.feed(text: "\u{1B}[16;1HB")
        XCTAssertTrue(mailbox.offer(terminal.captureTerminalSnapshot(), generation: 2,
                                    reflowEpoch: 0, started: 20))
        XCTAssertTrue(mailbox.accepts(first), "the taken packet still owns its damage")
        let second = try XCTUnwrap(mailbox.take())
        XCTAssertEqual(first.snapshot.line(absolute: 15)?.cells[0].scalar, 0,
                       "an immutable taken snapshot cannot change beneath its observer")
        XCTAssertEqual(second.snapshot.line(absolute: 15)?.cells[0].scalar, 66)
        XCTAssertFalse(mailbox.callbackQueued)
        XCTAssertNil(mailbox.pending)
    }

    func testSynchronousReplacementInvalidatesTakenPacketWithoutDuplicatingQueuedWork() throws {
        let terminal = CmdyTerminal(cols: 10, rows: 4)
        var mailbox = SnapshotPublicationMailbox()
        let snapshot = terminal.captureTerminalSnapshot()
        XCTAssertTrue(mailbox.offer(snapshot, generation: 1, reflowEpoch: 0, started: 1))
        let taken = try XCTUnwrap(mailbox.take())
        mailbox.discardPending()
        XCTAssertFalse(mailbox.accepts(taken))
        XCTAssertTrue(mailbox.offer(snapshot, generation: 2, reflowEpoch: 0, started: 2))
        XCTAssertTrue(mailbox.discardPending())
        XCTAssertTrue(mailbox.callbackQueued, "an enqueued callback retains exclusive ownership")
        XCTAssertFalse(mailbox.offer(snapshot, generation: 3, reflowEpoch: 0, started: 3))
        XCTAssertEqual(mailbox.take()?.generation, 3)
    }

    func testManyReplacementsStillOwnOnePendingCallbackAndNewestSnapshot() throws {
        let terminal = CmdyTerminal(cols: 10, rows: 4)
        var mailbox = SnapshotPublicationMailbox()
        var enqueued = 0
        for generation in 1...200 {
            terminal.feed(text: "\u{1B}[1;1H\(generation)")
            if mailbox.offer(terminal.captureTerminalSnapshot(), generation: UInt64(generation),
                             reflowEpoch: 0, started: UInt64(generation)) { enqueued += 1 }
        }
        XCTAssertEqual(enqueued, 1)
        XCTAssertEqual(mailbox.pending?.generation, 200)
        XCTAssertEqual(mailbox.take()?.generation, 200)
        XCTAssertFalse(mailbox.callbackQueued)
    }

    func testAlternateRoundTripKeepsFullInvalidationSticky() throws {
        let terminal = CmdyTerminal(cols: 10, rows: 4)
        var mailbox = SnapshotPublicationMailbox()
        _ = mailbox.offer(terminal.captureTerminalSnapshot(), generation: 1, reflowEpoch: 0, started: 1)
        terminal.feed(text: "\u{1B}[?1049hA")
        _ = mailbox.offer(terminal.captureTerminalSnapshot(), generation: 2, reflowEpoch: 0, started: 2)
        terminal.feed(text: "\u{1B}[?1049l")
        _ = mailbox.offer(terminal.captureTerminalSnapshot(), generation: 3, reflowEpoch: 0, started: 3)
        let publication = try XCTUnwrap(mailbox.take())
        XCTAssertFalse(publication.snapshot.grid.isAlternateBuffer)
        XCTAssertTrue(publication.damage.invalidatesAllRows)
    }

    func testChangedDimensionsAndReflowEpochForceFullInvalidation() throws {
        for resize in [false, true] {
            let terminal = CmdyTerminal(cols: 10, rows: 4)
            var mailbox = SnapshotPublicationMailbox()
            _ = mailbox.offer(terminal.captureTerminalSnapshot(), generation: 1, reflowEpoch: 0, started: 1)
            if resize { terminal.resize(cols: 8, rows: 5) }
            _ = mailbox.offer(terminal.captureTerminalSnapshot(), generation: 2,
                              reflowEpoch: resize ? 0 : 1, started: 2)
            XCTAssertTrue(try XCTUnwrap(mailbox.take()).damage.invalidatesAllRows)
        }
    }

    func testViewportMotionPreservesCachesButRetainedOriginChangeInvalidatesThem() throws {
        let terminal = CmdyTerminal(cols: 10, rows: 4, scrollback: 4)
        terminal.feed(text: String(repeating: "line\r\n", count: 12))
        let initial = terminal.captureTerminalSnapshot()
        var mailbox = SnapshotPublicationMailbox()
        _ = mailbox.offer(initial, generation: 1, reflowEpoch: 0, started: 1)
        terminal.scrollViewport(to: 0)
        let scrolled = terminal.captureTerminalSnapshot()
        XCTAssertNotEqual(initial.grid.displayTopRow, scrolled.grid.displayTopRow)
        _ = mailbox.offer(scrolled, generation: 2, reflowEpoch: 0, started: 2)
        XCTAssertFalse(try XCTUnwrap(mailbox.take()).damage.invalidatesAllRows)
        _ = mailbox.offer(scrolled, generation: 3, reflowEpoch: 0, started: 3)
        terminal.feed(text: String(repeating: "more\r\n", count: 12))
        let dropped = terminal.captureTerminalSnapshot()
        XCTAssertGreaterThan(dropped.grid.retainedRowOrigin, scrolled.grid.retainedRowOrigin)
        _ = mailbox.offer(dropped, generation: 4, reflowEpoch: 0, started: 4)
        XCTAssertTrue(try XCTUnwrap(mailbox.take()).damage.invalidatesAllRows)
    }

    func testOrdinaryHistoryGrowthPreservesRowCoordinatesAndMergedDamage() throws {
        let terminal = CmdyTerminal(cols: 10, rows: 4, scrollback: 40)
        _ = terminal.captureTerminalSnapshot()
        terminal.feed(text: "first\r\nsecond\r\nthird")
        let initial = terminal.captureTerminalSnapshot()
        var mailbox = SnapshotPublicationMailbox()
        _ = mailbox.offer(initial, generation: 1, reflowEpoch: 0, started: 1)
        terminal.feed(text: "\r\nfourth\r\nfifth")
        let appended = terminal.captureTerminalSnapshot()
        XCTAssertGreaterThan(appended.grid.bufferLineCount, initial.grid.bufferLineCount)
        XCTAssertGreaterThan(appended.grid.liveTopRow, initial.grid.liveTopRow)
        XCTAssertGreaterThan(appended.grid.displayTopRow, initial.grid.displayTopRow)
        XCTAssertEqual(appended.grid.retainedRowOrigin, initial.grid.retainedRowOrigin)
        XCTAssertEqual(appended.line(absolute: 0)?.version, initial.line(absolute: 0)?.version)
        _ = mailbox.offer(appended, generation: 2, reflowEpoch: 0, started: 2)
        let packet = try XCTUnwrap(mailbox.take())
        XCTAssertFalse(packet.damage.invalidatesAllRows, "append-only output must retain row caches")
        let rows = try XCTUnwrap(packet.damage.rows)
        XCTAssertTrue(rows.contains(try XCTUnwrap(initial.dirtyRows).lowerBound))
        XCTAssertTrue(rows.contains(try XCTUnwrap(appended.dirtyRows).upperBound))
    }

    func testBufferShrinkCannotReuseAnOlderCoordinateMapping() throws {
        let terminal = CmdyTerminal(cols: 10, rows: 4, scrollback: 40)
        terminal.feed(text: String(repeating: "history\r\n", count: 10))
        let initial = terminal.captureTerminalSnapshot()
        var mailbox = SnapshotPublicationMailbox()
        _ = mailbox.offer(initial, generation: 1, reflowEpoch: 0, started: 1)
        terminal.feed(text: "\u{1B}c")
        let reset = terminal.captureTerminalSnapshot()
        XCTAssertLessThan(reset.grid.bufferLineCount, initial.grid.bufferLineCount)
        _ = mailbox.offer(reset, generation: 2, reflowEpoch: 0, started: 2)
        XCTAssertTrue(try XCTUnwrap(mailbox.take()).damage.invalidatesAllRows)
    }

    func testCursorOnlyChangesPreserveRowSpecificInvalidation() throws {
        let terminal = CmdyTerminal(cols: 10, rows: 4)
        _ = terminal.captureTerminalSnapshot()
        var mailbox = SnapshotPublicationMailbox()
        terminal.feed(text: "\u{1B}[2;2H")
        _ = mailbox.offer(terminal.captureTerminalSnapshot(), generation: 1, reflowEpoch: 0, started: 1)
        terminal.feed(text: "\u{1B}[3;3H")
        _ = mailbox.offer(terminal.captureTerminalSnapshot(), generation: 2, reflowEpoch: 0, started: 2)
        let packet = try XCTUnwrap(mailbox.take())
        XCTAssertFalse(packet.damage.invalidatesAllRows)
        XCTAssertEqual(packet.damage.rows, 0...2)
    }
}
