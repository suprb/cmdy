import Foundation

// Simctl — a thin, honest wrapper over the Apple command-line tools that
// already do all the heavy lifting: `xcodebuild` (compile), `xcrun simctl`
// (boot / install / launch / screenshot / log / openurl / push), and
// Injection detection (is this project wired for hot reload?). Everything
// returns structured results so the agent layer can render them.

enum Simctl {
    static func readFile(_ path: String, maxBytes: Int) -> Data? {
        let limit = min(max(maxBytes, 0), 256 * 1024 * 1024)
        guard let handle = try? FileHandle(
            forReadingFrom: URL(fileURLWithPath: path)
        ) else { return nil }
        defer { try? handle.close() }

        var data = Data()
        data.reserveCapacity(min(limit, 64 * 1024))
        while true {
            let remainingWithSentinel = limit - data.count + 1
            guard remainingWithSentinel > 0 else { return nil }
            let chunk: Data
            do {
                // FileHandle is allowed to return nil at normal EOF. That is
                // a successful complete read, not a malformed input.
                guard let next = try handle.read(
                    upToCount: min(64 * 1024, remainingWithSentinel)
                ) else { return data }
                chunk = next
            } catch {
                return nil
            }
            if chunk.isEmpty { return data }
            data.append(chunk)
            guard data.count <= limit else { return nil }
        }
    }

    private final class TailCapture: @unchecked Sendable {
        private let limit: Int
        private let lock = NSLock()
        private var data = Data()

