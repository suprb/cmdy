#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import CmdyPTY

final class LocalProcessFlowControlTests: XCTestCase {
    private final class Delegate: LocalProcessDelegate {
        private let lock = NSLock()
        private var byteStorage: [UInt8] = []
        private var terminationStorage: [Int32?] = []

        var bytes: [UInt8] {
            lock.lock(); defer { lock.unlock() }
            return byteStorage
        }

        var byteCount: Int {
            lock.lock(); defer { lock.unlock() }
            return byteStorage.count
        }

        var terminationCount: Int {
            lock.lock(); defer { lock.unlock() }
            return terminationStorage.count
        }

        var lastExitCode: Int32? {
            lock.lock(); defer { lock.unlock() }
            return terminationStorage.last ?? nil
        }

        func resetBytes() {
            lock.lock(); defer { lock.unlock() }
            byteStorage.removeAll(keepingCapacity: true)
        }

        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            lock.lock(); defer { lock.unlock() }
            terminationStorage.append(exitCode)
        }

        func dataReceived(slice: ArraySlice<UInt8>) {
            lock.lock(); defer { lock.unlock() }
            byteStorage.append(contentsOf: slice)
        }

        func getWindowSize() -> winsize {
            var size = winsize()
            size.ws_col = 80
            size.ws_row = 24
            return size
        }
    }

    func testMainQueueBackpressureResumesWithoutDroppingBytes() {
        let target = 12_000_000
        let delegate = Delegate()
        let process = LocalProcess(delegate: delegate)
        process.startProcess(executable: "/usr/bin/head",
                             args: ["-c", "\(target)", "/dev/zero"],
                             environment: nil)

        var runningWhileMainWasBlocked = false
        let block = {
            Thread.sleep(forTimeInterval: 0.35)
            runningWhileMainWasBlocked = process.running
        }
        if Thread.isMainThread { block() } else { DispatchQueue.main.sync(execute: block) }

        XCTAssertTrue(runningWhileMainWasBlocked,
                      "the child should be kernel-backpressured while the main drain is blocked")
        XCTAssertTrue(waitUntil(timeout: 10) {
            delegate.byteCount == target && delegate.terminationCount == 1
        })
        XCTAssertEqual(delegate.byteCount, target)
        XCTAssertFalse(process.running)
    }

    func testCompletedProcessCanReuseTheReadLoop() {
        let delegate = Delegate()
        let process = LocalProcess(delegate: delegate)

        process.startProcess(executable: "/usr/bin/printf", args: ["first"], environment: nil)
        XCTAssertTrue(waitUntil(timeout: 3) {
            delegate.bytes == Array("first".utf8) && delegate.terminationCount == 1
        })

        delegate.resetBytes()
        process.startProcess(executable: "/usr/bin/printf", args: ["second"], environment: nil)
        XCTAssertTrue(waitUntil(timeout: 3) {
            delegate.bytes == Array("second".utf8) && delegate.terminationCount == 2
        })
        XCTAssertFalse(process.running)
    }

    func testProcessTerminationReportsDecodedExitCode() {
        let delegate = Delegate()
        let process = LocalProcess(delegate: delegate)

        process.startProcess(executable: "/bin/sh", args: ["-c", "exit 7"], environment: nil)

        XCTAssertTrue(waitUntil(timeout: 3) { delegate.terminationCount == 1 })
        XCTAssertEqual(delegate.lastExitCode, 7)
        XCTAssertEqual(process.shellPid, 0)
        XCTAssertFalse(process.running)
    }

    func testTerminateThenReuseDropsStaleQueuedOutputAndUnpausesReads() {
        let delegate = Delegate()
        let process = LocalProcess(delegate: delegate)
        process.startProcess(executable: "/usr/bin/head",
                             args: ["-c", "12000000", "/dev/zero"],
                             environment: nil)
        let oldPID = process.shellPid

        var oldProcessWasBackpressured = false
        let replaceProcess = {
            Thread.sleep(forTimeInterval: 0.35)
            oldProcessWasBackpressured = process.running
            process.terminate()
            delegate.resetBytes()
            process.startProcess(executable: "/usr/bin/printf", args: ["second"], environment: nil)
        }
        if Thread.isMainThread {
            replaceProcess()
        } else {
            DispatchQueue.main.sync(execute: replaceProcess)
        }

        XCTAssertTrue(oldProcessWasBackpressured)
        XCTAssertTrue(waitUntil(timeout: 3) {
            delegate.bytes == Array("second".utf8) && delegate.terminationCount == 1
        })
        XCTAssertEqual(delegate.bytes, Array("second".utf8))
        XCTAssertFalse(process.running)
        XCTAssertTrue(waitUntil(timeout: 3) {
            var status: Int32 = 0
            errno = 0
            let result = waitpid(oldPID, &status, WNOHANG)
            return result == -1 && errno == ECHILD
        }, "the terminated child must be reaped by its process monitor")
    }

    func testChildIsReapedAfterLocalProcessDeallocation() {
        let delegate = Delegate()
        weak var weakProcess: LocalProcess?
        var childPID: pid_t = 0

        autoreleasepool {
            var process: LocalProcess? = LocalProcess(delegate: delegate)
            weakProcess = process
            process?.startProcess(
                executable: "/bin/sh",
                args: ["-c", "sleep 0.15; exit 0"],
                environment: nil)
            childPID = process?.shellPid ?? 0
            process = nil
        }

        XCTAssertGreaterThan(childPID, 0)
        XCTAssertNil(weakProcess)
        assertReaped(childPID, timeout: 3)
    }

    func testTermAndHupIgnoringZshIsForceReapedAfterTermination() throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else {
            throw XCTSkip("zsh is unavailable")
        }
        let delegate = Delegate()
        weak var weakProcess: LocalProcess?
        var childPID: pid_t = 0

        autoreleasepool {
            var process: LocalProcess? = LocalProcess(delegate: delegate)
            weakProcess = process
            process?.startProcess(
                executable: "/bin/zsh",
                args: [
                    "-f", "-c",
                    "trap '' TERM HUP; printf ready; while true; do sleep 10; done",
                ],
                environment: nil)
            XCTAssertTrue(waitUntil(timeout: 2) {
                delegate.bytes == Array("ready".utf8)
            })
            childPID = process?.shellPid ?? 0
            process?.terminate()
            process = nil
        }

        XCTAssertGreaterThan(childPID, 0)
        XCTAssertNil(weakProcess)
        assertReaped(childPID, timeout: 3)
    }

    private func assertReaped(
        _ pid: pid_t,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(waitUntil(timeout: timeout) {
            errno = 0
            return kill(pid, 0) == -1 && errno == ESRCH
        }, "child \(pid) remained present after its expected exit", file: file, line: line)

        errno = 0
        XCTAssertEqual(kill(-pid, 0), -1, file: file, line: line)
        XCTAssertEqual(errno, ESRCH, "child process group remained alive",
                       file: file, line: line)

        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1, file: file, line: line)
        XCTAssertEqual(errno, ECHILD, file: file, line: line)
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            if Thread.isMainThread {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            } else {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        return condition()
    }
}
#endif
