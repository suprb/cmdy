import AppKit
import MetalKit
import XCTest
@_spi(CmdyApp) @testable import CmdyGPU

@MainActor
final class KeyboardFeedbackSchedulingTests: XCTestCase {
    func testPublicationReplacesKeyboardFallbackWithoutDrawingOldSnapshot() async throws {
        let f = try await HeadlessSchedulingFixture(), r = try XCTUnwrap(f.renderer)
        let now = ProcessInfo.processInfo.systemUptime
        r.cancelScrollAnimation(); r.noteKeyboardInteraction(at: now); await f.flushOwner()
        XCTAssertEqual(f.view.drawRequests, 0); XCTAssertEqual(f.view.captureRequests, 0)
        let timer = try XCTUnwrap(r.keyboardFeedbackTimerForTesting)
        // The echo gets three frame intervals before cursor-only feedback
        // (render_schedule.zig keyboard_feedback_frames).
        XCTAssertEqual(try XCTUnwrap(r.keyboardFeedbackDeadlineForTesting) - now,
                       3 / max(1, f.interactiveFPS), accuracy: 0.000_001)
        r.noteActivity(); await f.flushOwner()
        XCTAssertNil(r.keyboardFeedbackDeadlineForTesting); XCTAssertNil(r.keyboardFeedbackTimerForTesting)
        XCTAssertFalse(timer.isValid); XCTAssertFalse(r.animationTimerIsActiveForTesting)
        XCTAssertEqual(f.source.captureCount, 0)
        await f.drainServices()
        XCTAssertEqual(f.view.captureRequests, 1); XCTAssertEqual(f.view.drawRequests, 0)
    }

    func testNoEchoFiresOnceAndFurtherKeysCannotPostponeTheDeadline() async throws {
        let f = try await HeadlessSchedulingFixture(), r = try XCTUnwrap(f.renderer)
        let now = ProcessInfo.processInfo.systemUptime
        r.noteKeyboardInteraction(at: now); await f.flushOwner()
        let timer = try XCTUnwrap(r.keyboardFeedbackTimerForTesting)
        let deadline = try XCTUnwrap(r.keyboardFeedbackDeadlineForTesting)
        for index in 1...5 {
            r.noteKeyboardInteraction(at: now + Double(index) * 0.0001); await f.flushOwner()
            XCTAssertTrue(r.keyboardFeedbackTimerForTesting === timer)
            XCTAssertEqual(r.keyboardFeedbackDeadlineForTesting, deadline)
            XCTAssertEqual(r.keyboardResponseDeadlineForTesting, now + Double(index) * 0.0001 + 0.15)
        }
        timer.fire(); await f.flushOwner()
        XCTAssertFalse(timer.isValid); XCTAssertNil(r.keyboardFeedbackTimerForTesting)
        XCTAssertNil(r.keyboardFeedbackDeadlineForTesting); XCTAssertFalse(r.animationTimerIsActiveForTesting)
        XCTAssertEqual(f.view.drawRequests, 0)
        await f.drainServices(); XCTAssertEqual(f.view.captureRequests, 1)
        await f.drainServices(); XCTAssertEqual(f.view.captureRequests, 1)
    }

    func testLatePublicationAfterFallbackKeepsOneDeferredInteractiveRequest() async throws {
        let f = try await HeadlessSchedulingFixture(), r = try XCTUnwrap(f.renderer)
        r.noteKeyboardInteraction(); await f.flushOwner()
        let deadline = try XCTUnwrap(r.keyboardResponseDeadlineForTesting)
        try XCTUnwrap(r.keyboardFeedbackTimerForTesting).fire(); await f.flushOwner()
        let fallback = r.interactiveDrawGenerationForTesting
        XCTAssertEqual(r.keyboardResponseDeadlineForTesting, deadline)
        r.noteActivity(); await f.flushOwner()
        XCTAssertEqual(r.interactiveDrawGenerationForTesting, fallback &+ 1)
        XCTAssertNil(r.keyboardResponseDeadlineForTesting)
        let response = r.interactiveDrawGenerationForTesting
        r.noteActivity(); await f.flushOwner()
        XCTAssertEqual(r.interactiveDrawGenerationForTesting, response)
        XCTAssertEqual(f.view.captureRequests, 0)
        await f.drainServices(); XCTAssertEqual(f.view.captureRequests, 1)
        await f.drainServices(); XCTAssertEqual(f.view.captureRequests, 1)
        XCTAssertNil(r.keyboardFeedbackTimerForTesting); XCTAssertFalse(r.animationTimerIsActiveForTesting)
    }

