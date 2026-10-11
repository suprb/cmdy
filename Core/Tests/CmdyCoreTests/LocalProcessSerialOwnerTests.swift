#if os(macOS)
import Darwin
import Dispatch
import Foundation
import XCTest
@_spi(CmdyApp) @testable import CmdyPTY

final class LocalProcessSerialOwnerTests: XCTestCase {
    private final class Probe: LocalProcessDelegate {
        private let lock = NSLock()
        private var storedBytes: [UInt8] = []
        private var storedEvents: [String] = []
        private var storedChunkSizes: [Int] = []
        private var storedQueueChecks: [Bool] = []
        private var storedExitCodes: [Int32?] = []
        // Set before the first process starts; callbacks only read these hooks.
        var queueCheck: (() -> Bool)?
        var onData: ((ArraySlice<UInt8>) -> Void)?

        var bytes: [UInt8] {
            lock.lock(); defer { lock.unlock() }
            return storedBytes
        }
        var byteCount: Int {
            lock.lock(); defer { lock.unlock() }
            return storedBytes.count
        }
        var events: [String] {
            lock.lock(); defer { lock.unlock() }
            return storedEvents
        }
        var chunkSizes: [Int] {
            lock.lock(); defer { lock.unlock() }
            return storedChunkSizes
        }
        var queueChecks: [Bool] {
            lock.lock(); defer { lock.unlock() }
            return storedQueueChecks
        }
        var terminationCount: Int {
            lock.lock(); defer { lock.unlock() }
            return storedExitCodes.count
        }
        var lastExitCode: Int32? {
            lock.lock(); defer { lock.unlock() }
            return storedExitCodes.last ?? nil
        }

