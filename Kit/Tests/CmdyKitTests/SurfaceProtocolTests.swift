import Foundation
import XCTest
@testable import CmdyKit

final class SurfaceProtocolTests: XCTestCase {
    func testTableRoundTripsAndKeepsTextFallback() throws {
        let document = try SurfaceDocument(
            id: "git-status", kind: .table, title: "Git status",
            pane: "pane-1", block: "block-4", fallback: " M README.md",
            columns: [
                SurfaceColumn(id: "state", title: "State"),
                SurfaceColumn(id: "path", title: "Path"),
            ],
            rows: [
                SurfaceRow(id: "README.md", cells: [
                    "state": .string("modified"), "path": .string("README.md"),
                ]),
            ])

        let decoded = try SurfaceDocument.decode(document.encoded())
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.fallback, " M README.md")
    }

    func testRawAuthorsCanOmitDefaultedFields() throws {
        let document = try SurfaceDocument.decode(Data("""
        {"id":"choices","kind":"list","title":"Choices","fallback":"One",
         "rows":[{"id":"one","cells":{"label":"One"}}]}
        """.utf8))

        XCTAssertEqual(document.protocolVersion, 1)
        XCTAssertEqual(document.block, "current")
        XCTAssertEqual(document.sequence, 0)
        XCTAssertEqual(document.rows.first?.actions, [])

        var updated = document
        let patch = try JSONDecoder().decode(
            SurfacePatch.self, from: Data("{\"sequence\":1,\"summary\":\"Ready\"}".utf8))
        try updated.apply(patch)
        XCTAssertEqual(updated.summary, "Ready")
    }

    func testPatchUsesStableIDsAndRejectsSequenceGaps() throws {
        var document = try SurfaceDocument(
            id: "tests", kind: .task, title: "Tests", fallback: "1 test",
            tasks: [SurfaceTask(id: "core", label: "Core", status: .running)])

        try document.apply(SurfacePatch(
            sequence: 1,
            upsertTasks: [SurfaceTask(id: "core", label: "Core", status: .passed,
                                      durationMs: 125)]))
        XCTAssertEqual(document.tasks.first?.status, .passed)
        XCTAssertEqual(document.sequence, 1)

        XCTAssertThrowsError(try document.apply(SurfacePatch(sequence: 3))) { error in
            XCTAssertEqual(error as? SurfaceProtocolError,
                           .sequence(expected: 2, received: 3))
        }
    }

    func testInvalidPatchDoesNotPartiallyMutateDocument() throws {
        var document = try SurfaceDocument(
            id: "tests", kind: .task, title: "Tests", fallback: "running",
            tasks: [SurfaceTask(id: "core", label: "Core", status: .running)])
        let original = document

        XCTAssertThrowsError(try document.apply(SurfacePatch(
            sequence: 1, title: "Mutated",
            upsertTasks: [SurfaceTask(id: "bad/id", label: "Bad", status: .passed)])))
        XCTAssertEqual(document, original)
    }

    func testNestedIdentitiesAndNumericRangesAreValidated() {
        XCTAssertThrowsError(try SurfaceDocument(
            id: "tasks", kind: .task, title: "Tests", fallback: "bad",
            tasks: [SurfaceTask(id: "bad/id", label: "Bad", status: .running)]))
        XCTAssertThrowsError(try SurfaceDocument(
            id: "tasks", kind: .task, title: "Tests", fallback: "bad",
            tasks: [SurfaceTask(id: "bad", label: "Bad", status: .running,
                                progress: 1.5)]))
        XCTAssertThrowsError(try SurfaceDocument(
            id: "actions", kind: .text, title: "Actions", fallback: "bad",
            actions: [
                SurfaceAction(id: "same", title: "One"),
                SurfaceAction(id: "same", title: "Two"),
            ]))
    }

    func testRejectsDuplicateRowsAndMissingDiff() throws {
        XCTAssertThrowsError(try SurfaceDocument(
            id: "duplicate", kind: .list, title: "Duplicate", fallback: "x",
            rows: [
                SurfaceRow(id: "same", cells: ["label": .string("A")]),
                SurfaceRow(id: "same", cells: ["label": .string("B")]),
            ]))

        XCTAssertThrowsError(try SurfaceDocument(
            id: "diff", kind: .diff, title: "Diff", fallback: "none"))
    }

    func testSurfaceValuesDoNotAcceptNestedExecutableObjects() {
        let data = Data("""
        {"v":1,"id":"bad","kind":"list","title":"Bad","block":"current",
         "sequence":0,"state":"live","fallback":"bad","columns":[],
         "rows":[{"id":"x","cells":{"value":{"html":"<script>"}},"actions":[]}],
         "tasks":[],"fields":[],"actions":[]}
        """.utf8)
        XCTAssertThrowsError(try SurfaceDocument.decode(data))
    }

    func testMutatingActionsMustExplainWhatWillHappen() {
        XCTAssertThrowsError(try SurfaceDocument(
            id: "deploy", kind: .text, title: "Deploy", fallback: "deploy",
            actions: [SurfaceAction(id: "deploy", title: "Deploy", effect: .mutate)]))

        XCTAssertNoThrow(try SurfaceDocument(
            id: "deploy", kind: .text, title: "Deploy", fallback: "deploy",
            actions: [SurfaceAction(id: "deploy", title: "Deploy", effect: .mutate,
                                    style: .destructive,
                                    confirmation: "Deploy the current commit to production?")]))
    }

    func testTableAdapterDisambiguatesUnsafeJSONKeysAndRowIDs() throws {
        let document = try SurfaceCLI.makeDocument(
            kind: .table, id: "records", title: "Records", pane: nil,
            block: "current",
            fallback: #"[{"id":"path/one","a/b":1,"a b":2},{"id":"path/one","a/b":3,"a b":4}]"#)

        XCTAssertEqual(Set(document.columns.map(\.id)).count, document.columns.count)
        XCTAssertEqual(Set(document.rows.map(\.id)).count, document.rows.count)
        XCTAssertTrue(document.columns.allSatisfy { !$0.id.contains("/") })
    }
}
