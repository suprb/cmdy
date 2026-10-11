import CmdyNative
import Foundation
import Metal
import XCTest
@testable import CmdyGPU

final class RenderUpdateMailboxTests: XCTestCase {
    private struct Timers {
        var active: [Int: [Double]] = [:]
        var fps: Int64 = 0
        var work: UInt32 = 0
        mutating func receive(_ value: CmdyRenderSessionUpdate) {
            guard value.kind == UInt32(CMDY_SESSION_ACTIONS) else { return }
            let flags = value.actions.flags
            let starts = [CMDY_RENDER_START_ANIMATION, CMDY_RENDER_START_COALESCED,
                          CMDY_RENDER_START_KEYBOARD, CMDY_RENDER_START_RECOVERY]
            let stops = [CMDY_RENDER_STOP_ANIMATION, CMDY_RENDER_STOP_COALESCED,
                         CMDY_RENDER_STOP_KEYBOARD, CMDY_RENDER_STOP_RECOVERY]
            let intervals = [value.actions.animation_interval, value.actions.coalesced_interval,
                             value.actions.keyboard_interval, value.actions.recovery_interval]
            for i in 0..<4 {
                if flags & UInt32(stops[i]) != 0 { active.removeValue(forKey: i) }
                if flags & UInt32(starts[i]) != 0 { active[i] = [value.environment.now, intervals[i]] }
            }
            if value.actions.preferred_fps > 0 { fps = value.actions.preferred_fps }
            work |= flags & UInt32(CMDY_RENDER_QUEUE_SERVICE | CMDY_RENDER_INVALIDATE_VIEW)
        }
    }
    private func actions(_ index: Int, flags: UInt32 = 0) -> CmdyRenderSessionUpdate {
        var value = CmdyRenderSessionUpdate()
        value.kind = UInt32(CMDY_SESSION_ACTIONS); value.actions.flags = flags
        value.environment.now = Double(index)
        value.inspection.activity_time = Double(index)
        value.actions.animation_interval = 0.04
        value.actions.coalesced_interval = 0.005
        value.actions.keyboard_interval = 0.012
        value.actions.recovery_interval = 0.021
        return value
    }

    func testHundredThousandUpdatesStayBoundedAndPreserveTimerSemantics() {
        let mailbox = RenderUpdateMailbox()
        var expected = Timers(), wakeups = 0, random: UInt64 = 923
        for i in 1...100_000 {
            random = random &* 6364136223846793005 &+ 1
            var value = actions(i, flags: UInt32((random >> 32) & 2047))
            if i % 37 == 0 { value.actions.preferred_fps = i % 2 == 0 ? 60 : 120 }
            expected.receive(value)
            if mailbox.append(value) { wakeups += 1 }
        }
        XCTAssertEqual(wakeups, 1)
        XCTAssertLessThanOrEqual(mailbox.retainedUpdateCount, 14)
        let updates = mailbox.take()
        var actual = Timers()
        for update in updates { actual.receive(update.value) }
        XCTAssertEqual(actual.active, expected.active)
        XCTAssertEqual(actual.fps, expected.fps)
        XCTAssertEqual(actual.work, expected.work)
        XCTAssertEqual(updates.last?.value.inspection.activity_time, 100_000)
        XCTAssertFalse(mailbox.finishDrain())
        XCTAssertEqual(mailbox.retainedUpdateCount, 0)
    }

    func testTimerOriginsAndRepeatingCadenceSurviveLaterEmptyActions() throws {
        let mailbox = RenderUpdateMailbox()
        XCTAssertTrue(mailbox.append(actions(10, flags: UInt32(CMDY_RENDER_START_ANIMATION))))
        XCTAssertFalse(mailbox.append(actions(20, flags: UInt32(CMDY_RENDER_START_KEYBOARD))))
        XCTAssertFalse(mailbox.append(actions(1000)))
        let updates = mailbox.take().map(\.value)
        let animation = try XCTUnwrap(updates.first { $0.actions.flags & UInt32(CMDY_RENDER_START_ANIMATION) != 0 })
        let keyboard = try XCTUnwrap(updates.first { $0.actions.flags & UInt32(CMDY_RENDER_START_KEYBOARD) != 0 })
        XCTAssertEqual(animation.environment.now, 10)
        XCTAssertEqual(animation.actions.animation_interval, 0.04)
        XCTAssertEqual(keyboard.environment.now + keyboard.actions.keyboard_interval, 20.012)
        XCTAssertEqual(updates.last?.environment.now, 1000)
    }

