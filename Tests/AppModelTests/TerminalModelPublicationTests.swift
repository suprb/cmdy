import Foundation
import XCTest
@_spi(CmdyApp) import CmdyCore
@testable import ModelProbe

@MainActor
private final class PublicationObserver: TerminalModelObserver {
    struct Event {
        let snapshot: CoreTerminalSnapshot
        let damage: SnapshotPublicationDamage
    }
    var events: [Event] = []
    var onPublication: (() -> Void)?
    private(set) var depth = 0
    private(set) var greatestDepth = 0

    #if BASELINE
    func terminalModel(_ model: TerminalModel, didPublish snapshot: CoreTerminalSnapshot) {
        receive(snapshot, damage: .init(rows: snapshot.dirtyRows))
    }
    #else
    func terminalModel(_ model: TerminalModel, didPublish snapshot: CoreTerminalSnapshot,
                       damage: SnapshotPublicationDamage) {
        receive(snapshot, damage: damage)
    }
    #endif

    private func receive(_ snapshot: CoreTerminalSnapshot, damage: SnapshotPublicationDamage) {
        depth += 1
        greatestDepth = max(greatestDepth, depth)
        defer { depth -= 1 }
        events.append(Event(snapshot: snapshot, damage: damage))
        onPublication?()
    }

    func terminalModel(_ model: TerminalModel, didSetTitle title: String) {}
    func terminalModel(_ model: TerminalModel, didSetCurrentDirectory directory: String?) {}
    func terminalModelDidBell(_ model: TerminalModel) {}
    func terminalModel(_ model: TerminalModel, didRequestNotification title: String, body: String) {}
    func terminalModel(_ model: TerminalModel, didRequestClipboardCopy content: Data) {}
    func terminalModel(_ model: TerminalModel, didSend data: [UInt8]) {}
    func terminalModel(_ model: TerminalModel, processTerminated exitCode: Int32?) {}
}

