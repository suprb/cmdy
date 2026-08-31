import Darwin
import Foundation

/// The pieces of app presentation that live outside a terminal split tree.
/// All fields are optional so older workspace files remain useful when new
/// presentation features are added.
public struct WorkspacePresentation: Codable, Equatable, Sendable {
    public var windowGridEnabled: Bool?
    public var windowGridState: Data?
    public var navigatorVisible: Bool?
    public var inspectorVisible: Bool?

    public init(
        windowGridEnabled: Bool? = nil,
        windowGridState: Data? = nil,
        navigatorVisible: Bool? = nil,
        inspectorVisible: Bool? = nil
    ) {
        self.windowGridEnabled = windowGridEnabled
        self.windowGridState = windowGridState
        self.navigatorVisible = navigatorVisible
        self.inspectorVisible = inspectorVisible
    }
}

/// A deliberately small, non-secret hint for a terminal tool that explicitly
/// exposes a resumable session identifier. cmdy never reads a process's
/// environment, keychain, config files, or authentication state to make one.
public struct WorkspaceLaunchHint: Codable, Equatable, Sendable {
    public enum Tool: String, Codable, CaseIterable, Sendable {
        case codex
        case claude
        case pi
    }

    public let tool: Tool
    public let sessionIdentifier: String

    public init?(tool: Tool, sessionIdentifier: String) {
        let value = sessionIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_.:"))
        guard !value.isEmpty,
              value.utf8.count <= 160,
              value.unicodeScalars.allSatisfy(allowed.contains)
        else { return nil }
        self.tool = tool
        self.sessionIdentifier = value
    }
}

/// A JSON value with a real Codable model. Terminal layout nodes are purposely
/// extensible dictionaries; this type preserves unknown future fields without
/// falling back to an untyped file format.
public enum WorkspaceJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([WorkspaceJSONValue])
    case object([String: WorkspaceJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([WorkspaceJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: WorkspaceJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    init(foundation value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .integer(Int64(value))
        case let value as Int8:
            self = .integer(Int64(value))
        case let value as Int16:
            self = .integer(Int64(value))
        case let value as Int32:
            self = .integer(Int64(value))
        case let value as Int64:
            self = .integer(value)
        case let value as UInt where value <= UInt(Int64.max):
            self = .integer(Int64(value))
        case let value as Double where value.isFinite:
            self = .number(value)
        case let value as Float where value.isFinite:
            self = .number(Double(value))
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(try value.map(Self.init(foundation:)))
        case let value as [String: Any]:
            self = .object(try value.mapValues(Self.init(foundation:)))
        default:
            throw WorkspaceStore.StoreError.invalidSnapshot(
                "unsupported layout value \(String(describing: type(of: value)))")
        }
    }

    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .integer(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.foundationValue)
        case .object(let value): return value.mapValues(\.foundationValue)
        }
    }
}

public struct SavedWorkspace: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var updatedAt: Date
    public var layouts: [WorkspaceJSONValue]
    public var presentation: WorkspacePresentation
    /// Keyed by a stable pane-tree path supplied by the app (for example
    /// `window-0/child-1`). Empty unless a tool explicitly exposes a safe ID.
    public var launchHints: [String: WorkspaceLaunchHint]

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        layouts: [[String: Any]],
        presentation: WorkspacePresentation = .init(),
        launchHints: [String: WorkspaceLaunchHint] = [:]
    ) throws {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = try WorkspaceStore.normalizedName(name)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.layouts = try layouts.map {
            .object(try $0.mapValues(WorkspaceJSONValue.init(foundation:)))
        }
        guard !self.layouts.isEmpty else {
            throw WorkspaceStore.StoreError.invalidSnapshot(
                "a workspace must contain at least one window")
        }
        self.presentation = presentation
        self.launchHints = launchHints
    }

    /// Layout dictionaries ready for `TerminalWindowController(session:)`.
    public func foundationLayouts() throws -> [[String: Any]] {
        try layouts.map { value in
            guard case .object(let object) = value else {
                throw WorkspaceStore.StoreError.invalidSnapshot(
                    "each saved window must be a JSON object")
            }
            return object.mapValues(\.foundationValue)
        }
    }

    public var summary: SavedWorkspaceSummary {
        SavedWorkspaceSummary(
            id: id, name: name, createdAt: createdAt, updatedAt: updatedAt,
            windowCount: layouts.count)
    }
}

public struct SavedWorkspaceSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let createdAt: Date
    public let updatedAt: Date
    public let windowCount: Int
}

