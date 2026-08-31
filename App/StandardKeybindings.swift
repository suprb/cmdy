import AppKit
import CmdyKit

/// Ghostty-compatible macOS defaults that are not already native menu key
/// equivalents. This remains an additive compatibility layer: performable
/// actions return the event to the PTY when Cmdy has nothing to act on.
final class StandardKeybindings {
    enum Action {
        case openConfig, reloadConfig
        case copy, cut, paste, selectAll, pasteSelection
        case increaseFont, decreaseFont, resetFont
        case writeScreen(TerminalWindowController.ScreenFileAction)
        case adjustSelection(TerminalSelectionAdjustment)
        case previousTab, nextTab, tab(Int), lastTab
        case fullscreen, splitZoom, palette
        case quit, clear, undo, redo
        case scrollTop, scrollBottom, pageUp, pageDown, scrollSelection
        case previousPrompt, nextPrompt
        case newWindow, newTab, closeSurface, closeTab, closeWindow, closeAllWindows
        case splitRight, splitDown, previousSplit, nextSplit
        case focus(TerminalWindowController.PaneDirection)
        case resize(TerminalWindowController.PaneDirection), equalize
        case startSearch, searchSelection, endSearch, searchNext, searchPrevious
        case inspector
        case send(String)
    }

    private weak var delegate: AppDelegate?
    private var monitor: Any?
    private var importedMappings:
        [CMDYKeybindingShortcut: CMDYKeybindingCommand] = [:]

