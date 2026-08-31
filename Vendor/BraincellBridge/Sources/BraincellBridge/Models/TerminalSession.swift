import Foundation
import CryptoKit

/// A live cmdy pane registered through the plugin API and removed when the
/// pane closes or its process exits.
struct TerminalSession: Codable, Identifiable, Equatable, Hashable {

    /// Deterministic UUIDv5-style derivation from `(pid, tty)`. Same input
    /// always yields the same UUID, so cmdy republishing a pane after a
    /// Bridge restart resolves to the same session.
    ///
    /// pid + tty is the strongest stable identity at register time:
    ///   - shell pid is stable for the life of the shell process
    ///   - tty is stable for the life of the shell process
    ///   - pid alone could collide across reboots; tty alone could be reused
    /// On reboot both reset → all old session ids invalidate → user re-binds.
    /// Acceptable.
    static func deterministicId(pid: Int32, tty: String) -> String {
        let input = "braincell-bridge:session:\(pid):\(tty)"
        let digest = Insecure.SHA1.hash(data: Data(input.utf8))
        var bytes = Array(digest.prefix(16))
        // Set RFC 4122 version 5 (name-based SHA-1) and variant bits so
        // the result reads as a valid UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        return [
            String(hex.prefix(8)),
            String(hex.dropFirst(8).prefix(4)),
            String(hex.dropFirst(12).prefix(4)),
            String(hex.dropFirst(16).prefix(4)),
            String(hex.dropFirst(20).prefix(12))
        ].joined(separator: "-")
    }

    let id: String
    let pid: Int32
    let tty: String
    let terminalApp: String
    /// Exact cmdy window number supplied by the plugin API.
    var windowId: UInt32?
    /// Public plugin API pane identity and focus state. A window with splits
    /// still receives one plus, targeting its currently focused pane.
    var paneId: String?
    var paneFocused: Bool
    var windowTitle: String?
    var projectPath: String?
    let registeredAt: Date
    var lastSeen: Date

    /// Best-effort short label for UI rows.
    var displayName: String {
        if let proj = projectPath, !proj.isEmpty {
            return (proj as NSString).lastPathComponent
        }
        if let title = windowTitle, !title.isEmpty {
            return title
        }
        return "\(terminalApp) (\(pid))"
    }

    /// Subtitle: "Terminal · /dev/ttys003" or "iTerm · ~/code/foo"
    var subtitle: String {
        var parts: [String] = [terminalApp]
        if let proj = projectPath, !proj.isEmpty {
            parts.append((proj as NSString).abbreviatingWithTildeInPath)
        } else {
            parts.append(tty)
        }
        return parts.joined(separator: " · ")
    }
}
