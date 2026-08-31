import Darwin
import Foundation
import ProductIdentity

/// Persist-and-restore for the whole app: every window's frame, split layout,
/// per-pane cwd and recent scrollback. Saved on quit, restored on launch
/// (`restore-session` in the config, on by default). Quit cmdy, come back,
/// and everything is where you left it.
public enum SessionStore {
    public static var url: URL { ConfigFile.directory.appendingPathComponent("session.json") }

    enum StoreError: LocalizedError {
        case corrupt(path: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .corrupt(let path, let reason):
                return "session file at \(path) is corrupt: \(reason)"
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
        let windows = layouts.filter { !$0.isEmpty }
        guard !windows.isEmpty else {
            do {
                try fileManager.removeItem(at: destination)
            } catch where isMissingFile(error) {
                // An absent file already represents an empty saved session.
            }
            return
        }

        let obj: [String: Any] = ["version": 1, "windows": windows]
        let data = try JSONSerialization.data(withJSONObject: obj)
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try writeAtomically(
            data, to: destination, fileManager: fileManager,
            stagedWriter: stagedWriter)
    }

    /// Returns the saved window nodes, oldest layout first (nil = nothing saved).
    public static func load() -> [[String: Any]]? {
        do {
            return try load(from: url)
        } catch {
            NSLog(
                "%@: session restore ignored unreadable data at %@: %@",
                ProductIdentity.current.slug, url.path, error.localizedDescription)
            return nil
        }
    }

    static func load(from source: URL) throws -> [[String: Any]]? {
        let data: Data
        do {
            data = try BoundedFileReader.data(
                at: source, maxBytes: 64 * 1024 * 1024)
        } catch where isMissingFile(error) {
            return nil
        }

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
        guard let windows = root["windows"] as? [[String: Any]],
              !windows.isEmpty else {
            throw StoreError.corrupt(
                path: source.path,
                reason: "windows must be a non-empty array of objects")
        }
        return windows
    }

    private static func writeAtomically(
        _ data: Data,
        to destination: URL,
        fileManager: FileManager,
        stagedWriter: StagedWriter?
    ) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }

        if let stagedWriter {
            try stagedWriter(data, temporary)
        } else {
            try data.write(to: temporary, options: .withoutOverwriting)
        }

        guard rename(temporary.path, destination.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let cocoa = error as NSError
        return cocoa.domain == NSCocoaErrorDomain
            && [CocoaError.Code.fileNoSuchFile.rawValue,
                CocoaError.Code.fileReadNoSuchFile.rawValue].contains(cocoa.code)
    }
}