    init(delegate: AppDelegate) {
        self.delegate = delegate
        reloadImportedMappings()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self?.handle(event) == true else { return event }
            return nil
        }
    }

    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        if let command = Self.importedCommand(
            for: event, mappings: importedMappings),
           let action = Self.action(for: command) {
            return perform(action, event: event)
        }
        guard let action = Self.resolve(event) else { return false }
        return perform(action, event: event)
    }

    func reloadImportedMappings() {
        do {
            importedMappings = Dictionary(
                uniqueKeysWithValues: try CMDYKeybindingStore().list().map {
                    ($0.shortcut, $0.command)
                })
        } catch {
            importedMappings = [:]
            NSLog("cmdy: imported keybindings unavailable: %@",
                  error.localizedDescription)
        }
    }

    func invalidate() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func resolve(_ event: NSEvent) -> Action? {
        resolve(keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers ?? "",
                modifiers: event.modifierFlags)
    }

    private static func importShortcut(
        _ event: NSEvent
    ) -> CMDYKeybindingShortcut? {
        let special: [UInt16: String] = [
            36: "enter", 76: "enter", 53: "escape", 48: "tab",
            51: "backspace", 117: "delete", 49: "space",
            123: "left", 124: "right", 125: "down", 126: "up",
            115: "home", 119: "end", 116: "page_up", 121: "page_down",
            114: "insert",
            122: "f1", 120: "f2", 99: "f3", 118: "f4",
            96: "f5", 97: "f6", 98: "f7", 100: "f8",
            101: "f9", 109: "f10", 103: "f11", 111: "f12",
            105: "f13", 107: "f14", 113: "f15", 106: "f16",
            64: "f17", 79: "f18", 80: "f19", 90: "f20",
        ]
        let key = special[event.keyCode]
            ?? event.charactersIgnoringModifiers?.lowercased()
        guard let key, !key.isEmpty else { return nil }
        let flags = event.modifierFlags
        var modifiers = Set<CMDYKeybindingModifier>()
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return try? CMDYKeybindingShortcut(key: key, modifiers: modifiers)
    }

    static func importedCommand(
        for event: NSEvent,
        mappings: [CMDYKeybindingShortcut: CMDYKeybindingCommand]
    ) -> CMDYKeybindingCommand? {
        importShortcut(event).flatMap { mappings[$0] }
    }

    private static func action(
        for command: CMDYKeybindingCommand
    ) -> Action? {
        switch command {
        case .sendText(let text): return .send(text)
        case .action(let value):
            switch value {
            case .openConfig: return .openConfig
            case .reloadConfig: return .reloadConfig
            case .copy: return .copy
            case .cut: return .cut
            case .paste: return .paste
            case .pasteSelection: return .pasteSelection
            case .selectAll: return .selectAll
            case .increaseFont: return .increaseFont
            case .decreaseFont: return .decreaseFont
            case .resetFont: return .resetFont
            case .previousTab: return .previousTab
            case .nextTab: return .nextTab
            case .tab1: return .tab(0)
            case .tab2: return .tab(1)
            case .tab3: return .tab(2)
            case .tab4: return .tab(3)
            case .tab5: return .tab(4)
            case .tab6: return .tab(5)
            case .tab7: return .tab(6)
            case .tab8: return .tab(7)
            case .lastTab: return .lastTab
            case .fullscreen: return .fullscreen
            case .splitZoom: return .splitZoom
            case .commandPalette: return .palette
            case .quit: return .quit
            case .clear: return .clear
            case .undo: return .undo
            case .redo: return .redo
            case .scrollTop: return .scrollTop
            case .scrollBottom: return .scrollBottom
            case .pageUp: return .pageUp
            case .pageDown: return .pageDown
            case .scrollSelection: return .scrollSelection
            case .previousPrompt: return .previousPrompt
            case .nextPrompt: return .nextPrompt
            case .newWindow: return .newWindow
            case .newTab: return .newTab
            case .closeSurface: return .closeSurface
            case .closeTab: return .closeTab
            case .closeWindow: return .closeWindow
            case .closeAllWindows: return .closeAllWindows
            case .splitRight: return .splitRight
            case .splitDown: return .splitDown
            case .previousSplit: return .previousSplit
            case .nextSplit: return .nextSplit
            case .focusLeft: return .focus(.left)
            case .focusRight: return .focus(.right)
            case .focusUp: return .focus(.up)
            case .focusDown: return .focus(.down)
            case .resizeLeft: return .resize(.left)
            case .resizeRight: return .resize(.right)
            case .resizeUp: return .resize(.up)
            case .resizeDown: return .resize(.down)
            case .equalizeSplits: return .equalize
            case .startSearch: return .startSearch
            case .searchSelection: return .searchSelection
            case .endSearch: return .endSearch
            case .searchNext: return .searchNext
            case .searchPrevious: return .searchPrevious
            case .inspector: return .inspector
            case .writeScreenCopy: return .writeScreen(.copy)
            case .writeScreenPaste: return .writeScreen(.paste)
            case .writeScreenOpen: return .writeScreen(.open)
            }
        }
    }

    static func resolve(keyCode: UInt16, characters: String,
                        modifiers: NSEvent.ModifierFlags) -> Action? {
        let m = modifiers.intersection([.command, .option, .control, .shift])
        let c = characters.lowercased()

        // Physical keys are layout-independent.
        switch (keyCode, m) {
        case (53, []): return .endSearch
        case (48, [.control, .shift]): return .previousTab
        case (48, [.control]): return .nextTab
        case (36, [.command]), (76, [.command]): return .fullscreen
        case (36, [.command, .shift]), (76, [.command, .shift]): return .splitZoom
        case (18, [.command]): return .tab(0)
        case (19, [.command]): return .tab(1)
        case (20, [.command]): return .tab(2)
        case (21, [.command]): return .tab(3)
        case (23, [.command]): return .tab(4)
        case (22, [.command]): return .tab(5)
        case (26, [.command]): return .tab(6)
        case (28, [.command]): return .tab(7)
        case (25, [.command]): return .lastTab
        case (115, [.command]): return .scrollTop
        case (119, [.command]): return .scrollBottom
        case (116, [.command]): return .pageUp
        case (121, [.command]): return .pageDown
        case (126, [.command]), (126, [.command, .shift]): return .previousPrompt
        case (125, [.command]), (125, [.command, .shift]): return .nextPrompt
        case (126, [.command, .option]): return .focus(.up)
        case (125, [.command, .option]): return .focus(.down)
        case (123, [.command, .option]): return .focus(.left)
        case (124, [.command, .option]): return .focus(.right)
        case (126, [.command, .control]): return .resize(.up)
        case (125, [.command, .control]): return .resize(.down)
        case (123, [.command, .control]): return .resize(.left)
        case (124, [.command, .control]): return .resize(.right)
        case (123, [.command]): return .send("\u{01}")
        case (124, [.command]): return .send("\u{05}")
        case (51, [.command]): return .send("\u{15}")
        case (51, [.option]): return .send("\u{1b}\u{7f}")
        case (123, [.option]): return .send("\u{1b}b")
        case (124, [.option]): return .send("\u{1b}f")
        case (123, [.shift]): return .adjustSelection(.left)
        case (124, [.shift]): return .adjustSelection(.right)
        case (126, [.shift]): return .adjustSelection(.up)
        case (125, [.shift]): return .adjustSelection(.down)
        case (116, [.shift]): return .adjustSelection(.pageUp)
        case (121, [.shift]): return .adjustSelection(.pageDown)
        case (115, [.shift]): return .adjustSelection(.home)
        case (119, [.shift]): return .adjustSelection(.end)
        default: break
        }

        // Dedicated Copy/Paste function keys (rare, but part of the defaults).
        if m.isEmpty, let scalar = c.unicodeScalars.first {
            if scalar.value == 0xF72F { return .copy }
            if scalar.value == 0xF730 { return .paste }
        }

        switch (c, m) {
        case (",", [.command]): return .openConfig
        case (",", [.command, .shift]): return .reloadConfig
        case ("c", [.command]): return .copy
        case ("x", [.command]): return .cut
        case ("v", [.command]): return .paste
        case ("v", [.command, .shift]): return .pasteSelection
        case ("=", [.command]), ("+", [.command]): return .increaseFont
        case ("-", [.command]): return .decreaseFont
        case ("0", [.command]): return .resetFont
        case ("j", [.command, .control, .shift]): return .writeScreen(.copy)
        case ("j", [.command, .option, .shift]): return .writeScreen(.open)
        case ("j", [.command, .shift]): return .writeScreen(.paste)
        case ("j", [.command]): return .scrollSelection
        case ("p", [.command, .shift]): return .palette
        case ("q", [.command]): return .quit
        case ("k", [.command]): return .clear
        case ("a", [.command]): return .selectAll
        case ("t", [.command, .shift]), ("z", [.command]): return .undo
        case ("z", [.command, .shift]): return .redo
        case ("n", [.command]): return .newWindow
        case ("t", [.command]): return .newTab
        case ("w", [.command]): return .closeSurface
        case ("w", [.command, .option]): return .closeTab
        case ("w", [.command, .shift]): return .closeWindow
        case ("w", [.command, .option, .shift]): return .closeAllWindows
        case ("[", [.command, .shift]): return .previousTab
        case ("]", [.command, .shift]): return .nextTab
        case ("d", [.command]): return .splitRight
        case ("d", [.command, .shift]): return .splitDown
        case ("[", [.command]): return .previousSplit
        case ("]", [.command]): return .nextSplit
        case ("=", [.command, .control]): return .equalize
        case ("f", [.command]): return .startSearch
        case ("e", [.command]): return .searchSelection
        case ("f", [.command, .shift]): return .endSearch
        case ("g", [.command]): return .searchNext
        case ("g", [.command, .shift]): return .searchPrevious
        case ("i", [.command, .option]): return .inspector
        case ("f", [.command, .control]): return .fullscreen
        default:
            if m == [.command], let digit = Int(c), (1...8).contains(digit) { return .tab(digit - 1) }
            if c == "9", m == [.command] { return .lastTab }
            return nil
        }
    }

    private func perform(_ action: Action, event: NSEvent) -> Bool {
        guard let delegate else { return false }
        let eventController = event.window?.windowController as? TerminalWindowController
        let controller = eventController
            ?? delegate.currentController

        // A text document is a first-class surface. Consume normal editing
        // commands here so the fallback terminal controller can never receive
        // them while an editor window or attached editor owns the keyboard.
        if let editor = CmdyEditorManager.shared.editor(in: event.window) {
            switch action {
            case .copy: editor.textView.copy(nil)
            case .cut: editor.textView.cut(nil)
            case .paste, .pasteSelection: editor.textView.paste(nil)
            case .selectAll: editor.textView.selectAll(nil)
            case .undo:
                if let manager = editor.textView.undoManager, manager.canUndo { manager.undo() }
            case .redo:
                if let manager = editor.textView.undoManager, manager.canRedo { manager.redo() }
            case .startSearch: editor.showFind()
            case .searchNext: editor.performFindAction(.nextMatch)
            case .searchPrevious: editor.performFindAction(.previousMatch)
            case .searchSelection: editor.performFindAction(.setSearchString)
            case .closeSurface: CmdyEditorManager.shared.requestClose(editor)
            default: return false
            }
            return true
        }

        // Terminal search remains navigable while its field owns first responder.
        switch action {
        case .endSearch:
            guard let eventController, eventController.isFindVisible else { return false }
            eventController.hideFindBar(); return true
        case .searchNext: return eventController?.stepFind(forward: true) ?? false
        case .searchPrevious: return eventController?.stepFind(forward: false) ?? false
        default: break
        }

        guard let controller, let pane = controller.focusedPane, pane.isTerminalFocused else {
            return false
        }
        switch action {
        case .openConfig: delegate.openConfig(nil)
        case .reloadConfig: delegate.reloadConfig(nil)
        case .copy:
            let text = pane.surface.selectedText()
            guard !text.isEmpty else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .cut: return false
        case .paste:
            return pane.surface.view.tryToPerform(#selector(NSText.paste(_:)), with: nil)
        case .selectAll: pane.surface.selectAllContent()
        case .pasteSelection:
            let text = pane.surface.selectedText()
            guard !text.isEmpty else { return false }
            pane.surface.send(txt: text)
        case .increaseFont: delegate.increaseFontSize(nil)
        case .decreaseFont: delegate.decreaseFontSize(nil)
        case .resetFont: delegate.resetFontSize(nil)
        case .writeScreen(let operation): return controller.writeScreenFile(operation)
        case .adjustSelection(let adjustment): return pane.surface.adjustSelection(adjustment)
        case .previousTab: return controller.selectTab(offset: -1)
        case .nextTab: return controller.selectTab(offset: 1)
        case .tab(let index): return controller.selectTab(index: index)
        case .lastTab:
            guard let count = controller.window?.tabGroup?.windows.count, count > 0 else { return false }
            return controller.selectTab(index: count - 1)
        case .fullscreen:
            guard !pane.isCommandAssistanceVisible else { return false }
            controller.window?.toggleFullScreen(nil)
        case .splitZoom: controller.toggleSplitZoom()
        case .palette: delegate.showPalette(nil)
        case .quit: NSApp.terminate(nil)
        case .clear: controller.clearBuffer()
        case .undo:
            if let manager = controller.window?.undoManager, manager.canUndo { manager.undo() }
            else { return delegate.undoClose() }
        case .redo:
            if let manager = controller.window?.undoManager, manager.canRedo { manager.redo() }
            else { return delegate.redoClose() }
        case .scrollTop: pane.surface.scrollTo(row: 0)
        case .scrollBottom: pane.surface.scrollTo(row: pane.surface.engine.liveScreenTopRow)
        case .pageUp: pane.surface.scrollUp(lines: max(1, pane.surface.engine.rows - 1))
        case .pageDown: pane.surface.scrollDown(lines: max(1, pane.surface.engine.rows - 1))
        case .scrollSelection: return pane.surface.scrollSelectionIntoView()
        case .previousPrompt: controller.jumpToPreviousPrompt()
        case .nextPrompt: controller.jumpToNextPrompt()
        case .newWindow: delegate.newWindow(nil)
        case .newTab: delegate.newTab(nil)
        case .closeSurface: controller.closePaneOrWindow()
        case .closeTab: controller.window?.performClose(nil)
        case .closeWindow: controller.closeTabGroup()
        case .closeAllWindows: delegate.closeAllTerminalWindows()
        case .splitRight: controller.splitFocusedPane(vertical: true)
        case .splitDown: controller.splitFocusedPane(vertical: false)
        case .previousSplit: controller.focusNextPane(offset: -1)
        case .nextSplit: controller.focusNextPane(offset: 1)
        case .focus(let direction): return controller.focusPane(direction: direction)
        case .resize(let direction): return controller.resizeSplit(direction: direction)
        case .equalize: controller.equalizeSplits()
        case .startSearch: controller.showFindBar()
        case .searchSelection:
            let term = pane.surface.selectedText().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return false }
            controller.showFindBar(term: term)
        case .inspector: controller.showInspector()
        case .send(let text): pane.surface.send(txt: text)
        case .endSearch, .searchNext, .searchPrevious: return false
        }
        return true
    }
}
