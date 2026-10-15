import AppKit

public struct ConfigValidationIssue: Equatable, Identifiable, Sendable {
    public let key: String
    public let message: String
    public var id: String { key }
}

extension ConfigFile {
    public static func syntaxIssues(in text: String) -> [ConfigValidationIssue] {
        text.components(separatedBy: "\n").enumerated().compactMap { index, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            guard let equals = line.firstIndex(of: "="),
                  !line[..<equals].trimmingCharacters(in: .whitespaces).isEmpty else {
                return ConfigValidationIssue(key: "Line \(index + 1)", message: "Use key = value, or start a comment with #.")
            }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.count < 2 || !value.hasSuffix("\"") {
                return ConfigValidationIssue(key: "Line \(index + 1)", message: "Close the quoted value with a matching quotation mark.")
            }
            return nil
        }
    }

    /// Validate known settings without changing preferences. Unknown keys stay
    /// forward compatible, and messages never echo user-supplied values.
    public static func validationIssues(for values: [String: String]) -> [ConfigValidationIssue] {
        let booleans: Set<String> = [
            "marketplace-update-checks", "cursor-blink", "option-as-meta", "copy-on-select",
            "attention-signals", "shell-integration", "clean-prompt",
            "hide-traffic-lights", "window-grid", "workspace-navigator",
            "workspace-inspector", "blur", "ghost-text", "crt", "smooth-cursor",
            "smooth-scroll", "sounds", "restore-session", "automatic-error-help",
        ]
        let ranges: [String: ClosedRange<Double>] = [
            "font-size": 6...72, "line-height": 0.5...2,
            "scroll-speed": 0.2...5, "margin": 0...60, "opacity": 0.3...1,
            "cursor-glide-speed": 0.1...8, "cursor-glide-max-distance": 0...100,
        ]
        var issues: [ConfigValidationIssue] = []
        for key in values.keys.sorted() {
            let value = values[key]!
            let lower = value.lowercased()
            var message: String?
            if booleans.contains(key) {
                if !["true", "yes", "on", "1", "false", "no", "off", "0"].contains(lower) {
                    message = "Use true or false."
                }
            } else if let range = ranges[key] {
                if let number = Double(value), number.isFinite, range.contains(number) {
                    continue
                }
                message = "Use a number from \(range.lowerBound.formatted()) to \(range.upperBound.formatted())."
            } else {
                switch key {
                case "theme":
                    if !Theme.names.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                        message = "Choose an installed theme in Settings → Appearance."
                    }
                case "shader":
                    if !Preferences.shaderNames.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame })
                        && !["false", "no", "off", "0"].contains(lower) {
                        message = "Choose an installed shader, or None."
                    }
                case "font-family":
                    if lower != "system", FontLoader.font(named: value, size: 13) == nil {
                        message = "Choose an installed font, or System."
                    }
                case "cursor-color":
                    if !["theme", "auto"].contains(lower), Theme.hex(value) == nil {
                        message = "Use theme or a color in #RRGGBB format."
                    }
                case "keymap":
                    if !Preferences.keymaps.contains(lower) {
                        message = "Choose standard or omarchy."
                    }
                case "cursor-style":
                    if !["block", "bar", "underline"].contains(lower) {
                        message = "Choose block, bar, or underline."
                    }
                case "text-rendering":
                    if !Preferences.textRenderingModes.contains(lower) {
                        message = "Choose a Text Rendering preset from the Appearance menu."
                    }
                case "editor", "ai-model", "marketplace-registry":
                    if value.isEmpty { message = "This setting needs a value." }
                default: break
                }
            }
            if let message { issues.append(ConfigValidationIssue(key: key, message: message)) }
        }
        return issues
    }

    /// Remove active or commented legacy assignments while retaining every
    /// other line. Used for both the config and its automatic backup; credentials
    /// must not survive in a freshly generated .bak file.
    public static func removingAssistantCredentials(from text: String) -> String {
        var replaced = false
        return text.components(separatedBy: "\n").compactMap { raw -> String? in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            guard let eq = line.firstIndex(of: "="),
                  line[..<eq].trimmingCharacters(in: .whitespaces).lowercased() == "anthropic-api-key" else {
                return raw
            }
            guard !replaced else { return nil }
            replaced = true
            return "# Manage the Anthropic API key in Settings → Assistant (stored in Keychain)."
        }.joined(separator: "\n")
    }
}
