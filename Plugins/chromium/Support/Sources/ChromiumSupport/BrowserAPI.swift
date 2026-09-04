import AppKit
import CoreGraphics
import ScreenCaptureKit
import CmdySDK

// BrowserAPI — the agent↔browser layer: a plugin-local HTTP API that lets any
// local agent (claude / codex / pi, via the mcp/index.js stdio shim or plain
// curl) drive the Chromium sidecar.
//
//   POST /execute {"tool": "navigate", "arguments": {"url": "…"}}  → {"result": …} | {"error": "…"}
//   GET  /health                                                   → {"status": "ok", …}
//
// Discovery mirrors cmdy's plugin-api.json: ~/.config/cmdy/browser-api.json
// holds {port, token, api}, 0600. Tool semantics are ported from Braincell's
// CEF router (the design this plugin mirrors): navigation and JS execution are
// native cef_bridge calls; interactions are CSS-selector JS injection; eval
// RESULTS come back through the console callback — the injected code logs
// __CMDY_RESULT__:<id>:<json> and the CEF console hook resolves the
// matching pending request.

public enum BrowserAPIError: LocalizedError {
    case missingParam(String)
    case noBrowser
    case jsError(String)
    case screenshotFailed(String)
    case unknownTool(String)

    public var errorDescription: String? {
        switch self {
        case .missingParam(let p): return "missing parameter: \(p)"
        case .noBrowser: return "no browser — CEF is not up"
        case .jsError(let m): return "JavaScript error: \(m)"
        case .screenshotFailed(let m): return "screenshot failed: \(m)"
        case .unknownTool(let t): return "unknown tool: \(t)"
        }
    }
}

public typealias ChromiumBrowserHandle = UnsafeMutableRawPointer

/// The browser API is shared by the legacy development sidecar and cmdy's
/// embedded host. Keeping CEF behind these operations lets the app leave its
/// sealed runtime unloaded until the Browser Extension is enabled.
public struct ChromiumBrowserOperations: @unchecked Sendable {
    public let executeJavaScript: (ChromiumBrowserHandle, String) -> Void
    public let reload: (ChromiumBrowserHandle) -> Void
    public let goBack: (ChromiumBrowserHandle) -> Void
    public let goForward: (ChromiumBrowserHandle) -> Void
    public let currentURL: (ChromiumBrowserHandle) -> String

    public init(
        executeJavaScript: @escaping (ChromiumBrowserHandle, String) -> Void,
        reload: @escaping (ChromiumBrowserHandle) -> Void,
        goBack: @escaping (ChromiumBrowserHandle) -> Void,
        goForward: @escaping (ChromiumBrowserHandle) -> Void,
        currentURL: @escaping (ChromiumBrowserHandle) -> String
    ) {
        self.executeJavaScript = executeJavaScript
        self.reload = reload
        self.goBack = goBack
        self.goForward = goForward
        self.currentURL = currentURL
    }
}

// @unchecked: cross-thread state (console buffer, pending evals) is
// lock-guarded; hooks and CEF calls stay on the main thread.
public final class BrowserAPI: @unchecked Sendable {
    // Hooks installed by main.swift; all run on the main thread.
    /// Create the browser if needed, show the sidecar, return the handle.
    public var ensureBrowser: ((CGWindowID?) -> ChromiumBrowserHandle?)?
    /// Navigate through the owner so a new browser receives the requested URL
    /// as its initial load instead of racing the start page.
    public var navigateBrowser: ((String, CGWindowID?) -> Bool)?
    /// Ensure the sidecar window is on screen for a capture (sets the hold
    /// flag so the glue tick doesn't hide it mid-capture) and return it.
    public var windowForScreenshot: ((CGWindowID?) -> NSWindow?)?
    /// Optional browser rectangle in window coordinates. The sidecar leaves
    /// this nil because its whole window is Chromium; the embedded host uses
    /// it to keep terminal chrome out of agent screenshots.
    public var screenshotCropRect: ((CGWindowID?) -> NSRect?)?
    /// Release the capture hold.
    public var screenshotDone: ((CGWindowID?) -> Void)?
    /// Deliver a semantic feedback record to the owning Cmdy window.
    public var feedbackReceived: ((CGWindowID, [String: Any]) -> Void)?

