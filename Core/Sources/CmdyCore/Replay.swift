import Foundation

/// The event-sourced substrate: every byte fed to the engine, appendable to
/// a session log, replayable to an identical screen. No wall clock lives in
/// the engine, so replay is bit-deterministic — this is both the test
/// oracle's transport and the future collaboration layer.
///
/// Format (.term): a line-oriented header, then length-prefixed chunks.
///   CMDY-REPLAY 1
///   cols=<n> rows=<n>
///   ----
///   [u32 LE chunk length][chunk bytes] …
public final class SessionRecorder {
    public private(set) var chunks: [[UInt8]] = []
    public let cols: Int
    public let rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }

    func record(_ bytes: ArraySlice<UInt8>) {
        chunks.append(Array(bytes))
    }

    public var totalBytes: Int {
        chunks.reduce(0) { total, chunk in
            total > Int.max - chunk.count ? Int.max : total + chunk.count
        }
    }

    public func serialize() -> Data {
        var out = Data()
        out.append(contentsOf: Array("CMDY-REPLAY 1\ncols=\(cols) rows=\(rows)\n----\n".utf8))
        for chunk in chunks {
            if chunk.isEmpty {
                var len: UInt32 = 0
                withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
                continue
            }
            var offset = 0
            while offset < chunk.count {
                let count = min(chunk.count - offset, Int(UInt32.max))
                var len = UInt32(count).littleEndian
                withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
                out.append(contentsOf: chunk[offset..<(offset + count)])
                offset += count
            }
        }
        return out
    }
}

public enum SessionReplay {
    public struct Log {
        public let cols: Int
        public let rows: Int
        public let chunks: [[UInt8]]
        /// All chunk bytes, concatenated.
        public var allBytes: [UInt8] { chunks.flatMap { $0 } }
    }

    public enum ReplayError: Error {
        case badHeader
        case truncated
        case invalidDimensions
        case tooLarge
    }

    public static func load(_ data: Data) throws -> Log {
        guard data.count <= 256 * 1024 * 1024 else { throw ReplayError.tooLarge }
        let bytes = [UInt8](data)
        guard let headerEnd = firstRange(of: Array("----\n".utf8), in: bytes) else {
            throw ReplayError.badHeader
        }
        let header = String(decoding: bytes[0..<headerEnd.lowerBound], as: UTF8.self)
        // Recorded oracle fixtures predate the public rename. New recordings
        // use CMDY; the read path remains backward compatible so existing
        // sessions and the locked regression corpus stay replayable forever.
        guard header.hasPrefix("CMDY-REPLAY 1")
                || header.hasPrefix("TERMITE-REPLAY 1")
        else { throw ReplayError.badHeader }
        var cols = 80, rows = 24
        for line in header.split(separator: "\n") where line.hasPrefix("cols=") {
            let parts = line.split(separator: " ")
            for part in parts {
                let kv = part.split(separator: "=")
                if kv.count == 2, kv[0] == "cols" { cols = Int(kv[1]) ?? 80 }
                if kv.count == 2, kv[0] == "rows" { rows = Int(kv[1]) ?? 24 }
            }
        }
        guard cols > 0, rows > 0, cols <= 4_096, rows <= 4_096 else {
            throw ReplayError.invalidDimensions
        }
        let (screenCells, overflow) = cols.multipliedReportingOverflow(by: rows)
        guard !overflow, screenCells <= 4_000_000 else {
            throw ReplayError.invalidDimensions
        }
        var chunks: [[UInt8]] = []
        var i = headerEnd.upperBound
        while i < bytes.count {
            guard i + 4 <= bytes.count else { throw ReplayError.truncated }
            let len = Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
            i += 4
            guard len <= 64 * 1024 * 1024 else { throw ReplayError.tooLarge }
            let (end, endOverflow) = i.addingReportingOverflow(len)
            guard !endOverflow, end <= bytes.count else { throw ReplayError.truncated }
            chunks.append(Array(bytes[i..<i + len]))
            guard chunks.count <= 1_000_000 else { throw ReplayError.tooLarge }
            i = end
        }
        return Log(cols: cols, rows: rows, chunks: chunks)
    }

    /// Replay a log into a fresh engine; the resulting screen is identical
    /// to the recorded session's, every time.
    public static func replay(_ log: Log, scrollback: Int = 10_000) -> CmdyTerminal {
        let term = CmdyTerminal(cols: log.cols, rows: log.rows, scrollback: scrollback)
        for chunk in log.chunks {
            term.feed(chunk)
        }
        return term
    }

    private static func firstRange(of needle: [UInt8], in haystack: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<start + needle.count]) == needle {
                return start..<(start + needle.count)
            }
        }
        return nil
    }
}
