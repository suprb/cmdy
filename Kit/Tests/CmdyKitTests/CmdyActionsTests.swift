import Foundation
import XCTest
@testable import CmdyKit

final class CmdyActionsTests: XCTestCase {
    func testManifestResolvesInputsContextAndWorkflowSteps() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let actionDirectory = root.appendingPathComponent("deploy")
        try FileManager.default.createDirectory(at: actionDirectory,
                                                withIntermediateDirectories: true)
        let manifest = actionDirectory.appendingPathComponent("action.json")
        try Data("""
        {
          "manifestVersion": 1,
          "id": "project.deploy",
          "title": "Deploy Preview",
          "group": "Release",
          "shortcut": "cmd+shift+r",
          "confirmation": "Deploy {{input.environment}}?",
          "inputs": [
            {"id":"environment", "label":"Environment", "kind":"choice",
             "options":["staging","production"], "default":"staging"},
            {"id":"announce", "label":"Announce", "kind":"toggle", "default":"false"}
          ],
          "steps": [
            {"command":"deploy --to {{input.environment}}", "cwd":"project"},
            {"command":"notify --enabled {{input.announce}}", "pane":"right", "mode":"type"}
          ],
          "whenFiles": ["Package.swift"]
        }
        """.utf8).write(to: manifest)

        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data().write(to: project.appendingPathComponent("Package.swift"))
        let action = try CmdyActionCatalog.load(from: manifest, scope: .project(project))
        let context = CmdyActionContext(cwd: project.appendingPathComponent("Sources").path,
                                           projectRoot: project)

