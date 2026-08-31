import Foundation

struct BridgeProcessResult: Sendable {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
}

enum BridgeProcessCaptureError: LocalizedError {
    case timedOut(executable: String, seconds: TimeInterval, output: String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let executable, let seconds, let output):
            let suffix = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return suffix.isEmpty
                ? "\(executable) timed out after \(Int(seconds))s"
                : "\(executable) timed out after \(Int(seconds))s:\n\(suffix)"
        }
    }
}

enum BridgeProcessCapture {
    private final class Reader: @unchecked Sendable {
        private let handle: FileHandle
        private let limit: Int
        private(set) var data = Data()
        private(set) var truncated = false

        init(_ handle: FileHandle, limit: Int) {
            self.handle = handle
            self.limit = min(max(0, limit), 256 * 1024 * 1024)
            data.reserveCapacity(min(self.limit, 64 * 1024))
        }

        func drain() {
            while true {
                guard let chunk = try? handle.read(upToCount: 64 * 1024),
                      !chunk.isEmpty else { return }
                let remaining = max(0, limit - data.count)
                if remaining > 0 { data.append(chunk.prefix(remaining)) }
                if chunk.count > remaining { truncated = true }
            }
        }

        func cancel() {
            try? handle.close()
        }
    }

    static func run(
        executable: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 600,
        stdoutLimit: Int = 16 * 1024 * 1024,
        stderrLimit: Int = 4 * 1024 * 1024
    ) throws -> BridgeProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        let stdout = Reader(stdoutPipe.fileHandleForReading, limit: stdoutLimit)
        let stderr = Reader(stderrPipe.fileHandleForReading, limit: stderrLimit)
        let readers = DispatchGroup()
        for reader in [stdout, stderr] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                reader.drain()
                readers.leave()
            }
        }

        let boundedTimeout = timeout.isFinite
            ? min(max(0.1, timeout), 24 * 60 * 60)
            : 600
        let deadline = Date().addingTimeInterval(boundedTimeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(1)
            while process.isRunning, Date() < grace {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            finishReading([stdout, stderr], group: readers)
            let combined = String(decoding: stdout.data + stderr.data, as: UTF8.self)
            throw BridgeProcessCaptureError.timedOut(
                executable: executable.lastPathComponent,
                seconds: boundedTimeout,
                output: combined)
        }

        process.waitUntilExit()
        finishReading([stdout, stderr], group: readers)
        return BridgeProcessResult(
            terminationStatus: process.terminationStatus,
            stdout: stdout.data,
            stderr: stderr.data,
            stdoutTruncated: stdout.truncated,
            stderrTruncated: stderr.truncated)
    }

    private static func finishReading(_ readers: [Reader], group: DispatchGroup) {
        if group.wait(timeout: .now() + 1) == .timedOut {
            readers.forEach { $0.cancel() }
            group.wait()
        }
    }

    static func runAsync(
        executable: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 600,
        stdoutLimit: Int = 16 * 1024 * 1024,
        stderrLimit: Int = 4 * 1024 * 1024
    ) async throws -> BridgeProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try run(
                        executable: executable,
                        arguments: arguments,
                        currentDirectoryURL: currentDirectoryURL,
                        environment: environment,
                        timeout: timeout,
                        stdoutLimit: stdoutLimit,
                        stderrLimit: stderrLimit))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