    func testLateResponseEligibilityExpiresWithoutAnExpiryTimerOrRenewal() async throws {
        let f = try await HeadlessSchedulingFixture(), r = try XCTUnwrap(f.renderer)
        r.noteKeyboardInteraction(at: ProcessInfo.processInfo.systemUptime - 0.151); await f.flushOwner()
        try XCTUnwrap(r.keyboardFeedbackTimerForTesting).fire(); await f.flushOwner()
        let generation = r.interactiveDrawGenerationForTesting
        r.noteActivity(); await f.flushOwner()
        XCTAssertEqual(r.interactiveDrawGenerationForTesting, generation)
        XCTAssertNil(r.keyboardResponseDeadlineForTesting); XCTAssertNil(r.keyboardFeedbackTimerForTesting)
        XCTAssertFalse(r.animationTimerIsActiveForTesting)
        await f.drainServices(); let serviced = f.view.captureRequests
        await f.drainServices(); XCTAssertEqual(f.view.captureRequests, serviced)
    }

    func testHidingFallbackServiceCancelsLateResponseEligibility() async throws {
        let f = try await HeadlessSchedulingFixture(), r = try XCTUnwrap(f.renderer)
        r.noteKeyboardInteraction(); await f.flushOwner()
        try XCTUnwrap(r.keyboardFeedbackTimerForTesting).fire(); await f.flushOwner()
        f.view.isHidden = true; await f.drainServices()
        XCTAssertNil(r.keyboardResponseDeadlineForTesting); XCTAssertNil(r.keyboardFeedbackTimerForTesting)
        XCTAssertEqual(f.view.captureRequests, 0)
        let generation = r.interactiveDrawGenerationForTesting
        f.view.isHidden = false; r.noteActivity(); await f.flushOwner()
        XCTAssertEqual(r.interactiveDrawGenerationForTesting, generation)
        XCTAssertEqual(f.view.drawRequests, 1)
        await f.drainServices(); XCTAssertEqual(f.view.captureRequests, 0)
        XCTAssertFalse(r.animationTimerIsActiveForTesting)
    }

    func testFocusCancellationPreservesQueuedFramesButCannotLeakIntoRegainedFocus() async throws {
        let f = try await HeadlessSchedulingFixture(), r = try XCTUnwrap(f.renderer)
        r.noteKeyboardInteraction(); await f.flushOwner()
        let deadline = try XCTUnwrap(r.keyboardResponseDeadlineForTesting)
        try XCTUnwrap(r.keyboardFeedbackTimerForTesting).fire(); await f.flushOwner()
        let fallback = r.interactiveDrawGenerationForTesting, activity = r.cursorActivityTimeForTesting
        r.cancelKeyboardInteraction(); await f.flushOwner()
        XCTAssertNil(r.keyboardResponseDeadlineForTesting); XCTAssertNil(r.keyboardFeedbackTimerForTesting)
        XCTAssertEqual(r.interactiveDrawGenerationForTesting, fallback)
        XCTAssertEqual(r.cursorActivityTimeForTesting, activity)
        r.noteActivity(); r.noteActivity(); await f.flushOwner()
        XCTAssertEqual(r.interactiveDrawGenerationForTesting, fallback)
        await f.drainServices(); XCTAssertEqual(f.view.captureRequests, 1)
        r.noteKeyboardInteraction(); await f.flushOwner()
        XCTAssertGreaterThan(try XCTUnwrap(r.keyboardResponseDeadlineForTesting), deadline)
        r.noteActivity(); await f.flushOwner()
        XCTAssertEqual(r.interactiveDrawGenerationForTesting, fallback &+ 1)
        await f.drainServices(); XCTAssertEqual(f.view.captureRequests, 2)
        XCTAssertNil(r.keyboardResponseDeadlineForTesting); XCTAssertNil(r.keyboardFeedbackTimerForTesting)
        XCTAssertFalse(r.animationTimerIsActiveForTesting)
    }

    func testFocusLossBeforeFallbackCancelsFeedbackAndLeavesLateOutputOrdinary() async throws {
        let f = try await HeadlessSchedulingFixture(), r = try XCTUnwrap(f.renderer)
        r.noteKeyboardInteraction(); await f.flushOwner()
        let timer = try XCTUnwrap(r.keyboardFeedbackTimerForTesting)
        let generation = r.interactiveDrawGenerationForTesting
        r.cancelKeyboardInteraction(); r.noteActivity(); await f.flushOwner()
        XCTAssertFalse(timer.isValid); XCTAssertNil(r.keyboardResponseDeadlineForTesting)
        XCTAssertNil(r.keyboardFeedbackTimerForTesting)
        XCTAssertEqual(r.interactiveDrawGenerationForTesting, generation)
        XCTAssertEqual(f.view.drawRequests, 1)
        await f.drainServices(); XCTAssertEqual(f.view.captureRequests, 0)
        XCTAssertFalse(r.animationTimerIsActiveForTesting)
    }

