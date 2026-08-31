import Foundation
import XCTest
@testable import CmdyKit

final class KeybindingImportTests: XCTestCase {
    private let noReservedShortcuts = Set<CMDYKeybindingShortcut>()

    func testGhosttyFixtureTranslatesActionsAndExplainsUnsupportedRows() throws {
        let fixture = """
        # ~/.config/ghostty/config
        keybind = ctrl+shift+n=new_window
        keybind = alt+h=goto_split:left
        keybind = ctrl+alt+b=text:\\x1b[1;5D
        keybind = ctrl+x>n=new_tab
        keybind = global:cmd+g=navigate_search:next
        keybind = ctrl+u=not_a_real_action
        """

        let preview = try preview(fixture, source: .ghostty)

        XCTAssertEqual(preview.candidates.count, 6)
        XCTAssertEqual(preview.readyCount, 3)
        XCTAssertEqual(preview.unsupportedCount, 3)
        assert(preview.candidates[0], shortcut: "ctrl+shift+n", command: .action(.newWindow))
        assert(preview.candidates[1], shortcut: "option+h", command: .action(.focusLeft))
        assert(preview.candidates[2], shortcut: "ctrl+option+b", command: .sendText("\u{1b}[1;5D"))
        XCTAssertEqual(preview.candidates[3].disposition, .unsupported)
        XCTAssertTrue(preview.candidates[3].detail.contains("sequences"))
        XCTAssertEqual(preview.candidates[4].disposition, .unsupported)
        XCTAssertTrue(preview.candidates[4].detail.contains("scope"))
        XCTAssertEqual(preview.candidates[5].disposition, .unsupported)
        XCTAssertTrue(preview.candidates[5].detail.contains("Unsupported Ghostty action"))
    }

    func testTmuxFixtureImportsOnlyRootTableBindings() throws {
        let fixture = """
        bind-key -n M-h select-pane -L
        bind -T root C-S-Right resize-pane -R 5
        bind-key -n M-\\\\ split-window -h
        bind c new-window
        bind-key -n F2 display-menu
        """

        let preview = try preview(fixture, source: .tmux)

        XCTAssertEqual(preview.candidates.count, 5)
        XCTAssertEqual(preview.readyCount, 3)
        assert(preview.candidates[0], shortcut: "option+h", command: .action(.focusLeft))
        assert(preview.candidates[1], shortcut: "ctrl+shift+right", command: .action(.resizeRight))
        assert(preview.candidates[2], shortcut: "option+\\", command: .action(.splitRight))
        XCTAssertEqual(preview.candidates[3].disposition, .unsupported)
        XCTAssertTrue(preview.candidates[3].detail.contains("prefix-table"))
        XCTAssertEqual(preview.candidates[4].disposition, .unsupported)
    }

