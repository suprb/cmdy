import AppKit
import WebKit
import CmdySDK

// detox — a live-coding modular synth for cmdy (built on the codio engine), as an EXTERNAL plugin.
// cmdy launches this process; everything it does goes through the public
// SDK (commands, the inline editor panel, events) — the same surface any
// third-party plugin gets. The audio engine (CodioCore, WebAudio) runs in a
// hidden WKWebView inside THIS process, so the music is ours to own.

final class DetoxApp: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    let cmdy: Cmdy
    var webView: WKWebView?
    var engineReady = false
    var queued: [() -> Void] = []
    var isPlaying = false
    var lastLog = ""
    var panelId: String?

    var bufferURL: URL {
        HostProductIdentity.configurationDirectory
            .appendingPathComponent("audio/session.detox")
    }

    init(cmdy: Cmdy) {
        self.cmdy = cmdy
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One-time: carry the pre-rename session buffer over.
        let old = bufferURL.deletingLastPathComponent().appendingPathComponent("session.codio")
        if !FileManager.default.fileExists(atPath: bufferURL.path),
           FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.copyItem(at: old, to: bufferURL)
        }
        cmdy.registerCommand(id: "detox.editor", title: "Detox: Editor… (live-code the synth)", plugin: "Detox")
        cmdy.registerCommand(id: "detox.stop", title: "Detox: Stop Audio", plugin: "Detox")
        cmdy.onEvent = { [weak self] event in self?.handle(event) }
        cmdy.listen()
        ensureEngine { }   // warm boot
    }

    // MARK: - cmdy events

    func handle(_ event: [String: Any]) {
        switch event["kind"] as? String {
        case "command":
            switch event["id"] as? String {
            case "detox.editor": openEditor()
            case "detox.stop": stopAudio()
            default: break
            }
        case "ui":
            guard let panel = event["panel"] as? String, panel == panelId else { return }
            switch event["event"] as? String {
            case "evaluate":
                run(event["value"] as? String ?? "")
            case "changed":
                let text = event["value"] as? String ?? ""
                try? FileManager.default.createDirectory(
                    at: bufferURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: bufferURL, atomically: true, encoding: .utf8)
            case "dismissed":
                panelId = nil
            default: break
            }
        default:
            break
        }
    }

    func openEditor() {
        let saved = readBuffer() ?? Self.starterPattern
        cmdy.openPanel([
            "mode": "editor",
            "title": "✦ detox — live synth",
            "body": saved,
            "hint": hint,
        ]) { [weak self] id in
            self?.panelId = id
        }
    }

    private func readBuffer() -> String? {
        guard let handle = try? FileHandle(forReadingFrom: bufferURL) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16 * 1024 * 1024 + 1),
              data.count <= 16 * 1024 * 1024 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var hint: String {
        (isPlaying ? "♪ playing · " : "") + "⌘⏎ play buffer · esc hide (audio keeps going)"
            + (lastLog.isEmpty ? "" : " · \(lastLog)")
    }

    func refreshHint() {
        if let panelId { cmdy.updatePanel(panelId, ["hint": hint]) }
    }

    // MARK: - The engine (CodioCore in a hidden webview)

    func run(_ code: String) {
        ensureEngine { [weak self] in
            guard let self, let wv = self.webView,
                  let data = try? JSONSerialization.data(withJSONObject: [code]),
                  let json = String(data: data, encoding: .utf8) else { return }
            wv.evaluateJavaScript("window.detox.run(\(json)[0])", completionHandler: nil)
            self.isPlaying = true
            self.refreshHint()
        }
    }

    func stopAudio() {
        webView?.evaluateJavaScript("window.detox.stop()", completionHandler: nil)
        isPlaying = false
        lastLog = ""
        refreshHint()
    }

    func ensureEngine(_ done: @escaping () -> Void) {
        if engineReady { done(); return }
        queued.append(done)
        guard webView == nil else { return }

        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        config.userContentController.add(self, name: "detox")
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        webView = wv

        guard let dir = Bundle.module.url(forResource: "Detox", withExtension: nil) else {
            NSLog("detox: engine resources missing")
            return
        }
        wv.loadFileURL(dir.appendingPathComponent("harness.html"), allowingReadAccessTo: dir)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let kind = body["kind"] as? String else { return }
        switch kind {
        case "ready":
            NSLog("detox: engine ready")
            engineReady = true
            let q = queued
            queued = []
            q.forEach { $0() }
        case "error":
            lastLog = "⚠ \(body["text"] as? String ?? "error")"
            refreshHint()
        case "log":
            lastLog = body["text"] as? String ?? ""
            refreshHint()
        case "stopped":
            isPlaying = false
            refreshHint()
        default:
            break
        }
    }

    static let starterPattern = """
    // detox — live-code a modular synth. ⌘⏎ plays this buffer, esc hides
    // the editor (the music keeps going), "Detox: Stop Audio" silences it.
    //
    //   osc(440)  osc(C4, sine|square|triangle|sawtooth)   oscillators
    //   seq([C3, .., E3, G3], 8)                           step sequencer (.. = rest)
    //   -> lpf(1200) -> gain(0.5) -> reverb(0.3) -> out    chain effects to the speakers
    //   lfo(0.1, 400, 2000)                                modulate any parameter
    //   out(mixA, 1) / in(mixA, 1, 2)                      named mixer buses

    seq([C3, .., E3, G3, .., B3, .., D4], 8) -> osc(sine) -> gain(0.35) -> out(mix, 1)
    seq([.., C5, .., .., E5, .., G5, ..], 8) -> osc(triangle) -> gain(0.15) -> out(mix, 2)
    in(mix, 1, 2) -> lpf(1400, 0, lfo(0.07, 500, 2400)) -> reverb(0.35) -> out
    """
}

guard let cmdy = Cmdy() else {
    FileHandle.standardError.write(Data(
        ("detox: not launched by \(HostProductIdentity.name) "
            + "(missing \(HostProductIdentity.environmentPrefix)_PORT/TOKEN)\n").utf8))
    exit(1)
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)   // invisible agent — no dock, no menu
let delegate = DetoxApp(cmdy: cmdy)
app.delegate = delegate
app.run()
