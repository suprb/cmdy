import Foundation
import CryptoKit
import XCTest
@testable import CmdyKit

final class MarketplaceVersionTests: XCTestCase {
    func testShareablePackageIsInspectedBeforeInstall() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-package-inspection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = try makeNativeArchive(in: root, id: "dev.example.shared")

        let package = try Marketplace.prepareExtensionPackage(from: archive)

        XCTAssertEqual(package.manifest.id, "dev.example.shared")
        XCTAssertEqual(package.manifest.name, "Native")
        XCTAssertEqual(package.manifest.capabilities, [.events])
        XCTAssertEqual(package.sha256, try sha256(of: archive))
        XCTAssertEqual(package.archiveByteCount, try Data(contentsOf: archive).count)

        let legacyName = root.appendingPathComponent("legacy.zip")
        try FileManager.default.copyItem(at: archive, to: legacyName)
        XCTAssertThrowsError(
            try Marketplace.prepareExtensionPackage(from: legacyName)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains(".cmdyext"))
        }
    }

    func testShareablePackageRejectsDuplicateArchivePaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-package-duplicate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("duplicate.cmdyext")
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        writer.arguments = [
            "python3", "-c",
            "import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],'w'); "
                + "z.writestr('duplicate/manifest.json','{}'); "
                + "z.writestr('duplicate/manifest.json','{}'); z.close()",
            archive.path,
        ]
        writer.standardOutput = FileHandle.nullDevice
        writer.standardError = FileHandle.nullDevice
        try writer.run()
        writer.waitUntilExit()
        XCTAssertEqual(writer.terminationStatus, 0)

        XCTAssertThrowsError(
            try Marketplace.prepareExtensionPackage(from: archive)
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("duplicate path"),
                error.localizedDescription)
        }
    }

    func testInstallLinksAcceptOnlySafeMarketplaceIDsAndHTTPSPackages() throws {
        XCTAssertEqual(
            Marketplace.extensionInstallRequest(
                from: URL(string: "cmdy://extension/install?id=dev.termite.chromium")!),
            .marketplace(id: "dev.termite.chromium"))

        var components = URLComponents(string: "cmdy://extension/install")!
        components.queryItems = [
            URLQueryItem(
                name: "url",
                value: "https://example.com/releases/tool-1.0.0.cmdyext"),
        ]
        XCTAssertEqual(
            Marketplace.extensionInstallRequest(from: try XCTUnwrap(components.url)),
            .package(URL(string: "https://example.com/releases/tool-1.0.0.cmdyext")!))
        XCTAssertNil(Marketplace.extensionInstallRequest(
            from: URL(string: "cmdy://extension/install?id=../escape")!))

        components.queryItems = [
            URLQueryItem(name: "url", value: "http://example.com/tool.cmdyext"),
        ]
        XCTAssertNil(Marketplace.extensionInstallRequest(
            from: try XCTUnwrap(components.url)))
        components.queryItems = [
            URLQueryItem(name: "url", value: "https://example.com/tool.zip"),
        ]
        XCTAssertNil(Marketplace.extensionInstallRequest(
            from: try XCTUnwrap(components.url)))
    }

    func testNestedAppEntrypointIsRecognizedAsOneSignedUnit() throws {
        let root = URL(fileURLWithPath: "/tmp/cmdy-extension-test/chromium")
        let executable = root.appendingPathComponent(
            "cmdy Browser.app/Contents/MacOS/cmdy Browser")
        XCTAssertEqual(
            Marketplace.enclosingAppBundle(for: executable, inside: root)?.path,
            root.appendingPathComponent("cmdy Browser.app").path)
        XCTAssertNil(Marketplace.enclosingAppBundle(
            for: root.appendingPathComponent("bin/browser"), inside: root))
        XCTAssertNil(Marketplace.enclosingAppBundle(
            for: root.deletingLastPathComponent().appendingPathComponent(
                "Outside.app/Contents/MacOS/outside"),
            inside: root))
    }

    func testDefaultRegistryIncludesPublishedLegacyFallbacks() {
        XCTAssertEqual(
            Marketplace.registryURLs(
                configured: Preferences.defaultMarketplaceRegistry)
                .map(\.absoluteString),
            [
                "https://raw.githubusercontent.com/suprb/cmdy-registry/main/registry.json",
                "https://raw.githubusercontent.com/suprb/termite-registry/main/registry.json",
                "https://raw.githubusercontent.com/suprb/term64-registry/main/registry.json",
            ])
    }

    func testExplicitRegistryDoesNotFallBack() {
        XCTAssertEqual(
            Marketplace.registryURLs(override: "/tmp/custom-registry.json")
                .map(\.path),
            ["/tmp/custom-registry.json"])
    }

    func testRelativeContentUsesEntrySourceRegistry() throws {
        let source = URL(string: "https://example.test/legacy/registry.json")!
        let entry = try XCTUnwrap(Marketplace.Entry([
            "kind": "theme",
            "id": "example/theme",
            "name": "Example",
            "file": "themes/example.json",
        ], sourceRegistryURL: source))
        XCTAssertEqual(entry.sourceRegistryURL, source)
    }

    func testNumericVersionsDetectOnlyNewerRegistryReleases() {
        XCTAssertTrue(Marketplace.isVersion("1.0.1", newerThan: "1.0.0"))
        XCTAssertTrue(Marketplace.isVersion("1.10.0", newerThan: "1.9.9"))
        XCTAssertFalse(Marketplace.isVersion("1.0.0", newerThan: "1.0.0"))
        XCTAssertFalse(Marketplace.isVersion("1.9.0", newerThan: "2.0.0"))
    }

    func testChannelMarketplaceKindUsesExtensionPipeline() {
        XCTAssertTrue(Marketplace.isExtensionKind("plugin"))
        XCTAssertTrue(Marketplace.isExtensionKind("channel"))
        XCTAssertFalse(Marketplace.isExtensionKind("theme"))
    }

    func testNativeArchiveDigestMustBePresentAndWellFormedBeforeFetch() throws {
        for (value, label) in [(nil, "missing"), ("abc", "malformed")] as [(String?, String)] {
            var json: [String: Any] = [
                "kind": "plugin", "id": "dev.example.\(label)", "name": "Native",
                "version": "1.0.0", "url": "file:///definitely-not-present.zip",
            ]
            if let value { json["sha256"] = value }
            let entry = try XCTUnwrap(Marketplace.Entry(json))
            XCTAssertThrowsError(try Marketplace.installPlugin(
                entry, consented: true, progress: { _ in })) { error in
                XCTAssertTrue(error.localizedDescription.contains("archive sha256"))
                XCTAssertTrue(error.localizedDescription.contains("64-character hexadecimal"))
            }
        }
    }

    func testNativeArchiveDigestAcceptsUppercaseAndRejectsMismatch() throws {
        let uppercase = String(repeating: "A", count: 64)
        XCTAssertEqual(
            try Marketplace.requiredSHA256(uppercase, field: "archive"),
            String(repeating: "a", count: 64))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-marketplace-digest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("native.cmdyext")
        try Data("not the pinned archive".utf8).write(to: archive)
        let entry = try XCTUnwrap(Marketplace.Entry([
            "kind": "plugin", "id": "dev.example.mismatch", "name": "Native",
            "version": "1.0.0", "url": archive.absoluteString,
            "sha256": String(repeating: "0", count: 64),
        ]))
        XCTAssertThrowsError(try Marketplace.installPlugin(
            entry, consented: true, progress: { _ in })) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("sha256 mismatch"),
                error.localizedDescription)
        }
    }

    func testNativePayloadDigestMustBePresentAndWellFormedBeforeFetch() throws {
        let cases: [[String: Any]] = [
            ["url": "file:///definitely-not-present-payload.zip"],
            ["url": "file:///definitely-not-present-payload.zip", "sha256": "abc"],
        ]
        for (index, payload) in cases.enumerated() {
            let entry = try XCTUnwrap(Marketplace.Entry([
                "kind": "plugin", "id": "dev.example.payload.\(index)", "name": "Native",
                "version": "1.0.0", "url": "file:///definitely-not-present.zip",
                "sha256": String(repeating: "0", count: 64),
                "payload": payload,
            ]))
            XCTAssertThrowsError(try Marketplace.installPlugin(
                entry, consented: true, progress: { _ in })) { error in
                XCTAssertTrue(error.localizedDescription.contains("payload"))
                XCTAssertTrue(
                    error.localizedDescription.contains("requires url and sha256")
                        || error.localizedDescription.contains("64-character hexadecimal"))
            }
        }
    }

    func testNativePayloadDigestMismatchIsRejectedBeforeAssembly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-marketplace-payload-digest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = try makeNativeArchive(in: root, id: "dev.example.payload-mismatch")
        let payload = root.appendingPathComponent("payload.zip")
        try Data("not the pinned payload".utf8).write(to: payload)
        let entry = try XCTUnwrap(Marketplace.Entry([
            "kind": "plugin", "id": "dev.example.payload-mismatch", "name": "Native",
            "version": "1.0.0", "url": archive.absoluteString,
            "sha256": try sha256(of: archive),
            "payload": [
                "url": payload.absoluteString,
                "sha256": String(repeating: "0", count: 64),
            ],
        ]))

        XCTAssertThrowsError(try Marketplace.installPlugin(
            entry, consented: true, progress: { _ in })) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("sha256 mismatch"),
                error.localizedDescription)
        }
    }

    func testChannelMarketplaceEntryRequiresChannelManifestGrant() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-channel-marketplace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("channel-bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let manifest = try ExtensionManifest(
            id: "dev.example.channel", name: "Channel", version: "1.0.0",
            entrypoint: "run.sh", capabilities: [.events])
        try manifest.encoded().write(to: bundle.appendingPathComponent("manifest.json"))
        let executable = bundle.appendingPathComponent("run.sh")
        try "#!/bin/sh\nexit 0\n".write(
            to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let archive = root.appendingPathComponent("channel.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", bundle.path, archive.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        var archiveDigest = try sha256(of: archive)
        var entry = try XCTUnwrap(Marketplace.Entry([
            "kind": "channel", "id": "dev.example.channel", "name": "Channel",
            "version": "1.0.0", "url": archive.absoluteString,
            "sha256": archiveDigest,
        ]))

        XCTAssertThrowsError(try Marketplace.installPlugin(
            entry, consented: true, progress: { _ in })) { error in
            XCTAssertTrue(error.localizedDescription.contains("channels capability"))
        }

        try FileManager.default.removeItem(at: archive)
        let legacy: [String: Any] = ["name": "Channel", "exec": "run.sh"]
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        try legacyData.write(to: bundle.appendingPathComponent("manifest.json"))
        let legacyArchive = Process()
        legacyArchive.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        legacyArchive.arguments = ["-c", "-k", "--keepParent", bundle.path, archive.path]
        try legacyArchive.run()
        legacyArchive.waitUntilExit()
        XCTAssertEqual(legacyArchive.terminationStatus, 0)
        archiveDigest = try sha256(of: archive)
        entry = try XCTUnwrap(Marketplace.Entry([
            "kind": "channel", "id": "dev.example.channel", "name": "Channel",
            "version": "1.0.0", "url": archive.absoluteString,
            "sha256": archiveDigest,
        ]))
        XCTAssertThrowsError(try Marketplace.installPlugin(
            entry, consented: true, progress: { _ in })) { error in
            XCTAssertTrue(error.localizedDescription.contains("v1 Extension manifest"))
        }
    }

    func testExtensionSourceMetadataAcceptsCanonicalAndLegacyKeys() {
        let base: [String: Any] = [
            "kind": "plugin", "id": "dev.example.tool", "name": "Tool",
        ]
        XCTAssertEqual(Marketplace.Entry(base.merging([
            "homepage": "https://example.com/tool",
        ]) { _, new in new })?.homepage, "https://example.com/tool")
        XCTAssertEqual(Marketplace.Entry(base.merging([
            "repository": "https://github.com/example/tool",
        ]) { _, new in new })?.homepage, "https://github.com/example/tool")
        XCTAssertEqual(Marketplace.Entry(base.merging([
            "repo": "https://codeberg.org/example/tool",
        ]) { _, new in new })?.homepage, "https://codeberg.org/example/tool")
    }

    func testChannelEntryPreservesSetupMetadata() throws {
        let entry = try XCTUnwrap(Marketplace.Entry([
            "kind": "channel", "id": "dev.example.channel", "name": "Channel",
            "mode": "two-way", "setup": "Bot token + room allowlist",
            "configuration": [
                "version": 1,
                "fields": [
                    ["key": "token", "label": "Bot token", "type": "secret",
                     "required": true, "keychainService": "cmdy.example"],
                    ["key": "rooms", "label": "Rooms", "type": "string-list",
                     "required": true, "placeholder": "one, two"],
                    ["key": "enabled", "label": "Enabled", "type": "boolean",
                     "required": true, "default": true],
                ],
            ],
        ]))
        XCTAssertEqual(entry.channelMode, "two-way")
        XCTAssertEqual(entry.setup, "Bot token + room allowlist")
        XCTAssertEqual(entry.channelConfigurationVersion, 1)
        XCTAssertEqual(entry.channelSetupFields.map(\.key), ["token", "rooms", "enabled"])
        XCTAssertEqual(entry.channelSetupFields[0].kind, .secret)
        XCTAssertEqual(entry.channelSetupFields[0].keychainService, "cmdy.example")
        XCTAssertEqual(entry.channelSetupFields[1].kind, .stringList)
        XCTAssertEqual(entry.channelSetupFields[2].defaultValue, "true")
    }

    func testExtensionUpdatePreservesPrivateConfigAndEnabledState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-marketplace-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("existing")
        let staged = root.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let oldManifest = try JSONSerialization.data(withJSONObject: ["enabled": false])
        try oldManifest.write(to: existing.appendingPathComponent("manifest.json"))
        let privateConfig = Data("{\"room\":\"ops\"}\n".utf8)
        try privateConfig.write(to: existing.appendingPathComponent("config.json"))
        var manifest: [String: Any] = ["enabled": true]

        try Marketplace.preserveLocalExtensionState(
            from: existing, into: staged, manifest: &manifest)

        XCTAssertEqual(manifest["enabled"] as? Bool, false)
        let copied = staged.appendingPathComponent("config.json")
        XCTAssertEqual(try Data(contentsOf: copied), privateConfig)
        let attributes = try FileManager.default.attributesOfItem(atPath: copied.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testExtensionUpdateRefusesSymlinkedConfig() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-marketplace-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("existing")
        let staged = root.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: existing.appendingPathComponent("config.json"),
            withDestinationURL: outside)
        var manifest: [String: Any] = ["enabled": true]

        XCTAssertThrowsError(try Marketplace.preserveLocalExtensionState(
            from: existing, into: staged, manifest: &manifest)) { error in
            XCTAssertTrue(error.localizedDescription.contains("safe bounded file"))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: staged.appendingPathComponent("config.json").path))
    }

    func testPayloadAssemblyAllowsOnlyContainedTemporarySymlinks() throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-marketplace-payload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let extensionRoot = staging.appendingPathComponent("browser")
        try FileManager.default.createDirectory(
            at: extensionRoot, withIntermediateDirectories: true)
        let link = extensionRoot.appendingPathComponent("libEGL.dylib")
        let target = "Frameworks/Chromium Embedded Framework.framework/Libraries/libEGL.dylib"
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: target)

        XCTAssertNoThrow(try Marketplace.validateExtractedTree(
            extensionRoot, inside: staging, allowDanglingSymlinks: true))
        XCTAssertThrowsError(try Marketplace.validateExtractedTree(
            extensionRoot, inside: staging)) { error in
            XCTAssertTrue(error.localizedDescription.contains("dangling symlink"))
        }

        let targetURL = extensionRoot.appendingPathComponent(target)
        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("library".utf8).write(to: targetURL)
        XCTAssertNoThrow(try Marketplace.validateExtractedTree(
            extensionRoot, inside: staging))
    }

    func testPayloadAssemblyStillRejectsSymlinkEscapes() throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-marketplace-escape-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let extensionRoot = staging.appendingPathComponent("browser")
        try FileManager.default.createDirectory(
            at: extensionRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: extensionRoot.appendingPathComponent("escape").path,
            withDestinationPath: "../../outside")

        XCTAssertThrowsError(try Marketplace.validateExtractedTree(
            extensionRoot, inside: staging, allowDanglingSymlinks: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("outside its folder"))
        }
    }

    func testRegistryIDsBecomeSafeLocalPathComponents() throws {
        let entry = try XCTUnwrap(Marketplace.Entry([
            "kind": "theme",
            "id": "../../odd/theme",
            "name": "Odd",
        ]))

        XCTAssertFalse(entry.stem.contains("/"))
        XCTAssertFalse(entry.stem.contains(".."))
        XCTAssertFalse(entry.folderName.contains("/"))
        XCTAssertFalse(entry.folderName.contains(".."))
    }

    func testMarketplaceGuideUsesRegistryCopyAndFirstPartyFallback() throws {
        let custom = try XCTUnwrap(Marketplace.Entry([
            "kind": "plugin", "id": "dev.example.guide", "name": "Guide",
            "guide": [
                "whatItDoes": ["Adds one command."],
                "safety": ["Makes no network requests."],
                "setup": ["Enable it."],
            ],
        ]))
        XCTAssertEqual(custom.guide.whatItDoes, ["Adds one command."])

        let message = try XCTUnwrap(Marketplace.Entry([
            "kind": "channel", "id": "dev.cmdy.imessage", "name": "iMessage",
            "description": "Messages connector", "mode": "two-way",
        ]))
        XCTAssertTrue(message.guide.whatItDoes.contains(where: { $0.contains("Messages database") }))
        XCTAssertTrue(message.guide.safety.contains(where: { $0.contains("SQLite read-only") }))
    }

    func testUpdateScheduleRequiresReceiptsAndWaitsOneDay() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertFalse(MarketplaceUpdateMonitor.shouldCheck(
            enabled: false, hasReceipts: true, lastCheck: nil, now: now))
        XCTAssertFalse(MarketplaceUpdateMonitor.shouldCheck(
            enabled: true, hasReceipts: false, lastCheck: nil, now: now))
        XCTAssertTrue(MarketplaceUpdateMonitor.shouldCheck(
            enabled: true, hasReceipts: true, lastCheck: nil, now: now))
        XCTAssertFalse(MarketplaceUpdateMonitor.shouldCheck(
            enabled: true, hasReceipts: true,
            lastCheck: now.addingTimeInterval(-23 * 60 * 60), now: now))
        XCTAssertTrue(MarketplaceUpdateMonitor.shouldCheck(
            enabled: true, hasReceipts: true,
            lastCheck: now.addingTimeInterval(-25 * 60 * 60), now: now))
    }

    func testUpdateSignatureIsStableAndVersionSensitive() throws {
        let first = try XCTUnwrap(Marketplace.Entry([
            "kind": "plugin", "id": "dev.example.first", "name": "First",
            "version": "2.0.0",
        ]))
        let second = try XCTUnwrap(Marketplace.Entry([
            "kind": "plugin", "id": "dev.example.second", "name": "Second",
            "version": "1.5.0",
        ]))
        XCTAssertEqual(
            MarketplaceUpdateMonitor.signature(for: [second, first]),
            MarketplaceUpdateMonitor.signature(for: [first, second]))
        XCTAssertEqual(
            MarketplaceUpdateMonitor.notificationBody(for: [first]),
            "First 2.0.0 is ready. Open Extensions to update.")

        let newer = try XCTUnwrap(Marketplace.Entry([
            "kind": "plugin", "id": "dev.example.first", "name": "First",
            "version": "2.1.0",
        ]))
        XCTAssertNotEqual(
            MarketplaceUpdateMonitor.signature(for: [first]),
            MarketplaceUpdateMonitor.signature(for: [newer]))
    }

    private func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func makeNativeArchive(in root: URL, id: String) throws -> URL {
        let bundle = root.appendingPathComponent("native-bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let manifest = try ExtensionManifest(
            id: id, name: "Native", version: "1.0.0",
            entrypoint: "run.sh", capabilities: [.events])
        try manifest.encoded().write(to: bundle.appendingPathComponent("manifest.json"))
        let executable = bundle.appendingPathComponent("run.sh")
        try "#!/bin/sh\nexit 0\n".write(
            to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let archive = root.appendingPathComponent("native.cmdyext")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", bundle.path, archive.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return archive
    }
}
