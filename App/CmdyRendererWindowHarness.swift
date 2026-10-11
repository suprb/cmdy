import AppKit
import CmdyKit
@_spi(CmdyApp) import CmdyGPU

/// Explicit native diagnostic. The campaign controller supplies the fresh
/// activity/power guard; this entry point never starts a shell or the app delegate.
@MainActor
enum CmdyRendererWindowHarness {
    static func run(arguments: [String]) -> Never {
        guard arguments.count == 3, arguments[1] == "--renderer-window-test",
              arguments[2].hasPrefix("/") else {
            print("usage: cmdy --renderer-window-test <new absolute result path>")
            exit(2)
        }
        let output = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        var directory: ObjCBool = false
        guard !FileManager.default.fileExists(atPath: output.path),
              FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path,
                                             isDirectory: &directory), directory.boolValue else {
            print("FAIL: renderer-window-test needs an existing directory and a new result file")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let test = WindowCheck()
            let passed = await test.run()
            do {
                let result: [String: Any] = [
                    "schemaVersion": 1, "status": passed ? "pass" : "fail",
                    "checks": test.checks, "errors": test.errors,
                    "lastPublishedRows": test.lastPublishedRows,
                    "repeatedPresentationRounds": test.repeatedPresentationRounds,
                    "fontFirstFrameMilliseconds": test.fontFirstFrameMilliseconds,
                    "releasedLifetimeCycles": test.releasedLifetimeCycles,
                    "compositionCases": ["Japanese", "Korean", "emoji UTF-16 replacement", "combining mark", "cancel", "focus loss"],
                    "presentations": test.presentations.map { rows in rows.map { row in
                        ["surface": row.surface, "epoch": row.epoch, "sequence": row.sequence,
                         "drawableID": row.drawableID, "presented": row.presented,
                         "pixelWidth": row.pixelWidth, "pixelHeight": row.pixelHeight] as [String: Any]
                    } },
                    "nativeWindows": 1, "terminalSurfaces": 2, "shellsStarted": 0,
                    "performanceSamples": 0, "programmaticResize": true,
                    "interactiveLiveResizeVerified": false, "systemIMEServiceVerified": false
                ]
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output, options: .withoutOverwriting)
            } catch {
                print("FAIL: renderer-window-test result write: \(error)")
                exit(1)
            }
            print(passed ? "ALL RENDERER WINDOW CHECKS PASS" : "RENDERER WINDOW CHECKS FAILED")
            exit(passed ? 0 : 1)
        }
        app.run()
        print("FAIL: renderer-window-test run loop exited before completion")
        exit(1)
    }

    @MainActor
    private final class WindowCheck {
        var checks: [String] = []
        var errors: [String] = []
        var lastPublishedRows: [String] = []
        var repeatedPresentationRounds = 0
        var fontFirstFrameMilliseconds: [String: Double] = [:]
        var releasedLifetimeCycles = 0
        var presentations: [[DrawablePresentationObservation]] = [[], []]
        private var received: [[UInt8]] = [[], []]
        private var committed: [[String]] = [[], []]
        private var surfaces: [CmdyTerminalSurface] = []
        private var window: NSWindow?

        private struct Failure: Error { let message: String }
        private func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(message: message) }
        }
        private func pass(_ message: String) { checks.append(message); print("PASS: \(message)") }
        private func wait(_ message: String, until condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            while !condition() {
                if let error = errors.first { throw Failure(message: error) }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw Failure(message: "Timed out: " + message)
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        private func rowText(_ index: Int) -> String {
            let snapshot = surfaces[index].renderSnapshot
            return snapshot.line(absolute: snapshot.grid.displayTopRow)?.cells
                .filter { $0.width > 0 }.map(\.text).joined() ?? ""
        }
        private func layout(_ size: NSSize) {
            guard let window else { return }
            window.setContentSize(size)
            let half = floor((size.width - 2) / 2)
            surfaces[0].frame = NSRect(x: 0, y: 0, width: half, height: size.height)
            surfaces[1].frame = NSRect(x: half + 2, y: 0, width: size.width - half - 2, height: size.height)
            window.contentView?.layoutSubtreeIfNeeded()
        }
        private func currentSizePresented(_ index: Int, after count: Int) -> Bool {
            guard let size = surfaces[index].metalView?.drawableSize else { return false }
            return presentations[index].dropFirst(count).contains {
                $0.presented && $0.pixelWidth == Int(size.width) && $0.pixelHeight == Int(size.height)
            }
        }

        func run() async -> Bool {
            do {
                let size = NSSize(width: 780, height: 360)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                self.window = window
                window.isReleasedWhenClosed = false
                window.title = "CMDY renderer qualification"
                window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
                for index in 0..<2 {
                    let surface = CmdyTerminalSurface(frame: NSRect(x: 0, y: 0, width: 389, height: size.height))
                    surfaces.append(surface)
                    surface.onSendToProcess = { [weak self] bytes in self?.received[index].append(contentsOf: bytes) }
                    surface.onTextInputCommitted = { [weak self] text in self?.committed[index].append(text) }
                    surface.onRendererError = { [weak self] error in self?.errors.append("Surface \(index): \(error)") }
                    window.contentView?.addSubview(surface)
                    try surface.setUseMetal(true)
                    surface.metalRenderer?.onDrawablePresentedForTesting = { [weak self] observation in
                        guard let self, self.presentations[index].count < 512 else { return }
                        self.presentations[index].append(observation)
                    }
                }
                layout(size)
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                try await wait("key visible window") { window.isKeyWindow && window.occlusionState.contains(.visible) }
                let seed = ["left A\u{0301}\u{1F600}\u{2500}\u{2588}", "right independent"]
                for index in 0..<2 { surfaces[index].feed(text: seed[index]) }
                try await wait("both published snapshots") { (0..<2).allSatisfy { self.rowText($0).hasPrefix(seed[$0]) } }
                let captured = surfaces[0].captureGrid()
                let shaped = surfaces[0].lineInfo(forRow: captured.displayTopRow)
                try require(shaped.boxDrawings.contains { $0.codePoint == 0x2500 }
                    && shaped.blockElements.contains { $0.codePoint == 0x2588 },
                    "box and block cells must produce procedural render items")
                try await wait("both on-screen Metal drawables") { (0..<2).allSatisfy { self.currentSizePresented($0, after: 0) } }
                try require(surfaces.allSatisfy { $0.isUsingMetalRenderer && $0.shellPid == 0 }, "normal Metal surfaces must have no shell")
                let ids = presentations.compactMap { $0.first(where: { $0.presented })?.surface }
                try require(ids.count == 2 && ids[0] != ids[1], "surfaces must have distinct render owners")
                pass("two normal surfaces publish independent Unicode content and present real Metal drawables")

                // Exercise feed-driven updates after the initial AppKit draw
                // cycle has settled. GPU completion alone does not establish
                // drawable presentation, and explicit view.draw() calls here
                // would mask an adapter that reuses a cached drawable.
                for surface in surfaces {
                    surface.metalRenderer?.smoothCursorEnabled = false
                    surface.metalRenderer?.smoothScrollEnabled = false
                    surface.feed(text: "\u{1B}[?25l")
                }
                try await Task.sleep(nanoseconds: 100_000_000)
                for round in 1...16 {
                    let counts = presentations.map(\.count)
                    for index in 0..<2 {
                        surfaces[index].feed(text: "\r\u{1B}[2K" + seed[index] + " frame-\(round)")
                    }
                    try await wait("both updated snapshots in round \(round)") {
                        (0..<2).allSatisfy { self.rowText($0).hasPrefix(seed[$0] + " frame-\(round)") }
                    }
                    try await wait("both new drawable presentations in round \(round)") {
                        (0..<2).allSatisfy { self.currentSizePresented($0, after: counts[$0]) }
                    }
                    repeatedPresentationRounds = round
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                pass("sixteen feed-only rounds present new drawables on both surfaces without manual draw requests")

                try require(window.makeFirstResponder(surfaces[0]), "left surface must become first responder")
                let unspecified = NSRange(location: NSNotFound, length: 0)
                surfaces[0].setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
                try require(surfaces[0].hasMarkedText() && received[0].isEmpty, "preedit must stay local")
                surfaces[0].insertText("日本", replacementRange: unspecified)
                try await wait("left committed input observer") { !self.received[0].isEmpty }
                try require(!surfaces[0].hasMarkedText() && received[0] == Array("日本".utf8)
                    && committed[0] == ["日本"] && received[1].isEmpty, "composition commits exactly once to focused surface")
                try require(window.makeFirstResponder(surfaces[1]), "right surface must become first responder")
                surfaces[1].insertText("ok", replacementRange: unspecified)
                try await wait("right committed input observer") { !self.received[1].isEmpty }
                try require(received[1] == Array("ok".utf8) && committed[1] == ["ok"], "right input is independent")
                pass("native text-input client preedit, commit and first-responder switching")

                for text in ["한글", "👩🏽‍💻", "e\u{301}"] {
                    let before = received[1]
                    surfaces[1].setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0), replacementRange: unspecified)
                    try require(surfaces[1].hasMarkedText() && received[1] == before, "composition must not send preedit")
                    var actual = NSRange()
                    let marked = surfaces[1].attributedSubstring(forProposedRange: surfaces[1].markedRange(), actualRange: &actual)
                    try require(marked?.string == text && actual.length == (text as NSString).length, "UTF-16 marked ranges must cover the complete composition")
                    surfaces[1].insertText(text, replacementRange: unspecified)
                    try await wait("multiscript commit") { self.received[1] == before + Array(text.utf8) }
                }
                let beforeCancel = received[1]
                surfaces[1].setMarkedText("discard", selectedRange: NSRange(location: 2, length: 3), replacementRange: unspecified)
                surfaces[1].doCommand(by: #selector(NSResponder.cancelOperation(_:)))
                try require(!surfaces[1].hasMarkedText() && received[1] == beforeCancel, "cancel must discard composition without sending bytes")
                surfaces[1].setMarkedText("focus", selectedRange: NSRange(location: 5, length: 0), replacementRange: unspecified)
                try require(window.makeFirstResponder(surfaces[0]) && !surfaces[1].hasMarkedText(), "focus loss must cancel the former pane's composition")
                try require(received[1] == beforeCancel, "focus loss cannot commit cancelled preedit")
                pass("Korean, emoji, combining-text commit plus cancel and focus-loss composition checks")

                guard let deletion = NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
                    isARepeat: false, keyCode: 51) else { throw Failure(message: "composition deletion event") }
                for text in ["ㄱ", "e\u{301}", "👩🏽‍💻"] {
                    let before = received[1], commitsBefore = committed[1]
                    surfaces[1].setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0), replacementRange: unspecified)
                    surfaces[1].interpretCompositionKey(deletion) {
                        surfaces[1].insertText(text, replacementRange: unspecified)
                        surfaces[1].doCommand(by: #selector(NSResponder.deleteBackward(_:)))
                        return true
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                    try require(!surfaces[1].hasMarkedText() && received[1] == before && committed[1] == commitsBefore,
                                "same-key insertion and deletion must emit no text or PTY bytes")
                }
                let beforePartialDelete = received[1]
                surfaces[1].setMarkedText("한글", selectedRange: NSRange(location: 2, length: 0), replacementRange: unspecified)
                surfaces[1].interpretCompositionKey(deletion) {
                    surfaces[1].insertText("한글", replacementRange: unspecified)
                    surfaces[1].doCommand(by: #selector(NSResponder.deleteBackward(_:)))
                    return true
                }
                try await wait("net committed text after deletion") { self.received[1] == beforePartialDelete + Array("한".utf8) }
                try require(committed[1].last == "한", "deletion preserves the remaining committed text")
                let beforeNewPreedit = received[1]
                surfaces[1].setMarkedText("가", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
                surfaces[1].interpretCompositionKey(deletion) {
                    surfaces[1].insertText("가", replacementRange: unspecified)
                    surfaces[1].setMarkedText("나", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
                    return true
                }
                try await wait("commit followed by new preedit") { self.received[1] == beforeNewPreedit + Array("가".utf8) }
                try require(surfaces[1].hasMarkedText() && surfaces[1].markedTextPresentationForTesting?.text == "나",
                            "flushing committed text must preserve new composition")
                surfaces[1].doCommand(by: #selector(NSResponder.cancelOperation(_:)))
                pass("same-key IME deletion is atomic for Hangul, combining and emoji text; remaining commits and new preedit survive")

                let originalFont = surfaces[0].font
                for entry in FontLoader.bundledFonts {
                    let started = ProcessInfo.processInfo.systemUptime
                    let count = presentations[0].count
                    guard let font = FontLoader.font(named: entry.fontName, size: 14) else {
                        throw Failure(message: "Bundled font unavailable: " + entry.fontName)
                    }
                    surfaces[0].font = font
                    surfaces[0].feed(text: "\r\u{1b}[2Kfont é 中文 😀 \u{10ffff}")
                    try await wait("new-font drawable") { self.currentSizePresented(0, after: count) }
                    try require(surfaces[0].cellSize.width > 0 && surfaces[0].cellSize.height > 0,
                                "font metrics must remain usable")
                    fontFirstFrameMilliseconds[entry.fontName] = (ProcessInfo.processInfo.systemUptime - started) * 1000
                }
                surfaces[0].font = originalFont
                surfaces[0].feed(text: "\r\u{1b}[2K" + seed[0])
                try await wait("original font restores content") { self.rowText(0).hasPrefix(seed[0]) }
                pass("all bundled fonts render fallback/missing glyphs and restore the original font")

                let beforeHide = presentations[1].count
                window.orderOut(nil)
                surfaces[1].feed(text: "\r\u{1b}[2K" + seed[1] + " hidden recovery")
                try await Task.sleep(for: .milliseconds(120))
                window.makeKeyAndOrderFront(nil)
                try await wait("restored window drawable") { self.currentSizePresented(1, after: beforeHide) }
                try require(rowText(1).hasPrefix(seed[1] + " hidden recovery"), "hidden output must survive presentation recovery")
                pass("hidden-window output recovers with current source and geometry")

                let oldColumns = surfaces.map { $0.engine.cols }
                let counts = presentations.map(\.count)
                layout(NSSize(width: 960, height: 430))
                try await wait("resized grids") { zip(self.surfaces, oldColumns).allSatisfy { $0.0.engine.cols > $0.1 } }
                try await wait("new-size on-screen drawables") { (0..<2).allSatisfy { self.currentSizePresented($0, after: counts[$0]) } }
                try require((0..<2).allSatisfy { rowText($0).hasPrefix(seed[$0]) }, "resize must preserve both surfaces' content")
                pass("programmatic native-window resize updates both grids and presented drawable dimensions")

                let surface = surfaces[0]
                let originalRows = surface.engine.rows
                let rowHeight = surface.cellSize.height
                surface.minimumBottomContentInset = rowHeight
                try require(surface.engine.rows == originalRows - 1
                    && surface.bottomContentInset == rowHeight,
                    "bottom edge margin must exclude a full row from the terminal and PTY grid")
                surface.bottomContentInset = rowHeight * 2
                try require(surface.engine.rows == originalRows - 2
                    && surface.bottomContentInset == rowHeight * 2,
                    "panel reservation must overlap, not add to, the bottom edge margin")
                surface.bottomContentInset = 0
                try require(surface.engine.rows == originalRows - 1
                    && surface.bottomContentInset == rowHeight,
                    "closing a panel must preserve the configured bottom edge margin")
                let insetCounts = presentations[0].count
                surface.minimumBottomContentInset = 0
                try require(surface.engine.rows == originalRows && surface.bottomContentInset == 0,
                    "removing the configured margin must restore the original row count")
                try await wait("drawable after bottom inset restoration") {
                    self.currentSizePresented(0, after: insetCounts)
                }
                pass("bottom grid margin composes with panel reservation and restores rows and presentation")

                let leftRenderer = surfaces[0].metalRenderer
                surfaces[0].terminate()
                await leftRenderer?.shutdown()
                let leftCount = presentations[0].count, rightCount = presentations[1].count
                surfaces[1].feed(text: "\r\nsurvivor")
                try await wait("surviving surface presents") { self.presentations[1].count > rightCount }
                try require(presentations[0].count == leftCount && surfaces[1].isUsingMetalRenderer,
                            "closed surface must not publish callbacks; sibling stays active")
                pass("one surface closes and drains while its sibling continues presenting")
            } catch let failure as Failure { errors.append(failure.message) }
              catch { errors.append(String(describing: error)) }
            lastPublishedRows = surfaces.indices.map(rowText)
            let renderers = surfaces.compactMap(\.metalRenderer)
            for surface in surfaces { surface.terminate() }
            for renderer in renderers { await renderer.shutdown() }
            window?.close()
            if errors.isEmpty {
                do {
                    for _ in 0..<24 {
                        let lifetime = try await lifetimeCycle()
                        try await Task.sleep(for: .milliseconds(10))
                        try require(lifetime.surface == nil && lifetime.renderer == nil,
                                    "closed surface or renderer survived its lifetime cycle")
                        releasedLifetimeCycles += 1
                    }
                    pass("24 repeated visible-window/surface lifetimes release every surface and renderer")
                } catch { errors.append(String(describing: error)) }
            }
            if errors.isEmpty { pass("all surfaces and the native window close after awaited render-worker shutdown") }
            else { for error in errors { print("FAIL: \(error)") } }
            return errors.isEmpty
        }

        private final class Lifetime {
            weak var surface: CmdyTerminalSurface?
            weak var renderer: MetalTerminalRenderer?
            var presented = false
        }
        private func lifetimeCycle() async throws -> Lifetime {
            let lifetime = Lifetime()
            let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 640, height: 300),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let surface = CmdyTerminalSurface(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
            window.contentView = surface
            try surface.setUseMetal(true)
            lifetime.surface = surface; lifetime.renderer = surface.metalRenderer
            surface.metalRenderer?.onDrawablePresentedForTesting = { value in
                if value.presented { lifetime.presented = true }
            }
            window.makeKeyAndOrderFront(nil)
            surface.feed(text: (0..<200).map { "lifetime-\($0) é 中文 😀" }.joined(separator: "\r\n")
                + "\u{1b}[?1049hALTERNATE\u{1b}[?1049l")
            try await wait("lifetime drawable") { lifetime.presented }
            let renderer = surface.metalRenderer
            surface.terminate()
            await renderer?.shutdown()
            window.contentView = nil
            window.close()
            return lifetime
        }
    }
}