final class TerminalModelPublicationTests: XCTestCase {
    private final class RenderReceipts: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(UInt64, UInt64, Bool)] = []
        var accepts = true // Changed only across synchronous model queue barriers.
        func receive(_ snapshot: CoreTerminalSnapshot, _ generation: UInt64) -> Bool {
            lock.lock(); defer { lock.unlock() }
            values.append((snapshot.modelPublicationGeneration, generation + 1, Thread.isMainThread))
            return accepts
        }
        var captured: [(UInt64, UInt64, Bool)] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }

    @MainActor
    func testRendererReceivesWorkerUpdatesWhileMainDeliveryIsBlocked() throws {
        let model = TerminalModel(cols: 20, rows: 4)
        let observer = PublicationObserver()
        model.observer = observer
        let receipts = RenderReceipts()
        model.setRenderPublication { snapshot, generation in
            // Taking the public snapshot lock from the callback must be safe.
            _ = model.snapshot
            return receipts.receive(snapshot, generation)
        }
        defer { model.setRenderPublication(nil) }
        let done = DispatchSemaphore(value: 0)
        model.afterWorkerTurnForTesting {
            for i in 0..<40 {
                model.feed(text: "\u{1B}[1;1H\(i)")
                model.captureForTesting()
            }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        let captured = receipts.captured
        XCTAssertEqual(captured.count, 41)
        XCTAssertTrue(captured.allSatisfy { $0.0 == $0.1 })
        XCTAssertEqual(captured.map(\.0), Array(1...41).map(UInt64.init))
        XCTAssertTrue(captured.dropFirst().allSatisfy { !$0.2 })
        XCTAssertTrue(observer.events.isEmpty)
        XCTAssertTrue(model.wasPublishedToRenderer(model.snapshot))
        XCTAssertEqual(model.snapshot.line(absolute: 0)?.cells[0].scalar, 51)
    }

    @MainActor
    func testRejectedPublicationAndReplacedRendererRequireHostFallback() {
        let model = TerminalModel(cols: 20, rows: 4)
        let receipts = RenderReceipts()
        model.setRenderPublication { receipts.receive($0, $1) }
        XCTAssertTrue(model.wasPublishedToRenderer(model.snapshot))
        receipts.accepts = false
        model.feed(text: "A")
        model.captureForTesting()
        XCTAssertFalse(model.wasPublishedToRenderer(model.snapshot))
        receipts.accepts = true
        let resized = model.resize(cols: 21, rows: 5, pixelWidth: 168, pixelHeight: 40)
        XCTAssertTrue(model.wasPublishedToRenderer(resized))
        XCTAssertEqual(receipts.captured.last?.0, resized.modelPublicationGeneration)
        model.setRenderPublication { _, _ in false }
        XCTAssertFalse(model.wasPublishedToRenderer(model.snapshot), "the new renderer has not accepted the old renderer's contents")
        model.setRenderPublication(nil)
        XCTAssertFalse(model.wasPublishedToRenderer(model.snapshot))
    }

    @MainActor
    func testTerminateReleasesRendererSinkAndClearsItsAcceptance() {
        let model = TerminalModel(cols: 20, rows: 4)
        weak var released: RenderReceipts?
        do {
            let receipts = RenderReceipts()
            released = receipts
            model.setRenderPublication { receipts.receive($0, $1) }
        }
        XCTAssertNotNil(released)
        model.terminate()
        XCTAssertNil(released)
        XCTAssertFalse(model.wasPublishedToRenderer(model.snapshot))
    }

    @MainActor
    func testSynchronousScrollWaitsForHostViewportAndAnimationCapture() throws {
        let model = TerminalModel(cols: 20, rows: 4)
        model.feed(text: (0..<30).map { "row-\($0)\r\n" }.joined())
        model.captureForTesting()
        let receipts = RenderReceipts()
        model.setRenderPublication { receipts.receive($0, $1) }
        defer { model.setRenderPublication(nil) }
        let count = receipts.captured.count
        let absolute = model.scrollViewport(to: 0)
        XCTAssertEqual(absolute.after, 0)
        XCTAssertNotNil(absolute.snapshot)
        XCTAssertEqual(receipts.captured.count, count, "scroll must not race ahead of its main-actor animation control")
        XCTAssertFalse(model.wasPublishedToRenderer(try XCTUnwrap(absolute.snapshot)))
        let relative = model.scrollViewport(lines: 3)
        XCTAssertEqual(relative.after, 3)
        XCTAssertEqual(receipts.captured.count, count)
        XCTAssertFalse(model.wasPublishedToRenderer(try XCTUnwrap(relative.snapshot)))
        // Ordinary parser publications still use the worker-owned fast path.
        model.feed(text: "next")
        model.captureForTesting()
        XCTAssertGreaterThan(receipts.captured.count, count)
        XCTAssertTrue(model.wasPublishedToRenderer(model.snapshot))
    }

    @MainActor
    private func drainMain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    private func preparedModel(cols: Int = 20, rows: Int = 20) -> TerminalModel {
        let model = TerminalModel(cols: cols, rows: rows)
        model.feed(text: "\u{1B}[11;1H")
        model.captureForTesting()
        return model
    }

    /// The production e7d model fails the row-0 assertion: the second capture
    /// replaces the first callback after the first capture consumed its damage.
    @MainActor
    func testDisjointDamageSurvivesReplacingAnUndeliveredSnapshot() async throws {
        let model = preparedModel()
        let observer = PublicationObserver()
        model.observer = observer
        model.feed(text: "\u{1B}[1;1HA\u{1B}[11;1H")
        model.captureForTesting()
        model.feed(text: "\u{1B}[16;1HB\u{1B}[11;1H")
        model.captureForTesting()
        XCTAssertTrue(observer.events.isEmpty, "worker captures must not deliver inline")
        await drainMain()
        let event = try XCTUnwrap(observer.events.last)
        XCTAssertEqual(observer.events.count, 1, "one callback owns the newest pending value")
        XCTAssertEqual(event.snapshot.line(absolute: 0)?.cells[0].scalar, 65)
        XCTAssertEqual(event.snapshot.line(absolute: 15)?.cells[0].scalar, 66)
        XCTAssertTrue(event.damage.rows?.contains(0) == true, "the first capture's damage must survive")
        XCTAssertTrue(event.damage.rows?.contains(15) == true)
        XCTAssertFalse(event.damage.invalidatesAllRows, "stable coordinates only need merged rows")
    }

    @MainActor
    func testMainTurnDeliversOnlyNewestSnapshotIncludingModesAndUnicode() async throws {
        let model = preparedModel()
        let observer = PublicationObserver()
        model.observer = observer
        for index in 0..<40 {
            model.feed(text: "\u{1B}[1;1H\(index)")
            model.captureForTesting()
        }
        model.feed(text: "\u{1B}[?2004h\u{1B}[2;1H\u{1B}[31m界e\u{301}")
        model.captureForTesting()
        await drainMain()
        let event = try XCTUnwrap(observer.events.first)
        XCTAssertEqual(observer.events.count, 1)
        XCTAssertTrue(event.snapshot.bracketedPaste)
        XCTAssertEqual(event.snapshot.line(absolute: 1)?.cells[0].text, "界")
        XCTAssertEqual(event.snapshot.line(absolute: 1)?.cells[0].attribute.fg, .ansi256(1))
        XCTAssertEqual(event.snapshot.line(absolute: 1)?.cells[2].text, "e\u{301}")
    }

    @MainActor
    func testResizeSupersedesPendingCallbackAndLaterCaptureKeepsNewDimensions() async throws {
        let model = preparedModel()
        let observer = PublicationObserver()
        model.observer = observer
        model.feed(text: "old geometry")
        model.captureForTesting()
        let resized = model.resize(cols: 32, rows: 12, pixelWidth: 640, pixelHeight: 240)
        XCTAssertEqual(resized.grid.cols, 32)
        await drainMain()
        XCTAssertTrue(observer.events.allSatisfy {
            $0.snapshot.grid.cols == 32 && $0.snapshot.grid.rows == 12
        }, "pre-resize callback must not replace the installed resize with old dimensions")
        observer.events.removeAll()
        model.feed(text: "\u{1B}[1;1Hnew")
        model.captureForTesting()
        await drainMain()
        XCTAssertEqual(observer.events.count, 1)
        XCTAssertEqual(observer.events.last?.snapshot.grid.cols, 32)
        XCTAssertEqual(observer.events.last?.snapshot.grid.rows, 12)
    }

    #if !BASELINE
    @MainActor
    func testScrollTransfersUndeliveredDamageWithoutClearingStableRowCaches() async throws {
        let model = TerminalModel(cols: 20, rows: 4)
        model.feed(text: (0..<12).map { "line\($0)\r\n" }.joined())
        model.captureForTesting()
        let observer = PublicationObserver()
        model.observer = observer
        model.feed(text: "\u{1B}[1;1HX")
        model.captureForTesting()
        let changedRow = model.snapshot.grid.liveTopRow
        let update = model.scrollViewport(to: 0)
        XCTAssertNotEqual(update.after, update.before)
        XCTAssertNotNil(update.snapshot)
        XCTAssertTrue(update.damage?.rows?.contains(changedRow) == true)
        XCTAssertFalse(try XCTUnwrap(update.damage).invalidatesAllRows)
        await drainMain()
        XCTAssertTrue(observer.events.isEmpty)
        XCTAssertEqual(model.snapshot.grid.displayTopRow, update.after)
    }

    @MainActor
    func testObserverReplacementCannotReceiveOldPendingPacket() async throws {
        let model = preparedModel()
        let first = PublicationObserver()
        let second = PublicationObserver()
        model.observer = first
        model.feed(text: "A")
        model.captureForTesting()
        model.observer = nil
        model.observer = second
        await drainMain()
        XCTAssertTrue(first.events.isEmpty)
        XCTAssertTrue(second.events.isEmpty)
        model.feed(text: "B")
        model.captureForTesting()
        await drainMain()
        XCTAssertEqual(second.events.count, 1)
    }
    #endif

    @MainActor
    func testObserverProducingMoreOutputCannotReenterDelivery() async throws {
        let model = preparedModel()
        let observer = PublicationObserver()
        model.observer = observer
        observer.onPublication = {
            if observer.events.count == 1 {
                model.feed(text: "\u{1B}[2;1Hnext")
                model.captureForTesting()
                XCTAssertEqual(observer.events.count, 1)
            }
        }
        model.feed(text: "first")
        model.captureForTesting()
        await drainMain()
        await drainMain()
        XCTAssertEqual(observer.events.count, 2)
        XCTAssertEqual(observer.greatestDepth, 1)
        observer.onPublication = nil
    }
}
