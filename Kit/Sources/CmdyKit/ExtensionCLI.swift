import AppKit
import Foundation
import ProductIdentity

final class CLIHTTPResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = (status: 0, json: [String: Any]())

    func complete(status: Int, json: [String: Any]) {
        lock.lock()
        value = (status, json)
        lock.unlock()
    }

    func snapshot() -> (status: Int, json: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Headless authoring commands. They use the same manifest parser and live
/// HTTP controller as the app, so `validate`, `install`, and `dev` cannot drift
/// into a second interpretation of the extension contract.
public enum ExtensionCLI {
    private static let identity = ProductIdentity.current

    public static func run(_ arguments: [String]) -> Never {
        guard let verb = arguments.first else { usage() }
        switch verb {
        case "dev": dev(Array(arguments.dropFirst()))
        case "validate": validate(Array(arguments.dropFirst()))
        case "new": create(Array(arguments.dropFirst()))
        case "install": install(Array(arguments.dropFirst()))
        case "enable": setEnabled(Array(arguments.dropFirst()), enabled: true)
        case "disable": setEnabled(Array(arguments.dropFirst()), enabled: false)
        case "trust": trust(Array(arguments.dropFirst()), trusted: true)
        case "untrust": trust(Array(arguments.dropFirst()), trusted: false)
        case "trusted": listTrusted()
        case "list": listInstalled()
        default: usage("unknown extension command '\(verb)'")
        }
    }

    private static func dev(_ arguments: [String]) -> Never {
        guard let rawPath = arguments.first, !rawPath.hasPrefix("--") else {
            usage("extension dev needs a file or directory")
        }
        var capabilityNames: [String] = []
        var index = 1
        while index < arguments.count {
            guard arguments[index] == "--capability", index + 1 < arguments.count else {
                usage("use --capability <name>")
            }
            capabilityNames.append(arguments[index + 1])
            index += 2
        }
        for name in capabilityNames where ExtensionCapability(rawValue: name) == nil {
            die("unknown capability '\(name)'\n\(capabilityHelp())")
        }
        let source = expandedURL(rawPath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            die("no extension source at \(source.path)")
        }
        let connection = requireLiveConnection()
        var body: [String: Any] = ["path": source.path]
        if !capabilityNames.isEmpty { body["capabilities"] = capabilityNames }
        let started = request(connection, method: "POST", path: "/v1/extensions/dev", body: body)
        guard started.status == 200, let session = started.json["session"] as? String else {
            die(started.json["error"] as? String ?? "could not start development extension")
        }

        print("\(identity.titleName) extension development")
        print("  source: \(source.path)")
        print("  session: \(session)")
        print("  watching; press Control-C to stop")
        fflush(stdout)

        var lastSequence = 0
        var failures = 0
        while true {
            let heartbeat = request(connection, method: "POST",
                                    path: "/v1/extensions/dev/\(session)/heartbeat")
            let status = request(connection, method: "GET",
                                 path: "/v1/extensions/dev/\(session)")
            if heartbeat.status != 200 || status.status != 200 {
                failures += 1
                if failures >= 4 {
                    die("\(identity.titleName) development session ended")
                }
            } else {
                failures = 0
            }
            for log in status.json["logs"] as? [[String: Any]] ?? [] {
                let sequence = log["sequence"] as? Int ?? 0
                guard sequence > lastSequence else { continue }
                lastSequence = sequence
                let stream = log["stream"] as? String ?? "extension"
                let text = log["text"] as? String ?? ""
                print("[\(stream)] \(text)")
            }
            fflush(stdout)
            Thread.sleep(forTimeInterval: 0.65)
        }
    }

    private static func validate(_ arguments: [String]) -> Never {
        guard let path = arguments.first else { usage("extension validate needs a directory") }
        do {
            let manifest = try validatedManifest(at: expandedURL(path))
            print("valid \(identity.titleName) extension")
            print("  \(manifest.name) \(manifest.version)")
            print("  id: \(manifest.id)")
            print("  entrypoint: \(manifest.entrypoint)")
            print("  manifest: v\(manifest.manifestVersion)\(manifest.isLegacy ? " (legacy full access)" : "")")
            print("  capabilities: \(manifest.effectiveCapabilities.map(\.rawValue).sorted().joined(separator: ", "))")
            exit(0)
        } catch { die(error.localizedDescription) }
    }

    private static func create(_ arguments: [String]) -> Never {
        guard let path = arguments.first else { usage("extension new needs a directory") }
        let directory = expandedURL(path)
        let name = directory.lastPathComponent
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            die("\(directory.path) already exists")
        }
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let component = idComponent(name)
            let manifest = try ExtensionManifest(
                id: "local.\(component)", name: name, entrypoint: "extension.py",
                capabilities: [.events, .panesRead, .commands, .surfaces, .notifications],
                description: "A \(identity.titleName) extension")
            try manifest.encoded().write(to: directory.appendingPathComponent("manifest.json"),
                                         options: .atomic)
            let source = samplePython(id: "local.\(component)", name: name)
            let executable = directory.appendingPathComponent("extension.py")
            try source.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: executable.path)
            print("created \(directory.path)")
            print("run: \(identity.executableName) extension dev "
                + shellQuote(directory.path))
            exit(0)
        } catch { die(error.localizedDescription) }
    }

    private static func install(_ arguments: [String]) -> Never {
        guard let path = arguments.first else { usage("extension install needs a directory") }
        let source = expandedURL(path)
        do {
            let manifest = try validatedManifest(at: source)
            let root = PluginManager.extensionsDirectory
            let destination = root
                .appendingPathComponent(manifest.id, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                die("\(manifest.id) is already installed; remove it or use the marketplace updater")
            }
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
            let staging = root.appendingPathComponent(
                ".install-\(manifest.id)-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: source, to: staging)
            _ = try validatedManifest(at: staging)
            try FileManager.default.moveItem(at: staging, to: destination)
            print("installed \(manifest.name) to \(destination.path)")
            if let connection = liveConnection() {
                let response = request(connection, method: "POST", path: "/v1/extensions/reload",
                                       body: ["id": manifest.id])
                if response.status == 200 {
                    print("running now in \(identity.titleName)")
                }
                else { print("installed but not started: \(response.json["error"] as? String ?? "reload failed")") }
            } else {
                print("It will start when \(identity.titleName) opens.")
            }
            print("Enable or disable it in View > Extensions.")
            exit(0)
        } catch { die(error.localizedDescription) }
    }

    private static func trust(_ arguments: [String], trusted: Bool) -> Never {
        guard let path = arguments.first else {
            usage("extension \(trusted ? "trust" : "untrust") needs a project directory")
        }
        let root = expandedURL(path)
        let markerNames = [identity.projectDirectoryName]
            + identity.legacyProjectDirectoryNames
        guard markerNames.contains(where: {
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent($0).path)
        }) else {
            die("\(root.path) has no \(identity.projectDirectoryName) directory")
        }
        let store = ExtensionTrustStore(
            url: ConfigFile.directory.appendingPathComponent("extension-trust.json"))
        do {
            if trusted { try store.trust(root) } else { try store.revoke(root) }
            print("\(trusted ? "trusted" : "revoked") \(root.path)")
            exit(0)
        } catch { die(error.localizedDescription) }
    }

    private static func listTrusted() -> Never {
        let store = ExtensionTrustStore(
            url: ConfigFile.directory.appendingPathComponent("extension-trust.json"))
        let projects = store.trustedProjects()
        if projects.isEmpty {
            print("No trusted \(identity.titleName) projects")
        }
        else { projects.forEach { print($0) } }
        exit(0)
    }

    private static func listInstalled() -> Never {
        let root = PluginManager.pluginsDirectory
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        var count = 0
        for directory in directories.sorted(by: { $0.path < $1.path }) {
            guard let manifest = try? ExtensionManifest.load(from: directory) else { continue }
            count += 1
            let state = manifest.enabled ? "enabled" : "disabled"
            print("\(manifest.id)\t\(manifest.version)\t\(state)\t\(manifest.name)")
        }
        if count == 0 {
            print("No installed \(identity.titleName) extensions")
        }
        exit(0)
    }

    fileprivate struct Connection {
        let port: Int
        let token: String
    }

    fileprivate static func requireLiveConnection() -> Connection {
        if let connection = liveConnection() { return connection }

        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", bundle.path]
            try? process.run()
            for _ in 0..<40 {
                Thread.sleep(forTimeInterval: 0.2)
                if let connection = liveConnection() { return connection }
            }
        }
        die("\(identity.titleName) is not running. Open "
            + "\(identity.appBundleName), then run this command again.")
    }

    private static func setEnabled(_ arguments: [String], enabled: Bool) -> Never {
        guard let id = arguments.first else {
            usage("extension \(enabled ? "enable" : "disable") needs an Extension id")
        }
        let root = PluginManager.extensionsDirectory
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        guard let directory = directories.first(where: {
            (try? ExtensionManifest.load(from: $0).id) == id
                || $0.lastPathComponent == id
        }) else {
            die("no installed \(identity.titleName) Extension '\(id)'")
        }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        do {
            let manifest = try ExtensionManifest.load(from: directory)
            if let connection = liveConnection() {
                let response = request(connection, method: "POST", path: "/v1/extensions/state",
                                       body: ["id": manifest.id, "enabled": enabled])
                guard response.status == 200 else {
                    die(response.json["error"] as? String ?? "lifecycle change failed")
                }
            } else {
                let data = try BoundedFileReader.data(
                    at: manifestURL, maxBytes: 1024 * 1024)
                guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { die("manifest.json is not an object") }
                object["enabled"] = enabled
                try JSONSerialization.data(withJSONObject: object,
                                           options: [.prettyPrinted, .sortedKeys])
                    .write(to: manifestURL, options: .atomic)
            }
            print("\(enabled ? "enabled" : "disabled") \(manifest.id)")
            exit(0)
        } catch { die(error.localizedDescription) }
    }

    fileprivate static func liveConnection() -> Connection? {
        let discoveries = [
            ConfigFile.directory.appendingPathComponent("extension-api.json"),
            ConfigFile.directory.appendingPathComponent("plugin-api.json"),
        ]
        func read() -> Connection? {
            for discovery in discoveries {
                guard let data = try? BoundedFileReader.data(
                        at: discovery, maxBytes: 64 * 1024),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let port = object["port"] as? Int,
                      let token = object["token"] as? String,
                      (1...65_535).contains(port),
                      !token.isEmpty, token.count <= 4_096 else { continue }
                return Connection(port: port, token: token)
            }
            return nil
        }
        guard let connection = read(),
              request(connection, method: "GET", path: "/health",
                      authenticated: false).status == 200 else { return nil }
        return connection
    }

    private static func validatedManifest(at directory: URL) throws -> ExtensionManifest {
        let manifest = try ExtensionManifest.load(from: directory)
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let entrypoint = directory.appendingPathComponent(manifest.entrypoint)
            .standardizedFileURL
        guard entrypoint.resolvingSymlinksInPath().path.hasPrefix(root) else {
            throw ExtensionManifestError.unsafeEntrypoint(manifest.entrypoint)
        }
        guard FileManager.default.fileExists(atPath: entrypoint.path) else {
            throw ExtensionManifestError.unavailableEntrypoint(entrypoint.path)
        }
        guard FileManager.default.isExecutableFile(atPath: entrypoint.path) else {
            throw ExtensionManifestError.unavailableEntrypoint(
                "\(entrypoint.path) (run chmod +x)")
        }
        return manifest
    }

    fileprivate static func request(_ connection: Connection, method: String, path: String,
                                body: [String: Any]? = nil,
                                authenticated: Bool = true,
                                timeout: TimeInterval = 5) -> (status: Int, json: [String: Any]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(connection.port)\(path)")!)
        request.httpMethod = method
        if authenticated {
            request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = timeout
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
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
        }
        return result.snapshot()
    }

    private static func samplePython(id: String, name: String) -> String {
        let portKey = identity.environmentKey("PORT")
        let tokenKey = identity.environmentKey("TOKEN")
        return """
        #!/usr/bin/env python3
        import json, os, urllib.request

        base = f"http://127.0.0.1:{os.environ['\(portKey)']}"
        headers = {"Authorization": f"Bearer {os.environ['\(tokenKey)']}",
                   "Content-Type": "application/json"}

        def post(path, body):
            request = urllib.request.Request(base + path, json.dumps(body).encode(), headers, method="POST")
            return json.load(urllib.request.urlopen(request))

        post("/v1/commands", {"id": "\(id).hello", "title": "\(name): Hello"})
        request = urllib.request.Request(base + "/v1/events", headers=headers)
        with urllib.request.urlopen(request) as events:
            for raw in events:
                if not raw.startswith(b"data: "):
                    continue
                event = json.loads(raw[6:])
                if event.get("kind") == "command" and event.get("id") == "\(id).hello":
                    post("/v1/notify", {"title": "\(name)", "body": "The extension is live."})
        """
    }

    fileprivate static func expandedURL(_ path: String) -> URL {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath,
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL
    }

    fileprivate static func idComponent(_ name: String) -> String {
        let value = name.lowercased().map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber
                || character == "-" || character == "_") ? character : "-"
        }
        let result = String(value).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "extension" : result
    }

    fileprivate static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func capabilityHelp() -> String {
        ExtensionCapability.allCases
            .map { "  \($0.rawValue): \($0.explanation)" }.joined(separator: "\n")
    }

    private static func usage(_ error: String? = nil) -> Never {
        if let error { FileHandle.standardError.write(Data((error + "\n\n").utf8)) }
        print("""
        usage: \(identity.executableName) extension <command>

          new <directory>                 create a minimal extension
          dev <path> [--capability NAME]  run, watch, and restart it live
          validate <directory>            check its manifest
          install <directory>             install a local extension
          enable <id>                     enable and start an installed extension
          disable <id>                    stop and disable an installed extension
          list                            list installed extensions
          trust <project>                 allow \(identity.projectDirectoryName)/extensions in a project
          untrust <project>               revoke project trust
          trusted                         list trusted projects

        \(capabilityHelp())
        """)
        exit(error == nil ? 0 : 1)
    }

    private static func die(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

/// Channel connector authoring and user-owned Inbox/Outbox commands. A Channel
/// is packaged and installed as an ordinary Extension; this shorter on-ramp
/// scaffolds the required capability and a complete Receive/Reply loop.
public enum ChannelCLI {
    private static let identity = ProductIdentity.current

    public static func run(_ arguments: [String]) -> Never {
        guard let verb = arguments.first else { usage() }
        switch verb {
        case "new": create(Array(arguments.dropFirst()))
        case "list": listChannels()
        case "items": listItems()
        case "replies": listReplies()
        case "doctor": doctor(Array(arguments.dropFirst()))
        case "remove": remove(Array(arguments.dropFirst()))
        case "reply": reply(Array(arguments.dropFirst()))
        default: usage("unknown Channel command '\(verb)'")
        }
    }

    private static func create(_ arguments: [String]) -> Never {
        guard let rawPath = arguments.first, !rawPath.hasPrefix("--") else {
            usage("channel new needs a directory")
        }
        let directory = ExtensionCLI.expandedURL(rawPath)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            die("\(directory.path) already exists")
        }
        let name = directory.lastPathComponent
        let component = ExtensionCLI.idComponent(name)
        let extensionID = "local.\(component)"
        let staging = directory.deletingLastPathComponent().appendingPathComponent(
            ".\(directory.lastPathComponent)-channel-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: true)
            let manifest = try ExtensionManifest(
                id: extensionID, name: name, entrypoint: "channel.py",
                capabilities: [.channels, .events],
                description: "A \(identity.titleName) Channel connector")
            try manifest.encoded().write(
                to: staging.appendingPathComponent("manifest.json"), options: .atomic)
            let source = samplePython(extensionID: extensionID, name: name)
            let executable = staging.appendingPathComponent("channel.py")
            try source.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path)
            try FileManager.default.moveItem(at: staging, to: directory)
            print("created \(identity.titleName) Channel connector at \(directory.path)")
            print("run: \(identity.executableName) extension dev "
                + ExtensionCLI.shellQuote(directory.path))
            exit(0)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            die(error.localizedDescription)
        }
    }

    private static func listChannels() -> Never {
        let response = ExtensionCLI.request(
            ExtensionCLI.requireLiveConnection(), method: "GET", path: "/v1/channels")
        guard response.status == 200 else {
            die(response.json["error"] as? String ?? "could not list Channels")
        }
        let channels = response.json["channels"] as? [[String: Any]] ?? []
        if channels.isEmpty { print("No \(identity.titleName) Channels") }
        for channel in channels {
            let id = channel["id"] as? String ?? "?"
            let name = channel["name"] as? String ?? id
            let service = channel["service"] as? String ?? "?"
            let connected = channel["connected"] as? Bool == true ? "connected" : "offline"
            print("\(id)\t\(connected)\t\(service)\t\(name)")
        }
        exit(0)
    }

    private static func listItems() -> Never {
        let response = ExtensionCLI.request(
            ExtensionCLI.requireLiveConnection(), method: "GET",
            path: "/v1/channel-work-items")
        guard response.status == 200 else {
            die(response.json["error"] as? String ?? "could not list Work Items")
        }
        let items = response.json["workItems"] as? [[String: Any]] ?? []
        if items.isEmpty { print("\(identity.titleName) Work Inbox is empty") }
        for item in items {
            let channel = item["channel"] as? String ?? "?"
            let id = item["id"] as? String ?? "?"
            let status = item["status"] as? String ?? "?"
            let title = item["title"] as? String ?? id
            print("\(channel)\t\(id)\t\(status)\t\(title)")
        }
        exit(0)
    }

    private static func listReplies() -> Never {
        let response = ExtensionCLI.request(
            ExtensionCLI.requireLiveConnection(), method: "GET",
            path: "/v1/channel-replies")
        guard response.status == 200 else {
            die(response.json["error"] as? String ?? "could not list Channel replies")
        }
        let replies = response.json["replies"] as? [[String: Any]] ?? []
        if replies.isEmpty { print("\(identity.titleName) Channel Outbox is empty") }
        for reply in replies {
            let id = reply["id"] as? String ?? "?"
            let state = reply["state"] as? String ?? "?"
            let channel = reply["channel"] as? String ?? "?"
            let workItem = reply["workItem"] as? String ?? "?"
            print("\(id)\t\(state)\t\(channel)\t\(workItem)")
        }
        exit(0)
    }

    private static func doctor(_ arguments: [String]) -> Never {
        guard arguments.count <= 1 else { usage("channel doctor accepts at most one id") }
        let connection = ExtensionCLI.requireLiveConnection()
        let channels: [[String: Any]]
        if let id = arguments.first {
            guard id.utf8.count <= 128, !id.isEmpty, id.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "."
                    || $0 == "-" || $0 == "_")
            }) else { usage("channel doctor needs a valid Channel id") }
            let response = ExtensionCLI.request(
                connection, method: "GET", path: "/v1/channels/\(id)/health")
            guard response.status == 200,
                  let channel = response.json["channel"] as? [String: Any] else {
                die(response.json["error"] as? String ?? "Channel not found")
            }
            channels = [channel]
        } else {
            let response = ExtensionCLI.request(
                connection, method: "GET", path: "/v1/channels")
            guard response.status == 200 else {
                die(response.json["error"] as? String ?? "could not inspect Channels")
            }
            channels = response.json["channels"] as? [[String: Any]] ?? []
        }
        let replyResponse = ExtensionCLI.request(
            connection, method: "GET", path: "/v1/channel-replies")
        guard replyResponse.status == 200 else {
            die(replyResponse.json["error"] as? String ?? "could not inspect replies")
        }
        let replies = replyResponse.json["replies"] as? [[String: Any]] ?? []
        let lines = doctorLines(channels: channels, replies: replies)
        if lines.isEmpty { print("No \(identity.titleName) Channels") }
        lines.forEach { print($0) }
        exit(0)
    }

    /// Pure formatter kept internal so the CLI's distinction between process
    /// connectivity and provider health remains regression-testable.
    static func doctorLines(channels: [[String: Any]],
                            replies: [[String: Any]]) -> [String] {
        var lines: [String] = []
        let sorted = channels.sorted {
            ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "")
        }
        for (index, channel) in sorted.enumerated() {
            if index > 0 { lines.append("") }
            let id = channel["id"] as? String ?? "?"
            let name = channel["name"] as? String ?? id
            let connected = channel["connected"] as? Bool == true
            let health = channel["health"] as? [String: Any] ?? [:]
            let provider = health["status"] as? String ?? "offline"
            lines.append("\(id)  \(name)")
            lines.append("  connector process: \(connected ? "connected" : "offline")")
            lines.append("  provider health: \(provider)")
            if let value = health["lastSuccessAt"] as? String {
                lines.append("  last success: \(value)")
            }
            if let at = health["lastErrorAt"] as? String {
                let error = health["error"] as? String
                lines.append("  last error: \(at)\(error.map { " — \($0)" } ?? "")")
            } else if let error = health["error"] as? String {
                lines.append("  last error: \(error)")
            }
            if let value = health["nextRetryAt"] as? String {
                lines.append("  next retry: \(value)")
            }
            if let value = health["detail"] as? String {
                lines.append("  detail: \(value)")
            }
            let ambiguous = replies.filter {
                $0["channel"] as? String == id
                    && $0["state"] as? String
                        == CmdyChannelReplyState.verificationNeeded.rawValue
            }
            let delivering = replies.filter {
                $0["channel"] as? String == id
                    && $0["state"] as? String == CmdyChannelReplyState.delivering.rawValue
            }
            lines.append("  delivery attempts in progress: \(delivering.count)")
            lines.append("  replies needing verification: \(ambiguous.count)")
            for reply in ambiguous.prefix(8) {
                lines.append("    \(reply["id"] as? String ?? "?")")
            }
            if ambiguous.count > 8 {
                lines.append("    … and \(ambiguous.count - 8) more")
            }
        }
        return lines
    }

    private static func remove(_ arguments: [String]) -> Never {
        guard arguments.count == 2, arguments[1] == "--yes" else {
            usage("channel remove needs <channel> --yes because it deletes host state")
        }
        let response = ExtensionCLI.request(
            ExtensionCLI.requireLiveConnection(), method: "DELETE",
            path: "/v1/channels/\(arguments[0])")
        guard response.status == 200 else {
            die(response.json["error"] as? String ?? "could not remove Channel")
        }
        print("removed Channel \(arguments[0]) and its host-owned state")
        exit(0)
    }

    private static func reply(_ arguments: [String]) -> Never {
        guard arguments.count >= 3 else {
            usage("channel reply needs a Channel id, Work Item id, and message")
        }
        let channelID = arguments[0]
        let workItemID = arguments[1]
        let body = arguments.dropFirst(2).joined(separator: " ")
        let response = ExtensionCLI.request(
            ExtensionCLI.requireLiveConnection(), method: "POST",
            path: "/v1/channel-work-items/\(channelID)/\(workItemID)/replies",
            body: ["body": body, "kind": "result", "send": true])
        guard response.status == 200 else {
            die(response.json["error"] as? String ?? "could not queue reply")
        }
        let reply = response.json["reply"] as? [String: Any]
        print("queued Channel reply \(reply?["id"] as? String ?? "")")
        exit(0)
    }

    private static func samplePython(extensionID: String, name: String) -> String {
        let nameLiteral = (try? JSONEncoder().encode(name)).map {
            String(decoding: $0, as: UTF8.self)
        } ?? "\"Channel\""
        let portKey = identity.environmentKey("PORT")
        let tokenKey = identity.environmentKey("TOKEN")
        return """
        #!/usr/bin/env python3
        import json, os, urllib.request

        base = f"http://127.0.0.1:{os.environ['\(portKey)']}"
        headers = {"Authorization": f"Bearer {os.environ['\(tokenKey)']}",
                   "Content-Type": "application/json"}
        channel_id = "\(extensionID).inbox"
        display_name = \(nameLiteral)

        def request(path, body=None):
            data = None if body is None else json.dumps(body).encode()
            method = "GET" if body is None else "POST"
            req = urllib.request.Request(base + path, data, headers, method=method)
            return json.load(urllib.request.urlopen(req))

        def deliver(reply):
            # Persist the provider-call boundary before sending. If this
            # process dies after provider acceptance but before acknowledgement,
            # \(identity.titleName) will require verification instead of auto-retrying.
            request(f"/v1/channel-replies/{reply['id']}/attempt", {})
            # Replace this print with the provider's send-message API.
            print(f"outbound [{reply['conversationID']}]: {reply['body']}", flush=True)
            request(f"/v1/channel-replies/{reply['id']}/ack", {"delivered": True})

        registration = request("/v1/channels", {
            "id": channel_id,
            "name": display_name + " Inbox",
            "service": "Demo",
            "description": "A scaffolded \(identity.titleName) Channel",
            "replyCapabilities": ["reply"]
        })
        for pending in registration.get("pendingReplies", []):
            deliver(pending)

        # Replace this demo event with polling, webhooks, or the provider SDK.
        request(f"/v1/channels/{channel_id}/work-items", {
            "id": "welcome",
            "deliveryID": "demo-welcome-v1",
            "conversationID": "demo-thread",
            "senderName": display_name,
            "title": "Your Channel connector is live",
            "body": "Open Channels > Work Inbox, then try Agent, Shell, or Reply."
        })

        stream = urllib.request.Request(base + "/v1/events", headers=headers)
        with urllib.request.urlopen(stream) as events:
            for raw in events:
                if not raw.startswith(b"data: "):
                    continue
                event = json.loads(raw[6:])
                if event.get("kind") == "channel-reply":
                    deliver(event)
        """
    }

    private static func usage(_ error: String? = nil) -> Never {
        if let error { FileHandle.standardError.write(Data((error + "\n\n").utf8)) }
        print("""
        usage: \(identity.executableName) channel <command>

          new <directory>                    create a Channel Extension
          list                               list registered Channels
          items                              list the durable Work Inbox
          replies                            list every durable reply state
          doctor [channel]                   inspect process, provider, and ambiguous delivery health
          remove <channel> --yes              delete a Channel and its host state
          reply <channel> <item> <message>   explicitly queue a reply
        """)
        exit(error == nil ? 0 : 1)
    }

    private static func die(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

/// One-shot workflow authoring and execution. Actions are intentionally much
/// smaller than resident Extensions: they are discovered from disk when used,
/// execute in real terminal panes, and do not remain running in the background.
public enum ActionCLI {
    private static let identity = ProductIdentity.current

    public static func run(_ arguments: [String]) -> Never {
        guard let verb = arguments.first else { usage() }
        switch verb {
        case "new": create(Array(arguments.dropFirst()))
        case "install-starters": installStarters(Array(arguments.dropFirst()))
        case "validate": validate(Array(arguments.dropFirst()))
        case "list": list()
        case "run": execute(Array(arguments.dropFirst()))
        default: usage("unknown action command '\(verb)'")
        }
    }

    private static func installStarters(_ arguments: [String]) -> Never {
        guard arguments.isEmpty else { usage("action install-starters takes no arguments") }
        do {
            let result = try CmdyActionCatalog.installStarterActions()
            for action in result.installed { print("installed\t\(action.id)\t\(action.title)") }
            for action in result.skipped { print("kept\t\(action.id)\t\(action.title)") }
            if result.installed.isEmpty {
                print("Starter Actions are already installed")
            }
            exit(0)
        } catch { die(error.localizedDescription) }
    }

    private static func create(_ arguments: [String]) -> Never {
        guard let rawPath = arguments.first, !rawPath.hasPrefix("--") else {
            usage("action new needs a directory")
        }
        var command: String?
        var index = 1
        while index < arguments.count {
            guard arguments[index] == "--command", index + 1 < arguments.count else {
                usage("use --command <shell command>")
            }
            command = arguments[index + 1]
            index += 2
        }
        let directory = ExtensionCLI.expandedURL(rawPath)
        do {
            let manifest = try CmdyActionCatalog.createSample(
                at: directory, command: command)
            print("created \(identity.titleName) Action at \(manifest.path)")
            exit(0)
        } catch { die(error.localizedDescription) }
    }

    private static func validate(_ arguments: [String]) -> Never {
        guard let rawPath = arguments.first else {
            usage("action validate needs an action.json or Action directory")
        }
        let source = manifestURL(for: ExtensionCLI.expandedURL(rawPath))
        do {
            let action = try CmdyActionCatalog.load(from: source)
            print("valid \(identity.titleName) Action")
            print("  \(action.title)")
            print("  id: \(action.id)")
            print("  steps: \(action.steps.count)")
            if !action.inputs.isEmpty {
                print("  inputs: \(action.inputs.map(\.id).joined(separator: ", "))")
            }
            if let shortcut = action.shortcut {
                print("  shortcut: \(shortcut.descriptor)")
            }
            exit(0)
        } catch { die(error.localizedDescription) }
    }

    private static func list() -> Never {
        if let connection = ExtensionCLI.liveConnection() {
            let response = ExtensionCLI.request(
                connection, method: "GET", path: "/v1/actions")
            guard response.status == 200 else {
                die(response.json["error"] as? String ?? "could not list Actions")
            }
            let actions = response.json["actions"] as? [[String: Any]] ?? []
            if actions.isEmpty {
                print("No available \(identity.titleName) Actions")
            }
            for action in actions {
                let id = action["id"] as? String ?? "?"
                let title = action["title"] as? String ?? id
                let group = action["group"] as? String ?? "Actions"
                let shortcut = action["shortcut"] as? String
                print("\(id)\t\(group)\t\(title)\(shortcut.map { "\t\($0)" } ?? "")")
            }
            exit(0)
        }

        var discovery = CmdyActionCatalog.discover(
            in: CmdyActionCatalog.personalDirectory)
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                      isDirectory: true)
        let trustStore = ExtensionTrustStore(
            url: ConfigFile.directory.appendingPathComponent("extension-trust.json"))
        if let root = ProjectExtensionDiscovery.projectRoot(containing: cwd),
           trustStore.isTrusted(root) {
            let project = CmdyActionCatalog.discover(
                in: CmdyActionCatalog.projectDirectory(for: root),
                scope: .project(root))
            discovery = CmdyActionDiscovery(
                actions: discovery.actions + project.actions,
                issues: discovery.issues + project.issues)
        }
        if discovery.actions.isEmpty {
            print("No local \(identity.titleName) Actions")
        }
        for action in discovery.actions.sorted(by: { $0.id < $1.id }) {
            print("\(action.id)\t\(action.group)\t\(action.title)")
        }
        for issue in discovery.issues {
            FileHandle.standardError.write(
                Data(("warning: \(issue.path): \(issue.message)\n").utf8))
        }
        exit(0)
    }

    private static func execute(_ arguments: [String]) -> Never {
        guard let id = arguments.first, !id.hasPrefix("--") else {
            usage("action run needs an Action id")
        }
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard arguments[index] == "--input", index + 1 < arguments.count,
                  let separator = arguments[index + 1].firstIndex(of: "=") else {
                usage("use --input name=value")
            }
            let value = arguments[index + 1]
            let key = String(value[..<separator])
            guard !key.isEmpty else { usage("input name cannot be empty") }
            values[key] = String(value[value.index(after: separator)...])
            index += 2
        }
        let connection = ExtensionCLI.requireLiveConnection()
        let response = ExtensionCLI.request(
            connection, method: "POST", path: "/v1/actions/run",
            body: ["id": id, "inputs": values], timeout: 300)
        guard response.status == 200 else {
            die(response.json["error"] as? String ?? "Action failed")
        }
        print("started \(response.json["title"] as? String ?? id)")
        if let panes = response.json["panes"] as? [String], !panes.isEmpty {
            print("  panes: \(panes.joined(separator: ", "))")
        }
        exit(0)
    }

    private static func manifestURL(for source: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return source.appendingPathComponent("action.json")
        }
        return source
    }

    private static func usage(_ error: String? = nil) -> Never {
        if let error { FileHandle.standardError.write(Data((error + "\n\n").utf8)) }
        print("""
        usage: \(identity.executableName) action <command>

          new <directory> [--command CMD]  create a \(identity.titleName) Action
          install-starters                  install five editable personal Actions
          validate <path>                  validate action.json
          list                             list Actions for the current context
          run <id> [--input name=value]    run an Action in the live terminal
        """)
        exit(error == nil ? 0 : 1)
    }

    private static func die(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