    func testITermJSONFixtureTranslatesKeyMapActions() throws {
        let fixture: [String: Any] = [
            "Profiles": [[
                "Name": "Imported",
                "Keyboard Map": [
                    "0xf702-0x80000": ["Action": 18, "Text": ""],
                    "0x74-0x100000": ["Action": 27, "Text": ""],
                    "0x5b-0x40000": ["Action": 10, "Text": "A"],
                    "0x75-0x100000": ["Action": 999, "Text": ""],
                ],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: fixture)

        let preview = try CMDYKeybindingImporter.preview(
            data: data, source: .iTerm2, reserved: noReservedShortcuts)

        XCTAssertEqual(preview.candidates.count, 4)
        XCTAssertEqual(preview.readyCount, 3)
        let byShortcut = Dictionary(uniqueKeysWithValues: preview.candidates.compactMap {
            candidate in candidate.shortcut.map { ($0.descriptor, candidate) }
        })
        assert(try XCTUnwrap(byShortcut["option+left"]),
               shortcut: "option+left", command: .action(.focusLeft))
        assert(try XCTUnwrap(byShortcut["cmd+t"]),
               shortcut: "cmd+t", command: .action(.newTab))
        assert(try XCTUnwrap(byShortcut["ctrl+["]),
               shortcut: "ctrl+[", command: .sendText("\u{1b}A"))
        XCTAssertEqual(preview.unsupportedCount, 1)
    }

    func testITermPlistFixtureAndSessionNavigation() throws {
        let fixture: [String: Any] = [
            "Profiles": [[
                "Keyboard Map": [
                    "0x5d-0x80000": ["Action": 0, "Text": ""],
                    "0x5b-0x80000": ["Action": 2, "Text": ""],
                    "0x78-0x40000": ["Action": 11, "Text": "1b 5b 41"],
                ],
            ]],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: fixture, format: .xml, options: 0)

        let preview = try CMDYKeybindingImporter.preview(
            data: data, source: .iTerm2, reserved: noReservedShortcuts)

        let commands = Dictionary(uniqueKeysWithValues: preview.candidates.compactMap {
            candidate in candidate.shortcut.flatMap { shortcut in
                candidate.command.map { (shortcut.descriptor, $0) }
            }
        })
        XCTAssertEqual(commands["option+]"], .action(.nextTab))
        XCTAssertEqual(commands["option+["], .action(.previousTab))
        XCTAssertEqual(commands["ctrl+x"], .sendText("\u{1b}[A"))
    }

    func testTerminalProfileFixtureDecodesCocoaKeyDescriptors() throws {
        let fixture: [String: Any] = [
            "Window Settings": [
                "Pro": [
                    "keyMapBoundKeys": [
                        "~^F702": "\u{1b}b",
                        "$F704": "function",
                        "@0074": "tab",
                    ],
                ],
            ],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: fixture, format: .xml, options: 0)

        let preview = try CMDYKeybindingImporter.preview(
            data: data, source: .macOSTerminal, reserved: noReservedShortcuts)

        XCTAssertEqual(preview.readyCount, 3)
        let commands = Dictionary(uniqueKeysWithValues: preview.candidates.compactMap {
            candidate in candidate.shortcut.flatMap { shortcut in
                candidate.command.map { (shortcut.descriptor, $0) }
            }
        })
        XCTAssertEqual(commands["ctrl+option+left"], .sendText("\u{1b}b"))
        XCTAssertEqual(commands["shift+f1"], .sendText("function"))
        XCTAssertEqual(commands["cmd+t"], .sendText("tab"))
    }

    func testPreviewMarksNativeExistingAndImportCollisions() throws {
        let existingShortcut = try CMDYKeybindingImporter.parseShortcutDescriptor("ctrl+option+x")
        let existing = CMDYKeybindingMapping(
            shortcut: existingShortcut, command: .action(.newTab),
            source: .tmux, sourceAction: "new-window")
        let fixture = """
        keybind = cmd+n=new_window
        keybind = ctrl+option+x=new_tab
        keybind = ctrl+option+y=new_tab
        keybind = ctrl+option+y=close_tab
        keybind = a=new_tab
        """

        let preview = try CMDYKeybindingImporter.preview(
            data: Data(fixture.utf8), source: .ghostty, existing: [existing])

        XCTAssertEqual(preview.candidates.map(\.disposition), [
            .nativeConflict, .existingConflict, .importConflict, .importConflict, .unsupported,
        ])
        XCTAssertEqual(preview.readyCount, 0)
        XCTAssertEqual(preview.conflictCount, 4)
    }

    func testStoreNeverOverwritesAndRechecksStalePreviews() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CMDYKeybindingStore(url: directory.appendingPathComponent("keybindings.json"))
        let first = try preview("keybind = ctrl+option+x=new_tab", source: .ghostty)
        let stale = try preview("bind-key -n C-M-x kill-pane", source: .tmux)

        let firstResult = try store.apply(first)
        let staleResult = try store.apply(stale)

        XCTAssertEqual(firstResult.applied.count, 1)
        XCTAssertEqual(staleResult.applied.count, 0)
        XCTAssertEqual(staleResult.skipped.count, 1)
        XCTAssertEqual(try store.list().count, 1)
        XCTAssertEqual(try store.list().first?.command, .action(.newTab))
    }

    func testStoreListUndoAndResetRoundTrip() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/keybindings.json")
        let store = CMDYKeybindingStore(url: url)
        let first = try preview("keybind = ctrl+option+x=new_tab", source: .ghostty)
        let second = try preview("bind-key -n C-M-y kill-pane", source: .tmux)

        XCTAssertEqual(try store.apply(first).applied.count, 1)
        XCTAssertEqual(try store.apply(second).applied.count, 1)
        XCTAssertEqual(try store.list().map(\.shortcut.descriptor), [
            "ctrl+option+x", "ctrl+option+y",
        ])
        XCTAssertTrue(try store.undo())
        XCTAssertEqual(try store.list().map(\.shortcut.descriptor), ["ctrl+option+x"])
        XCTAssertTrue(try store.reset())
        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertTrue(try store.undo())
        XCTAssertEqual(try store.list().map(\.shortcut.descriptor), ["ctrl+option+x"])

        let persisted = try Data(contentsOf: url)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: persisted))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: url.deletingLastPathComponent().path),
            ["keybindings.json"])
    }

    func testStoreAppliesOnlyExplicitReadySelection() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CMDYKeybindingStore(url: directory.appendingPathComponent("keybindings.json"))
        let imported = try preview("""
            keybind = ctrl+option+x=new_tab
            keybind = ctrl+option+y=new_window
            """, source: .ghostty)

        let result = try store.apply(imported, selectedCandidateIDs: [1])

        XCTAssertEqual(result.applied.map(\.shortcut.descriptor), ["ctrl+option+y"])
        XCTAssertEqual(try store.list().map(\.shortcut.descriptor), ["ctrl+option+y"])
    }

    func testBoundedInputAndMalformedDocumentsFailClosed() throws {
        let tooLarge = Data(repeating: 0x61, count: CMDYKeybindingImporter.maximumSourceBytes + 1)
        XCTAssertThrowsError(try CMDYKeybindingImporter.preview(
            data: tooLarge, source: .ghostty, reserved: noReservedShortcuts))
        XCTAssertThrowsError(try CMDYKeybindingImporter.preview(
            data: Data([0xFF]), source: .ghostty, reserved: noReservedShortcuts))
        XCTAssertThrowsError(try CMDYKeybindingImporter.preview(
            data: Data("not a plist".utf8), source: .iTerm2,
            reserved: noReservedShortcuts))
    }

    func testPlusKeyDescriptorIsRepresentableAndReserved() throws {
        let shortcut = try CMDYKeybindingImporter.parseShortcutDescriptor("cmd++")
        XCTAssertEqual(shortcut.key, "+")
        XCTAssertEqual(shortcut.modifiers, [.command])
        XCTAssertTrue(CMDYKeybindingCatalog.nativeShortcuts.contains(shortcut))
    }

    private func preview(
        _ fixture: String, source: CMDYKeybindingImportSource
    ) throws -> CMDYKeybindingImportPreview {
        try CMDYKeybindingImporter.preview(
            data: Data(fixture.utf8), source: source, reserved: noReservedShortcuts)
    }

    private func assert(
        _ candidate: CMDYKeybindingImportCandidate,
        shortcut: String,
        command: CMDYKeybindingCommand,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(candidate.shortcut?.descriptor, shortcut, file: file, line: line)
        XCTAssertEqual(candidate.command, command, file: file, line: line)
        XCTAssertEqual(candidate.disposition, .ready, file: file, line: line)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-keybinding-import-tests-\(UUID().uuidString)")
    }
}
