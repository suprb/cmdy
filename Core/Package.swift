// swift-tools-version:5.9
import PackageDescription

// CmdyCore — cmdy's own VT engine: parser, buffer, blocks, replay.
// Pure Swift, zero AppKit/Metal. Headless, CI-able, Swift-6-concurrency
// clean. Blocks and insets are native buffer concepts, not bolt-ons, and
// every byte fed can be recorded and replayed deterministically (no wall
// clock in here — that rule is what makes sessions replayable).
let package = Package(
    name: "Core",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "CmdyCore", targets: ["CmdyCore"]),
        .library(name: "CmdyPTY", targets: ["CmdyPTY"]),
        // Internal, unreleased C ABI experiment. Not a supported public
        // product; no compatibility or binary-stability promise.
        .library(name: "lib_cmdy", type: .dynamic, targets: ["CmdyC"])
    ],
    targets: [
        .target(
            name: "CmdyCore",
            path: "Sources/CmdyCore"
        ),
        .target(
            name: "CmdyPTYShim",
            path: "Sources/CmdyPTYShim",
            publicHeadersPath: "include"
        ),
        // Native pseudo-terminal transport and child-process lifecycle.
        .target(
            name: "CmdyPTY",
            dependencies: ["CmdyPTYShim"],
            path: "Sources/CmdyPTY"
        ),
        .target(
            name: "CmdyC",
            dependencies: ["CmdyCore"],
            path: "Sources/CmdyC"
        ),
        .testTarget(
            name: "CmdyCoreTests",
            dependencies: ["CmdyCore", "CmdyPTY", "CmdyC"],
            path: "Tests/CmdyCoreTests"
        )
    ]
)
