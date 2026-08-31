import Foundation
import ProductIdentity
import CmdyKit

/// Builds the child-process environment and, for zsh, injects OSC 133 shell
/// integration via a throwaway ZDOTDIR (the same technique iTerm2/Ghostty use).
/// The generated rc files source the user's real config first, so the shell is
/// unchanged apart from emitting semantic prompt markers.
enum ShellIntegration {

    /// Remove zdotdirs left behind by dead product processes (crashes / force
    /// quits) — each directory name embeds the pid that created it.
    static func cleanupStaleDirectories() {
        let tmp = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil) else { return }
        let myPid = ProcessInfo.processInfo.processIdentifier
        let prefixes = [ProductIdentity.current.slug]
            + ProductIdentity.current.legacySlugs
        for url in entries where prefixes.contains(where: {
            url.lastPathComponent.hasPrefix("\($0)-zdotdir-")
        }) {
            let parts = url.lastPathComponent.split(separator: "-")
            guard parts.count >= 3, let pid = Int32(parts[2]), pid != myPid else { continue }
            if kill(pid, 0) == -1 && errno == ESRCH {   // process is gone
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Returns the environment array ("KEY=VALUE" strings) for the shell.
    static func makeEnvironment(shellPath: String, integrationEnabled: Bool,
                                cleanPrompt: Bool = false) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        let identity = ProductIdentity.current
        env["TERM_PROGRAM"] = identity.slug

        // Finder launches do not inherit a shell PATH. Put the packaged cmdy
        // executable on PATH so the same CLI works in every child shell.
        if let executableDirectory = Bundle.main.executableURL?
            .deletingLastPathComponent().path {
            let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            let entries = currentPath.split(separator: ":").map(String.init)
            if !entries.contains(executableDirectory) {
                env["PATH"] = "\(executableDirectory):\(currentPath)"
            }
        }

        let isZsh = shellPath.hasSuffix("zsh")
        if integrationEnabled, isZsh, let dir = writeZshIntegration(cleanPrompt: cleanPrompt) {
            let prefix = identity.environmentPrefix
            env["\(prefix)_ORIG_ZDOTDIR"] =
                env["ZDOTDIR"] ?? env["HOME"] ?? NSHomeDirectory()
            env["ZDOTDIR"] = dir
            env["\(prefix)_SHELL_INTEGRATION"] = "1"
        }
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Writes a temp ZDOTDIR whose rc files defer to the user's real ones and
    /// add OSC 133 hooks. Returns the directory path, or nil on failure.
    private static func writeZshIntegration(cleanPrompt: Bool) -> String? {
        let identity = ProductIdentity.current
        let shellPrefix = identity.environmentPrefix
        let hookPrefix = "_" + identity.slug.replacingOccurrences(
            of: "-", with: "_")
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(identity.slug)-zdotdir-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))")
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        func passthrough(_ file: String) -> String {
            """
            export \(shellPrefix)_ORIG_ZDOTDIR="${\(shellPrefix)_ORIG_ZDOTDIR:-$HOME}"
            [[ -f "$\(shellPrefix)_ORIG_ZDOTDIR/\(file)" ]] && source "$\(shellPrefix)_ORIG_ZDOTDIR/\(file)"
            """
        }

        // Opt-in minimal prompt: after the user's config is sourced, replace
        // PROMPT with a hostname-free one (keeps the folder, except at `/`,
        // where the prompt is just `%`). The OSC 133 B marker below still
        // appends to it.
        let cleanBlock = cleanPrompt
            ? "# --- \(identity.slug) clean prompt (clean-prompt = true): no user@host ---\nPROMPT='%(1/.%~ .)%# '\nRPROMPT=''"
            : ""

        // .zshrc additionally installs the OSC 133 hooks, then restores ZDOTDIR
        // so the interactive session sees the user's real value.
        let zshrc = """
        export \(shellPrefix)_ORIG_ZDOTDIR="${\(shellPrefix)_ORIG_ZDOTDIR:-$HOME}"
        [[ -f "$\(shellPrefix)_ORIG_ZDOTDIR/.zshrc" ]] && source "$\(shellPrefix)_ORIG_ZDOTDIR/.zshrc"
        export ZDOTDIR="$\(shellPrefix)_ORIG_ZDOTDIR"
        \(cleanBlock)
        # --- \(identity.slug) OSC 133 semantic prompt integration ---
        autoload -Uz add-zsh-hook 2>/dev/null
        \(hookPrefix)_precmd()  { local r=$?; print -n "\\e]133;D;${r}\\a\\e]133;A\\a\\e]7;file://${HOST}${PWD}\\a"; }
        \(hookPrefix)_preexec() { print -n "\\e]133;C\\a"; }
        add-zsh-hook precmd  \(hookPrefix)_precmd  2>/dev/null
        add-zsh-hook preexec \(hookPrefix)_preexec 2>/dev/null
        # Embed the prompt-end (B) marker literally: no subshell, no PROMPT_SUBST.
        PROMPT="${PROMPT}%{"$'\\e]133;B\\a'"%}"

        """

        let files: [(String, String)] = [
            (".zshenv", passthrough(".zshenv")),
            (".zprofile", passthrough(".zprofile")),
            (".zlogin", passthrough(".zlogin")),
            (".zshrc", zshrc),
        ]
        for (name, contents) in files {
            let url = base.appendingPathComponent(name)
            if (try? contents.write(to: url, atomically: true, encoding: .utf8)) == nil {
                return nil
            }
        }
        return base.path
    }
}
