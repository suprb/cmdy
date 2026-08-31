import Darwin
import Foundation

public enum CMDYKeybindingImportSource: String, CaseIterable, Codable, Sendable {
    case ghostty
    case tmux
    case iTerm2 = "iterm2"
    case macOSTerminal = "macos-terminal"

    public var displayName: String {
        switch self {
        case .ghostty: return "Ghostty"
        case .tmux: return "tmux"
        case .iTerm2: return "iTerm2"
        case .macOSTerminal: return "macOS Terminal"
        }
    }
}

public enum CMDYKeybindingModifier: String, CaseIterable, Codable, Hashable, Sendable {
    case control
    case option
    case shift
    case command
}

public struct CMDYKeybindingShortcut: Codable, Hashable, Sendable {
    public let key: String
    public let modifiers: Set<CMDYKeybindingModifier>

    public init(key: String, modifiers: Set<CMDYKeybindingModifier>) throws {
        guard let normalized = Self.normalizedKey(key) else {
            throw CMDYKeybindingImportError.invalidShortcut(key)
        }
        self.key = normalized
        self.modifiers = modifiers
    }

    public var descriptor: String {
        let order: [CMDYKeybindingModifier] = [.control, .option, .shift, .command]
        let names: [CMDYKeybindingModifier: String] = [
            .control: "ctrl", .option: "option", .shift: "shift", .command: "cmd",
        ]
        return (order.filter(modifiers.contains).compactMap { names[$0] } + [key])
            .joined(separator: "+")
    }

    public var display: String {
        let symbols: [CMDYKeybindingModifier: String] = [
            .control: "⌃", .option: "⌥", .shift: "⇧", .command: "⌘",
        ]
        let keyNames: [String: String] = [
            "enter": "↩", "escape": "⎋", "tab": "⇥", "backspace": "⌫",
            "delete": "⌦", "space": "Space", "left": "←", "right": "→",
            "up": "↑", "down": "↓", "home": "Home", "end": "End",
            "page_up": "Page Up", "page_down": "Page Down", "insert": "Insert",
        ]
        return [CMDYKeybindingModifier.control, .option, .shift, .command]
            .filter(modifiers.contains).compactMap { symbols[$0] }.joined()
            + (keyNames[key] ?? key.uppercased())
    }

    static func normalizedKey(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let aliases: [String: String] = [
            "return": "enter", "numenter": "enter", "kp_enter": "enter",
            "esc": "escape", "back_space": "backspace", "bspace": "backspace",
            "bs": "backspace", "dc": "delete", "delete_forward": "delete",
            "del": "delete", "pgup": "page_up", "ppage": "page_up",
            "pageup": "page_up", "pgdn": "page_down", "npage": "page_down",
            "pagedown": "page_down", "ic": "insert", "arrowleft": "left",
            "arrowright": "right", "arrowup": "up", "arrowdown": "down",
            "backquote": "`", "grave": "`", "comma": ",", "period": ".",
            "slash": "/", "backslash": "\\", "minus": "-", "equal": "=",
            "left_bracket": "[", "right_bracket": "]", "semicolon": ";",
            "apostrophe": "'", "quote": "'", "plus": "+",
        ]
        let key = aliases[value] ?? value
        let named: Set<String> = [
            "enter", "escape", "tab", "backspace", "delete", "space", "left",
            "right", "up", "down", "home", "end", "page_up", "page_down", "insert",
        ]
        if named.contains(key) { return key }
        if key.range(of: #"^f([1-9]|1[0-9]|2[0-4])$"#, options: .regularExpression) != nil {
            return key
        }
        guard key.count == 1, key.utf8.count <= 4,
              key.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return key
    }
}

public enum CMDYKeybindingAction: String, CaseIterable, Codable, Hashable, Sendable {
    case openConfig, reloadConfig
    case copy, cut, paste, pasteSelection, selectAll
    case increaseFont, decreaseFont, resetFont
    case previousTab, nextTab, tab1, tab2, tab3, tab4, tab5, tab6, tab7, tab8, lastTab
    case fullscreen, splitZoom, commandPalette
    case quit, clear, undo, redo
    case scrollTop, scrollBottom, pageUp, pageDown, scrollSelection
    case previousPrompt, nextPrompt
    case newWindow, newTab, closeSurface, closeTab, closeWindow, closeAllWindows
    case splitRight, splitDown, previousSplit, nextSplit
    case focusLeft, focusRight, focusUp, focusDown
    case resizeLeft, resizeRight, resizeUp, resizeDown, equalizeSplits
    case startSearch, searchSelection, endSearch, searchNext, searchPrevious
    case inspector
    case writeScreenCopy, writeScreenPaste, writeScreenOpen

    public var displayName: String {
        rawValue
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2",
                                  options: .regularExpression)
            .replacingOccurrences(of: "([A-Za-z])(\\d)", with: "$1 $2",
                                  options: .regularExpression)
            .capitalized
    }
}

public enum CMDYKeybindingCommand: Codable, Hashable, Sendable {
    case action(CMDYKeybindingAction)
    case sendText(String)

