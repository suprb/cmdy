import CmdyNative
import Foundation
import MetalKit
import XCTest
@testable import CmdyGPU

@MainActor
final class RendererBackpressureTests: XCTestCase {
    private final class RetainedControl {
        var executions = 0
    }
    private func capacityUpdate() -> CmdyRenderSessionUpdate {
        var update = CmdyRenderSessionUpdate()
        update.kind = UInt32(CMDY_SESSION_CAPACITY_AVAILABLE)
        return update
    }

    func testCapacityNotificationPreservesFIFOAndAdjacentCoalescingWithoutTimer() async throws {
        let fixture = try await HeadlessSchedulingFixture()
        let renderer = try XCTUnwrap(fixture.renderer)
        let scheduler = try XCTUnwrap(renderer.scheduler)
        var accepts = false
        var delivered: [String] = []
        scheduler.capacityWaitForTesting = { true }
        for (key, text) in [(0, "key-one"), (7, "old-draw"), (7, "latest-draw"), (0, "key-two")] {
            scheduler.enqueue(coalesceKey: key) {
                guard accepts else { return false }
                delivered.append(text); return true
            }
        }
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertNil(scheduler.retryTimerForTesting)
        accepts = true
        scheduler.receive(capacityUpdate())
        XCTAssertEqual(delivered, ["key-one", "latest-draw", "key-two"])
        scheduler.receive(capacityUpdate())
        XCTAssertEqual(delivered.count, 3)
        XCTAssertNil(scheduler.retryTimerForTesting)
    }

    func testCapacityReleasedBeforeRegistrationRetriesImmediately() async throws {
        let fixture = try await HeadlessSchedulingFixture()
        let renderer = try XCTUnwrap(fixture.renderer)
        let scheduler = try XCTUnwrap(renderer.scheduler)
        var attempts = 0, registrations = 0, deliveries = 0
        scheduler.capacityWaitForTesting = { registrations += 1; return false }
        scheduler.enqueue {
            attempts += 1
            guard attempts >= 3 else { return false }
            deliveries += 1; return true
        }
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(deliveries, 1)
        XCTAssertNil(scheduler.retryTimerForTesting)
    }

    func testAllocationFailureUsesBoundedFallbackAndReleasesItAfterRecovery() async throws {
        let fixture = try await HeadlessSchedulingFixture()
        let renderer = try XCTUnwrap(fixture.renderer)
        let scheduler = try XCTUnwrap(renderer.scheduler)
        var accepts = false, attempts = 0
        scheduler.capacityWaitForTesting = { false }
        scheduler.enqueue { attempts += 1; return accepts }
        XCTAssertEqual(attempts, 3)
        let timer = try XCTUnwrap(scheduler.retryTimerForTesting)
        XCTAssertTrue(timer.isValid)
        timer.fire()
        XCTAssertEqual(attempts, 5)
        accepts = true
        timer.fire()
        XCTAssertEqual(attempts, 6)
        XCTAssertFalse(timer.isValid)
        XCTAssertNil(scheduler.retryTimerForTesting)
    }

    func testCloseDropsPendingWorkAndIgnoresLateCapacityDelivery() async throws {
        let fixture = try await HeadlessSchedulingFixture()
        let renderer = try XCTUnwrap(fixture.renderer)
        let scheduler = try XCTUnwrap(renderer.scheduler)
        var attempts = 0
        scheduler.capacityWaitForTesting = { true }
        scheduler.enqueue { attempts += 1; return false }
        let beforeClose = attempts
        scheduler.close()
        scheduler.receive(capacityUpdate())
        XCTAssertEqual(attempts, beforeClose)
        XCTAssertNil(scheduler.capacityWaitForTesting)
        XCTAssertNil(scheduler.retryTimerForTesting)
    }

