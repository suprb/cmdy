import Darwin
import Foundation
import ProductIdentity

/// Persist-and-restore for the whole app: every window's frame, split layout,
/// per-pane cwd and recent scrollback. Checkpointed during use and on quit,
/// restored on launch (`restore-session` in the config, on by default).
/// Restoring a layout/transcript starts fresh shells; it does not resume jobs.
public enum SessionStore {
    public static var url: URL { ConfigFile.directory.appendingPathComponent("session.json") }
    public static var previousURL: URL { previousURL(for: url) }
    static let maximumBytes = 64 * 1024 * 1024

    public struct LoadResult {
        public let layouts: [[String: Any]]?
        public let notice: RecoveryNotice?
    }

    public enum RecoveryNotice: Equatable, Sendable {
        case recoveredPrevious(reason: String)
        case couldNotRestore(reason: String)

        public var title: String {
            switch self {
            case .recoveredPrevious: return "An Earlier Session Was Recovered"
            case .couldNotRestore: return "The Saved Session Could Not Be Restored"
            }
        }

        public var message: String {
            switch self {
            case .recoveredPrevious(let reason):
                return "The latest checkpoint could not be read. The previous good layout and transcript were restored in fresh shells. Recent output may be missing.\n\n\(reason)"
            case .couldNotRestore(let reason):
                return "A fresh terminal was opened because neither saved checkpoint could be restored.\n\n\(reason)"
            }
        }
    }

