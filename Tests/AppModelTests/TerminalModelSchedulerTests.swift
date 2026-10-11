import Foundation
import XCTest
@testable import ModelProbe

final class TerminalModelSchedulerTests: XCTestCase {
    private func drainWorker(_ model: TerminalModel) async {
        await withCheckedContinuation { continuation in
            model.afterWorkerTurnForTesting { continuation.resume() }
        }
    }

    func testPTYResponseCapturesAfterCompleteWorkerTurnExactlyOnce() async {
        let model = TerminalModel(cols: 20, rows: 4)
        model.captureForTesting()
        let before = model.workerStateForTesting.generation
        model.performWorkerTurnForTesting { model in
            model.sendUserInput([97])
            model.dataReceived(slice: Array("\u{1B}[1;1HA".utf8)[...])
            XCTAssertEqual(model.workerStateForTesting.kind, .immediate)
            XCTAssertEqual(model.workerStateForTesting.generation, before,
                           "capture must not reenter the parser or its delegates")
            model.dataReceived(slice: Array("\u{1B}[2;1HB".utf8)[...])
            XCTAssertEqual(model.workerStateForTesting.generation, before)
        }
        await drainWorker(model)
        XCTAssertEqual(model.workerStateForTesting.generation, before + 1)
        XCTAssertEqual(model.snapshot.line(absolute: 0)?.cells[0].scalar, 65)
        XCTAssertEqual(model.snapshot.line(absolute: 1)?.cells[0].scalar, 66)
        XCTAssertNil(model.workerStateForTesting.deadline)
    }

    func testHostFeedAndProtocolSendCannotCreateOrConsumeUserCredit() {
        let model = TerminalModel(cols: 20, rows: 4)
        model.performWorkerTurnForTesting { model in
            model.send([27, 91, 73]) // focus-report path, not committed user input
            XCTAssertNil(model.workerStateForTesting.deadline)
            model.sendUserInput([97])
            model.feed(text: "host annotation")
            XCTAssertEqual(model.workerStateForTesting.kind, .delayed)
            XCTAssertNotNil(model.workerStateForTesting.deadline)
            model.dataReceived(slice: Array("reply".utf8)[...])
            XCTAssertEqual(model.workerStateForTesting.kind, .immediate)
            XCTAssertNil(model.workerStateForTesting.deadline)
        }
    }

    func testFocusDetachResizeAndTerminateCancelUnusedCredit() {
        let model = TerminalModel(cols: 20, rows: 4)
        model.performWorkerTurnForTesting { model in
            model.sendUserInput([97])
            model.cancelKeyboardInteraction()
            XCTAssertNil(model.workerStateForTesting.deadline)
            model.dataReceived(slice: Array("late".utf8)[...])
            XCTAssertEqual(model.workerStateForTesting.kind, .delayed)
            model.sendUserInput([98])
            model.observer = nil
            XCTAssertNil(model.workerStateForTesting.deadline)
            model.sendUserInput([99])
            _ = model.resize(cols: 21, rows: 4, pixelWidth: 210, pixelHeight: 80)
            XCTAssertNil(model.workerStateForTesting.deadline)
            XCTAssertNil(model.workerStateForTesting.kind)
            model.sendUserInput([100])
            model.terminate() // unstarted process; no PTY or child is created
            XCTAssertNil(model.workerStateForTesting.deadline)
            XCTAssertNil(model.workerStateForTesting.kind)
            XCTAssertLessThanOrEqual(model.workerStateForTesting.services, 2)
        }
    }
}
