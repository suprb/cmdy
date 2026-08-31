// swift-tools-version:6.0
import PackageDescription

// cmdy Bridge engine, packaged as a library so the
// engine (HTTP server on 3457, MCP runtime, the Chrome / Mac App / iOS
// Simulator / Native App adapters — the 93 tools) runs inside cmdy's
// process as part of the Bridge plugin. main.swift is excluded; its
// single-instance/orphan-cleanup logic lives in BridgeEngine.start().

let package = Package(
    name: "BraincellBridge",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "BraincellBridgeKit", targets: ["BraincellBridgeKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(path: "../../Identity"),
    ],
    targets: [
        .target(
            name: "BraincellBridgeKit",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "ProductIdentity", package: "Identity"),
            ],
            path: "Sources/BraincellBridge",
            resources: [
                .copy("Resources/mcp"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(
            name: "BraincellBridgeKitTests",
            dependencies: ["BraincellBridgeKit"],
            path: "Tests/BraincellBridgeKitTests"
        ),
    ]
)
