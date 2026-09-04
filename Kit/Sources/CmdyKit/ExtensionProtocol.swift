import Foundation
import ProductIdentity

/// Authority an extension may request in a manifest v1 file. The names are
/// intentionally transport-neutral: HTTP is the v1 transport, not the product
/// model. New capabilities are additive; unknown capabilities reject a v1
/// manifest instead of silently granting something broader.
public enum ExtensionCapability: String, Codable, CaseIterable, Sendable {
    case events = "events.read"
    case panesRead = "panes.read"
    case panesType = "panes.type"
    case panesManage = "panes.manage"
    case commands = "commands"
    case hotkeys = "hotkeys"
    case panels = "ui.panels"
    case surfaces = "ui.surfaces"
    case companion = "ui.companion"
    case notifications = "notifications"
    case channels = "channels"
    case hooks = "hooks"
    case marketplace = "marketplace.install"
    case debug = "debug"

    public var explanation: String {
        switch self {
        case .events: return "Observe semantic terminal, pane, window, and extension events"
        case .panesRead: return "Read pane metadata and recent text output"
        case .panesType: return "Type or run text in a terminal pane"
        case .panesManage: return "Focus, scroll, split, or close terminal panes"
        case .commands:
            return "Add commands to \(ProductIdentity.current.titleName)'s command palette"
        case .hotkeys: return "Register system-wide keyboard shortcuts"
        case .panels: return "Open transient native panels"
        case .surfaces: return "Attach bounded native surfaces to command output"
        case .companion: return "Reserve window space for an external companion app"
        case .notifications: return "Show native notifications"
        case .channels: return "Connect an external work source and receive approved replies"
        case .hooks:
            return "Participate in bounded \(ProductIdentity.current.titleName) decision hooks"
        case .marketplace: return "Install items from the configured marketplace"
        case .debug: return "Read diagnostic renderer and hit-test information"
        }
    }
}

public enum ExtensionHookKind: String, Codable, CaseIterable, Sendable {
    case command = "command.submit"
    case paste = "paste"
    case paneSplit = "pane.split"
    case paneClose = "pane.close"
    case notification = "notification"
}

public enum ExtensionDecisionAction: String, Codable, Sendable {
    case `continue`
    case replace
    case cancel
}

public struct ExtensionDecision: Codable, Equatable, Sendable {
    public var action: ExtensionDecisionAction
    public var value: String?
    public var reason: String?

    public init(_ action: ExtensionDecisionAction = .continue,
                value: String? = nil, reason: String? = nil) {
        self.action = action
        self.value = value
        self.reason = reason
    }
}

public enum ExtensionManifestError: LocalizedError, Equatable {
    case unreadable(String)
    case invalidJSON(String)
    case unsupportedVersion(Int)
    case missing(String)
    case invalidID(String)
    case unsafeEntrypoint(String)
    case unavailableEntrypoint(String)
    case duplicateCapability(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path): return "Could not read extension manifest at \(path)"
        case .invalidJSON(let detail): return "Invalid extension manifest: \(detail)"
        case .unsupportedVersion(let version):
            return "Unsupported extension manifest version \(version)"
        case .missing(let field): return "Extension manifest is missing '\(field)'"
        case .invalidID(let id):
            return "Invalid extension id '\(id)' (use reverse-DNS text such as dev.example.tool)"
        case .unsafeEntrypoint(let path):
            return "Extension entrypoint must be a relative path inside its folder: \(path)"
        case .unavailableEntrypoint(let path):
            return "Extension entrypoint is missing or not executable: \(path)"
        case .duplicateCapability(let capability):
            return "Extension capability is declared more than once: \(capability)"
        }
    }
}

/// The install and launch contract. `manifestVersion: 1` is capability scoped.
/// Old `{name, exec, enabled}` manifests remain readable as version 0 and keep
/// their historical full access so existing Cmdy installations do not break.
public struct ExtensionManifest: Equatable, Sendable {
    public static let currentVersion = 1
    /// Freeze v0 authority at the capabilities that existed before Channels.
    /// New capabilities must never silently broaden every legacy Extension.
    public static let legacyCapabilities: Set<ExtensionCapability> = [
        .events, .panesRead, .panesType, .panesManage, .commands, .hotkeys,
        .panels, .surfaces, .companion, .notifications, .hooks, .marketplace,
        .debug,
    ]