        func dataReceived(slice: ArraySlice<UInt8>) {
            let onExpectedQueue = queueCheck?() ?? true
            lock.lock()
            storedBytes.append(contentsOf: slice)
            storedChunkSizes.append(slice.count)
            storedEvents.append("data")
            storedQueueChecks.append(onExpectedQueue)
            lock.unlock()
            onData?(slice)
        }
        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            let onExpectedQueue = queueCheck?() ?? true
            lock.lock(); defer { lock.unlock() }
            storedExitCodes.append(exitCode)
            storedEvents.append("termination")
            storedQueueChecks.append(onExpectedQueue)
        }
        func getWindowSize() -> winsize {
            var size = winsize()
            size.ws_col = 80; size.ws_row = 24
            return size
        }
    }

    func testSerialOwnerPreservesQueueBinaryOutputAndTerminationOrder() throws {
        let queue = DispatchQueue(label: "com.cmdy.pty.test-serial-output")
        let key = DispatchSpecificKey<UInt8>()
        queue.setSpecific(key: key, value: 1)
        let probe = Probe()
        probe.queueCheck = { DispatchQueue.getSpecific(key: key) == 1 }
        let process = LocalProcess(delegate: probe, serialQueue: queue)
        defer { process.terminate() }
        let payload = Self.payload(count: 2 * 65_536 + 37)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-serial-output-\(UUID().uuidString)")
        try Data(payload).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "stty raw -echo; cat \"$1\"", "cmdy-serial-test", file.path],
            environment: ["PATH=/usr/bin:/bin"])

        XCTAssertTrue(waitUntil(timeout: 5) { probe.terminationCount == 1 })
        XCTAssertTrue(probe.bytes == payload, "binary bytes must retain their exact order")
        XCTAssertTrue(probe.chunkSizes.allSatisfy { (1...65_536).contains($0) })
        XCTAssertEqual(probe.events.last, "termination")
        XCTAssertTrue(probe.events.dropLast().allSatisfy { $0 == "data" })
        XCTAssertFalse(probe.queueChecks.isEmpty)
        XCTAssertTrue(probe.queueChecks.allSatisfy { $0 })
        XCTAssertEqual(probe.lastExitCode, 0)
        XCTAssertEqual(process.childfd, -1)
    }

    func testSerialOwnerCallbackCanSendAndReadProcessProperties() {
        let queue = DispatchQueue(label: "com.cmdy.pty.test-serial-reply")
        let probe = Probe()
        let process = LocalProcess(delegate: probe, serialQueue: queue)
        defer { process.terminate() }
        let response: [UInt8] = [0x41, 0, 0x42, 0xff]
        probe.onData = { [weak probe, weak process] _ in
            guard probe?.bytes == Array("ready".utf8), let process else { return }
            XCTAssertTrue(process.running)
            XCTAssertGreaterThan(process.shellPid, 0)
            XCTAssertGreaterThanOrEqual(process.childfd, 0)
            process.send(data: response[...])
        }
        process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "stty raw -echo; printf ready; head -c 4"],
            environment: ["PATH=/usr/bin:/bin"])

        XCTAssertTrue(waitUntil(timeout: 5) { probe.terminationCount == 1 })
        XCTAssertEqual(probe.bytes, Array("ready".utf8) + response)
        XCTAssertEqual(probe.lastExitCode, 0)
    }

    func testSerialOwnerCallbackCanTerminateAndStartNewGeneration() {
        let queue = DispatchQueue(label: "com.cmdy.pty.test-serial-restart")
        let probe = Probe()
        let process = LocalProcess(delegate: probe, serialQueue: queue)
        defer { process.terminate() }
        probe.onData = { [weak probe, weak process] _ in
            guard probe?.bytes == Array("old".utf8), let process else { return }
            process.terminate()
            XCTAssertFalse(process.running)
            XCTAssertEqual(process.childfd, -1)
            process.startProcess(
                executable: "/usr/bin/printf", args: ["new"], environment: [])
        }
        process.startProcess(
            executable: "/bin/sh", args: ["-c", "printf old; sleep 10"],
            environment: ["PATH=/usr/bin:/bin"])

        XCTAssertTrue(waitUntil(timeout: 5) { probe.terminationCount == 1 })
        XCTAssertEqual(probe.bytes, Array("oldnew".utf8))
        XCTAssertEqual(probe.lastExitCode, 0)
        XCTAssertEqual(probe.events.last, "termination")
        XCTAssertFalse(process.running)
    }

    func testSerialOwnerFinalTailFinishesBeforeReapedChildTermination() {
        let queue = DispatchQueue(label: "com.cmdy.pty.test-serial-tail")
        let probe = Probe()
        let process = LocalProcess(delegate: probe, serialQueue: queue)
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        defer {
            gate.signal()
            process.terminate()
        }
        probe.onData = { [weak probe] _ in
            guard probe?.bytes == Array("tail".utf8) else { return }
            entered.signal()
            gate.wait()
        }
        // Obtain identity before read delivery can occupy the owner queue.
        let childPID = queue.sync { () -> pid_t in
            process.startProcess(
                executable: "/bin/sh", args: ["-c", "printf tail; sleep 0.15"],
                environment: ["PATH=/usr/bin:/bin"])
            return process.shellPid
        }
        XCTAssertGreaterThan(childPID, 0)
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        if childPID > 0 {
            XCTAssertTrue(waitUntil(timeout: 3) {
                errno = 0
                return Darwin.kill(childPID, 0) == -1 && errno == ESRCH
            }, "the independent reaper must still run while delivery is held")
        }
        // Do not synchronously query LocalProcess while deliberately holding
        // its owner queue. The delegate's locked records remain observable.
        XCTAssertEqual(probe.bytes, Array("tail".utf8))
        XCTAssertEqual(probe.terminationCount, 0)
        gate.signal()
        XCTAssertTrue(waitUntil(timeout: 3) { probe.terminationCount == 1 })
        XCTAssertEqual(probe.events.last, "termination")
        XCTAssertEqual(process.childfd, -1)
    }

    func testDefaultConcurrentCallbackQueueKeepsIndependentProcessAccess() {
        let callbackQueue = DispatchQueue(
            label: "com.cmdy.pty.test-default-concurrent", attributes: .concurrent)
        let probe = Probe()
        let process = LocalProcess(delegate: probe, dispatchQueue: callbackQueue)
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let independentWork = DispatchSemaphore(value: 0)
        defer {
            gate.signal()
            process.terminate()
        }
        probe.onData = { _ in
            entered.signal()
            gate.wait()
        }
        process.startProcess(
            executable: "/bin/sh", args: ["-c", "printf ready; sleep 10"],
            environment: ["PATH=/usr/bin:/bin"])
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        callbackQueue.async {
            XCTAssertTrue(process.running)
            XCTAssertGreaterThan(process.shellPid, 0)
            XCTAssertGreaterThanOrEqual(process.childfd, 0)
            independentWork.signal()
        }
        XCTAssertEqual(independentWork.wait(timeout: .now() + 3), .success,
                       "existing callback queues must not become process owner queues")
        gate.signal()
    }

    func testSerialOwnerQueuedWorkProgressesDuringLargeBidirectionalTransfer() {
        let queue = DispatchQueue(label: "com.cmdy.pty.test-serial-fairness")
        let probe = Probe()
        let process = LocalProcess(delegate: probe, serialQueue: queue)
        defer { process.terminate() }
        process.startProcess(
            executable: "/bin/sh", args: ["-c", "stty raw -echo; printf ready; cat"],
            environment: ["PATH=/usr/bin:/bin"])
        guard waitUntil(timeout: 3, { probe.bytes == Array("ready".utf8) }) else {
            XCTFail("raw echo fixture did not become ready")
            return
        }
        let payload = Self.payload(count: 4_000_000)
        let workRan = DispatchSemaphore(value: 0)
        queue.async { process.send(data: payload[...]) }
        queue.async {
            XCTAssertLessThan(probe.byteCount, payload.count + 5,
                              "queued owner work must progress before the full transfer drains")
            workRan.signal()
        }
        XCTAssertEqual(workRan.wait(timeout: .now() + 3), .success)
        XCTAssertTrue(waitUntil(timeout: 10) { probe.byteCount == payload.count + 5 })
        XCTAssertTrue(Array(probe.bytes.dropFirst(5)) == payload,
                      "yielding the write pump must preserve every byte and its order")
        XCTAssertTrue(probe.chunkSizes.allSatisfy { (1...65_536).contains($0) })
    }

    func testRetainedCallbackSlicesStayImmutableAcrossLaterReadsAndRestart() throws {
        for serialOwner in [false, true] {
            let queue = DispatchQueue(label: "com.cmdy.pty.test-retained-slices")
            let probe = Probe()
            let process = serialOwner
                ? LocalProcess(delegate: probe, serialQueue: queue)
                : LocalProcess(delegate: probe, dispatchQueue: queue)
            defer { process.terminate() }
            var retained: [ArraySlice<UInt8>] = []
            probe.onData = { slice in retained.append(slice) }
            let first = Self.payload(count: 3 * 65_536 + 73)
            let second = [UInt8](repeating: 0xa5, count: 65_536 + 31)
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmdy-retained-slices-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: file) }
            func launch(_ bytes: [UInt8]) throws {
                try Data(bytes).write(to: file)
                process.startProcess(executable: "/bin/sh",
                    args: ["-c", "stty raw -echo; cat \"$1\"", "cmdy-slice-test", file.path],
                    environment: ["PATH=/usr/bin:/bin"])
            }
            try launch(first)
            guard waitUntil(timeout: 5, { probe.terminationCount == 1 }) else {
                XCTFail("first retained-slice fixture did not exit")
                continue
            }
            let firstSlices = queue.sync { retained }
            XCTAssertGreaterThan(firstSlices.count, 1)
            XCTAssertEqual(firstSlices.flatMap { Array($0) }, first)
            try launch(second)
            XCTAssertTrue(waitUntil(timeout: 5) { probe.terminationCount == 2 })
            let allSlices = queue.sync { retained }
            XCTAssertEqual(firstSlices.flatMap { Array($0) }, first,
                           "a later generation must not overwrite retained callback storage")
            XCTAssertEqual(allSlices.flatMap { Array($0) }, first + second)
            XCTAssertEqual(probe.bytes, first + second)
            XCTAssertTrue(allSlices.allSatisfy { (1...65_536).contains($0.count) })
        }
    }

    func testRetainedSliceSurvivesReentrantSerialGenerationReplacement() {
        let queue = DispatchQueue(label: "com.cmdy.pty.test-retained-reentrant")
        let probe = Probe()
        let process = LocalProcess(delegate: probe, serialQueue: queue)
        defer { process.terminate() }
        var retained: [ArraySlice<UInt8>] = []
        probe.onData = { [weak probe, weak process] slice in
            retained.append(slice)
            guard probe?.bytes == Array("old".utf8), let process else { return }
            process.terminate()
            process.startProcess(executable: "/usr/bin/printf",
                                 args: ["replacement"], environment: [])
        }
        process.startProcess(executable: "/bin/sh",
            args: ["-c", "printf old; sleep 10"], environment: ["PATH=/usr/bin:/bin"])
        XCTAssertTrue(waitUntil(timeout: 5) { probe.terminationCount == 1 })
        let slices = queue.sync { retained }
        XCTAssertEqual(slices.flatMap { Array($0) }, Array("oldreplacement".utf8))
        XCTAssertEqual(probe.bytes, Array("oldreplacement".utf8))
        XCTAssertEqual(probe.events.last, "termination")
        XCTAssertEqual(process.childfd, -1)
    }

    private static func payload(count: Int) -> [UInt8] {
        (0..<count).map { (index: Int) -> UInt8 in
            let value = (index * 17 + 3) % 251
            return UInt8(value)
        }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }
}
#endif
