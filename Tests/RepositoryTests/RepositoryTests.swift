import Foundation
import ProductIdentity
import XCTest

final class RepositoryTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testCanonicalProductIdentityIsUsable() {
        let identity = ProductIdentity.current
        XCTAssertEqual(identity.slug, "cmdy")
        XCTAssertEqual(identity.executableName, "cmdy")
        XCTAssertEqual(identity.githubRepository, "suprb/cmdy")
        XCTAssertTrue(identity.compatibleEnvironmentPrefixes.contains("TERMITE"))
    }

    func testPublicSchemasAreValidJSONObjects() throws {
        let schemaNames = [
            "action-manifest-v1.schema.json",
            "extension-manifest-v1.schema.json",
            "surface-v1.schema.json",
        ]
        for name in schemaNames {
            let data = try Data(contentsOf: repositoryRoot
                .appendingPathComponent("Schemas")
                .appendingPathComponent(name))
            let object = try JSONSerialization.jsonObject(with: data)
            XCTAssertNotNil(object as? [String: Any], "\(name) must contain a JSON object")
        }
    }

    func testPublicRepositoryDocumentsArePresent() {
        for name in [
            "LICENSE", "THIRD_PARTY_NOTICES.md", "SECURITY.md",
            "CODE_OF_CONDUCT.md", "CONTRIBUTING.md", "SUPPORT.md",
            "docs/ARCHITECTURE.md",
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: repositoryRoot.appendingPathComponent(name).path),
                "missing public repository document: \(name)")
        }
    }

    func testChromiumPayloadIsNeverAMachineLocalSymlink() throws {
        let payload = repositoryRoot
            .appendingPathComponent("Plugins/chromium/Frameworks")
        let values = try? payload.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertNotEqual(values?.isSymbolicLink, true)
    }
}