    private let server = BrowserHTTPServer()
    private let operations: ChromiumBrowserOperations
    public var port: Int { server.port }

    /// Console ring buffer (the bridge exposes message/source/line, not
    /// severity — every entry is level "log").
    private var console: [[String: Any]] = []
    private let consoleLock = NSLock()

    /// Pending JS evals keyed by request id; resolved by the console hook.
    private var pendingJS: [String: CheckedContinuation<Any?, Never>] = [:]
    private let jsLock = NSLock()

    /// 1 = text-only screenshots, 2 = balanced (default), 3 = thorough.
    /// The MCP shim reads this to decide how much context to auto-append.
    private var thoroughness = 2
    private let feedback = CmdyFeedbackStore()
    /// A page can write to its own console. Require a process-random nonce so
    /// normal page logs cannot masquerade as user-authored Cmdy feedback.
    private let feedbackToken = UUID().uuidString.lowercased()

    public static let discoveryURL = HostProductIdentity.configurationDirectory
        .appendingPathComponent("browser-api.json")

    // MARK: - Lifecycle

    public init(operations: ChromiumBrowserOperations) {
        self.operations = operations
    }

    public func start() {
        let preferred = HostProductIdentity.environmentValue("BROWSER_PORT")
            .flatMap(UInt16.init) ?? 4680
        guard server.start(preferredPort: preferred) else {
            NSLog("chromium: browser API failed to bind near port %d", Int(preferred))
            return
        }
        server.handler = { [weak self] request, respond in
            guard let self else { respond(503, ["error": "shutting down"]); return }
            self.route(request, respond)
        }
        writeDiscoveryFile()
        NSLog("chromium: browser API listening on 127.0.0.1:%d", server.port)
    }

    public func stop() {
        server.stop()
        try? FileManager.default.removeItem(at: Self.discoveryURL)
    }

    /// Written next to cmdy's plugin-api.json so ANY process (the MCP shim,
    /// a curl gate, another agent) can find the API: {"port", "token", "api"}.
    private func writeDiscoveryFile() {
        let info: [String: Any] = ["port": server.port, "token": server.authToken,
                                   "api": "browser-v1", "pid": Int(getpid())]
        if let data = try? JSONSerialization.data(withJSONObject: info) {
            try? FileManager.default.createDirectory(
                at: Self.discoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.discoveryURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: Self.discoveryURL.path)
        }
    }

    // MARK: - Routing

