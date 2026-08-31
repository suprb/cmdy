import Foundation

/// Dispatches a tool name + arguments to the per-session ChromeAdapter for a given session.
/// All adapter access is on MainActor.
@MainActor
struct BridgeToolRouter {
    let appState: BridgeAppState

    enum ToolError: Error, LocalizedError {
        case unknownTool(String)
        case missingParam(String)
        case noAdapter
        case invalidArgument(String)

        var errorDescription: String? {
            switch self {
            case .unknownTool(let name): return "Unknown tool: \(name)"
            case .missingParam(let name): return "Missing required parameter: \(name)"
            case .noAdapter: return "No Chrome adapter for session"
            case .invalidArgument(let msg): return msg
            }
        }
    }

    /// Tools whose response should include a fresh `pageContext` snapshot —
    /// state-mutating + navigation + wait_for. Skips the read-only tools
    /// (Claude already has its answer) and the buffer-clears (no page change).
    /// Scene injection eliminates follow-up
    /// `get_content`/`screenshot` calls.
    private static let pageContextTools: Set<String> = [
        "click", "type", "hover", "double_click", "right_click", "drag_drop",
        "scroll", "press_key", "focus",
        "fill_form", "submit_form", "select_option", "set_checkbox",
        "execute_js",
        "navigate", "reload", "back", "forward",
        "wait_for"
    ]

    func execute(tool: String, arguments: [String: Any], sessionId: String) async throws -> [String: Any] {
        // Surface intent on the bound Chrome window before dispatching. Same
        // wall-clock latency as before, but the user sees a labeled ribbon +
        // edge strip light up the moment dispatch begins, and flash green/red
        // on completion. Wrapped around the existing switch via a private
        // helper so the per-case `return`s don't need touching.
        let label = IntentOverlayController.label(for: tool, args: arguments)
        appState.intentOverlay.start(sessionId: sessionId, label: label)
        // Heartbeat the cursor: every tool call (visual or read-only)
        // refreshes its lastShownAt, so the cursor stays pinned at its
        // last anchor point as long as the agent keeps issuing tools. This
        // provides a visible work signal without coupling the cursor to any
        // specific tool.
        appState.cursorOverlay.heartbeat()
        do {
            var result = try await dispatch(tool: tool, arguments: arguments, sessionId: sessionId)
            // Scene injection: attach a fresh page-context blob to every
            // state-mutating + nav tool's response. Claude reads it and
            // skips the next "what's on the page now?" round-trip.
            if Self.pageContextTools.contains(tool),
               let adapter = appState.chromeAdapters[sessionId],
               let ctx = await adapter.pageContext() {
                result["pageContext"] = ctx
            }
            appState.intentOverlay.end(sessionId: sessionId, success: true)
            return result
        } catch {
            appState.intentOverlay.end(sessionId: sessionId, success: false, errorLabel: error.localizedDescription)
            throw error
        }
    }

    private func dispatch(tool: String, arguments: [String: Any], sessionId: String) async throws -> [String: Any] {
        // Sim tools route to SimulatorAdapter (xcrun simctl subprocess wrapper).
        if tool.hasPrefix("sim_") {
            return try await dispatchSimulator(tool: tool, arguments: arguments, sessionId: sessionId)
        }
        // Mac App tools route to MacAppAdapter (different lifecycle, no CDP).
        if tool.hasPrefix("mac_") {
            return try await dispatchMacApp(tool: tool, arguments: arguments, sessionId: sessionId)
        }
        // Native app tools route to NativeAppAdapter (already-running macOS
        // app — Slack/Notion/Figma desktop/etc — bound by bundle id).
        if tool.hasPrefix("native_") {
            return try await dispatchNativeApp(tool: tool, arguments: arguments, sessionId: sessionId)
        }

        // Plain tool name (no prefix) — historically always Chrome since
        // Chrome was the original adapter. But Claude often guesses the
        // unprefixed verb regardless of binding ("click X" → tool=`click`)
        // because it sounds more general than `native_click`. If this
        // session is bound to a non-Chrome target, auto-route the plain
        // verb to the bound adapter's equivalent. Avoids the user-visible
        // "no Chrome adapter" trap for sessions bound to native apps.
        if appState.chromeAdapters[sessionId] == nil,
           let binding = appState.bindings.get(sessionId: sessionId),
           let routed = Self.reroutedToolName(plain: tool, target: binding.target) {
            NSLog("[Bridge] auto-routed `%@` → `%@` (session bound to %@)",
                  tool, routed, binding.target.label)
            return try await dispatch(tool: routed, arguments: rewrittenArguments(plain: tool, args: arguments, target: binding.target), sessionId: sessionId)
        }

        guard let adapter = appState.chromeAdapters[sessionId] else {
            throw ToolError.noAdapter
        }

        switch tool {
        case "navigate":
            guard let url = arguments["url"] as? String else { throw ToolError.missingParam("url") }
            try await adapter.navigate(to: url)
            return ["success": true, "url": url]

        case "reload":
            let ignoreCache = (arguments["ignoreCache"] as? Bool) ?? false
            try await adapter.reload(ignoreCache: ignoreCache)
            return ["success": true]

        case "back":
            try await adapter.goBack()
            return ["success": true]

        case "forward":
            try await adapter.goForward()
            return ["success": true]

        case "screenshot":
            let format = (arguments["format"] as? String) ?? "png"
            let quality = intArg(arguments["quality"]) ?? 80
            // Native screenshot UX: pulsing rect around the Chrome window +
            // cursor sweep top-left → bottom-right (mirrors macOS ⌘⇧4 capture).
            // Same mechanic the Mac App + Sim adapters use. After capture,
            // animate a thumbnail of the result into the page bottom-left
            // (still a page-injected DOM overlay — separate concern from the
            // cursor system, kept for the Chrome-only thumbnail UX).
            if let frame = adapter.windowFrame() {
                appState.cursorOverlay.showScreenshotCapture(rectCGTopLeft: frame)
            }
            // Wait for the rect/cursor sweep to settle before capture so the
            // overlay panel doesn't bake into the image. The native overlay
            // is a separate window layer so SCK / Page.captureScreenshot
            // shouldn't see it, but this matches the pacing the user expects.
            try? await Task.sleep(nanoseconds: 600_000_000)
            let data = try await adapter.screenshot(format: format, quality: quality)
            let ext = (format == "jpeg") ? "jpg" : "png"
            let filename = "bridge-shot-\(UUID().uuidString).\(ext)"
            let path = NSTemporaryDirectory() + filename
            try data.write(to: URL(fileURLWithPath: path))
            if let http = appState.httpServer {
                await adapter.showScreenshotThumbnail(
                    filename: filename,
                    httpPort: http.port,
                    authenticationToken: http.crossOriginAuthenticationToken)
            }
            return ["success": true, "path": path, "size": data.count, "format": format]

        case "execute_js":
            guard let code = arguments["code"] as? String else { throw ToolError.missingParam("code") }
            let value = try await adapter.executeJS(code)
            return ["success": true, "value": jsonSafe(value)]

        case "click":
            guard let selector = arguments["selector"] as? String else { throw ToolError.missingParam("selector") }
            if let rect = await adapter.screenRectForSelector(selector) {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                appState.cursorOverlay.showClickAt(screenPointCGTopLeft: center, label: "Click")
            }
            try await adapter.click(selector: selector)
            return ["success": true, "selector": selector]

        case "type":
            guard let selector = arguments["selector"] as? String else { throw ToolError.missingParam("selector") }
            guard let text = arguments["text"] as? String else { throw ToolError.missingParam("text") }
            let clear = (arguments["clear"] as? Bool) ?? false
            if let rect = await adapter.screenRectForSelector(selector) {
                let preview = text.count > 18 ? String(text.prefix(18)) + "…" : text
                let center = CGPoint(x: rect.midX, y: rect.midY)
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: center,
                    label: "Type \"\(preview)\"",
                    duration: 0.25
                )
            }
            try await adapter.type(selector: selector, text: text, clear: clear)
            return ["success": true, "selector": selector]

        case "hover":
            guard let selector = arguments["selector"] as? String else { throw ToolError.missingParam("selector") }
            if let rect = await adapter.screenRectForSelector(selector) {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: center,
                    label: "Hover",
                    duration: 0.25
                )
            }
            let payload = try await adapter.hover(selector: selector)
            return merge(["success": true, "selector": selector], payload)

