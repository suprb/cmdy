import AppKit
@_spi(CmdyApp) import CmdyGPU
import CmdyNative

/// A fixed capture-attribution episode. It does not create an NSApplication,
/// NSWindow, Metal target or PTY, and it does not measure terminal display speed.
@MainActor
enum CmdyRendererCaptureProfile {
    static func run(arguments: [String]) -> Never {
        guard arguments.count == 3, arguments[1] == "--renderer-capture-profile",
              arguments[2].hasPrefix("/"), CmdyPerformanceTrace.enabled else {
            print("usage: CMDY_FRAME_TRACE=1 cmdy --renderer-capture-profile <new absolute result path>")
            exit(2)
        }
        let output = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        var directory: ObjCBool = false
        guard !FileManager.default.fileExists(atPath: output.path),
              FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path,
                                             isDirectory: &directory), directory.boolValue else {
            print("FAIL: capture profile needs a new result path in an existing directory")
            exit(2)
        }
        Task { @MainActor in
            var results: [[String: Any]] = []
            var failure: String?
            for (index, name) in ["ascii", "styled", "unicode"].enumerated() {
                let surface = CmdyTerminalSurface(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
                let rows = surface.engine.rows, cols = surface.engine.cols
                let prefix = "\(name)|"
                var payload = "\u{1b}[?25l\u{1b}[2J"
                for row in 0..<rows {
                    payload += "\u{1b}[\(row + 1);1H" + prefix
                    let available = max(0, cols - prefix.count - 1)
                    switch name {
                    case "ascii": payload += String(repeating: "x", count: available)
                    case "styled":
                        let pieces = ["let ", "result", " = ", "call", "(value)"]
                        var used = 0, part = 0
                        while used < available {
                            let text = String(pieces[part % pieces.count].prefix(available - used))
                            payload += "\u{1b}[\(31 + part % 6)m" + text
                            used += text.count; part += 1
                        }
                        payload += "\u{1b}[0m"
                    default:
                        payload += String(repeating: "A\u{0301}😀─█ 中文 ", count: available / 16)
                    }
                }
                surface.feed(text: payload)
                let deadline = ProcessInfo.processInfo.systemUptime + 8
                while true {
                    let snapshot = surface.renderSnapshot
                    let published = (0..<rows).allSatisfy { row in
                        let text = snapshot.line(absolute: snapshot.grid.displayTopRow + row)?.cells
                            .filter { $0.width > 0 }.map(\.text).joined() ?? ""
                        return text.hasPrefix(prefix)
                    }
                    if published { break }
                    if ProcessInfo.processInfo.systemUptime >= deadline {
                        failure = "Timed out publishing \(name) viewport"; break
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                if failure == nil {
                    do {
                        let probe = ProducerFrameCaptureProbe()
                        let scale = surface.backingScaleFactor()
                        let size = CGSize(width: surface.bounds.width * scale, height: surface.bounds.height * scale)
                        for sequence: UInt64 in [1, 2] {
                            let capturedRows = try probe.capture(source: surface, surface: UInt64(index + 1),
                                sequence: sequence, drawableSize: size)
                            guard capturedRows == rows else {
                                failure = "Capture row count mismatch for \(name)"; break
                            }
                            results.append(["workload": name, "surface": index + 1, "sequence": sequence,
                                "cache": sequence == 1 ? "cold" : "warm", "rows": rows, "cols": cols,
                                "pixelWidth": Int(size.width), "pixelHeight": Int(size.height)])
                        }
                        guard surface.shellPid == 0, surface.metalRenderer == nil, surface.window == nil else {
                            failure = "Capture-only diagnostic unexpectedly owns a shell, renderer or window"; break
                        }
                    } catch { failure = String(describing: error) }
                }
                surface.terminate()
                if failure != nil { break }
            }
            await CmdyPerformanceTrace.flush()
            await Task.detached { cmdy_render_trace_flush() }.value
            let passed = failure == nil && results.count == 6
            do {
                let result: [String: Any] = ["schemaVersion": 1, "status": passed ? "pass" : "fail",
                    "captures": results, "errors": failure.map { [$0] } ?? [], "comparisonSamples": 0,
                    "nativeWindows": 0, "PTYLaunches": 0, "GPUWork": false,
                    "scope": "Single cold and warm main-actor producer capture per fixed workload; instrumentation included; no display or Ghostty comparison."]
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output, options: .withoutOverwriting)
            } catch {
                print("FAIL: capture-profile result write: \(error)"); exit(1)
            }
            print(passed ? "CAPTURE PROFILE COMPLETE" : "CAPTURE PROFILE FAILED")
            exit(passed ? 0 : 1)
        }
        RunLoop.main.run()
        print("FAIL: capture-profile run loop returned before completion")
        exit(1)
    }
}
