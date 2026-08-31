import Foundation
import ProductIdentity

/// Adapter for existing command output. It always writes the original text to
/// stdout first; attaching a native Surface is an additive best effort and can
/// never change the producer's exit status or portable output.
public enum SurfaceCLI {
    public static func run(_ arguments: [String]) -> Never {
        guard let kindName = arguments.first,
              let kind = SurfaceKind(rawValue: kindName) else { usage() }
        let options = parseOptions(Array(arguments.dropFirst()))
        let (input, truncated, lastByte) = readAndForwardInput()
        if lastByte != nil, lastByte != 0x0A {
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        var fallback = String(decoding: input, as: UTF8.self)
        if truncated {
            fallback += "\n… surface preview truncated at 16 MB …"
        }

        guard let connection = connection() else { exit(0) }
        do {
            let document = try makeDocument(
                kind: kind,
                id: options["id"] ?? "surface-\(UUID().uuidString.prefix(8))",
                title: options["title"] ?? defaultTitle(kind),
                pane: options["pane"], block: options["block"] ?? "current",
                fallback: fallback)
            let response = request(connection, data: try document.encoded())
            if response.status != 200,
               let error = response.json["error"] as? String {
                FileHandle.standardError.write(Data(
                    ("\(ProductIdentity.current.slug) surface: \(error)\n").utf8))
            }
        } catch {
            FileHandle.standardError.write(Data(
                ("\(ProductIdentity.current.slug) surface: \(error.localizedDescription)\n").utf8))
        }
        exit(0)
    }

    static func makeDocument(kind: SurfaceKind, id: String, title: String,
                             pane: String?, block: String,
                             fallback: String) throws -> SurfaceDocument {
        switch kind {
        case .table:
            let objects = structuredObjects(fallback)
            let keys = Array(Set(objects.flatMap(\.keys))).sorted()
            let keyMap = uniqueColumnIDs(keys.isEmpty ? ["value"] : keys)
            let columns = keyMap.map {
                SurfaceColumn(id: $0.id, title: $0.key)
            }
            let rows: [SurfaceRow]
            if objects.isEmpty {
                rows = fallback.split(whereSeparator: \.isNewline).enumerated().map {
                    SurfaceRow(id: "row-\($0.offset)",
                               cells: ["value": .string(String($0.element))])
                }
            } else {
                rows = objects.enumerated().map { index, object in
                    let suffix = object["id"].map(stringValue).map(safeID) ?? "item"
                    return SurfaceRow(
                        id: "row-\(index)-\(suffix)",
                        cells: Dictionary(uniqueKeysWithValues: keyMap.compactMap { mapping in
                            object[mapping.key].map { (mapping.id, surfaceValue($0)) }
                        }))
                }
            }
            return try SurfaceDocument(id: id, kind: .table, title: title,
                                       pane: pane, block: block, fallback: fallback,
                                       columns: columns, rows: rows)
        case .task:
            let objects = structuredObjects(fallback)
            let tasks = objects.enumerated().map { index, object -> SurfaceTask in
                let rawStatus = object["status"] as? String ?? object["state"] as? String ?? "pending"
                let status = SurfaceTask.Status(rawValue: rawStatus.lowercased()) ?? .pending
                let suffix = object["id"].map(stringValue).map(safeID) ?? "item"
                return SurfaceTask(
                    id: "task-\(index)-\(suffix)",
                    label: object["label"].map(stringValue)
                        ?? object["name"].map(stringValue)
                        ?? object["id"].map(stringValue) ?? "Task \(index + 1)",
                    status: status,
                    detail: object["detail"].map(stringValue),
                    progress: (object["progress"] as? NSNumber)?.doubleValue,
                    durationMs: (object["durationMs"] as? NSNumber)?.intValue)
            }
            let fallbackTasks = fallback.split(whereSeparator: \.isNewline).enumerated().map {
                SurfaceTask(id: "task-\($0.offset)", label: String($0.element), status: .pending)
            }
            return try SurfaceDocument(id: id, kind: .task, title: title,
                                       pane: pane, block: block, fallback: fallback,
                                       tasks: tasks.isEmpty ? fallbackTasks : tasks)
        case .diff:
            return try SurfaceDocument(id: id, kind: .diff, title: title,
                                       pane: pane, block: block, fallback: fallback,
                                       diff: fallback)
        case .list:
            let rows = fallback.split(whereSeparator: \.isNewline).enumerated().map {
                SurfaceRow(id: "row-\($0.offset)",
                           cells: ["label": .string(String($0.element))])
            }
            return try SurfaceDocument(id: id, kind: .list, title: title,
                                       pane: pane, block: block, fallback: fallback,
                                       rows: rows)
        case .text:
            return try SurfaceDocument(id: id, kind: .text, title: title,
                                       pane: pane, block: block, fallback: fallback)
        case .form:
            throw SurfaceProtocolError.invalid(
                "forms are interactive and must be created through the Extension or Surface Protocol")
        }
    }

    private static func structuredObjects(_ text: String) -> [[String: Any]] {
        let data = Data(text.utf8)
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return [object]
        }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
    }

