import Foundation

/// What an on-demand Extension registered the last time it ran: enough for
/// cmdy to show its palette commands and arm its hotkeys while the process
/// sleeps. Keyed by Extension id and only trusted for the same version, so
/// an update relearns its contributions on the first launch.
struct ExtensionContributions: Equatable {
    struct Command: Equatable {
        let id: String
        let title: String
    }
    struct HotKey: Equatable {
        let id: String
        let keyCode: UInt32
        let modifiers: UInt32
    }

    let version: String
    let commands: [Command]
    let hotKeys: [HotKey]

    var isEmpty: Bool { commands.isEmpty && hotKeys.isEmpty }
}

struct ExtensionContributionCache {
    let url: URL

    func load() -> [String: ExtensionContributions] {
        guard let data = try? BoundedFileReader.data(at: url, maxBytes: 1024 * 1024),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var result: [String: ExtensionContributions] = [:]
        for (id, value) in root {
            guard let entry = value as? [String: Any],
                  let version = entry["version"] as? String else { continue }
            let commands = (entry["commands"] as? [[String: Any]] ?? []).compactMap {
                item -> ExtensionContributions.Command? in
                guard let id = item["id"] as? String,
                      let title = item["title"] as? String else { return nil }
                return .init(id: id, title: title)
            }
            let hotKeys = (entry["hotkeys"] as? [[String: Any]] ?? []).compactMap {
                item -> ExtensionContributions.HotKey? in
                guard let id = item["id"] as? String,
                      let keyCode = (item["keyCode"] as? Int).flatMap(UInt32.init(exactly:)),
                      let modifiers = (item["modifiers"] as? Int).flatMap(UInt32.init(exactly:))
                else { return nil }
                return .init(id: id, keyCode: keyCode, modifiers: modifiers)
            }
            result[id] = ExtensionContributions(
                version: version, commands: commands, hotKeys: hotKeys)
        }
        return result
    }

    func contributions(for manifest: ExtensionManifest) -> ExtensionContributions? {
        guard let entry = load()[manifest.id], entry.version == manifest.version,
              !entry.isEmpty else { return nil }
        return entry
    }

    func save(_ contributions: ExtensionContributions, for id: String) {
        var root: [String: Any] = [:]
        if let data = try? BoundedFileReader.data(at: url, maxBytes: 1024 * 1024),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }
        root[id] = [
            "version": contributions.version,
            "commands": contributions.commands.map { ["id": $0.id, "title": $0.title] },
            "hotkeys": contributions.hotKeys.map {
                ["id": $0.id, "keyCode": Int($0.keyCode), "modifiers": Int($0.modifiers)]
            },
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
