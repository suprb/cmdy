import AppKit
import CmdyCore
@_spi(CmdyApp) import CmdyGPU

/// Actual surface/style publication checks without an application, window,
/// renderer, GPU target, PTY, clipboard or native input event.
@MainActor
enum CmdyRendererStyleHarness {
    private struct Failure: Error { let message: String }

    static func run(arguments: [String]) -> Never {
        guard arguments.count == 3, arguments[1] == "--renderer-style-test",
              arguments[2].hasPrefix("/"), CmdyPerformanceTrace.enabled else {
            print("usage: CMDY_FRAME_TRACE=1 cmdy --renderer-style-test <new absolute result path>")
            exit(2)
        }
        let output = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: output.path),
              FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path) else { exit(2) }
        Task { @MainActor in
            var checks: [[String: Any]] = []
            var failure: String?
            do {
                CmdySnapshotRevisionHarness.run { passed, name in
                    checks.append(["name": name, "pass": passed])
                    if !passed { failure = name }
                }
                if let failure { throw Failure(message: failure) }
                try await surfaceChecks(&checks)
            } catch { failure = String(describing: error) }
            await CmdyPerformanceTrace.flush()
            let passed = failure == nil && checks.allSatisfy { $0["pass"] as? Bool == true }
            do {
                let data = try JSONSerialization.data(withJSONObject: [
                    "status": passed ? "pass" : "fail", "checks": checks,
                    "errors": failure.map { [$0] } ?? [], "nativeWindows": 0,
                    "PTYLaunches": 0, "GPUWork": false, "comparisonSamples": 0,
                    "scope": "Actual producer capture, source publications and UI style invalidation; trace operation counts only."
                ], options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output, options: .withoutOverwriting)
            } catch { print("FAIL: style result write: \(error)"); exit(1) }
            print(passed ? "ALL RENDERER STYLE TESTS PASS" : "RENDERER STYLE TESTS FAILED")
            exit(passed ? 0 : 1)
        }
        RunLoop.main.run()
        exit(1)
    }

    private static func surfaceChecks(_ checks: inout [[String: Any]]) async throws {
        let surface = CmdyTerminalSurface(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        defer { surface.terminate() }
        surface.appearance = NSAppearance(named: .aqua)
        surface.nativeForegroundColor = .white
        surface.nativeBackgroundColor = .black
        let producer = ProducerFrameCaptureProbe()
        var sequence: UInt64 = 0
        func check(_ passed: Bool, _ name: String) throws {
            checks.append(["name": name, "pass": passed])
            if !passed { throw Failure(message: name) }
        }
        func feed(_ text: String, expected: String) async throws {
            surface.feed(text: "\u{1b}[H\u{1b}[0m\u{1b}[2K" + text)
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while true {
                let snapshot = surface.renderSnapshot
                let row = snapshot.line(absolute: snapshot.grid.displayTopRow)
                let actual = row?.cells.filter { $0.width > 0 }.map(\.text).joined() ?? ""
                if actual.hasPrefix(expected) { return }
                if ProcessInfo.processInfo.systemUptime >= deadline { throw Failure(message: "snapshot publication timeout") }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        func capture(_ phase: Int) throws -> (SnapshotRowRevision?, ViewLineInfo) {
            CmdyPerformanceTrace.record(event: "style-test.begin", started: CmdyPerformanceTrace.now(), fields: ["phase": phase])
            defer { CmdyPerformanceTrace.record(event: "style-test.end", started: CmdyPerformanceTrace.now(), fields: ["phase": phase]) }
            sequence += 1
            let scale = surface.backingScaleFactor()
            let count = try producer.capture(source: surface, surface: 1, sequence: sequence,
                drawableSize: CGSize(width: surface.bounds.width * scale, height: surface.bounds.height * scale))
            guard count > 0 else { throw Failure(message: "producer captured no rows") }
            let row = surface.renderSnapshot.grid.displayTopRow
            return (surface.snapshotRowRevision(forRow: row), surface.lineInfo(forRow: row))
        }
        func first(_ info: ViewLineInfo, _ key: NSAttributedString.Key) -> Any? {
            guard let segment = info.segments.first, segment.attributedString.length > 0 else { return nil }
            return segment.attributedString.attribute(key, at: 0, effectiveRange: nil)
        }
        func rgba(_ color: NSColor?) -> [CGFloat]? {
            guard let rgb = color?.usingColorSpace(.sRGB) else { return nil }
            return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
        }
        func color(_ info: ViewLineInfo, _ key: NSAttributedString.Key, _ expected: NSColor) -> Bool {
            rgba(first(info, key) as? NSColor) == rgba(expected)
        }

        try await feed("initial", expected: "initial")
        let initial = try capture(0)
        try check(initial.0 != nil && color(initial.1, .foregroundColor, .white), "surface style: initial producer captures resolved style")
        for edit in 1...12 {
            let text = "edit\(edit)"
            try await feed(text, expected: text)
            let changed = try capture(1)
            try check(changed.0?.context == initial.0?.context && changed.0?.content != initial.0?.content
                && changed.1.segments.first?.attributedString.string.hasPrefix(text) == true,
                "surface style: publication \(edit) updates text with the same style context")
        }
        surface.nativeForegroundColor = .cyan
        let foreground = try capture(2)
        try check(foreground.0?.context != initial.0?.context && color(foreground.1, .foregroundColor, .cyan),
                  "surface style: foreground assignment invalidates resolved color")
        surface.selectedTextBackgroundColor = .yellow
        let selection = try capture(3)
        try check(selection.0?.context != foreground.0?.context && color(selection.1, .foregroundColor, .cyan),
                  "surface style: selection color updates context without changing ordinary text")
        surface.nativeBackgroundColor = .blue
        let background = try capture(4)
        try check(background.0?.context != selection.0?.context, "surface style: background assignment updates context")
        try await feed("\u{1b}[31mansi", expected: "ansi")
        _ = try capture(5)
        surface.installColors([.init(red: 0, green: 0, blue: 0), .init(red: 0, green: .max, blue: 0)])
        let palette = try capture(6)
        try check(color(palette.1, .foregroundColor, .green), "surface style: ANSI palette assignment changes captured attributes")
        try await feed("font", expected: "font")
        _ = try capture(7)
        surface.font = NSFont.monospacedSystemFont(ofSize: 20, weight: .regular)
        let font = try capture(8)
        try check((first(font.1, .font) as? NSFont)?.pointSize == 20, "surface style: font assignment refreshes shaped font")
        surface.failedBlockForegroundColor = .red
        surface.failedBlockBackgroundColor = .green
        surface.failedBlockRows = [surface.renderSnapshot.grid.displayTopRow]
        let failed = try capture(9)
        try check(color(failed.1, .foregroundColor, .red) && color(failed.1, .backgroundColor, .green),
                  "surface style: failed rows receive updated foreground and background")
        surface.failedBlockRows = []
        let restored = try capture(10)
        try check(color(restored.1, .foregroundColor, .cyan) && color(failed.1, .foregroundColor, .red),
                  "surface style: removing failure updates new rows and preserves retained old text")
        surface.nativeForegroundColor = .textColor
        surface.nativeBackgroundColor = .textBackgroundColor
        let light = try capture(11)
        let retainedLight = rgba(first(light.1, .foregroundColor) as? NSColor)
        surface.appearance = NSAppearance(named: .darkAqua)
        let dark = try capture(12)
        try check(light.0?.context != dark.0?.context && retainedLight != rgba(first(dark.1, .foregroundColor) as? NSColor)
                    && retainedLight == rgba(first(light.1, .foregroundColor) as? NSColor),
                  "surface style: effective appearance refreshes dynamic colors and preserves old text")
        NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
        let system = try capture(13)
        try check(system.0?.context == dark.0?.context && rgba(first(system.1, .foregroundColor) as? NSColor)
                  == rgba(first(dark.1, .foregroundColor) as? NSColor),
                  "surface style: system-color notification refreshes without inventing a content change")
        var expectedLayerBackground: [CGFloat]?
        surface.effectiveAppearance.performAsCurrentDrawingAppearance {
            expectedLayerBackground = rgba(.textBackgroundColor)
        }
        try check(expectedLayerBackground != nil
                  && rgba(surface.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }) == expectedLayerBackground,
                  "surface style: system-color notification resolves the layer under the view appearance")
        try check(surface.shellPid == 0 && surface.metalRenderer == nil && surface.window == nil,
                  "surface style: no PTY, renderer or window was created")
        surface.terminate()
        let closedRevision = surface.frameContentRevision
        NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
        try check(surface.frameContentRevision == closedRevision,
                  "surface style: termination removes the color observer without a late redraw")
    }
}
