// swift-tools-version:5.9
import PackageDescription
import Foundation

private struct IdentityManifest: Decodable {
    let name: String
}

private let identityURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent(
        "Identity/Sources/ProductIdentity/Resources/product-identity.json")
private let identity = try! JSONDecoder().decode(
    IdentityManifest.self, from: Data(contentsOf: identityURL))
private let executableName = identity.name.lowercased()
    .replacingOccurrences(
        of: "[^a-z0-9]+", with: "-", options: .regularExpression)
    .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

let package = Package(
    name: executableName,
    platforms: [
        // macOS 26: required by Foundation Models and the native split APIs
        // used by the current app shell.
        .macOS("26.0")
    ],
    // The public executable follows the canonical product identity. The app
    // module uses that identity as well; no retired product name leaks into
    // the active package graph.
    products: [
        .executable(name: executableName, targets: ["CmdyApp"])
    ],
    dependencies: [
        .package(path: "Core"),      // CmdyCore engine + CmdyPTY + lib_cmdy
        .package(path: "Renderer"),  // CmdyGPU — the Metal pipeline
        .package(path: "Kit"),       // CmdyKit — the platform layer
        .package(path: "Identity"),  // public product identity
        .package(path: "Plugins/chromium/Support"),
    ],
    targets: [
        .executableTarget(
            name: "CmdyApp",
            dependencies: [
                .product(name: "CmdyCore", package: "Core"),
                .product(name: "CmdyPTY", package: "Core"),
                .product(name: "CmdyGPU", package: "Renderer"),
                .product(name: "CmdyKit", package: "Kit"),
                .product(name: "ProductIdentity", package: "Identity"),
                .product(name: "ChromiumSupport", package: "Support"),
            ],
            path: "App"
        ),
        .testTarget(
            name: "RepositoryTests",
            dependencies: [
                .product(name: "ProductIdentity", package: "Identity"),
            ],
            path: "Tests/RepositoryTests"
        )
    ]
)
