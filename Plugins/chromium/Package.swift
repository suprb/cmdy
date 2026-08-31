// swift-tools-version:5.9
import PackageDescription

// chromium — real Chromium (CEF, multi-process, GPU) as a cmdy sidecar,
// driven through the plugin SDK. The CEF framework + prebuilt bridge libs
// are NOT in the repo: `Frameworks/` here is a symlink (or copy) created by
// plugins.sh from a Braincell checkout, or populated per README-CEF.md.
let package = Package(
    name: "chromium",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../CmdySDK"),
        .package(path: "Support"),
    ],
    targets: [
        .executableTarget(
            name: "chromium",
            dependencies: [
                "CmdySDK",
                "CEFBridge",
                .product(name: "ChromiumSupport", package: "Support"),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .unsafeFlags([
                    "-L", "Frameworks",
                    "-lcef_bridge",
                    "-lcef_dll_wrapper",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
                ]),
            ]
        ),
        .systemLibrary(
            name: "CEFBridge",
            path: "Sources/CEFBridge"
        ),
    ]
)
