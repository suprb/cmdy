import Foundation
import XCTest
@testable import CmdyKit

@MainActor
final class FeedbackSteeringTests: XCTestCase {
    private func pane(id: String = "pane", staged: @escaping (String) -> Void) -> PluginPane {
        PluginPane(
            id: id,
            title: "agent",
            cwd: nil,
            pid: 1,
            tty: "ttys001",
            aiTool: "claude",
            type: { _ in },
            stage: staged,
            run: { _ in },
            focus: {},
            output: { _ in "" },
            scrollInfo: { [:] },
            scrollBy: { _ in },
            feed: { _ in })
    }

    func testFeedbackItemsStageSeparatelyAndReturnAdvancesQueue() {
        let manager = PluginManager()
        var staged: [String] = []
        let target = pane { staged.append($0) }
        manager.panesProvider = { [target] }

        let first = manager.enqueueFeedbackSteering(
            id: "one", prompt: "first annotation", in: target)
        let second = manager.enqueueFeedbackSteering(
            id: "two", prompt: "second annotation", in: target)

        XCTAssertEqual(first.delivery, "staged")
        XCTAssertEqual(second.delivery, "queued")
        XCTAssertEqual(second.position, 2)
        XCTAssertEqual(staged, ["first annotation"])
        XCTAssertEqual(manager.feedbackSteeringDepth(in: target.id), 2)

        XCTAssertTrue(manager.feedbackPromptDidSubmit(in: target.id, stageDelay: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(staged, ["first annotation", "second annotation"])
        XCTAssertEqual(manager.feedbackSteeringDepth(in: target.id), 1)

        XCTAssertTrue(manager.feedbackPromptDidSubmit(in: target.id, stageDelay: 0))
        XCTAssertEqual(manager.feedbackSteeringDepth(in: target.id), 0)
        XCTAssertFalse(manager.feedbackPromptDidSubmit(in: target.id, stageDelay: 0))
    }
}
