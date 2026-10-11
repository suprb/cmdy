import AppKit
import XCTest
@_spi(CmdyApp) @testable import CmdyGPU

@MainActor
final class InputActivitySchedulingTests: XCTestCase {
    func testTelemetryKeepsPublicationAndDoesNotScheduleOldContent() async throws {
        let f = try await HeadlessSchedulingFixture(), r = try XCTUnwrap(f.renderer)
        let beforeReply = await r.synchronizeForTesting()
        let before = try XCTUnwrap(beforeReply)
        for value in 1...32 {
            r.updateInputActivity(keypressTime: CFAbsoluteTimeGetCurrent(), typingRate: Float(value))
        }
        await f.flushOwner()
        let afterReply = await r.synchronizeForTesting()
        let after = try XCTUnwrap(afterReply)
        XCTAssertEqual(after.source_revision, before.source_revision)
        XCTAssertEqual(after.identity.epoch, before.identity.epoch)
        XCTAssertEqual(after.inspection.interactive_generation, before.inspection.interactive_generation)
        XCTAssertEqual(f.view.drawRequests, 0)
        XCTAssertEqual(f.view.captureRequests, 0)
        XCTAssertTrue(f.services.pending.isEmpty)
        XCTAssertNil(r.keyboardFeedbackTimerForTesting)
        XCTAssertFalse(r.animationTimerIsActiveForTesting)
    }

    func testTelemetryPreservesKeyboardFeedbackAndResponseEligibility() async throws {
        let f = try await HeadlessSchedulingFixture(), r = try XCTUnwrap(f.renderer)
        r.noteKeyboardInteraction(); await f.flushOwner()
        let feedback = r.keyboardFeedbackDeadlineForTesting
        let response = r.keyboardResponseDeadlineForTesting
        let timer = try XCTUnwrap(r.keyboardFeedbackTimerForTesting)
        r.updateInputActivity(keypressTime: CFAbsoluteTimeGetCurrent() - 0.25, typingRate: 4.5)
        await f.flushOwner()
        XCTAssertTrue(r.keyboardFeedbackTimerForTesting === timer)
        XCTAssertEqual(r.keyboardFeedbackDeadlineForTesting, feedback)
        XCTAssertEqual(r.keyboardResponseDeadlineForTesting, response)
        XCTAssertEqual(f.view.drawRequests, 0)
        r.noteActivity(); await f.drainServices()
        XCTAssertFalse(timer.isValid)
        XCTAssertEqual(f.view.captureRequests, 1)
    }

    func testInvalidTelemetryAndUpdatesAfterCloseDoNotQueueWork() async throws {
        let f = try await HeadlessSchedulingFixture(), r = try XCTUnwrap(f.renderer)
        r.updateInputActivity(keypressTime: .nan, typingRate: 1)
        r.updateInputActivity(keypressTime: 1, typingRate: .infinity)
        r.updateInputActivity(keypressTime: 1, typingRate: -1)
        await f.flushOwner()
        XCTAssertEqual(f.view.drawRequests, 0)
        XCTAssertEqual(f.view.captureRequests, 0)
        r.close()
        r.updateInputActivity(keypressTime: CFAbsoluteTimeGetCurrent(), typingRate: 1)
        XCTAssertTrue(f.services.pending.isEmpty)
    }
}