    func testControlRepliesSealFIFOStateAndBoundAllOutstandingReservations() throws {
        let mailbox = RenderUpdateMailbox()
        XCTAssertFalse(mailbox.reserveReply(0))
        var wakeups = 0
        for id in 1...RenderUpdateMailbox.replyLimit {
            XCTAssertTrue(mailbox.reserveReply(UInt64(id)))
            XCTAssertFalse(mailbox.reserveReply(UInt64(id)))
            for tick in 0..<20 {
                if mailbox.append(actions(id * 100 + tick, flags: UInt32(CMDY_RENDER_START_KEYBOARD))) { wakeups += 1 }
            }
            var reply = CmdyRenderSessionUpdate()
            reply.kind = UInt32(CMDY_SESSION_INSPECTION); reply.request_id = UInt64(id)
            reply.inspection.activity_time = Double(id * 100 + 19)
            XCTAssertFalse(mailbox.append(reply))
            XCTAssertFalse(mailbox.append(reply)) // duplicate cannot consume another slot
        }
        XCTAssertEqual(wakeups, 1)
        XCTAssertTrue(mailbox.replyCapacityFull)
        XCTAssertFalse(mailbox.reserveReply(1000))
        XCTAssertLessThanOrEqual(mailbox.retainedUpdateCount, 15 * RenderUpdateMailbox.replyLimit)
        var time: Double = 0
        var ids: [UInt64] = []
        for update in mailbox.take().map(\.value) {
            if update.kind == UInt32(CMDY_SESSION_ACTIONS) { time = update.inspection.activity_time }
            if update.request_id != 0 {
                XCTAssertEqual(time, update.inspection.activity_time)
                ids.append(update.request_id)
            }
        }
        XCTAssertEqual(ids, (1...64).map(UInt64.init))
        // Taking a batch doesn't release a reply before the client receives it.
        XCTAssertFalse(mailbox.reserveReply(1000))
        mailbox.releaseReply(1)
        XCTAssertTrue(mailbox.reserveReply(1000))
    }

    func testUpdateDuringDeliveryRearmsExactlyOnceAndCloseDropsRetainedState() {
        let mailbox = RenderUpdateMailbox()
        XCTAssertTrue(mailbox.append(actions(1)))
        XCTAssertEqual(mailbox.take().count, 1)
        // A producer races the UI callback while the original wakeup is armed.
        XCTAssertFalse(mailbox.append(actions(2)))
        XCTAssertTrue(mailbox.finishDrain())
        XCTAssertEqual(mailbox.take().last?.value.environment.now, 2)
        XCTAssertFalse(mailbox.finishDrain())
        XCTAssertTrue(mailbox.append(actions(3)))
        XCTAssertTrue(mailbox.reserveReply(17))
        mailbox.close()
        XCTAssertEqual(mailbox.retainedUpdateCount, 0)
        XCTAssertTrue(mailbox.take().isEmpty)
        XCTAssertFalse(mailbox.finishDrain())
        XCTAssertFalse(mailbox.append(actions(4)))
        XCTAssertFalse(mailbox.reserveReply(18))
    }

    func testCaptureFrameAndErrorsKeepTheirLatestIdentityAcrossStateUpdates() {
        let mailbox = RenderUpdateMailbox()
        let kinds = [CMDY_SESSION_READY, CMDY_SESSION_CAPTURE, CMDY_SESSION_FRAME,
                     CMDY_SESSION_ERROR, CMDY_SESSION_CAPACITY_AVAILABLE]
        for i in 1...1000 {
            for kind in kinds {
                var value = CmdyRenderSessionUpdate()
                value.kind = UInt32(kind); value.identity.sequence = UInt64(i)
                value.source_revision = UInt64(i)
                _ = mailbox.append(value)
            }
        }
        let updates = mailbox.take().map(\.value)
        XCTAssertEqual(updates.count, kinds.count)
        XCTAssertEqual(updates.map(\.kind), kinds.map(UInt32.init))
        XCTAssertTrue(updates.allSatisfy { $0.source_revision == 1000 && $0.identity.sequence == 1000 })
    }

