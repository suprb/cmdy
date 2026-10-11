import XCTest
@testable import ModelProbe

final class SnapshotPublicationSchedulerTests: XCTestCase {
    func testCoalescedCallbacksDoNotEvaluateClockUnlessPTYInputIntentNeedsProcessing() throws {
        var scheduler = SnapshotPublicationScheduler()
        var clockReads = 0
        var now = 1.0
        func clock() -> Double { clockReads += 1; return now }
        _ = scheduler.request(at: clock(), fromPTYOutput: true)
        XCTAssertEqual(clockReads, 1)
        for _ in 0..<1_000 {
            XCTAssertNil(scheduler.request(at: clock(), fromPTYOutput: true))
        }
        XCTAssertEqual(clockReads, 1)
        scheduler.noteUserInput(at: now)
        XCTAssertNil(scheduler.request(at: clock(), fromPTYOutput: false))
        XCTAssertEqual(clockReads, 1, "host output cannot promote a pending response")
        let response = try XCTUnwrap(scheduler.request(at: clock(), fromPTYOutput: true))
        XCTAssertEqual(response.kind, .immediate)
        XCTAssertEqual(clockReads, 2)
        XCTAssertNil(scheduler.request(at: clock(), fromPTYOutput: true))
        XCTAssertEqual(clockReads, 2)
        scheduler.noteUserInput(at: now)
        now = 2
        XCTAssertNil(scheduler.request(at: clock(), fromPTYOutput: true))
        XCTAssertEqual(clockReads, 3, "an outstanding credit must expire on the next PTY callback")
        XCTAssertNil(scheduler.responseDeadline)
        XCTAssertEqual(scheduler.queuedServiceCount, 2)
    }

    func testQueuedOutputLeavesInputCreditToTheReadThatDrainsTheBurst() throws {
        var scheduler = SnapshotPublicationScheduler()
        scheduler.noteUserInput(at: 1)
        let piece = try XCTUnwrap(scheduler.request(at: 1.001, fromPTYOutput: true, outputContinues: true))
        XCTAssertEqual(piece.kind, .delayed, "a piece of a larger response must not capture at once")
        XCTAssertNotNil(scheduler.responseDeadline)
        XCTAssertNil(scheduler.request(at: 1.0012, fromPTYOutput: true, outputContinues: true))
        let last = try XCTUnwrap(scheduler.request(at: 1.0014, fromPTYOutput: true))
        XCTAssertEqual(last.kind, .immediate, "the draining read keeps the response promotion")
        XCTAssertNil(scheduler.responseDeadline)
        XCTAssertEqual(scheduler.fire(last, at: 1.0014).capture?.kind, .immediate)
    }

    func testOrdinaryOutputKeepsOneMillisecondWindowAndOneService() throws {
        var scheduler = SnapshotPublicationScheduler()
        let service = try XCTUnwrap(scheduler.request(at: 1, fromPTYOutput: true))
        XCTAssertEqual(service.kind, .delayed)
        XCTAssertEqual(service.readyAt, 1.001, accuracy: 0.0000001)
        for index in 1...100 {
            XCTAssertNil(scheduler.request(at: 1 + Double(index) / 1_000_000,
                                           fromPTYOutput: true))
        }
        XCTAssertEqual(scheduler.queuedServiceCount, 1)
        XCTAssertEqual(scheduler.fire(service, at: 1.001).capture?.kind, .delayed)
        XCTAssertFalse(scheduler.isScheduled)
        XCTAssertEqual(scheduler.queuedServiceCount, 0)
    }

    func testOnlyFirstPTYResponseConsumesInputCredit() throws {
        var scheduler = SnapshotPublicationScheduler()
        scheduler.noteUserInput(at: 1)
        let host = try XCTUnwrap(scheduler.request(at: 1.0001, fromPTYOutput: false))
        XCTAssertEqual(host.kind, .delayed)
        XCTAssertNotNil(scheduler.responseDeadline)
        let response = try XCTUnwrap(scheduler.request(at: 1.0002, fromPTYOutput: true))
        XCTAssertEqual(response.kind, .immediate)
        XCTAssertNil(scheduler.responseDeadline)
        XCTAssertNil(scheduler.request(at: 1.0003, fromPTYOutput: true))
        XCTAssertEqual(scheduler.queuedServiceCount, 2)
        XCTAssertNil(scheduler.fire(host, at: 1.002).capture,
                     "the stale delayed callback cannot own a promoted response")
        XCTAssertEqual(scheduler.fire(response, at: 1.002).capture?.kind, .immediate)
        let later = try XCTUnwrap(scheduler.request(at: 1.003, fromPTYOutput: true))
        XCTAssertEqual(later.kind, .delayed)
    }

    func testEarlyDelayedServiceRearmsForLatestRequestWithoutCapturingEarly() throws {
        var scheduler = SnapshotPublicationScheduler()
        let old = try XCTUnwrap(scheduler.request(at: 1, fromPTYOutput: true))
        scheduler.resetPendingCapture()
        XCTAssertNil(scheduler.request(at: 1.0009, fromPTYOutput: true))
        let action = scheduler.fire(old, at: 1.001)
        XCTAssertNil(action.capture)
        let later = try XCTUnwrap(action.enqueue)
        XCTAssertEqual(later.readyAt, 1.0019, accuracy: 0.0000001)
        XCTAssertEqual(scheduler.queuedServiceCount, 1)
        XCTAssertNotNil(scheduler.fire(later, at: 1.002).capture)
    }