    private enum CodingKeys: String, CodingKey { case type, value }
    private enum Kind: String, Codable { case action, sendText }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .type) {
        case .action:
            self = .action(try values.decode(CMDYKeybindingAction.self, forKey: .value))
        case .sendText:
            let text = try values.decode(String.self, forKey: .value)
            guard text.utf8.count <= CMDYKeybindingImporter.maximumSendTextBytes else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: values, debugDescription: "send text exceeds 16 KB")
            }
            self = .sendText(text)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .action(let action):
            try values.encode(Kind.action, forKey: .type)
            try values.encode(action, forKey: .value)
        case .sendText(let text):
            try values.encode(Kind.sendText, forKey: .type)
            try values.encode(text, forKey: .value)
        }
    }

    public var displayName: String {
        switch self {
        case .action(let action): return action.displayName
        case .sendText(let text):
            let rendered = text.unicodeScalars.map { scalar -> String in
                switch scalar.value {
                case 0x1B: return "\\e"
                case 0x0A: return "\\n"
                case 0x0D: return "\\r"
                case 0x09: return "\\t"
                case 0x20...0x7E: return String(scalar)
                default: return String(format: "\\u{%X}", scalar.value)
                }
            }.joined()
            return "Send “\(rendered.prefix(48))\(rendered.count > 48 ? "…" : "")”"
        }
    }
}

public enum CMDYKeybindingImportDisposition: String, Codable, Sendable {
    case ready
    case unsupported
    case malformed
    case importConflict
    case nativeConflict
    case existingConflict
}

public struct CMDYKeybindingImportCandidate: Identifiable, Sendable {
    public let id: Int
    public let source: CMDYKeybindingImportSource
    public let location: String
    public let sourceShortcut: String
    public let sourceAction: String
    public let shortcut: CMDYKeybindingShortcut?
    public let command: CMDYKeybindingCommand?
    public let disposition: CMDYKeybindingImportDisposition
    public let detail: String

    public var canApply: Bool { disposition == .ready && shortcut != nil && command != nil }
}

public struct CMDYKeybindingImportPreview: Sendable {
    public let source: CMDYKeybindingImportSource
    public let candidates: [CMDYKeybindingImportCandidate]

    public var readyCount: Int { candidates.lazy.filter(\.canApply).count }
    public var unsupportedCount: Int {
        candidates.lazy.filter { $0.disposition == .unsupported || $0.disposition == .malformed }.count
    }
    public var conflictCount: Int {
        candidates.lazy.filter {
            [.importConflict, .nativeConflict, .existingConflict].contains($0.disposition)
        }.count
    }
}

public struct CMDYKeybindingMapping: Codable, Hashable, Sendable {
    public let shortcut: CMDYKeybindingShortcut
    public let command: CMDYKeybindingCommand
    public let source: CMDYKeybindingImportSource
    public let sourceAction: String
    public let importedAt: Date

    public init(shortcut: CMDYKeybindingShortcut, command: CMDYKeybindingCommand,
                source: CMDYKeybindingImportSource, sourceAction: String,
                importedAt: Date = Date()) {
        self.shortcut = shortcut
        self.command = command
        self.source = source
        self.sourceAction = sourceAction
        self.importedAt = importedAt
    }
}

public enum CMDYKeybindingImportError: LocalizedError, Equatable {
    case unreadable(String)
    case tooManyMappings(Int)
    case invalidDocument(String)
    case invalidShortcut(String)
    case corruptStore(String)
    case storeTooLarge

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path): return "Could not read keybindings at \(path)"
        case .tooManyMappings(let limit): return "Keybinding source exceeds \(limit) mappings"
        case .invalidDocument(let reason): return "Invalid keybinding document: \(reason)"
        case .invalidShortcut(let value): return "Invalid shortcut: \(value)"
        case .corruptStore(let reason): return "Keybinding store is corrupt: \(reason)"
        case .storeTooLarge: return "Keybinding store exceeds 4 MB"
        }
    }
}

public enum CMDYKeybindingCatalog {
    /// Known shortcuts already owned by cmdy's native event monitor or standard
    /// macOS menus. App integration may union additional menu equivalents.
    public static let nativeShortcuts: Set<CMDYKeybindingShortcut> = {
        var result = Set<CMDYKeybindingShortcut>()
        func add(_ descriptor: String) {
            if let shortcut = try? CMDYKeybindingImporter.parseShortcutDescriptor(descriptor) {
                result.insert(shortcut)
            }
        }
        [
            "escape", "ctrl+tab", "ctrl+shift+tab", "cmd+enter", "cmd+shift+enter",
            "cmd+home", "cmd+end", "cmd+page_up", "cmd+page_down",
            "cmd+up", "cmd+down", "cmd+shift+up", "cmd+shift+down",
            "cmd+left", "cmd+right", "cmd+backspace",
            "option+left", "option+right", "option+backspace",
            "cmd+option+left", "cmd+option+right", "cmd+option+up", "cmd+option+down",
            "cmd+ctrl+left", "cmd+ctrl+right", "cmd+ctrl+up", "cmd+ctrl+down",
            "shift+left", "shift+right", "shift+up", "shift+down",
            "shift+home", "shift+end", "shift+page_up", "shift+page_down",
            "cmd+,", "cmd+shift+,", "cmd+c", "cmd+x", "cmd+v", "cmd+shift+v",
            "cmd+=", "cmd++", "cmd+-", "cmd+0", "cmd+a", "cmd+shift+p",
            "cmd+q", "cmd+k", "cmd+z", "cmd+shift+z", "cmd+shift+t",
            "cmd+n", "cmd+t",
            "cmd+w", "cmd+option+w", "cmd+shift+w", "cmd+option+shift+w",
            "cmd+[", "cmd+]", "cmd+shift+[", "cmd+shift+]", "cmd+d",
            "cmd+shift+d", "cmd+ctrl+=", "cmd+f", "cmd+e", "cmd+shift+f",
            "cmd+g", "cmd+shift+g", "cmd+option+i", "cmd+ctrl+f",
            "cmd+o", "cmd+option+o", "cmd+s", "cmd+shift+s", "cmd+h", "cmd+m",
            "cmd+ctrl+shift+j", "cmd+option+shift+j", "cmd+shift+j", "cmd+j",
        ].forEach(add)
        for digit in 1...9 { add("cmd+\(digit)") }
        return result
    }()
}

