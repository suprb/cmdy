// swift-tools-version:5.9
import PackageDescription

// CmdyGPU — cmdy's independently implemented terminal compositor.
// The package depends only on system frameworks and the narrow
// MetalRenderSource boundary documented in docs/independence.
let package = Package(
    name: "Renderer",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "CmdyGPU", targets: ["CmdyGPU"])
    ],
    targets: [
        .target(
            name: "CmdyGPU",
            path: "Sources/CmdyGPU"
        ),
        .testTarget(
            name: "CmdyGPUTests",
            dependencies: ["CmdyGPU"]
        ),
    ]
)
