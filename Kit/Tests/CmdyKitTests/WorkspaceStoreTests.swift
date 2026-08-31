import Foundation
import XCTest
@testable import CmdyKit

final class WorkspaceStoreTests: XCTestCase {
    func testSaveListUpdateRenameAndDelete() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let updated = Date(timeIntervalSince1970: 1_700_000_100)

        let saved = try store.saveAsNew(
            name: "  Demo\n Workspace  ",
            layouts: [pane(cwd: "/tmp/original")],
            presentation: WorkspacePresentation(
                windowGridEnabled: true,
                windowGridState: Data([0, 1, 2]),
                navigatorVisible: true,
                inspectorVisible: false),
            now: created,
            id: id)

        XCTAssertEqual(saved.name, "Demo Workspace")
        XCTAssertEqual(store.currentWorkspaceID(), id)
        XCTAssertEqual(try store.list(), [saved.summary])
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(id.uuidString + ".json").path
            )[.posixPermissions] as? NSNumber,
            NSNumber(value: 0o600))

        let replacement = pane(cwd: "/tmp/replacement", theme: "Nord")
        let changed = try store.update(id: id, layouts: [replacement], now: updated)
        XCTAssertEqual(changed.createdAt, created)
        XCTAssertEqual(changed.updatedAt, updated)
        XCTAssertEqual(
            try changed.foundationLayouts()[0]["cwd"] as? String,
            "/tmp/replacement")
        XCTAssertEqual(
            try changed.foundationLayouts()[0]["paneTheme"] as? String,
            "Nord")

        let renamed = try store.rename(id: id, to: "Production", now: updated)
        XCTAssertEqual(renamed.name, "Production")
        try store.delete(id: id)
        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertNil(store.currentWorkspaceID())
    }

    func testExactNestedLayoutAndAppearanceFieldsRoundTrip() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let layout: [String: Any] = [
            "type": "split",
            "vertical": true,
            "frame": "{{10, 20}, {900, 600}}",
            "floating": false,
            "tabTheme": "Black",
            "tabShader": "none",
            "tabFont": "Berkeley Mono",
            "tabFontSize": 15.0,
            "workspaceTabGroup": "group-1",
            "workspaceTabIndex": 1,
            "workspaceTabSelected": true,
            "workspaceTabSidebar": false,
            "children": [
                pane(cwd: "/tmp/left", theme: "Nord", shader: "bloom"),
                pane(cwd: "/tmp/right", theme: "Dracula", shader: "none"),
            ],
        ]

        let saved = try store.saveAsNew(name: "Nested", layouts: [layout])
        let restored = try store.load(id: saved.id).foundationLayouts()
        XCTAssertTrue(NSDictionary(dictionary: restored[0]).isEqual(to: layout))
    }

    func testDuplicateNamesAreCaseInsensitiveAndNamesCannotEscapeDirectory() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        _ = try store.saveAsNew(name: "My Workspace", layouts: [pane()])

        XCTAssertThrowsError(
            try store.saveAsNew(name: "my workspace", layouts: [pane()])) {
            XCTAssertEqual(
                $0 as? WorkspaceStore.StoreError,
                .duplicateName("my workspace"))
        }
        let hostile = try store.saveAsNew(
            name: "../../Outside", layouts: [pane()])
        XCTAssertEqual(hostile.name, "Outside")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".json") }.count,
            2)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.deletingLastPathComponent()
                .appendingPathComponent("Outside").path))
    }

    func testInvalidAndCorruptSnapshotsDoNotAffectOtherWorkspaces() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let good = try store.saveAsNew(name: "Good", layouts: [pane()])
        let corruptID = UUID()
        try Data("{bad json".utf8).write(
            to: directory.appendingPathComponent(corruptID.uuidString + ".json"))

        XCTAssertEqual(try store.list().map(\.id), [good.id])
        XCTAssertThrowsError(try store.load(id: corruptID)) {
            guard case WorkspaceStore.StoreError.corrupt = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }
        XCTAssertThrowsError(
            try store.saveAsNew(name: "Empty", layouts: [])) {
            guard case WorkspaceStore.StoreError.invalidSnapshot = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }
    }

    func testSafeLaunchHintRejectsCommandsAndCredentialLikeText() {
        XCTAssertNotNil(WorkspaceLaunchHint(
            tool: .codex, sessionIdentifier: "session_01HZ-abc.2"))
        XCTAssertNil(WorkspaceLaunchHint(
            tool: .claude, sessionIdentifier: "claude resume secret value"))
        XCTAssertNil(WorkspaceLaunchHint(
            tool: .pi, sessionIdentifier: "--api-key=secret"))
    }

    @MainActor
    func testCoordinatorDefaultsToAdditionalWindowsAndMarksCurrentOnlyOnSuccess() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        var openedModes: [WorkspaceOpenMode] = []
        let coordinator = NamedWorkspaceCoordinator(
            store: store,
            capture: { WorkspaceCapture(layouts: [self.pane(cwd: "/tmp/live")]) },
            open: { _, mode in openedModes.append(mode) })
        let saved = try coordinator.saveAsNew(named: "Current")
        try store.setCurrentWorkspaceID(nil)

        try coordinator.open(id: saved.id)
        XCTAssertEqual(openedModes.count, 1)
        guard case .additionalWindows = openedModes[0] else {
            return XCTFail("open should be non-destructive by default")
        }
        XCTAssertEqual(coordinator.currentWorkspaceID, saved.id)

        enum Rejected: Error { case no }
        let rejected = NamedWorkspaceCoordinator(
            store: store,
            capture: { WorkspaceCapture(layouts: [self.pane()]) },
            open: { _, _ in throw Rejected.no })
        try store.setCurrentWorkspaceID(nil)
        XCTAssertThrowsError(try rejected.open(id: saved.id))
        XCTAssertNil(store.currentWorkspaceID())
    }

    private func pane(
        cwd: String = "/tmp",
        theme: String? = nil,
        shader: String? = nil
    ) -> [String: Any] {
        var result: [String: Any] = [
            "type": "pane",
            "cwd": cwd,
            "scrollback": "recent output",
            "paneFont": "System",
            "paneFontSize": 13,
        ]
        if let theme { result["paneTheme"] = theme }
        if let shader { result["paneShader"] = shader }
        return result
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-workspace-tests-\(UUID().uuidString)")
    }
}