    enum StoreError: LocalizedError {
        case corrupt(path: String, reason: String)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .corrupt(let path, let reason):
                return "session file at \(path) is corrupt: \(reason)"
            case .tooLarge:
                return "the session exceeds the 64 MB recovery limit"
            }
        }
    }

    typealias StagedWriter = (Data, URL) throws -> Void

    public static func save(layouts: [[String: Any]]) {
        do {
            try save(layouts: layouts, to: url)
        } catch {
            NSLog(
                "%@: session save failed at %@; the previous session was left untouched: %@",
                ProductIdentity.current.slug, url.path, error.localizedDescription)
        }
    }

    static func save(
        layouts: [[String: Any]],
        to destination: URL,
        fileManager: FileManager = .default,
        stagedWriter: StagedWriter? = nil
    ) throws {
        try save(
            data: encodedSnapshot(layouts: layouts), to: destination,
            fileManager: fileManager, stagedWriter: stagedWriter)
    }

    static func encodedSnapshot(layouts: [[String: Any]]) throws -> Data {
        // A valid empty envelope is a durable tombstone: a crash while clearing
        // the previous snapshot cannot make intentionally closed windows return.
        let obj: [String: Any] = [
            "version": 2, "windows": layouts.filter { !$0.isEmpty },
        ]
        let data = try JSONSerialization.data(withJSONObject: obj, options: .sortedKeys)
        guard data.count <= maximumBytes else { throw StoreError.tooLarge }
        return data
    }

    static func save(
        data: Data,
        to destination: URL,
        fileManager: FileManager = .default,
        stagedWriter: StagedWriter? = nil
    ) throws {
        guard data.count <= maximumBytes else { throw StoreError.tooLarge }
        let snapshot = try decodedSnapshot(data, source: destination)
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try writeAtomically(
            data, to: destination, fileManager: fileManager,
            stagedWriter: stagedWriter, preservePrevious: true)
        if snapshot.isEmpty {
            // The committed empty primary takes precedence even if removing
            // the older backup fails; never resurrect it on the next launch.
            do { try fileManager.removeItem(at: previousURL(for: destination)) }
            catch where isMissingFile(error) {}
            catch {
                NSLog("%@: obsolete session backup could not be removed: %@",
                      ProductIdentity.current.slug, error.localizedDescription)
            }
        }
    }

    /// Returns the saved window nodes, oldest layout first (nil = nothing saved).
    public static func load() -> [[String: Any]]? {
        loadWithRecovery().layouts
    }

    public static func loadWithRecovery() -> LoadResult {
        loadWithRecovery(from: url)
    }

    static func loadWithRecovery(from source: URL) -> LoadResult {
        var failure: String?
        do {
            if let windows = try readSnapshot(from: source) {
                return LoadResult(layouts: windows.isEmpty ? nil : windows, notice: nil)
            }
        } catch { failure = error.localizedDescription }

        do {
            if let windows = try readSnapshot(from: previousURL(for: source)) {
                return LoadResult(
                    layouts: windows.isEmpty ? nil : windows,
                    notice: .recoveredPrevious(
                        reason: failure ?? "The latest checkpoint is missing."))
            }
        } catch {
            failure = [failure, error.localizedDescription].compactMap { $0 }
                .joined(separator: "\n")
        }
        return LoadResult(
            layouts: nil,
            notice: failure.map { .couldNotRestore(reason: $0) })
    }

    static func load(from source: URL) throws -> [[String: Any]]? {
        guard let windows = try readSnapshot(from: source), !windows.isEmpty else {
            return nil
        }
        return windows
    }

    private static func readSnapshot(from source: URL) throws -> [[String: Any]]? {
        let data: Data
        do {
            data = try BoundedFileReader.data(
                at: source, maxBytes: maximumBytes)
        } catch where isMissingFile(error) {
            return nil
        }
        return try decodedSnapshot(data, source: source)
    }

    private static func decodedSnapshot(_ data: Data, source: URL) throws -> [[String: Any]] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw StoreError.corrupt(
                path: source.path,
                reason: "invalid JSON (\(error.localizedDescription))")
        }
        guard let root = object as? [String: Any] else {
            throw StoreError.corrupt(
                path: source.path, reason: "root must be a JSON object")
        }
        guard let version = root["version"] as? Int, [1, 2].contains(version) else {
            throw StoreError.corrupt(
                path: source.path, reason: "unsupported session version")
        }
        guard let windows = root["windows"] as? [[String: Any]],
              !windows.isEmpty || version == 2 else {
            throw StoreError.corrupt(
                path: source.path,
                reason: "windows must be a non-empty array of objects")
        }
        guard windows.allSatisfy({ validLayout($0, depth: 0) }) else {
            throw StoreError.corrupt(
                path: source.path, reason: "invalid terminal layout")
        }
        return windows
    }

    private static func validLayout(_ node: [String: Any], depth: Int) -> Bool {
        guard depth <= 32 else { return false }
        if node["type"] as? String == "pane" {
            return (node["cwd"] == nil || node["cwd"] is String)
                && (node["scrollback"] == nil || node["scrollback"] is String)
        }
        guard node["type"] as? String == "split",
              let children = node["children"] as? [[String: Any]],
              children.count > 1 else { return false }
        return children.allSatisfy { validLayout($0, depth: depth + 1) }
    }

    static func previousURL(for source: URL) -> URL {
        source.deletingLastPathComponent().appendingPathComponent(
            source.deletingPathExtension().lastPathComponent + ".previous.json")
    }

    private static func writeAtomically(
        _ data: Data,
        to destination: URL,
        fileManager: FileManager,
        stagedWriter: StagedWriter?,
        preservePrevious: Bool = false
    ) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }

        if let stagedWriter {
            try stagedWriter(data, temporary)
        } else {
            // Restrict the temporary before writing any transcript bytes.
            let descriptor = Darwin.open(
                temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                mode_t(0o600))
            guard descriptor >= 0 else { throw currentPOSIXError() }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)

        if preservePrevious,
           let previousData = try? BoundedFileReader.data(
                at: destination, maxBytes: maximumBytes),
           (try? decodedSnapshot(previousData, source: destination)) != nil {
            // Rotate only a fully readable primary. A corrupt primary must
            // never replace the recovery copy that just saved a launch.
            try writeAtomically(
                previousData, to: previousURL(for: destination),
                fileManager: fileManager, stagedWriter: nil)
        }

        guard rename(temporary.path, destination.path) == 0 else {
            throw currentPOSIXError()
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let cocoa = error as NSError
        return cocoa.domain == NSCocoaErrorDomain
            && [CocoaError.Code.fileNoSuchFile.rawValue,
                CocoaError.Code.fileReadNoSuchFile.rawValue].contains(cocoa.code)
    }
}
