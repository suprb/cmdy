import Foundation

enum BridgeBoundedFileReader {
    static func data(at url: URL, maxBytes: Int) throws -> Data {
        let limit = min(max(maxBytes, 0), 1024 * 1024 * 1024)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        data.reserveCapacity(min(limit, 64 * 1024))
        while true {
            let remainingWithSentinel = limit - data.count + 1
            guard remainingWithSentinel > 0 else {
                throw CocoaError(.fileReadTooLarge)
            }
            guard let chunk = try handle.read(
                upToCount: min(64 * 1024, remainingWithSentinel)
            ), !chunk.isEmpty else {
                return data
            }
            data.append(chunk)
            guard data.count <= limit else {
                throw CocoaError(.fileReadTooLarge)
            }
        }
    }
}

enum BridgePIDFile {
    static func previousPID(at url: URL, excluding currentPID: pid_t) -> pid_t? {
        guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let data = try? BridgeBoundedFileReader.data(at: url, maxBytes: 64),
              let text = String(data: data, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(
                in: .whitespacesAndNewlines)),
              pid > 1,
              pid != currentPID else { return nil }
        return pid
    }

    static func writeCurrentPID(_ pid: pid_t, to url: URL) {
        guard pid > 1 else { return }
        try? Data("\(pid)".utf8).write(to: url, options: .atomic)
    }
}