        init(limit: Int) {
            self.limit = max(0, limit)
            data.reserveCapacity(min(self.limit, 64 * 1024))
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty, limit > 0 else { return }
            lock.lock()
            defer { lock.unlock() }
            if chunk.count >= limit {
                data = Data(chunk.suffix(limit))
                return
            }
            let overflow = max(0, data.count + chunk.count - limit)
            if overflow > 0 { data.removeFirst(overflow) }
            data.append(chunk)
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private static func finishReaders(
        _ handles: [FileHandle],
        group: DispatchGroup
    ) {
        if group.wait(timeout: .now() + 1) == .timedOut {
            handles.forEach { try? $0.close() }
            group.wait()
        }
    }

    struct Run {
        let status: Int32
        let out: String
        let err: String
        var ok: Bool { status == 0 }
        var combined: String { (out + (err.isEmpty ? "" : "\n" + err)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Run a tool to completion, capturing stdout/stderr. `timeout` guards
    /// against a hung xcodebuild.
    @discardableResult
    static func run(_ launch: String, _ args: [String], cwd: String? = nil,
                    timeout: TimeInterval = 600) -> Run {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let outData = TailCapture(limit: 16 * 1024 * 1024)
        let errData = TailCapture(limit: 16 * 1024 * 1024)
        do { try p.run() } catch {
            return Run(status: -1, out: "", err: "cannot launch \(launch): \(error.localizedDescription)")
        }
        let readers = DispatchGroup()
        let readerPairs = [
            (outPipe.fileHandleForReading, outData),
            (errPipe.fileHandleForReading, errData),
        ]
        for (handle, capture) in readerPairs {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                while true {
                    guard let chunk = try? handle.read(upToCount: 64 * 1024),
                          !chunk.isEmpty else { break }
                    capture.append(chunk)
                }
                readers.leave()
            }
        }
        let boundedTimeout = timeout.isFinite
            ? min(max(0.1, timeout), 24 * 60 * 60)
            : 600
        let deadline = Date().addingTimeInterval(boundedTimeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        let timedOut = p.isRunning
        if timedOut {
            p.terminate()
            let grace = Date().addingTimeInterval(1)
            while p.isRunning && Date() < grace { usleep(50_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        p.waitUntilExit()
        finishReaders(readerPairs.map(\.0), group: readers)
        var errorText = String(decoding: errData.snapshot(), as: UTF8.self)
        if timedOut {
            if !errorText.isEmpty, !errorText.hasSuffix("\n") { errorText.append("\n") }
            errorText.append("timed out after \(Int(boundedTimeout))s")
        }
        return Run(status: p.terminationStatus,
                   out: String(decoding: outData.snapshot(), as: UTF8.self),
                   err: errorText)
    }

    static func xcrun(_ args: [String], timeout: TimeInterval = 600) -> Run {
        run("/usr/bin/xcrun", args, timeout: timeout)
    }

    // MARK: - Devices

    struct Device { let udid: String, name: String, state: String, runtime: String }

    /// Available iPhone/iPad simulators, booted ones first.
    static func devices() -> [Device] {
        let r = xcrun(["simctl", "list", "devices", "available", "--json"], timeout: 30)
        guard let data = r.out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = json["devices"] as? [String: [[String: Any]]] else { return [] }
        var out: [Device] = []
        for (runtime, list) in byRuntime {
            let rt = runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
            for d in list {
                guard let udid = d["udid"] as? String, let name = d["name"] as? String,
                      let state = d["state"] as? String else { continue }
                out.append(Device(udid: udid, name: name, state: state, runtime: rt))
            }
        }
        return out.sorted { ($0.state == "Booted" ? 0 : 1, $0.name) < ($1.state == "Booted" ? 0 : 1, $1.name) }
    }

    static func bootedUDID() -> String? {
        devices().first { $0.state == "Booted" }?.udid
    }

    /// Boot a device (by udid or name; default = a booted one, else the first
    /// iPhone), and open Simulator.app so it has a window to dock.
    static func boot(_ target: String?) -> Run {
        let all = devices()
        let device: Device?
        if let target {
            device = all.first { $0.udid == target || $0.name.lowercased() == target.lowercased() }
        } else {
            device = all.first { $0.state == "Booted" } ?? all.first { $0.name.contains("iPhone") }
        }
        guard let device else { return Run(status: 1, out: "", err: "no matching simulator") }
        if device.state != "Booted" {
            let r = xcrun(["simctl", "boot", device.udid], timeout: 120)
            if !r.ok && !r.combined.contains("current state: Booted") { return r }
        }
        run("/usr/bin/open", ["-a", "Simulator", "--args", "-CurrentDeviceUDID", device.udid], timeout: 30)
        return Run(status: 0, out: device.udid, err: "")
    }

    // MARK: - Build (xcodebuild)

    struct BuildResult { let ok: Bool; let appPath: String?; let bundleId: String?; let log: String }

    /// Build a scheme for the simulator and locate the resulting .app.
    /// project OR workspace; scheme required. Uses a fixed DerivedData so the
    /// .app path is predictable.
    static func build(project: String?, workspace: String?, scheme: String,
                      configuration: String, derivedData: String) -> BuildResult {
        var args = ["build",
                    "-scheme", scheme,
                    "-configuration", configuration,
                    "-destination", "generic/platform=iOS Simulator",
                    "-derivedDataPath", derivedData,
                    "CODE_SIGNING_ALLOWED=NO"]
        if let workspace { args = ["-workspace", workspace] + args }
        else if let project { args = ["-project", project] + args }
        let r = run("/usr/bin/xcodebuild", args, timeout: 1200)
        // Find the built .app under DerivedData.
        let productsDir = "\(derivedData)/Build/Products/\(configuration)-iphonesimulator"
        var appPath: String?, bundleId: String?
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: productsDir) {
            let apps = entries.filter { $0.hasSuffix(".app") }.sorted()
            if let app = apps.first(where: { $0 == "\(scheme).app" }) ?? apps.first {
                appPath = "\(productsDir)/\(app)"
                bundleId = infoPlistBundleId("\(productsDir)/\(app)/Info.plist")
            }
        }
        // xcodebuild logs are huge — keep the tail (where errors surface).
        let log = String(r.combined.suffix(3000))
        return BuildResult(ok: r.ok && appPath != nil, appPath: appPath, bundleId: bundleId, log: log)
    }

    static func infoPlistBundleId(_ path: String) -> String? {
        guard let data = readFile(path, maxBytes: 4 * 1024 * 1024),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    // MARK: - Install / launch / lifecycle

    static func install(udid: String, appPath: String) -> Run {
        xcrun(["simctl", "install", udid, appPath], timeout: 120)
    }

    /// Launch and return the app's pid (for log correlation).
    static func launch(udid: String, bundleId: String) -> Run {
        xcrun(["simctl", "launch", udid, bundleId], timeout: 60)
    }

    static func terminate(udid: String, bundleId: String) -> Run {
        xcrun(["simctl", "terminate", udid, bundleId], timeout: 30)
    }

    static func openURL(udid: String, url: String) -> Run {
        xcrun(["simctl", "openurl", udid, url], timeout: 30)
    }

    static func push(udid: String, bundleId: String, payloadPath: String) -> Run {
        xcrun(["simctl", "push", udid, bundleId, payloadPath], timeout: 30)
    }

    /// A device-resolution PNG of the booted simulator — no Screen Recording
    /// permission needed (simctl renders it directly).
    static func screenshot(udid: String) -> Data? {
        let tmp = NSTemporaryDirectory() + "sim-shot-\(UUID().uuidString).png"
        let r = xcrun(["simctl", "io", udid, "screenshot", tmp], timeout: 30)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        guard r.ok else { return nil }
        return readFile(tmp, maxBytes: 64 * 1024 * 1024)
    }

    /// Recent unified-log lines for a bundle id (its own subsystem).
    static func logs(udid: String, bundleId: String, tail: Int) -> String {
        // A bounded, non-streaming pull: the last chunk of this process's log.
        let r = xcrun(["simctl", "spawn", udid, "log", "show", "--last", "2m",
                       "--predicate", "processImagePath CONTAINS \"\(bundleId)\"",
                       "--style", "compact"], timeout: 30)
        return String(r.combined.suffix(max(0, min(100_000, tail))))
    }

    // MARK: - Injection detection

    struct Injection { let ready: Bool; let reason: String }

    /// Is this project wired for hot reload? We look for the Inject package in
    /// a resolved dependency file — the honest signal that edits can hot-swap
    /// instead of triggering a full rebuild.
    static func injection(projectDir: String) -> Injection {
        let fm = FileManager.default
        // Package.resolved (SPM) or *.xcodeproj/project.xcworkspace resolved file.
        let candidates = ["\(projectDir)/Package.resolved"]
        func fileMentionsInject(_ path: String) -> Bool {
            guard let data = readFile(path, maxBytes: 4 * 1024 * 1024),
                  let s = String(data: data, encoding: .utf8) else { return false }
            return s.contains("krzysztofzablocki/Inject") || s.lowercased().contains("/inject")
        }
        for c in candidates where fileMentionsInject(c) {
            return Injection(ready: true, reason: "Inject package resolved — edits hot-reload (with InjectionIII running)")
        }
        // Deep scan: any resolved file under the project mentioning Inject.
        if let enumerator = fm.enumerator(atPath: projectDir) {
            let skipped: Set<String> = [
                ".git", ".build", "DerivedData", "node_modules", "Pods",
            ]
            var visited = 0
            while let path = enumerator.nextObject() as? String, visited < 20_000 {
                visited += 1
                if path.split(separator: "/").contains(where: {
                    skipped.contains(String($0))
                }) {
                    enumerator.skipDescendants()
                    continue
                }
                guard path.hasSuffix("Package.resolved") || path.hasSuffix(".resolved")
                else { continue }
                if fileMentionsInject("\(projectDir)/\(path)") {
                    return Injection(ready: true, reason: "Inject package found — edits hot-reload (with InjectionIII running)")
                }
            }
        }
        return Injection(ready: false, reason: "no Inject dependency — edits need a rebuild (run). Add krzysztofzablocki/Inject + InjectionIII for hot reload.")
    }
}
