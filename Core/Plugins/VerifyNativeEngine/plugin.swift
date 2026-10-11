import PackagePlugin
import Foundation

@main
struct VerifyNativeEngine: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        // This plugin also verifies the Renderer facade from its own package.
        // Anchor verification to the plugin's Core sources, not the consumer.
        let core = Path(URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path)
        let archive = core.appending(".zig-build/libcmdy_engine.a")
        let receipt = core.appending(".zig-build/manifest.json")
        guard FileManager.default.fileExists(atPath: archive.string),
              FileManager.default.fileExists(atPath: receipt.string) else {
            Diagnostics.error("CMDY Zig engine is missing. Run ./build.sh from the repository root before using SwiftPM directly.")
            return []
        }
        let verifier = core.appending("Tools/ZigEngine/verify.py")
        var inputs = [archive, receipt, verifier, core.appending("Tools/ZigEngine/build.py"),
                      core.appending("Tools/ZigEngine/source_inputs.py"),
                      core.appending("Tools/ZigEngine/apple_toolchain.py")]
        for directory in ["Zig", "Sources/CmdyNative/include", "Platform"] {
            let path = core.appending(directory)
            guard FileManager.default.fileExists(atPath: path.string) else { continue }
            let files = try FileManager.default.subpathsOfDirectory(atPath: path.string)
            inputs += files.filter { $0.hasSuffix(".zig") || $0.hasSuffix(".metal") || $0.hasSuffix(".h") || $0.hasSuffix(".m") || $0.hasSuffix(".c") || $0.hasPrefix("testdata/") }
                .filter { !FileManager.default.isDirectory(atPath: path.appending($0).string) }
                .sorted().map { path.appending($0) }
        }
        let output = context.pluginWorkDirectory.appending("NativeEngineVerified-\(target.name).swift")
        return [.buildCommand(displayName: "Verify CMDY native engine source and archive",
            executable: Path("/usr/bin/env"),
            arguments: ["python3", verifier.string, "--core", core.string, "--output", output.string],
            inputFiles: inputs, outputFiles: [output])]
    }
}

private extension FileManager {
    func isDirectory(atPath path: String) -> Bool {
        var directory: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}
