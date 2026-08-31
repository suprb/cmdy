import Foundation

public enum BoundedFileReaderError: LocalizedError {
    case tooLarge(path: String, maxBytes: Int)
    case invalidUTF8(path: String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let path, let maxBytes):
            return "\(path) exceeds the \(maxBytes / (1024 * 1024)) MB read limit"
        case .invalidUTF8(let path):
            return "\(path) is not valid UTF-8 text"
        }
    }
}

/// Read local configuration, manifest, and editor files without trusting their
/// size metadata. The extra byte detects a file that grows between stat/open.
public enum BoundedFileReader {
    public static func data(
        at url: URL,
        maxBytes: Int
    ) throws -> Data {
        let limit = min(max(maxBytes, 0), 1024 * 1024 * 1024)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        data.reserveCapacity(min(limit, 64 * 1024))
        while true {
            let remainingWithSentinel = limit - data.count + 1
            guard remainingWithSentinel > 0 else {
                throw BoundedFileReaderError.tooLarge(
                    path: url.path, maxBytes: limit)
            }
            let requestSize = min(64 * 1024, remainingWithSentinel)
            guard let chunk = try handle.read(upToCount: requestSize),
                  !chunk.isEmpty else { return data }
            data.append(chunk)
            guard data.count <= limit else {
                throw BoundedFileReaderError.tooLarge(
                    path: url.path, maxBytes: limit)
            }
        }
    }

    public static func utf8String(
        at url: URL,
        maxBytes: Int
    ) throws -> String {
        let data = try data(at: url, maxBytes: maxBytes)
        guard let string = String(data: data, encoding: .utf8) else {
            throw BoundedFileReaderError.invalidUTF8(path: url.path)
        }
        return string
    }
}