public enum CMDYKeybindingImporter {
    public static let maximumSourceBytes = 8 * 1024 * 1024
    public static let maximumMappings = 4_096
    public static let maximumSendTextBytes = 16 * 1024

    private struct Draft {
        let source: CMDYKeybindingImportSource
        let location: String
        let sourceShortcut: String
        let sourceAction: String
        let shortcut: CMDYKeybindingShortcut?
        let command: CMDYKeybindingCommand?
        let disposition: CMDYKeybindingImportDisposition
        let detail: String
    }

    public static func preview(
        fileURL: URL,
        source: CMDYKeybindingImportSource,
        existing: [CMDYKeybindingMapping] = [],
        reserved: Set<CMDYKeybindingShortcut> = CMDYKeybindingCatalog.nativeShortcuts
    ) throws -> CMDYKeybindingImportPreview {
        let data: Data
        do {
            data = try BoundedFileReader.data(at: fileURL, maxBytes: maximumSourceBytes)
        } catch {
            throw CMDYKeybindingImportError.unreadable(fileURL.path)
        }
        return try preview(data: data, source: source, existing: existing, reserved: reserved)
    }

    public static func preview(
        data: Data,
        source: CMDYKeybindingImportSource,
        existing: [CMDYKeybindingMapping] = [],
        reserved: Set<CMDYKeybindingShortcut> = CMDYKeybindingCatalog.nativeShortcuts
    ) throws -> CMDYKeybindingImportPreview {
        guard data.count <= maximumSourceBytes else {
            throw BoundedFileReaderError.tooLarge(path: source.rawValue, maxBytes: maximumSourceBytes)
        }
        let drafts: [Draft]
        switch source {
        case .ghostty:
            drafts = try parseGhostty(text(data, source: source))
        case .tmux:
            drafts = try parseTmux(text(data, source: source))
        case .iTerm2:
            drafts = try parseITerm2(data)
        case .macOSTerminal:
            drafts = try parseTerminal(data)
        }
        guard drafts.count <= maximumMappings else {
            throw CMDYKeybindingImportError.tooManyMappings(maximumMappings)
        }
        return finalize(source: source, drafts: drafts, existing: existing, reserved: reserved)
    }

