// swift-tools-version:5.9
import PackageDescription
import Foundation

// CmdyCore — cmdy's own VT engine: parser, buffer, blocks, replay.
// The Zig library owns the engine; CmdyCore preserves the Swift API for the
// native macOS host. Terminal state stays independent of AppKit/Metal; the
// aggregate native library also owns the platform renderer. Blocks and insets are
// native buffer concepts, not bolt-ons, and
// every byte fed can be recorded and replayed deterministically (no wall
// clock in here — that rule is what makes sessions replayable).
let coreDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
func selectedNativeKey() -> String {
    let manifest = coreDirectory.appendingPathComponent(".zig-build/manifest.json")
    guard let data = try? Data(contentsOf: manifest),
          let receipt = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let key = receipt["source_key"] as? String, key.count == 64,
          key.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
        // Package graph inspection works before bootstrap. The plugin rejects
        // builds until a real archive and receipt have been prepared.
        return "unprepared"
    }
    return key
}
let nativeKey = selectedNativeKey()
let nativeArchive = coreDirectory
    .appendingPathComponent(".zig-build/artifacts/\(nativeKey)/libcmdy_engine.a").path
let nativeSelection = "CMDY_ZIG_SELECTED_\(nativeKey)"
let package = Package(
    name: "Core",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "CmdyCore", targets: ["CmdyCore"]),
        .library(name: "CmdyNative", targets: ["CmdyNative"]),
        .plugin(name: "VerifyNativeEngine", targets: ["VerifyNativeEngine"]),
        .library(name: "CmdyPTY", targets: ["CmdyPTY"]),
        // Internal, unreleased C ABI experiment. Not a supported public
        // product; no compatibility or binary-stability promise.
        .library(name: "lib_cmdy", type: .dynamic, targets: ["CmdyC"])
    ],
    targets: [
        .plugin(name: "VerifyNativeEngine", capability: .buildTool()),
        .target(
            name: "CmdyNative",
            path: "Sources/CmdyNative",
            publicHeadersPath: "include",
            cSettings: [.define("CMDY_ZIG_SELECTED_SOURCE_KEY", to: "\"\(nativeKey)\"")],
            linkerSettings: [.unsafeFlags([nativeArchive]), .linkedLibrary("objc"),
                .linkedFramework("AppKit"), .linkedFramework("Foundation"),
                .linkedFramework("CoreFoundation"), .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"), .linkedFramework("Metal"),
                .linkedFramework("MetalKit"), .linkedFramework("QuartzCore"),
                .linkedFramework("ImageIO")]
        ),
        .target(
            name: "CmdyCore",
            dependencies: ["CmdyNative"],
            path: "Sources/CmdyCoreZig",
            swiftSettings: [.define(nativeSelection)],
            plugins: [.plugin(name: "VerifyNativeEngine")]
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
            dependencies: ["CmdyNative"],
            path: "Sources/CmdyCZig",
            swiftSettings: [.define(nativeSelection)],
            plugins: [.plugin(name: "VerifyNativeEngine")]
        ),
        .testTarget(
            name: "CmdyCoreTests",
            dependencies: ["CmdyCore", "CmdyPTY", "CmdyC"],
            path: "Tests/CmdyCoreTests"
        )
    ]
)
