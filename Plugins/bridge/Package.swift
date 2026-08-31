// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "bridge",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../CmdySDK"),
        .package(path: "../../Vendor/BraincellBridge"),
    ],
    targets: [
        .executableTarget(
            name: "bridge",
            dependencies: [
                "CmdySDK",
                .product(name: "BraincellBridgeKit", package: "BraincellBridge"),
            ]
        )
    ]
)
