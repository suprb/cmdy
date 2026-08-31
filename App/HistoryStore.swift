import Foundation
import CmdyKit

/// Command history powering ghost-text autocomplete: the user's ~/.zsh_history
/// (parsed once at first use) plus successful commands run in this session.
/// Most-recent match wins.
final class HistoryStore {
    nonisolated(unsafe) static let shared = HistoryStore()
    private static let maxCommands = 20_000
    private static let maxHistoryBytes = 8 * 1024 * 1024

    /// Oldest → newest. Consecutive duplicates collapsed; capped to `cap`.
    private var commands: [String] = []

    init(commands: [String]? = nil) {
        self.commands = commands ?? Self.loadZshHistory()
    }

    /// A command just ran in a cmdy session — remember it (newest position).
    func record(_ command: String) {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, commands.last != cmd else { return }
        commands.append(cmd)
        if commands.count > Self.maxCommands {
            commands.removeFirst(commands.count - Self.maxCommands)
        }
    }

    /// A command just failed. Remove matching entries so a bad command from
    /// zsh history cannot immediately return as ghost text at the next prompt.
    func reject(_ command: String) {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        commands.removeAll { $0 == cmd }
    }

    /// The most recent command that extends `prefix` (and isn't just `prefix`).
    /// Bare `cd <path>` candidates are checked against the pane's current
    /// directory so a stale path is never presented as an actionable hint.
    func suggestion(for prefix: String, cwd: String? = nil) -> String? {
        guard prefix.count >= 2 else { return nil }
        for cmd in commands.reversed() where cmd.hasPrefix(prefix) && cmd.count > prefix.count {
            if Self.isContextuallyValid(cmd, cwd: cwd) { return cmd }
        }
        return nil
    }

    private static func isContextuallyValid(_ command: String, cwd: String?) -> Bool {
        guard let cwd, let target = literalCDTarget(in: command) else { return true }
        let candidate: URL
        if target.hasPrefix("/") {
            candidate = URL(fileURLWithPath: target, isDirectory: true)
        } else {
            candidate = URL(fileURLWithPath: cwd, isDirectory: true)
                .appendingPathComponent(target, isDirectory: true)
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: candidate.standardizedFileURL.path,
            isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Returns a target only for the simple literal form we can validate
    /// without pretending to be a shell parser. Variables, globs, command
    /// substitutions, options, and compound commands remain eligible.
    private static func literalCDTarget(in command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard parts.count == 2, parts[0] == "cd" else { return nil }

        var target = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target != "-", !target.hasPrefix("-") else { return nil }

        let wasQuoted: Bool
        if target.count >= 2,
           (target.first == "\"" && target.last == "\""
            || target.first == "'" && target.last == "'") {
            target.removeFirst()
            target.removeLast()
            wasQuoted = true
        } else {
            wasQuoted = false
        }
        guard !target.isEmpty else { return nil }
        if !wasQuoted, target.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return nil
        }
        let shellSyntax = CharacterSet(charactersIn: "$~*?[]{}()`\\;&|<>\n\r")
        guard target.rangeOfCharacter(from: shellSyntax) == nil else { return nil }
        return target
    }

    /// Parse ~/.zsh_history — both plain lines and the extended format
    /// (`: <ts>:<dur>;command`). Multi-line entries (backslash continuations)
    /// are skipped; a partial suggestion would type broken commands.
    static func loadZshHistory() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zsh_history")
        let data: Data
        let readTail: Bool
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            let start = size > UInt64(maxHistoryBytes)
                ? size - UInt64(maxHistoryBytes) : 0
            readTail = start > 0
            try handle.seek(toOffset: start)
            data = try handle.readToEnd() ?? Data()
        } catch {
            return []
        }
        // zsh history is not guaranteed UTF-8; fall back to ISO-Latin so we
        // never drop the whole file over one odd byte.
        var text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) ?? ""
        // A tail read may begin in the middle of an entry. Discard that
        // fragment so ghost text never offers a broken command.
        if readTail, let newline = text.firstIndex(of: "\n") {
            text.removeSubrange(...newline)
        }
        var out: [String] = []
        out.reserveCapacity(4096)
        var skipContinuation = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if skipContinuation {   // tail of a multi-line entry
                skipContinuation = rawLine.hasSuffix("\\")
                continue
            }
            var line = Substring(rawLine)
            if line.hasPrefix(": "), let semi = line.firstIndex(of: ";") {
                line = line[line.index(after: semi)...]   // extended format
            }
            if line.hasSuffix("\\") { skipContinuation = true; continue }
            let cmd = line.trimmingCharacters(in: .whitespaces)
            if !cmd.isEmpty, out.last != cmd { out.append(cmd) }
            if out.count >= maxCommands * 2 {
                out.removeFirst(maxCommands)
            }
        }
        return Array(out.suffix(maxCommands))
    }
}