    func testConcurrentProducersRemainBoundedWithoutWaitingForUIDelivery() async {
        let mailbox = RenderUpdateMailbox()
        await withTaskGroup(of: Int.self) { group in
            for producer in 0..<8 {
                group.addTask {
                    var wakeups = 0
                    for i in 0..<10_000 {
                        var value = CmdyRenderSessionUpdate()
                        value.kind = UInt32(CMDY_SESSION_ACTIONS)
                        value.environment.now = Double(producer * 10_000 + i)
                        if mailbox.append(value) { wakeups += 1 }
                    }
                    return wakeups
                }
            }
            var wakeups = 0
            for await count in group { wakeups += count }
            XCTAssertEqual(wakeups, 1)
        }
        XCTAssertEqual(mailbox.retainedUpdateCount, 1)
        XCTAssertEqual(mailbox.take().count, 1)
        XCTAssertFalse(mailbox.finishDrain())
    }
    private func fillAllSlots(_ mailbox: RenderUpdateMailbox, index: Int) {
        let kinds = [CMDY_SESSION_READY, CMDY_SESSION_CAPTURE, CMDY_SESSION_FRAME,
                     CMDY_SESSION_ERROR, CMDY_SESSION_ERROR, CMDY_SESSION_CAPACITY_AVAILABLE,
                     CMDY_SESSION_INSPECTION]
        for (i, kind) in kinds.enumerated() {
            var value = CmdyRenderSessionUpdate()
            value.kind = UInt32(kind)
            value.identity.sequence = i == 3 ? 0 : UInt64(index)
            value.source_revision = UInt64(index)
            _ = mailbox.append(value)
        }
        var value = actions(index, flags: 2047)
        value.actions.preferred_fps = 120
        value.source_revision = UInt64(index)
        _ = mailbox.append(value)
    }

    func testAllSlotsPreserveOrderIncludingActionsFromSameUpdate() {
        let mailbox = RenderUpdateMailbox()
        fillAllSlots(mailbox, index: 1)
        XCTAssertEqual(mailbox.retainedUpdateCount, 14)
        let output = mailbox.take().map(\.value)
        XCTAssertEqual(output.count, 14)
        XCTAssertEqual(output.prefix(7).map(\.kind), [CMDY_SESSION_READY, CMDY_SESSION_CAPTURE,
            CMDY_SESSION_FRAME, CMDY_SESSION_ERROR, CMDY_SESSION_ERROR,
            CMDY_SESSION_CAPACITY_AVAILABLE, CMDY_SESSION_INSPECTION].map(UInt32.init))
        XCTAssertEqual(output.suffix(7).map { $0.actions.flags }, [24, 96, 384, 1536, 0, 7, 0])
        XCTAssertEqual(output.suffix(7).map { $0.actions.preferred_fps }, [0, 0, 0, 0, 120, 0, 0])
        XCTAssertFalse(mailbox.finishDrain())
        XCTAssertEqual(mailbox.retainedUpdateCount, 0)
    }

