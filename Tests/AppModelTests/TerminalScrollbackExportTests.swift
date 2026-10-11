import Foundation
import CmdyKit
import XCTest
@testable import ModelProbe

final class TerminalScrollbackExportTests: XCTestCase {
    @MainActor
    func testEveryGeneratedLogicalLineSurvivesPhysicalWrapAndReflow() {
        let model = TerminalModel(cols: 120, rows: 36)
        let lines = (0..<1_000).map { String(format: "%04d:", $0) + String(repeating: "x", count: 140) }
        model.feed(text: lines.joined(separator: "\r\n") + "\r\n")
        let expected = lines.joined()
        XCTAssertGreaterThan(model.bufferLineCount, model.rows)
        XCTAssertEqual(model.scrollbackText().replacingOccurrences(of: "\n", with: ""), expected)
        let atBottom = model.scrollbackText()
        _ = model.scrollViewport(to: 0)
        XCTAssertEqual(model.currentTopRow, 0)
        XCTAssertEqual(model.scrollbackText(), atBottom)
        _ = model.resize(cols: 132, rows: 40, pixelWidth: 1320, pixelHeight: 800)
        XCTAssertEqual(model.scrollbackText().replacingOccurrences(of: "\n", with: ""), expected)
        _ = model.resize(cols: 120, rows: 36, pixelWidth: 1200, pixelHeight: 720)
        XCTAssertEqual(model.scrollbackText().replacingOccurrences(of: "\n", with: ""), expected)
    }

    @MainActor
    func testAlternateBufferDoesNotExportInactivePrimaryHistory() {
        let model = TerminalModel(cols: 40, rows: 4)
        model.feed(text: (0..<12).map { "primary-\($0)\r\n" }.joined())
        let primary = model.scrollbackText()
        XCTAssertTrue(primary.contains("primary-0"))
        model.feed(text: "\u{1b}[?1049hALT_ONLY")
        let alternate = model.scrollbackText()
        XCTAssertTrue(alternate.contains("ALT_ONLY"))
        XCTAssertFalse(alternate.contains("primary-"))
        model.feed(text: "\u{1b}[?1049l")
        XCTAssertEqual(model.scrollbackText(), primary)
    }

    @MainActor
    func testExportHonorsErasedHistoryAndPreservesUnicode() {
        let model = TerminalModel(cols: 20, rows: 4)
        model.feed(text: String(repeating: "old-content\r\n", count: 20))
        model.feed(text: "\u{1b}[3J\u{1b}[2J\u{1b}[H界e\u{301}🙂")
        let text = model.scrollbackText()
        XCTAssertFalse(text.contains("old-content"))
        XCTAssertEqual(text.components(separatedBy: "\n").first, "界e\u{301}🙂")
        XCTAssertEqual(text.components(separatedBy: "\n").count, model.rows + 1)
    }

    @MainActor
    func testExportIsSafeInsideTheSerializedWorkerTurn() {
        let model = TerminalModel(cols: 30, rows: 4)
        model.performWorkerTurnForTesting { current in
            current.feed(text: "one\r\ntwo")
            XCTAssertEqual(current.scrollbackText(), "one\ntwo\n\n\n")
        }
    }

    @MainActor
    func testPublicEngineDispatchSendsOnlyCompletedPathWithoutChangingViewportOrPublication() throws {
        let model = TerminalModel(cols: 20, rows: 4)
        model.feed(text: (0..<30).map { "row-\($0) 界e\u{301}🙂\r\n" }.joined())
        _ = model.scrollViewport(to: 0)
        let state = model.workerStateForTesting
        let top = model.currentTopRow, live = model.liveScreenTopRow
        let cursor = model.scrollInvariantCursorRow, column = model.cursorColumn
        let expected = model.scrollbackText()
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine: TerminalEngine = model
        var sent: [String] = []
        let url = try TerminalScrollbackExport.paste(from: engine, directory: root) { path in
            sent.append(path)
            XCTAssertEqual(try? String(contentsOfFile: path, encoding: .utf8), expected)
        }
        XCTAssertEqual(sent, [url.path])
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(model.currentTopRow, top)
        XCTAssertEqual(model.liveScreenTopRow, live)
        XCTAssertEqual(model.scrollInvariantCursorRow, cursor)
        XCTAssertEqual(model.cursorColumn, column)
        XCTAssertEqual(model.workerStateForTesting.generation, state.generation)
        XCTAssertEqual(model.workerStateForTesting.kind, state.kind)
        XCTAssertEqual(model.workerStateForTesting.deadline, state.deadline)
        XCTAssertEqual(model.scrollbackText(), expected)
    }

    @MainActor
    func testZWJAndWideCellContinuationsAreNotExportedAsExtraSpaces() {
        let model = TerminalModel(cols: 30, rows: 4)
        let text = "A界e\u{301}👩‍💻Z"
        model.feed(text: text)
        XCTAssertEqual(model.scrollbackText(), text + "\n\n\n\n")
    }

    @MainActor
    func testFailureDoesNotSendAnyPath() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: file, options: .withoutOverwriting)
        let model = TerminalModel(cols: 20, rows: 4)
        var paths: [String] = []
        XCTAssertThrowsError(try TerminalScrollbackExport.paste(from: model, directory: file) { paths.append($0) })
        XCTAssertTrue(paths.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
    }

    func testFileIsPrivateUniqueAndPreservesExactUTF8Bytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = String(repeating: "界 e\u{301} 🙂\n", count: 5_000)
        let first = try TerminalTextFile.write(text, directory: root)
        let second = try TerminalTextFile.write("second", directory: root)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), Data(text.utf8))
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second")
        let attributes = try FileManager.default.attributesOfItem(atPath: first.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
    }

    func testFailedExportDoesNotReplaceAnExistingDestination() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("keep".utf8).write(to: file, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try TerminalTextFile.write("new", directory: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep")
    }

    func testExclusiveLeafCreationRejectsExistingFileAndSymlink() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("existing.txt")
        try Data("keep".utf8).write(to: file, options: .withoutOverwriting)
        XCTAssertThrowsError(try TerminalTextFile.write("replace", directory: root, filename: "existing.txt"))
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try TerminalTextFile.write("replace", directory: root, filename: "link.txt"))
        XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), file.path)
    }

    func testDirectorySymlinkAndEscapingFilenameAreRejected() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        XCTAssertThrowsError(try TerminalTextFile.write("new", directory: alias))
        for name in ["", ".", "..", "../escape.txt", "child/file", "nul\0name"] {
            XCTAssertThrowsError(try TerminalTextFile.write("new", directory: directory, filename: name))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testExplicitTemporaryDirectoryRoutingAndAbsentOnlyFallback() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try TerminalTextFile.temporaryDirectory(environment: ["TMPDIR": root.path + "/"]), root)
        XCTAssertEqual(try TerminalTextFile.temporaryDirectory(environment: [:]), FileManager.default.temporaryDirectory)
        for path in ["", "relative", "file:///private/tmp", "/private/tmp/nul\0name"] {
            XCTAssertThrowsError(try TerminalTextFile.temporaryDirectory(environment: ["TMPDIR": path]))
        }
    }

    private func privateDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmdy-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: NSNumber(value: 0o700)])
        return root
    }
}
