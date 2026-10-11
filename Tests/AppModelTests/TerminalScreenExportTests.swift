import CmdyKit
import Foundation
import XCTest
@testable import ModelProbe

final class TerminalScreenExportTests: XCTestCase {
    @MainActor
    func testVisibleViewportUsesExplicitTMPDIRAndDeliversCompletedPrivateUTF8File() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = TerminalModel(cols: 40, rows: 3)
        model.feed(text: "hidden-before\r\nrow-one\r\n界e\u{301}🙂\r\nrow-three\r\nhidden-after\r\nlast")
        _ = model.scrollViewport(to: 1)
        XCTAssertEqual(model.currentTopRow, 1)
        let state = model.workerStateForTesting
        let top = model.currentTopRow, live = model.liveScreenTopRow
        let cursor = model.scrollInvariantCursorRow, column = model.cursorColumn
        // Preserve the existing screen accessor's grid-shaped text, including
        // one space for each wide-cell continuation.
        let expected = Data("row-one\n界 e\u{301}🙂 \nrow-three\n".utf8)
        let filename = "cmdy-screen-\(UUID().uuidString).txt"
        var delivered: [URL] = []
        let engine: TerminalEngine = model
        let url = try TerminalScreenExport.write(from: engine, filename: filename,
                                                 environment: ["TMPDIR": root.path + "/"]) { url in
            delivered.append(url)
            XCTAssertEqual(try? Data(contentsOf: url), expected)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes?[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual(attributes?[.type] as? FileAttributeType, .typeRegular)
        }
        XCTAssertEqual(delivered, [url])
        XCTAssertEqual(url.lastPathComponent, filename)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [filename])
        XCTAssertEqual(model.currentTopRow, top)
        XCTAssertEqual(model.liveScreenTopRow, live)
        XCTAssertEqual(model.scrollInvariantCursorRow, cursor)
        XCTAssertEqual(model.cursorColumn, column)
        XCTAssertEqual(model.workerStateForTesting.generation, state.generation)
        XCTAssertEqual(model.workerStateForTesting.kind, state.kind)
        XCTAssertEqual(model.workerStateForTesting.deadline, state.deadline)
    }

    @MainActor
    func testDefaultProcessEnvironmentPreservesBlankRowsAndTrailingNewline() throws {
        let model = TerminalModel(cols: 20, rows: 3)
        let directory = try TerminalTextFile.temporaryDirectory()
        let filename = "cmdy-screen-\(UUID().uuidString).txt"
        var delivered: [URL] = []
        let url = try TerminalScreenExport.write(from: model, filename: filename) { delivered.append($0) }
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(delivered, [url])
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: url), Data("\n\n\n".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    @MainActor
    func testAlternateScreenExcludesInactivePrimaryHistory() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = TerminalModel(cols: 20, rows: 3)
        model.feed(text: String(repeating: "primary-hidden\r\n", count: 12))
        model.feed(text: "\u{1b}[?1049h\u{1b}[HALT_ONLY")
        let url = try TerminalScreenExport.write(from: model, filename: "cmdy-screen-alternate.txt",
                                                 environment: ["TMPDIR": root.path]) { _ in }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "ALT_ONLY\n\n\n")
    }

    @MainActor
    func testInvalidExplicitTMPDIRNeverFallsBackOrDeliversAPath() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: file, options: .withoutOverwriting)
        let actual = root.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let model = TerminalModel(cols: 20, rows: 3)
        model.feed(text: "generated private text")
        for path in ["", "relative", "file:///private/tmp", root.appendingPathComponent("missing").path,
                     file.path, alias.path, root.path + "/nul\0name"] {
            let filename = "cmdy-screen-\(UUID().uuidString).txt"
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fallback.path))
            var delivered: [URL] = []
            XCTAssertThrowsError(try TerminalScreenExport.write(from: model, filename: filename,
                                                                environment: ["TMPDIR": path]) { delivered.append($0) })
            XCTAssertTrue(delivered.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fallback.path))
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: actual.path), [])
    }

    @MainActor
    func testExclusiveWriteFailureLeavesDestinationAndDoesNotDeliverAPath() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let filename = "cmdy-screen-existing.txt"
        let destination = root.appendingPathComponent(filename)
        try Data("keep".utf8).write(to: destination, options: .withoutOverwriting)
        let model = TerminalModel(cols: 20, rows: 3)
        model.feed(text: "replacement")
        var delivered: [URL] = []
        XCTAssertThrowsError(try TerminalScreenExport.write(from: model, filename: filename,
                                                            environment: ["TMPDIR": root.path]) { delivered.append($0) })
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [filename])
    }

    @MainActor
    func testAlternateMemoryFixtureExportsOnlyVisibleRowsAndPadding() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = TerminalModel(cols: 120, rows: 36)
        let marker = "0123456789abcdef"
        let rows = (0..<35).map { index in
            let prefix = String(format: "CMDY_MEMORY_\(marker)_ROW_%06d|", index)
            return prefix + String(repeating: "A", count: 76 - prefix.utf8.count)
        }
        XCTAssertTrue(rows.allSatisfy { $0.utf8.count == 76 })
        // Match memory_bench_payloads: enter alternate, stream the complete
        // payload, clear/home, then write 35 numbered rows with a final CRLF.
        model.feed(text: "\u{1b}[?1049h" + String(repeating: "A", count: 3_000_000)
                   + "\u{1b}[2J\u{1b}[H" + rows.joined(separator: "\r\n") + "\r\n")
        XCTAssertTrue(model.isCurrentBufferAlternate)
        XCTAssertEqual(model.currentTopRow, model.liveScreenTopRow)
        XCTAssertGreaterThan(model.bufferLineCount, model.rows)
        let retainedHistoryRow = String(repeating: "A", count: 120) + "\n"
        XCTAssertTrue(model.scrollbackText().hasPrefix(retainedHistoryRow))

        var delivered: [URL] = []
        let url = try TerminalScreenExport.write(from: model, filename: "cmdy-screen-alternate-memory.txt",
                                                 environment: ["TMPDIR": root.path]) { delivered.append($0) }
        let exported = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(delivered, [url])
        XCTAssertEqual(exported, rows.joined(separator: "\n") + "\n\n")
        XCTAssertEqual(exported.components(separatedBy: "\n"), rows + ["", ""])
        XCTAssertFalse(exported.contains(retainedHistoryRow))
    }

    private func privateDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmdy-screen-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: NSNumber(value: 0o700)])
        return root
    }
}
