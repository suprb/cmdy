import Foundation
import AppKit
import CoreGraphics

/// Owns one Chrome process and CDP connection per bound session. Each adapter
/// has an isolated profile directory and debugging port.
@MainActor
final class ChromeAdapter: TargetAdapter {
    /// TargetAdapter conformance: anchor visuals + wire to the Chrome process.
    var anchorPid: pid_t? { chromeProcessPid }

    /// Mutable so `relaunch(newCdpPort:)` can grab a fresh port (the dead
    /// process's old port may still be lingering for a few seconds).
    private(set) var cdpPort: Int
    let profileDir: String
    private(set) var isLaunched: Bool = false

    private let cdpClient = CDPClient()
    private var chromeProcess: Process?

    /// PID of the launched Chrome process, exposed so the wire-overlay can find
    /// the corresponding window via CGWindowList. nil before launch / after terminate.
    var chromeProcessPid: pid_t? { chromeProcess?.processIdentifier }

    /// Fires on the main actor when the Chrome process terminates (window closed,
    /// quit, or crashed). The delegate uses this to auto-unbind the session so the
    /// popover doesn't show a stale binding for a Chrome window that no longer exists.
    var onTerminated: (() -> Void)?

    private var consoleMessages: [[String: Any]] = []
    private var networkRequests: [[String: Any]] = []

    /// Last URL the bound Chrome was on. Updated via `Page.frameNavigated`. Used
    /// by `relaunch()` so the user gets back to where they were after a crash /
    /// accidental window close. Persists across the dead-adapter window.
    private(set) var lastURL: String?

    // Common Chrome installation paths on macOS
    private static let chromePaths = [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    ]

    enum ChromeError: Error, LocalizedError {
        case chromeNotFound
        case launchFailed(String)
        case connectionFailed(String)
        case notConnected

        var errorDescription: String? {
            switch self {
            case .chromeNotFound: return "Chrome not found. Install Google Chrome."
            case .launchFailed(let msg): return "Failed to launch Chrome: \(msg)"
            case .connectionFailed(let msg): return "Failed to connect to Chrome: \(msg)"
            case .notConnected: return "Not connected to Chrome"
            }
        }
    }

    /// Optional initial window frame in CG coords (top-left origin). When set,
    /// passed to Chrome as `--window-position=X,Y` + `--window-size=W,H` so the
    /// window appears AT the right place from the first frame instead of
    /// opening at its profile-default position then jumping after AX repositions
    /// it. Used by `BridgeAppDelegate.bindSessionToChrome`.
    private let initialFrame: CGRect?

    init(cdpPort: Int, profileDir: String, initialFrame: CGRect? = nil) {
        self.cdpPort = cdpPort
        self.profileDir = profileDir
        self.initialFrame = initialFrame
    }

    // MARK: - Chrome Lifecycle

