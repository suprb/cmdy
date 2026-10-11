// swift-tools-version:5.9
import PackageDescription
import Foundation

let nativeManifest = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../Core/.zig-build/manifest.json")
let nativeReceipt = (try? Data(contentsOf: nativeManifest))
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
let nativeKey = (nativeReceipt?["source_key"] as? String).flatMap { key in
    key.count == 64 && key.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) ? key : nil
} ?? "unprepared"

// CmdyGPU — cmdy's independently implemented terminal compositor.
// The native library owns font handling, rasterization, caches and Metal
// composition. Swift exposes AppKit values and MTKView event plumbing.
let package = Package(
    name: "Renderer",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "CmdyGPU", targets: ["CmdyGPU"])
    ],
    dependencies: [.package(path: "../Core")],
    targets: [
        .target(
            name: "CmdyGPU",
            dependencies: [.product(name: "CmdyNative", package: "Core")],
            path: "Sources/CmdyGPUZig",
            swiftSettings: [.define("CMDY_ZIG_SELECTED_\(nativeKey)")],
            plugins: [.plugin(name: "VerifyNativeEngine", package: "Core")]
        ),
        .testTarget(
            name: "CmdyGPUTests",
            dependencies: ["CmdyGPU"]
        ),
    ]
)