    func testAcceptedControlReleasesCaptureWhileFollowingControlIsStillBlocked() async throws {
        let fixture = try await HeadlessSchedulingFixture()
        let scheduler = try XCTUnwrap(fixture.renderer?.scheduler)
        scheduler.capacityWaitForTesting = { true }
        var first: RetainedControl? = RetainedControl()
        var second: RetainedControl? = RetainedControl()
        weak var firstOwner = first
        weak var secondOwner = second
        var acceptsFirst = false
        scheduler.enqueue { [owner = try! XCTUnwrap(first)] in
            guard acceptsFirst else { return false }
            owner.executions += 1
            return true
        }
        scheduler.enqueue { [owner = try! XCTUnwrap(second)] in
            owner.executions += 1
            return false
        }
        first = nil; second = nil
        XCTAssertNotNil(firstOwner)
        XCTAssertNotNil(secondOwner)
        acceptsFirst = true
        scheduler.receive(capacityUpdate())
        XCTAssertNil(firstOwner, "Accepted work must release its capture before the whole queue drains")
        XCTAssertNotNil(secondOwner, "Unaccepted work must remain alive for retry")
        scheduler.close()
        XCTAssertNil(secondOwner)
    }

    func testSustainedOverloadHasFiniteAdmissionAndRecoversInFIFOOrder() async throws {
        let fixture = try await HeadlessSchedulingFixture()
        let scheduler = try XCTUnwrap(fixture.renderer?.scheduler)
        scheduler.capacityWaitForTesting = { true }
        var blocked = true
        var delivered: [Int] = []
        var accepted: [Int] = []
        for value in 0..<100_000 {
            if scheduler.enqueue(attempt: {
                guard !blocked else { return false }
                delivered.append(value); return true
            }) { accepted.append(value) }
            XCTAssertLessThanOrEqual(scheduler.pendingCount, RendererScheduler.pendingLimit)
        }
        XCTAssertEqual(accepted, Array(0..<RendererScheduler.pendingLimit))
        XCTAssertEqual(scheduler.rejectedControlCount, UInt64(100_000 - RendererScheduler.pendingLimit))
        XCTAssertNil(scheduler.retryTimerForTesting)
        blocked = false
        scheduler.receive(capacityUpdate())
        XCTAssertEqual(delivered.count, 32, "A capacity callback must yield after one bounded batch")
        for _ in 0..<30 where scheduler.pendingCount > 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(delivered, accepted)
        XCTAssertEqual(scheduler.pendingCount, 0)
        scheduler.receive(capacityUpdate())
        XCTAssertEqual(delivered, accepted, "Late notifications cannot execute accepted controls twice")
        XCTAssertTrue(scheduler.enqueue { delivered.append(100_001); return true })
        XCTAssertEqual(delivered.last, 100_001)
    }

    func testRejectedCaptureIsReleasedAndAdjacentReplacementWorksAtCapacity() async throws {
        let fixture = try await HeadlessSchedulingFixture()
        let scheduler = try XCTUnwrap(fixture.renderer?.scheduler)
        scheduler.capacityWaitForTesting = { true }
        for _ in 0..<(RendererScheduler.pendingLimit - 1) {
            XCTAssertTrue(scheduler.enqueue { false })
        }
        var old: RetainedControl? = RetainedControl()
        weak var oldOwner = old
        XCTAssertTrue(scheduler.enqueue(coalesceKey: 7) { [owner = old!] in owner.executions += 1; return false })
        old = nil
        XCTAssertNotNil(oldOwner)
        XCTAssertTrue(scheduler.enqueue(coalesceKey: 7) { false })
        XCTAssertNil(oldOwner)
        var rejected: RetainedControl? = RetainedControl()
        weak var rejectedOwner = rejected
        XCTAssertFalse(scheduler.enqueue { [owner = rejected!] in owner.executions += 1; return false })
        rejected = nil
        XCTAssertNil(rejectedOwner)
        XCTAssertEqual(scheduler.pendingCount, RendererScheduler.pendingLimit)
        scheduler.close()
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertFalse(scheduler.enqueue { XCTFail("Closed work must not execute"); return true })
    }

