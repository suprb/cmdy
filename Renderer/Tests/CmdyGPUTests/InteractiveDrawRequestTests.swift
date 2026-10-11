import Foundation
import XCTest
@testable import CmdyGPU

@MainActor
final class InteractiveDrawRequestTests: XCTestCase {
    func testManyRequestsQueueOneServiceAndCommitTheLatestGeneration() throws {
        var requests = InteractiveDrawRequests()
        requests.request()
        XCTAssertTrue(requests.queueServiceIfNeeded(blocked: false))
        for _ in 0..<20 {
            requests.request()
            XCTAssertFalse(requests.queueServiceIfNeeded(blocked: false))
        }
        XCTAssertTrue(requests.beginService())
        let generation = try XCTUnwrap(requests.beginDraw())
        XCTAssertEqual(generation, requests.generation)
        requests.finishDraw(committed: generation)
        XCTAssertFalse(requests.isPending)
        XCTAssertFalse(requests.queueServiceIfNeeded(blocked: false))
    }

    func testRequestDuringDrawingWaitsAndIsNotConsumedByTheOlderFrame() throws {
        var requests = InteractiveDrawRequests()
        requests.request()
        let olderFrame = try XCTUnwrap(requests.beginDraw())
        requests.request()
        XCTAssertNil(requests.beginDraw())
        XCTAssertFalse(requests.queueServiceIfNeeded(blocked: false))
        requests.finishDraw(committed: olderFrame)
        XCTAssertTrue(requests.isPending)
        XCTAssertTrue(requests.queueServiceIfNeeded(blocked: false))
        XCTAssertFalse(requests.queueServiceIfNeeded(blocked: false))
        XCTAssertTrue(requests.beginService())
        let newerFrame = try XCTUnwrap(requests.beginDraw())
        XCTAssertGreaterThan(newerFrame, olderFrame)
        requests.finishDraw(committed: newerFrame)
        XCTAssertFalse(requests.isPending)
    }

    func testAppKitFrameCanConsumeAlreadyQueuedManualService() throws {
        var requests = InteractiveDrawRequests()
        requests.request()
        XCTAssertTrue(requests.queueServiceIfNeeded(blocked: false))
        let appKitFrame = try XCTUnwrap(requests.beginDraw())
        requests.finishDraw(committed: appKitFrame)
        XCTAssertFalse(requests.beginService())
        XCTAssertFalse(requests.serviceIsQueued)
    }

    func testBlockedOrUncommittedFrameRetainsOneRequestWithoutPolling() throws {
        var requests = InteractiveDrawRequests()
        requests.request()
        for _ in 0..<100 {
            XCTAssertFalse(requests.queueServiceIfNeeded(blocked: true))
        }
        XCTAssertTrue(requests.isPending)
        XCTAssertFalse(requests.serviceIsQueued)
        XCTAssertTrue(requests.queueServiceIfNeeded(blocked: false))
        XCTAssertTrue(requests.beginService())
        _ = try XCTUnwrap(requests.beginDraw())
        requests.finishDraw(committed: nil)
        XCTAssertTrue(requests.isPending)
        XCTAssertFalse(requests.serviceIsQueued)
        // A timer, GPU completion or subsequent publication supplies the
        // retry. An unbuildable frame does not enqueue a polling loop.
        XCTAssertTrue(requests.queueServiceIfNeeded(blocked: false))
        XCTAssertFalse(requests.queueServiceIfNeeded(blocked: false))
    }

    func testResponseAfterCommittedFallbackQueuesANewGeneration() throws {
        var requests = InteractiveDrawRequests()
        requests.request()
        XCTAssertTrue(requests.queueServiceIfNeeded(blocked: false))
        XCTAssertTrue(requests.beginService())
        let fallback = try XCTUnwrap(requests.beginDraw())
        requests.finishDraw(committed: fallback)
        XCTAssertFalse(requests.isPending)

        requests.request()
        XCTAssertTrue(requests.isPending)
        XCTAssertFalse(requests.queueServiceIfNeeded(blocked: true))
        XCTAssertTrue(requests.queueServiceIfNeeded(blocked: false))
        XCTAssertFalse(requests.queueServiceIfNeeded(blocked: false))
        XCTAssertTrue(requests.beginService())
        let response = try XCTUnwrap(requests.beginDraw())
        XCTAssertGreaterThan(response, fallback)
        requests.finishDraw(committed: response)
        XCTAssertFalse(requests.isPending)
        XCTAssertFalse(requests.queueServiceIfNeeded(blocked: false))
    }

    func testCancellationRetainsOnlyTheExistingQueuedServiceOwnership() throws {
        var requests = InteractiveDrawRequests()
        requests.request()
        XCTAssertTrue(requests.queueServiceIfNeeded(blocked: false))
        requests.cancel()
        XCTAssertFalse(requests.isPending)
        requests.request()
        XCTAssertFalse(requests.queueServiceIfNeeded(blocked: false))
        XCTAssertTrue(requests.beginService())
        let generation = try XCTUnwrap(requests.beginDraw())
        requests.finishDraw(committed: generation)
        XCTAssertFalse(requests.isPending)
    }

    func testCancellationDuringDrawCannotBeUndoneByItsCommit() throws {
        var requests = InteractiveDrawRequests()
        requests.request()
        let olderFrame = try XCTUnwrap(requests.beginDraw())
        requests.request()
        requests.cancel()
        requests.finishDraw(committed: olderFrame)
        XCTAssertFalse(requests.isPending)
        XCTAssertFalse(requests.queueServiceIfNeeded(blocked: false))
    }

    func testRetryStillUsesEachExistingPowerAndThermalFrameBudget() throws {
        let conditions: [(ProcessInfo.ThermalState, Bool, Bool, Double)] = [
            (.nominal, false, true, 120),
            (.nominal, true, true, 60),
            (.serious, false, true, 30),
            (.critical, false, true, 20),
            (.nominal, false, false, 30)
        ]
        for (thermal, lowPower, keyWindow, expectedFPS) in conditions {
            let fps = MetalTerminalRenderer.interactiveContentTargetFPS(
                isKeyWindow: keyWindow, thermalState: thermal,
                lowPowerMode: lowPower, maximumFramesPerSecond: 120)
            XCTAssertEqual(fps, expectedFPS)
            var pacer = FrameBuildPacer()
            pacer.markBuild(at: 100)
            var requests = InteractiveDrawRequests()
            requests.request()
            let delay = pacer.delay(at: 100.001, targetFPS: fps)
            XCTAssertEqual(delay, 1 / expectedFPS - 0.001, accuracy: 0.000_001)
            XCTAssertFalse(requests.queueServiceIfNeeded(blocked: delay > 0.000_25))
            XCTAssertTrue(requests.isPending)
            let retryTime = 100 + 1 / fps
            XCTAssertTrue(requests.queueServiceIfNeeded(
                blocked: pacer.delay(at: retryTime, targetFPS: fps) > 0.000_25))
            XCTAssertTrue(requests.beginService())
            let frame = try XCTUnwrap(requests.beginDraw())
            pacer.markBuild(at: retryTime)
            requests.finishDraw(committed: frame)
            XCTAssertFalse(requests.queueServiceIfNeeded(blocked: false))
            XCTAssertEqual(pacer.delay(at: retryTime, targetFPS: fps),
                           1 / expectedFPS, accuracy: 0.000_001)
        }
    }
}
