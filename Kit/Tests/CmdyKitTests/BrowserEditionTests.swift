import XCTest
@testable import CmdyKit

final class BrowserEditionTests: XCTestCase {
    func testCanonicalDownloadUsesStableSignedBrowserEditionAlias() {
        XCTAssertEqual(
            BrowserEdition.downloadURL().absoluteString,
            "https://github.com/suprb/cmdy/releases/latest/download/"
                + "cmdy-browser-macOS-arm64.dmg")
    }

    func testBrowserRowStateCoversEveryDistributionAndLegacyCombination() {
        for hasExternalInstall in [false, true] {
            XCTAssertEqual(
                BrowserEdition.rowState(
                    distribution: .bundled,
                    hasExternalInstall: hasExternalInstall),
                .included)
        }
        for distribution in [
            HostComponentDistribution.unavailable,
            HostComponentDistribution.external,
        ] {
            XCTAssertEqual(
                BrowserEdition.rowState(
                    distribution: distribution, hasExternalInstall: false),
                .notInstalled)
            XCTAssertNil(BrowserEdition.rowState(
                distribution: distribution, hasExternalInstall: true))
        }
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
