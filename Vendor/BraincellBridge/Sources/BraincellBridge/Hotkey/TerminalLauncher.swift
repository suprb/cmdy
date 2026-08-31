import Foundation
import AppKit

/// Open a new host-terminal window at `path`. Bridge deliberately has no generic
/// terminal launcher or injection fallback.
@MainActor
enum TerminalLauncher {
    /// The argument is retained for source compatibility with the menu flow.
    static func preferredTerminalBundleId(lastFrontmostBundleId: String?) -> String {
        BridgeHostIdentity.bundleIdentifier
    }

    /// Open `path` in the chosen terminal. Returns true on success (the
    /// `open` subprocess exited 0). Synchronous — wraps
    /// `Process.waitUntilExit` off-main so the popover thread doesn't block.
    ///
    /// LaunchServices opens the directory without an Automation permission.
    static func openTerminal(at path: String, bundleId: String) async -> Bool {
        guard bundleId == BridgeHostIdentity.bundleIdentifier else { return false }
        return await runProcess(executable: "/usr/bin/open",
                                args: ["-b", BridgeHostIdentity.bundleIdentifier, path])
    }

    // MARK: - Subprocess helper

    private static func runProcess(executable: String, args: [String]) async -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch {
            NSLog("[TerminalLauncher] %@ failed to launch: %@", executable, error.localizedDescription)
            return false
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                proc.waitUntilExit()
                cont.resume(returning: proc.terminationStatus == 0)
            }
        }
    }

}
