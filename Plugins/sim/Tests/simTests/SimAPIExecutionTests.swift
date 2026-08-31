import CoreGraphics
import Foundation
import XCTest
@testable import sim

final class SimAPIExecutionTests: XCTestCase {
    func testConcurrentExecuteRequestsSerializeStateWhileHealthResponds() throws {
        let recorder = ExecutionRecorder()
        let api = SimAPI(
            toolExecutionOverride: recorder.execute,
            healthProbe: { false })
        let firstResponse = ResponseCapture()
        let secondResponse = ResponseCapture()
        let healthResponse = ResponseCapture()
        let firstDone = expectation(description: "first execute response")
        let secondDone = expectation(description: "second execute response")
        let healthDone = expectation(description: "health response")

        api.routeForTesting(try executeRequest(tool: "first")) { status, payload in
            firstResponse.store(status: status, payload: payload)
            firstDone.fulfill()
        }
        guard recorder.firstStarted.wait(timeout: .now() + 1) == .success else {
            recorder.releaseFirst.signal()
            XCTFail("first request never entered the execution lane")
            return
        }

        api.routeForTesting(try executeRequest(tool: "second")) { status, payload in
            secondResponse.store(status: status, payload: payload)
            secondDone.fulfill()
        }
        api.routeForTesting(SimHTTPServer.Request(
            method: "GET", path: "/health", body: Data()
        )) { status, payload in
            healthResponse.store(status: status, payload: payload)
            healthDone.fulfill()
        }

        // The first stateful request is deliberately blocked. Health must use
        // its independent lane and return before that request is released.
        wait(for: [healthDone], timeout: 1)
        XCTAssertEqual(healthResponse.status, 200)
        XCTAssertEqual(
            (healthResponse.payload as? [String: Any])?["booted"] as? Bool,
            false)

        // A concurrent execution queue would enter the second closure while
        // the first is held. The real serial scheduler must keep it pending.
        XCTAssertEqual(
            recorder.secondStarted.wait(timeout: .now() + 0.15),
            .timedOut)

        recorder.releaseFirst.signal()
        wait(for: [firstDone, secondDone], timeout: 2)

        XCTAssertEqual(firstResponse.status, 200)
        XCTAssertEqual(secondResponse.status, 200)
        XCTAssertNotNil((firstResponse.payload as? [String: Any])?["result"])
        XCTAssertNotNil((secondResponse.payload as? [String: Any])?["result"])
        let recorderState = recorder.snapshot()
        XCTAssertEqual(recorderState.maximumActiveExecutions, 1)
        XCTAssertEqual(recorderState.stateObservedBySecond, "first-complete")
    }

    private func executeRequest(tool: String) throws -> SimHTTPServer.Request {
        SimHTTPServer.Request(
            method: "POST",
            path: "/execute",
            body: try JSONSerialization.data(withJSONObject: [
                "tool": tool,
                "arguments": [:],
            ]))
    }
}

private final class ExecutionRecorder: @unchecked Sendable {
    let firstStarted = DispatchSemaphore(value: 0)
    let secondStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var activeExecutions = 0
    private var maximumActiveExecutions = 0
    private var state = "initial"
    private var stateObservedBySecond: String?

    func snapshot() -> (
        maximumActiveExecutions: Int,
        stateObservedBySecond: String?
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (maximumActiveExecutions, stateObservedBySecond)
    }

    func execute(
        tool: String,
        arguments: [String: Any],
        windowNumber: CGWindowID?
    ) throws -> Any {
        lock.lock()
        activeExecutions += 1
        maximumActiveExecutions = max(maximumActiveExecutions, activeExecutions)
        lock.unlock()
        defer {
            lock.lock()
            activeExecutions -= 1
            lock.unlock()
        }

        switch tool {
        case "first":
            lock.lock()
            state = "first-started"
            lock.unlock()
            firstStarted.signal()
            guard releaseFirst.wait(timeout: .now() + 2) == .success else {
                throw ExecutionRecorderError.releaseTimedOut
            }
            lock.lock()
            state = "first-complete"
            lock.unlock()
            return ["state": "first-complete"]

        case "second":
            secondStarted.signal()
            lock.lock()
            stateObservedBySecond = state
            state = "second-complete"
            lock.unlock()
            return ["state": "second-complete"]

        default:
            throw ExecutionRecorderError.unexpectedTool(tool)
        }
    }
}

private enum ExecutionRecorderError: Error {
    case releaseTimedOut
    case unexpectedTool(String)
}

private final class ResponseCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStatus: Int?
    private var storedPayload: Any?

    var status: Int? {
        lock.lock()
        defer { lock.unlock() }
        return storedStatus
    }

    var payload: Any? {
        lock.lock()
        defer { lock.unlock() }
        return storedPayload
    }

    func store(status: Int, payload: Any) {
        lock.lock()
        storedStatus = status
        storedPayload = payload
        lock.unlock()
    }
}
