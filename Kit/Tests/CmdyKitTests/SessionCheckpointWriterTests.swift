import Foundation
import XCTest
@testable import CmdyKit

final class SessionCheckpointWriterTests: XCTestCase {
    func testBusyWriterKeepsOnlyNewestPendingCheckpointAndFlushesIt() throws {
        let began = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let captured = NSLock()
        var values: [String] = []
        var didBlock = false
        var allOffMain = true
        let writer = SessionCheckpointWriter(writer: { data in
            captured.lock()
            let shouldBlock = !didBlock
            didBlock = true
            allOffMain = allOffMain && !Thread.isMainThread
            captured.unlock()
            if shouldBlock {
                began.signal()
                guard release.wait(timeout: .now() + 5) == .success else {
                    throw CocoaError(.userCancelled)
                }
            }
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let windows = try XCTUnwrap(root["windows"] as? [[String: Any]])
            captured.lock()
            values.append(windows.first?["cwd"] as? String ?? "")
            captured.unlock()
        })
        writer.submit(layouts: [["type": "pane", "cwd": "first"]])
        XCTAssertEqual(began.wait(timeout: .now() + 3), .success)
        for index in 0..<100 {
            writer.submit(layouts: [["type": "pane", "cwd": "pending-\(index)"]])
        }
        release.signal()
        try writer.flush(layouts: [["type": "pane", "cwd": "final"]])
        captured.lock()
        let saved = values
        let offMain = allOffMain
        captured.unlock()
        XCTAssertEqual(saved.first, "first")
        XCTAssertEqual(saved.last, "final")
        XCTAssertLessThanOrEqual(saved.count, 3)
        XCTAssertTrue(offMain)
    }

    func testIdenticalCheckpointsDoNotRotateTheGoodBackup() throws {
        var writes = 0
        let writer = SessionCheckpointWriter(writer: { _ in writes += 1 })
        try writer.flush(layouts: [["type": "pane", "cwd": "/tmp"]])
        try writer.flush(layouts: [["cwd": "/tmp", "type": "pane"]])
        XCTAssertEqual(writes, 1)
    }

    func testWriteFailureRetriesAndFinalFlushReportsFailure() throws {
        enum Failure: Error { case interrupted }
        var fail = true
        let writer = SessionCheckpointWriter(writer: { _ in
            if fail { throw Failure.interrupted }
        })
        XCTAssertThrowsError(try writer.flush(layouts: [["type": "pane", "cwd": "/tmp"]]))
        fail = false
        XCTAssertNoThrow(try writer.flush(layouts: [["type": "pane", "cwd": "/tmp"]]))
    }

    func testDebounceHasMaximumDelayAndResetsAfterCapture() {
        var schedule = SessionCheckpointSchedule(debounce: 2, maximumDelay: 10)
        XCTAssertEqual(schedule.changed(at: 0), 2)
        XCTAssertEqual(schedule.changed(at: 1), 3)
        XCTAssertEqual(schedule.changed(at: 9), 10)
        XCTAssertEqual(schedule.changed(at: 12), 10)
        schedule.captured()
        XCTAssertEqual(schedule.changed(at: 12), 14)
    }
}
