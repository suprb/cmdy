import Darwin
import Foundation

/// Best-effort cleanup of the existing product-owned temporary shell files.
/// Enumerate names first: unrelated entries need no URL or resource metadata.
enum StaleShellDirectoryCleanup {
    static func removeStaleDirectories(
        in directory: URL, prefixes: [String], currentPID: pid_t
    ) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where prefixes.contains(where: { name.hasPrefix($0) }) {
            let parts = name.split(separator: "-")
            guard parts.count >= 3, let pid = pid_t(parts[2]), pid != currentPID else { continue }
            if kill(pid, 0) == -1 && errno == ESRCH {
                try? manager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }
}