    private static func surfaceValue(_ value: Any) -> SurfaceValue {
        switch value {
        case let value as Bool: return .bool(value)
        case let value as NSNumber: return .number(value.doubleValue)
        case let value as String: return .string(value)
        case is NSNull: return .null
        default:
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            return .string(data.map { String(decoding: $0, as: UTF8.self) } ?? String(describing: value))
        }
    }

    private static func stringValue(_ value: Any) -> String {
        surfaceValue(value).description
    }

    private static func safeID(_ value: String) -> String {
        let mapped = value.map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber
                || character == "." || character == "-" || character == "_")
                ? character : "_"
        }
        let result = String(mapped.prefix(112))
        return result.isEmpty ? "value" : result
    }

    private static func uniqueColumnIDs(_ keys: [String]) -> [(key: String, id: String)] {
        var used = Set<String>()
        return keys.enumerated().map { index, key in
            let base = safeID(key)
            var candidate = base
            if used.contains(candidate) { candidate = "\(base)-\(index)" }
            while used.contains(candidate) { candidate += "_" }
            used.insert(candidate)
            return (key, candidate)
        }
    }

    private static func defaultTitle(_ kind: SurfaceKind) -> String {
        kind.rawValue.prefix(1).uppercased() + kind.rawValue.dropFirst()
    }

    private static func parseOptions(_ arguments: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index + 1 < arguments.count, arguments[index].hasPrefix("--") {
            result[String(arguments[index].dropFirst(2))] = arguments[index + 1]
            index += 2
        }
        return result
    }

    private struct Connection { let port: Int; let token: String }

    /// Preserve the command's complete portable stdout while retaining only a
    /// bounded preview for the optional native Surface.
    private static func readAndForwardInput() -> (
        data: Data,
        truncated: Bool,
        lastByte: UInt8?
    ) {
        let captureLimit = 16 * 1024 * 1024
        var captured = Data()
        captured.reserveCapacity(min(captureLimit, 64 * 1024))
        var truncated = false
        var lastByte: UInt8?
        while let chunk = try? FileHandle.standardInput.read(upToCount: 64 * 1024),
              !chunk.isEmpty {
            FileHandle.standardOutput.write(chunk)
            lastByte = chunk.last
            let remaining = max(0, captureLimit - captured.count)
            if remaining > 0 { captured.append(chunk.prefix(remaining)) }
            if chunk.count > remaining { truncated = true }
        }
        return (captured, truncated, lastByte)
    }

    private static func connection() -> Connection? {
        for url in [ConfigFile.directory.appendingPathComponent("extension-api.json"),
                    ConfigFile.directory.appendingPathComponent("plugin-api.json")] {
            guard let data = try? BoundedFileReader.data(
                    at: url, maxBytes: 64 * 1024),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let port = object["port"] as? Int,
                  let token = object["token"] as? String,
                  (1...65_535).contains(port),
                  !token.isEmpty, token.count <= 4_096 else { continue }
            return Connection(port: port, token: token)
        }
        return nil
    }

    private static func request(_ connection: Connection, data: Data)
        -> (status: Int, json: [String: Any]) {
        var request = URLRequest(url: URL(
            string: "http://127.0.0.1:\(connection.port)/v1/surfaces")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = 3
        let semaphore = DispatchSemaphore(value: 0)
        let result = CLIHTTPResultBox()
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            let json = data.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            } ?? [:]
            result.complete(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                json: json)
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 3) == .timedOut {
            task.cancel()
        }
        return result.snapshot()
    }

    private static func usage() -> Never {
        print("""
        usage: \(ProductIdentity.current.executableName) surface <list|table|diff|task|text> [options]

          --id ID       stable surface id
          --title TEXT  visible title
          --pane ID     target pane (focused pane by default)
          --block ID    current, last, or an explicit command block id

        Input is always preserved on stdout. JSON objects/JSON Lines become
        table rows or tasks; plain lines become a list. Native UI is additive.
        """)
        exit(1)
    }
}
