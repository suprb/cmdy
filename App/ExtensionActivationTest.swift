import Foundation
import CmdyKit
import ProductIdentity

/// `--extension-activation-test`: headless end-to-end check of on-demand
/// Extensions. Installs a tiny Python Extension into an isolated config,
/// then proves it learns its commands, sleeps, wakes on its command and
/// receives it, sleeps soon after releasing its companion, and that disabling
/// removes its sleeping commands. Requires CMDY_CONFIG_DIR.
enum ExtensionActivationTest {
    static func run() -> Never {
        guard ProductIdentity.current.environmentValue("CONFIG_DIR") != nil else {
            print("FAIL extension activation: set CMDY_CONFIG_DIR to an empty directory")
            exit(2)
        }
        let manager = PluginManager.shared
        let directory = PluginManager.extensionsDirectory
            .appendingPathComponent("lazy-demo", isDirectory: true)
        let log = directory.appendingPathComponent("received.log")
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(
            at: ConfigFile.directory.appendingPathComponent("extension-contributions.json"))
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = """
        {"manifestVersion": 1, "id": "dev.cmdy.lazy-demo", "name": "Lazy Demo",
         "version": "1.0.0", "entrypoint": "run.py", "activation": "on-demand",
         "capabilities": ["events.read", "commands", "ui.companion"]}
        """
        try! manifest.write(to: directory.appendingPathComponent("manifest.json"),
                            atomically: true, encoding: .utf8)
        let script = """
        #!/usr/bin/env python3
        import json, os, urllib.request
        BASE = f"http://127.0.0.1:{os.environ['CMDY_PORT']}"
        HEADERS = {"Authorization": f"Bearer {os.environ['CMDY_TOKEN']}",
                   "Content-Type": "application/json"}
        def post(path, body):
            req = urllib.request.Request(BASE + path, json.dumps(body).encode(), HEADERS, method="POST")
            urllib.request.urlopen(req).read()
        post("/v1/extensions/register", {"commands": [{"id": "lazy.ping", "title": "Lazy: Ping"}]})
        req = urllib.request.Request(BASE + "/v1/events", headers=HEADERS)
        with urllib.request.urlopen(req) as stream:
            for raw in stream:
                if not raw.startswith(b"data: "):
                    continue
                event = json.loads(raw[6:])
                if event.get("kind") == "command" and event.get("id") == "lazy.ping":
                    with open("received.log", "a") as f:
                        f.write(f"ping {os.getpid()}\\n")
                    post("/v1/ui/inset", {"right": 120})
                    post("/v1/ui/inset", {"right": 0})
        """
        let entry = directory.appendingPathComponent("run.py")
        try! script.write(to: entry, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)

        var failures = 0
        func check(_ ok: Bool, _ label: String) {
            print("\(ok ? "ok  " : "FAIL") extension activation: \(label)")
            if !ok { failures += 1 }
        }
        func phase() -> ExtensionRuntimePhase { manager.extensionRuntimeStatus(at: directory).phase }
        @discardableResult
        func pump(upTo seconds: TimeInterval, until done: () -> Bool) -> TimeInterval {
            let start = Date()
            while !done(), Date().timeIntervalSince(start) < seconds {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
            return Date().timeIntervalSince(start)
        }

        manager.activateAll()
        pump(upTo: 8) { phase() == .ready && manager.hasCommand(id: "lazy.ping") }
        check(phase() == .ready && manager.hasCommand(id: "lazy.ping"),
              "first launch runs and registers its command")

        pump(upTo: PluginManager.extensionIdleSeconds + 8) { phase() == .sleeping }
        check(phase() == .sleeping, "idle on-demand Extension sleeps")
        check(manager.hasCommand(id: "lazy.ping"), "its command stays in the palette while sleeping")

        check(manager.runCommand(id: "lazy.ping"), "running the sleeping command is accepted")
        pump(upTo: 8) { (try? String(contentsOf: log, encoding: .utf8))?.contains("ping") == true }
        let received = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        check(received.contains("ping"), "woken Extension receives the command that woke it")
        check(phase() == .ready, "it is running after the wake")

        let slept = pump(upTo: PluginManager.extensionIdleSeconds + 8) { phase() == .sleeping }
        check(phase() == .sleeping
                && slept < PluginManager.extensionIdleSeconds,
              "it sleeps soon after releasing its companion (\(String(format: "%.1f", slept))s)")

        try? manager.setPluginEnabled(false, at: directory)
        check(!manager.hasCommand(id: "lazy.ping") && phase() == .stopped,
              "disabling removes the sleeping command")

        manager.deactivateAll()
        try? FileManager.default.removeItem(at: directory)
        print(failures == 0 ? "EXTENSION ACTIVATION PASS" : "EXTENSION ACTIVATION FAIL (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}
