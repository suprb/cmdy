// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CmdySDK",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CmdySDK", targets: ["CmdySDK"])
    ],
    dependencies: [
        .package(path: "../../Identity"),
    ],
    targets: [
        .target(
            name: "CmdySDK",
            dependencies: [
                .product(name: "ProductIdentity", package: "Identity"),
            ],
            sources: ["CmdySDK.swift", "Surfaces.swift", "Feedback.swift",
                      "Channels.swift", "Workspace.swift"]
        ),
        .testTarget(name: "CmdySDKTests", dependencies: ["CmdySDK"])
    ]
)
