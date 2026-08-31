// swift-tools-version:5.9
import PackageDescription

// sim — the iOS Simulator as a cmdy split, driven by agents. Wraps
// xcodebuild + xcrun simctl for the build/install/launch/screenshot/log
// lifecycle, docks the Simulator window into the terminal (its own AX
// adoption, no appdock dependency), and is Injection-aware: when the project
// uses krzysztofzablocki/Inject + johnno1962/InjectionIII, edits hot-reload
// into the running app instead of triggering a full rebuild.
let package = Package(
    name: "sim",
    platforms: [.macOS("26.0")],
    dependencies: [ .package(path: "../CmdySDK") ],
    targets: [
        .executableTarget(name: "sim", dependencies: ["CmdySDK"]),
        .testTarget(name: "simTests", dependencies: ["sim"]),
    ]
)
