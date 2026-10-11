import Foundation

public extension WorkspaceLaunchHint {
    var displayName: String {
        switch tool {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .pi: return "Pi"
        }
    }

    /// Only a fixed executable and one validated identifier reach the shell.
    /// Restoring a workspace never executes this command.
    var resumeCommand: String {
        let identifier = "'\(sessionIdentifier)'"
        switch tool {
        case .codex: return "codex resume \(identifier)"
        case .claude: return "claude --resume \(identifier)"
        case .pi: return "pi --session \(identifier)"
        }
    }

    var layoutValue: [String: String] {
        ["tool": tool.rawValue, "sessionIdentifier": sessionIdentifier]
    }

    static func fromLayout(_ value: Any?) -> WorkspaceLaunchHint? {
        guard let object = value as? [String: Any],
              let rawTool = object["tool"] as? String,
              let tool = Tool(rawValue: rawTool),
              let identifier = object["sessionIdentifier"] as? String
        else { return nil }
        return WorkspaceLaunchHint(tool: tool, sessionIdentifier: identifier)
    }
}

/// Connect the named-workspace hint map to the same pane-tree paths used by
/// automatic recovery. Both forms remain backwards compatible with old files.
public enum WorkspaceResume {
    /// Recognize only an explicitly entered resume command with one ID. Never
    /// infer an ID from model output, environment variables, or session files.
    public static func explicitHint(command: String) -> WorkspaceLaunchHint? {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count == 3 else { return nil }
        let tool: WorkspaceLaunchHint.Tool
        switch (words[0], words[1]) {
        case ("codex", "resume"): tool = .codex
        case ("claude", "--resume"), ("claude", "-r"): tool = .claude
        case ("pi", "--session"): tool = .pi
        default: return nil
        }
        var identifier = words[2]
        if identifier.hasPrefix("'"), identifier.hasSuffix("'"), identifier.count > 2 {
            identifier = String(identifier.dropFirst().dropLast())
        }
        return WorkspaceLaunchHint(tool: tool, sessionIdentifier: identifier)
    }

    public static func launchHints(in layouts: [[String: Any]]) -> [String: WorkspaceLaunchHint] {
        var hints: [String: WorkspaceLaunchHint] = [:]
        func collect(_ node: [String: Any], path: String) {
            if node["type"] as? String == "split",
               let children = node["children"] as? [[String: Any]] {
                for (index, child) in children.enumerated() {
                    collect(child, path: "\(path)/child-\(index)")
                }
            } else if node["type"] as? String == "pane",
                      let hint = WorkspaceLaunchHint.fromLayout(node["launchHint"]) {
                hints[path] = hint
            }
        }
        for (index, node) in layouts.enumerated() {
            collect(node, path: "window-\(index)")
        }
        return hints
    }

    public static func applying(
        _ hints: [String: WorkspaceLaunchHint], to layouts: [[String: Any]]
    ) -> [[String: Any]] {
        func apply(_ original: [String: Any], path: String) -> [String: Any] {
            var node = original
            if node["type"] as? String == "split",
               let children = node["children"] as? [[String: Any]] {
                node["children"] = children.enumerated().map {
                    apply($0.element, path: "\(path)/child-\($0.offset)")
                }
            } else if node["type"] as? String == "pane", let hint = hints[path] {
                node["launchHint"] = hint.layoutValue
            }
            return node
        }
        return layouts.enumerated().map {
            apply($0.element, path: "window-\($0.offset)")
        }
    }
}
