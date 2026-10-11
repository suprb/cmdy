import Foundation
import XCTest
@testable import CmdyKit

final class SessionStoreTests: XCTestCase {
    func testRoundTripPreservesWindowOrderAndNestedLayout() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.json")
        let layouts: [[String: Any]] = [
            [
                "type": "pane",
                "cwd": "/tmp/first",
                "scrollback": "hello",
            ],
            [
                "type": "split",
                "vertical": true,
                "children": [
                    ["type": "pane", "cwd": "/tmp/left"],
                    ["type": "pane", "cwd": "/tmp/right"],
                ],
            ],
        ]

        try SessionStore.save(layouts: layouts, to: url)
        let restored = try XCTUnwrap(SessionStore.load(from: url))

        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored[0]["cwd"] as? String, "/tmp/first")
        XCTAssertEqual(restored[1]["type"] as? String, "split")
        let children = try XCTUnwrap(
            restored[1]["children"] as? [[String: Any]])
        XCTAssertEqual(children.map { $0["cwd"] as? String }, [
            "/tmp/left", "/tmp/right",
        ])
    }

    func testMissingFileIsNilButCorruptJSONThrows() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.json")

        XCTAssertNil(try SessionStore.load(from: url))

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(to: url)

        XCTAssertThrowsError(try SessionStore.load(from: url)) { error in
            guard case SessionStore.StoreError.corrupt(let path, let reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(path, url.path)
            XCTAssertTrue(reason.contains("invalid JSON"))
        }
    }

    func testFailedStagedWritePreservesLastGoodSessionAtomically() throws {
        enum InjectedFailure: Error { case interrupted }

        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.json")
        try SessionStore.save(
            layouts: [["type": "pane", "cwd": "/tmp/last-good"]],
            to: url)
        let lastGoodData = try Data(contentsOf: url)

        XCTAssertThrowsError(try SessionStore.save(
            layouts: [["type": "pane", "cwd": "/tmp/replacement"]],
            to: url,
            stagedWriter: { data, stagedURL in
                try Data(data.prefix(7)).write(to: stagedURL)
                throw InjectedFailure.interrupted
            })) { error in
                guard case InjectedFailure.interrupted = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }

        XCTAssertEqual(try Data(contentsOf: url), lastGoodData)
        let restored = try XCTUnwrap(SessionStore.load(from: url))
        XCTAssertEqual(restored.first?["cwd"] as? String, "/tmp/last-good")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["session.json"])
    }

    func testCheckpointsAndPreviousCopyArePrivateAndRecoverCorruption() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.json")
        let previous = SessionStore.previousURL(for: url)
        try SessionStore.save(layouts: [["type": "pane", "cwd": "/first"]], to: url)
        try SessionStore.save(layouts: [["type": "pane", "cwd": "/second"]], to: url)
        for file in [url, previous] {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }

        try Data("{interrupted".utf8).write(to: url)
        let recovered = SessionStore.loadWithRecovery(from: url)
        XCTAssertEqual(recovered.layouts?.first?["cwd"] as? String, "/first")
        guard case .recoveredPrevious = recovered.notice else {
            return XCTFail("recovery must include a visible-notice payload")
        }
        // A corrupt primary must not poison the last-good backup on retry.
        try SessionStore.save(layouts: [["type": "pane", "cwd": "/third"]], to: url)
        XCTAssertEqual(try SessionStore.load(from: previous)?.first?["cwd"] as? String, "/first")
    }

    func testEmptyCheckpointNeverResurrectsClosedWindows() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.json")
        let previous = SessionStore.previousURL(for: url)
        try SessionStore.save(layouts: [["type": "pane", "cwd": "/old"]], to: url)
        let oldData = try Data(contentsOf: url)
        try SessionStore.save(layouts: [], to: url)
        // Simulate interruption before an obsolete previous copy is removed.
        try oldData.write(to: previous)
        let loaded = SessionStore.loadWithRecovery(from: url)
        XCTAssertNil(loaded.layouts)
        XCTAssertNil(loaded.notice)
    }

    func testMissingPrimaryUsesPreviousAndDoubleCorruptionReportsFailure() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.json")
        let previous = SessionStore.previousURL(for: url)
        try SessionStore.save(layouts: [["type": "pane", "cwd": "/old"]], to: url)
        try SessionStore.save(layouts: [["type": "pane", "cwd": "/new"]], to: url)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(SessionStore.loadWithRecovery(from: url).layouts?.first?["cwd"] as? String, "/old")
        try Data("bad".utf8).write(to: url)
        try Data("also bad".utf8).write(to: previous)
        let failed = SessionStore.loadWithRecovery(from: url)
        XCTAssertNil(failed.layouts)
        guard case .couldNotRestore = failed.notice else {
            return XCTFail("unreadable recovery state must not silently disappear")
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-session-tests-\(UUID().uuidString)")
    }
}