    public static func parseShortcutDescriptor(_ descriptor: String) throws
        -> CMDYKeybindingShortcut {
        var components = descriptor.split(separator: "+", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let rawKey: String
        if components.count >= 3,
           components[components.count - 1].isEmpty,
           components[components.count - 2].isEmpty {
            rawKey = "+"
            components.removeLast(2)
        } else if let key = components.popLast(), !key.isEmpty {
            rawKey = key
        } else {
            throw CMDYKeybindingImportError.invalidShortcut(descriptor)
        }
        var modifiers = Set<CMDYKeybindingModifier>()
        for token in components {
            switch token.lowercased() {
            case "cmd", "command", "super": modifiers.insert(.command)
            case "option", "opt", "alt", "meta": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            case "shift": modifiers.insert(.shift)
            default: throw CMDYKeybindingImportError.invalidShortcut(descriptor)
            }
        }
        return try CMDYKeybindingShortcut(key: rawKey, modifiers: modifiers)
    }

    private static func text(_ data: Data, source: CMDYKeybindingImportSource) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CMDYKeybindingImportError.invalidDocument(
                "\(source.displayName) configuration is not UTF-8")
        }
        return text
    }

    private static func finalize(
        source: CMDYKeybindingImportSource,
        drafts: [Draft],
        existing: [CMDYKeybindingMapping],
        reserved: Set<CMDYKeybindingShortcut>
    ) -> CMDYKeybindingImportPreview {
        let existingShortcuts = Set(existing.map(\.shortcut))
        var counts: [CMDYKeybindingShortcut: Int] = [:]
        for draft in drafts {
            if let shortcut = draft.shortcut, draft.disposition == .ready {
                counts[shortcut, default: 0] += 1
            }
        }
        let candidates = drafts.enumerated().map { index, draft -> CMDYKeybindingImportCandidate in
            var disposition = draft.disposition
            var detail = draft.detail
            if disposition == .ready, let shortcut = draft.shortcut {
                if shortcut.modifiers.isEmpty,
                   shortcut.key.count == 1,
                   shortcut.key != " " {
                    disposition = .unsupported
                    detail = "Unmodified printable keys would replace normal terminal typing"
                } else if (counts[shortcut] ?? 0) > 1 {
                    disposition = .importConflict
                    detail = "More than one imported action uses \(shortcut.display)"
                } else if reserved.contains(shortcut) {
                    disposition = .nativeConflict
                    detail = "\(shortcut.display) is already owned by macOS or cmdy"
                } else if existingShortcuts.contains(shortcut) {
                    disposition = .existingConflict
                    detail = "\(shortcut.display) already exists in cmdy's imported mappings"
                }
            }
            return CMDYKeybindingImportCandidate(
                id: index, source: draft.source, location: draft.location,
                sourceShortcut: draft.sourceShortcut, sourceAction: draft.sourceAction,
                shortcut: draft.shortcut, command: draft.command,
                disposition: disposition, detail: detail)
        }
        return CMDYKeybindingImportPreview(source: source, candidates: candidates)
    }

    // MARK: Ghostty

    private static func parseGhostty(_ text: String) throws -> [Draft] {
        var result: [Draft] = []
        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else {
                continue
            }
            let directive = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard directive == "keybind" else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            guard let actionEquals = value.firstIndex(of: "=") else {
                result.append(invalidDraft(.ghostty, offset + 1, value, "", "Missing trigger/action separator"))
                continue
            }
            let trigger = String(value[..<actionEquals]).trimmingCharacters(in: .whitespaces)
            let action = String(value[value.index(after: actionEquals)...])
                .trimmingCharacters(in: .whitespaces)
            if trigger == "chain" {
                result.append(unsupportedDraft(.ghostty, offset + 1, trigger, action,
                                               "Chained actions are not representable as one cmdy command"))
                continue
            }
            if trigger.contains(">") || trigger.contains("/") {
                result.append(unsupportedDraft(.ghostty, offset + 1, trigger, action,
                                               "Key sequences and named key tables are not supported"))
                continue
            }
            var triggerParts = trigger.split(separator: ":", omittingEmptySubsequences: false)
                .map(String.init)
            var prefixes: [String] = []
            while triggerParts.count > 1,
                  ["all", "global", "unconsumed", "performable"].contains(triggerParts[0]) {
                prefixes.append(triggerParts.removeFirst())
            }
            if !prefixes.isEmpty {
                result.append(unsupportedDraft(
                    .ghostty, offset + 1, trigger, action,
                    "Ghostty's \(prefixes.joined(separator: ", ")) scope/consumption semantics cannot be preserved"))
                continue
            }
            let shortcut: CMDYKeybindingShortcut
            do { shortcut = try parseShortcutDescriptor(triggerParts.joined(separator: ":")) }
            catch {
                result.append(invalidDraft(.ghostty, offset + 1, trigger, action,
                                           "Shortcut is not representable in cmdy"))
                continue
            }
            switch translateGhosttyAction(action) {
            case .success(let command):
                result.append(readyDraft(.ghostty, offset + 1, trigger, action, shortcut, command))
            case .failure(let error):
                result.append(unsupportedDraft(.ghostty, offset + 1, trigger, action,
                                               error.localizedDescription))
            }
        }
        return result
    }

    private static func translateGhosttyAction(_ raw: String) -> Result<CMDYKeybindingCommand, Error> {
        let pieces = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(pieces[0]).lowercased()
        let argument = pieces.count > 1 ? String(pieces[1]) : ""
        let direct: [String: CMDYKeybindingAction] = [
            "open_config": .openConfig, "reload_config": .reloadConfig,
            "copy_to_clipboard": .copy, "paste_from_clipboard": .paste,
            "paste_from_selection": .pasteSelection, "select_all": .selectAll,
            "increase_font_size": .increaseFont, "decrease_font_size": .decreaseFont,
            "reset_font_size": .resetFont, "new_window": .newWindow,
            "new_tab": .newTab, "close_surface": .closeSurface, "close_tab": .closeTab,
            "close_window": .closeWindow, "close_all_windows": .closeAllWindows,
            "toggle_split_zoom": .splitZoom, "toggle_fullscreen": .fullscreen,
            "equalize_splits": .equalizeSplits, "clear_screen": .clear,
            "scroll_to_top": .scrollTop, "scroll_to_bottom": .scrollBottom,
            "scroll_page_up": .pageUp, "scroll_page_down": .pageDown,
            "scroll_to_selection": .scrollSelection, "start_search": .startSearch,
            "search_selection": .searchSelection, "end_search": .endSearch,
            "toggle_command_palette": .commandPalette, "undo": .undo, "redo": .redo,
        ]
        if let action = direct[name] { return .success(.action(action)) }
        switch name {
        case "text": return decodeEscapedText(argument).map(CMDYKeybindingCommand.sendText)
        case "esc": return boundedText("\u{1b}" + argument).map(CMDYKeybindingCommand.sendText)
        case "csi": return boundedText("\u{1b}[" + argument).map(CMDYKeybindingCommand.sendText)
        case "new_split":
            if argument == "right" { return .success(.action(.splitRight)) }
            if argument == "down" { return .success(.action(.splitDown)) }
        case "goto_split":
            let map: [String: CMDYKeybindingAction] = [
                "left": .focusLeft, "right": .focusRight, "up": .focusUp,
                "down": .focusDown, "previous": .previousSplit, "next": .nextSplit,
            ]
            if let action = map[argument] { return .success(.action(action)) }
        case "resize_split":
            let direction = argument.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
            let map: [String: CMDYKeybindingAction] = [
                "left": .resizeLeft, "right": .resizeRight, "up": .resizeUp, "down": .resizeDown,
            ]
            if let action = map[direction] { return .success(.action(action)) }
        case "navigate_search":
            if ["next", "down", "1"].contains(argument) { return .success(.action(.searchNext)) }
            if ["previous", "up", "-1"].contains(argument) { return .success(.action(.searchPrevious)) }
        case "jump_to_prompt":
            if argument.hasPrefix("-") { return .success(.action(.previousPrompt)) }
            if let count = Int(argument), count > 0 { return .success(.action(.nextPrompt)) }
        case "write_screen_file":
            let map: [String: CMDYKeybindingAction] = [
                "copy": .writeScreenCopy, "paste": .writeScreenPaste, "open": .writeScreenOpen,
            ]
            if let action = map[argument] { return .success(.action(action)) }
        case "inspector":
            if argument.isEmpty || argument == "toggle" { return .success(.action(.inspector)) }
        case "goto_tab":
            let map: [String: CMDYKeybindingAction] = [
                "previous": .previousTab, "next": .nextTab, "last": .lastTab,
                "1": .tab1, "2": .tab2, "3": .tab3, "4": .tab4,
                "5": .tab5, "6": .tab6, "7": .tab7, "8": .tab8,
            ]
            if let action = map[argument] { return .success(.action(action)) }
        default: break
        }
        return .failure(TranslationError.unsupported("Unsupported Ghostty action ‘\(raw)’"))
    }

    // MARK: tmux

    private static func parseTmux(_ text: String) throws -> [Draft] {
        var result: [Draft] = []
        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let tokens = shellTokens(rawLine)
            guard let verb = tokens.first, ["bind", "bind-key"].contains(verb) else { continue }
            var index = 1
            var direct = false
            var table: String?
            while index < tokens.count, tokens[index].hasPrefix("-") {
                let flag = tokens[index]
                if flag == "--" { index += 1; break }
                if flag == "-T" || flag == "-N" {
                    guard index + 1 < tokens.count else { break }
                    if flag == "-T" { table = tokens[index + 1] }
                    index += 2
                    continue
                }
                if flag.dropFirst().contains("n") { direct = true }
                index += 1
            }
            guard index < tokens.count else {
                result.append(invalidDraft(.tmux, offset + 1, "", "", "Missing tmux key"))
                continue
            }
            let key = tokens[index]
            let actionTokens = index + 1 < tokens.count ? Array(tokens[(index + 1)...]) : []
            let actionText = actionTokens.joined(separator: " ")
            let effectiveDirect = direct || table == "root"
            guard effectiveDirect else {
                result.append(unsupportedDraft(
                    .tmux, offset + 1, key, actionText,
                    "tmux prefix-table bindings are key sequences; only -n or -T root imports"))
                continue
            }
            let shortcut: CMDYKeybindingShortcut
            do { shortcut = try parseTmuxShortcut(key) }
            catch {
                result.append(invalidDraft(.tmux, offset + 1, key, actionText,
                                           "tmux key is not representable in cmdy"))
                continue
            }
            if let command = translateTmuxAction(actionTokens) {
                result.append(readyDraft(.tmux, offset + 1, key, actionText, shortcut, command))
            } else {
                result.append(unsupportedDraft(.tmux, offset + 1, key, actionText,
                                               "Unsupported tmux command ‘\(actionText)’"))
            }
        }
        return result
    }

    private static func parseTmuxShortcut(_ raw: String) throws -> CMDYKeybindingShortcut {
        var value = raw
        var modifiers = Set<CMDYKeybindingModifier>()
        while true {
            if value.hasPrefix("C-") || value.hasPrefix("c-") {
                modifiers.insert(.control); value.removeFirst(2)
            } else if value.hasPrefix("M-") || value.hasPrefix("m-") {
                modifiers.insert(.option); value.removeFirst(2)
            } else if value.hasPrefix("S-") || value.hasPrefix("s-") {
                modifiers.insert(.shift); value.removeFirst(2)
            } else if value.hasPrefix("^") {
                modifiers.insert(.control); value.removeFirst()
            } else { break }
        }
        return try CMDYKeybindingShortcut(key: value, modifiers: modifiers)
    }

    private static func translateTmuxAction(_ tokens: [String]) -> CMDYKeybindingCommand? {
        guard let verb = tokens.first else { return nil }
        let args = Array(tokens.dropFirst())
        switch verb {
        case "new-window": return .action(.newTab)
        case "kill-pane": return .action(.closeSurface)
        case "kill-window": return .action(.closeTab)
        case "next-window": return .action(.nextTab)
        case "previous-window": return .action(.previousTab)
        case "last-window": return .action(.lastTab)
        case "next-layout": return nil
        case "select-pane":
            let map: [String: CMDYKeybindingAction] = [
                "-L": .focusLeft, "-R": .focusRight, "-U": .focusUp, "-D": .focusDown,
            ]
            return args.compactMap { map[$0] }.first.map(CMDYKeybindingCommand.action)
        case "resize-pane":
            let map: [String: CMDYKeybindingAction] = [
                "-L": .resizeLeft, "-R": .resizeRight, "-U": .resizeUp, "-D": .resizeDown,
            ]
            return args.compactMap { map[$0] }.first.map(CMDYKeybindingCommand.action)
        case "select-window":
            if args.contains("-n") { return .action(.nextTab) }
            if args.contains("-p") { return .action(.previousTab) }
            if args.contains("-l") { return .action(.lastTab) }
            return nil
        case "split-window":
            if args.contains("-h") { return .action(.splitRight) }
            return .action(.splitDown)
        case "send-keys":
            guard let literal = args.firstIndex(of: "-l"), literal + 1 < args.count else { return nil }
            let text = args[(literal + 1)...].joined(separator: " ")
            return text.utf8.count <= maximumSendTextBytes ? .sendText(text) : nil
        default: return nil
        }
    }

    // MARK: iTerm2

    private static func parseITerm2(_ data: Data) throws -> [Draft] {
        let root = try propertyListOrJSON(data, source: "iTerm2")
        var records: [(String, [String: Any])] = []
        collectITermMappings(root, path: "iTerm2", depth: 0, records: &records)
        return records.prefix(maximumMappings + 1).enumerated().map { index, record in
            let (descriptor, value) = record
            let sourceAction = String(describing: value["Action"] ?? "")
            guard let shortcut = parseITermShortcut(descriptor: descriptor, value: value) else {
                return invalidDraft(.iTerm2, index + 1, descriptor, sourceAction,
                                    "iTerm2 key descriptor is not representable in cmdy")
            }
            guard let command = translateITermAction(value) else {
                return unsupportedDraft(.iTerm2, index + 1, descriptor, sourceAction,
                                        "Unsupported iTerm2 action \(sourceAction)")
            }
            return readyDraft(.iTerm2, index + 1, descriptor, sourceAction, shortcut, command)
        }
    }

    private static func collectITermMappings(
        _ object: Any, path: String, depth: Int,
        records: inout [(String, [String: Any])]
    ) {
        guard depth <= 12, records.count <= maximumMappings else { return }
        if let dictionary = object as? [String: Any] {
            for key in ["Keyboard Map", "Key Mappings"] {
                if let mappings = dictionary[key] as? [String: Any] {
                    for descriptor in mappings.keys.sorted() {
                        if let value = mappings[descriptor] as? [String: Any] {
                            records.append((descriptor, value))
                        }
                    }
                } else if let mappings = dictionary[key] as? [[String: Any]] {
                    for value in mappings {
                        let descriptor = (value["Shortcut"] as? String)
                            ?? (value["Key Combination"] as? String)
                            ?? (value["Key"] as? String)
                            ?? ""
                        records.append((descriptor, value))
                    }
                }
            }
            for (key, value) in dictionary where key != "Keyboard Map" && key != "Key Mappings" {
                collectITermMappings(value, path: path + "." + key, depth: depth + 1,
                                     records: &records)
            }
        } else if let array = object as? [Any] {
            for (index, value) in array.enumerated() {
                collectITermMappings(value, path: "\(path)[\(index)]", depth: depth + 1,
                                     records: &records)
            }
        }
    }

    private static func parseITermShortcut(
        descriptor: String, value: [String: Any]
    ) -> CMDYKeybindingShortcut? {
        var keyCode: Int?
        var modifierMask: Int = 0
        let parts = descriptor.split(separator: "-").map(String.init)
        if parts.count >= 2 {
            keyCode = parseInteger(parts[0])
            modifierMask = parseInteger(parts[1]) ?? 0
        }
        if keyCode == nil {
            keyCode = integer(value["Key"])
            modifierMask = integer(value["Modifiers"]) ?? modifierMask
        }
        guard let keyCode, let key = cocoaKey(code: keyCode) else { return nil }
        var modifiers = Set<CMDYKeybindingModifier>()
        if modifierMask & 0x20000 != 0 { modifiers.insert(.shift) }
        if modifierMask & 0x40000 != 0 { modifiers.insert(.control) }
        if modifierMask & 0x80000 != 0 { modifiers.insert(.option) }
        if modifierMask & 0x100000 != 0 { modifiers.insert(.command) }
        return try? CMDYKeybindingShortcut(key: key, modifiers: modifiers)
    }

    private static func translateITermAction(_ value: [String: Any]) -> CMDYKeybindingCommand? {
        let text = (value["Text"] as? String) ?? (value["Parameter"] as? String) ?? ""
        if let raw = integer(value["Action"]) {
            let direct: [Int: CMDYKeybindingAction] = [
                0: .nextTab, 2: .previousTab, 4: .scrollBottom, 5: .scrollTop,
                8: .pageDown, 9: .pageUp, 18: .focusLeft, 19: .focusRight,
                20: .focusUp, 21: .focusDown, 23: .fullscreen, 26: .newWindow,
                27: .newTab, 28: .splitDown, 29: .splitRight, 30: .nextSplit,
                31: .previousSplit, 32: .nextTab, 39: .previousTab, 44: .undo,
            ]
            if let action = direct[raw] { return .action(action) }
            if raw == 10 {
                let value = "\u{1b}" + text
                return value.utf8.count <= maximumSendTextBytes ? .sendText(value) : nil
            }
            if raw == 11 { return decodeHexBytes(text).map(CMDYKeybindingCommand.sendText) }
            if raw == 12 || raw == 38 || raw == 76 {
                return text.utf8.count <= maximumSendTextBytes ? .sendText(text) : nil
            }
            return nil
        }
        guard let actionName = value["Action"] as? String else { return nil }
        let normalized = actionName.lowercased().replacingOccurrences(of: " ", with: "-")
        let map: [String: CMDYKeybindingAction] = [
            "next-tab": .nextTab, "previous-tab": .previousTab,
            "next-pane": .nextSplit, "previous-pane": .previousSplit,
            "new-window": .newWindow, "new-tab": .newTab,
            "split-horizontally": .splitDown, "split-vertically": .splitRight,
            "toggle-fullscreen": .fullscreen, "scroll-to-top": .scrollTop,
            "scroll-to-bottom": .scrollBottom, "page-up": .pageUp, "page-down": .pageDown,
        ]
        return map[normalized].map(CMDYKeybindingCommand.action)
    }

    // MARK: macOS Terminal

    private static func parseTerminal(_ data: Data) throws -> [Draft] {
        let root = try propertyListOrJSON(data, source: "macOS Terminal")
        var records: [(String, Any)] = []
        collectTerminalMappings(root, depth: 0, records: &records)
        return records.prefix(maximumMappings + 1).enumerated().map { index, record in
            let (descriptor, output) = record
            guard let shortcut = parseTerminalShortcut(descriptor) else {
                return invalidDraft(.macOSTerminal, index + 1, descriptor, String(describing: output),
                                    "Terminal key descriptor is not representable in cmdy")
            }
            guard let text = output as? String, text.utf8.count <= maximumSendTextBytes else {
                return unsupportedDraft(.macOSTerminal, index + 1, descriptor,
                                        String(describing: output),
                                        "Terminal mapping does not contain bounded text output")
            }
            return readyDraft(.macOSTerminal, index + 1, descriptor, text,
                              shortcut, .sendText(text))
        }
    }

    private static func collectTerminalMappings(
        _ object: Any, depth: Int, records: inout [(String, Any)]
    ) {
        guard depth <= 12, records.count <= maximumMappings else { return }
        if let dictionary = object as? [String: Any] {
            if let mappings = dictionary["keyMapBoundKeys"] as? [String: Any] {
                for key in mappings.keys.sorted() { records.append((key, mappings[key] as Any)) }
            }
            for (key, value) in dictionary where key != "keyMapBoundKeys" {
                collectTerminalMappings(value, depth: depth + 1, records: &records)
            }
        } else if let array = object as? [Any] {
            for value in array { collectTerminalMappings(value, depth: depth + 1, records: &records) }
        }
    }

    private static func parseTerminalShortcut(_ descriptor: String) -> CMDYKeybindingShortcut? {
        var value = descriptor
        var modifiers = Set<CMDYKeybindingModifier>()
        while let first = value.first, ["$", "^", "~", "@", "#"].contains(String(first)) {
            value.removeFirst()
            switch first {
            case "$": modifiers.insert(.shift)
            case "^": modifiers.insert(.control)
            case "~": modifiers.insert(.option)
            case "@": modifiers.insert(.command)
            default: break // numeric keypad has no cmdy modifier equivalent
            }
        }
        let key: String?
        if value.count == 4, let code = Int(value, radix: 16) { key = cocoaKey(code: code) }
        else { key = CMDYKeybindingShortcut.normalizedKey(value) }
        guard let key else { return nil }
        return try? CMDYKeybindingShortcut(key: key, modifiers: modifiers)
    }

    // MARK: shared parsing helpers

    private static func propertyListOrJSON(_ data: Data, source: String) throws -> Any {
        if let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) { return plist }
        if let json = try? JSONSerialization.jsonObject(with: data) { return json }
        throw CMDYKeybindingImportError.invalidDocument("\(source) file is not JSON or a plist")
    }

    private static func cocoaKey(code: Int) -> String? {
        let special: [Int: String] = [
            0x09: "tab", 0x0D: "enter", 0x1B: "escape", 0x20: "space",
            0x7F: "backspace", 0xF700: "up", 0xF701: "down", 0xF702: "left",
            0xF703: "right", 0xF727: "insert", 0xF728: "delete", 0xF729: "home",
            0xF72B: "end", 0xF72C: "page_up", 0xF72D: "page_down",
        ]
        if let key = special[code] { return key }
        if (0xF704...0xF71B).contains(code) { return "f\(code - 0xF704 + 1)" }
        guard let scalar = UnicodeScalar(code),
              !CharacterSet.controlCharacters.contains(scalar) else { return nil }
        return String(scalar).lowercased()
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return parseInteger(value) }
        return nil
    }

    private static func parseInteger(_ raw: String) -> Int? {
        let value = raw.lowercased()
        if value.hasPrefix("0x") { return Int(value.dropFirst(2), radix: 16) }
        return Int(value)
    }

    private static func shellTokens(_ raw: String) -> [String] {
        var tokens: [String] = []
        var token = ""
        var quote: Character?
        var escaping = false
        for character in raw {
            if escaping { token.append(character); escaping = false; continue }
            if character == "\\" { escaping = true; continue }
            if let active = quote {
                if character == active { quote = nil } else { token.append(character) }
                continue
            }
            if character == "\"" || character == "'" { quote = character; continue }
            if character == "#" { break }
            if character.isWhitespace {
                if !token.isEmpty { tokens.append(token); token = "" }
            } else { token.append(character) }
        }
        if escaping { token.append("\\") }
        if !token.isEmpty { tokens.append(token) }
        return tokens
    }

    private static func decodeEscapedText(_ raw: String) -> Result<String, Error> {
        var output = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            guard character == "\\" else {
                output.append(character); index = raw.index(after: index); continue
            }
            let nextIndex = raw.index(after: index)
            guard nextIndex < raw.endIndex else {
                return .failure(TranslationError.unsupported("Trailing escape in text action"))
            }
            let next = raw[nextIndex]
            switch next {
            case "n": output.append("\n"); index = raw.index(after: nextIndex)
            case "r": output.append("\r"); index = raw.index(after: nextIndex)
            case "t": output.append("\t"); index = raw.index(after: nextIndex)
            case "e": output.append("\u{1b}"); index = raw.index(after: nextIndex)
            case "\\": output.append("\\"); index = raw.index(after: nextIndex)
            case "\"": output.append("\""); index = raw.index(after: nextIndex)
            case "x":
                let start = raw.index(after: nextIndex)
                guard let end = raw.index(start, offsetBy: 2, limitedBy: raw.endIndex),
                      end <= raw.endIndex,
                      let byte = UInt8(raw[start..<end], radix: 16) else {
                    return .failure(TranslationError.unsupported("Invalid \\x escape in text action"))
                }
                output.append(Character(UnicodeScalar(byte)))
                index = end
            default:
                return .failure(TranslationError.unsupported("Unsupported text escape \\(next)"))
            }
            if output.utf8.count > maximumSendTextBytes {
                return .failure(TranslationError.unsupported("Text action exceeds 16 KB"))
            }
        }
        return .success(output)
    }

    private static func decodeHexBytes(_ raw: String) -> String? {
        let compact = raw.replacingOccurrences(of: "0x", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        guard !compact.isEmpty, compact.count.isMultiple(of: 2),
              compact.count / 2 <= maximumSendTextBytes else { return nil }
        var bytes: [UInt8] = []
        var index = compact.startIndex
        while index < compact.endIndex {
            let end = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<end], radix: 16) else { return nil }
            bytes.append(byte); index = end
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func boundedText(_ text: String) -> Result<String, Error> {
        text.utf8.count <= maximumSendTextBytes
            ? .success(text)
            : .failure(TranslationError.unsupported("Text action exceeds 16 KB"))
    }

    private static func readyDraft(
        _ source: CMDYKeybindingImportSource, _ line: Int, _ shortcut: String,
        _ action: String, _ normalized: CMDYKeybindingShortcut,
        _ command: CMDYKeybindingCommand
    ) -> Draft {
        Draft(source: source, location: "line \(line)", sourceShortcut: shortcut,
              sourceAction: action, shortcut: normalized, command: command,
              disposition: .ready, detail: "Ready to import")
    }

    private static func unsupportedDraft(
        _ source: CMDYKeybindingImportSource, _ line: Int, _ shortcut: String,
        _ action: String, _ detail: String
    ) -> Draft {
        Draft(source: source, location: "line \(line)", sourceShortcut: shortcut,
              sourceAction: action, shortcut: nil, command: nil,
              disposition: .unsupported, detail: detail)
    }

    private static func invalidDraft(
        _ source: CMDYKeybindingImportSource, _ line: Int, _ shortcut: String,
        _ action: String, _ detail: String
    ) -> Draft {
        Draft(source: source, location: "line \(line)", sourceShortcut: shortcut,
              sourceAction: action, shortcut: nil, command: nil,
              disposition: .malformed, detail: detail)
    }

    private enum TranslationError: LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            guard case .unsupported(let message) = self else { return nil }
            return message
        }
    }
}

