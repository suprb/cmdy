#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import CmdyPTY

final class LocalProcessLifecycleTests: XCTestCase {
    private final class Probe: LocalProcessDelegate {
        private let lock = NSLock()
        private var storedBytes: [UInt8] = []
        private var storedTerminations: [Int32?] = []
        private var storedEvents: [String] = []
        private var storedCallbackQueueChecks: [Bool] = []
        private var storedWindowSizeRequests = 0
        let windowSize: winsize
        var callbackQueueCheck: (() -> Bool)?

        init(columns: UInt16 = 80, rows: UInt16 = 24) {
            var size = winsize()
            size.ws_col = columns
            size.ws_row = rows
            windowSize = size
        }

        var bytes: [UInt8] {
            lock.lock(); defer { lock.unlock() }
            return storedBytes
        }

        var byteCount: Int {
            lock.lock(); defer { lock.unlock() }
            return storedBytes.count
        }

        var terminationCount: Int {
            lock.lock(); defer { lock.unlock() }
            return storedTerminations.count
        }

        var lastExitCode: Int32? {
            lock.lock(); defer { lock.unlock() }
            return storedTerminations.last ?? nil
        }

        var events: [String] {
            lock.lock(); defer { lock.unlock() }
            return storedEvents
        }

        var callbackQueueChecks: [Bool] {
            lock.lock(); defer { lock.unlock() }
            return storedCallbackQueueChecks
        }

        var windowSizeRequestCount: Int {
            lock.lock(); defer { lock.unlock() }
            return storedWindowSizeRequests
        }

        func resetBytes() {
            lock.lock()
            storedBytes.removeAll(keepingCapacity: true)
            lock.unlock()
        }

        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            lock.lock()
            storedTerminations.append(exitCode)
            storedEvents.append("termination")
            if let callbackQueueCheck {
                storedCallbackQueueChecks.append(callbackQueueCheck())
            }
            lock.unlock()
        }

        func dataReceived(slice: ArraySlice<UInt8>) {
            lock.lock()
            storedBytes.append(contentsOf: slice)
            storedEvents.append("data")
            if let callbackQueueCheck {
                storedCallbackQueueChecks.append(callbackQueueCheck())
            }
            lock.unlock()
        }