    func testFullReplyCapacityKeepsEveryStateBoundaryAndTrailingState() {
        let mailbox = RenderUpdateMailbox()
        for id in 1...RenderUpdateMailbox.replyLimit {
            XCTAssertTrue(mailbox.reserveReply(UInt64(id)))
            fillAllSlots(mailbox, index: id)
            var reply = CmdyRenderSessionUpdate()
            reply.kind = UInt32(CMDY_SESSION_INSPECTION)
            reply.request_id = UInt64(id)
            reply.source_revision = UInt64(id)
            XCTAssertFalse(mailbox.append(reply))
            XCTAssertFalse(mailbox.append(reply))
            XCTAssertEqual(mailbox.retainedUpdateCount, id * 15)
        }
        fillAllSlots(mailbox, index: 65)
        XCTAssertEqual(mailbox.retainedUpdateCount, 15 * RenderUpdateMailbox.replyLimit + 14)
        XCTAssertFalse(mailbox.reserveReply(65))
        let output = mailbox.take().map(\.value)
        XCTAssertEqual(output.count, 974)
        for (offset, update) in output.enumerated() {
            XCTAssertEqual(update.source_revision, UInt64(offset / 15 + 1))
            XCTAssertEqual(update.request_id, offset % 15 == 14 ? UInt64(offset / 15 + 1) : 0)
        }
        XCTAssertEqual(mailbox.retainedUpdateCount, 0)
        XCTAssertTrue(mailbox.replyCapacityFull)
        mailbox.releaseReply(1)
        XCTAssertTrue(mailbox.reserveReply(65))
        XCTAssertFalse(mailbox.finishDrain())
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testConcurrentDeliveryRetainsEveryReservedReplyExactlyOnce() async {
        let mailbox = RenderUpdateMailbox()
        let completion = Completion()
        for id in 1...64 { XCTAssertTrue(mailbox.reserveReply(UInt64(id))) }
        let replies = await withTaskGroup(of: [UInt64].self, returning: [UInt64].self) { group in
            for producer in 0..<4 {
                group.addTask {
                    defer { completion.increment() }
                    for tick in 0..<2000 {
                        var action = CmdyRenderSessionUpdate()
                        action.kind = UInt32(CMDY_SESSION_ACTIONS)
                        action.environment.now = Double(producer * 2000 + tick)
                        action.actions.flags = 2047
                        action.actions.preferred_fps = 120
                        _ = mailbox.append(action)
                        if tick % 125 == 0 {
                            var reply = CmdyRenderSessionUpdate()
                            reply.kind = UInt32(CMDY_SESSION_INSPECTION)
                            reply.request_id = UInt64(producer * 16 + tick / 125 + 1)
                            _ = mailbox.append(reply)
                            _ = mailbox.append(reply)
                        }
                        if tick % 31 == 0 { await Task.yield() }
                    }
                    return []
                }
            }
            group.addTask {
                var ids: [UInt64] = []
                while true {
                    for update in mailbox.take() where update.value.request_id != 0 {
                        ids.append(update.value.request_id)
                        mailbox.releaseReply(update.value.request_id)
                    }
                    let again = mailbox.finishDrain()
                    if completion.count == 4 && !again && mailbox.retainedUpdateCount == 0 { break }
                    await Task.yield()
                }
                return ids
            }
            var result: [UInt64] = []
            for await ids in group { result.append(contentsOf: ids) }
            return result
        }
        XCTAssertEqual(replies.sorted(), (1...64).map(UInt64.init))
        XCTAssertEqual(mailbox.retainedUpdateCount, 0)
        XCTAssertFalse(mailbox.replyCapacityFull)
        XCTAssertFalse(mailbox.finishDrain())
    }

    func testConcurrentClosePreventsNewAdmissionAndRearming() async {
        let mailbox = RenderUpdateMailbox()
        await withTaskGroup(of: Void.self) { group in
            for producer in 0..<4 {
                group.addTask {
                    for tick in 0..<2000 {
                        var action = CmdyRenderSessionUpdate()
                        action.kind = UInt32(CMDY_SESSION_ACTIONS)
                        action.environment.now = Double(producer * 2000 + tick)
                        _ = mailbox.append(action)
                        if tick % 31 == 0 { await Task.yield() }
                    }
                }
            }
            group.addTask {
                for _ in 0..<32 { _ = mailbox.take(); _ = mailbox.finishDrain(); await Task.yield() }
                mailbox.close()
            }
        }
        XCTAssertTrue(mailbox.take().isEmpty)
        XCTAssertEqual(mailbox.retainedUpdateCount, 0)
        XCTAssertFalse(mailbox.finishDrain())
        XCTAssertFalse(mailbox.reserveReply(1))
        var update = CmdyRenderSessionUpdate(); update.kind = UInt32(CMDY_SESSION_ACTIONS)
        XCTAssertFalse(mailbox.append(update))
    }
}

@MainActor
final class RenderUpdateMailboxIntegrationTests: XCTestCase {
    func testRealWorkerReplyAdmissionRecoversAfterMainThreadDrain() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let session = try RenderWorkerSession(device: device, pixelFormat: .bgra8Unorm, surface: 903)
        let first = expectation(description: "all accepted replies delivered")
        first.expectedFulfillmentCount = RenderUpdateMailbox.replyLimit
        let resumed = expectation(description: "admission resumes after delivery")
        var ids: [UInt64] = []
        session.onUpdate = { update in
            guard update.kind == UInt32(CMDY_SESSION_INSPECTION) else { return }
            ids.append(update.request_id)
            if update.request_id == 1000 { resumed.fulfill() } else { first.fulfill() }
        }
        var command = CmdyRenderSessionCommand(); command.kind = UInt32(CMDY_SESSION_INSPECT)
        // The main actor cannot drain callbacks while this synchronous loop runs.
        for id in 1...RenderUpdateMailbox.replyLimit {
            command.request_id = UInt64(id)
            XCTAssertTrue(session.post(command))
        }
        command.request_id = 1000
        XCTAssertFalse(session.post(command))
        XCTAssertTrue(session.waitForCapacity())
        await fulfillment(of: [first], timeout: 10)
        XCTAssertEqual(ids, (1...64).map(UInt64.init))
        XCTAssertTrue(session.post(command))
        await fulfillment(of: [resumed], timeout: 10)
        XCTAssertEqual(ids.last, 1000)
        await session.shutdown()
    }

    func testCloseWithQueuedNativeRepliesNeverCallsDetachedOwner() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let session = try RenderWorkerSession(device: device, pixelFormat: .bgra8Unorm, surface: 904)
        var callbacks = 0
        session.onUpdate = { _ in callbacks += 1 }
        var command = CmdyRenderSessionCommand(); command.kind = UInt32(CMDY_SESSION_INSPECT)
        for id in 1...RenderUpdateMailbox.replyLimit {
            command.request_id = UInt64(id); XCTAssertTrue(session.post(command))
        }
        session.close()
        await session.shutdown()
        XCTAssertEqual(callbacks, 0)
        XCTAssertFalse(session.post(command))
    }
}
