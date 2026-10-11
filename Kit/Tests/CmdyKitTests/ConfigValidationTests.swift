import Foundation
import XCTest
@testable import CmdyKit

final class ConfigValidationTests: XCTestCase {
    func testMalformedLinesAreReportedWithoutEchoingTheirContents() {
        let issues = ConfigFile.syntaxIssues(in: "# retained\nfixture-private-value\neditor = \"unclosed\n")
        XCTAssertEqual(issues.map(\.key), ["Line 2", "Line 3"])
        XCTAssertFalse(issues.map(\.message).joined().contains("fixture-private-value"))
        XCTAssertNil(ConfigFile.parse("editor = \"unclosed")["editor"])
        XCTAssertTrue(ConfigFile.syntaxIssues(in: "cursor-color = #80AABB\neditor = \"System\"\n").isEmpty)
    }

    func testInvalidSettingsHaveActionableMessagesWithoutEchoingValues() {
        let invalid = [
            "theme": "fixture-private-value", "shader": "fixture-private-value",
            "font-family": "fixture-private-value",
            "cursor-color": "fixture-private-value", "cursor-style": "round",
            "ghost-text": "maybe", "font-size": "nan", "line-height": "5",
            "opacity": "infinity", "scroll-speed": "0", "text-rendering": "missing",
        ]
        let issues = ConfigFile.validationIssues(for: invalid)
        XCTAssertEqual(Set(issues.map(\.key)), Set(invalid.keys))
        XCTAssertTrue(issues.allSatisfy { !$0.message.contains("fixture-private-value") })
        XCTAssertTrue(issues.allSatisfy { !$0.message.isEmpty })
    }

    func testValidConfigAndUnknownFutureSettingsRemainAccepted() {
        let issues = ConfigFile.validationIssues(for: [
            "theme": "light", "shader": "off", "font-family": "System",
            "cursor-color": "#80AABB", "cursor-style": "bar", "cursor-blink": "yes",
            "font-size": "14", "opacity": "0.3", "margin": "60",
            "new-future-setting": "forward compatible", "anthropic-api-key": "fixture-key",
        ])
        XCTAssertTrue(issues.isEmpty)
    }

    func testInvalidColorCannotBeMistakenForResetToTheme() {
        XCTAssertEqual(ConfigFile.validationIssues(for: ["cursor-color": "bad-color"]).map(\.key),
                       ["cursor-color"])
        XCTAssertTrue(ConfigFile.validationIssues(for: ["cursor-color": "theme"]).isEmpty)
    }

    func testWriteBackUpdatesAllDuplicateAssignments() {
        let text = "# retained comment\nghost-text = true\ntheme = Light\nGHOST-TEXT = true\n"
        let updated = ConfigFile.rewriting(text, key: "ghost-text", value: "false")
        XCTAssertEqual(ConfigFile.parse(updated)["ghost-text"], "false")
        XCTAssertTrue(updated.contains("# retained comment"))
        XCTAssertFalse(updated.contains("ghost-text = true"))
        XCTAssertEqual(ConfigFile.parse(updated)["theme"], "Light")
    }

    func testCredentialScrubbingAlsoRemovesCommentedAndDuplicateBackupEntries() {
        let source = """
        # keep this comment
        theme = Light
        anthropic-api-key = fixture-active
        # anthropic-api-key = fixture-commented
        ANTHROPIC-API-KEY = fixture-duplicate
        editor = System
        """
        let sanitized = ConfigFile.removingAssistantCredentials(from: source)
        XCTAssertNil(ConfigFile.parse(sanitized)["anthropic-api-key"])
        XCTAssertFalse(sanitized.contains("fixture-"))
        XCTAssertTrue(sanitized.contains("# keep this comment"))
        XCTAssertEqual(ConfigFile.parse(sanitized)["theme"], "Light")
        XCTAssertEqual(ConfigFile.parse(sanitized)["editor"], "System")
        XCTAssertEqual(ConfigFile.removingAssistantCredentials(from: sanitized), sanitized)
    }

    func testAtomicConfigWritesUsePrivatePermissionsAndKeepLastGoodOnFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("config")
        try ConfigFile.writePrivate(Data("theme = Light\n".utf8), to: target)
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        try ConfigFile.writePrivate(Data("theme = Dark\n".utf8), to: target)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "theme = Dark\n")

        let blocked = directory.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ConfigFile.writePrivate(Data("new".utf8), to: blocked))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "theme = Dark\n")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .contains(where: { $0.hasPrefix(".cmdy-config-") }))
    }
}
