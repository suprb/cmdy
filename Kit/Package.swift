// swift-tools-version:5.9
import PackageDescription

// CmdyKit — the platform layer: inline UI, config engine, plugin bus,
// blocks model, session persistence, themes. AppKit is welcome here (this
// is the *platform* layer, not the engine); SwiftTerm and Metal are not.
// The app target on top of this is a thin shell of windows and menus.
let package = Package(
    name: "Kit",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "CmdyKit", targets: ["CmdyKit"])
    ],
    dependencies: [
        .package(path: "../Identity"),
    ],
    targets: [
        .target(
            name: "CmdyKit",
            dependencies: [
                .product(name: "ProductIdentity", package: "Identity"),
            ],
            path: "Sources/CmdyKit",
            resources: [.copy("Fonts")]
        ),
        .testTarget(
            name: "CmdyKitTests",
            dependencies: ["CmdyKit"],
            path: "Tests/CmdyKitTests"
        ),
    ]
)