    func testShaderAndInspectionRejectImmediatelyAtCapacityAndDoNotDoubleReplyOnClose() async throws {
        let fixture = try await HeadlessSchedulingFixture()
        let renderer = try XCTUnwrap(fixture.renderer)
        let scheduler = try XCTUnwrap(renderer.scheduler)
        scheduler.capacityWaitForTesting = { true }
        for _ in 0..<RendererScheduler.pendingLimit { scheduler.enqueue { false } }
        let reply = await renderer.loadUserShader(source: nil)
        XCTAssertEqual(reply, "Renderer control queue is busy; retry the shader change")
        let inspection = await renderer.synchronizeForTesting()
        XCTAssertNil(inspection)
        XCTAssertEqual(scheduler.pendingCount, RendererScheduler.pendingLimit)
        await renderer.shutdown()
        scheduler.receive(capacityUpdate())
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testOverloadedInputDoesNotWaitAndFinalConfigurationRecovers() async throws {
        let fixture = try await HeadlessSchedulingFixture()
        let renderer = try XCTUnwrap(fixture.renderer)
        let scheduler = try XCTUnwrap(renderer.scheduler)
        scheduler.capacityWaitForTesting = { true }
        var blocked = true, deliveries = 0, overloads = 0
        scheduler.onOverload = { overloads += 1 }
        for _ in 0..<RendererScheduler.pendingLimit {
            scheduler.enqueue { guard !blocked else { return false }; deliveries += 1; return true }
        }
        for _ in 0..<10_000 { scheduler.noteKeyboardInteraction() }
        renderer.smoothScrollEnabled = false
        renderer.textRenderingMode = .crisp
        renderer.invalidateRowCache()
        XCTAssertEqual(overloads, 1)
        XCTAssertEqual(scheduler.pendingCount, RendererScheduler.pendingLimit)
        XCTAssertEqual(deliveries, 0)
        blocked = false
        scheduler.receive(capacityUpdate())
        for _ in 0..<100 where scheduler.pendingCount > 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        let response = await renderer.synchronizeForTesting()
        let recovered = try XCTUnwrap(response)
        XCTAssertEqual(deliveries, RendererScheduler.pendingLimit)
        XCTAssertFalse(recovered.config.smooth_scroll)
        XCTAssertEqual(recovered.preset, TextRenderingMode.crisp.gpuValue)
        XCTAssertEqual(scheduler.pendingCount, 0)
        await renderer.shutdown()
    }

    func testStaleAllocationRetryCannotServiceNewQueueAndCloseReleasesAllCaptures() async throws {
        let fixture = try await HeadlessSchedulingFixture()
        let scheduler = try XCTUnwrap(fixture.renderer?.scheduler)
        scheduler.capacityWaitForTesting = { false }
        var accepts = false
        scheduler.enqueue { accepts }
        let stale = try XCTUnwrap(scheduler.retryTimerForTesting)
        accepts = true; stale.fire()
        var attempts = 0
        scheduler.enqueue { attempts += 1; return false }
        let current = try XCTUnwrap(scheduler.retryTimerForTesting)
        let before = attempts
        stale.fire()
        XCTAssertEqual(attempts, before)
        XCTAssertTrue(current.isValid)
        var control: RetainedControl? = RetainedControl()
        weak var owner = control
        scheduler.enqueue { [value = control!] in value.executions += 1; return false }
        control = nil
        XCTAssertNotNil(owner)
        scheduler.close()
        XCTAssertNil(owner)
        current.fire()
        XCTAssertEqual(attempts, before)
    }

    func testActualBlockedNativeWorkerBoundsHostQueueAndRecovers() async throws {
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let view = SchedulingView(frame: .zero, device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let source = MemoryRenderSource()
        let renderer = try MetalTerminalRenderer(view: view, source: source, nativeCallbackForTesting: { kind in
            guard kind == UInt32(CMDY_SESSION_READY) else { return }
            entered.signal()
            _ = resume.wait(timeout: .now() + 10)
        })
        let scheduler = try XCTUnwrap(renderer.scheduler)
        var didEnter = false
        for _ in 0..<1_000 {
            if entered.wait(timeout: .now()) == .success { didEnter = true; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        defer { resume.signal() }
        XCTAssertTrue(didEnter)
        // This is the actual Zig worker blocked in its callback, with the real
        // 1,024-ticket admission and notification path still in use.
        for _ in 0..<100_000 { scheduler.noteKeyboardInteraction() }
        XCTAssertEqual(scheduler.pendingCount, RendererScheduler.pendingLimit)
        XCTAssertGreaterThan(scheduler.rejectedControlCount, 98_000)
        XCTAssertNil(scheduler.retryTimerForTesting)
        renderer.smoothScrollEnabled = false
        renderer.invalidateRowCache()
        resume.signal()
        for _ in 0..<1_000 where scheduler.pendingCount > 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(scheduler.pendingCount, 0)
        let response = await renderer.synchronizeForTesting()
        XCTAssertFalse(try XCTUnwrap(response).config.smooth_scroll)
        await renderer.shutdown()
    }
}
