import XCTest
@testable import CmdyKit

final class WorkspaceContributionTests: XCTestCase {
    private let valid: [String: Any] = [
        "location": "navigator",
        "title": "Agents",
        "contexts": ["pane"],
        "sequence": 4,
        "items": [
            ["id": "builder", "title": "Builder", "detail": "running tests",
             "badge": "RUN", "status": "active", "action": "focus"],
        ],
    ]

    func testDecodesBoundedDeclarativeContribution() throws {
        let result = try PluginManager.decodeWorkspaceContribution(
            valid, id: "swarm", owner: "launch-token",
            extensionID: "dev.cmdy.swarm", extensionName: "Swarm")
        XCTAssertEqual(result.location, .navigator)
        XCTAssertEqual(result.contexts, [.pane])
        XCTAssertEqual(result.sequence, 4)
        XCTAssertEqual(result.items.first?.status, .active)
        XCTAssertEqual(result.items.first?.action, "focus")
    }

    func testUpdateIsSequencedAndKeepsOmittedFields() throws {
        let original = try PluginManager.decodeWorkspaceContribution(
            valid, id: "swarm", owner: "launch-token",
            extensionID: "dev.cmdy.swarm", extensionName: "Swarm")
        let updated = try PluginManager.decodeWorkspaceContribution(
            ["items": [["id": "builder", "title": "Builder", "status": "success"]]],
            id: "swarm", owner: "launch-token",
            extensionID: original.extensionID, extensionName: original.extensionName,
            replacing: original)
        XCTAssertEqual(updated.sequence, 5)
        XCTAssertEqual(updated.location, .navigator)
        XCTAssertEqual(updated.title, "Agents")
        XCTAssertEqual(updated.items.first?.status, .success)

        XCTAssertThrowsError(try PluginManager.decodeWorkspaceContribution(
            ["sequence": 5], id: "swarm", owner: "launch-token",
            extensionID: original.extensionID, extensionName: original.extensionName,
            replacing: updated))
    }

    func testRejectsExecutableOrUnboundedShapes() {
        var invalid = valid
        invalid["contexts"] = ["unknown"]
        XCTAssertThrowsError(try PluginManager.decodeWorkspaceContribution(
            invalid, id: "swarm", owner: "launch-token",
            extensionID: "dev.cmdy.swarm", extensionName: "Swarm"))

        invalid = valid
        invalid["items"] = (0..<65).map { ["id": "item-\($0)", "title": "Item"] }
        XCTAssertThrowsError(try PluginManager.decodeWorkspaceContribution(
            invalid, id: "swarm", owner: "launch-token",
            extensionID: "dev.cmdy.swarm", extensionName: "Swarm"))
    }
}