    private func route(_ request: BrowserHTTPServer.Request, _ respond: @escaping (Int, Any) -> Void) {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            respond(200, [
                "status": "ok",
                "app": "\(HostProductIdentity.slug)-chromium",
                "api": "browser-v1",
                "port": server.port,
            ])
        case ("POST", "/execute"):
            guard let json = request.json, let tool = json["tool"] as? String else {
                respond(400, ["error": "invalid request — expected {\"tool\": …, \"arguments\": {…}}"])
                return
            }
            let arguments = json["arguments"] as? [String: Any] ?? [:]
            let hostWindow = (json["window"] as? NSNumber)
                .map { CGWindowID($0.uint32Value) }
            Task { @MainActor in
                do {
                    let result = try await self.execute(
                        tool: tool, arguments: arguments, hostWindow: hostWindow)
                    respond(200, ["result": result])
                } catch {
                    respond(200, ["error": error.localizedDescription])
                }
            }
        default:
            respond(404, ["error": "no route for \(request.method) \(request.path)"])
        }
    }

    // MARK: - Console hook (called from the CEF console callback)

    public func handleConsoleMessage(_ text: String, source: String, line: Int,
                                     hostWindow: CGWindowID) {
        if captureFeedback(text, hostWindow: hostWindow) { return }
        if resolveJSResult(text) { return }
        consoleLock.lock()
        console.append(["type": "log", "content": text, "source": source, "line": line,
                        "timestamp": ISO8601DateFormatter().string(from: Date())])
        if console.count > 500 { console.removeFirst(console.count - 500) }
        consoleLock.unlock()
    }

    private func captureFeedback(_ message: String, hostWindow: CGWindowID) -> Bool {
        let prefix = "__CMDY_FEEDBACK__:\(feedbackToken):"
        guard message.hasPrefix(prefix) else { return false }
        let json = String(message.dropFirst(prefix.count))
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let record = object as? [String: Any] else { return true }
        let stored = feedback.add(record)
        DispatchQueue.main.async { [weak self] in
            self?.feedbackReceived?(hostWindow, stored)
        }
        return true
    }

    /// Locked buffer access lives in sync helpers — NSLock across an async
    /// frame is a Swift 6 error even when no suspension sits inside.
    private func consoleSnapshot(clearing: Bool) -> [[String: Any]] {
        consoleLock.lock()
        defer { consoleLock.unlock() }
        let snapshot = console
        if clearing { console.removeAll() }
        return snapshot
    }

    private func resolveJSResult(_ message: String) -> Bool {
        let prefix = "__CMDY_RESULT__:"
        guard message.hasPrefix(prefix) else { return false }
        let rest = String(message.dropFirst(prefix.count))
        guard let colon = rest.firstIndex(of: ":") else { return true }
        let requestId = String(rest[rest.startIndex..<colon])
        let jsonStr = String(rest[rest.index(after: colon)...])

        jsLock.lock()
        let continuation = pendingJS.removeValue(forKey: requestId)
        jsLock.unlock()
        guard let continuation else { return true }

        // .fragmentsAllowed for bare strings/numbers/booleans.
        if let data = jsonStr.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
            continuation.resume(returning: parsed)
        } else {
            continuation.resume(returning: jsonStr)
        }
        return true
    }

    // MARK: - JS execution

    /// Produce a complete JavaScript string literal. JSON escaping covers
    /// quotes, slashes, control characters, and Unicode line separators.
    private func jsString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Fire-and-forget JS in the page.
    @MainActor
    private func fireJS(_ browser: ChromiumBrowserHandle, _ code: String) {
        operations.executeJavaScript(browser, code)
    }

    /// Execute JS and await its JSON-serializable result via the console
    /// round-trip. Returns nil on timeout; throws when the page code threw.
    @MainActor
    private func evalJS(_ browser: ChromiumBrowserHandle, _ code: String,
                        timeout: TimeInterval = 10.0) async throws -> Any? {
        let safeTimeout = timeout.isFinite ? min(max(timeout, 0.1), 120) : 10
        let requestId = UUID().uuidString
        let wrapped = """
        (function(){
          try{
            var __r=\(code);
            console.log('__CMDY_RESULT__:\(requestId):'+JSON.stringify(__r));
          }catch(e){
            console.log('__CMDY_RESULT__:\(requestId):'+JSON.stringify({__error:e.message||String(e)}));
          }
        })();
        """
        let result: Any? = await withCheckedContinuation { continuation in
            jsLock.lock()
            pendingJS[requestId] = continuation
            jsLock.unlock()
            operations.executeJavaScript(browser, wrapped)
            DispatchQueue.global().asyncAfter(deadline: .now() + safeTimeout) { [weak self] in
                guard let self else { return }
                self.jsLock.lock()
                let pending = self.pendingJS.removeValue(forKey: requestId)
                self.jsLock.unlock()
                pending?.resume(returning: nil)
            }
        }
        if let dict = result as? [String: Any], let err = dict["__error"] as? String {
            throw BrowserAPIError.jsError(err)
        }
        return result
    }

    // MARK: - Tools

    @MainActor
    public func execute(tool: String, arguments: [String: Any],
                        hostWindow: CGWindowID? = nil) async throws -> Any {
        // Server-state tools work without (and never summon) a browser.
        switch tool {
        case "set_thoroughness":
            thoroughness = max(1, min(3, arguments["level"] as? Int ?? 2))
            return ["thoroughness": thoroughness]
        case "get_thoroughness":
            return ["thoroughness": thoroughness]
        case "get_console":
            let limit = max(0, min(500, arguments["limit"] as? Int ?? 50))
            let pattern = arguments["pattern"] as? String
            let clear = arguments["clear"] as? Bool ?? false
            var messages = consoleSnapshot(clearing: clear)
            if let pattern, pattern.utf8.count <= 512,
               let regex = try? NSRegularExpression(
                pattern: pattern, options: .caseInsensitive) {
                messages = messages.filter { m in
                    let t = m["content"] as? String ?? ""
                    return regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
                }
            }
            let limited = Array(messages.suffix(limit))
            return ["success": true, "count": limited.count, "messages": limited]
        case "clear_console":
            _ = consoleSnapshot(clearing: true)
            return ["success": true]
        case "get_feedback":
            let status = arguments["status"] as? String
            let id = arguments["id"] as? String
            var records = feedback.list(status: status)
            if let id { records = records.filter { $0["id"] as? String == id } }
            return ["success": true, "count": records.count, "feedback": records]
        case "resolve_feedback":
            guard let id = arguments["id"] as? String else {
                throw BrowserAPIError.missingParam("id")
            }
            let record = feedback.resolve(id: id, resolution: arguments["resolution"] as? String)
            let value: Any = record.map { $0 as Any } ?? NSNull()
            return ["success": record != nil, "feedback": value]
        case "clear_feedback":
            let removed = feedback.clear(resolvedOnly: arguments["resolvedOnly"] as? Bool ?? false)
            return ["success": true, "removed": removed]
        default:
            break
        }

        if tool == "navigate" {
            guard let url = arguments["url"] as? String else {
                throw BrowserAPIError.missingParam("url")
            }
            guard navigateBrowser?(url, hostWindow) == true else {
                throw BrowserAPIError.noBrowser
            }
            return ["success": true, "url": url]
        }

        // Everything else touches the page: create the browser on first use
        // and show the sidecar — the user should see what the agent does.
        guard let browser = ensureBrowser?(hostWindow) else { throw BrowserAPIError.noBrowser }

        switch tool {
        case "begin_feedback":
            let result = try await evalJS(
                browser, DOMFeedback.script(token: feedbackToken))
            return result ?? ["success": true, "active": true]

        case "reload":
            operations.reload(browser)
            return ["success": true]

        case "back":
            operations.goBack(browser)
            return ["success": true]

        case "forward":
            operations.goForward(browser)
            return ["success": true]

        case "get_url":
            let url = operations.currentURL(browser)
            return ["success": true, "url": url]

        case "get_title":
            // Native cef_bridge_get_title is empty until CEF's title-change
            // event lands — document.title is the truth (Braincell does the
            // same); fall back to the URL like the reference.
            var title = try await evalJS(browser, "document.title") as? String ?? ""
            if title.isEmpty { title = operations.currentURL(browser) }
            return ["success": true, "title": title]

        case "execute_js":
            guard let code = arguments["code"] as? String else { throw BrowserAPIError.missingParam("code") }
            let result = try await evalJS(browser, code)
            return ["success": true, "result": result ?? NSNull()]

        case "get_content":
            let selector = arguments["selector"] as? String ?? "body"
            let type = arguments["type"] as? String ?? "text"
            let prop = type == "html" ? "outerHTML" : "innerText"
            let result = try await evalJS(browser, """
            (function(){
              var el=document.querySelector(\(jsString(selector)));
              if(!el) return {success:false,error:'Element not found: '+\(jsString(selector))};
              var content=el['\(prop)'];
              return {success:true,content:content.substring(0,50000),truncated:content.length>50000};
            })()
            """)
            return result ?? ["success": false, "error": "No response"]

        case "screenshot":
            if thoroughness <= 1 {
                let text = try await evalJS(browser, "document.body ? document.body.innerText.substring(0, 4000) : ''")
                return ["success": true, "mode": "text", "content": text ?? "",
                        "note": "Response mode is Text — use set_thoroughness(2) for visual screenshots"]
            }
            guard let window = windowForScreenshot?(hostWindow) else {
                throw BrowserAPIError.screenshotFailed("no browser window")
            }
            defer { screenshotDone?(hostWindow) }
            // Give the WindowServer a beat after the capture window is ordered.
            // Background captures are parked offscreen, never raised over the
            // user's active application.
            try await Task.sleep(nanoseconds: 350_000_000)
            let data = try await captureWindow(
                window, cropRect: screenshotCropRect?(hostWindow))
            return ["success": true, "image": data.base64EncodedString(), "format": "jpeg", "encoding": "base64"]

        case "click":
            guard let selector = arguments["selector"] as? String else { throw BrowserAPIError.missingParam("selector") }
            let result = try await evalJS(browser, """
            (function(){
              var el=document.querySelector(\(jsString(selector)));
              if(!el) return {success:false,error:'Element not found: '+\(jsString(selector))};
              el.click();
              return {success:true,clicked:\(jsString(selector))};
            })()
            """)
            return result ?? ["success": true, "clicked": selector]

        case "type":
            guard let selector = arguments["selector"] as? String,
                  let text = arguments["text"] as? String else { throw BrowserAPIError.missingParam("selector and text") }
            let clear = arguments["clear"] as? Bool ?? true
            let clearJS = clear ? "el.value='';" : ""
            let result = try await evalJS(browser, """
            (function(){
              var el=document.querySelector(\(jsString(selector)));
              if(!el) return {success:false,error:'Element not found: '+\(jsString(selector))};
              \(clearJS)el.focus();el.value+=\(jsString(text));
              el.dispatchEvent(new Event('input',{bubbles:true}));
              el.dispatchEvent(new Event('change',{bubbles:true}));
              return {success:true,typed:\(jsString(text))};
            })()
            """)
            return result ?? ["success": true, "typed": text]

        case "hover":
            guard let selector = arguments["selector"] as? String else { throw BrowserAPIError.missingParam("selector") }
            let result = try await evalJS(browser, """
            (function(){
              var el=document.querySelector(\(jsString(selector)));
              if(!el) return {success:false,error:'Element not found: '+\(jsString(selector))};
              el.dispatchEvent(new MouseEvent('mouseover',{bubbles:true}));
              el.dispatchEvent(new MouseEvent('mouseenter',{bubbles:true}));
              return {success:true,hovered:\(jsString(selector))};
            })()
            """)
            return result ?? ["success": true, "hovered": selector]

        case "focus":
            guard let selector = arguments["selector"] as? String else { throw BrowserAPIError.missingParam("selector") }
            fireJS(browser, "(function(){var el=document.querySelector(\(jsString(selector)));if(el)el.focus();})();")
            return ["success": true, "focused": selector]

        case "scroll":
            let selector = arguments["selector"] as? String
            let direction = arguments["direction"] as? String ?? "down"
            let amount = max(0, min(100_000, arguments["amount"] as? Int ?? 300))
            if let sel = selector {
                fireJS(browser, "(function(){var el=document.querySelector(\(jsString(sel)));if(el){el.scrollIntoView({behavior:'smooth',block:'center'});}})();")
            } else {
                let dy = direction == "up" ? -amount : amount
                fireJS(browser, "window.scrollBy({top:\(dy),behavior:'smooth'});")
            }
            return ["success": true, "scrolled": selector ?? direction]

        case "press_key":
            guard let key = arguments["key"] as? String else { throw BrowserAPIError.missingParam("key") }
            let modifiers = arguments["modifiers"] as? [String] ?? []
            let modJS = modifiers.map { mod -> String in
                switch mod.lowercased() {
                case "ctrl", "control": return "ctrlKey:true"
                case "shift": return "shiftKey:true"
                case "alt": return "altKey:true"
                case "meta", "cmd": return "metaKey:true"
                default: return ""
                }
            }.filter { !$0.isEmpty }.joined(separator: ",")
            let opts = modJS.isEmpty
                ? "key:\(jsString(key)),bubbles:true"
                : "key:\(jsString(key)),bubbles:true,\(modJS)"
            fireJS(browser, "(function(){var el=document.activeElement||document.body;el.dispatchEvent(new KeyboardEvent('keydown',{\(opts)}));el.dispatchEvent(new KeyboardEvent('keyup',{\(opts)}));})();")
            return ["success": true, "key": key]

        case "double_click":
            guard let selector = arguments["selector"] as? String else { throw BrowserAPIError.missingParam("selector") }
            fireJS(browser, "(function(){var el=document.querySelector(\(jsString(selector)));if(el){el.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));}})();")
            return ["success": true, "doubleClicked": selector]

        case "right_click":
            guard let selector = arguments["selector"] as? String else { throw BrowserAPIError.missingParam("selector") }
            fireJS(browser, "(function(){var el=document.querySelector(\(jsString(selector)));if(el){el.dispatchEvent(new MouseEvent('contextmenu',{bubbles:true}));}})();")
            return ["success": true, "rightClicked": selector]

        case "drag_drop":
            guard let source = arguments["source"] as? String,
                  let target = arguments["target"] as? String else { throw BrowserAPIError.missingParam("source and target") }
            fireJS(browser, """
            (function(){
              var src=document.querySelector(\(jsString(source)));
              var tgt=document.querySelector(\(jsString(target)));
              if(src&&tgt){
                var dt=new DataTransfer();
                src.dispatchEvent(new DragEvent('dragstart',{dataTransfer:dt,bubbles:true}));
                tgt.dispatchEvent(new DragEvent('drop',{dataTransfer:dt,bubbles:true}));
                src.dispatchEvent(new DragEvent('dragend',{dataTransfer:dt,bubbles:true}));
              }
            })();
            """)
            return ["success": true, "source": source, "target": target]

        case "select_option":
            guard let selector = arguments["selector"] as? String,
                  let value = arguments["value"] as? String else { throw BrowserAPIError.missingParam("selector and value") }
            fireJS(browser, "(function(){var el=document.querySelector(\(jsString(selector)));if(el){el.value=\(jsString(value));el.dispatchEvent(new Event('change',{bubbles:true}));}})();")
            return ["success": true, "selected": value, "selector": selector]

        case "set_checkbox":
            guard let selector = arguments["selector"] as? String else { throw BrowserAPIError.missingParam("selector") }
            let checked = arguments["checked"] as? Bool ?? true
            fireJS(browser, "(function(){var el=document.querySelector(\(jsString(selector)));if(el){el.checked=\(checked);el.dispatchEvent(new Event('change',{bubbles:true}));}})();")
            return ["success": true, "checked": checked, "selector": selector]

        case "fill_form":
            guard let fields = arguments["fields"] as? [[String: String]] else { throw BrowserAPIError.missingParam("fields") }
            for field in fields.prefix(500) {
                if let sel = field["selector"], let val = field["value"] {
                    fireJS(browser, "(function(){var el=document.querySelector(\(jsString(sel)));if(el){el.value=\(jsString(val));el.dispatchEvent(new Event('input',{bubbles:true}));}})();")
                }
            }
            return ["success": true, "filledCount": min(fields.count, 500)]

        case "submit_form":
            let selector = arguments["selector"] as? String ?? "form"
            fireJS(browser, "(function(){var el=document.querySelector(\(jsString(selector)));if(el){el.submit?el.submit():el.closest('form')?.submit();}})();")
            return ["success": true, "submitted": selector]

        case "get_forms":
            let result = try await evalJS(browser, """
            (function(){
              var forms=Array.from(document.querySelectorAll('form')).slice(0,50);
              return {success:true,count:forms.length,forms:forms.map(function(f,i){
                var fields=Array.from(f.querySelectorAll('input,select,textarea')).slice(0,500).map(function(el){
                  return {tag:el.tagName.toLowerCase(),type:el.type||'',name:el.name||'',id:el.id||'',value:el.value||'',placeholder:el.placeholder||''};
                });
                return {index:i,id:f.id||null,action:f.action||'',method:f.method||'GET',fields:fields};
              })};
            })()
            """)
            return result ?? ["success": false, "error": "No response"]

        case "find":
            guard let query = arguments["query"] as? String else { throw BrowserAPIError.missingParam("query") }
            let limit = max(0, min(500, arguments["limit"] as? Int ?? 10))
            let result = try await evalJS(browser, """
            (function(){
              var query=\(jsString(query));
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
                if(score>15) results.push({selector:getSelector(el),tag:tag,text:(el.innerText||'').substring(0,100).trim(),score:score,matchReason:reasons.join(', '),rect:{x:Math.round(rect.x),y:Math.round(rect.y),width:Math.round(rect.width),height:Math.round(rect.height)},visible:rect.width>0&&rect.height>0});
              }
              results.sort(function(a,b){return b.score-a.score});
              results=results.slice(0,\(limit));
              return {success:true,query:query,count:results.length,elements:results};
            })()
            """)
            return result ?? ["success": false, "error": "No response"]

        case "get_element":
            guard let selector = arguments["selector"] as? String else { throw BrowserAPIError.missingParam("selector") }
            let result = try await evalJS(browser, """
            (function(){
              var el=document.querySelector(\(jsString(selector)));
              if(!el) return {success:false,error:'Element not found'};
              var rect=el.getBoundingClientRect();
              return {
                success:true,tag:el.tagName.toLowerCase(),id:el.id||null,
                classes:Array.from(el.classList),
                text:(el.innerText||'').substring(0,500),
                value:el.value||null,href:el.href||null,src:el.src||null,
                rect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height},
                visible:rect.width>0&&rect.height>0
              };
            })()
            """)
            return result ?? ["success": false, "error": "No response"]

        case "list_interactive":
            let limit = max(0, min(500, arguments["limit"] as? Int ?? 50))
            let result = try await evalJS(browser, """
            (function(){
              var els=document.querySelectorAll('a,button,input,select,textarea,[onclick],[role="button"]');
              var items=Array.from(els).slice(0,\(limit)).map(function(el,i){
                return {
                  index:i,tag:el.tagName.toLowerCase(),type:el.type||null,
                  id:el.id||null,name:el.name||null,
                  text:(el.innerText||el.value||el.placeholder||'').substring(0,100),
                  href:el.href||null,
                  selector:el.id?'#'+el.id:el.name?'[name="'+el.name+'"]':(typeof el.className==='string'&&el.className)?el.tagName.toLowerCase()+'.'+el.className.split(' ')[0]:el.tagName.toLowerCase()
                };
              });
              return {success:true,count:items.length,elements:items};
            })()
            """)
            return result ?? ["success": false, "error": "No response"]

        case "wait_for":
            guard let selector = arguments["selector"] as? String else { throw BrowserAPIError.missingParam("selector") }
            let timeout = max(0, min(60_000, arguments["timeout"] as? Int ?? 5000))
            let start = Date()
            while Date().timeIntervalSince(start) * 1000 < Double(timeout) {
                let found = try await evalJS(
                    browser, "!!document.querySelector(\(jsString(selector)))")
                    as? Bool ?? false
                if found { return ["success": true, "found": true, "selector": selector] }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            return ["success": false, "found": false, "error": "Timeout waiting for \(selector)"]

        default:
            throw BrowserAPIError.unknownTool(tool)
        }
    }

    // MARK: - Screenshot

    /// `NSView.cacheDisplay` does NOT capture CEF's IOSurface-composited
    /// content (returns the solid background), so this goes through
    /// ScreenCaptureKit — which needs the Screen Recording permission the
    /// first time. Embedded Chromium shares Cmdy's window, so `cropRect`
    /// isolates the browser viewport before downscaling and JPEG encoding.
    @MainActor
    private func captureWindow(_ window: NSWindow, cropRect: NSRect?) async throws -> Data {
        let targetID = CGWindowID(window.windowNumber)
        let shareable = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let scWindow = shareable.windows.first(where: { $0.windowID == targetID }) else {
            throw BrowserAPIError.screenshotFailed("browser window is not on screen")
        }
        let scale = window.backingScaleFactor
        let config = SCStreamConfiguration()
        let pixelWidth = scWindow.frame.width * scale
        let pixelHeight = scWindow.frame.height * scale
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= 16_384, pixelHeight <= 16_384 else {
            throw BrowserAPIError.screenshotFailed("invalid browser window dimensions")
        }
        config.width = Int(pixelWidth.rounded(.up))
        config.height = Int(pixelHeight.rounded(.up))
        config.showsCursor = false
        config.scalesToFit = false
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        var captured = image
        if let cropRect {
            let windowHeight = window.frame.height
            let pixelRect = CGRect(
                x: cropRect.minX * scale,
                y: (windowHeight - cropRect.maxY) * scale,
                width: cropRect.width * scale,
                height: cropRect.height * scale).integral
                .intersection(CGRect(
                    x: 0, y: 0,
                    width: CGFloat(image.width), height: CGFloat(image.height)))
            if pixelRect.width >= 1, pixelRect.height >= 1,
               let cropped = image.cropping(to: pixelRect) {
                captured = cropped
            }
        }

        let maxDim: CGFloat = 800
        let srcW = CGFloat(captured.width), srcH = CGFloat(captured.height)
        let longest = max(srcW, srcH)
        var final = captured
        if longest > maxDim {
            let ratio = maxDim / longest
            let dstW = max(1, Int((srcW * ratio).rounded()))
            let dstH = max(1, Int((srcH * ratio).rounded()))
            if let ctx = CGContext(data: nil, width: dstW, height: dstH, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .medium
                ctx.draw(captured, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
                if let scaled = ctx.makeImage() { final = scaled }
            }
        }
        let rep = NSBitmapImageRep(cgImage: final)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else {
            throw BrowserAPIError.screenshotFailed("JPEG encode failed")
        }
        return jpeg
    }
}
