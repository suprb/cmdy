import Foundation

/// A small, language-neutral queue for feedback captured from an Extension's
/// live surface. The HTTP payload remains the ABI; this helper only gives Swift
/// Extensions the same pending/resolved behavior without inventing it again.
public final class CmdyFeedbackStore: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [[String: Any]] = []

    public init() {}

    /// Normalize and retain one feedback record. Callers may attach arbitrary
    /// JSON-safe context under `context`; the common fields stay predictable.
    @discardableResult
    public func add(_ payload: [String: Any]) -> [String: Any] {
        var record = payload
        record["version"] = 1
        record["id"] = (payload["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? UUID().uuidString.lowercased()
        record["timestamp"] = payload["timestamp"] as? String
            ?? ISO8601DateFormatter().string(from: Date())
        record["status"] = payload["status"] as? String ?? "open"

        lock.lock()
        records.append(record)
        if records.count > 500 { records.removeFirst(records.count - 500) }
        lock.unlock()
        return record
    }

    public func list(status: String? = nil) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        guard let status, !status.isEmpty else { return records }
        return records.filter { ($0["status"] as? String) == status }
    }

    @discardableResult
    public func resolve(id: String, resolution: String? = nil) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.firstIndex(where: { ($0["id"] as? String) == id }) else {
            return nil
        }
        records[index]["status"] = "resolved"
        records[index]["resolvedAt"] = ISO8601DateFormatter().string(from: Date())
        if let resolution, !resolution.isEmpty { records[index]["resolution"] = resolution }
        return records[index]
    }

    @discardableResult
    public func clear(resolvedOnly: Bool = false) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let before = records.count
        if resolvedOnly {
            records.removeAll { ($0["status"] as? String) == "resolved" }
        } else {
            records.removeAll()
        }
        return before - records.count
    }
}
