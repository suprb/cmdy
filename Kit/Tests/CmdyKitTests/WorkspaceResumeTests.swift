import Foundation
import XCTest
@testable import CmdyKit

final class WorkspaceResumeTests: XCTestCase {
    func testOnlyExplicitResumeCommandsCreateHints() {
        XCTAssertEqual(WorkspaceResume.explicitHint(command: "codex resume abc-123")?.sessionIdentifier, "abc-123")
        XCTAssertEqual(WorkspaceResume.explicitHint(command: "claude --resume 'abc-123'")?.tool, .claude)
        XCTAssertEqual(WorkspaceResume.explicitHint(command: "pi --session abc-123")?.tool, .pi)
        for command in ["codex resume --last", "codex resume abc;pwd", "echo codex resume abc", "codex resume abc extra", "codex resume $(whoami)", "claude --resume ../file", "pi --session /tmp/session.jsonl", "pi --session session.jsonl"] {
            XCTAssertNil(WorkspaceResume.explicitHint(command: command), command)
        }
    }

    func testCommandsUseOnlyFixedToolAndOneIdentifier() throws {
        let id = "12345678-abcd-1234-abcd-123456789abc"
        let commands: [(WorkspaceLaunchHint.Tool, String)] = [
            (.codex, "codex resume '\(id)'"),
            (.claude, "claude --resume '\(id)'"),
            (.pi, "pi --session '\(id)'")
        ]
        for (tool, expected) in commands {
            XCTAssertEqual(WorkspaceLaunchHint(tool: tool, sessionIdentifier: id)?.resumeCommand, expected)
        }
    }

    func testUntrustedDecodedHintsUseTheSameValidation() throws {
        for identifier in ["--last", "$(touch /tmp/example)", "abc;pwd", "../session", "abc\nwhoami", "", "abc'", String(repeating: "a", count: 161)] {
            XCTAssertNil(WorkspaceLaunchHint(tool: .codex, sessionIdentifier: identifier))
            let data = try JSONSerialization.data(withJSONObject: ["tool": "codex", "sessionIdentifier": identifier])
            XCTAssertThrowsError(try JSONDecoder().decode(WorkspaceLaunchHint.self, from: data))
        }
    }

    func testPiRejectsFileNamesEvenWithoutPathSeparators() throws {
        for identifier in ["session.jsonl", "SESSION.JSONL"] {
            XCTAssertNil(WorkspaceLaunchHint(tool: .pi, sessionIdentifier: identifier))
            XCTAssertNil(WorkspaceLaunchHint.fromLayout([
                "tool": "pi", "sessionIdentifier": identifier]))
            let data = try JSONSerialization.data(withJSONObject: [
                "tool": "pi", "sessionIdentifier": identifier])
            XCTAssertThrowsError(try JSONDecoder().decode(WorkspaceLaunchHint.self, from: data))
        }
        XCTAssertNotNil(WorkspaceLaunchHint(tool: .pi, sessionIdentifier: "abc-123"))
    }

    func testWorkspaceDropsOnlyBadOptionalHintsAndKeepsLayoutAndValidSiblings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-resume-decode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let layouts: [[String: Any]] = [[
            "type": "split", "vertical": true, "children": [
                ["type": "pane", "cwd": "/tmp/first", "scrollback": "saved work"],
                ["type": "pane", "cwd": "/tmp/second", "scrollback": "other work"],
            ],
        ]]
        let saved = try store.saveAsNew(name: "Recovery", layouts: layouts)
        let file = directory.appendingPathComponent(saved.id.uuidString + ".json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file))
            as? [String: Any])
        object["launchHints"] = [
            "window-0/child-0": ["tool": "codex", "sessionIdentifier": "valid-123"],
            "window-0/child-1": ["tool": "claude", "sessionIdentifier": "--old-id"],
            "legacy-unicode": ["tool": "claude", "sessionIdentifier": "sésión"],
            "future-tool": ["tool": "unknown-agent", "sessionIdentifier": "id-123"],
            "pi-path": ["tool": "pi", "sessionIdentifier": "session.jsonl"],
            "malformed": "not a hint",
        ] as [String: Any]
        try JSONSerialization.data(withJSONObject: object).write(to: file)

        let loaded = try store.load(id: saved.id)
        XCTAssertEqual(try loaded.foundationLayouts() as NSArray, layouts as NSArray)
        XCTAssertEqual(loaded.launchHints, [
            "window-0/child-0": try XCTUnwrap(
                WorkspaceLaunchHint(tool: .codex, sessionIdentifier: "valid-123")),
        ])
        XCTAssertEqual(try store.list().map(\.id), [saved.id])
    }

    func testWorkspaceRecoveryDoesNotRequireAnOptionalHintMap() throws {
        let saved = try SavedWorkspace(name: "Legacy", layouts: [
            ["type": "pane", "cwd": "/tmp", "scrollback": "recover me"],
        ])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))
            as? [String: Any])
        for optionalValue in [nil, NSNull(), "invalid map"] as [Any?] {
            object["launchHints"] = optionalValue
            let loaded = try JSONDecoder().decode(
                SavedWorkspace.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertTrue(loaded.launchHints.isEmpty)
            XCTAssertEqual(loaded.layouts, saved.layouts)
        }
        object["layouts"] = "invalid required layout"
        XCTAssertThrowsError(try JSONDecoder().decode(
            SavedWorkspace.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testHintsFollowExactNestedPanePathsAndPreserveLayout() throws {
        let hint = try XCTUnwrap(WorkspaceLaunchHint(tool: .claude, sessionIdentifier: "session_123"))
        let layouts: [[String: Any]] = [["type": "split", "vertical": true, "children": [
            ["type": "pane", "cwd": "/tmp/left"],
            ["type": "split", "children": [["type": "pane", "cwd": "/tmp/right"]]]
        ]]]
        let path = "window-0/child-1/child-0"
        let restored = WorkspaceResume.applying([path: hint, "window-50": hint], to: layouts)
        XCTAssertEqual(WorkspaceResume.launchHints(in: restored), [path: hint])
        XCTAssertEqual(restored.first?["vertical"] as? Bool, true)
        let children = try XCTUnwrap(restored.first?["children"] as? [[String: Any]])
        XCTAssertEqual(children[0]["cwd"] as? String, "/tmp/left")
        XCTAssertNil(children[0]["launchHint"])
        XCTAssertEqual(WorkspaceResume.launchHints(in: layouts), [:])
    }
}