        XCTAssertEqual(action.shortcut?.display, "⇧⌘R")
        XCTAssertTrue(action.isAvailable(in: context))
        let steps = try action.resolve(in: context, values: [
            "environment": "production", "announce": "true",
        ])
        XCTAssertEqual(steps.map(\.pane), [.focused, .right])
        XCTAssertEqual(steps.map(\.mode), [.run, .type])
        XCTAssertTrue(steps[0].command.contains("cd -- '\(project.path)'"))
        XCTAssertTrue(steps[0].command.contains("deploy --to 'production'"))
        XCTAssertTrue(steps[0].command.contains("CMDY_ACTION_INPUT_ENVIRONMENT='production'"))
        XCTAssertTrue(steps[1].command.contains("notify --enabled 'true'"))
        XCTAssertTrue(action.guide.whatItDoes.contains(where: { $0.contains("2 shell") || $0.contains("runs 1 shell") }))
        XCTAssertTrue(action.guide.safety.contains(where: { $0.contains("confirmation") }))
        XCTAssertTrue(action.guide.setup.contains(where: { $0.contains("Environment") }))
    }

    func testManifestCanProvideFactualGuideCopy() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = root.appendingPathComponent("action.json")
        try Data("""
        {"manifestVersion":1,"id":"test.guide","title":"Guided","command":"true",
         "guide":{"whatItDoes":["Checks the current checkout."],
                  "safety":["Makes no network request."],
                  "setup":["No setup required."]}}
        """.utf8).write(to: manifest)

        let action = try CmdyActionCatalog.load(from: manifest)

        XCTAssertEqual(action.guide.whatItDoes, ["Checks the current checkout."])
        XCTAssertEqual(action.guide.safety, ["Makes no network request."])
        XCTAssertEqual(action.guide.setup, ["No setup required."])
    }

    func testEntrypointsCannotEscapeActionDirectory() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let actionDirectory = root.appendingPathComponent("escape")
        try FileManager.default.createDirectory(at: actionDirectory,
                                                withIntermediateDirectories: true)
        let manifest = actionDirectory.appendingPathComponent("action.json")
        try Data("""
        {"manifestVersion":1,"id":"bad.escape","title":"Escape","entrypoint":"../run.sh"}
        """.utf8).write(to: manifest)

        XCTAssertThrowsError(try CmdyActionCatalog.load(from: manifest)) { error in
            XCTAssertEqual(error as? CmdyActionError, .unsafePath("../run.sh"))
        }
    }

    func testDiscoverySupportsZeroConfigScriptsAndReportsBrokenManifests() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("clean-cache.sh")
        try "#!/bin/sh\ntrue\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        try Data("{}".utf8).write(to: root.appendingPathComponent("broken.json"))

        let discovery = CmdyActionCatalog.discover(in: root)

        XCTAssertEqual(discovery.actions.map(\.id), ["clean-cache"])
        XCTAssertEqual(discovery.actions.map(\.title), ["Clean Cache"])
        XCTAssertEqual(discovery.issues.count, 1)
    }

    func testSampleScaffoldRoundTrips() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("say-hello")

        let manifest = try CmdyActionCatalog.createSample(at: directory)
        let action = try CmdyActionCatalog.load(from: manifest)
        let resolved = try action.resolve(
            in: CmdyActionContext(cwd: root.path), values: [:])

        XCTAssertEqual(action.id, "say-hello")
        XCTAssertEqual(resolved.count, 1)
        XCTAssertTrue(resolved[0].command.contains("run.sh"))
    }

    func testStarterActionsInstallValidateAndNeverDuplicate() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try CmdyActionCatalog.installStarterActions(at: root)
        XCTAssertEqual(first.installed.count, 5)
        XCTAssertTrue(first.skipped.isEmpty)

        let discovery = CmdyActionCatalog.discover(in: root)
        XCTAssertTrue(discovery.issues.isEmpty)
        XCTAssertEqual(discovery.actions.count, 5)
        XCTAssertTrue(discovery.actions.allSatisfy {
            !$0.guide.whatItDoes.isEmpty && !$0.guide.safety.isEmpty && !$0.guide.setup.isEmpty
        })

        let cc = try XCTUnwrap(discovery.actions.first { $0.id == "personal.cc" })
        let ccSteps = try cc.resolve(in: CmdyActionContext(cwd: root.path), values: [:])
        XCTAssertTrue(ccSteps[0].command.contains("claude --continue"))

        let pulse = try XCTUnwrap(
            discovery.actions.first { $0.id == "personal.project-pulse" })
        XCTAssertEqual(pulse.steps.map(\.pane), [.right, .down])
        XCTAssertTrue(pulse.steps.allSatisfy { $0.mode == .run })

        let second = try CmdyActionCatalog.installStarterActions(at: root)
        XCTAssertTrue(second.installed.isEmpty)
        XCTAssertEqual(second.skipped.count, 5)
    }

    func testStarterActionsKeepAnExistingFolderUntouched() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("cc")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let note = existing.appendingPathComponent("mine.txt")
        try "do not replace".write(to: note, atomically: true, encoding: .utf8)

        let result = try CmdyActionCatalog.installStarterActions(at: root)

        XCTAssertEqual(result.installed.count, 4)
        XCTAssertEqual(result.skipped.map(\.id), ["personal.cc"])
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "do not replace")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: existing.appendingPathComponent("action.json").path))
    }

    func testUnknownAndOversizedInputsAreRejected() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let manifest = directory.appendingPathComponent("action.json")
        try Data("""
        {"manifestVersion":1,"id":"test.inputs","title":"Inputs",
         "command":"printf %s {{input.name}}",
         "inputs":[{"id":"name","label":"Name","required":true}]}
        """.utf8).write(to: manifest)
        let action = try CmdyActionCatalog.load(from: manifest)
        let context = CmdyActionContext(cwd: root.path)

        XCTAssertThrowsError(try action.resolve(
            in: context, values: ["name": "ok", "typo": "ignored"]))
        XCTAssertThrowsError(try action.resolve(
            in: context, values: ["name": String(repeating: "x", count: 16 * 1024 + 1)]))
    }

    func testSampleRejectsInvalidContentWithoutLeavingDirectory() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("invalid")

        XCTAssertThrowsError(try CmdyActionCatalog.createSample(
            at: directory, title: String(repeating: "x", count: 161)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertThrowsError(try CmdyActionCatalog.createSample(
            at: directory, command: "   "))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-action-tests-\(UUID().uuidString)")
    }
}
