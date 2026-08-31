import Foundation

/// Side-effect helpers backing the popover's "Install Hook" and "Register MCP" buttons.
/// Idempotent — safe to call again. Returns a `SetupResult` describing what happened so
/// the UI can show "Installed", "Already installed", or "Failed".
enum BridgeSetup {
    enum SetupResult: Equatable {
        case installed       // we did the work; success
        case alreadyDone     // detected pre-existing state, no-op
        case failed(String)  // user-presentable error
    }

    // MARK: - Claude Code MCP registration

    /// Register the bridge's stdio bridge with Claude Code via `claude mcp add --scope user`.
    /// Idempotent — if `bridge` is already registered (detected via `claude mcp get`),
    /// returns `.alreadyDone`.
    static func registerMCP(stdioPath: String) -> SetupResult {
        // Fast detection BEFORE shelling out — reading ~/.claude.json is instant
        // and avoids the slow / occasionally-hanging `which claude` fallback.
        if isMCPRegistered() {
            return .alreadyDone
        }

        guard let claudeBin = locateClaude() else {
            return .failed("`claude` CLI not found. Run the snippet manually in your terminal.")
        }

        // Replace the legacy name/path instead of leaving two Bridge MCPs
        // advertising the same tools (the legacy entry commonly points at a
        // deleted debug build and reports "Connection closed").
        if registeredMCPNames().contains("braincell-bridge") {
            _ = runCommand(claudeBin, [
                "mcp", "remove", "braincell-bridge", "-s", "user",
            ], timeout: 10)
        }

        let result = runCommand(claudeBin, [
            "mcp", "add",
            "--scope", "user",
            "bridge",
            "--", "node", stdioPath,
        ], timeout: 15)

        if result.exit == 0 { return .installed }
        let msg = result.output.isEmpty ? "claude mcp add failed (exit \(result.exit))" : result.output
        return .failed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Read `~/.claude.json` directly to check if `bridge` is registered at the
    /// user scope. Authoritative + fast; doesn't shell out.
    static func isMCPRegistered() -> Bool {
        registeredMCPNames().contains("bridge")
    }

    private static func registeredMCPNames() -> Set<String> {
        let path = ("~/.claude.json" as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        guard let data = try? BridgeBoundedFileReader.data(
                at: url, maxBytes: 16 * 1024 * 1024),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mcpServers = root["mcpServers"] as? [String: Any] else {
            return []
        }
        return Set(mcpServers.keys)
    }

    // MARK: - Internals

    private static func locateClaude() -> String? {
        // Common install locations.
        let candidates = [
            ("~/.npm-global/bin/claude" as NSString).expandingTildeInPath,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            ("~/.bun/bin/claude" as NSString).expandingTildeInPath,
            "/usr/local/share/npm-global/bin/claude",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        // Try /usr/bin/which against our process's PATH (no shell-init sourcing).
        let r = runCommand("/usr/bin/which", ["claude"], timeout: 2)
        let path = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.exit == 0, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Last-ditch: ask the login shell. Capped at 5s — slow .zshrc is the original
        // beach-ball culprit, this timeout makes the failure visible instead of hanging.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let s = runCommand(shell, ["-l", "-c", "which claude"], timeout: 5)
        let spath = s.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.exit == 0, !spath.isEmpty, FileManager.default.isExecutableFile(atPath: spath) {
            return spath
        }
        return nil
    }

    /// Run a subprocess with a hard timeout. If the timeout elapses, the process is
    /// killed and we return exit=-2 + an error message. Prevents hangs on slow shell
    /// init, network-dependent commands, etc.
    private static func runCommand(_ path: String, _ args: [String], timeout: TimeInterval = 30) -> (exit: Int32, output: String) {
        do {
            let result = try BridgeProcessCapture.run(
                executable: URL(fileURLWithPath: path),
                arguments: args,
                timeout: timeout,
                stdoutLimit: 1_048_576,
                stderrLimit: 1_048_576)
            let output = String(decoding: result.stdout + result.stderr, as: UTF8.self)
            return (result.terminationStatus, output)
        } catch let error as BridgeProcessCaptureError {
            return (-2, error.localizedDescription)
        } catch {
            return (-1, "Failed to launch \(path): \(error.localizedDescription)")
        }
    }
}
