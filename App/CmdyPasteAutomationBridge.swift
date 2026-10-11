import AppKit

extension TerminalPane: CmdyScriptPasteTarget {
    var scriptTerminalID: String { paneId }
    var scriptTerminalName: String { window?.title ?? "Terminal" }

    func scriptPasteText(_ text: String) -> Bool {
        guard surface.shellPid > 0, let terminal = surface as? CmdyTerminalSurface else { return false }
        return terminal.pasteText(text)
    }
}

extension NSApplication {
    /// Cocoa Scripting evaluates only existing panes; it cannot create or
    /// activate a window as a side effect of an input command.
    @objc var cmdyScriptTerminals: [CmdyScriptTerminal] {
        guard let owner = delegate as? AppDelegate else { return [] }
        return owner.allControllers.flatMap(\.panes).map { pane in
            CmdyScriptTerminal(id: pane.paneId, name: pane.scriptTerminalName) { [weak owner] id in
                owner?.allControllers.lazy.flatMap(\.panes).first { $0.paneId == id }
            }
        }
    }

    @objc(valueInCmdyScriptTerminalsWithUniqueID:)
    func cmdyScriptTerminal(withUniqueID id: String) -> CmdyScriptTerminal? {
        cmdyScriptTerminals.first { $0.id == id }
    }
}