    func testHiddenAndDetachedViewsCancelFeedbackWithoutStartingAnotherTimer() async throws {
        let f = try await HeadlessSchedulingFixture(), r = try XCTUnwrap(f.renderer)
        r.noteKeyboardInteraction(); await f.flushOwner()
        let hiddenTimer = try XCTUnwrap(r.keyboardFeedbackTimerForTesting)
        f.view.isHidden = true; r.draw(in: f.view); await f.flushOwner()
        XCTAssertFalse(hiddenTimer.isValid); XCTAssertNil(r.keyboardFeedbackTimerForTesting)
        XCTAssertNil(r.keyboardResponseDeadlineForTesting)
        r.noteKeyboardInteraction(); await f.flushOwner()
        XCTAssertNil(r.keyboardFeedbackTimerForTesting); XCTAssertEqual(f.source.captureCount, 0)
        f.view.isHidden = false; r.noteKeyboardInteraction(); await f.flushOwner()
        let detachedTimer = try XCTUnwrap(r.keyboardFeedbackTimerForTesting)
        f.environment.attached = false; r.noteKeyboardInteraction(); await f.flushOwner()
        XCTAssertFalse(detachedTimer.isValid); XCTAssertNil(r.keyboardFeedbackTimerForTesting)
        XCTAssertNil(r.keyboardResponseDeadlineForTesting)
    }

    func testFeedbackTimerDoesNotRetainRendererAndIsInvalidatedOnRelease() async throws {
        let f = try await HeadlessSchedulingFixture()
        f.renderer?.noteKeyboardInteraction(); await f.flushOwner()
        let timer = try XCTUnwrap(f.renderer?.keyboardFeedbackTimerForTesting)
        weak let renderer = f.renderer
        f.renderer = nil
        XCTAssertNil(renderer); XCTAssertFalse(timer.isValid)
    }

    func testActiveScrollCancellationStillRequestsItsImmediateResetFrame() async throws {
        let f = try await HeadlessSchedulingFixture(), r = try XCTUnwrap(f.renderer)
        r.smoothScrollEnabled = true; await f.flushOwner()
        var offsets: [CGFloat] = []; r.onScrollOffsetChanged = { offsets.append($0) }
        r.setScrollHeld(8); await f.flushOwner(); f.view.drawRequests = 0
        r.cancelScrollAnimation(); await f.flushOwner()
        XCTAssertEqual(f.view.drawRequests, 1); XCTAssertEqual(offsets, [0])
        r.cancelScrollAnimation(); await f.flushOwner()
        XCTAssertEqual(f.view.drawRequests, 1); XCTAssertEqual(offsets, [0, 0])
        // Two notches form a continuing, eased scroll; a lone notch has no glide to reset.
        r.noteScroll(pixels: 0); r.noteScroll(pixels: 12); await f.flushOwner(); f.view.drawRequests = 0
        r.cancelScrollAnimation(); await f.flushOwner()
        XCTAssertEqual(f.view.drawRequests, 1); XCTAssertFalse(r.animationTimerIsActiveForTesting)
    }

    func testUnbuildableFrameDoesNotConsumeNoEchoFallback() async throws {
        let f = try await HeadlessSchedulingFixture(), r = try XCTUnwrap(f.renderer)
        r.noteKeyboardInteraction(); await f.flushOwner()
        let timer = try XCTUnwrap(r.keyboardFeedbackTimerForTesting)
        r.draw(in: f.view); await f.flushOwner()
        XCTAssertEqual(f.source.captureCount, 1)
        XCTAssertTrue(timer.isValid); XCTAssertTrue(r.keyboardFeedbackTimerForTesting === timer)
        timer.fire(); await f.drainServices()
        XCTAssertEqual(f.view.captureRequests, 2); XCTAssertEqual(f.view.drawRequests, 0)
    }

    func testPublicationsCoalesceUntilTheCurrentSourceCanBeDrawn() async throws {
        let f = try await HeadlessSchedulingFixture(), r = try XCTUnwrap(f.renderer)
        var current = 0, drawn: [Int] = []
        f.view.onCapture = { drawn.append(current) }
        r.noteKeyboardInteraction()
        for snapshot in 1...20 { current = snapshot; r.noteActivity() }
        await f.flushOwner()
        XCTAssertEqual(f.view.captureRequests, 0); XCTAssertEqual(f.view.drawRequests, 0)
        await f.drainServices(); XCTAssertEqual(drawn, [20])
        await f.drainServices(); XCTAssertEqual(f.view.captureRequests, 1)
        XCTAssertFalse(r.animationTimerIsActiveForTesting)
    }

