"""Exercise production cleanup against owned temporary fixtures; no app launch."""
from pathlib import Path
import json
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'App/StaleShellDirectoryCleanup.swift'
HARNESS = r'''
import Darwin
import Foundation

@main struct CleanupChecks {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("cmdy-cleanup-tests-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let directory = root.appendingPathComponent("scan")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        let dead = pid_t.max
        guard kill(dead, 0) == -1 && errno == ESRCH else { fatalError("test PID is unexpectedly present") }
        let target = root.appendingPathComponent("preserved-symlink-target")
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: target.appendingPathComponent("marker"))
        let removed = ["cmdy-zdotdir-\(dead)-dead", "termite-zdotdir-\(dead)-legacy"]
        let retained = ["cmdy-zdotdir-\(getpid())-current", "cmdy-zdotdir-\(getppid())-live",
                        "cmdy-zdotdir-invalid-pid", "cmdyx-zdotdir-\(dead)-unrelated",
                        "unrelated space é", "cmdy-zdotdir-999999999999999-overflow"]
        for name in removed + retained {
            try manager.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: false)
            try Data(name.utf8).write(to: directory.appendingPathComponent(name).appendingPathComponent("marker"))
        }
        let link = directory.appendingPathComponent("cmdy-zdotdir-\(dead)-link")
        try manager.createSymbolicLink(at: link, withDestinationURL: target)
        StaleShellDirectoryCleanup.removeStaleDirectories(
            in: directory, prefixes: ["cmdy-zdotdir-", "termite-zdotdir-"], currentPID: getpid())
        for name in removed { precondition(!manager.fileExists(atPath: directory.appendingPathComponent(name).path)) }
        for name in retained {
            let contents = try Data(contentsOf: directory.appendingPathComponent(name).appendingPathComponent("marker"))
            precondition(contents == Data(name.utf8))
        }
        precondition(!manager.fileExists(atPath: link.path))
        let targetContents = try Data(contentsOf: target.appendingPathComponent("marker"))
        precondition(targetContents == Data("keep".utf8))
        StaleShellDirectoryCleanup.removeStaleDirectories(
            in: root.appendingPathComponent("missing"), prefixes: ["cmdy-zdotdir-"], currentPID: getpid())
        print("{\"status\":\"pass\",\"checks\":11,\"applicationLaunches\":0}")
    }
}
'''


class ShellDirectoryCleanupTests(unittest.TestCase):
    def test_cleanup_preserves_live_current_unrelated_entries_and_symlink_target(self):
        with tempfile.TemporaryDirectory(prefix='cmdy-cleanup-compile-') as name:
            root = Path(name); harness = root / 'Checks.swift'; harness.write_text(HARNESS)
            binary = root / 'cleanup-checks'
            compiled = subprocess.run(['/usr/bin/xcrun', 'swiftc', '-O', '-parse-as-library',
                str(SOURCE), str(harness), '-o', str(binary)], capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), dict(status='pass', checks=11, applicationLaunches=0))


if __name__ == '__main__': unittest.main()
