import AppKit
import CmdyKit

/// tmux-style pane, tab and window keys. A tmux pane is a split, a tmux window
/// is a tab, and a tmux session is a window. Ctrl+Space is the prefix.
enum PaneKeys {
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

    /// Keys that act without the prefix (tmux `bind -n`). They hold Alt; with
    /// `usesCommand` (pane-key-modifier = command) ⌘ takes Alt's place,
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

/// The pane keys as native menu items, so the menu bar shows them. A typed key
/// is handled by StandardKeybindings before the menu sees it; choosing an item
/// runs the same action.
@MainActor
enum PaneKeyMenu {
    typealias Action = StandardKeybindings.Action

    private struct Entry {
        let title: String
        let action: Action
        let key: String
        let modifiers: NSEvent.ModifierFlags   // besides Alt (or ⌘)
        /// ⌘←/⌘→ keep moving to the start and end of the line.
        var unboundWithCommand = false
    }

    private static let left = String(UnicodeScalar(0xF702)!)
    private static let right = String(UnicodeScalar(0xF703)!)
    private static let up = String(UnicodeScalar(0xF700)!)
    private static let down = String(UnicodeScalar(0xF701)!)

    private static let paneEntries: [Entry] = [
        Entry(title: "Split Down", action: .splitDown, key: "\r", modifiers: []),
        Entry(title: "Split Right", action: .splitRight, key: "\r", modifiers: [.shift]),
        Entry(title: "Focus Pane Left", action: .focus(.left), key: left, modifiers: [.control]),
        Entry(title: "Focus Pane Right", action: .focus(.right), key: right, modifiers: [.control]),
        Entry(title: "Focus Pane Up", action: .focus(.up), key: up, modifiers: [.control]),
        Entry(title: "Focus Pane Down", action: .focus(.down), key: down, modifiers: [.control]),
        Entry(title: "Close Pane", action: .closeSurface, key: "\u{1b}", modifiers: []),
    ]

    private static let windowEntries: [Entry] = [
        Entry(title: "Previous Tab", action: .previousTab, key: left, modifiers: [],
              unboundWithCommand: true),
        Entry(title: "Next Tab", action: .nextTab, key: right, modifiers: [],
              unboundWithCommand: true),
        Entry(title: "Move Tab Left", action: .moveTab(-1), key: left, modifiers: [.shift]),
        Entry(title: "Move Tab Right", action: .moveTab(1), key: right, modifiers: [.shift]),
        Entry(title: "Previous Window", action: .switchWindow(-1), key: up, modifiers: []),
        Entry(title: "Next Window", action: .switchWindow(1), key: down, modifiers: []),
    ]

    private static var installed: [(item: NSMenuItem, entry: Entry)] = []

    /// Split items first, a separator, then focus and close.
    static func paneItems() -> [NSMenuItem] {
        var items = paneEntries.prefix(2).map(makeItem)
        items.append(.separator())
        items += paneEntries.dropFirst(2).map(makeItem)
        return items
    }

    static func windowItems() -> [NSMenuItem] {
        var items = windowEntries.map(makeItem)
        let help = NSMenuItem(title: "Pane, Tab and Window Keys",
                              action: #selector(AppDelegate.performPaneKey(_:)),
                              keyEquivalent: "")
        help.representedObject = Action.keymapHelp
        items.append(.separator())
        items.append(help)
        return items
    }

    private static func makeItem(_ entry: Entry) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title,
                              action: #selector(AppDelegate.performPaneKey(_:)),
                              keyEquivalent: "")
        item.representedObject = entry.action
        installed.append((item, entry))
        apply(entry, to: item, usesCommand: Preferences.shared.paneKeysUseCommand)
        return item
    }

    /// Follows pane-key-modifier.
    static func refresh(usesCommand: Bool = Preferences.shared.paneKeysUseCommand) {
        for (item, entry) in installed { apply(entry, to: item, usesCommand: usesCommand) }
        // With ⌘, ⌘↑/⌘↓ switch windows, so the prompt items give those keys up.
        let promptKeys: [Selector: String] = [
            #selector(AppDelegate.previousPrompt(_:)): up,
            #selector(AppDelegate.nextPrompt(_:)): down,
        ]
        func visit(_ menu: NSMenu) {
            for item in menu.items {
                if let action = item.action, let key = promptKeys[action] {
                    item.keyEquivalent = usesCommand ? "" : key
                    item.keyEquivalentModifierMask = usesCommand ? [] : [.command]
                }
                if let submenu = item.submenu { visit(submenu) }
            }
        }
        if let menu = NSApp.mainMenu { visit(menu) }
    }

    private static func apply(_ entry: Entry, to item: NSMenuItem, usesCommand: Bool) {
        if usesCommand && entry.unboundWithCommand {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = entry.key
        item.keyEquivalentModifierMask = entry.modifiers.union(usesCommand ? .command : .option)
    }
}
