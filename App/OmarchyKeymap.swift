import AppKit

/// Omarchy's tmux/herdr keys (basecamp/omarchy config/tmux/tmux.conf and
/// config/herdr/config.toml). A tmux pane is a split, a tmux window is a tab,
/// and a tmux session is a window. Ctrl+Space is the prefix.
enum OmarchyKeymap {
    typealias Action = StandardKeybindings.Action

    static let prefixKeyCode: UInt16 = 49 // Space

    static func isPrefix(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == prefixKeyCode
            && modifiers.intersection([.command, .option, .control, .shift]) == [.control]
    }

    private static let digitKeyCodes: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]

    private static func direction(_ keyCode: UInt16) -> TerminalWindowController.PaneDirection? {
        switch keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: return nil
        }
    }

    /// Keys that act without the prefix (tmux `bind -n`). Omarchy holds Alt;
    /// with `usesCommand` (omarchy-modifier = command) ⌘ takes Alt's place,
    /// except ⌘←/⌘→, which keep moving to the start and end of the line.
    static func root(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                     usesCommand: Bool = false) -> Action? {
        let held = modifiers.intersection([.command, .option, .control, .shift])
        let alt: NSEvent.ModifierFlags = usesCommand ? .command : .option
        guard held.contains(alt),
              held.intersection([.command, .option]) == alt else { return nil }
        let m = held.subtracting(alt).union(.option)
        let isReturn = keyCode == 36 || keyCode == 76
        switch m {
        case [.option]:
            if isReturn { return .splitDown }
            if keyCode == 53 { return .closeSurface }
            if let digit = digitKeyCodes[keyCode] { return .tab(digit - 1) }
            switch direction(keyCode) {
            case .left: return usesCommand ? nil : .previousTab
            case .right: return usesCommand ? nil : .nextTab
            case .up: return .switchWindow(-1)
            case .down: return .switchWindow(1)
            case nil: return nil
            }
        case [.option, .shift]:
            if isReturn { return .splitRight }
            switch direction(keyCode) {
            case .left: return .moveTab(-1)
            case .right: return .moveTab(1)
            default: return nil
            }
        case [.control, .option]:
            return direction(keyCode).map { .focus($0) }
        case [.control, .option, .shift]:
            return direction(keyCode).map { .resizeCells($0, 5) }
        default:
            return nil
        }
    }

    /// Keys pressed after the prefix. `characters` keeps Shift, so "C" is
    /// Shift+C and "!" is Shift+1, as in tmux.
    static func afterPrefix(keyCode: UInt16, characters: String,
                            modifiers: NSEvent.ModifierFlags) -> Action? {
        let m = modifiers.intersection([.command, .option, .control, .shift])
        if isPrefix(keyCode: keyCode, modifiers: modifiers) { return .send("\u{0}") }
        if m == [.control], let direction = direction(keyCode) {
            return .resizeCells(direction, 5)
        }
        guard m.subtracting(.shift).isEmpty else { return nil }
        switch characters {
        case "h": return .splitDown
        case "v": return .splitRight
        case "x": return .closeSurface
        case "z": return .splitZoom
        case ";": return .lastPane
        case "!": return .breakPaneToTab
        case "@": return .joinTabLeft
        case "c": return .newTab
        case "r": return .renameTab
        case "k": return .closeTab
        case "p": return .previousTab
        case "n": return .nextTab
        case "C": return .newWindow
        case "K": return .closeWindow
        case "P": return .switchWindow(-1)
        case "N": return .switchWindow(1)
        case "q": return .reloadConfig
        case "?": return .keymapHelp
        default:
            if let digit = Int(characters), (1...9).contains(digit) { return .tab(digit - 1) }
            return nil
        }
    }

    static func helpRows(usesCommand: Bool) -> [(keys: String, action: String)] {
        let alt = usesCommand ? "Cmd" : "Alt"
        let tabs = usesCommand ? "prefix p / n" : "Alt+Left / Right  ·  prefix p / n"
        return [
        ("Ctrl+Space", "Prefix (press twice to send Ctrl+Space)"),
        ("\(alt)+Enter  ·  prefix h", "Split down"),
        ("\(alt)+Shift+Enter  ·  prefix v", "Split right"),
        ("\(alt)+Esc  ·  prefix x", "Close pane"),
        ("Ctrl+\(alt)+Arrows", "Focus pane"),
        ("Ctrl+\(alt)+Shift+Arrows  ·  prefix Ctrl+Arrows", "Resize pane"),
        ("prefix z", "Zoom pane"),
        ("prefix ;", "Last pane"),
        ("prefix !", "Break pane into a new tab"),
        ("prefix @", "Join tab into the tab on its left"),
        ("\(alt)+1…9  ·  prefix 1…9", "Go to tab"),
        (tabs, "Previous / next tab"),
        ("\(alt)+Shift+Left / Right", "Move tab left / right"),
        ("prefix c  ·  r  ·  k", "New / rename / close tab"),
        ("\(alt)+Up / Down  ·  prefix P / N", "Previous / next window"),
        ("prefix C  ·  K", "New / close window"),
        ("prefix q", "Reload configuration"),
        ("prefix ?", "Show these keys"),
        ]
    }
}