        case "double_click":
            guard let selector = arguments["selector"] as? String else { throw ToolError.missingParam("selector") }
            if let rect = await adapter.screenRectForSelector(selector) {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                appState.cursorOverlay.showDoubleClickAt(screenPointCGTopLeft: center, label: "Double-click")
            }
            try await adapter.doubleClick(selector: selector)
            return ["success": true, "selector": selector]

        case "right_click":
            guard let selector = arguments["selector"] as? String else { throw ToolError.missingParam("selector") }
            if let rect = await adapter.screenRectForSelector(selector) {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                appState.cursorOverlay.showRightClickAt(screenPointCGTopLeft: center, label: "Right-click")
            }
            try await adapter.rightClick(selector: selector)
            return ["success": true, "selector": selector]

        case "drag_drop":
            guard let source = arguments["source"] as? String,
                  let target = arguments["target"] as? String else {
                throw ToolError.missingParam("source and target")
            }
            // Pop cursor at source (instant), then tween to target over the
            // drag duration so the user sees the path. Cursor-tween machinery
            // will run the second call's `from` from the first's `to`, so
            // motion is continuous even though the dispatch is two calls.
            let sourceRect = await adapter.screenRectForSelector(source)
            if let r = sourceRect {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: r.midX, y: r.midY),
                    label: "Drag", duration: 0.0
                )
            }
            if let r = await adapter.screenRectForSelector(target) {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: r.midX, y: r.midY),
                    label: "Drag", duration: 0.4
                )
            }
            try await adapter.dragDrop(source: source, target: target)
            return ["success": true, "source": source, "target": target]

        case "scroll":
            let selector = arguments["selector"] as? String
            let direction = (arguments["direction"] as? String) ?? "down"
            let amount = intArg(arguments["amount"]) ?? 200
            // Plant cursor on the scroll target if a selector was given,
            // else at the center of the Chrome window so user sees where
            // the action is happening.
            var anchor: CGPoint?
            if let sel = selector, let r = await adapter.screenRectForSelector(sel) {
                anchor = CGPoint(x: r.midX, y: r.midY)
            } else if let r = adapter.windowFrame() {
                anchor = CGPoint(x: r.midX, y: r.midY)
            }
            if let pt = anchor {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: pt,
                    label: "Scroll \(direction)", duration: 0.25
                )
            }
            try await adapter.scroll(selector: selector, direction: direction, amount: amount)
            return ["success": true, "scrolled": selector ?? direction]

        case "press_key":
            guard let key = arguments["key"] as? String else { throw ToolError.missingParam("key") }
            let modifiers = (arguments["modifiers"] as? [String]) ?? []
            // No spatial selector — keys go to whatever is focused. Plant
            // cursor at the Chrome window center as a "Claude is here" beacon.
            if let r = adapter.windowFrame() {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: r.midX, y: r.midY),
                    label: "Press \(key)", duration: 0.2
                )
            }
            try await adapter.pressKey(key: key, modifiers: modifiers)
            return ["success": true, "key": key, "modifiers": modifiers]

        case "focus":
            guard let selector = arguments["selector"] as? String else { throw ToolError.missingParam("selector") }
            if let rect = await adapter.screenRectForSelector(selector) {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: center,
                    label: "Focus",
                    duration: 0.25
                )
            }
            try await adapter.focus(selector: selector)
            return ["success": true, "selector": selector]

        case "find":
            guard let query = arguments["query"] as? String else { throw ToolError.missingParam("query") }
            let limit = intArg(arguments["limit"]) ?? 10
            // No selector yet — anchor at window center with the query as label.
            if let r = adapter.windowFrame() {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: r.midX, y: r.midY),
                    label: "Find: \(query)", duration: 0.2
                )
            }

            // Run DOM scan + Apple Vision OCR in parallel. DOM is fast and
            // gives us actionable selectors; Vision catches text in canvas /
            // SVG / images that the DOM doesn't expose. Net latency is
            // max(DOM, Vision), not sum, so the visual matches are mostly
            // free from a wall-clock perspective. Vision failures (no
            // permission, window vanished) silently degrade to DOM-only.
            async let domPayloadTask = JSONDictionaryTransfer(
                try await adapter.find(query: query, limit: limit))
            let chromePid = adapter.chromeProcessPid
            let visionTask: Task<JSONRowsTransfer, Never>? = chromePid.map { pid in
                Task { [appState] in
                    do {
                        let scene = try await appState.visionFinder.indexWindow(ownerPid: pid)
                        return JSONRowsTransfer(scene.match(query: query, limit: limit).map { item in
                            [
                                "text": item.text,
                                "confidence": Double(item.confidence),
                                "bounds": [
                                    "x": item.bounds.origin.x,
                                    "y": item.bounds.origin.y,
                                    "width": item.bounds.width,
                                    "height": item.bounds.height,
                                ],
                            ] as [String: Any]
                        })
                    } catch {
                        NSLog("[BridgeRouter] Vision find skipped: %@", error.localizedDescription)
                        return JSONRowsTransfer([])
                    }
                }
            }

            let domPayload = try await domPayloadTask.value
            var result = merge(["success": true], domPayload)
            if let visionTask = visionTask {
                let visualMatches = await visionTask.value.value
                if !visualMatches.isEmpty {
                    result["visualMatches"] = visualMatches
                }
            }
            return result

        case "list_interactive":
            let limit = intArg(arguments["limit"]) ?? 50
            if let r = adapter.windowFrame() {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: r.midX, y: r.midY),
                    label: "Scan elements", duration: 0.2
                )
            }
            let payload = try await adapter.listInteractive(limit: limit)
            return merge(["success": true], payload)

        case "get_element":
            guard let selector = arguments["selector"] as? String else { throw ToolError.missingParam("selector") }
            if let rect = await adapter.screenRectForSelector(selector) {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: center,
                    label: "Inspect",
                    duration: 0.25
                )
            }
            let payload = try await adapter.getElement(selector: selector)
            return merge(["success": true, "selector": selector], payload)

        case "wait_for":
            guard let selector = arguments["selector"] as? String else { throw ToolError.missingParam("selector") }
            let timeout = intArg(arguments["timeout"]) ?? 5000
            // Element may not exist yet — fall back to window center.
            if let rect = await adapter.screenRectForSelector(selector) {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: center, label: "Wait", duration: 0.2
                )
            } else if let r = adapter.windowFrame() {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: r.midX, y: r.midY),
                    label: "Wait", duration: 0.2
                )
            }
            let payload = try await adapter.waitFor(selector: selector, timeoutMs: timeout)
            return merge(["success": true, "selector": selector], payload)

        case "get_forms":
            if let r = adapter.windowFrame() {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: r.midX, y: r.midY),
                    label: "Scan forms", duration: 0.2
                )
            }
            let payload = try await adapter.getForms()
            return merge(["success": true], payload)

        case "fill_form":
            guard let selector = arguments["selector"] as? String else { throw ToolError.missingParam("selector") }
            guard let fields = arguments["fields"] as? [String: Any] else { throw ToolError.missingParam("fields") }
            if let rect = await adapter.screenRectForSelector(selector) {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: center,
                    label: "Fill form",
                    duration: 0.25
                )
            }
            let payload = try await adapter.fillForm(selector: selector, fields: fields)
            return merge(["success": true, "selector": selector], payload)

        case "submit_form":
            guard let selector = arguments["selector"] as? String else { throw ToolError.missingParam("selector") }
            if let rect = await adapter.screenRectForSelector(selector) {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                appState.cursorOverlay.showClickAt(screenPointCGTopLeft: center, label: "Submit")
            }
            try await adapter.submitForm(selector: selector)
            return ["success": true, "selector": selector]

        case "select_option":
            guard let selector = arguments["selector"] as? String,
                  let value = arguments["value"] as? String else {
                throw ToolError.missingParam("selector and value")
            }
            if let rect = await adapter.screenRectForSelector(selector) {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                appState.cursorOverlay.showClickAt(screenPointCGTopLeft: center, label: "Select")
            }
            try await adapter.selectOption(selector: selector, value: value)
            return ["success": true, "selector": selector, "value": value]

        case "set_checkbox":
            guard let selector = arguments["selector"] as? String else { throw ToolError.missingParam("selector") }
            let checked = (arguments["checked"] as? Bool) ?? true
            if let rect = await adapter.screenRectForSelector(selector) {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                appState.cursorOverlay.showClickAt(
                    screenPointCGTopLeft: center,
                    label: checked ? "Check" : "Uncheck"
                )
            }
            try await adapter.setCheckbox(selector: selector, checked: checked)
            return ["success": true, "selector": selector, "checked": checked]

        case "get_network":
            let urlPattern = arguments["urlPattern"] as? String
            let limit = intArg(arguments["limit"]) ?? 50
            let requests = adapter.getNetworkRequests(urlPattern: urlPattern, limit: limit)
            return ["success": true, "count": requests.count, "requests": requests]

        case "clear_network":
            adapter.clearNetwork()
            return ["success": true]

        case "get_failed_requests":
            let limit = intArg(arguments["limit"]) ?? 50
            let requests = adapter.getFailedRequests(limit: limit)
            return ["success": true, "count": requests.count, "requests": requests]

        case "get_content":
            let selector = arguments["selector"] as? String
            let type = (arguments["type"] as? String) ?? "text"
            let content = try await adapter.getContent(selector: selector, type: type)
            return ["success": true, "content": content, "type": type]

        case "get_title":
            let title = try await adapter.getTitle()
            return ["success": true, "title": title]

        case "get_url":
            let url = try await adapter.getURL()
            return ["success": true, "url": url]

        case "get_console":
            let type = arguments["type"] as? String
            let limit = intArg(arguments["limit"]) ?? 50
            let pattern = arguments["pattern"] as? String
            let messages = adapter.getConsoleMessages(type: type, limit: limit, pattern: pattern)
            return ["success": true, "messages": messages, "count": messages.count]

        case "clear_console":
            adapter.clearConsole()
            return ["success": true]

        default:
            throw ToolError.unknownTool(tool)
        }
    }

    // MARK: - Mac App dispatch

    private func dispatchMacApp(tool: String, arguments: [String: Any], sessionId: String) async throws -> [String: Any] {
        guard let adapter = appState.macAppAdapters[sessionId] else {
            throw ToolError.noAdapter
        }
        switch tool {
        case "mac_build":
            let productName = arguments["productName"] as? String
            let configuration = (arguments["configuration"] as? String) ?? "debug"
            let result = try await adapter.build(productName: productName, configuration: configuration)
            return result.asDict()

        case "mac_run":
            let productName = arguments["productName"] as? String
            let args = (arguments["args"] as? [String]) ?? []
            let configuration = (arguments["configuration"] as? String) ?? "debug"
            let info = try await adapter.run(productName: productName, args: args, configuration: configuration)
            return merge(["success": true], info)

        case "mac_stop":
            let info = try await adapter.stop()
            return merge(["success": true], info)

        case "mac_screenshot":
            // Visual: pulsing rect around the bound window + "Screenshot"
            // cursor at top-left corner. Anchor BEFORE the SCK capture so
            // the user sees the rect appear, then SCK runs (config disables
            // hardware cursor so the overlay doesn't bake into the PNG).
            if let frame = adapter.targetWindowFrame() {
                appState.cursorOverlay.showScreenshotCapture(rectCGTopLeft: frame)
            }
            let data = try await adapter.screenshot()
            let filename = "mac-shot-\(UUID().uuidString).png"
            let path = NSTemporaryDirectory() + filename
            try data.write(to: URL(fileURLWithPath: path))
            return ["success": true, "path": path, "size": data.count, "format": "png"]

        case "mac_ax_tree":
            let maxDepth = intArg(arguments["maxDepth"]) ?? 5
            let tree = try await adapter.axTree(maxDepth: maxDepth)
            return ["success": true, "tree": tree, "maxDepth": maxDepth]

        case "mac_click":
            guard let query = arguments["query"] as? String else { throw ToolError.missingParam("query") }
            // Cursor anticipates the press: pre-resolve the frame, plant the
            // arrow on it (no ripple yet), then perform the press. On success
            // emit the ripple at the same point so user sees "approach → tap".
            // findFrame walks the AX tree once; click walks it again — costs
            // ~1ms total. Acceptable for v1; could be unified later.
            let preFrame = try? await adapter.findFrame(query: query)
            if let f = preFrame {
                let center = CGPoint(x: f.midX, y: f.midY)
                appState.cursorOverlay.showCursorAt(screenPointCGTopLeft: center, label: "Click")
            }
            let info = try await adapter.click(query: query)
            if let f = preFrame {
                let center = CGPoint(x: f.midX, y: f.midY)
                appState.cursorOverlay.showClickAt(screenPointCGTopLeft: center, label: "Click")
            }
            return merge(["success": true], info)

        case "mac_type":
            guard let text = arguments["text"] as? String else { throw ToolError.missingParam("text") }
            let query = arguments["query"] as? String
            // Plant cursor on the target field (if a query was given) so the
            // user sees where Claude is typing. No ripple — typing isn't a
            // click. Label shows a short text preview, matching Chrome's
            // intent ribbon convention.
            if let q = query, let f = try? await adapter.findFrame(query: q) {
                let preview = text.count > 18 ? String(text.prefix(18)) + "…" : text
                let center = CGPoint(x: f.midX, y: f.midY)
                appState.cursorOverlay.showCursorAt(screenPointCGTopLeft: center, label: "Type \"\(preview)\"")
            }
            let info = try await adapter.type(text: text, query: query)
            return merge(["success": true], info)

        case "mac_console":
            let limit = intArg(arguments["limit"]) ?? 200
            let stream = arguments["stream"] as? String
            let lines = adapter.console(limit: limit, stream: stream)
            return ["success": true, "lines": lines, "count": lines.count]

        case "mac_clear_console":
            adapter.clearConsole()
            return ["success": true]

        case "mac_double_click":
            guard let query = arguments["query"] as? String else { throw ToolError.missingParam("query") }
            if let f = try? await adapter.findFrame(query: query) {
                appState.cursorOverlay.showDoubleClickAt(screenPointCGTopLeft: CGPoint(x: f.midX, y: f.midY))
            }
            let info = try await adapter.doubleClick(query: query)
            return merge(["success": true], info)

        case "mac_right_click":
            guard let query = arguments["query"] as? String else { throw ToolError.missingParam("query") }
            if let f = try? await adapter.findFrame(query: query) {
                appState.cursorOverlay.showRightClickAt(screenPointCGTopLeft: CGPoint(x: f.midX, y: f.midY))
            }
            let info = try await adapter.rightClick(query: query)
            return merge(["success": true], info)

        case "mac_hover":
            guard let query = arguments["query"] as? String else { throw ToolError.missingParam("query") }
            let duration = (arguments["duration"] as? Double) ?? 1.0
            if let f = try? await adapter.findFrame(query: query) {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: f.midX, y: f.midY),
                    label: "Hover", duration: 0.25
                )
            }
            let info = try await adapter.hover(query: query, duration: duration)
            return merge(["success": true], info)

        case "mac_scroll":
            guard let direction = arguments["direction"] as? String else { throw ToolError.missingParam("direction") }
            let query = arguments["query"] as? String
            let amount = (arguments["amount"] as? Double) ?? 100
            // Plant cursor on the scroll target if a query was given, or at the
            // center of the focused window otherwise.
            let anchorFrame: CGRect?
            if let q = query {
                anchorFrame = try? await adapter.findFrame(query: q)
            } else {
                anchorFrame = adapter.targetWindowFrame()
            }
            if let f = anchorFrame {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: f.midX, y: f.midY),
                    label: "Scroll \(direction)", duration: 0.2
                )
            }
            let info = try await adapter.scroll(query: query, direction: direction, amount: amount)
            return merge(["success": true], info)

        case "mac_drag":
            guard let fromQuery = arguments["fromQuery"] as? String else { throw ToolError.missingParam("fromQuery") }
            guard let toQuery = arguments["toQuery"] as? String else { throw ToolError.missingParam("toQuery") }
            let duration = (arguments["duration"] as? Double) ?? 0.5
            // Plant cursor at source first; tween to destination over the drag
            // duration so the user sees the path. Both showCursorAt calls use
            // the cursor-tween machinery — second call's `from` is the first's
            // `to`, so motion is continuous.
            if let f = try? await adapter.findFrame(query: fromQuery) {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: f.midX, y: f.midY),
                    label: "Drag", duration: 0.0
                )
            }
            if let t = try? await adapter.findFrame(query: toQuery) {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: t.midX, y: t.midY),
                    label: "Drag", duration: duration
                )
            }
            let info = try await adapter.drag(fromQuery: fromQuery, toQuery: toQuery, duration: duration)
            return merge(["success": true], info)

        case "mac_focus":
            guard let query = arguments["query"] as? String else { throw ToolError.missingParam("query") }
            if let f = try? await adapter.findFrame(query: query) {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: f.midX, y: f.midY),
                    label: "Focus", duration: 0.2
                )
            }
            let info = try await adapter.focus(query: query)
            return merge(["success": true], info)

        case "mac_key":
            guard let keys = arguments["keys"] as? String else { throw ToolError.missingParam("keys") }
            // No spatial cursor anchor — keys are sent to whatever is focused.
            // The intent overlay strip carries the visual signal.
            let info = try await adapter.sendKey(keys)
            return merge(["success": true], info)

        case "mac_press_return":
            let info = try await adapter.pressReturn()
            return merge(["success": true], info)

        case "mac_find":
            guard let query = arguments["query"] as? String else { throw ToolError.missingParam("query") }
            // Plant cursor on the FIRST match's center so user sees where
            // Claude is looking. findFrame walks the AX tree once; findAll
            // walks it again — costs ~1ms total. Acceptable for a read.
            // Failure is silent — the tool itself returns [] for no matches,
            // but we still want some visual signal that Claude is inspecting.
            if let f = try? await adapter.findFrame(query: query) {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: f.midX, y: f.midY),
                    label: "Find \"\(query)\"", duration: 0.2
                )
            } else if let win = adapter.targetWindowFrame() {
                // No match yet (or query intentionally broad) — anchor on the
                // window so the user still sees the inspection happen.
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: win.midX, y: win.midY),
                    label: "Find \"\(query)\"", duration: 0.2
                )
            }
            let matches = try await adapter.findAll(query: query)
            return ["success": true, "query": query, "matches": matches, "count": matches.count]

        case "mac_wait_for":
            guard let query = arguments["query"] as? String else { throw ToolError.missingParam("query") }
            let timeout = (arguments["timeout"] as? Double) ?? 5.0
            // Anchor on the window center while polling — the match doesn't
            // exist yet by definition, so we can't plant on it. The label
            // makes the wait legible to the user. Once the match resolves
            // we *could* re-plant on it, but the tool returns immediately
            // and the next dispatched tool will handle its own cursor.
            if let win = adapter.targetWindowFrame() {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: win.midX, y: win.midY),
                    label: "Wait for \"\(query)\"", duration: 0.3
                )
            }
            let info = try await adapter.waitFor(query: query, timeout: timeout)
            // Now that we found it, plant the cursor at its center so the
            // user sees the resolution. Brief duration — the next tool call
            // will most likely re-anchor.
            if let frameDict = info["frame"] as? [String: Any],
               let x = frameDict["x"] as? CGFloat, let y = frameDict["y"] as? CGFloat,
               let w = frameDict["w"] as? CGFloat, let h = frameDict["h"] as? CGFloat {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: x + w / 2, y: y + h / 2),
                    label: "Found", duration: 0.2
                )
            }
            return merge(["success": true], info)

        case "mac_list_interactive":
            let role = arguments["role"] as? String
            // No specific target — anchor at window center so the user sees
            // the inspection happen on the bound surface.
            if let win = adapter.targetWindowFrame() {
                let label = role.map { "List \($0)" } ?? "List interactive"
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: win.midX, y: win.midY),
                    label: label, duration: 0.2
                )
            }
            let elements = try await adapter.listInteractive(role: role)
            return ["success": true, "role": role as Any, "elements": elements, "count": elements.count]

        case "mac_get_element":
            guard let query = arguments["query"] as? String else { throw ToolError.missingParam("query") }
            // Plant cursor on the matched element so the user sees Claude
            // inspecting it. findFrame walks the tree once; getElement walks
            // it again — costs ~1ms total.
            if let f = try? await adapter.findFrame(query: query) {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: f.midX, y: f.midY),
                    label: "Inspect \"\(query)\"", duration: 0.2
                )
            }
            let element = try await adapter.getElement(query: query)
            return ["success": true, "query": query, "element": element]

        case "mac_get_content":
            // No specific target — anchor at window center so the user sees
            // Claude reading the screen.
            if let win = adapter.targetWindowFrame() {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: win.midX, y: win.midY),
                    label: "Read screen", duration: 0.2
                )
            }
            let text = try await adapter.getContent()
            return ["success": true, "text": text, "length": text.count]

        default:
            throw ToolError.unknownTool(tool)
        }
    }

    // MARK: - Native App dispatch

    private func dispatchNativeApp(tool: String, arguments: [String: Any], sessionId: String) async throws -> [String: Any] {
        guard let adapter = appState.nativeAdapters[sessionId] else {
            throw ToolError.noAdapter
        }
        switch tool {
        case "native_screenshot":
            // Pulse a rect around the bound app's window before SCK fires
            // so the user sees the capture happening. SCK config disables
            // the hardware cursor; the overlay panel is a separate window
            // layer so SCK shouldn't pick it up either.
            if let frame = adapter.targetWindowFrame() {
                appState.cursorOverlay.showScreenshotCapture(rectCGTopLeft: frame)
            }
            let data = try await adapter.screenshot()
            let filename = "native-shot-\(UUID().uuidString).png"
            let path = NSTemporaryDirectory() + filename
            try data.write(to: URL(fileURLWithPath: path))
            return ["success": true, "path": path, "size": data.count, "format": "png"]

        case "native_ax_tree":
            let maxDepth = intArg(arguments["maxDepth"]) ?? 5
            // Read-only — anchor at window center so the user sees Claude
            // inspecting the bound surface.
            if let win = adapter.targetWindowFrame() {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: win.midX, y: win.midY),
                    label: "AX tree", duration: 0.2
                )
            }
            let tree = try await adapter.axTree(maxDepth: maxDepth)
            return ["success": true, "tree": tree, "maxDepth": maxDepth]

        case "native_click":
            guard let query = arguments["query"] as? String else { throw ToolError.missingParam("query") }
            let preFrame = try? await adapter.findFrame(query: query)
            if let f = preFrame {
                let center = CGPoint(x: f.midX, y: f.midY)
                appState.cursorOverlay.showCursorAt(screenPointCGTopLeft: center, label: "Click")
            }
            let info = try await adapter.click(query: query)
            if let f = preFrame {
                let center = CGPoint(x: f.midX, y: f.midY)
                appState.cursorOverlay.showClickAt(screenPointCGTopLeft: center, label: "Click")
            }
            return merge(["success": true], info)

        case "native_double_click":
            guard let query = arguments["query"] as? String else { throw ToolError.missingParam("query") }
            if let f = try? await adapter.findFrame(query: query) {
                appState.cursorOverlay.showDoubleClickAt(screenPointCGTopLeft: CGPoint(x: f.midX, y: f.midY))
            }
            let info = try await adapter.doubleClick(query: query)
            return merge(["success": true], info)

        case "native_right_click":
            guard let query = arguments["query"] as? String else { throw ToolError.missingParam("query") }
            if let f = try? await adapter.findFrame(query: query) {
                appState.cursorOverlay.showRightClickAt(screenPointCGTopLeft: CGPoint(x: f.midX, y: f.midY))
            }
            let info = try await adapter.rightClick(query: query)
            return merge(["success": true], info)

        case "native_hover":
            guard let query = arguments["query"] as? String else { throw ToolError.missingParam("query") }
            let duration = (arguments["duration"] as? Double) ?? 1.0
            if let f = try? await adapter.findFrame(query: query) {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: f.midX, y: f.midY),
                    label: "Hover", duration: 0.25
                )
            }
            let info = try await adapter.hover(query: query, duration: duration)
            return merge(["success": true], info)

        case "native_type":
            guard let text = arguments["text"] as? String else { throw ToolError.missingParam("text") }
            let query = arguments["query"] as? String
            if let q = query, let f = try? await adapter.findFrame(query: q) {
                let preview = text.count > 18 ? String(text.prefix(18)) + "…" : text
                let center = CGPoint(x: f.midX, y: f.midY)
                appState.cursorOverlay.showCursorAt(screenPointCGTopLeft: center, label: "Type \"\(preview)\"")
            } else if let win = adapter.targetWindowFrame() {
                // No selector — anchor at window center as a "Claude is here" beacon.
                let preview = text.count > 18 ? String(text.prefix(18)) + "…" : text
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: win.midX, y: win.midY),
                    label: "Type \"\(preview)\"", duration: 0.2
                )
            }
            let info = try await adapter.type(text: text, query: query)
            return merge(["success": true], info)

        case "native_focus":
            guard let query = arguments["query"] as? String else { throw ToolError.missingParam("query") }
            if let f = try? await adapter.findFrame(query: query) {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: f.midX, y: f.midY),
                    label: "Focus", duration: 0.2
                )
            }
            let info = try await adapter.focus(query: query)
            return merge(["success": true], info)

        case "native_scroll":
            guard let direction = arguments["direction"] as? String else { throw ToolError.missingParam("direction") }
            let query = arguments["query"] as? String
            let amount = (arguments["amount"] as? Double) ?? 100
            let anchorFrame: CGRect?
            if let q = query {
                anchorFrame = try? await adapter.findFrame(query: q)
            } else {
                anchorFrame = adapter.targetWindowFrame()
            }
            if let f = anchorFrame {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: f.midX, y: f.midY),
                    label: "Scroll \(direction)", duration: 0.2
                )
            }
            let info = try await adapter.scroll(query: query, direction: direction, amount: amount)
            return merge(["success": true], info)

        case "native_key":
            guard let keys = arguments["keys"] as? String else { throw ToolError.missingParam("keys") }
            // No spatial anchor — keys are sent to whatever's focused. The
            // intent overlay strip carries the visual signal. Plant a
            // beacon at window center so the user still sees Claude is
            // doing something on this surface.
            if let win = adapter.targetWindowFrame() {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: win.midX, y: win.midY),
                    label: "Press \(keys)", duration: 0.2
                )
            }
            let info = try await adapter.sendKey(keys)
            return merge(["success": true], info)

        case "native_press_return":
            if let win = adapter.targetWindowFrame() {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: win.midX, y: win.midY),
                    label: "Press return", duration: 0.2
                )
            }
            let info = try await adapter.pressReturn()
            return merge(["success": true], info)

        case "native_find":
            guard let query = arguments["query"] as? String else { throw ToolError.missingParam("query") }
            // Plant cursor on the first match if any, else on the window
            // itself so the user still sees the inspection happen.
            if let f = try? await adapter.findFrame(query: query) {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: f.midX, y: f.midY),
                    label: "Find \"\(query)\"", duration: 0.2
                )
            } else if let win = adapter.targetWindowFrame() {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: win.midX, y: win.midY),
                    label: "Find \"\(query)\"", duration: 0.2
                )
            }
            let matches = try await adapter.findAll(query: query)
            return ["success": true, "query": query, "matches": matches, "count": matches.count]

        case "native_wait_for":
            guard let query = arguments["query"] as? String else { throw ToolError.missingParam("query") }
            let timeout = (arguments["timeout"] as? Double) ?? 5.0
            if let win = adapter.targetWindowFrame() {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: win.midX, y: win.midY),
                    label: "Wait for \"\(query)\"", duration: 0.3
                )
            }
            let info = try await adapter.waitFor(query: query, timeout: timeout)
            // Re-anchor on the resolved match so the user sees where it appeared.
            if let frameDict = info["frame"] as? [String: Any],
               let x = frameDict["x"] as? CGFloat, let y = frameDict["y"] as? CGFloat,
               let w = frameDict["w"] as? CGFloat, let h = frameDict["h"] as? CGFloat {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: x + w / 2, y: y + h / 2),
                    label: "Found", duration: 0.2
                )
            }
            return merge(["success": true], info)

        case "native_list_interactive":
            let role = arguments["role"] as? String
            if let win = adapter.targetWindowFrame() {
                let label = role.map { "List \($0)" } ?? "List interactive"
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: win.midX, y: win.midY),
                    label: label, duration: 0.2
                )
            }
            let elements = try await adapter.listInteractive(role: role)
            return ["success": true, "role": role as Any, "elements": elements, "count": elements.count]

        case "native_get_element":
            guard let query = arguments["query"] as? String else { throw ToolError.missingParam("query") }
            if let f = try? await adapter.findFrame(query: query) {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: f.midX, y: f.midY),
                    label: "Inspect \"\(query)\"", duration: 0.2
                )
            }
            let element = try await adapter.getElement(query: query)
            return ["success": true, "query": query, "element": element]

        case "native_get_content":
            if let win = adapter.targetWindowFrame() {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: win.midX, y: win.midY),
                    label: "Read screen", duration: 0.2
                )
            }
            let text = try await adapter.getContent()
            return ["success": true, "text": text, "length": text.count]

        default:
            throw ToolError.unknownTool(tool)
        }
    }

    // MARK: - Simulator dispatch

    private func dispatchSimulator(tool: String, arguments: [String: Any], sessionId: String) async throws -> [String: Any] {
        guard let adapter = appState.simAdapters[sessionId] else {
            throw ToolError.noAdapter
        }
        switch tool {
        case "sim_screenshot":
            // Visual: pulse a rect around the Simulator window if we can find
            // it. Same pattern as mac_screenshot. SCK isn't involved here
            // (simctl reads from the simulator's framebuffer directly), so the
            // overlay won't bake into the PNG either way.
            if let frame = adapter.targetWindowFrame() {
                appState.cursorOverlay.showScreenshotCapture(rectCGTopLeft: frame)
            }
            let data = try await adapter.screenshot()
            let path = NSTemporaryDirectory() + "sim-shot-\(UUID().uuidString).png"
            try data.write(to: URL(fileURLWithPath: path))
            return ["success": true, "path": path, "size": data.count, "format": "png"]

        case "sim_state":
            let info = try await adapter.currentState()
            return merge(["success": true], info)

        case "sim_launch":
            guard let bundleId = arguments["bundleId"] as? String else { throw ToolError.missingParam("bundleId") }
            let args = (arguments["args"] as? [String]) ?? []
            let info = try await adapter.launch(bundleId: bundleId, args: args)
            return merge(["success": true], info)

        case "sim_terminate":
            guard let bundleId = arguments["bundleId"] as? String else { throw ToolError.missingParam("bundleId") }
            let info = try await adapter.terminate(bundleId: bundleId)
            return merge(["success": true], info)

        case "sim_openurl":
            guard let url = arguments["url"] as? String else { throw ToolError.missingParam("url") }
            let info = try await adapter.openurl(url)
            return merge(["success": true], info)

        case "sim_install":
            guard let appPath = arguments["appPath"] as? String else { throw ToolError.missingParam("appPath") }
            let info = try await adapter.install(appPath: appPath)
            return merge(["success": true], info)

        case "sim_uninstall":
            guard let bundleId = arguments["bundleId"] as? String else { throw ToolError.missingParam("bundleId") }
            let info = try await adapter.uninstall(bundleId: bundleId)
            return merge(["success": true], info)

        case "sim_set_appearance":
            guard let mode = arguments["mode"] as? String else { throw ToolError.missingParam("mode") }
            let info = try await adapter.setAppearance(mode)
            return merge(["success": true], info)

        case "sim_push":
            guard let bundleId = arguments["bundleId"] as? String else { throw ToolError.missingParam("bundleId") }
            guard let payload = arguments["payloadJson"] as? String else { throw ToolError.missingParam("payloadJson") }
            let info = try await adapter.sendPush(bundleId: bundleId, payloadJson: payload)
            return merge(["success": true], info)

        // ----- Gestures (idb-backed) -----
        // Coord conventions: tools take host-screen (x, y) by default — matches
        // sim_screenshot output coords. Optional vpX/vpY override goes straight
        // to idb in viewport coords if the AI already knows them.

        case "sim_tap":
            let (vpx, vpy, hostPt) = try await resolveSimCoords(adapter: adapter, args: arguments, xKey: "x", yKey: "y", vpXKey: "vpX", vpYKey: "vpY")
            if let hp = hostPt {
                appState.cursorOverlay.showClickAt(screenPointCGTopLeft: hp, label: "Tap")
            }
            let info = try await adapter.tap(viewportX: vpx, viewportY: vpy)
            return merge(["success": true], info)

        case "sim_double_tap":
            let (vpx, vpy, hostPt) = try await resolveSimCoords(adapter: adapter, args: arguments, xKey: "x", yKey: "y", vpXKey: "vpX", vpYKey: "vpY")
            if let hp = hostPt {
                appState.cursorOverlay.showDoubleClickAt(screenPointCGTopLeft: hp, label: "Double-tap")
            }
            let info = try await adapter.doubleTap(viewportX: vpx, viewportY: vpy)
            return merge(["success": true], info)

        case "sim_long_press":
            let (vpx, vpy, hostPt) = try await resolveSimCoords(adapter: adapter, args: arguments, xKey: "x", yKey: "y", vpXKey: "vpX", vpYKey: "vpY")
            let duration = (arguments["duration"] as? Double) ?? 0.8
            if let hp = hostPt {
                appState.cursorOverlay.showRightClickAt(screenPointCGTopLeft: hp, label: "Long-press")
            }
            let info = try await adapter.longPress(viewportX: vpx, viewportY: vpy, durationSec: duration)
            return merge(["success": true], info)

        case "sim_swipe", "sim_drag":
            let (fromVpx, fromVpy, fromHost) = try await resolveSimCoords(adapter: adapter, args: arguments, xKey: "fromX", yKey: "fromY", vpXKey: "fromVpX", vpYKey: "fromVpY")
            let (toVpx, toVpy, toHost) = try await resolveSimCoords(adapter: adapter, args: arguments, xKey: "toX", yKey: "toY", vpXKey: "toVpX", vpYKey: "toVpY")
            // Swipe defaults 0.25s, drag defaults 0.5s — same idb call shape.
            let defaultDur = tool == "sim_drag" ? 0.5 : 0.25
            let duration = (arguments["duration"] as? Double) ?? defaultDur
            // Cursor sweep — pop at start, tween to end over the gesture's
            // duration so the user sees the path.
            if let fh = fromHost {
                appState.cursorOverlay.showCursorAt(screenPointCGTopLeft: fh, label: tool == "sim_drag" ? "Drag" : "Swipe", duration: 0.0)
            }
            if let th = toHost {
                appState.cursorOverlay.showCursorAt(screenPointCGTopLeft: th, label: tool == "sim_drag" ? "Drag" : "Swipe", duration: duration)
            }
            let info = try await adapter.swipe(fromX: fromVpx, fromY: fromVpy, toX: toVpx, toY: toVpy, durationSec: duration)
            return merge(["success": true], info)

        case "sim_pinch":
            let (cx, cy, centerHost) = try await resolveSimCoords(adapter: adapter, args: arguments, xKey: "centerX", yKey: "centerY", vpXKey: "centerVpX", vpYKey: "centerVpY")
            guard let scale = arguments["scale"] as? Double else { throw ToolError.missingParam("scale") }
            let duration = (arguments["duration"] as? Double) ?? 0.4
            if let ch = centerHost {
                appState.cursorOverlay.showPinchAt(centerCGTopLeft: ch, scale: scale, label: scale > 1 ? "Pinch out" : "Pinch in")
            }
            // Two opposite swipes around center. For pinch-out (scale > 1),
            // start close, end far. Pinch-in: start far, end close.
            let halfStart: Double = scale > 1 ? 20 : 100 * abs(scale - 1)
            let halfEnd: Double = scale > 1 ? 100 * (scale - 1) : 20
            // Issue both as concurrent Tasks so idb sees them as roughly
            // parallel. idb itself doesn't have a native pinch primitive
            // accessible via the swipe API; this is a best-effort approximation
            // and may register as two sequential swipes rather than a true
            // pinch on iOS depending on idb version.
            async let left = JSONDictionaryTransfer(try await adapter.swipe(
                fromX: cx - halfStart, fromY: cy,
                toX: cx - halfEnd, toY: cy, durationSec: duration))
            async let right = JSONDictionaryTransfer(try await adapter.swipe(
                fromX: cx + halfStart, fromY: cy,
                toX: cx + halfEnd, toY: cy, durationSec: duration))
            _ = try await (left, right)
            return ["success": true, "scale": scale, "center": ["x": cx, "y": cy], "duration": duration, "pinched": true]

        case "sim_button":
            guard let name = arguments["name"] as? String else { throw ToolError.missingParam("name") }
            // No spatial anchor — buttons are device-physical. Future: small
            // floating glyph centered on Simulator window.
            let info = try await adapter.pressButton(name)
            return merge(["success": true], info)

        case "sim_text":
            guard let text = arguments["text"] as? String else { throw ToolError.missingParam("text") }
            // Plant cursor at center of sim window with a text preview label.
            if let frame = adapter.targetWindowFrame() {
                let preview = text.count > 18 ? String(text.prefix(18)) + "…" : text
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: frame.midX, y: frame.midY),
                    label: "Type \"\(preview)\"", duration: 0.2
                )
            }
            let info = try await adapter.typeText(text)
            return merge(["success": true], info)

        case "sim_key":
            guard let kc = intArg(arguments["keycode"]) else { throw ToolError.missingParam("keycode") }
            let info = try await adapter.pressKey(kc)
            return merge(["success": true], info)

        case "sim_keys":
            guard let raw = arguments["keycodes"] as? [Any] else { throw ToolError.missingParam("keycodes") }
            let codes = raw.compactMap { intArg($0) }
            let info = try await adapter.pressKeySequence(codes)
            return merge(["success": true], info)

        case "sim_find_element":
            guard let query = arguments["query"] as? String else { throw ToolError.missingParam("query") }
            if let frame = adapter.targetWindowFrame() {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: frame.midX, y: frame.midY),
                    label: "Find \"\(query)\"", duration: 0.2
                )
            }
            let matches = try await adapter.findElement(query: query)
            return ["success": true, "query": query, "matches": matches, "count": matches.count]

        case "sim_wait_for":
            guard let query = arguments["query"] as? String else { throw ToolError.missingParam("query") }
            let timeout = (arguments["timeout"] as? Double) ?? 5.0
            if let frame = adapter.targetWindowFrame() {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: frame.midX, y: frame.midY),
                    label: "Waiting for \"\(query)\"", duration: 0.2
                )
            }
            let info = try await adapter.waitForElement(query: query, timeout: timeout)
            return merge(["success": true], info)

        case "sim_list_interactive":
            let type = arguments["type"] as? String
            if let frame = adapter.targetWindowFrame() {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: frame.midX, y: frame.midY),
                    label: "List interactive", duration: 0.2
                )
            }
            let elements = try await adapter.listInteractive(type: type)
            return ["success": true, "elements": elements, "count": elements.count]

        case "sim_get_element":
            guard let query = arguments["query"] as? String else { throw ToolError.missingParam("query") }
            if let frame = adapter.targetWindowFrame() {
                appState.cursorOverlay.showCursorAt(
                    screenPointCGTopLeft: CGPoint(x: frame.midX, y: frame.midY),
                    label: "Get \"\(query)\"", duration: 0.2
                )
            }
            let element = try await adapter.getElement(query: query)
            return ["success": true, "element": element]

        default:
            throw ToolError.unknownTool(tool)
        }
    }

    /// Resolve sim coords: prefer viewport (vpX/vpY) if both present, else
    /// translate host-screen (x/y) via the adapter's screenToViewport. Returns
    /// (viewportX, viewportY, hostScreenPoint?) — the host point is nil when
    /// the caller passed viewport directly so we can't reverse-derive it for
    /// the cursor overlay.
    private func resolveSimCoords(
        adapter: SimulatorAdapter, args: [String: Any],
        xKey: String, yKey: String, vpXKey: String, vpYKey: String
    ) async throws -> (Double, Double, CGPoint?) {
        if let vx = args[vpXKey] as? Double, let vy = args[vpYKey] as? Double {
            return (vx, vy, nil)
        }
        guard let hx = args[xKey] as? Double, let hy = args[yKey] as? Double else {
            throw ToolError.missingParam(xKey)
        }
        let host = CGPoint(x: hx, y: hy)
        guard let vp = await adapter.screenToViewport(host) else {
            throw ToolError.invalidArgument("No Simulator window visible — can't translate host coords. Boot the sim or pass vpX/vpY directly.")
        }
        return (Double(vp.x), Double(vp.y), host)
    }

    // MARK: - Plain-verb auto-routing

    /// Map a plain (unprefixed) Chrome verb to the bound adapter's equivalent
    /// when the session is bound to a non-Chrome target. Returns nil for
    /// verbs that don't translate (e.g. Chrome-only `execute_js`, `navigate`,
    /// `get_url`) — caller falls through to the original "no Chrome adapter"
    /// error so the user knows that verb really only makes sense for Chrome.
    static func reroutedToolName(plain: String, target: Target) -> String? {
        switch target {
        case .chrome:
            return nil  // Chrome bindings use plain verbs natively.
        case .macAppProject:
            return Self.macTranslations[plain]
        case .nativeApp:
            return Self.nativeTranslations[plain]
        case .simulator:
            return Self.simTranslations[plain]
        }
    }

    /// Some verbs change argument shape across adapters (Chrome `click`
    /// uses `selector`; native/mac `click` use `query`). Rewrite the args
    /// dict so the routed adapter sees what it expects.
    private func rewrittenArguments(plain: String, args: [String: Any], target: Target) -> [String: Any] {
        if case .chrome = target { return args }
        var out = args
        // Chrome's selector → AX query (mac/native AX matchers want `query`).
        switch target {
        case .nativeApp, .macAppProject:
            renameKey(in: &out, from: "selector", to: "query")
        case .simulator, .chrome:
            break
        }
        return out
    }

    private func renameKey(in dict: inout [String: Any], from old: String, to new: String) {
        if let val = dict.removeValue(forKey: old), dict[new] == nil {
            dict[new] = val
        }
    }

    /// Mac App translation: plain Chrome verb → `mac_<verb>`.
    private static let macTranslations: [String: String] = [
        "click": "mac_click",
        "double_click": "mac_double_click",
        "right_click": "mac_right_click",
        "type": "mac_type",
        "hover": "mac_hover",
        "scroll": "mac_scroll",
        "drag_drop": "mac_drag",
        "press_key": "mac_key",
        "focus": "mac_focus",
        "find": "mac_find",
        "wait_for": "mac_wait_for",
        "list_interactive": "mac_list_interactive",
        "get_element": "mac_get_element",
        "get_content": "mac_get_content",
        "screenshot": "mac_screenshot",
    ]

    /// Native App translation — same verbs, `native_` prefix.
    private static let nativeTranslations: [String: String] = [
        "click": "native_click",
        "double_click": "native_double_click",
        "right_click": "native_right_click",
        "type": "native_type",
        "hover": "native_hover",
        "scroll": "native_scroll",
        "drag_drop": "native_drag",
        "press_key": "native_key",
        "focus": "native_focus",
        "find": "native_find",
        "wait_for": "native_wait_for",
        "list_interactive": "native_list_interactive",
        "get_element": "native_get_element",
        "get_content": "native_get_content",
        "screenshot": "native_screenshot",
    ]

    /// Sim translation — note `screenshot` and `wait_for` map cleanly,
    /// other interactions don't (sim uses tap-by-coord, Chrome uses
    /// click-by-selector — incompatible signatures).
    private static let simTranslations: [String: String] = [
        "screenshot": "sim_screenshot",
        "wait_for": "sim_wait_for",
        "find": "sim_find_element",
        "list_interactive": "sim_list_interactive",
        "get_element": "sim_get_element",
    ]

    // MARK: - Helpers

    /// MCP clients sometimes serialize integers as strings or doubles. Coerce.
    private func intArg(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let d = raw as? Double { return Int(d) }
        if let s = raw as? String, let i = Int(s) { return i }
        return nil
    }

    /// Make sure we only stuff JSON-safe values into the response dict.
    /// CDP `Runtime.evaluate` with returnByValue=true gives us already-serializable values,
    /// but it can also return nil — we map nil to NSNull so it round-trips.
    private func jsonSafe(_ value: Any?) -> Any {
        guard let v = value else { return NSNull() }
        if JSONSerialization.isValidJSONObject([v]) { return v }
        // Fallback: stringify.
        return String(describing: v)
    }

    /// Merge an adapter payload into the response dict. Caller's keys win on collision.
    private func merge(_ base: [String: Any], _ payload: [String: Any]) -> [String: Any] {
        var out = payload
        for (k, v) in base { out[k] = v }
        return out
    }
}
