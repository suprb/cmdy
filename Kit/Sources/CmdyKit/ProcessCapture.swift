import Foundation

/// Bounded output from a subprocess. The pipe is drained while the child is
/// running, so verbose tools cannot deadlock after filling the kernel buffer.
public struct ProcessCaptureResult: Sendable {
    public let terminationStatus: Int32
    public let output: String
    public let outputWasTruncated: Bool
}

public enum ProcessCaptureError: LocalizedError {
    case timedOut(executable: String, seconds: TimeInterval, output: String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let executable, let seconds, let output):
            let duration = seconds.rounded() == seconds
                ? String(Int(seconds))
                : String(format: "%.1f", seconds)
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "\(executable) timed out after \(duration)s"
                : "\(executable) timed out after \(duration)s:\n\(detail)"
        }
    }
}

public enum ProcessCapture {
    private final class PipeReader: @unchecked Sendable {
        private let handle: FileHandle
        private let limit: Int
        private var data = Data()
        private(set) var truncated = false

        init(handle: FileHandle, limit: Int) {
            self.handle = handle
            self.limit = min(max(0, limit), 256 * 1024 * 1024)
            data.reserveCapacity(min(self.limit, 64 * 1024))
        }

        func drain() {
            while true {
                guard let chunk = try? handle.read(upToCount: 64 * 1024),
                      !chunk.isEmpty else { return }
                let remaining = max(0, limit - data.count)
                if remaining > 0 {
                    data.append(chunk.prefix(remaining))
                }
                if chunk.count > remaining {
                    truncated = true
                }
            }
        }

        func cancel() {
            try? handle.close()
        }

        var text: String {
            var value = String(decoding: data, as: UTF8.self)
            if truncated {
                if !value.isEmpty, !value.hasSuffix("\n") { value.append("\n") }
                value.append("… output truncated …")
            }
            return value
        }
    }

    /// Run a process synchronously while continuously draining merged
    /// stdout/stderr. Captured output is bounded even if the child is noisy.
    @discardableResult
    public static func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval = 600,
        outputLimit: Int = 1_048_576
    ) throws -> ProcessCaptureResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let reader = PipeReader(handle: pipe.fileHandleForReading, limit: outputLimit)
        let readerGroup = DispatchGroup()
        readerGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            reader.drain()
            readerGroup.leave()
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
            let graceDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < graceDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            finishReading(reader, group: readerGroup)
            throw ProcessCaptureError.timedOut(
                executable: executable.lastPathComponent,
                seconds: boundedTimeout,
                output: reader.text)
        }

        process.waitUntilExit()
        finishReading(reader, group: readerGroup)
        return ProcessCaptureResult(
            terminationStatus: process.terminationStatus,
            output: reader.text,
            outputWasTruncated: reader.truncated)
    }

    /// A child can exit after spawning a background descendant that inherited
    /// its stdout pipe. Preserve everything already drained, then close our
    /// read end instead of waiting forever for that unrelated process.
    private static func finishReading(_ reader: PipeReader, group: DispatchGroup) {
        if group.wait(timeout: .now() + 1) == .timedOut {
            reader.cancel()
            group.wait()
        }
    }
}