    public var manifestVersion: Int
    public var id: String
    public var name: String
    public var version: String
    public var entrypoint: String
    public var enabled: Bool
    public var capabilities: [ExtensionCapability]
    /// Optional app-hosted component activation. The package still carries an
    /// executable-shaped entrypoint for a uniform install contract, but the
    /// app allow-lists the manifest identity and owns the component lifecycle.
    public var hostComponent: String?
    public var description: String?
    public var guide: CmdyProductGuide?
    public var homepage: String?

    public init(manifestVersion: Int = Self.currentVersion,
                id: String,
                name: String,
                version: String = "0.1.0",
                entrypoint: String,
                enabled: Bool = true,
                capabilities: [ExtensionCapability],
                hostComponent: String? = nil,
                description: String? = nil,
                guide: CmdyProductGuide? = nil,
                homepage: String? = nil) throws {
        self.manifestVersion = manifestVersion
        self.id = id
        self.name = name
        self.version = version
        self.entrypoint = entrypoint
        self.enabled = enabled
        self.capabilities = capabilities
        self.hostComponent = hostComponent
        self.description = description
        self.guide = guide
        self.homepage = homepage
        try validate()
    }

    public var isLegacy: Bool { manifestVersion == 0 }

    /// Legacy manifests predate capability declarations and retain their
    /// historical access. Capabilities introduced later are not added here.
    public var effectiveCapabilities: Set<ExtensionCapability> {
        isLegacy ? Self.legacyCapabilities : Set(capabilities)
    }

    public func allows(_ capability: ExtensionCapability) -> Bool {
        effectiveCapabilities.contains(capability)
    }

    public func validate() throws {
        guard manifestVersion == 0 || manifestVersion == Self.currentVersion else {
            throw ExtensionManifestError.unsupportedVersion(manifestVersion)
        }
        guard !id.isEmpty else { throw ExtensionManifestError.missing("id") }
        guard Self.isValidID(id) else { throw ExtensionManifestError.invalidID(id) }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExtensionManifestError.missing("name")
        }
        guard !entrypoint.isEmpty else { throw ExtensionManifestError.missing("entrypoint") }
        if let hostComponent,
           hostComponent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ExtensionManifestError.missing("hostComponent")
        }
        let path = NSString(string: entrypoint)
        guard !path.isAbsolutePath,
              !entrypoint.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0 == ".." }),
              entrypoint != "." else {
            throw ExtensionManifestError.unsafeEntrypoint(entrypoint)
        }
        var seen = Set<ExtensionCapability>()
        for capability in capabilities where !seen.insert(capability).inserted {
            throw ExtensionManifestError.duplicateCapability(capability.rawValue)
        }
    }

    public static func load(from directory: URL) throws -> ExtensionManifest {
        let url = directory.appendingPathComponent("manifest.json")
        guard let data = try? BoundedFileReader.data(
            at: url, maxBytes: 1024 * 1024) else {
            throw ExtensionManifestError.unreadable(url.path)
        }
        return try decode(data, fallbackID: directory.lastPathComponent)
    }

    public static func decode(_ data: Data, fallbackID: String? = nil) throws -> ExtensionManifest {
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ExtensionManifestError.invalidJSON("the root must be an object")
            }
            object = decoded
        } catch let error as ExtensionManifestError {
            throw error
        } catch {
            throw ExtensionManifestError.invalidJSON(error.localizedDescription)
        }

        let manifestVersion = object["manifestVersion"] as? Int ?? 0
        guard manifestVersion == 0 || manifestVersion == currentVersion else {
            throw ExtensionManifestError.unsupportedVersion(manifestVersion)
        }
        guard let entrypoint = (object["entrypoint"] as? String)
            ?? (object["exec"] as? String) else {
            throw ExtensionManifestError.missing("entrypoint")
        }
        let rawID = object["id"] as? String ?? fallbackID ?? ""
        let id = manifestVersion == 0 && !Self.isValidID(rawID)
            ? "local.\(Self.sanitizedIDComponent(rawID))" : rawID
        let name = object["name"] as? String ?? fallbackID ?? ""
        let version = object["version"] as? String ?? (manifestVersion == 0 ? "0.0.0" : "")
        if manifestVersion == currentVersion, version.isEmpty {
            throw ExtensionManifestError.missing("version")
        }

        let capabilities: [ExtensionCapability]
        if manifestVersion == 0 {
            capabilities = []
        } else {
            guard let names = object["capabilities"] as? [String] else {
                throw ExtensionManifestError.missing("capabilities")
            }
            do {
                capabilities = try names.map { name in
                    guard let capability = ExtensionCapability(rawValue: name) else {
                        throw ExtensionManifestError.invalidJSON("unknown capability '\(name)'")
                    }
                    return capability
                }
            } catch { throw error }
        }

        return try ExtensionManifest(
            manifestVersion: manifestVersion,
            id: id,
            name: name,
            version: version,
            entrypoint: entrypoint,
            enabled: object["enabled"] as? Bool ?? true,
            capabilities: capabilities,
            hostComponent: object["hostComponent"] as? String,
            description: object["description"] as? String,
            guide: CmdyProductGuide.decode(object["guide"]),
            homepage: object["homepage"] as? String)
    }

    public func encoded(pretty: Bool = true) throws -> Data {
        var object: [String: Any] = [
            "manifestVersion": manifestVersion,
            "id": id,
            "name": name,
            "version": version,
            "entrypoint": entrypoint,
            "enabled": enabled,
            "capabilities": capabilities.map(\.rawValue),
        ]
        if let hostComponent { object["hostComponent"] = hostComponent }
        if let description { object["description"] = description }
        if let guide { object["guide"] = guide.jsonObject }
        if let homepage { object["homepage"] = homepage }
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

    private static func isValidID(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            guard let first = part.first, first.isASCII,
                  first.isLetter || first.isNumber else { return false }
            return part.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber
                    || character == "-" || character == "_")
            }
        }
    }

    private static func sanitizedIDComponent(_ raw: String) -> String {
        let mapped = raw.lowercased().map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber
                || character == "-" || character == "_") ? character : "-"
        }
        let text = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return text.isEmpty ? "extension" : text
    }
}

