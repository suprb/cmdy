import Foundation
import Dispatch
import Darwin
import CryptoKit
@_spi(CmdyApp) import CmdyCore
@_spi(CmdyApp) import CmdyPTY

final class Host: LocalProcessDelegate, CmdyTerminalDelegate {
    let queue = DispatchQueue(label: "com.cmdy.headless-engine", qos: .userInteractive)
    let exited = DispatchSemaphore(value: 0)
    let terminal = CmdyTerminal(cols: 120, rows: 36, scrollback: 10_000)
    var process: LocalProcess!
    private var bytesReceived = 0
    private var chunkSizes: [Int] = []
    private var responses: [String] = []
    private var contentChanges = 0
    private var capturing = false
    private var captured: [UInt8] = []
    private var terminationCount = 0
    private var exitCode: Int32?
    private let captureSnapshots: Bool
    private var captureCount = 0
    private var snapshotScheduled = false
    private var captureEpoch: UInt64 = 0
    private var lastCapturedSnapshot: CoreTerminalSnapshot?

    init(reuseReadBuffer: Bool, captureSnapshots: Bool) {
        self.captureSnapshots = captureSnapshots
        terminal.delegate = self
        process = LocalProcess(delegate: self, serialQueue: queue, reuseReadBuffer: reuseReadBuffer)
    }
    func start(python: String, worker: String, directory: String, payload: String, socket: String) {
        process.startProcess(executable: python,
            args: [worker, "--directory", directory, "--payload", payload, "--socket", socket],
            environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color", "LANG=en_US.UTF-8", "TERM_PROGRAM=CMDY-headless-probe"],
            currentDirectory: directory)
    }
    func begin(validation: Bool) {
        queue.sync {
            bytesReceived = 0
            captureCount = 0
            snapshotScheduled = false; captureEpoch &+= 1
            chunkSizes.removeAll(keepingCapacity: true)
            chunkSizes.reserveCapacity(4096)
            responses.removeAll(keepingCapacity: true)
            contentChanges = 0
            capturing = validation
            captured.removeAll(keepingCapacity: false)
            if validation { captured.reserveCapacity(3_001_024) }
        }
    }
    func snapshot() -> [String: Any] {
        queue.sync {
            var result: [String: Any] = [
                "bytesReceived": bytesReceived, "chunkSizes": chunkSizes,
                "snapshotCaptures": captureCount, "snapshotMode": captureSnapshots,
                "diagnosticsEnabled": false,
                "responseHexes": responses, "contentChanges": contentChanges,
                "columns": terminal.cols, "rows": terminal.rows,
                "cursorRow": terminal.cursorRow, "cursorColumn": terminal.cursorColumn,
                "bufferLineCount": terminal.bufferLineCount,
                "terminationCount": terminationCount,
                "exitCode": exitCode.map { Int($0) } as Any? ?? NSNull(),
                "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
                "activeProcessorCount": ProcessInfo.processInfo.activeProcessorCount,
                "thermalState": ProcessInfo.processInfo.thermalState.rawValue]
            if capturing {
                result["receivedSHA256"] = SHA256.hash(data: Data(captured))
                    .map { String(format: "%02x", $0) }.joined()
            }
            return result
        }
    }
    func dataReceived(slice: ArraySlice<UInt8>) {
        dispatchPrecondition(condition: .onQueue(queue))
        bytesReceived += slice.count
        chunkSizes.append(slice.count)
        if capturing { captured.append(contentsOf: slice) }
        terminal.feed(slice)
    }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        dispatchPrecondition(condition: .onQueue(queue))
        self.exitCode = exitCode
        terminationCount += 1
        exited.signal()
    }
    func getWindowSize() -> winsize {
        var size = winsize()
        size.ws_col = 120; size.ws_row = 36
        return size
    }
    func send(_ terminal: CmdyTerminal, data: ArraySlice<UInt8>) {
        responses.append(data.map { String(format: "%02x", $0) }.joined())
        process.send(data: data)
    }
    func contentChanged(_ terminal: CmdyTerminal) {
        contentChanges += 1
        guard captureSnapshots, !snapshotScheduled else { return }
        snapshotScheduled = true
        let epoch = captureEpoch
        queue.asyncAfter(deadline: .now() + .milliseconds(1)) { [weak self] in
            guard let self, self.captureEpoch == epoch, self.snapshotScheduled else { return }
            self.snapshotScheduled = false
            self.lastCapturedSnapshot = self.terminal.captureTerminalSnapshot()
            self.captureCount += 1
        }
    }
    func setTitle(_ terminal: CmdyTerminal, title: String) {}
    func setCurrentDirectory(_ terminal: CmdyTerminal, directory: String?) {}
    func bell(_ terminal: CmdyTerminal) {}
    func clipboardCopy(_ terminal: CmdyTerminal, content: Data) {}
    func willReflow(_ terminal: CmdyTerminal) {}
    func didReflow(_ terminal: CmdyTerminal) {}
}

func emit(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

let args = CommandLine.arguments
if !(7...8).contains(args.count) || !["serial-owner", "serial-owner-reuse"].contains(args[6])
    || (args.count == 8 && !["on", "off"].contains(args[7])) {
    fputs("usage: PTYEngineProbe PYTHON WORKER DIRECTORY PAYLOAD SOCKET MODE [SNAPSHOTS:on|off]\n", stderr)
    exit(2)
}
let snapshots = args.count == 7 || args[7] == "on"
let host = Host(reuseReadBuffer: args[6] == "serial-owner-reuse", captureSnapshots: snapshots)
host.start(python: args[1], worker: args[2], directory: args[3], payload: args[4], socket: args[5])
emit(["ready": true, "mode": args[6], "childPID": host.process.shellPid,
      "snapshotMode": snapshots, "probeSnapshotCadenceMilliseconds": 1,
      "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
      "activeProcessorCount": ProcessInfo.processInfo.activeProcessorCount,
      "thermalState": ProcessInfo.processInfo.thermalState.rawValue])
while let line = readLine() {
    do {
        let command = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        switch command["command"] as? String {
        case "begin":
            host.begin(validation: command["validation"] as? Bool ?? false)
            emit(["ok": true])
        case "stats": emit(["ok": true, "stats": host.snapshot()])
        case "finish":
            let stopped = host.exited.wait(timeout: .now() + 5) == .success
            let record = host.snapshot()
            emit(["ok": stopped, "stats": record, "descriptorClosed": host.process.childfd == -1])
            if !stopped { host.process.terminate() }
            exit(stopped ? 0 : 1)
        default: emit(["ok": false, "error": "unknown command"])
        }
    } catch {
        emit(["ok": false, "error": "invalid control JSON"])
    }
}
host.process.terminate()