    func testResetAndRequestFloodCannotAccumulateQueuedClosures() throws {
        var scheduler = SnapshotPublicationScheduler()
        var services: [SnapshotPublicationScheduler.Service] = []
        for index in 0..<10_000 {
            let now = 1 + Double(index) / 1_000_000
            scheduler.resetPendingCapture()
            if let service = scheduler.request(at: now, fromPTYOutput: false) { services.append(service) }
            scheduler.noteUserInput(at: now)
            if let service = scheduler.request(at: now, fromPTYOutput: true) { services.append(service) }
            XCTAssertLessThanOrEqual(scheduler.queuedServiceCount, 2)
        }
        XCTAssertEqual(services.count, 2, "one delayed plus one immediate callback is the hard bound")
        scheduler.resetPendingCapture()
        for service in services {
            let action = scheduler.fire(service, at: 2)
            XCTAssertNil(action.capture)
            XCTAssertNil(action.enqueue)
        }
        XCTAssertEqual(scheduler.queuedServiceCount, 0)
        XCTAssertFalse(scheduler.isScheduled)
    }

    func testExpiryCreatesNoSelfTickAndLateResponseKeepsOrdinaryBudget() throws {
        var scheduler = SnapshotPublicationScheduler()
        scheduler.noteUserInput(at: 1)
        XCTAssertEqual(scheduler.queuedServiceCount, 0)
        XCTAssertFalse(scheduler.isScheduled)
        let late = try XCTUnwrap(scheduler.request(at: 1.151, fromPTYOutput: true))
        XCTAssertNil(scheduler.responseDeadline)
        XCTAssertEqual(late.kind, .delayed)
        XCTAssertNotNil(scheduler.fire(late, at: 1.153).capture)
        XCTAssertEqual(scheduler.queuedServiceCount, 0)
        XCTAssertFalse(scheduler.isScheduled)
    }

    func testNewKeysReplaceDeadlineAndCancellationCannotReviveOldIntent() throws {
        var scheduler = SnapshotPublicationScheduler()
        scheduler.noteUserInput(at: 1)
        scheduler.noteUserInput(at: 1.1)
        XCTAssertEqual(try XCTUnwrap(scheduler.responseDeadline), 1.25, accuracy: 0.0000001)
        scheduler.cancelUserInput()
        let late = try XCTUnwrap(scheduler.request(at: 1.12, fromPTYOutput: true))
        XCTAssertEqual(late.kind, .delayed)
        _ = scheduler.fire(late, at: 1.122)
        scheduler.noteUserInput(at: 1.13)
        let fresh = try XCTUnwrap(scheduler.request(at: 1.131, fromPTYOutput: true))
        XCTAssertEqual(fresh.kind, .immediate)
        XCTAssertNil(scheduler.responseDeadline)
    }

    func testCancellationPreservesAlreadyPendingContent() throws {
        var scheduler = SnapshotPublicationScheduler()
        scheduler.noteUserInput(at: 1)
        let response = try XCTUnwrap(scheduler.request(at: 1.01, fromPTYOutput: true))
        scheduler.cancelUserInput()
        XCTAssertNotNil(scheduler.fire(response, at: 1.011).capture)
        XCTAssertEqual(scheduler.queuedServiceCount, 0)
    }

    func testSustainedKeysCannotExceedExpeditedCeilingOrReuseCredit() throws {
        var scheduler = SnapshotPublicationScheduler()
        var previousFast: Double?
        var fastCaptures = 0
        for index in 0..<1_000 {
            let now = 1 + Double(index) * 0.001
            scheduler.noteUserInput(at: now)
            if let service = scheduler.request(at: now, fromPTYOutput: true) {
                let firedAt = max(now, service.readyAt)
                if scheduler.fire(service, at: firedAt).capture?.kind == .immediate {
                    if let previousFast {
                        XCTAssertGreaterThanOrEqual(firedAt - previousFast,
                                                   SnapshotPublicationScheduler.minimumExpeditedInterval)
                    }
                    previousFast = firedAt
                    fastCaptures += 1
                }
            }
            XCTAssertNil(scheduler.responseDeadline)
            XCTAssertLessThanOrEqual(scheduler.queuedServiceCount, 2)
        }
        XCTAssertGreaterThan(fastCaptures, 0)
        XCTAssertLessThanOrEqual(fastCaptures, 120)
    }

    func testDuplicateServiceCannotCaptureTwiceAndResetKeepsCeiling() throws {
        var scheduler = SnapshotPublicationScheduler()
        scheduler.noteUserInput(at: 1)
        let response = try XCTUnwrap(scheduler.request(at: 1, fromPTYOutput: true))
        XCTAssertNotNil(scheduler.fire(response, at: 1).capture)
        XCTAssertNil(scheduler.fire(response, at: 1).capture)
        scheduler.resetPendingCapture()
        scheduler.noteUserInput(at: 1.001)
        let next = try XCTUnwrap(scheduler.request(at: 1.001, fromPTYOutput: true))
        XCTAssertEqual(next.kind, .delayed, "reset cannot bypass the 120/s ceiling")
    }
}
