import XCTest
@testable import CmdyKit

final class BrowserEditionTests: XCTestCase {
    func testOnlyCanonicalBrowserManifestCanActivateHostComponent() throws {
        let browser = try ExtensionManifest(
            id: BrowserEdition.marketplaceID,
            name: "Browser",
            version: "2.1.0",
            entrypoint: "browser-component",
            capabilities: [],
            hostComponent: BrowserEdition.hostComponentIdentifier)
        XCTAssertTrue(BrowserEdition.authorizesHostComponent(
            BrowserEdition.hostComponentIdentifier, manifest: browser))

        var impersonator = browser
        impersonator.id = "dev.example.impersonator"
        XCTAssertFalse(BrowserEdition.authorizesHostComponent(
            BrowserEdition.hostComponentIdentifier, manifest: impersonator))
        XCTAssertFalse(BrowserEdition.authorizesHostComponent(
            "unknown-host-component", manifest: browser))
    }

    func testBrowserUsesStableMarketplaceExtensionIdentity() {
        XCTAssertEqual(BrowserEdition.marketplaceID, "dev.termite.chromium")
        XCTAssertTrue(BrowserEdition.guide.plainText.contains("real split inside"))
        XCTAssertTrue(BrowserEdition.guide.plainText.contains("visible browser is built into"))
        XCTAssertTrue(BrowserEdition.guide.plainText.contains("remove Browser"))
    }

    func testConfigTemplateDoesNotOfferRetiredBootBanner() {
        XCTAssertNil(ConfigFile.parse(ConfigFile.template())["banner"])
    }

    func testEditingMigratesRetiredBannerAndPreservesCustomSettings() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "cmdy-banner-migration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let environmentKey = "CMDY_CONFIG_DIR"
        let previous = getenv(environmentKey).map { String(cString: $0) }
        setenv(environmentKey, root.path, 1)
        defer {
            if let previous { setenv(environmentKey, previous, 1) }
            else { unsetenv(environmentKey) }
        }

        let original = ConfigFile.template()
            + "\nbanner = true\ncustom-release-note = preserved\n"
        try original.write(to: ConfigFile.url, atomically: true, encoding: .utf8)
        _ = ConfigFile.prepareForEditing()

        let migrated = try String(contentsOf: ConfigFile.url, encoding: .utf8)
        let backup = try String(
            contentsOf: ConfigFile.url.appendingPathExtension("bak"),
            encoding: .utf8)
        XCTAssertNil(ConfigFile.parse(migrated)["banner"])
        XCTAssertEqual(
            ConfigFile.parse(migrated)["custom-release-note"], "preserved")
        XCTAssertEqual(backup, original)
    }
}