public final class CMDYKeybindingStore: @unchecked Sendable {
    public struct ApplyResult: Sendable {
        public let applied: [CMDYKeybindingMapping]
        public let skipped: [CMDYKeybindingImportCandidate]
    }

    private struct Document: Codable {
        var version = 1
        var mappings: [CMDYKeybindingMapping] = []
        var history: [[CMDYKeybindingMapping]] = []
    }

    public static var defaultURL: URL {
        ConfigFile.directory.appendingPathComponent("keybindings.json")
    }

    public let url: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private let maximumStoreBytes = 4 * 1024 * 1024
    private let maximumHistory = 20

    public init(url: URL = CMDYKeybindingStore.defaultURL,
                fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public func preview(
        fileURL: URL,
        source: CMDYKeybindingImportSource,
        reserved: Set<CMDYKeybindingShortcut> = CMDYKeybindingCatalog.nativeShortcuts
    ) throws -> CMDYKeybindingImportPreview {
        try CMDYKeybindingImporter.preview(
            fileURL: fileURL, source: source, existing: list(), reserved: reserved)
    }

    public func list() throws -> [CMDYKeybindingMapping] {
        lock.lock(); defer { lock.unlock() }
        return try loadUnlocked().mappings.sorted { $0.shortcut.descriptor < $1.shortcut.descriptor }
    }

    /// Applies only explicitly selected, conflict-free preview rows. Selection
    /// defaults to every `ready` row. Conflicts are rechecked against the live
    /// store so a stale preview can never overwrite a newer mapping.
    public func apply(
        _ preview: CMDYKeybindingImportPreview,
        selectedCandidateIDs: Set<Int>? = nil
    ) throws -> ApplyResult {
        lock.lock(); defer { lock.unlock() }
        var document = try loadUnlocked()
        var occupied = Set(document.mappings.map(\.shortcut))
        let selected = selectedCandidateIDs
            ?? Set(preview.candidates.lazy.filter(\.canApply).map(\.id))
        var applied: [CMDYKeybindingMapping] = []
        var skipped: [CMDYKeybindingImportCandidate] = []
        for candidate in preview.candidates where selected.contains(candidate.id) {
            guard candidate.canApply,
                  let shortcut = candidate.shortcut,
                  let command = candidate.command,
                  !CMDYKeybindingCatalog.nativeShortcuts.contains(shortcut),
                  !occupied.contains(shortcut) else {
                skipped.append(candidate)
                continue
            }
            let mapping = CMDYKeybindingMapping(
                shortcut: shortcut, command: command, source: preview.source,
                sourceAction: candidate.sourceAction)
            document.mappings.append(mapping)
            occupied.insert(shortcut)
            applied.append(mapping)
        }
        guard !applied.isEmpty else { return ApplyResult(applied: [], skipped: skipped) }
        document.history.append(Array(document.mappings.dropLast(applied.count)))
        if document.history.count > maximumHistory {
            document.history.removeFirst(document.history.count - maximumHistory)
        }
        try saveUnlocked(document)
        return ApplyResult(applied: applied, skipped: skipped)
    }

    @discardableResult
    public func undo() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        var document = try loadUnlocked()
        guard let previous = document.history.popLast() else { return false }
        document.mappings = previous
        try saveUnlocked(document)
        return true
    }