/// Durable named workspaces stored independently under cmdy's config folder.
/// Each workspace is an atomic file, so an interrupted update cannot corrupt
/// the other saved workspaces or the ordinary quit/launch `session.json`.
public struct WorkspaceStore {
    public static var directory: URL {
        ConfigFile.directory.appendingPathComponent("workspaces", isDirectory: true)
    }

    public enum StoreError: LocalizedError, Equatable {
        case invalidName
        case duplicateName(String)
        case notFound(UUID)
        case corrupt(path: String, reason: String)
        case invalidSnapshot(String)

        public var errorDescription: String? {
            switch self {
            case .invalidName:
                return "Workspace names cannot be empty."
            case .duplicateName(let name):
                return "A workspace named \"\(name)\" already exists."
            case .notFound(let id):
                return "Workspace \(id.uuidString) was not found."
            case .corrupt(let path, let reason):
                return "Workspace file at \(path) is corrupt: \(reason)."
            case .invalidSnapshot(let reason):
                return "The workspace snapshot is invalid: \(reason)."
            }
        }
    }

    private let directoryURL: URL
    private let fileManager: FileManager

    public init(
        directory: URL = WorkspaceStore.directory,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directory
        self.fileManager = fileManager
    }

    @discardableResult
    public func saveAsNew(
        name: String,
        layouts: [[String: Any]],
        presentation: WorkspacePresentation = .init(),
        launchHints: [String: WorkspaceLaunchHint] = [:],
        now: Date = Date(),
        id: UUID = UUID()
    ) throws -> SavedWorkspace {
        let normalized = try Self.normalizedName(name)
        try requireUniqueName(normalized, excluding: nil)
        let workspace = try SavedWorkspace(
            id: id, name: normalized, createdAt: now, updatedAt: now,
            layouts: layouts, presentation: presentation,
            launchHints: launchHints)
        try write(workspace)
        try setCurrentWorkspaceID(id)
        return workspace
    }

    @discardableResult
    public func update(
        id: UUID,
        layouts: [[String: Any]],
        presentation: WorkspacePresentation = .init(),
        launchHints: [String: WorkspaceLaunchHint] = [:],
        now: Date = Date()
    ) throws -> SavedWorkspace {
        let existing = try load(id: id)
        let workspace = try SavedWorkspace(
            id: existing.id, name: existing.name,
            createdAt: existing.createdAt, updatedAt: now,
            layouts: layouts, presentation: presentation,
            launchHints: launchHints)
        try write(workspace)
        try setCurrentWorkspaceID(id)
        return workspace
    }

    @discardableResult
    public func rename(id: UUID, to name: String, now: Date = Date()) throws -> SavedWorkspace {
        let normalized = try Self.normalizedName(name)
        try requireUniqueName(normalized, excluding: id)
        var workspace = try load(id: id)
        workspace.name = normalized
        workspace.updatedAt = now
        try write(workspace)
        return workspace
    }