    func launch() async throws {
        guard let path = Self.findChrome() else {
            throw ChromeError.chromeNotFound
        }

        // Create the profile directory.
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: profileDir),
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        var args: [String] = [
            "--remote-debugging-port=\(cdpPort)",
            "--no-first-run",
            "--no-default-browser-check",
            "--user-data-dir=\(profileDir)",
            "--app=about:blank",
        ]
        if let f = initialFrame,
           f.origin.x.isFinite, f.origin.y.isFinite,
           f.width.isFinite, f.height.isFinite,
           f.width > 0, f.height > 0 {
            let x = Int(f.origin.x.rounded())
            let y = Int(f.origin.y.rounded())
            let w = Int(f.width.rounded())
            let h = Int(f.height.rounded())
            args.append("--window-position=\(x),\(y)")
            args.append("--window-size=\(w),\(h)")
        } else {
            args.append("--window-size=1024,768")
        }
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            chromeProcess = process
            NSLog("[ChromeAdapter] Launched Chrome PID %d on CDP port %d", process.processIdentifier, cdpPort)
            // Fire onTerminated when the user closes the Chrome window. macOS Chrome
            // doesn't always EXIT the process when the last window closes (it can
            // stay alive in the background), so two signals matter:
            //   1) Process termination — Cmd+Q, crash, parent kill.
            //   2) CDP websocket disconnect — last page/window closed.
            // Both converge on `markDisconnected()` so the UI / wire react either way.
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor [weak self] in self?.markDisconnected(reason: "process exit") }
            }
        } catch {
            throw ChromeError.launchFailed(error.localizedDescription)
        }

        try await connectCDP()
        isLaunched = true
    }

    /// Re-launch Chrome on a fresh CDP port using the SAME profile dir (so
    /// cookies/storage/extensions persist) and navigate back to `lastURL` if
    /// known. Used by the popover's "Reopen Chrome" affordance after the user
    /// closed the bound Chrome window. Caller passes a freshly-allocated port —
    /// don't reuse the dead one (it can take a moment to free).
    func relaunch(newCdpPort: Int) async throws {
        await cdpClient.disconnect()
        chromeProcess?.terminate()
        chromeProcess = nil
        isLaunched = false
        // Belt-and-suspenders: kill any other Chrome instance still holding our
        // profile dir's singleton lock. Without this the new launch piggybacks
        // on the existing process and CDP never starts.
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-f", "user-data-dir=\(profileDir)"]
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        try? killer.run()
        killer.waitUntilExit()
        try? await Task.sleep(nanoseconds: 400_000_000)  // let Chrome release lock
        cdpPort = newCdpPort
        let restoreURL = lastURL
        try await launch()
        if let url = restoreURL {
            try? await navigate(to: url)
        }
    }

    /// Single convergence point for "Chrome is no longer reachable" — fired by
    /// either process termination OR CDP websocket disconnect. Idempotent (the
    /// `isLaunched` guard means a process exit + CDP disconnect in quick
    /// succession only fire `onTerminated` once).
    private func markDisconnected(reason: String) {
        if isLaunched {
            isLaunched = false
            NSLog("[ChromeAdapter] Chrome disconnected (CDP %d, reason: %@)", cdpPort, reason)
            onTerminated?()
        }
    }

    func terminate() {
        Task { [cdpClient] in await cdpClient.disconnect() }
        chromeProcess?.terminate()
        chromeProcess = nil
        isLaunched = false
        NSLog("[ChromeAdapter] Terminated CDP %d", cdpPort)
    }

    /// TargetAdapter conformance — async wrapper around the existing sync
    /// terminate(). Awaits the CDP disconnect so the caller can know we're
    /// fully torn down. Idempotent (already-disconnected calls are no-ops).
    func shutdown() async {
        await cdpClient.disconnect()
        chromeProcess?.terminate()
        chromeProcess = nil
        isLaunched = false
        NSLog("[ChromeAdapter] Shutdown CDP %d", cdpPort)
    }

    // MARK: - CDP Connection

    private func connectCDP(maxRetries: Int = 10) async throws {
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                let targetsURL = URL(string: "http://localhost:\(cdpPort)/json")!
                let (data, _) = try await URLSession.shared.data(from: targetsURL)

                guard let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                      let firstTarget = targets.first(where: { ($0["type"] as? String) == "page" }),
                      let wsUrl = firstTarget["webSocketDebuggerUrl"] as? String,
                      let url = URL(string: wsUrl) else {
                    throw ChromeError.connectionFailed("No page targets found")
                }

                try await cdpClient.connect(to: url)

                _ = try await cdpClient.send(method: "Page.enable")
                _ = try await cdpClient.send(method: "Runtime.enable")
                _ = try await cdpClient.send(method: "Console.enable")
                _ = try await cdpClient.send(method: "Network.enable")

                await cdpClient.subscribe(to: "Console.messageAdded") { [weak self] params in
                    guard let self = self else { return }
                    if let message = params["message"] as? [String: Any] {
                        Task { @MainActor in
                            self.consoleMessages.append(message)
                            if self.consoleMessages.count > 500 {
                                self.consoleMessages.removeFirst()
                            }
                        }
                    }
                }

                // Track current URL so a later relaunch can restore it.
                await cdpClient.subscribe(to: "Page.frameNavigated") { [weak self] params in
                    guard let self = self,
                          let frame = params["frame"] as? [String: Any],
                          frame["parentId"] == nil,                                // top-level frame only
                          let url = frame["url"] as? String,
                          url != "about:blank" else { return }
                    Task { @MainActor in self.lastURL = url }
                }

                await cdpClient.subscribe(to: "Network.responseReceived") { [weak self] params in
                    guard let self = self else { return }
                    Task { @MainActor in
                        self.networkRequests.append(params)
                        if self.networkRequests.count > 200 {
                            self.networkRequests.removeFirst()
                        }
                    }
                }

                // CDP-disconnect signal: when Chrome closes the page (window-close
                // even if process lingers), our websocket dies. Fires the same
                // markDisconnected path as Process.terminationHandler.
                await cdpClient.setOnDisconnected { [weak self] in
                    Task { @MainActor [weak self] in self?.markDisconnected(reason: "CDP disconnect") }
                }

                // Window-close-without-process-exit signal: macOS Chrome keeps
                // its process alive after the last window closes (stays in the
                // menu bar with no windows). Process.terminationHandler doesn't
                // fire for window-close, and depending on Chrome's launch
                // semantics the CDP socket may not cleanly close either. The
                // protocol-level signal is `Inspector.detached` — fires when
                // the inspected target goes away. Subscribe and converge on
                // markDisconnected so the bind lifecycle (and the `+`
                // affordance for re-binding) works whether Chrome dies via
                // process exit, CDP socket close, or just window close.
                await cdpClient.subscribe(to: "Inspector.detached") { [weak self] params in
                    let reason = (params["reason"] as? String) ?? "unknown"
                    Task { @MainActor [weak self] in
                        self?.markDisconnected(reason: "Inspector.detached: \(reason)")
                    }
                }

                NSLog("[ChromeAdapter] CDP connected to %@", wsUrl)
                return

            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: UInt64(500_000_000 * (attempt + 1)))
            }
        }

        throw ChromeError.connectionFailed(lastError?.localizedDescription ?? "Unknown error")
    }

    // MARK: - Browser Control

    func navigate(to url: String) async throws {
        var fullUrl = url
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") && !url.hasPrefix("file://") {
            fullUrl = "https://\(url)"
        }
        _ = try await cdpClient.send(method: "Page.navigate", params: ["url": fullUrl])
    }

    func reload(ignoreCache: Bool = false) async throws {
        _ = try await cdpClient.send(method: "Page.reload", params: ["ignoreCache": ignoreCache])
    }

    /// Snapshot the current page into a structured blob: URL, title, headings,
    /// visible buttons, links, forms, error/alert banners. Single CDP
    /// `Runtime.evaluate` call (~30–50ms typical). Used by `BridgeToolRouter`
    /// to attach a `pageContext` field to every state-mutating tool's response
    /// so Claude doesn't need to follow up with `get_content` / `screenshot`
    /// to figure out what just happened.
    ///
    /// Best-effort: heuristic visibility filter (excludes display:none / 0×0
    /// rects), conservative caps on each list (10 headings, 20 buttons, etc.)
    /// so the response stays compact even on large pages. Whitespace is
    /// trimmed and text is truncated to 80 chars per item.
    ///
    /// Caller is expected to swallow errors — page might be mid-navigation,
    /// CDP might be transient. Returns nil rather than throwing.
    func pageContext() async -> [String: Any]? {
        let js = """
        (() => {
          const trim = s => (s || '').replace(/\\s+/g, ' ').trim().slice(0, 80);
          const visible = el => {
            const r = el.getBoundingClientRect();
            if (r.width < 1 || r.height < 1) return false;
            const cs = getComputedStyle(el);
            if (cs.visibility === 'hidden' || cs.display === 'none' || parseFloat(cs.opacity) === 0) return false;
            return true;
          };
          const sel = el => el.id ? '#' + el.id : null;

          const headings = Array.from(document.querySelectorAll('h1, h2, h3'))
            .filter(visible).slice(0, 10)
            .map(h => ({ tag: h.tagName.toLowerCase(), text: trim(h.innerText || h.textContent) }))
            .filter(h => h.text);

          const buttons = Array.from(document.querySelectorAll(
            'button, [role="button"], input[type="submit"], input[type="button"], a.btn, a[role="button"]'
          )).filter(visible).slice(0, 20)
            .map(b => ({
              label: trim(b.innerText || b.textContent || b.value || b.getAttribute('aria-label') || b.getAttribute('title')),
              selector: sel(b)
            }))
            .filter(b => b.label);

          const links = Array.from(document.querySelectorAll('a[href]'))
            .filter(visible).slice(0, 15)
            .map(a => ({ text: trim(a.innerText || a.textContent), href: a.getAttribute('href') }))
            .filter(l => l.text);

          const forms = Array.from(document.forms).slice(0, 5).map(f => ({
            id: f.id || null,
            action: f.action || null,
            fields: Array.from(f.elements).slice(0, 12)
              .map(e => ({
                name: e.name || e.id || null,
                type: (e.type || e.tagName || '').toLowerCase(),
                placeholder: e.placeholder || null,
                required: !!e.required
              }))
              .filter(e => e.name)
          }));

          const errors = Array.from(document.querySelectorAll(
            '[role="alert"], .error, .alert, .toast, [class*="error" i], [class*="alert" i]'
          )).filter(visible).slice(0, 5)
            .map(e => trim(e.innerText || e.textContent))
            .filter(Boolean);

          return {
            url: location.href,
            title: document.title || '',
            headings, buttons, links, forms,
            errors: errors.length ? errors : undefined,
            readyState: document.readyState
          };
        })()
        """
        guard let raw = try? await executeJS(js) else { return nil }
        return raw as? [String: Any]
    }

    /// Hot-swap CSS without reloading the page. For each watched file basename,
    /// finds matching `<link rel="stylesheet">` elements and bumps a cache-busting
    /// query param, which forces the browser to re-fetch the stylesheet while
    /// preserving page state (scroll position, form input, JS state). Returns
    /// the count of swapped links — caller can fall back to full reload if zero.
    @discardableResult
    func hotReloadCSS(filenames: [String]) async -> Int {
        let bases = Set(filenames.prefix(1_000).map { ($0 as NSString).lastPathComponent })
        guard !bases.isEmpty else { return 0 }
        let nameList = bases.map { "'\(jsEscape($0))'" }.joined(separator: ",")
        let js = """
        (() => {
          const names = new Set([\(nameList)]);
          let n = 0;
          document.querySelectorAll('link[rel="stylesheet"]').forEach(link => {
            try {
              const url = new URL(link.href, document.baseURI);
              const last = url.pathname.split('/').pop();
              if (names.has(last)) {
                url.searchParams.set('_t', Date.now().toString());
                link.href = url.toString();
                n++;
              }
            } catch (e) {}
          });
          return n;
        })()
        """
        let result = (try? await executeJS(js)) ?? nil
        if let count = result as? Int { return count }
        if let d = result as? Double { return Int(d) }
        return 0
    }

    func goBack() async throws {
        let history = try await cdpClient.send(method: "Page.getNavigationHistory")
        if let currentIndex = history["currentIndex"] as? Int, currentIndex > 0,
           let entries = history["entries"] as? [[String: Any]] {
            let entryId = entries[currentIndex - 1]["id"] as? Int ?? 0
            _ = try await cdpClient.send(method: "Page.navigateToHistoryEntry", params: ["entryId": entryId])
        }
    }

    func goForward() async throws {
        let history = try await cdpClient.send(method: "Page.getNavigationHistory")
        if let currentIndex = history["currentIndex"] as? Int,
           let entries = history["entries"] as? [[String: Any]],
           currentIndex < entries.count - 1 {
            let entryId = entries[currentIndex + 1]["id"] as? Int ?? 0
            _ = try await cdpClient.send(method: "Page.navigateToHistoryEntry", params: ["entryId": entryId])
        }
    }

    func screenshot(format: String = "png", quality: Int = 80, clip: CGRect? = nil) async throws -> Data {
        let safeFormat = format == "jpeg" ? "jpeg" : "png"
        var params: [String: Any] = ["format": safeFormat]
        if safeFormat == "jpeg" { params["quality"] = min(max(quality, 0), 100) }
        if let clip = clip,
           clip.origin.x.isFinite, clip.origin.y.isFinite,
           clip.width.isFinite, clip.height.isFinite,
           clip.width > 0, clip.height > 0,
           clip.width <= 16_384, clip.height <= 16_384 {
            params["clip"] = [
                "x": clip.origin.x,
                "y": clip.origin.y,
                "width": clip.width,
                "height": clip.height,
                "scale": 1.0,
            ]
            // Deliberately NOT setting `captureBeyondViewport: true`. That flag
            // forces Chrome's compositor to render off-viewport content, which
            // triggers a visible page flash. Inspector clips are always within
            // the visible viewport, so the default (fromSurface=true,
            // captureBeyondViewport=false) is faster AND flash-free.
        }
        let result = try await cdpClient.send(method: "Page.captureScreenshot", params: params)
        guard let base64 = result["data"] as? String,
              let data = Data(base64Encoded: base64) else {
            throw ChromeError.notConnected
        }
        return data
    }

    func executeJS(_ expression: String) async throws -> Any? {
        let result = try await cdpClient.send(method: "Runtime.evaluate", params: [
            "expression": expression,
            "returnByValue": true,
        ])
        if let exceptionDetails = result["exceptionDetails"] as? [String: Any],
           let exception = exceptionDetails["text"] as? String {
            throw ChromeError.connectionFailed("JS error: \(exception)")
        }
        let resultObj = result["result"] as? [String: Any]
        return resultObj?["value"]
    }

    func click(selector: String) async throws {
        let escaped = jsEscape(selector)
        _ = try await executeJS("""
            (() => {
                const el = document.querySelector('\(escaped)');
                if (!el) throw new Error('Element not found: \(escaped)');
                el.click();
                return true;
            })()
        """)
    }

    func type(selector: String, text: String, clear: Bool = false) async throws {
        let escapedSelector = jsEscape(selector)
        let escapedText = jsEscape(text)
        _ = try await executeJS("""
            (() => {
                const el = document.querySelector('\(escapedSelector)');
                if (!el) throw new Error('Element not found');
                el.focus();
                if (\(clear)) el.value = '';
                el.value += '\(escapedText)';
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                return true;
            })()
        """)
    }

    func getContent(selector: String? = nil, type: String = "text") async throws -> String {
        let js: String
        if let sel = selector {
            let escaped = jsEscape(sel)
            js = type == "html"
                ? "document.querySelector('\(escaped)')?.outerHTML || ''"
                : "document.querySelector('\(escaped)')?.textContent || ''"
        } else {
            js = type == "html"
                ? "document.documentElement.outerHTML"
                : "document.body.innerText"
        }
        let content = try await executeJS(js) as? String ?? ""
        return String(content.prefix(2 * 1024 * 1024))
    }

    func getTitle() async throws -> String {
        return try await executeJS("document.title") as? String ?? ""
    }

    func getURL() async throws -> String {
        return try await executeJS("window.location.href") as? String ?? ""
    }

    // MARK: - Console buffer

    func getConsoleMessages(type: String? = nil, limit: Int = 50, pattern: String? = nil) -> [[String: Any]] {
        var messages = consoleMessages
        if let type = type, type != "all" {
            messages = messages.filter { ($0["level"] as? String) == type }
        }
        if let pattern = pattern, pattern.count <= 2_048,
           let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            messages = messages.filter { msg in
                let text = (msg["text"] as? String) ?? ""
                return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }
        }
        return Array(messages.suffix(min(max(limit, 0), 500)))
    }

    func clearConsole() {
        consoleMessages.removeAll()
    }

    // MARK: - Network buffer

    func getNetworkRequests(urlPattern: String? = nil, limit: Int = 50) -> [[String: Any]] {
        var requests = networkRequests
        if let pattern = urlPattern {
            requests = requests.filter { req in
                let url = (req["response"] as? [String: Any])?["url"] as? String ?? ""
                return url.contains(pattern)
            }
        }
        return Array(requests.suffix(min(max(limit, 0), 200)))
    }

    func clearNetwork() {
        networkRequests.removeAll()
    }

    func getFailedRequests(limit: Int = 50) -> [[String: Any]] {
        let failed = networkRequests.filter { req in
            let response = req["response"] as? [String: Any]
            let status = response?["status"] as? Int ?? 0
            return status >= 400
        }
        return Array(failed.suffix(min(max(limit, 0), 200)))
    }

    // MARK: - Mouse / Interaction

    func hover(selector: String) async throws -> [String: Any] {
        let escaped = jsEscape(selector)
        let result = try await executeJS("""
        (function(){
          var el=document.querySelector('\(escaped)');
          if(!el) return {success:false,error:'Element not found: \(escaped)'};
          el.dispatchEvent(new MouseEvent('mouseover',{bubbles:true}));
          el.dispatchEvent(new MouseEvent('mouseenter',{bubbles:true}));
          return {success:true,hovered:'\(escaped)'};
        })()
        """)
        return (result as? [String: Any]) ?? ["success": true, "hovered": selector]
    }

    func doubleClick(selector: String) async throws {
        let escaped = jsEscape(selector)
        _ = try await executeJS("""
        (function(){
          var el=document.querySelector('\(escaped)');
          if(!el) throw new Error('Element not found: \(escaped)');
          el.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));
        })()
        """)
    }

    func rightClick(selector: String) async throws {
        let escaped = jsEscape(selector)
        _ = try await executeJS("""
        (function(){
          var el=document.querySelector('\(escaped)');
          if(!el) throw new Error('Element not found: \(escaped)');
          el.dispatchEvent(new MouseEvent('contextmenu',{bubbles:true}));
        })()
        """)
    }

    func dragDrop(source: String, target: String) async throws {
        let src = jsEscape(source)
        let tgt = jsEscape(target)
        _ = try await executeJS("""
        (function(){
          var src=document.querySelector('\(src)');
          var tgt=document.querySelector('\(tgt)');
          if(!src||!tgt) throw new Error('Elements not found');
          var dt=new DataTransfer();
          src.dispatchEvent(new DragEvent('dragstart',{dataTransfer:dt,bubbles:true}));
          tgt.dispatchEvent(new DragEvent('dragenter',{dataTransfer:dt,bubbles:true}));
          tgt.dispatchEvent(new DragEvent('dragover',{dataTransfer:dt,bubbles:true,cancelable:true}));
          tgt.dispatchEvent(new DragEvent('drop',{dataTransfer:dt,bubbles:true}));
          src.dispatchEvent(new DragEvent('dragend',{dataTransfer:dt,bubbles:true}));
        })()
        """)
    }

    func scroll(selector: String?, direction: String, amount: Int) async throws {
        if let sel = selector {
            let escaped = jsEscape(sel)
            _ = try await executeJS("(function(){var el=document.querySelector('\(escaped)');if(el){el.scrollIntoView({behavior:'smooth',block:'center'});}})();")
        } else {
            let distance = min(max(amount, 0), 100_000)
            let dy: Int
            let dx: Int
            switch direction {
            case "up": dy = -distance; dx = 0
            case "left": dy = 0; dx = -distance
            case "right": dy = 0; dx = distance
            default: dy = distance; dx = 0
            }
            _ = try await executeJS("window.scrollBy({top:\(dy),left:\(dx),behavior:'smooth'});")
        }
    }

    // MARK: - Keyboard

    func pressKey(key: String, modifiers: [String]) async throws {
        // CDP modifier bitmask: alt=1, ctrl=2, meta=4, shift=8
        var mask = 0
        for mod in modifiers {
            switch mod.lowercased() {
            case "alt": mask |= 1
            case "ctrl", "control": mask |= 2
            case "meta", "cmd", "command": mask |= 4
            case "shift": mask |= 8
            default: break
            }
        }
        let baseParams: [String: Any] = [
            "key": key,
            "modifiers": mask,
        ]
        var down = baseParams; down["type"] = "keyDown"
        var up = baseParams; up["type"] = "keyUp"
        _ = try await cdpClient.send(method: "Input.dispatchKeyEvent", params: down)
        _ = try await cdpClient.send(method: "Input.dispatchKeyEvent", params: up)
    }

    func focus(selector: String) async throws {
        let escaped = jsEscape(selector)
        _ = try await executeJS("(function(){var el=document.querySelector('\(escaped)');if(!el) throw new Error('Element not found');el.focus();})();")
    }

    // MARK: - Discovery

    func find(query: String, limit: Int = 10) async throws -> [String: Any] {
        let q = jsEscape(query)
        let safeLimit = min(max(limit, 0), 200)
        let result = try await executeJS("""
        (function(){
          var query='\(q)';
          var queryLower=query.toLowerCase();
          var results=[];
          function getSelector(el){
            if(el.id) return '#'+el.id;
            if(el.name) return el.tagName.toLowerCase()+'[name="'+el.name+'"]';
            if(el.className&&typeof el.className==='string'){
              var cls=el.className.trim().split(/\\s+/).slice(0,2).join('.');
              if(cls) return el.tagName.toLowerCase()+'.'+cls;
            }
            var parent=el.parentElement;
            if(parent){
              var sibs=Array.from(parent.children).filter(function(c){return c.tagName===el.tagName});
              return el.tagName.toLowerCase()+':nth-of-type('+(sibs.indexOf(el)+1)+')';
            }
            return el.tagName.toLowerCase();
          }
          var terms=queryLower.split(/\\s+/).filter(function(t){return t.length>2});
          var all=document.querySelectorAll('*');
          for(var i=0;i<all.length;i++){
            var el=all[i];
            if(['SCRIPT','STYLE','META','LINK','NOSCRIPT','BR','HR'].indexOf(el.tagName)>=0) continue;
            var score=0,reasons=[];
            var text=(el.innerText||'').toLowerCase();
            var ariaLabel=(el.getAttribute('aria-label')||'').toLowerCase();
            var placeholder=(el.placeholder||'').toLowerCase();
            var id=(el.id||'').toLowerCase();
            var className=(typeof el.className==='string'?el.className:'').toLowerCase();
            var role=(el.getAttribute('role')||'').toLowerCase();
            var tag=el.tagName.toLowerCase();
            var type=(el.type||'').toLowerCase();
            var isBtn=/button|btn|click|submit/i.test(query)&&(tag==='button'||type==='submit'||role==='button');
            var isInput=/input|field|text|search/i.test(query)&&(tag==='input'||tag==='textarea');
            if(isBtn){score+=20;reasons.push('button');}
            if(isInput){score+=20;reasons.push('input');}
            for(var t=0;t<terms.length;t++){
              var term=terms[t];
              if(text.includes(term)){score+=15;reasons.push('text:'+term);}
              if(ariaLabel.includes(term)){score+=20;reasons.push('aria:'+term);}
              if(placeholder.includes(term)){score+=18;reasons.push('placeholder:'+term);}
              if(id.includes(term)){score+=10;reasons.push('id:'+term);}
              if(className.includes(term)){score+=8;reasons.push('class:'+term);}
              if(role.includes(term)){score+=15;reasons.push('role:'+term);}
            }
            var rect=el.getBoundingClientRect();
            if(rect.width>0&&rect.height>0){score+=5;if(rect.top>=0&&rect.top<window.innerHeight)score+=5;}
            if(score>15) results.push({selector:getSelector(el),tag:tag,text:(el.innerText||'').substring(0,100).trim(),score:score,matchReason:reasons.join(', ')});
          }
          results.sort(function(a,b){return b.score-a.score});
          results=results.slice(0,\(safeLimit));
          return {query:query,count:results.length,elements:results};
        })()
        """)
        return (result as? [String: Any]) ?? ["query": query, "count": 0, "elements": []]
    }

    func listInteractive(limit: Int = 50) async throws -> [String: Any] {
        let safeLimit = min(max(limit, 0), 500)
        let result = try await executeJS("""
        (function(){
          var els=document.querySelectorAll('a,button,input,select,textarea,[onclick],[role="button"]');
          var items=Array.from(els).slice(0,\(safeLimit)).map(function(el,i){
            var sel=el.id?'#'+el.id:el.name?el.tagName.toLowerCase()+'[name="'+el.name+'"]':(typeof el.className==='string'&&el.className)?el.tagName.toLowerCase()+'.'+el.className.trim().split(/\\s+/)[0]:el.tagName.toLowerCase();
            return {
              index:i,tag:el.tagName.toLowerCase(),
              selector:sel,
              text:(el.innerText||el.value||el.placeholder||'').substring(0,100)
            };
          });
          return {count:items.length,elements:items};
        })()
        """)
        return (result as? [String: Any]) ?? ["count": 0, "elements": []]
    }

    func getElement(selector: String) async throws -> [String: Any] {
        let escaped = jsEscape(selector)
        let result = try await executeJS("""
        (function(){
          var el=document.querySelector('\(escaped)');
          if(!el) return {found:false,error:'Element not found'};
          var rect=el.getBoundingClientRect();
          var attrs={};
          for(var i=0;i<el.attributes.length;i++){
            var a=el.attributes[i]; attrs[a.name]=a.value;
          }
          return {
            found:true,
            tag:el.tagName.toLowerCase(),
            attributes:attrs,
            text:(el.innerText||'').substring(0,500),
            position:{x:rect.x,y:rect.y,w:rect.width,h:rect.height},
            visible:rect.width>0&&rect.height>0
          };
        })()
        """)
        return (result as? [String: Any]) ?? ["found": false]
    }

    func waitFor(selector: String, timeoutMs: Int = 5000) async throws -> [String: Any] {
        let start = Date()
        let escaped = jsEscape(selector)
        let safeTimeout = min(max(timeoutMs, 0), 120_000)
        while Date().timeIntervalSince(start) * 1000 < Double(safeTimeout) {
            let found = try await executeJS("!!document.querySelector('\(escaped)')") as? Bool ?? false
            if found {
                let waited = Int(Date().timeIntervalSince(start) * 1000)
                return ["found": true, "waitedMs": waited]
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ChromeError.connectionFailed("Timeout waiting for \(selector)")
    }

    // MARK: - Forms

    func getForms() async throws -> [String: Any] {
        let result = try await executeJS("""
        (function(){
          function getSelector(el){
            if(el.id) return '#'+el.id;
            if(el.name) return el.tagName.toLowerCase()+'[name="'+el.name+'"]';
            return el.tagName.toLowerCase();
          }
          var forms=Array.from(document.querySelectorAll('form')).slice(0,50);
          return {count:forms.length,forms:forms.map(function(f,i){
            var fields=Array.from(f.querySelectorAll('input,select,textarea')).slice(0,500).map(function(el){
              var label='';
              if(el.id){
                var lbl=document.querySelector('label[for="'+el.id+'"]');
                if(lbl) label=(lbl.innerText||'').trim();
              }
              return {name:el.name||el.id||'',type:el.type||el.tagName.toLowerCase(),value:el.value||'',label:label};
            });
            return {formIndex:i,selector:getSelector(f),fields:fields};
          })};
        })()
        """)
        return (result as? [String: Any]) ?? ["count": 0, "forms": []]
    }

    func fillForm(selector: String, fields: [String: Any]) async throws -> [String: Any] {
        let formSel = jsEscape(selector)
        // Build a JS object literal of name → value (string-coerced).
        var pairs: [String] = []
        for (name, value) in fields.prefix(500) {
            let n = jsEscape(name)
            let v = jsEscape(String(describing: value))
            pairs.append("'\(n)':'\(v)'")
        }
        let obj = "{" + pairs.joined(separator: ",") + "}"
        let result = try await executeJS("""
        (function(){
          var form=document.querySelector('\(formSel)');
          if(!form) return {filled:0,error:'Form not found'};
          var data=\(obj);
          var filled=0;
          Object.keys(data).forEach(function(name){
            var el=form.querySelector('[name="'+name+'"]')||form.querySelector('#'+name);
            if(!el) return;
            if(el.type==='checkbox'||el.type==='radio'){ el.checked=!!data[name]; }
            else { el.value=data[name]; }
            el.dispatchEvent(new Event('input',{bubbles:true}));
            el.dispatchEvent(new Event('change',{bubbles:true}));
            filled++;
          });
          return {filled:filled};
        })()
        """)
        return (result as? [String: Any]) ?? ["filled": 0]
    }

    func submitForm(selector: String) async throws {
        let escaped = jsEscape(selector)
        _ = try await executeJS("""
        (function(){
          var f=document.querySelector('\(escaped)');
          if(!f) throw new Error('Form not found: \(escaped)');
          if(typeof f.submit==='function') f.submit();
          else if(f.closest) f.closest('form')?.submit();
        })()
        """)
    }

    func selectOption(selector: String, value: String) async throws {
        let sel = jsEscape(selector)
        let val = jsEscape(value)
        _ = try await executeJS("""
        (function(){
          var el=document.querySelector('\(sel)');
          if(!el) throw new Error('Element not found: \(sel)');
          var matched=false;
          for(var i=0;i<el.options.length;i++){
            var o=el.options[i];
            if(o.value==='\(val)'||o.text==='\(val)'){ el.selectedIndex=i; matched=true; break; }
          }
          if(!matched) el.value='\(val)';
          el.dispatchEvent(new Event('input',{bubbles:true}));
          el.dispatchEvent(new Event('change',{bubbles:true}));
        })()
        """)
    }

    func setCheckbox(selector: String, checked: Bool) async throws {
        let escaped = jsEscape(selector)
        _ = try await executeJS("""
        (function(){
          var el=document.querySelector('\(escaped)');
          if(!el) throw new Error('Element not found: \(escaped)');
          el.checked=\(checked);
          el.dispatchEvent(new Event('change',{bubbles:true}));
        })()
        """)
    }

    // MARK: - Native cursor anchoring helpers
    //
    // These feed the target-agnostic `OverlayCursorController` (a borderless
    // click-through panel rendered by the bridge process itself, not the
    // page). Same mechanic the Mac App + Simulator adapters use, so all 68
    // tools share one cursor visual language.
    // "Native cursor unification" for context.

    /// Resolve a CSS selector to its element's screen-space bounding rect
    /// (top-left CG coords). Returns nil if the element doesn't exist or
    /// isn't laid out. Used by the native cursor overlay to anchor visuals
    /// at the action target before dispatch.
    ///
    /// Coord math: `getBoundingClientRect` returns layout-viewport coords
    /// (already scroll-adjusted). `window.screenX/Y` is the OS window's
    /// top-left; `outerHeight - innerHeight` is the height of everything
    /// above the page (URL bar + tab bar + bookmarks bar + docked
    /// devtools). `visualViewport` accounts for pinch-zoom on mobile-
    /// emulated pages — most desktop pages have offsetLeft/Top=0, scale=1
    /// (no-op), but mobile sites in responsive mode do scale.
    ///
    /// Known limits (cursor is purely cosmetic — clicks dispatch via CSS
    /// selector regardless, so these only affect visual alignment):
    /// - Nested iframes: querySelector runs in the top frame; iframe
    ///   contents aren't reachable from here.
    /// - Browser chrome height varies if devtools docks change while the
    ///   cursor is showing (no live re-layout).
    ///
    /// TODO: subscribe to `Page.lifecycleEvent` + scroll to keep cursor
    /// pinned to a logical page point during user-driven scroll (Phase 4.5
    /// follow-up — DOM cursor "follows scroll for free", native cursor
    /// needs an explicit subscription to match).
    func screenRectForSelector(_ selector: String) async -> CGRect? {
        let escaped = jsEscape(selector)
        let js = """
        (function(){
          var el = document.querySelector('\(escaped)');
          if (!el) return null;
          var r = el.getBoundingClientRect();
          var vv = window.visualViewport;
          var ox = vv ? vv.offsetLeft : 0;
          var oy = vv ? vv.offsetTop : 0;
          var scale = vv ? vv.scale : 1;
          return {
            x: window.screenX + (r.left - ox) * scale,
            y: window.screenY + (window.outerHeight - window.innerHeight) + (r.top - oy) * scale,
            w: r.width * scale,
            h: r.height * scale
          };
        })();
        """
        guard let dict = try? await executeJS(js) as? [String: Any],
              let x = doubleArg(dict["x"]),
              let y = doubleArg(dict["y"]),
              let w = doubleArg(dict["w"]),
              let h = doubleArg(dict["h"]),
              x.isFinite, y.isFinite, w.isFinite, h.isFinite,
              w > 0, h > 0 else {
            return nil
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Top-level Chrome window frame in screen-space CG coords (top-left
    /// origin), or nil if no on-screen window matches the bound process.
    /// Used as a fallback anchor when selector resolution fails (e.g. the
    /// element vanished between Claude's plan and the dispatch), and as the
    /// screenshot capture rect.
    func windowFrame() -> CGRect? {
        guard let pid = chromeProcessPid else { return nil }
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list {
            let owner = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            guard owner == pid, layer == 0,
                  let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  x.isFinite, y.isFinite,
                  width.isFinite, height.isFinite,
                  width > 200, height > 200 else { continue }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        return nil
    }

    /// Coerce JS-bridged numerics — Runtime.evaluate gives us NSNumber, which
    /// projects equally well to Int / Double / CGFloat. Use this when reading
    /// numeric fields out of an evaluated dict.
    private func doubleArg(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let n = raw as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: - Inspector toolbar (in-page DOM injection)

    /// Whether the Inspector toolbar is currently armed for this Chrome window.
    /// Toggled per-binding from the popover.
    private(set) var inspectorEnabled: Bool = false
    private var inspectorScriptId: String?
    /// Cached for re-invocation when the user toggles inspector off→on after a navigation.
    private var inspectorBootstrap: String?

    /// Install Bridge's in-page Inspector toolbar. Persists across
    /// navigations via `Page.addScriptToEvaluateOnNewDocument`. The page-side JS
    /// reads `window.__cmdyBridge` to know which session to POST to.
    /// Must be called after `launch()` (CDP connected) and after `sessionId` is set.
    func enableInspector(sessionId: String, httpPort: Int,
                         authenticationToken: String) async {
        let bootstrap = """
        (function(){
          window.__cmdyBridge = {
            sessionId: '\(jsEscape(sessionId))',
            port: \(httpPort),
            token: '\(jsEscape(authenticationToken))'
          };
        })();
        """ + "\n" + Self.inspectorJS
        inspectorBootstrap = bootstrap

        do {
            let result = try await cdpClient.send(method: "Page.addScriptToEvaluateOnNewDocument", params: [
                "source": bootstrap,
            ])
            inspectorScriptId = result["identifier"] as? String
            // Also evaluate immediately so the current page (already loaded) gets it.
            _ = try await executeJS(bootstrap)
            inspectorEnabled = true
            NSLog("[ChromeAdapter] Inspector enabled for session %@", sessionId)
        } catch {
            NSLog("[ChromeAdapter] enableInspector failed: %@", String(describing: error))
        }
    }

    /// Tear down the Inspector toolbar: removes the new-document hook so future
    /// navigations don't get it, and removes the toolbar/outline/popup from the
    /// currently-loaded page.
    func disableInspector() async {
        if let id = inspectorScriptId {
            _ = try? await cdpClient.send(method: "Page.removeScriptToEvaluateOnNewDocument", params: [
                "identifier": id,
            ])
            inspectorScriptId = nil
        }
        _ = try? await executeJS("""
        (function(){
          if(window.__cmdyInspector && window.__cmdyInspector.teardown){
            try{ window.__cmdyInspector.teardown(); }catch(e){}
          }
          try{ window.__cmdyInspector=null; }catch(e){}
        })();
        """)
        inspectorEnabled = false
        NSLog("[ChromeAdapter] Inspector disabled (CDP %d)", cdpPort)
    }

    // MARK: - Screenshot thumbnail (in-page DOM injection)

    /// Display a floating thumbnail of the just-captured screenshot in the bottom-left
    /// corner of the page, then fade it out. Loads the image via the bridge's HTTP
    /// server (`http://127.0.0.1:<port>/thumbnail/<filename>`) — embedding base64 in a
    /// JS string truncates above ~1MB and CSP-strict pages reject `data:` URIs.
    func showScreenshotThumbnail(filename: String, httpPort: Int,
                                 authenticationToken: String) async {
        let url = "http://127.0.0.1:\(httpPort)/thumbnail/\(filename)"
        let escaped = jsEscape(url)
        let escapedToken = jsEscape(authenticationToken)
        _ = try? await executeJS("""
        (function(){
          var t=document.createElement('img');
          t.style.cssText='position:fixed;bottom:16px;left:16px;width:160px;'+
            'border-radius:8px;box-shadow:0 4px 24px rgba(0,0,0,0.5),0 0 0 1px rgba(255,255,255,0.15);'+
            'pointer-events:none;z-index:2147483646;opacity:0;'+
            'transform:translate(calc(50vw - 50% - 16px), calc(-50vh + 50% + 16px)) scale(3);'+
            'transform-origin:bottom left;'+
            'transition:all 0.5s cubic-bezier(0.22,0.61,0.36,1);';
          document.body.appendChild(t);
          var settle=function(){
            t.style.opacity='1';
            t.style.transform='translate(0,0) scale(1)';
          };
          t.onload=function(){requestAnimationFrame(settle);};
          fetch('\(escaped)', {
            headers: { 'Authorization': 'Bearer \(escapedToken)' }
          }).then(function(response){
            if(!response.ok) throw new Error('Bridge thumbnail HTTP ' + response.status);
            return response.blob();
          }).then(function(blob){
            var objectURL=URL.createObjectURL(blob);
            t.onload=function(){
              URL.revokeObjectURL(objectURL);
              requestAnimationFrame(settle);
            };
            t.src=objectURL;
          }).catch(function(){ t.remove(); });
          setTimeout(function(){
            t.style.opacity='0';
            t.style.transform='translate(0,10px) scale(0.95)';
            setTimeout(function(){t.remove();},400);
          },5000);
        })();
        """)
    }

    // MARK: - JS escape helper

    private func jsEscape(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0C: result += "\\f"
            case 0x0D: result += "\\r"
            case 0x27: result += "\\'"
            case 0x5C: result += "\\\\"
            case 0x2028: result += "\\u2028"
            case 0x2029: result += "\\u2029"
            case 0x00...0x1F:
                result += String(format: "\\u%04X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // MARK: - Inspector JS

    /// In-page inspector. Once enabled (via popover toggle), inspect mode is ARMED:
    /// hover outlines elements, click captures `{selector, tag, text, rect, ...}`,
    /// popup with note input → POSTs to /sessions/<id>/inject. The bridge injects
    /// the markdown into the bound terminal's Claude. No floating button — the
    /// popover toggle is the on/off switch. Toggle off → `disableInspector` tears
    /// everything down.
    private static let inspectorJS = #"""
    (function(){
      var bridge = window.__cmdyBridge || {};
      try { delete window.__cmdyBridge; } catch(e) {}
      if (window.__cmdyInspector) return;
      if (!bridge.sessionId || !bridge.port || !bridge.token) return;

      var hoverEl = null, outline = null, tagPill = null, badge = null;
      var prevCursor = document.body ? document.body.style.cursor : '';
      var BLUE = '#3B82F6';
      var BLUE_FILL = 'rgba(59,130,246,0.08)';
      var BLUE_GLOW = 'rgba(59,130,246,0.18)';

      function arm(){
        if (!document.body){ setTimeout(arm, 50); return; }
        prevCursor = document.body.style.cursor;
        document.body.style.cursor = 'crosshair';
        showBadge();
        // Immediate highlight at activation: use :hover state (deepest CSS-
        // hovered element) so the user doesn't have to move the mouse first.
        var initial = document.querySelector(':hover');
        // Walk to the deepest hover descendant.
        if (initial){
          var deeper = initial.querySelector(':hover');
          while (deeper){ initial = deeper; deeper = initial.querySelector(':hover'); }
          if (initial !== document.body && initial !== document.documentElement){
            hoverEl = initial;
            renderHighlight(initial);
          }
        }
      }

      // ─── Highlight (outline + glow + tag pill) ─────────────────────────────
      function ensureOutline(){
        if (outline) return;
        outline = document.createElement('div');
        outline.style.cssText = [
          'position:fixed', 'pointer-events:none', 'z-index:2147483644',
          'border:1.5px solid ' + BLUE,
          'background:' + BLUE_FILL,
          'box-shadow:0 0 0 4px ' + BLUE_GLOW + ', 0 8px 24px rgba(0,0,0,0.10)',
          'border-radius:4px', 'box-sizing:border-box',
          // Keep the highlight stable while moving between adjacent elements.
          'transition:left 180ms cubic-bezier(0.16,1,0.3,1),top 180ms cubic-bezier(0.16,1,0.3,1),width 180ms cubic-bezier(0.16,1,0.3,1),height 180ms cubic-bezier(0.16,1,0.3,1),opacity 120ms ease',
          'opacity:0'
        ].join(';') + ';';
        document.body.appendChild(outline);
      }
      function ensureTagPill(){
        if (tagPill) return;
        tagPill = document.createElement('div');
        tagPill.style.cssText = [
          'position:fixed', 'pointer-events:none', 'z-index:2147483645',
          'background:' + BLUE, 'color:#fff',
          'font:600 11px/1 -apple-system,BlinkMacSystemFont,system-ui,sans-serif',
          'padding:4px 7px', 'border-radius:4px',
          'box-shadow:0 2px 8px rgba(59,130,246,0.35)',
          'white-space:nowrap', 'opacity:0',
          'transition:left 180ms cubic-bezier(0.16,1,0.3,1),top 180ms cubic-bezier(0.16,1,0.3,1),opacity 120ms ease'
        ].join(';') + ';';
        document.body.appendChild(tagPill);
      }
      function renderHighlight(el){
        ensureOutline(); ensureTagPill();
        var r = el.getBoundingClientRect();
        outline.style.left = r.left + 'px';
        outline.style.top = r.top + 'px';
        outline.style.width = r.width + 'px';
        outline.style.height = r.height + 'px';
        outline.style.opacity = '1';
        var label = el.tagName.toLowerCase();
        if (el.id) label += '#' + el.id;
        else if (typeof el.className === 'string' && el.className.trim()){
          var cl = el.className.trim().split(/\s+/).slice(0, 2).join('.');
          if (cl) label += '.' + cl;
        }
        label += ' · ' + Math.round(r.width) + '×' + Math.round(r.height);
        tagPill.textContent = label;
        // Place pill above the element when there's room, else inside top-left.
        var pillTop = r.top - 24;
        if (pillTop < 8) pillTop = r.top + 4;
        tagPill.style.left = Math.max(8, r.left) + 'px';
        tagPill.style.top = pillTop + 'px';
        tagPill.style.opacity = '1';
      }
      function clearHighlight(){
        if (outline){ outline.style.opacity = '0'; }
        if (tagPill){ tagPill.style.opacity = '0'; }
        hoverEl = null;
      }

      // ─── Mode badge (top-right) ────────────────────────────────────────────
      function showBadge(){
        if (badge) return;
        badge = document.createElement('div');
        badge.style.cssText = [
          'position:fixed', 'top:16px', 'right:16px', 'z-index:2147483647',
          'pointer-events:none',
          'background:rgba(17,24,39,0.92)', 'color:#fff',
          'backdrop-filter:saturate(180%) blur(12px)',
          '-webkit-backdrop-filter:saturate(180%) blur(12px)',
          'font:500 11px/1.3 -apple-system,BlinkMacSystemFont,system-ui,sans-serif',
          'padding:7px 11px', 'border-radius:8px',
          'box-shadow:0 4px 16px rgba(0,0,0,0.25), 0 0 0 0.5px rgba(255,255,255,0.06)',
          'opacity:0', 'transform:translateY(-4px)',
          'transition:opacity 200ms ease, transform 200ms ease'
        ].join(';') + ';';
        badge.innerHTML = '<span style="display:inline-block;width:6px;height:6px;border-radius:50%;background:' + BLUE + ';margin-right:6px;vertical-align:1px"></span>Inspect mode <span style="opacity:0.55;margin-left:4px">ESC to exit</span>';
        document.body.appendChild(badge);
        requestAnimationFrame(function(){
          badge.style.opacity = '1';
          badge.style.transform = 'translateY(0)';
        });
      }

      // ─── Event handlers ────────────────────────────────────────────────────
      // When the cursor passes over <body>/<html> while moving between
      // sibling elements, we'd briefly highlight the whole page — visually
      // stressful when you're trying to inspect small buttons. Instead,
      // delay body highlights by 150ms; if the cursor lands on a real
      // element before the timer fires, cancel the body update.
      var bodyHoverTimer = null;
      function onMove(e){
        var t = e.target;
        if (badge && badge.contains(t)) return;
        if (t === hoverEl) return;

        // Cancel any pending body-hover update — we have a new target.
        if (bodyHoverTimer){ clearTimeout(bodyHoverTimer); bodyHoverTimer = null; }

        if (t === document.body || t === document.documentElement){
          bodyHoverTimer = setTimeout(function(){
            bodyHoverTimer = null;
            hoverEl = t;
            renderHighlight(t);
          }, 150);
          return;
        }
        hoverEl = t;
        renderHighlight(t);
      }
      function onClick(e){
        var t = e.target;
        if (badge && badge.contains(t)) return;
        e.preventDefault(); e.stopPropagation();
        capture(t, e.clientX, e.clientY);
      }
      document.addEventListener('mousemove', onMove, true);
      document.addEventListener('click', onClick, true);

      function capture(el, clickX, clickY){
        var style = getComputedStyle(el);
        var classes = (typeof el.className === 'string')
          ? el.className.split(/\s+/).filter(Boolean).slice(0, 20) : [];
        var data = {
          selector: getSelector(el),
          tag: el.tagName.toLowerCase(),
          text: (el.innerText || el.textContent || '').trim().slice(0, 200),
          label: (el.getAttribute('aria-label') || el.getAttribute('alt') ||
                  el.getAttribute('title') || el.innerText || el.textContent || '').trim().slice(0, 160),
          rect: el.getBoundingClientRect(),
          url: window.location.href,
          title: document.title,
          clickX: (typeof clickX === 'number') ? clickX : null,
          clickY: (typeof clickY === 'number') ? clickY : null,
          classes: classes,
          accessibility: {
            role: el.getAttribute('role') || null,
            name: el.getAttribute('aria-label') || null,
            description: el.getAttribute('aria-description') || el.getAttribute('title') || null,
            expanded: el.getAttribute('aria-expanded'),
            selected: el.getAttribute('aria-selected'),
            checked: el.getAttribute('aria-checked'),
            disabled: el.getAttribute('aria-disabled') || !!el.disabled
          },
          computedStyles: {
            display: style.display, position: style.position, color: style.color,
            backgroundColor: style.backgroundColor, fontFamily: style.fontFamily,
            fontSize: style.fontSize, fontWeight: style.fontWeight,
            lineHeight: style.lineHeight, padding: style.padding,
            margin: style.margin, border: style.border
          },
          viewport: {width: innerWidth, height: innerHeight, dpr: devicePixelRatio || 1},
          nearbyText: ((el.parentElement && (el.parentElement.innerText ||
                       el.parentElement.textContent)) || '').trim().slice(0, 700)
        };
        clearHighlight();
        // Hand semantic element identity to the native composer. Pixels are
        // deliberately not the primary contract: the agent receives the URL,
        // selector, accessibility identity, bounds, and relevant styles.
        var bodyLines = [
          '## From browser',
          '',
          '**URL:** ' + data.url,
          '**Title:** ' + data.title,
          '**Element:** `' + data.tag + '`  ·  `' + data.selector + '`'
        ];
        if (data.text) bodyLines.push('**Text:** "' + data.text.replace(/"/g, '\\"') + '"');
        bodyLines.push('**Position:** ' + Math.round(data.rect.width) + '×' + Math.round(data.rect.height) +
                       ' at (' + Math.round(data.rect.left) + ', ' + Math.round(data.rect.top) + ')');
        var subtitle = data.tag + '  ·  ' + (data.url.split('/').slice(-1)[0] || data.url);
        // Element rect in SCREEN coords (web px, top-left origin). Bridge
        // flips y to AppKit and uses this as the panel's anchor: panel
        // position + image area both align with where the element actually
        // sits on screen, so the composer feels physically lifted off the
        // page.
        var chromeTopHeight = window.outerHeight - window.innerHeight;
        var elementScreen = {
          x: window.screenX + data.rect.left,
          y: window.screenY + chromeTopHeight + data.rect.top,
          width: data.rect.width,
          height: data.rect.height
        };
        fetch('http://127.0.0.1:' + bridge.port + '/composer/show', {
          method: 'POST',
          headers: {
            'Authorization': 'Bearer ' + bridge.token,
            'Content-Type': 'application/json'
          },
          body: JSON.stringify({
            sessionId: bridge.sessionId,
            source: 'bridge',
            title: 'From browser',
            subtitle: subtitle,
            bodyMarkdown: bodyLines.join('\n'),
            context: {
              targetKind: 'browser',
              element: '<' + data.tag + '>',
              tag: data.tag,
              label: data.label,
              text: data.text,
              selector: data.selector,
              elementPath: data.selector,
              url: data.url,
              title: data.title,
              bounds: {
                x: data.rect.x, y: data.rect.y, width: data.rect.width,
                height: data.rect.height, top: data.rect.top, right: data.rect.right,
                bottom: data.rect.bottom, left: data.rect.left
              },
              documentBounds: {
                x: data.rect.x + scrollX, y: data.rect.y + scrollY,
                width: data.rect.width, height: data.rect.height
              },
              point: {x: data.clickX, y: data.clickY},
              viewport: data.viewport,
              cssClasses: data.classes,
              computedStyles: data.computedStyles,
              accessibility: data.accessibility,
              nearbyText: data.nearbyText,
              selectedText: String(getSelection ? getSelection() : '').slice(0, 500)
            },
            elementRect: elementScreen
          })
        }).catch(function(e){ toast('Composer failed: ' + e.message, false); });
      }

      function getSelector(el){
        if (el.id && /^[A-Za-z_][\w-]*$/.test(el.id)) return '#' + el.id;
        var path = [], cur = el, depth = 0;
        while (cur && cur.nodeType === 1 && cur !== document.body && depth < 6){
          var seg = cur.tagName.toLowerCase();
          var cls = (typeof cur.className === 'string') ? cur.className : '';
          var classes = cls.split(/\s+/)
            .filter(function(c){ return c && !c.startsWith('__braincell'); })
            .slice(0, 2);
          if (classes.length) seg += '.' + classes.join('.');
          var sib = cur.parentElement
            ? Array.from(cur.parentElement.children).filter(function(s){ return s.tagName === cur.tagName; })
            : [];
          if (sib.length > 1) seg += ':nth-of-type(' + (sib.indexOf(cur) + 1) + ')';
          path.unshift(seg);
          cur = cur.parentElement; depth++;
        }
        return path.join(' > ');
      }

      // ─── Brief toast (transient confirmations / errors only) ──────────────
      function toast(msg, ok){
        var t = document.createElement('div');
        t.textContent = msg;
        t.style.cssText = [
          'all:initial', 'position:fixed', 'bottom:80px', 'right:20px',
          'background:' + (ok ? BLUE : '#DC2626'),
          'color:#fff', 'padding:9px 14px', 'border-radius:8px',
          'font:500 12px/1.3 -apple-system,BlinkMacSystemFont,system-ui,sans-serif',
          'z-index:2147483647', 'opacity:0', 'transform:translateY(8px)',
          'transition:opacity 200ms ease, transform 200ms ease',
          'box-shadow:0 6px 20px rgba(0,0,0,0.18)'
        ].join(';') + ';';
        document.body.appendChild(t);
        requestAnimationFrame(function(){
          t.style.opacity = '1'; t.style.transform = 'translateY(0)';
        });
        setTimeout(function(){
          t.style.opacity = '0'; t.style.transform = 'translateY(8px)';
          setTimeout(function(){ t.remove(); }, 220);
        }, 2200);
      }

      arm();
      window.__cmdyInspector = {
        teardown: function(){
          // Remove every registered listener; ignore individual failures so
          // a single missing reference can't block the rest of the cleanup
          // (was the source of "can't toggle off" — a ReferenceError on
          // onKey/popup left the cursor + badge + outline stuck).
          try { document.removeEventListener('mousemove', onMove, true); } catch(e){}
          try { document.removeEventListener('click', onClick, true); } catch(e){}
          try { if (bodyHoverTimer){ clearTimeout(bodyHoverTimer); bodyHoverTimer = null; } } catch(e){}
          try { if (outline){ outline.remove(); outline = null; } } catch(e){}
          try { if (tagPill){ tagPill.remove(); tagPill = null; } } catch(e){}
          try { if (badge){ badge.remove(); badge = null; } } catch(e){}
          try { if (document.body) document.body.style.cursor = prevCursor || ''; } catch(e){}
        }
      };
    })();
    """#

    // MARK: - Chrome Detection

    private static func findChrome() -> String? {
        for path in chromePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
}
