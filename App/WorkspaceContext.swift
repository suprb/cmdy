import AppKit
import Foundation
import CmdyKit

/// Appearance that belongs to one AppKit terminal tab/window. A nil value
/// follows the global preference, so changing the global look still updates
/// every tab that has not deliberately opted out.
struct TerminalTabAppearance: Equatable {
    var themeName: String?
    var shaderName: String?
    var fontName: String?

    init(themeName: String? = nil, shaderName: String? = nil,
         fontName: String? = nil) {
        self.themeName = themeName
        self.shaderName = shaderName
        self.fontName = fontName
    }

    func resolvedThemeName(global: String) -> String {
        themeName ?? global
    }

    func resolvedShaderName(global: String) -> String {
        shaderName ?? global
    }

    func resolvedFontName(global: String) -> String {
        fontName ?? global
    }

    static func restored(themeName: String?, shaderName: String?,
                         fontName: String? = nil) -> Self {
        Self(
            themeName: themeName.flatMap { Theme.names.contains($0) ? $0 : nil },
            shaderName: shaderName.flatMap { name in
                Preferences.shaderNames.contains(name)
                    || (name.hasPrefix("user/") && UserShaders.source(named: name) != nil)
                    ? name : nil
            },
            fontName: TerminalAppearanceFontCatalog.validated(fontName))
    }
}

/// The font names a session is allowed to persist. The context menus expose
/// cmdy's redistributable bundle plus the native system-mono choice. Restores
/// also accept an installed PostScript name so a workspace remains portable
/// when a previously selected system font is still available.
enum TerminalAppearanceFontCatalog {
    static let systemName = "System"

    static var choices: [(title: String, name: String)] {
        var seen = Set<String>()
        var result: [(title: String, name: String)] = [
            (title: "System Mono", name: systemName),
        ]
        seen.insert(systemName)
        for font in bundledFonts where seen.insert(font.fontName).inserted {
            guard NSFont(name: font.fontName, size: 13) != nil else { continue }
            result.append((title: font.displayName, name: font.fontName))
        }
        return result
    }

    static func validated(_ requested: String?) -> String? {
        guard let requested = requested?.trimmingCharacters(
                in: .whitespacesAndNewlines),
              !requested.isEmpty else { return nil }
        if requested == systemName { return requested }
        guard NSFont(name: requested, size: 13) != nil,
              NSFontManager.shared.availableFonts.contains(requested)
        else { return nil }
        return requested
    }

    static func displayName(for name: String) -> String {
        if name == systemName { return "System Mono" }
        return choices.first(where: { $0.name == name })?.title ?? name
    }

    static func resolvedFont(name: String, size: CGFloat) -> NSFont {
        if name == systemName {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return NSFont(name: name, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

struct WorkspaceGitChange: Equatable {
    let status: String
    let path: String

    var displayStatus: String {
        let value = status.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? "Changed" : value
    }

    var prefersCachedDiff: Bool {
        guard let indexState = status.first else { return false }
        return indexState != " " && indexState != "?"
    }

    static func parse(_ line: String) -> Self? {
        guard line.count >= 4 else { return nil }
        let status = String(line.prefix(2))
        var path = String(line.dropFirst(3))
        if let rename = path.range(of: " -> ", options: .backwards) {
            path = String(path[rename.upperBound...])
        }
        if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 {
            path.removeFirst()
            path.removeLast()
        }
        guard !path.isEmpty else { return nil }
        return Self(status: status, path: path)
    }
}

struct WorkspaceOutputResource: Equatable {
    enum Kind: Equatable {
        case web
        case file
    }

    let kind: Kind
    let url: URL

    var displayName: String {
        switch kind {
        case .web:
            guard let host = url.host else { return "Link" }
            return url.port.map { "\(host):\($0)" } ?? host
        case .file:
            let name = url.lastPathComponent
            return name.isEmpty ? url.path : name
        }
    }
}

/// Converts concrete things printed by the active command into host-owned
/// actions. Detection is intentionally conservative: URLs must look like
/// links and paths must exist on disk before the Inspector offers them.
enum WorkspaceOutputRecognizer {
    static func resources(in output: String, cwd: String?, limit: Int = 4)
        -> [WorkspaceOutputResource] {
        guard limit > 0, !output.isEmpty else { return [] }
        let source = String(output.suffix(32_768))
        var resources: [WorkspaceOutputResource] = []
        var seen: Set<String> = []

        func append(_ resource: WorkspaceOutputResource) {
            guard resources.count < limit else { return }
            let key = resource.url.standardized.absoluteString
            guard seen.insert(key).inserted else { return }
            resources.append(resource)
        }

        let linkPattern =
            #"(?i)(?:https?://|file://|www\.|localhost(?::[0-9]{1,5})?|127\.0\.0\.1(?::[0-9]{1,5})?|\[::1\](?::[0-9]{1,5})?)[^\s<>{}\[\]"']*"#
        if let expression = try? NSRegularExpression(pattern: linkPattern) {
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in expression.matches(in: source, range: range) {
                guard resources.count < limit,
                      let swiftRange = Range(match.range, in: source) else { break }
                var raw = String(source[swiftRange])
                while let last = raw.last, ".,;!?)]}".contains(last) {
                    raw.removeLast()
                }
                let lower = raw.lowercased()
                if lower.hasPrefix("file://"), let url = URL(string: raw),
                   FileManager.default.fileExists(atPath: url.path) {
                    append(WorkspaceOutputResource(kind: .file, url: url))
                } else {
                    if lower.hasPrefix("www.") || lower.hasPrefix("localhost")
                        || lower.hasPrefix("127.0.0.1") || lower.hasPrefix("[::1]") {
                        raw = "http://" + raw
                    }
                    if let url = URL(string: raw),
                       ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                       url.host != nil {
                        append(WorkspaceOutputResource(kind: .web, url: url))
                    }
                }
            }
        }

        guard resources.count < limit else { return resources }
        let fileManager = FileManager.default
        let baseURL = cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let lineSuffix = source.components(separatedBy: .newlines).suffix(250)
        for line in lineSuffix {
            for rawToken in line.split(whereSeparator: \.isWhitespace) {
                guard resources.count < limit else { return resources }
                var token = String(rawToken)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{}<>,;"))
                guard !token.contains("://"), token.count < 1_024 else { continue }
                token = token.replacingOccurrences(
                    of: #":[0-9]+(?::[0-9]+)?$"#,
                    with: "", options: .regularExpression)

                let fileURL: URL?
                if token.hasPrefix("~/") {
                    fileURL = URL(fileURLWithPath:
                        NSString(string: token).expandingTildeInPath)
                } else if token.hasPrefix("/") {
                    fileURL = URL(fileURLWithPath: token)
                } else if let baseURL,
                          token.hasPrefix("./") || token.hasPrefix("../")
                            || token.contains("/") {
                    fileURL = URL(fileURLWithPath: token, relativeTo: baseURL)
                        .standardizedFileURL
                } else {
                    fileURL = nil
                }

                guard let fileURL, fileURL.path != "/",
                      fileURL.path != cwd,
                      fileManager.fileExists(atPath: fileURL.path) else { continue }
                append(WorkspaceOutputResource(kind: .file, url: fileURL))
            }
        }
        return resources
    }
}