    /// Clears imported mappings, retaining the previous state as one undo step.
    @discardableResult
    public func reset() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        var document = try loadUnlocked()
        guard !document.mappings.isEmpty else { return false }
        document.history.append(document.mappings)
        if document.history.count > maximumHistory {
            document.history.removeFirst(document.history.count - maximumHistory)
        }
        document.mappings = []
        try saveUnlocked(document)
        return true
    }

    private func loadUnlocked() throws -> Document {
        guard fileManager.fileExists(atPath: url.path) else { return Document() }
        let data: Data
        do { data = try BoundedFileReader.data(at: url, maxBytes: maximumStoreBytes) }
        catch { throw CMDYKeybindingImportError.corruptStore(error.localizedDescription) }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(Document.self, from: data)
            guard document.version == 1,
                  document.mappings.count <= CMDYKeybindingImporter.maximumMappings,
                  document.history.count <= maximumHistory else {
                throw CMDYKeybindingImportError.corruptStore("unsupported or oversized document")
            }
            let shortcuts = document.mappings.map(\.shortcut)
            guard Set(shortcuts).count == shortcuts.count else {
                throw CMDYKeybindingImportError.corruptStore("duplicate shortcuts")
            }
            return document
        } catch let error as CMDYKeybindingImportError { throw error }
        catch { throw CMDYKeybindingImportError.corruptStore(error.localizedDescription) }
    }

    private func saveUnlocked(_ document: Document) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        guard data.count <= maximumStoreBytes else { throw CMDYKeybindingImportError.storeTooLarge }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