    func testManualServiceDoesNotRecursivelyDrawForReentrantActivity() async throws {
        let f = try await HeadlessSchedulingFixture(), r = try XCTUnwrap(f.renderer)
        var depth = 0, maximumDepth = 0
        f.view.onCapture = { [weak r, weak view = f.view] in
            depth += 1; maximumDepth = max(maximumDepth, depth)
            if view?.captureRequests == 1 { r?.noteKeyboardInteraction(); r?.noteActivity() }
            depth -= 1
        }
        r.noteKeyboardInteraction(); r.noteActivity(); await f.drainServices()
        XCTAssertEqual(f.view.captureRequests, 2); XCTAssertEqual(maximumDepth, 1)
        await f.drainServices(); XCTAssertEqual(f.view.captureRequests, 2)
    }

    func testHiddenQueuedServiceIsCancelledAndDoesNotRestartOnItsOwn() async throws {
        let f = try await HeadlessSchedulingFixture(), r = try XCTUnwrap(f.renderer)
        r.noteKeyboardInteraction(); r.noteActivity(); await f.flushOwner()
        f.view.isHidden = true; await f.drainServices(); XCTAssertEqual(f.view.captureRequests, 0)
        f.view.isHidden = false; await f.drainServices(); XCTAssertEqual(f.view.captureRequests, 0)
        r.noteKeyboardInteraction(); r.noteActivity(); await f.drainServices()
        XCTAssertEqual(f.view.captureRequests, 1)
    }

    func testOrdinaryOutputKeepsAppKitScheduling() async throws {
        let f = try await HeadlessSchedulingFixture(), r = try XCTUnwrap(f.renderer)
        r.noteActivity(); await f.flushOwner(); XCTAssertEqual(f.view.drawRequests, 1)
        await f.drainServices(); XCTAssertEqual(f.view.captureRequests, 0)
        XCTAssertFalse(r.animationTimerIsActiveForTesting)
    }

    func testPacedManualRetryDoesNotTurnAnUnbuildableFrameIntoAnIdleLoop() async throws {
        let f = try await HeadlessSchedulingFixture(), r = try XCTUnwrap(f.renderer)
        r.draw(in: f.view); await f.flushOwner(); XCTAssertEqual(f.source.captureCount, 1)
        // Use actual main-run-loop timers for the pacing/idle behavior check.
        r.scheduler.timerInstallerForTesting = nil
        r.noteKeyboardInteraction(); r.noteActivity(); await f.drainServices()
        try await Task.sleep(for: .milliseconds(120)); await f.drainServices()
        XCTAssertEqual(f.source.captureCount, 2); XCTAssertEqual(f.view.captureRequests, 2)
        try await Task.sleep(for: .milliseconds(100)); await f.drainServices()
        XCTAssertEqual(f.source.captureCount, 2); XCTAssertEqual(f.view.captureRequests, 2)
        XCTAssertFalse(r.animationTimerIsActiveForTesting)
    }

    func testQueuedServiceDoesNotRetainTheRenderer() async throws {
        let f = try await HeadlessSchedulingFixture()
        f.renderer?.noteKeyboardInteraction(); f.renderer?.noteActivity(); await f.flushOwner()
        XCTAssertFalse(f.services.pending.isEmpty)
        weak let renderer = f.renderer; f.renderer = nil
        XCTAssertNil(renderer)
        await f.drainServices(); XCTAssertEqual(f.view.captureRequests, 0)
    }

    func testReplacedKeyboardTimerCannotFireIntoItsSuccessor() async throws {
        let f = try await HeadlessSchedulingFixture(), r = try XCTUnwrap(f.renderer)
        r.noteKeyboardInteraction(); await f.flushOwner()
        let stale = try XCTUnwrap(r.keyboardFeedbackTimerForTesting)
        r.cancelKeyboardInteraction(); r.noteKeyboardInteraction(); await f.flushOwner()
        let current = try XCTUnwrap(r.keyboardFeedbackTimerForTesting)
        let deadline = r.keyboardFeedbackDeadlineForTesting
        XCTAssertFalse(stale === current); XCTAssertFalse(stale.isValid)
        stale.fire(); await f.flushOwner()
        XCTAssertTrue(r.keyboardFeedbackTimerForTesting === current)
        XCTAssertEqual(r.keyboardFeedbackDeadlineForTesting, deadline)
        XCTAssertEqual(f.view.captureRequests, 0)
    }
}