        func getWindowSize() -> winsize {
            lock.lock()
            storedWindowSizeRequests += 1
            lock.unlock()
            return windowSize
        }
    }

    func testExecUsesRequestedArgvZeroEnvironmentAndDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-pty-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let probe = Probe()
        let process = LocalProcess(delegate: probe)
        process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "printf '%s|%s|%s' \"$0\" \"$CMDY_EXEC_TEST\" \"$PWD\""],
            environment: ["CMDY_EXEC_TEST=present", "PATH=/usr/bin:/bin"],
            execName: "cmdy-test-shell",
            currentDirectory: directory.path)

        XCTAssertTrue(waitUntil(timeout: 3) { probe.terminationCount == 1 })
        let fields = String(decoding: probe.bytes, as: UTF8.self)
            .split(separator: "|", omittingEmptySubsequences: false)
        XCTAssertEqual(fields.count, 3)
        XCTAssertEqual(fields.first, "cmdy-test-shell")
        XCTAssertEqual(fields.dropFirst().first, "present")
        let observedDirectory = fields.last.map(String.init) ?? ""
        XCTAssertEqual(URL(fileURLWithPath: observedDirectory).lastPathComponent,
                       directory.lastPathComponent)
        XCTAssertEqual(probe.lastExitCode, 0)
    }

    func testInitialWindowSizeAndResizeAreVisibleToChild() {
        let probe = Probe(columns: 93, rows: 37)
        let process = LocalProcess(delegate: probe)
        process.startProcess(
            executable: "/bin/sh",
            args: [
                "-c",
                "trap 'stty size; exit 0' WINCH; stty size; while :; do sleep 1; done",
            ],
            environment: nil)

        XCTAssertTrue(waitUntil(timeout: 3) {
            String(decoding: probe.bytes, as: UTF8.self).contains("37 93")
        })

        var resized = winsize()
        resized.ws_col = 111
        resized.ws_row = 42
        XCTAssertEqual(
            PseudoTerminalHelpers.setWinSize(
                masterPtyDescriptor: process.childfd,
                windowSize: &resized),
            0)

        XCTAssertTrue(waitUntil(timeout: 3) { probe.terminationCount == 1 })
        XCTAssertTrue(String(decoding: probe.bytes, as: UTF8.self).contains("42 111"))
        XCTAssertEqual(probe.lastExitCode, 0)
    }

    func testOutputTransportPreservesUTF8InvalidAndNulBytes() {
        let probe = Probe()
        let process = LocalProcess(delegate: probe)
        process.startProcess(
            executable: "/usr/bin/printf",
            args: ["\\303\\251\\377\\000A"],
            environment: nil)

        XCTAssertTrue(waitUntil(timeout: 3) { probe.terminationCount == 1 })
        XCTAssertEqual(probe.bytes, [0xc3, 0xa9, 0xff, 0x00, 0x41])
    }

    func testSignalTerminationUsesShellCompatibleExitCode() {
        let probe = Probe()
        let process = LocalProcess(delegate: probe)
        process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "kill -TERM $$"],
            environment: nil)

        XCTAssertTrue(waitUntil(timeout: 3) { probe.terminationCount == 1 })
        XCTAssertEqual(probe.lastExitCode, 128 + SIGTERM)
    }

    func testDefaultEnvironmentAndExplicitEmptyEnvironment() {
        let defaultEnvironment = LocalProcess.defaultEnvironment(termName: "cmdy-test-term")
        let values: [String: String] = Dictionary(
            uniqueKeysWithValues: defaultEnvironment.compactMap { item -> (String, String)? in
            let pieces = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { return nil }
            return (String(pieces[0]), String(pieces[1]))
        })
        XCTAssertEqual(values["TERM"], "cmdy-test-term")
        XCTAssertEqual(values["COLORTERM"], "truecolor")
        XCTAssertEqual(values["LANG"], "en_US.UTF-8")

        let defaultProbe = Probe()
        let defaultProcess = LocalProcess(delegate: defaultProbe, dispatchQueue: nil)
        defaultProcess.startProcess(executable: "/usr/bin/env")
        XCTAssertTrue(waitUntil(timeout: 3) { defaultProbe.terminationCount == 1 })
        let childEnvironment = String(decoding: defaultProbe.bytes, as: UTF8.self)
        XCTAssertTrue(childEnvironment.contains("TERM=xterm-256color"))
        XCTAssertTrue(childEnvironment.contains("COLORTERM=truecolor"))
        XCTAssertTrue(childEnvironment.contains("LANG=en_US.UTF-8"))

        let emptyProbe = Probe()
        let emptyProcess = LocalProcess(delegate: emptyProbe)
        emptyProcess.startProcess(executable: "/usr/bin/env", environment: [])
        XCTAssertTrue(waitUntil(timeout: 3) { emptyProbe.terminationCount == 1 })
        XCTAssertTrue(emptyProbe.bytes.isEmpty)
    }

    func testStartWhileRunningIsCompleteNoOp() {
        let probe = Probe()
        let process = LocalProcess(delegate: probe)
        process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "printf first; sleep 0.2"],
            environment: nil)
        XCTAssertTrue(waitUntil(timeout: 2) { probe.bytes == Array("first".utf8) })
        let firstPID = process.shellPid

        process.startProcess(executable: "/usr/bin/printf", args: ["second"], environment: nil)
        XCTAssertEqual(process.shellPid, firstPID)
        XCTAssertEqual(probe.windowSizeRequestCount, 1)

        XCTAssertTrue(waitUntil(timeout: 3) { probe.terminationCount == 1 })
        XCTAssertEqual(probe.bytes, Array("first".utf8))

        probe.resetBytes()
        process.startProcess(executable: "/usr/bin/printf", args: ["second"], environment: nil)
        XCTAssertTrue(waitUntil(timeout: 3) { probe.terminationCount == 2 })
        XCTAssertEqual(probe.bytes, Array("second".utf8))
        XCTAssertEqual(probe.windowSizeRequestCount, 2)
    }

    func testCallbacksUseSuppliedQueueAndOutputPrecedesTermination() {
        let callbackQueue = DispatchQueue(label: "com.cmdy.pty.test-callbacks")
        let callbackKey = DispatchSpecificKey<UInt8>()
        callbackQueue.setSpecific(key: callbackKey, value: 1)

        let probe = Probe()
        probe.callbackQueueCheck = {
            DispatchQueue.getSpecific(key: callbackKey) == 1
        }
        let process = LocalProcess(delegate: probe, dispatchQueue: callbackQueue)

        callbackQueue.sync {
            process.startProcess(executable: "/usr/bin/printf", args: ["ordered"], environment: nil)
            XCTAssertTrue(probe.bytes.isEmpty)
            XCTAssertEqual(probe.terminationCount, 0)
        }

        XCTAssertTrue(waitUntil(timeout: 3) { probe.terminationCount == 1 })
        XCTAssertEqual(probe.bytes, Array("ordered".utf8))
        XCTAssertEqual(probe.events.last, "termination")
        XCTAssertTrue(probe.events.dropLast().allSatisfy { $0 == "data" })
        XCTAssertFalse(probe.callbackQueueChecks.isEmpty)
        XCTAssertTrue(probe.callbackQueueChecks.allSatisfy { $0 })
    }

    func testExecFailuresReturn127AndInvalidDirectoryIsIgnored() {
        let missingProbe = Probe()
        let missing = LocalProcess(delegate: missingProbe)
        missing.startProcess(
            executable: "/definitely/not/a/cmdy-executable",
            environment: [])
        XCTAssertTrue(waitUntil(timeout: 3) { missingProbe.terminationCount == 1 })
        XCTAssertEqual(missingProbe.lastExitCode, 127)

        let invalidExecutableProbe = Probe()
        let invalidExecutable = LocalProcess(delegate: invalidExecutableProbe)
        invalidExecutable.startProcess(executable: "/", environment: [])
        XCTAssertTrue(waitUntil(timeout: 3) {
            invalidExecutableProbe.terminationCount == 1
        })
        XCTAssertEqual(invalidExecutableProbe.lastExitCode, 127)

        let inheritedDirectory = FileManager.default.currentDirectoryPath
        let directoryProbe = Probe()
        let badDirectory = LocalProcess(delegate: directoryProbe)
        badDirectory.startProcess(
            executable: "/bin/pwd",
            environment: [],
            currentDirectory: "/definitely/not/a/cmdy-directory")
        XCTAssertTrue(waitUntil(timeout: 3) { directoryProbe.terminationCount == 1 })
        XCTAssertEqual(directoryProbe.lastExitCode, 0)
        let observedDirectory = String(decoding: directoryProbe.bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(observedDirectory, inheritedDirectory)
    }

    func testEOFAndExitCanArriveInEitherOrder() {
        let eofFirstProbe = Probe()
        let eofFirst = LocalProcess(delegate: eofFirstProbe)
        let eofFirstStart = Date()
        eofFirst.startProcess(
            executable: "/bin/sh",
            args: ["-c", "printf before; exec 0<&- 1>&- 2>&-; sleep 0.15"],
            environment: nil)
        XCTAssertTrue(waitUntil(timeout: 2) {
            eofFirstProbe.bytes == Array("before".utf8)
        })
        XCTAssertEqual(eofFirstProbe.terminationCount, 0)
        XCTAssertTrue(waitUntil(timeout: 3) { eofFirstProbe.terminationCount == 1 })
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(eofFirstStart), 0.12)

        let callbackQueue = DispatchQueue(label: "com.cmdy.pty.test-exit-before-eof")
        let callbackGate = DispatchSemaphore(value: 0)
        callbackQueue.async { callbackGate.wait() }
        let exitFirstProbe = Probe()
        let exitFirst = LocalProcess(delegate: exitFirstProbe, dispatchQueue: callbackQueue)
        // Small enough to fit in the PTY output buffer so the child can exit
        // while delivery of the first read chunk remains deliberately gated.
        let exitFirstBytes = [UInt8](repeating: 0x78, count: 512)
        exitFirst.startProcess(
            executable: "/usr/bin/printf",
            args: [String(decoding: exitFirstBytes, as: UTF8.self)],
            environment: nil)
        XCTAssertTrue(waitUntil(timeout: 3) { !exitFirst.running })
        XCTAssertEqual(exitFirstProbe.terminationCount, 0)
        callbackGate.signal()
        XCTAssertTrue(waitUntil(timeout: 3) { exitFirstProbe.terminationCount == 1 })
        XCTAssertEqual(exitFirstProbe.lastExitCode, 0)
        XCTAssertEqual(exitFirstProbe.bytes, exitFirstBytes)
    }

    func testHostLoggingIsExplicitRawAndNonDisruptive() throws {
        let firstDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-pty-log-a-\(UUID().uuidString)", isDirectory: true)
        let secondDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-pty-log-b-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }

        let probe = Probe()
        let process = LocalProcess(delegate: probe)
        process.setHostLogging(directory: firstDirectory.path)
        process.startProcess(
            executable: "/usr/bin/printf",
            args: ["\\303\\251\\377\\000logged"],
            environment: nil)

        XCTAssertTrue(waitUntil(timeout: 3) { probe.terminationCount == 1 })
        process.setHostLogging(directory: nil)
        let expected = [UInt8]([0xc3, 0xa9, 0xff, 0x00] + Array("logged".utf8))
        XCTAssertEqual(probe.bytes, expected)
        XCTAssertTrue(waitUntil(timeout: 3) {
            let file = firstDirectory.appendingPathComponent("log-0")
            guard let data = try? Data(contentsOf: file) else { return false }
            return [UInt8](data) == expected
        })

        probe.resetBytes()
        process.setHostLogging(directory: secondDirectory.path)
        process.startProcess(
            executable: "/usr/bin/printf",
            args: ["next"],
            environment: nil)
        XCTAssertTrue(waitUntil(timeout: 3) { probe.terminationCount == 2 })
        process.setHostLogging(directory: nil)
        XCTAssertTrue(waitUntil(timeout: 3) {
            let file = secondDirectory.appendingPathComponent("log-1")
            guard let data = try? Data(contentsOf: file) else { return false }
            return [UInt8](data) == Array("next".utf8)
        })
    }

    func testLegacyHelperUsesCompleteArgvAndLeavesDescriptorFlagsUntouched() throws {
        var size = winsize()
        size.ws_col = 80
        size.ws_row = 24
        let spawned = try XCTUnwrap(PseudoTerminalHelpers.fork(
            andExec: "/usr/bin/printf",
            args: ["custom-zero", "%s", "helper"],
            env: [],
            desiredWindowSize: &size))
        defer { Darwin.close(spawned.masterFd) }

        XCTAssertEqual(fcntl(spawned.masterFd, F_GETFL) & O_NONBLOCK, 0)
        XCTAssertEqual(fcntl(spawned.masterFd, F_GETFD) & FD_CLOEXEC, 0)

        var output = [UInt8](repeating: 0, count: 6)
        let count = output.withUnsafeMutableBytes { bytes in
            Darwin.read(spawned.masterFd, bytes.baseAddress, bytes.count)
        }
        XCTAssertEqual(count, output.count)
        XCTAssertEqual(output, Array("helper".utf8))

        var status: Int32 = 0
        XCTAssertEqual(waitpid(spawned.pid, &status, 0), spawned.pid)
        XCTAssertEqual(status, 0)
    }

    func testLegacyHelperAcceptsEmptyArgvAndTrueExitsZero() throws {
        var size = winsize()
        let spawned = try XCTUnwrap(PseudoTerminalHelpers.fork(
            andExec: "/usr/bin/true",
            args: [],
            env: [],
            desiredWindowSize: &size))
        defer { Darwin.close(spawned.masterFd) }

        var status: Int32 = 0
        XCTAssertEqual(waitpid(spawned.pid, &status, 0), spawned.pid)
        XCTAssertEqual(status, 0)
    }

    func testLegacyDescriptorHelpersReportKernelErrors() {
        var size = winsize()
        errno = 0
        XCTAssertEqual(
            PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: -1, windowSize: &size),
            -1)
        XCTAssertEqual(errno, EBADF)

        errno = 0
        let available = PseudoTerminalHelpers.availableBytes(fd: -1)
        XCTAssertEqual(available.status, -1)
        XCTAssertEqual(available.size, 0)
        XCTAssertEqual(errno, EBADF)
    }

    func testMasterDescriptorIsNonblockingCloseOnExecAndClosedAfterExit() {
        let probe = Probe()
        let process = LocalProcess(delegate: probe)
        process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "printf ready; sleep 0.1"],
            environment: nil)

        XCTAssertTrue(waitUntil(timeout: 2) { probe.bytes == Array("ready".utf8) })
        let descriptor = process.childfd
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertNotEqual(fcntl(descriptor, F_GETFL) & O_NONBLOCK, 0)
        XCTAssertNotEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0)

        XCTAssertTrue(waitUntil(timeout: 3) { probe.terminationCount == 1 })
        XCTAssertEqual(process.childfd, -1)
        errno = 0
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testResizeStormDuringBackpressuredOutputReachesFinalSizeWithoutLoss() {
        let callbackQueue = DispatchQueue(label: "com.cmdy.pty.test-resize-storm")
        let callbackGate = DispatchSemaphore(value: 0)
        callbackQueue.async { callbackGate.wait() }

        let probe = Probe()
        let process = LocalProcess(delegate: probe, dispatchQueue: callbackQueue)
        let payloadSize = 1_000_000
        process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "head -c \(payloadSize) /dev/zero; stty size"],
            environment: nil)
        let descriptor = process.childfd
        XCTAssertGreaterThanOrEqual(descriptor, 0)

        DispatchQueue.concurrentPerform(iterations: 240) { index in
            var size = winsize()
            size.ws_col = UInt16(40 + (index % 120))
            size.ws_row = UInt16(20 + (index % 60))
            _ = PseudoTerminalHelpers.setWinSize(
                masterPtyDescriptor: descriptor,
                windowSize: &size)
        }
        var finalSize = winsize()
        finalSize.ws_col = 123
        finalSize.ws_row = 57
        XCTAssertEqual(
            PseudoTerminalHelpers.setWinSize(
                masterPtyDescriptor: descriptor,
                windowSize: &finalSize),
            0)

        callbackGate.signal()
        XCTAssertTrue(waitUntil(timeout: 8) { probe.terminationCount == 1 })
        XCTAssertEqual(probe.lastExitCode, 0)
        XCTAssertGreaterThan(probe.byteCount, payloadSize)
        XCTAssertTrue(probe.bytes.prefix(payloadSize).allSatisfy { $0 == 0 })
        let suffix = String(decoding: probe.bytes.dropFirst(payloadSize), as: UTF8.self)
        XCTAssertTrue(suffix.contains("57 123"))
    }

    func testManyConcurrentPanesDrainAndReturnProcessAndDescriptorBaselines() {
        let baselineDescriptors = Self.openDescriptorCount()
        let paneCount = 32
        var probes: [Probe] = []
        var processes: [LocalProcess] = []
        var childPIDs: [pid_t] = []

        for _ in 0..<paneCount {
            let probe = Probe()
            let process = LocalProcess(delegate: probe)
            probe.resetBytes()
            process.startProcess(
                executable: "/usr/bin/head",
                args: ["-c", "65536", "/dev/zero"],
                environment: nil)
            probes.append(probe)
            processes.append(process)
            let pid = process.shellPid
            if pid > 0 { childPIDs.append(pid) }
        }

        XCTAssertTrue(waitUntil(timeout: 10) {
            probes.allSatisfy { $0.byteCount == 65_536 && $0.terminationCount == 1 }
        })
        XCTAssertTrue(processes.allSatisfy { !$0.running && $0.childfd == -1 })
        XCTAssertTrue(probes.allSatisfy { $0.lastExitCode == 0 })
        XCTAssertTrue(waitUntil(timeout: 5) {
            childPIDs.allSatisfy(Self.isGoneAndReaped)
        })
        XCTAssertLessThanOrEqual(Self.openDescriptorCount(), baselineDescriptors)
    }

    func testRapidRestartDropsStaleDataAndReapsEverySupersededChild() {
        let probe = Probe()
        let process = LocalProcess(delegate: probe)
        var supersededPIDs: [pid_t] = []

        for index in 0..<240 {
            process.startProcess(
                executable: "/bin/sh",
                args: ["-c", "printf stale-\(index); sleep 10"],
                environment: nil)
            supersededPIDs.append(process.shellPid)
            process.terminate()
        }

        probe.resetBytes()
        process.startProcess(executable: "/usr/bin/printf", args: ["latest"], environment: nil)

        XCTAssertTrue(waitUntil(timeout: 5) {
            probe.bytes == Array("latest".utf8) && probe.terminationCount == 1
        })
        XCTAssertEqual(probe.bytes, Array("latest".utf8))
        XCTAssertTrue(waitUntil(timeout: 5) {
            supersededPIDs.allSatisfy(Self.isGoneAndReaped)
        })
    }

    func testConcurrentSendSerializesEveryByte() {
        let probe = Probe()
        let process = LocalProcess(delegate: probe)
        process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "stty raw -echo; printf ready; cat"],
            environment: nil)

        XCTAssertTrue(waitUntil(timeout: 3) { probe.bytes == Array("ready".utf8) })
        probe.resetBytes()

        let writers = 8
        let sendsPerWriter = 80
        let bytesPerSend = 257
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.cmdy.pty.test-writers", attributes: .concurrent)
        for writer in 0..<writers {
            group.enter()
            queue.async {
                let byte = UInt8(48 + writer)
                let payload = [UInt8](repeating: byte, count: bytesPerSend)
                for _ in 0..<sendsPerWriter {
                    process.send(data: payload[...])
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)

        let expectedCount = writers * sendsPerWriter * bytesPerSend
        XCTAssertTrue(waitUntil(timeout: 8) { probe.byteCount == expectedCount })
        XCTAssertEqual(probe.byteCount, expectedCount)
        process.terminate()
        XCTAssertTrue(waitUntil(timeout: 3) { !process.running })
    }

    func testTerminateKillsForegroundProcessGroupAndReturnsImmediately() throws {
        let probe = Probe()
        let process = LocalProcess(delegate: probe)
        process.startProcess(
            executable: "/bin/sh",
            args: [
                "-c",
                "trap '' TERM HUP; (trap '' TERM HUP; while :; do sleep 10; done) & "
                    + "child=$!; printf '%s' \"$child\"; wait",
            ],
            environment: nil)

        XCTAssertTrue(waitUntil(timeout: 3) {
            Int32(String(decoding: probe.bytes, as: UTF8.self)) != nil
        })
        let childPID = try XCTUnwrap(Int32(String(decoding: probe.bytes, as: UTF8.self)))
        let groupPID = process.shellPid
        XCTAssertGreaterThan(groupPID, 0)
        XCTAssertGreaterThan(childPID, 0)
        XCTAssertEqual(getpgid(groupPID), groupPID)

        let started = ContinuousClock.now
        process.terminate()
        let elapsed = ContinuousClock.now - started
        XCTAssertLessThan(elapsed, .milliseconds(100))

        XCTAssertTrue(waitUntil(timeout: 4) { Self.processIsGone(groupPID) })
        XCTAssertTrue(waitUntil(timeout: 4) { Self.processIsGone(childPID) })
        XCTAssertTrue(waitUntil(timeout: 4) { Self.isGoneAndReaped(groupPID) })
    }

    func testRepeatedSessionsDoNotGrowOpenDescriptorCount() {
        let probe = Probe()
        let process = LocalProcess(delegate: probe)

        process.startProcess(executable: "/usr/bin/true", args: [], environment: nil)
        XCTAssertTrue(waitUntil(timeout: 3) { probe.terminationCount == 1 })
        let baseline = Self.openDescriptorCount()

        for expectedTerminationCount in 2...42 {
            process.startProcess(executable: "/usr/bin/true", args: [], environment: nil)
            XCTAssertTrue(waitUntil(timeout: 3) {
                probe.terminationCount == expectedTerminationCount
            })
        }

        XCTAssertEqual(process.childfd, -1)
        XCTAssertLessThanOrEqual(Self.openDescriptorCount(), baseline)
    }

    func testConcurrentNaturalExitAndTerminateAlwaysReaps() {
        let probe = Probe()
        let process = LocalProcess(delegate: probe)
        let terminationQueue = DispatchQueue(
            label: "com.cmdy.pty.test-termination-race",
            attributes: .concurrent)
        var childPIDs: [pid_t] = []

        for _ in 1...80 {
            process.startProcess(executable: "/usr/bin/true", args: [], environment: nil)
            let childPID = process.shellPid
            if childPID > 0 { childPIDs.append(childPID) }

            let group = DispatchGroup()
            group.enter()
            terminationQueue.async {
                process.terminate()
                group.leave()
            }
            XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
            XCTAssertFalse(process.running)
            if childPID > 0 {
                XCTAssertTrue(waitUntil(timeout: 3) {
                    Self.isGoneAndReaped(childPID)
                })
            }
        }

        XCTAssertLessThanOrEqual(probe.terminationCount, 80)
        XCTAssertTrue(waitUntil(timeout: 5) {
            childPIDs.allSatisfy(Self.isGoneAndReaped)
        })
    }

    private static func openDescriptorCount() -> Int {
        var count = 0
        for descriptor in 0..<getdtablesize() {
            errno = 0
            if fcntl(descriptor, F_GETFD) != -1 || errno != EBADF {
                count += 1
            }
        }
        return count
    }

    private static func processIsGone(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return true }
        errno = 0
        return kill(pid, 0) == -1 && errno == ESRCH
    }

    private static func isGoneAndReaped(_ pid: pid_t) -> Bool {
        guard processIsGone(pid) else { return false }
        var status: Int32 = 0
        errno = 0
        return waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD
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
