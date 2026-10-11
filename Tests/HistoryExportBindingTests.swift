import AppKit
import CmdyKit

// Only these enum types surround the exact production Action declaration.
// No window, view, event monitor, application, or clipboard is instantiated.
enum TerminalWindowController {
    enum ScreenFileAction { case copy, paste, open }
    enum PaneDirection { case left, right, up, down }
}

// PRODUCTION_IMPORTED_DISPATCH

@main
enum HistoryExportBindingTests {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let storeURL = directory.appendingPathComponent("keybindings.json")
        guard ProcessInfo.processInfo.environment["CMDY_CONFIG_DIR"] == directory.path,
              CMDYKeybindingStore.defaultURL == storeURL else {
            fatalError("The default public store must select only the generated config directory")
        }
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            checks += 1; precondition(value(), label)
        }
        func event(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ text: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 1, windowNumber: 0, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        }
        let exportCase = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
        let policy = exportCase == nil ? nil : "post-sample-public-history-v1"
        let intended = HistoryExportKey.action(verificationPolicy: policy, exportCase: exportCase)!
        let screen = exportCase == "alternate-continuous"
        let expectedCommand: CMDYKeybindingCommand = .action(screen ? .writeScreenPaste : .writeScrollbackPaste)
        expect(HistoryExportKey.action(verificationPolicy: "unknown", exportCase: exportCase) == nil, "Unknown policy accepted")
        expect(HistoryExportKey.action(verificationPolicy: "post-sample-public-history-v1", exportCase: "resize") == nil, "Resize borrowed phase")
        expect(HistoryExportKey.action(verificationPolicy: nil, exportCase: "alternate-continuous") == nil, "Case borrowed legacy policy")
        func isExport(_ action: StandardKeybindings.Action?) -> Bool {
            if screen, case .writeScreen(.paste)? = action { return true }
            if !screen, case .writeScrollbackPaste? = action { return true }
            return false
        }
        let original = try Data(contentsOf: storeURL)
        let store = CMDYKeybindingStore()
        let mappings = try store.list()
        expect(mappings.count == 1, "Generated public document must decode exactly one mapping")
        let mapping = mappings[0]
        expect(mapping.shortcut.descriptor == HistoryExportKey.shortcut, "Public descriptor differs")
        expect(mapping.shortcut.key == "enter" && mapping.shortcut.modifiers == [.control, .shift], "Public key/modifiers differ")
        expect(mapping.command == expectedCommand, "Public store command differs")
        expect(mapping.source == .ghostty && mapping.sourceAction == intended, "Public import provenance differs")
        expect(HistoryExportKey.code == 36 && HistoryExportKey.flags.rawValue == 0x60000, "Native helper event recipe differs")
        let flags = NSEvent.ModifierFlags(rawValue: UInt(HistoryExportKey.flags.rawValue))
        let key = event(HistoryExportKey.code, flags, "\r")
        expect(key.keyCode == 36 && key.modifierFlags == [.control, .shift], "Synthetic event differs from posted recipe")
        let dispatcher = StandardKeybindings()
        dispatcher.reloadImportedMappings()
        expect(isExport(dispatcher.fixtureAction(key)), "Actual imported dispatcher failed to select export")
        expect(isExport(dispatcher.fixtureAction(event(36, flags, "@"))), "Enter must resolve by physical key, not shifted text")
        for wrong in [event(19, flags, "@"), event(36, .control, "\r"),
                      event(36, .shift, "\r"), event(36, [.command, .shift], "\r")] {
            expect(dispatcher.fixtureAction(wrong) == nil, "Wrong key or modifiers selected export")
        }

        // Real public importer and store apply/read use the same Ghostty config
        // line that the other app receives. This is CMDY compatibility evidence;
        // Ghostty's native action still requires the separately owned pilot.
        let ghostty = directory.deletingLastPathComponent().appendingPathComponent("ghostty-config/config")
        let importedStore = CMDYKeybindingStore(url: directory.appendingPathComponent("imported.json"))
        let preview = try importedStore.preview(fileURL: ghostty, source: .ghostty)
        expect(preview.readyCount == 1 && preview.conflictCount == 0, "Exact public Ghostty line did not import")
        let applied = try importedStore.apply(preview)
        expect(applied.applied.count == 1 && applied.skipped.isEmpty, "Normal public apply rejected binding")
        let decoded = try importedStore.list()
        expect(decoded.count == 1 && decoded[0].shortcut == mapping.shortcut
            && decoded[0].command == mapping.command, "Normal imported store differs from generated document")

        let shiftedTwo = try CMDYKeybindingImporter.parseShortcutDescriptor("ctrl+shift+2")
        let oldMapping: [CMDYKeybindingShortcut: CMDYKeybindingCommand] = [shiftedTwo: .action(.writeScrollbackPaste)]
        expect(StandardKeybindings.importedCommand(for: event(19, flags, "@"), mappings: oldMapping) == nil,
               "Shifted @ must not falsely resolve an imported unshifted 2")
        expect(StandardKeybindings.importedCommand(for: event(19, flags, "2"), mappings: oldMapping) == .action(.writeScrollbackPaste),
               "The old shortcut depends on actual charactersIgnoringModifiers")

        // Missing store + a Ghostty keybind line reproduces the original setup
        // failure. It creates no export and does not retain or guess PTY input.
        try FileManager.default.removeItem(at: storeURL)
        try Data("keybind = ctrl+shift+2=write_scrollback_file:paste\n".utf8)
            .write(to: directory.appendingPathComponent("config"))
        let absent = try store.list()
        expect(absent.isEmpty, "Missing store unexpectedly imported preferences config")
        dispatcher.reloadImportedMappings()
        expect(dispatcher.fixtureAction(key) == nil, "Absent store must not select export")
        try original.write(to: storeURL)
        dispatcher.reloadImportedMappings()
        expect(isExport(dispatcher.fixtureAction(key)), "Restored public store did not reload")

        var document = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        var records = document["mappings"] as! [[String: Any]]
        records[0]["command"] = ["type": "action", "value": "copy"]
        document["mappings"] = records
        try JSONSerialization.data(withJSONObject: document).write(to: storeURL)
        dispatcher.reloadImportedMappings()
        expect(!isExport(dispatcher.fixtureAction(key)), "A different public action was mistaken for export")
        if case .copy? = dispatcher.fixtureAction(key) { checks += 1 }
        else { fatalError("Production action selection did not preserve the different command") }
        try original.write(to: storeURL)
        print("History imported binding: \(checks) checks passed; no app, window, event posting or clipboard")
    }
}
