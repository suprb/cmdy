// swift-tools-version:5.9
import PackageDescription

// The Browser transport, start page, and semantic feedback script have no CEF
// dependency. Keeping them in a standalone package lets CI exercise real
// Chromium-sidecar behavior without downloading the framework payload.
let package = Package(
    name: "ChromiumSupport",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ChromiumSupport", targets: ["ChromiumSupport"]),
    ],
    dependencies: [
        .package(path: "../../CmdySDK"),
    ],
    targets: [
        .target(
            name: "ChromiumSupport",
            dependencies: ["CmdySDK"]),
        .testTarget(
            name: "ChromiumSupportTests",
            dependencies: ["ChromiumSupport", "CmdySDK"]),
    ]
)
