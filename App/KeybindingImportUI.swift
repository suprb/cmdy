import AppKit
import CmdyKit

extension AppDelegate {
    @objc func importKeybindings(_ sender: Any?) {
        let represented = (sender as? NSMenuItem)?.representedObject as? String
        let source = represented.flatMap(CMDYKeybindingImportSource.init(rawValue:))
        guard let source else { NSSound.beep(); return }
        importKeybindings(from: source)
    }

    func importKeybindings(from source: CMDYKeybindingImportSource) {
        let panel = NSOpenPanel()
        panel.title = "Import \(source.displayName) Keybindings"
        panel.message = "cmdy will preview every translation and will not replace native or existing shortcuts."
        panel.prompt = "Preview"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let suggested = suggestedKeybindingURL(for: source) {
            panel.directoryURL = suggested.deletingLastPathComponent()
            panel.nameFieldStringValue = suggested.lastPathComponent
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let store = CMDYKeybindingStore()
            let preview = try store.preview(fileURL: url, source: source)
            guard presentKeybindingPreview(preview) else { return }
            let result = try store.apply(preview)
            reloadImportedKeybindings()
            let alert = NSAlert()
            alert.messageText = result.applied.isEmpty
                ? "No Keybindings Imported" : "Keybindings Imported"
            alert.informativeText = result.applied.isEmpty
                ? "Every mapping was unsupported or conflicted with a native or existing shortcut."
                : "Imported \(result.applied.count) shortcut\(result.applied.count == 1 ? "" : "s") from \(source.displayName)."
            alert.addButton(withTitle: "Done")
            alert.runModal()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func undoKeybindingImport(_ sender: Any?) {
        do {
            guard try CMDYKeybindingStore().undo() else {
                let alert = NSAlert()
                alert.messageText = "Nothing to Undo"
                alert.informativeText = "There is no earlier imported-keybinding state."
                alert.runModal()
                return
            }
            reloadImportedKeybindings()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func resetImportedKeybindings(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset Imported Keybindings?"
        alert.informativeText = "Native cmdy shortcuts are unchanged. You can undo this reset once from the Keybindings menu."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            _ = try CMDYKeybindingStore().reset()
            reloadImportedKeybindings()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func keybindingImportPaletteSection() -> PaletteItem {
        let imports = CMDYKeybindingImportSource.allCases.map { source in
            PaletteItem(
                title: "Import from \(source.displayName)…",
                subtitle: "preview translations and conflicts") { [weak self] in
                    self?.importKeybindings(from: source)
                }
        }
        return .section("Keybindings", "import · preview · undo", imports + [
            PaletteItem(title: "Undo Last Keybinding Import") { [weak self] in
                self?.undoKeybindingImport(nil)
            },
            PaletteItem(title: "Reset Imported Keybindings…") { [weak self] in
                self?.resetImportedKeybindings(nil)
            },
        ])
    }

    private func suggestedKeybindingURL(
        for source: CMDYKeybindingImportSource
    ) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let relative: String
        switch source {
        case .ghostty: relative = ".config/ghostty/config"
        case .tmux: relative = ".tmux.conf"
        case .iTerm2: relative = "Library/Preferences/com.googlecode.iterm2.plist"
        case .macOSTerminal: relative = "Library/Preferences/com.apple.Terminal.plist"
        }
        let url = home.appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func presentKeybindingPreview(
        _ preview: CMDYKeybindingImportPreview
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Import \(preview.source.displayName) Keybindings?"
        alert.informativeText = "\(preview.readyCount) ready · \(preview.conflictCount) conflicts · \(preview.unsupportedCount) unsupported. Only ready rows will be applied."

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 380))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = preview.candidates.map { candidate in
            let marker: String
            switch candidate.disposition {
            case .ready: marker = "✓ READY"
            case .nativeConflict: marker = "◆ NATIVE"
            case .existingConflict: marker = "◆ EXISTS"
            case .importConflict: marker = "◆ CONFLICT"
            case .unsupported: marker = "— UNSUPPORTED"
            case .malformed: marker = "✕ MALFORMED"
            }
            let target = candidate.shortcut.map { shortcut in
                let command = candidate.command?.displayName ?? ""
                return "\(shortcut.display)  →  \(command)"
            } ?? "\(candidate.sourceShortcut)  →  \(candidate.sourceAction)"
            return "\(marker)\n  \(target)\n  \(candidate.detail)\n"
        }.joined(separator: "\n")

        let scroll = NSScrollView(frame: textView.frame)
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        alert.accessoryView = scroll
        alert.addButton(withTitle: preview.readyCount > 0
            ? "Import \(preview.readyCount)" : "Done")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        return preview.readyCount > 0 && response == .alertFirstButtonReturn
    }
}
