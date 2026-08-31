import Foundation
import XCTest
@testable import CmdyKit

final class ExtensionProtocolTests: XCTestCase {
    func testVersionOneManifestRequiresAndScopesCapabilities() throws {
        let manifest = try ExtensionManifest.decode(Data("""
        {
          "manifestVersion": 1,
          "id": "dev.example.focus",
          "name": "Focus",
          "version": "1.2.0",
          "entrypoint": "bin/focus",
          "guide": {
            "whatItDoes": ["Groups focus events."],
            "safety": ["Cannot type into panes."],
            "setup": ["No setup required."]
          },
          "capabilities": ["events.read", "panes.manage"]
        }
        """.utf8))

        XCTAssertFalse(manifest.isLegacy)
        XCTAssertTrue(manifest.allows(.events))
        XCTAssertTrue(manifest.allows(.panesManage))
        XCTAssertFalse(manifest.allows(.panesType))
        XCTAssertEqual(manifest.guide?.whatItDoes, ["Groups focus events."])
        XCTAssertEqual(manifest.guide?.safety, ["Cannot type into panes."])
        XCTAssertEqual(try ExtensionManifest.decode(manifest.encoded()), manifest)
    }

    func testLegacyManifestKeepsCompatibilityWithoutPersistingFullGrant() throws {
        let manifest = try ExtensionManifest.decode(Data("""
        {"name":"Old Tool","exec":"run.sh","enabled":true}
        """.utf8), fallbackID: "old-tool")

        XCTAssertTrue(manifest.isLegacy)
        XCTAssertEqual(manifest.id, "local.old-tool")
        XCTAssertEqual(manifest.entrypoint, "run.sh")
        XCTAssertEqual(manifest.effectiveCapabilities, ExtensionManifest.legacyCapabilities)
        XCTAssertFalse(manifest.allows(.channels))
    }

    func testChannelCapabilityDoesNotImplyExecutionAuthority() throws {
        let manifest = try ExtensionManifest(
            id: "dev.example.channel", name: "Channel", entrypoint: "run",
            capabilities: [.channels, .events])

        XCTAssertTrue(manifest.allows(.channels))
        XCTAssertTrue(manifest.allows(.events))
        XCTAssertFalse(manifest.allows(.panesType))
        XCTAssertFalse(manifest.allows(.panesManage))
        XCTAssertFalse(manifest.allows(.commands))
    }

    func testHostedComponentRoundTripsWithoutBroadeningCapabilities() throws {
        let manifest = try ExtensionManifest(
            id: "dev.cmdy.chromium", name: "Browser",
            entrypoint: "chromium", capabilities: [.commands],
            hostComponent: "embedded-chromium")

        let decoded = try ExtensionManifest.decode(manifest.encoded())
        XCTAssertEqual(decoded.hostComponent, "embedded-chromium")
        XCTAssertEqual(decoded.entrypoint, "chromium")
        XCTAssertTrue(decoded.allows(.commands))
        XCTAssertFalse(decoded.allows(.companion))
    }

    func testManifestRejectsUnknownCapabilityAndPathTraversal() {
        XCTAssertThrowsError(try ExtensionManifest.decode(Data("""
        {"manifestVersion":1,"id":"dev.example.bad","name":"Bad","version":"1.0.0",
         "entrypoint":"run","capabilities":["filesystem.everything"]}
        """.utf8)))

        XCTAssertThrowsError(try ExtensionManifest(
            id: "dev.example.bad", name: "Bad", entrypoint: "../run",
            capabilities: [])) { error in
                XCTAssertEqual(error as? ExtensionManifestError,
                               .unsafeEntrypoint("../run"))
            }
    }

    func testProjectDiscoveryStopsAtNearestMarker() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let extensionDirectory = project.appendingPathComponent(".cmdy/extensions/demo")
        let nested = project.appendingPathComponent("Sources/Deep")
        try FileManager.default.createDirectory(at: extensionDirectory,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let manifest = try ExtensionManifest(
            id: "dev.example.demo", name: "Demo", entrypoint: "run.sh",
            capabilities: [.events])
        try manifest.encoded().write(to: extensionDirectory.appendingPathComponent("manifest.json"))

        XCTAssertEqual(ProjectExtensionDiscovery.projectRoot(containing: nested)?.path,
                       project.path)
        let found = try ProjectExtensionDiscovery.extensions(in: project)
        XCTAssertEqual(found.map(\.manifest.id), ["dev.example.demo"])
    }

    func testTrustLivesOutsideTheProjectAndCanBeRevoked() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ExtensionTrustStore(url: root.appendingPathComponent("state/trust.json"))
        let project = root.appendingPathComponent("project")

        XCTAssertFalse(store.isTrusted(project))
        try store.trust(project)
        XCTAssertTrue(store.isTrusted(project))
        XCTAssertEqual(store.trustedProjects(), [project.path])
        try store.revoke(project)
        XCTAssertFalse(store.isTrusted(project))
    }

    func testProjectExtensionDirectoryCannotEscapeThroughASymlink() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let extensions = project.appendingPathComponent(".cmdy/extensions")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let manifest = try ExtensionManifest(
            id: "dev.example.escape", name: "Escape", entrypoint: "run.sh",
            capabilities: [])
        try manifest.encoded().write(to: outside.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(
            at: extensions.appendingPathComponent("escape"), withDestinationURL: outside)

        XCTAssertThrowsError(try ProjectExtensionDiscovery.extensions(in: project))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-extension-tests-\(UUID().uuidString)")
    }
}