public struct ProjectExtension: Equatable, Sendable {
    public let projectRoot: URL
    public let directory: URL
    public let manifest: ExtensionManifest
}

/// Finds the current or legacy product project directory without following a path
/// above the filesystem root. Discovery does not execute anything; trust and
/// lifecycle are separate decisions made by the host.
public enum ProjectExtensionDiscovery {
    public static func projectRoot(containing path: URL,
                                   fileManager: FileManager = .default) -> URL? {
        var candidate = path.standardizedFileURL
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            candidate.deleteLastPathComponent()
        }
        while true {
            let markerNames = [ProductIdentity.current.projectDirectoryName]
                + ProductIdentity.current.legacyProjectDirectoryNames
            if markerNames.contains(where: {
                fileManager.fileExists(atPath: candidate
                    .appendingPathComponent($0, isDirectory: true).path)
            }) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return nil }
            candidate = parent
        }
    }

    public static func extensions(in projectRoot: URL,
                                  fileManager: FileManager = .default) throws -> [ProjectExtension] {
        let markerNames = [ProductIdentity.current.projectDirectoryName]
            + ProductIdentity.current.legacyProjectDirectoryNames
        guard let marker = markerNames.first(where: {
            fileManager.fileExists(atPath: projectRoot
                .appendingPathComponent($0, isDirectory: true).path)
        }) else { return [] }
        let directory = projectRoot
            .appendingPathComponent(marker, isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let children = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        let resolvedRoot = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return try children.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { child in
            guard child.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot)
            else { throw ExtensionManifestError.unsafeEntrypoint(child.path) }
            guard fileManager.fileExists(atPath: child.appendingPathComponent("manifest.json").path)
            else { return nil }
            return ProjectExtension(projectRoot: projectRoot.standardizedFileURL,
                                    directory: child.standardizedFileURL,
                                    manifest: try ExtensionManifest.load(from: child))
        }
    }
}

/// Explicit project trust, stored independently from project-controlled files.
/// Trusting a root means its `.cmdy/extensions` programs may run until the
/// user revokes that root; editing files inside an already trusted project does
/// not produce misleading repeated prompts.
public final class ExtensionTrustStore {
    private let url: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public func isTrusted(_ projectRoot: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return load().contains(canonical(projectRoot))
    }

    public func trustedProjects() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return load().sorted()
    }

    public func trust(_ projectRoot: URL) throws {
        try mutate { $0.insert(canonical(projectRoot)) }
    }

    public func revoke(_ projectRoot: URL) throws {
        try mutate { $0.remove(canonical(projectRoot)) }
    }

    private func mutate(_ body: (inout Set<String>) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var values = load()
        body(&values)
        let object: [String: Any] = ["version": 1, "projects": values.sorted()]
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys])
        try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600],
                                       ofItemAtPath: url.path)
    }

    private func load() -> Set<String> {
        guard let data = try? BoundedFileReader.data(
            at: url, maxBytes: 4 * 1024 * 1024),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = object["projects"] as? [String] else { return [] }
        return Set(projects)
    }

    private func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
