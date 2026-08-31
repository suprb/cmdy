import Foundation
import XCTest
@testable import CmdySDK

final class SurfaceTests: XCTestCase {
    func testCanonicalCmdyAliasUsesTheCompatibleClient() {
        let client: Cmdy? = Cmdy(environment: [
            "CMDY_PORT": "4680",
            "CMDY_TOKEN": "test-token",
        ])
        XCTAssertNotNil(client)
    }

    func testDocumentUsesSurfaceProtocolV1WireKeys() throws {
        let document = CmdySurfaceDocument(
            id: "git", kind: .table, title: "Git", block: "current",
            fallback: " M README.md",
            columns: [CmdySurfaceColumn(id: "path", title: "Path")],
            rows: [CmdySurfaceRow(id: "readme", cells: [
                "path": .string("README.md"),
            ])])

        let data = try JSONEncoder().encode(document)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["kind"] as? String, "table")
        XCTAssertEqual(object["fallback"] as? String, " M README.md")
    }

    func testPatchCarriesStableUpsertsAndSequence() throws {
        let patch = CmdySurfacePatch(
            sequence: 2,
            upsertTasks: [CmdySurfaceTask(id: "core", label: "Core",
                                              status: .passed)])
        let decoded = try JSONDecoder().decode(
            CmdySurfacePatch.self, from: JSONEncoder().encode(patch))
        XCTAssertEqual(decoded.sequence, 2)
        XCTAssertEqual(decoded.upsertTasks.first?.id, "core")
    }

    func testNewEnvironmentNamesTakePrecedence() {
        let cmdy = Cmdy(environment: [
            "CMDY_PORT": "4665", "CMDY_TOKEN": "new",
            "TERM64_PORT": "4999", "TERM64_TOKEN": "old",
        ])
        XCTAssertEqual(cmdy?.port, 4665)
        XCTAssertEqual(cmdy?.token, "new")
    }

    func testInvalidConnectionEnvironmentIsRejected() {
        XCTAssertNil(Cmdy(environment: [
            "CMDY_PORT": "0", "CMDY_TOKEN": "token",
        ]))
        XCTAssertNil(Cmdy(environment: [
            "CMDY_PORT": "70000", "CMDY_TOKEN": "token",
        ]))
        XCTAssertNil(Cmdy(environment: [
            "CMDY_PORT": "4665", "CMDY_TOKEN": "",
        ]))
        XCTAssertNil(Cmdy(environment: [
            "CMDY_PORT": "4665",
            "CMDY_TOKEN": String(repeating: "x", count: 4_097),
        ]))
    }
}
