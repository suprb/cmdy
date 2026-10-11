import XCTest
@testable import ModelProbe

final class HistoryMaintenanceSchedulerTests: XCTestCase {
    func testBusyOutputOwnsOneCallbackAndRequiresAnotherQuietInterval() throws {
        var scheduler = HistoryMaintenanceScheduler()
        let first = try XCTUnwrap(scheduler.request())
        for _ in 0..<10_000 { XCTAssertNil(scheduler.request()) }
        XCTAssertEqual(scheduler.queuedService, first)
        let deferred = scheduler.fire(first)
        XCTAssertNil(deferred.batch)
        let quiet = try XCTUnwrap(deferred.enqueue)
        XCTAssertEqual(quiet.delay, 0.150)
        XCTAssertNil(scheduler.fire(first).batch)
        let action = scheduler.fire(quiet)
        XCTAssertEqual(action.batch?.startingAt, 0)
        XCTAssertNil(action.enqueue)
    }

    func testBatchesYieldAndCompletionLeavesNoIdleTimer() throws {
        var scheduler = HistoryMaintenanceScheduler()
        let service = try XCTUnwrap(scheduler.request())
        let first = try XCTUnwrap(scheduler.fire(service).batch)
        let next = try XCTUnwrap(scheduler.finish(first, nextAbsoluteRow: 32, complete: false))
        XCTAssertEqual(next.delay, 0.002)
        XCTAssertNil(scheduler.activeBatch)
        XCTAssertTrue(scheduler.needsWork)
        let second = try XCTUnwrap(scheduler.fire(next).batch)
        XCTAssertEqual(second.startingAt, 32)
        XCTAssertNil(scheduler.finish(second, nextAbsoluteRow: 48, complete: true))
        XCTAssertFalse(scheduler.needsWork)
        XCTAssertNil(scheduler.queuedService)
        scheduler.noteActivity()
        XCTAssertNil(scheduler.queuedService)
        XCTAssertNil(scheduler.fire(next).batch)
    }

    func testInputPostponesAnAlreadyQueuedContinuation() throws {
        var scheduler = HistoryMaintenanceScheduler()
        let first = try XCTUnwrap(scheduler.request())
        let batch = try XCTUnwrap(scheduler.fire(first).batch)
        let continuation = try XCTUnwrap(scheduler.finish(batch, nextAbsoluteRow: 32, complete: false))
        scheduler.noteActivity()
        let action = scheduler.fire(continuation)
        XCTAssertNil(action.batch)
        let quiet = try XCTUnwrap(action.enqueue)
        XCTAssertEqual(quiet.delay, 0.150)
        XCTAssertEqual(scheduler.fire(quiet).batch?.startingAt, 32)
    }

    func testViewportResetRestartsTheCursorWithoutAnotherQueuedClosure() throws {
        var scheduler = HistoryMaintenanceScheduler()
        let first = try XCTUnwrap(scheduler.request())
        let batch = try XCTUnwrap(scheduler.fire(first).batch)
        let continuation = try XCTUnwrap(scheduler.finish(batch, nextAbsoluteRow: 128, complete: false))
        XCTAssertNil(scheduler.request(restart: true))
        XCTAssertEqual(scheduler.nextAbsoluteRow, 0)
        XCTAssertEqual(scheduler.queuedService, continuation)
        let quiet = try XCTUnwrap(scheduler.fire(continuation).enqueue)
        XCTAssertEqual(scheduler.fire(quiet).batch?.startingAt, 0)
    }

    func testCancelResumeFloodRetainsOneInertOldCallback() throws {
        var scheduler = HistoryMaintenanceScheduler()
        let first = try XCTUnwrap(scheduler.request())
        for _ in 0..<1000 {
            scheduler.cancel()
            XCTAssertNil(scheduler.request())
            scheduler.resume()
            XCTAssertNil(scheduler.request(restart: true))
            XCTAssertEqual(scheduler.queuedService, first)
        }
        let action = scheduler.fire(first)
        XCTAssertNil(action.batch)
        let quiet = try XCTUnwrap(action.enqueue)
        XCTAssertNil(scheduler.fire(first).enqueue)
        XCTAssertEqual(scheduler.queuedService, quiet)
        let batch = try XCTUnwrap(scheduler.fire(quiet).batch)
        XCTAssertNil(scheduler.finish(batch, nextAbsoluteRow: 0, complete: true))
        XCTAssertNil(scheduler.queuedService)
    }

    func testResetDuringActiveWorkDiscardsItsStaleCursorAndCompletion() throws {
        var scheduler = HistoryMaintenanceScheduler()
        let first = try XCTUnwrap(scheduler.request())
        let batch = try XCTUnwrap(scheduler.fire(first).batch)
        XCTAssertNil(scheduler.request(restart: true))
        let quiet = try XCTUnwrap(scheduler.finish(batch, nextAbsoluteRow: 1000, complete: true))
        XCTAssertEqual(quiet.delay, 0.150)
        XCTAssertEqual(scheduler.nextAbsoluteRow, 0)
        XCTAssertTrue(scheduler.needsWork)
        XCTAssertNil(scheduler.finish(batch, nextAbsoluteRow: 2000, complete: true))
        XCTAssertEqual(scheduler.fire(quiet).batch?.startingAt, 0)
    }

    func testCancellationMakesPendingAndActiveServicesInert() throws {
        var scheduler = HistoryMaintenanceScheduler()
        let pending = try XCTUnwrap(scheduler.request())
        scheduler.cancel()
        XCTAssertNil(scheduler.fire(pending).batch)
        XCTAssertNil(scheduler.queuedService)
        scheduler.resume()
        let next = try XCTUnwrap(scheduler.request())
        let batch = try XCTUnwrap(scheduler.fire(next).batch)
        scheduler.cancel()
        XCTAssertNil(scheduler.finish(batch, nextAbsoluteRow: 64, complete: false))
        XCTAssertFalse(scheduler.needsWork)
        XCTAssertNil(scheduler.queuedService)
    }

    func testDuplicateOldCompletionCannotReplaceANewerActiveBatch() throws {
        var scheduler = HistoryMaintenanceScheduler()
        let first = try XCTUnwrap(scheduler.request())
        let old = try XCTUnwrap(scheduler.fire(first).batch)
        let next = try XCTUnwrap(scheduler.finish(old, nextAbsoluteRow: 32, complete: false))
        let current = try XCTUnwrap(scheduler.fire(next).batch)
        XCTAssertNil(scheduler.finish(old, nextAbsoluteRow: 999, complete: true))
        XCTAssertEqual(scheduler.activeBatch, current)
        XCTAssertEqual(scheduler.nextAbsoluteRow, 32)
        XCTAssertNil(scheduler.finish(current, nextAbsoluteRow: 64, complete: true))
        XCTAssertEqual(scheduler.nextAbsoluteRow, 64)
    }
}
