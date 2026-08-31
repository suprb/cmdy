// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "detox",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../CmdySDK")
    ],
    targets: [
        .executableTarget(
            name: "detox",
            dependencies: ["CmdySDK"],
            resources: [.copy("Detox")]
        )
    ]
)