    public func delete(id: UUID) throws {
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw StoreError.notFound(id)
        }
        try fileManager.removeItem(at: url)
        if currentWorkspaceID() == id { try setCurrentWorkspaceID(nil) }
    }

    public func load(id: UUID) throws -> SavedWorkspace {
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw StoreError.notFound(id)
        }
        let data: Data
        do { data = try BoundedFileReader.data(at: url, maxBytes: 64 * 1024 * 1024) }
        catch {
            throw StoreError.corrupt(path: url.path, reason: error.localizedDescription)
        }
        do {
            let workspace = try Self.decoder.decode(SavedWorkspace.self, from: data)
            guard workspace.schemaVersion == SavedWorkspace.currentSchemaVersion else {
                throw StoreError.corrupt(
                    path: url.path,
                    reason: "unsupported schema version \(workspace.schemaVersion)")
            }
            _ = try workspace.foundationLayouts()
            return workspace
        } catch let error as StoreError { throw error }
        catch { throw StoreError.corrupt(path: url.path, reason: error.localizedDescription) }
    }

    /// Corrupt files are isolated instead of making every other workspace
    /// disappear from the picker. Loading the corrupt workspace still reports
    /// its precise error.
    public func list() throws -> [SavedWorkspaceSummary] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SavedWorkspaceSummary? in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      let workspace = try? load(id: id)
                else { return nil }
                return workspace.summary
            }
            .sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame
                    ? $0.id.uuidString < $1.id.uuidString
                    : order == .orderedAscending
            }
    }

    public func currentWorkspaceID() -> UUID? {
        let url = directoryURL.appendingPathComponent("current")
        guard let data = try? BoundedFileReader.data(at: url, maxBytes: 256),
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines)
        else { return nil }
        return UUID(uuidString: value)
    }

    public func setCurrentWorkspaceID(_ id: UUID?) throws {
        try fileManager.createDirectory(
            at: directoryURL, withIntermediateDirectories: true)
        let url = directoryURL.appendingPathComponent("current")
        guard let id else {
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            return
        }
        try atomicWrite(Data((id.uuidString + "\n").utf8), to: url)
    }

    public static func normalizedName(_ name: String) throws -> String {
        let normalizedScalars = name.unicodeScalars.map { scalar -> UnicodeScalar in
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet(charactersIn: "/\\:").contains(scalar) {
                return " "
            }
            return scalar
        }
        let collapsed = String(String.UnicodeScalarView(normalizedScalars))
            .split(whereSeparator: \Character.isWhitespace)
            .filter { $0 != "." && $0 != ".." }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { throw StoreError.invalidName }
        return String(collapsed.prefix(80))
    }

    private func requireUniqueName(_ name: String, excluding id: UUID?) throws {
        if try list().contains(where: {
            $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            throw StoreError.duplicateName(name)
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(id.uuidString + ".json")
    }

    private func write(_ workspace: SavedWorkspace) throws {
        try fileManager.createDirectory(
            at: directoryURL, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(workspace)
        guard data.count <= 64 * 1024 * 1024 else {
            throw StoreError.invalidSnapshot("encoded data exceeds 64 MB")
        }
        try atomicWrite(data, to: fileURL(for: workspace.id))
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = directoryURL.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public struct WorkspaceCapture {
    public var layouts: [[String: Any]]
    public var presentation: WorkspacePresentation
    public var launchHints: [String: WorkspaceLaunchHint]

    public init(
        layouts: [[String: Any]],
        presentation: WorkspacePresentation = .init(),
        launchHints: [String: WorkspaceLaunchHint] = [:]
    ) {
        self.layouts = layouts
        self.presentation = presentation
        self.launchHints = launchHints
    }
}

public enum WorkspaceOpenMode: Sendable {
    /// Open the saved windows alongside everything already running.
    case additionalWindows
    /// Explicitly replace the current live windows after the app has completed
    /// its normal dirty-editor/active-process confirmation path.
    case replaceCurrentWorkspace
}

/// App-facing orchestration with no AppKit ownership. The app supplies its
/// existing layout serializer and safe restore path; this service owns names,
/// current-workspace semantics, persistence, and the non-destructive default.
@MainActor
public final class NamedWorkspaceCoordinator {
    public typealias CaptureHandler = @MainActor () throws -> WorkspaceCapture
    public typealias OpenHandler = @MainActor (SavedWorkspace, WorkspaceOpenMode) throws -> Void

    private let store: WorkspaceStore
    private let captureHandler: CaptureHandler
    private let openHandler: OpenHandler

    public init(
        store: WorkspaceStore = WorkspaceStore(),
        capture: @escaping CaptureHandler,
        open: @escaping OpenHandler
    ) {
        self.store = store
        self.captureHandler = capture
        self.openHandler = open
    }

    public var currentWorkspaceID: UUID? { store.currentWorkspaceID() }
    public func list() throws -> [SavedWorkspaceSummary] { try store.list() }

    @discardableResult
    public func saveAsNew(named name: String) throws -> SavedWorkspace {
        let capture = try captureHandler()
        return try store.saveAsNew(
            name: name, layouts: capture.layouts,
            presentation: capture.presentation,
            launchHints: capture.launchHints)
    }

    @discardableResult
    public func updateCurrent() throws -> SavedWorkspace {
        guard let id = store.currentWorkspaceID() else {
            throw WorkspaceStore.StoreError.invalidSnapshot(
                "there is no current named workspace; use Save As New Workspace first")
        }
        let capture = try captureHandler()
        return try store.update(
            id: id, layouts: capture.layouts,
            presentation: capture.presentation,
            launchHints: capture.launchHints)
    }

    public func open(
        id: UUID,
        mode: WorkspaceOpenMode = .additionalWindows
    ) throws {
        let workspace = try store.load(id: id)
        // The current marker advances only after restoration succeeds.
        try openHandler(workspace, mode)
        try store.setCurrentWorkspaceID(id)
    }

    @discardableResult
    public func rename(id: UUID, to name: String) throws -> SavedWorkspace {
        try store.rename(id: id, to: name)
    }

    public func delete(id: UUID) throws { try store.delete(id: id) }
}
