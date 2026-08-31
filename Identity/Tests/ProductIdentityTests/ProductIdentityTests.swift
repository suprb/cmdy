import XCTest
@testable import ProductIdentity

final class ProductIdentityTests: XCTestCase {
    func testResourceBundleLocatorFindsSwiftPMIdentityResources() throws {
        let bundle = try XCTUnwrap(ProductResourceBundle.bundle(
            named: "ProductIdentity_ProductIdentity"))
        XCTAssertNotNil(bundle.url(
            forResource: "product-identity", withExtension: "json"))
    }

    func testCurrentIdentityDerivesEveryRenameableSurfaceFromName() {
        let identity = ProductIdentity.current

        XCTAssertEqual(identity.name, "cmdy")
        XCTAssertEqual(identity.displayName, "cmdy")
        XCTAssertEqual(identity.titleName, "cmdy")
        XCTAssertEqual(identity.slug, "cmdy")
        XCTAssertEqual(identity.executableName, "cmdy")
        XCTAssertEqual(identity.appBundleName, "cmdy.app")
        XCTAssertEqual(identity.configurationDirectoryName, "cmdy")
        XCTAssertEqual(identity.projectDirectoryName, ".cmdy")
        XCTAssertEqual(identity.environmentPrefix, "CMDY")
        XCTAssertEqual(identity.mcpServerName("browser"), "cmdy-browser")
        XCTAssertEqual(
            identity.compatibleMCPServerNames("browser"),
            ["cmdy-browser", "termite-browser", "term64-browser"])
        XCTAssertEqual(identity.releaseAssetPrefix, "cmdy")
        XCTAssertEqual(identity.githubRepository, "suprb/cmdy")
        XCTAssertEqual(identity.marketplaceRepositoryName, "cmdy-registry")
        XCTAssertEqual(
            identity.compatibleMarketplaceRepositoryNames,
            ["cmdy-registry", "termite-registry", "term64-registry"])
        XCTAssertEqual(
            identity.compatibleMarketplaceRegistryURLs.map(\.absoluteString),
            [
                "https://raw.githubusercontent.com/suprb/cmdy-registry/main/registry.json",
                "https://raw.githubusercontent.com/suprb/termite-registry/main/registry.json",
                "https://raw.githubusercontent.com/suprb/term64-registry/main/registry.json",
            ])
    }

    func testLegacyNamesProvideConfigAndEnvironmentCompatibility() {
        let identity = ProductIdentity.current
        let home = URL(fileURLWithPath: "/tmp/example-home", isDirectory: true)

        XCTAssertEqual(
            identity.compatibleEnvironmentPrefixes,
            ["CMDY", "TERMITE", "TERM64"])
        XCTAssertEqual(
            identity.legacyConfigurationDirectories(homeDirectory: home).map(\.path),
            [
                "/tmp/example-home/.config/termite",
                "/tmp/example-home/.config/term64",
            ])
        XCTAssertEqual(
            identity.environmentValue(
                "TOKEN", in: [
                    "TERM64_TOKEN": "old",
                    "TERMITE_TOKEN": "newer",
                    "CMDY_TOKEN": "current",
                ]),
            "current")
        XCTAssertEqual(
            identity.environmentValue(
                "TOKEN", in: ["TERM64_TOKEN": "old", "TERMITE_TOKEN": "new"]),
            "new")
        XCTAssertEqual(
            identity.environmentValue("TOKEN", in: ["TERM64_TOKEN": "old"]),
            "old")
        XCTAssertEqual(identity.legacyProjectDirectoryNames, [".termite", ".term64"])
    }

    func testSlugAndEnvironmentPrefixAreDeterministic() {
        XCTAssertEqual(ProductIdentity.slug(for: "Gravity TTY"), "gravity-tty")
        XCTAssertEqual(
            ProductIdentity.environmentPrefix(for: "gravity-tty"),
            "GRAVITY_TTY")
    }

    func testOneNameChangeFlowsAcrossAllPublicSurfaces() {
        let identity = ProductIdentity(
            name: "Gravitty",
            repositoryOwner: "example",
            bundleIdentifier: "com.cmdy.app",
            extensionIdentifierNamespace: "dev.cmdy",
            codeSigningIdentifierNamespace: "com.cmdy",
            legacyNames: ["termite", "term64"])

        XCTAssertEqual(identity.displayName, "Gravitty")
        XCTAssertEqual(identity.executableName, "gravitty")
        XCTAssertEqual(identity.appBundleName, "gravitty.app")
        XCTAssertEqual(identity.configurationDirectoryName, "gravitty")
        XCTAssertEqual(identity.projectDirectoryName, ".gravitty")
        XCTAssertEqual(identity.environmentPrefix, "GRAVITTY")
        XCTAssertEqual(identity.mcpServerName("browser"), "gravitty-browser")
        XCTAssertEqual(identity.githubRepository, "example/gravitty")
        XCTAssertEqual(identity.marketplaceRepositoryName, "gravitty-registry")
        XCTAssertEqual(identity.releaseAssetPrefix, "gravitty")
        XCTAssertEqual(identity.bundleIdentifier, "com.cmdy.app")
        XCTAssertEqual(
            identity.compatibleEnvironmentPrefixes,
            ["GRAVITTY", "TERMITE", "TERM64"])
    }
}
