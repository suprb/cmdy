import Foundation

/// Structured feedback captured from a surface bound through Bridge. Records
/// stay JSON-shaped so the MCP transport, cmdy SDK, and third-party agents
/// can all consume the same contract without linking this Swift module.
@MainActor
final class BridgeFeedbackStore {
    private var records: [[String: Any]] = []

    @discardableResult
    func add(_ payload: [String: Any]) -> [String: Any] {
        var record = payload
        record["version"] = 1
        record["id"] = (payload["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? UUID().uuidString.lowercased()
        record["timestamp"] = payload["timestamp"] as? String
            ?? ISO8601DateFormatter().string(from: Date())
        record["status"] = payload["status"] as? String ?? "open"
        records.append(record)
        if records.count > 500 { records.removeFirst(records.count - 500) }
        return record
    }

    func list(status: String? = nil, sessionId: String? = nil) -> [[String: Any]] {
        records.filter { record in
            let statusMatches = status.map { (record["status"] as? String) == $0 } ?? true
            let sessionMatches = sessionId.map { (record["sessionId"] as? String) == $0 } ?? true
            return statusMatches && sessionMatches
        }
    }

    @discardableResult
    func resolve(id: String, resolution: String? = nil) -> [String: Any]? {
        guard let index = records.firstIndex(where: { ($0["id"] as? String) == id }) else {
            return nil
        }
        records[index]["status"] = "resolved"
        records[index]["resolvedAt"] = ISO8601DateFormatter().string(from: Date())
        if let resolution, !resolution.isEmpty { records[index]["resolution"] = resolution }
        return records[index]
    }

    @discardableResult
    func clear(resolvedOnly: Bool = false, sessionId: String? = nil) -> Int {
        let before = records.count
        records.removeAll { record in
            let sessionMatches = sessionId.map { (record["sessionId"] as? String) == $0 } ?? true
            let statusMatches = !resolvedOnly || (record["status"] as? String) == "resolved"
            return sessionMatches && statusMatches
        }
        return before - records.count
    }
}
