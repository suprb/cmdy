// swift-tools-version:5.9
import PackageDescription

// appdock — dock ANY app's window into cmdy as a split (the chromium
// sidecar pattern generalized): Accessibility moves the target's real window
// into the reserved strip, the terminal reflows around it, and an HTTP+MCP
// surface lets agents launch, relaunch, inspect (AX tree), and drive the app
// they are building.
let package = Package(
    name: "appdock",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../CmdySDK"),
    ],
    targets: [
        .executableTarget(name: "appdock", dependencies: ["CmdySDK"]),
    ]
)
