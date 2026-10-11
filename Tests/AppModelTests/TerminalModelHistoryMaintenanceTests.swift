import Foundation
import XCTest
@testable import ModelProbe

final class TerminalModelHistoryMaintenanceTests: XCTestCase {
    private func fill(_ model: TerminalModel, count: Int) {
        model.feed(text: (0..<count).map { "line-\($0)\r\n" }.joined())
    }

    private func waitForCompletion(_ model: TerminalModel) async throws {
        for _ in 0..<300 {
            let state = model.historyStateForTesting
            if !state.needsWork && !state.queued && !state.active { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Model history maintenance did not become idle")
    }

    func testActualModelCompactsHistoryWithoutPublishingAnotherFrame() async throws {
        let model = TerminalModel(cols: 80, rows: 4)
        model.performWorkerTurnForTesting { model in
            fill(model, count: 1000)
            XCTAssertTrue(model.materializeHistoryRowForTesting(0))
            model.captureForTesting()
            XCTAssertEqual(model.historyStateForTesting.cursor, 0)
            XCTAssertTrue(model.historyStateForTesting.needsWork)
            XCTAssertEqual(model.historyRowHasDenseCellsForTesting(0), true)
        }
        let published = model.snapshot
        let cells = published.lines.map(\.cells)
        let generation = model.workerStateForTesting.generation
        try await waitForCompletion(model)
        XCTAssertEqual(model.historyRowHasDenseCellsForTesting(0), false)
        XCTAssertGreaterThan(model.historyStateForTesting.cursor, 900)
        XCTAssertEqual(model.workerStateForTesting.generation, generation)
        XCTAssertEqual(published.lines.map(\.cells), cells)
        XCTAssertEqual(model.scrollbackLineText(row: 0), "line-0")
        XCTAssertEqual(model.scrollbackLineText(row: 999), "line-999")
    }

    func testResumedRichOutputAndViewportResizePreserveRetainedPublication() async throws {
        let model = TerminalModel(cols: 80, rows: 4)
        model.performWorkerTurnForTesting { model in
            fill(model, count: 300)
            XCTAssertTrue(model.materializeHistoryRowForTesting(0))
            XCTAssertEqual(model.historyRowHasDenseCellsForTesting(0), true)
        }
        try await waitForCompletion(model)
        XCTAssertEqual(model.historyRowHasDenseCellsForTesting(0), false)
        var retained = model.snapshot
        model.performWorkerTurnForTesting { model in
            let update = model.scrollViewport(to: 0)
            retained = update.snapshot ?? model.snapshot
            XCTAssertEqual(model.historyStateForTesting.cursor, 0)
            XCTAssertTrue(model.historyStateForTesting.needsWork)
        }
        let expected = retained.lines.map(\.cells)
        _ = model.scrollViewport(to: 10_000)
        model.sendUserInput([97]) // Unstarted transport; no child or PTY is created.
        model.feed(text: "\u{1b}[31mé🧑‍💻\u{1b}[0m\r\n")
        _ = model.resize(cols: 40, rows: 6, pixelWidth: 400, pixelHeight: 120)
        try await waitForCompletion(model)
        XCTAssertEqual(retained.lines.map(\.cells), expected)
        XCTAssertTrue(model.scrollbackText().contains("é🧑‍💻"))
        XCTAssertEqual(model.coreGrid.cols, 40)
        XCTAssertEqual(model.coreGrid.rows, 6)
    }

    func testTerminationSuppressesAlreadyQueuedNativeMaintenance() async throws {
        let model = TerminalModel(cols: 80, rows: 4)
        model.performWorkerTurnForTesting { model in
            fill(model, count: 300)
            XCTAssertTrue(model.materializeHistoryRowForTesting(0))
            XCTAssertEqual(model.historyRowHasDenseCellsForTesting(0), true)
            XCTAssertTrue(model.historyStateForTesting.queued)
            model.terminate()
            XCTAssertFalse(model.historyStateForTesting.enabled)
            XCTAssertFalse(model.historyStateForTesting.needsWork)
        }
        try await waitForCompletion(model)
        XCTAssertEqual(model.historyStateForTesting.cursor, 0)
        XCTAssertEqual(model.historyRowHasDenseCellsForTesting(0), true)
        XCTAssertFalse(model.historyStateForTesting.queued)
    }

    func testQueuedMaintenanceDoesNotKeepAnUnobservedModelAlive() async throws {
        var model: TerminalModel? = TerminalModel(cols: 80, rows: 4)
        weak var observed = model
        fill(model!, count: 300)
        model = nil
        for _ in 0..<100 {
            if observed == nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(observed)
    }
}
