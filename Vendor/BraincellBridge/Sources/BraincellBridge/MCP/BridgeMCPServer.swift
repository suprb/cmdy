import Foundation
import NIOHTTP1

/// Bridges MCP tool calls (HTTP `/execute`) to the right per-session adapter.
/// Looks up the binding for a sessionId, finds the corresponding ChromeAdapter,
/// and dispatches via BridgeToolRouter.
@MainActor
final class BridgeMCPServer {
    weak var appState: BridgeAppState?

    init(appState: BridgeAppState) {
        self.appState = appState
    }

    /// Register HTTP routes onto the shared HTTPServer.
    func registerRoutes(on http: HTTPServer) {
        // POST /execute — main MCP dispatch
        http.route(.POST, "/execute") { [weak self] req in
            guard let self = self else { return .error("BridgeMCPServer deallocated") }
            return await self.handleExecute(req: req)
        }

        // GET /tools — static tool list for an MCP stdio bridge
        http.route(.GET, "/tools") { _ in
            return .ok(BridgeMCPServer.toolDefinitions())
        }
    }

    private nonisolated func handleExecute(req: HTTPServer.HTTPRequest) async -> HTTPServer.HTTPResponse {
        // Parse body
        guard !req.body.isEmpty,
              let raw = try? JSONSerialization.jsonObject(with: req.body),
              let payload = raw as? [String: Any] else {
            return .badRequest("Body must be JSON object: { tool, arguments, sessionId }")
        }

        guard let tool = payload["tool"] as? String,
              !tool.isEmpty, tool.utf8.count <= 128 else {
            return .badRequest("Missing required field: tool")
        }
        guard let sessionId = payload["sessionId"] as? String,
              !sessionId.isEmpty, sessionId.utf8.count <= 128 else {
            return .badRequest("Missing required field: sessionId")
        }
        let arguments = (payload["arguments"] as? [String: Any]) ?? [:]

        // Feedback tools operate on Bridge's durable semantic-note queue and
        // intentionally do not require a live adapter. A target can close
        // after the user leaves a note; the agent must still be able to read
        // and resolve that record.
        let feedbackTools: Set<String> = [
            "begin_feedback", "get_feedback", "resolve_feedback", "clear_feedback",
        ]
        if feedbackTools.contains(tool) {
            let result: [String: Any] = await MainActor.run {
                guard let appState = self.appState else {
                    return ["error": "BridgeAppState deallocated"]
                }
                switch tool {
                case "begin_feedback":
                    appState.beginFeedback?(sessionId)
                    return ["success": true, "active": true]
                case "get_feedback":
                    let status = arguments["status"] as? String
                    return ["feedback": appState.feedback.list(status: status, sessionId: sessionId)]
                case "resolve_feedback":
                    guard let id = arguments["id"] as? String, !id.isEmpty else {
                        return ["error": "id is required"]
                    }
                    guard let record = appState.feedback.resolve(
                        id: id, resolution: arguments["resolution"] as? String
                    ) else { return ["error": "feedback record not found"] }
                    return ["feedback": record]
                case "clear_feedback":
                    let removed = appState.feedback.clear(
                        resolvedOnly: arguments["resolvedOnly"] as? Bool ?? false,
                        sessionId: sessionId
                    )
                    return ["removed": removed]
                default:
                    return ["error": "unknown feedback tool"]
                }
            }
            return .ok(result)
        }

        // Validate binding & adapter exist; capture appState reference on MainActor.
        // Preflight is target-aware: Chrome bindings need a chromeAdapter,
        // Mac App bindings need a macAppAdapter. Old code always required
        // chromeAdapter, which made every mac_* tool call fail with
        // "no adapter" before the type-specific dispatch router ever ran.
        // That bug ate the entire "Mac App can't be reached" debug arc —
        // the per-call dispatch logic, persisted bindings, self-heal id —
        // all bypassed by the preflight gate above them.
        let preflight: HTTPServer.HTTPResponse? = await MainActor.run {
            guard let appState = self.appState else {
                return HTTPServer.HTTPResponse.error("BridgeAppState deallocated")
            }
            guard let binding = appState.bindings.get(sessionId: sessionId) else {
                return HTTPServer.HTTPResponse.ok([
                    "error": "Terminal not bound to a target. Use the Bridge menu bar to bind."
                ])
            }
            _ = binding   // keep capture so we don't shed the validity check
            // TargetAdapter protocol: single lookup across all per-target
            // dicts. Adding a 5th adapter just needs the new dict added to
            // `BridgeAppState.adapter(for:)` — no edit here. Replaces the
            // per-target switch that bit us once already (Mac App rollout,
            // commit dc61443 — preflight hardcoded chromeAdapters check).
            if appState.adapter(for: sessionId) == nil {
                return HTTPServer.HTTPResponse.ok([
                    "error": "No adapter found for session. Re-bind from the Bridge menu bar."
                ])
            }
            return nil
        }
        if let preflight = preflight { return preflight }

        // Dispatch via tool router (router is @MainActor; awaits cross actor boundary).
        do {
            // Log every tool call so debugging "what did Claude actually do
            // when X broke" doesn't require live tcpdump or in-process
            // breakpoints. Format optimized for grep — `[Execute] tool=X
            // session=...` is one line per invocation.
            NSLog("[Execute] tool=%@ session=%@ args=%@",
                  tool, sessionId, Self.compactArgs(arguments))
            let result: [String: Any] = try await { @MainActor in
                guard let appState = self.appState else {
                    throw NSError(domain: "BridgeMCP", code: 0, userInfo: [
                        NSLocalizedDescriptionKey: "BridgeAppState deallocated",
                    ])
                }
                // Pulse outbound — wire animation flows terminal → browser for ~1.2s.
                appState.pulse(sessionId: sessionId, direction: .outbound)
                let router = BridgeToolRouter(appState: appState)
                return try await router.execute(tool: tool, arguments: arguments, sessionId: sessionId)
            }()
            // Compact result-status log so a normal session doesn't flood with
            // full payloads (screenshots can be 100s of KB). Just the verb,
            // success/error, and a length proxy.
            let isErr = (result["error"] as? String) != nil
            let status = isErr ? "error=\((result["error"] as? String) ?? "")" : "ok"
            NSLog("[Execute] tool=%@ session=%@ %@", tool, sessionId, status)
            return .ok(result)
        } catch {
            NSLog("[Execute] tool=%@ session=%@ threw=%@",
                  tool, sessionId, error.localizedDescription)
            return .ok(["error": error.localizedDescription])
        }
    }

    /// Stringify arguments for the per-tool-call log. Truncates long values
    /// (a typed-text payload or a screenshot path can be huge) so the log
    /// stays scan-friendly. Don't try to parse these later — for grepping
    /// only. `nonisolated` so it can be called from `handleExecute` (which
    /// runs nonisolated to avoid blocking the main actor on every request).
    nonisolated static func compactArgs(_ args: [String: Any]) -> String {
        guard !args.isEmpty else { return "{}" }
        let parts = args.keys.sorted().map { key -> String in
            let v = args[key]
            let s: String
            if let str = v as? String {
                s = str.count > 64 ? "\"\(str.prefix(60))…\"" : "\"\(str)\""
            } else {
                s = String(describing: v ?? "nil")
            }
            return "\(key)=\(s)"
        }
        return "{" + parts.joined(separator: ", ") + "}"
    }

    // MARK: - Tool Definitions

    /// Static list of tools the bridge supports. Matches BridgeToolRouter.execute().
    /// Hints appended to every tool description to bias Claude toward parallel
    /// `tool_use` blocks per turn instead of long sequential chains. Anthropic's
    /// API supports parallel calls natively; the only thing that changes the
    /// behavior is whether tool descriptions invite or suppress batching.
    /// The scene snapshot is captured only when requested.
    private static let readHint = " READ-ONLY — safe to batch in parallel with other read-only tools in the same turn (prefer batching multiple inspections over chaining single calls)."
    private static let mutateHint = " MUTATES PAGE STATE — issue alone in its turn, or alongside reads that observe state preceding this change."
    private static let navHint = " RESETS PAGE STATE — issue alone; follow-up inspections belong in the next turn (use wait_for if you need a specific element to appear first)."
    private static let waitHint = " SYNCHRONOUS WAIT — typically issued alone; act on the awaited element in the next turn."

    static func toolDefinitions() -> [[String: Any]] {
        return [
            tool("begin_feedback",
                 "Let the user point at a live element on the bound surface and attach a semantic note. The note is routed back to this exact agent session." + mutateHint, [:]),
            tool("get_feedback",
                 "List semantic UI feedback captured from the bound surface." + readHint, [
                    "status": ["type": "string", "enum": ["open", "resolved"]],
                 ]),
            tool("resolve_feedback",
                 "Mark one feedback record resolved after implementing or explaining it." + mutateHint, [
                    "id": ["type": "string"],
                    "resolution": ["type": "string"],
                 ], required: ["id"]),
            tool("clear_feedback",
                 "Clear feedback records for this Bridge session." + mutateHint, [
                    "resolvedOnly": ["type": "boolean"],
                 ]),
            tool("navigate", "Navigate the bound Chrome window to a URL." + navHint, [
                "url": ["type": "string", "description": "URL to navigate to"],
            ], required: ["url"]),
            tool("reload", "Reload the current page." + navHint, [
                "ignoreCache": ["type": "boolean", "description": "Bypass the HTTP cache"],
            ]),
            tool("back", "Go back in browser history." + navHint, [:]),
            tool("forward", "Go forward in browser history." + navHint, [:]),
            tool("screenshot",
                "Capture a screenshot. Returns a temp file path." + readHint
                + " Common batch: screenshot + get_content + get_url in one turn for full page understanding.", [
                "format": ["type": "string", "enum": ["png", "jpeg"], "description": "Image format"],
                "quality": ["type": "integer", "description": "JPEG quality (1-100)"],
            ]),
            tool("execute_js",
                "Run a JavaScript expression in the page and return the value. Treat as mutating unless the expression is provably side-effect free." + mutateHint, [
                "code": ["type": "string", "description": "JavaScript expression"],
            ], required: ["code"]),
            tool("click", "Click the first element matching the CSS selector." + mutateHint, [
                "selector": ["type": "string", "description": "CSS selector"],
            ], required: ["selector"]),
            tool("type", "Type text into the first element matching the selector." + mutateHint, [
                "selector": ["type": "string", "description": "CSS selector"],
                "text": ["type": "string", "description": "Text to type"],
                "clear": ["type": "boolean", "description": "Clear existing value first"],
            ], required: ["selector", "text"]),
            tool("get_content",
                "Get text or HTML content from the page or a selector." + readHint
                + " Common batch: get_content + list_interactive + get_url to fully understand a page in one turn.", [
                "selector": ["type": "string", "description": "Optional CSS selector; whole page if omitted"],
                "type": ["type": "string", "enum": ["text", "html"], "description": "Return text or HTML"],
            ]),
            tool("get_title", "Return document.title." + readHint, [:]),
            tool("get_url", "Return window.location.href." + readHint, [:]),
            tool("get_console", "Return buffered console messages." + readHint, [
                "type": ["type": "string", "description": "Filter by level (log, warn, error, ...)"],
                "limit": ["type": "integer", "description": "Max messages to return"],
                "pattern": ["type": "string", "description": "Regex to match against message text"],
            ]),
            tool("clear_console", "Clear the console buffer." + mutateHint, [:]),

            // Mouse / interaction
            tool("hover", "Dispatch mouseover/mouseenter events on the element." + mutateHint, [
                "selector": ["type": "string", "description": "CSS selector"],
            ], required: ["selector"]),
            tool("double_click", "Dispatch a dblclick event on the element." + mutateHint, [
                "selector": ["type": "string", "description": "CSS selector"],
            ], required: ["selector"]),
            tool("right_click", "Dispatch a contextmenu event on the element." + mutateHint, [
                "selector": ["type": "string", "description": "CSS selector"],
            ], required: ["selector"]),
            tool("drag_drop", "Synthesize a drag-and-drop from one element to another." + mutateHint, [
                "source": ["type": "string", "description": "CSS selector for the source element"],
                "target": ["type": "string", "description": "CSS selector for the drop target"],
            ], required: ["source", "target"]),
            tool("scroll", "Scroll the page or scroll an element into view." + mutateHint, [
                "selector": ["type": "string", "description": "Optional CSS selector to scroll into view"],
                "direction": ["type": "string", "enum": ["up", "down", "left", "right"], "description": "Direction when no selector"],
                "amount": ["type": "integer", "description": "Pixels to scroll (default 200)"],
            ]),

            // Keyboard
            tool("press_key", "Dispatch a keyboard event with optional modifiers via CDP Input.dispatchKeyEvent." + mutateHint, [
                "key": ["type": "string", "description": "Key name (e.g. Enter, Tab, a)"],
                "modifiers": [
                    "type": "array",
                    "items": ["type": "string", "enum": ["ctrl", "shift", "alt", "meta"]],
                    "description": "Modifier keys to hold",
                ],
            ], required: ["key"]),
            tool("focus", "Call .focus() on the matched element." + mutateHint, [
                "selector": ["type": "string", "description": "CSS selector"],
            ], required: ["selector"]),

            // Discovery
            tool("find",
                "Heuristic search for interactive elements matching a query (text, aria-label, placeholder)." + readHint
                + " Common batch: find + list_interactive + screenshot to plan an action in one turn.", [
                "query": ["type": "string", "description": "Search terms"],
                "limit": ["type": "integer", "description": "Max results (default 10)"],
            ], required: ["query"]),
            tool("list_interactive", "List all clickable/typeable elements on the page." + readHint, [
                "limit": ["type": "integer", "description": "Max results (default 50)"],
            ]),
            tool("get_element", "Inspect an element: tag, attributes, text, position, visibility." + readHint, [
                "selector": ["type": "string", "description": "CSS selector"],
            ], required: ["selector"]),
            tool("wait_for", "Poll every 100ms until selector resolves or timeout (ms)." + waitHint, [
                "selector": ["type": "string", "description": "CSS selector to wait for"],
                "timeout": ["type": "integer", "description": "Timeout in ms (default 5000)"],
            ], required: ["selector"]),

            // Forms
            tool("get_forms", "Enumerate <form> elements with their fields." + readHint, [:]),
            tool("fill_form", "Fill named fields inside a form by selector." + mutateHint, [
                "selector": ["type": "string", "description": "CSS selector for the form"],
                "fields": ["type": "object", "description": "Map of field name → value"],
            ], required: ["selector", "fields"]),
            tool("submit_form", "Submit a form via .submit()." + mutateHint, [
                "selector": ["type": "string", "description": "CSS selector for the form"],
            ], required: ["selector"]),
            tool("select_option", "Set a <select> value, matching by value or visible text." + mutateHint, [
                "selector": ["type": "string", "description": "CSS selector for the <select>"],
                "value": ["type": "string", "description": "Value or visible text to select"],
            ], required: ["selector", "value"]),
            tool("set_checkbox", "Set a checkbox/radio's checked state." + mutateHint, [
                "selector": ["type": "string", "description": "CSS selector"],
                "checked": ["type": "boolean", "description": "Desired checked state (default true)"],
            ], required: ["selector"]),

            // Network
            tool("get_network", "Return buffered network responses, optionally filtered by URL substring." + readHint, [
                "urlPattern": ["type": "string", "description": "Substring to match against response URL"],
                "limit": ["type": "integer", "description": "Max requests to return (default 50)"],
            ]),
            tool("clear_network", "Clear the network response buffer." + mutateHint, [:]),
            tool("get_failed_requests", "Return buffered network responses with status >= 400." + readHint, [
                "limit": ["type": "integer", "description": "Max requests to return (default 50)"],
            ]),

            // ===== Mac App tools =====
            // Use these ONLY when the session is bound to a Mac App project
            // (Target.macAppProject). Tool names prefixed `mac_` to avoid
            // colliding with Chrome's surface; both can technically appear in
            // the same tools/list but only one set is meaningful per binding.
            tool("mac_build", "Build the bound Mac app project via `swift build`. Returns structured errors and warnings (file/line/column/message). Non-destructive on its own (just compiles; doesn't restart anything). Pair with mac_stop + mac_run for a code-edit → rebuild → relaunch dev loop." + mutateHint, [
                "productName": ["type": "string", "description": "Optional --product name; omitted = SwiftPM default"],
                "configuration": ["type": "string", "enum": ["debug", "release"], "description": "Build configuration (default: debug)"],
            ]),
            tool("mac_run", "Launch the most recently built executable. Returns PID + window count after a brief settle. Errors with `alreadyRunning` if an instance is already running (whether bridge-spawned or externally-launched via swift run / Xcode) — in that case the user is already iterating and you should attach via mac_screenshot/mac_click against the existing pid rather than spawning a duplicate. Use after mac_stop in a code-edit → rebuild → relaunch dev cycle." + mutateHint, [
                "productName": ["type": "string", "description": "Optional product name to launch; otherwise newest executable in .build/"],
                "args": ["type": "array", "items": ["type": "string"], "description": "Optional CLI args to pass to the launched binary"],
                "configuration": ["type": "string", "enum": ["debug", "release"], "description": "Which build dir to look in (default: debug)"],
            ]),
            tool("mac_stop", "Terminate the running Mac app via SIGTERM (then SIGKILL after 1s if still alive). REFUSES to kill externally-launched processes (returns `wasRunning: false, attached: true`) — the bridge only kills what it spawned. The binding survives across mac_stop, so mac_build → mac_stop → mac_run is the standard dev loop. Only fire when (a) the user is iterating with you on code and you need to relaunch with a fresh binary, or (b) the user explicitly asks to quit. Avoid calling on a session where the bridge attached to the user's externally-launched app and the user has unsaved state — `mac_stop` will refuse, but the call is wasted." + mutateHint, [:]),
            tool("mac_screenshot", "PNG screenshot of the running Mac app's largest on-screen window via ScreenCaptureKit." + readHint + " Returns a temp file path.", [:]),
            tool("mac_ax_tree", "Walk the AX tree of the running Mac app's frontmost window. Returns a JSON-friendly nested structure with role/title/label/value/id/frame/children." + readHint + " Common batch: mac_screenshot + mac_ax_tree to fully understand the running app's state.", [
                "maxDepth": ["type": "integer", "description": "Maximum recursion depth (default 5)"],
            ]),
            tool("mac_click", "Click an AX element matching `query` (case-insensitive substring against title/label/role/identifier/value)." + mutateHint, [
                "query": ["type": "string", "description": "Search string"],
            ], required: ["query"]),
            tool("mac_type", "Type text into the focused element, or into the element matched by `query`." + mutateHint, [
                "text": ["type": "string", "description": "Text to enter (replaces current value)"],
                "query": ["type": "string", "description": "Optional query to focus before typing; if omitted, types into currently-focused element"],
            ], required: ["text"]),
            tool("mac_console", "Return buffered stdout/stderr lines from the running Mac app." + readHint, [
                "limit": ["type": "integer", "description": "Max lines to return (default 200)"],
                "stream": ["type": "string", "enum": ["stdout", "stderr"], "description": "Filter by stream; default both"],
            ]),
            tool("mac_clear_console", "Drop all buffered console lines for the running Mac app." + mutateHint, [:]),
            tool("mac_double_click", "Double-click an AX element matching `query` (case-insensitive substring against title/label/role/identifier/value). CGEvent-driven — warps cursor, posts two click events, restores cursor." + mutateHint, [
                "query": ["type": "string", "description": "Substring to match against element title/label/role/id/value"],
            ], required: ["query"]),
            tool("mac_right_click", "Right-click an AX element matching `query` to surface its context menu." + mutateHint, [
                "query": ["type": "string"],
            ], required: ["query"]),
            tool("mac_hover", "Hover the cursor over an AX element matching `query` for `duration` seconds, then restore. Lets tooltips and on-hover menus surface." + mutateHint, [
                "query": ["type": "string"],
                "duration": ["type": "number", "description": "Hold time in seconds (default 1.0)"],
            ], required: ["query"]),
            tool("mac_scroll", "Scroll a direction in the focused window (or in the element matching `query` if given). Direction: up/down/left/right." + mutateHint, [
                "query": ["type": "string", "description": "Optional element to scroll within"],
                "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                "amount": ["type": "number", "description": "Scroll magnitude in points (default 100)"],
            ], required: ["direction"]),
            tool("mac_drag", "Drag from one AX element to another. CGEvent: mouseDown at `fromQuery`, intermediate moves over `duration`, mouseUp at `toQuery`." + mutateHint, [
                "fromQuery": ["type": "string"],
                "toQuery": ["type": "string"],
                "duration": ["type": "number", "description": "Drag duration in seconds (default 0.5)"],
            ], required: ["fromQuery", "toQuery"]),
            tool("mac_focus", "Set AX focus on the element matching `query` (kAXFocusedAttribute = true). Useful before sending keys to a specific text field." + mutateHint, [
                "query": ["type": "string"],
            ], required: ["query"]),
            tool("mac_key", "Send a keyboard chord to the focused responder. Format: 'cmd+s', 'shift+cmd+t', 'escape', 'return', 'f12'. Modifiers: cmd/ctrl/alt/option/shift." + mutateHint, [
                "keys": ["type": "string", "description": "Chord like 'cmd+s' or single key like 'return'"],
            ], required: ["keys"]),
            tool("mac_press_return", "Press the Return key in the focused responder. Convenience for the most common form-submit / dialog-accept case." + mutateHint, [:]),
            tool("mac_find",
                "Find ALL AX elements matching `query` (case-insensitive substring against role/title/label/id/value). Returns array of matches with role/title/label/id/value/frame in document order. Useful when you need to pick a specific match among many or count them." + readHint, [
                "query": ["type": "string"],
            ], required: ["query"]),
            tool("mac_wait_for",
                "Poll the AX tree every ~150ms until an element matching `query` appears, or until `timeout` seconds elapse. Throws if not found in time. Default timeout 5s. Use after a click/launch that triggers async UI rendering." + readHint, [
                "query": ["type": "string"],
                "timeout": ["type": "number", "description": "Seconds to wait (default 5.0)"],
            ], required: ["query"]),
            tool("mac_list_interactive",
                "List interactive AX elements (button/textField/textArea/link/popUpButton/checkBox/radioButton/menuItem/tabGroup/slider/scrollBar) in the running app. Optional `role` filter narrows further (e.g. 'AXButton'). Cheaper than mac_ax_tree when you only need to know what's clickable/typeable." + readHint, [
                "role": ["type": "string", "description": "Optional AX role filter, e.g. 'AXButton'"],
            ]),
            tool("mac_get_element",
                "Get full structured info for one AX element matching `query` — role, roleDescription, title, label, value, id, help, frame, enabled, focused, childrenCount. Read-only inspection (does not click/focus/mutate). Use before mac_click to verify the right element matches." + readHint, [
                "query": ["type": "string"],
            ], required: ["query"]),
            tool("mac_get_content",
                "Concatenate visible text from the focused window's AX tree (title + value + description per node, newline-separated lines). Lighter than mac_ax_tree when you only need 'what does the screen say', not the full structured tree." + readHint, [:]),
            // ===== Native App tools =====
            // Use these ONLY when the session is bound to an already-running
            // macOS app via Target.nativeApp(bundleId:). Tool names prefixed
            // `native_` to avoid colliding with Chrome's surface (and the
            // mac_* surface, which builds + spawns its own process). Mirrors
            // mac_*'s read+write verbs without the build/run/stop trio —
            // app lifecycle is the user's, not ours.
            tool("native_screenshot",
                 "PNG screenshot of the bound native app's largest on-screen window via ScreenCaptureKit." + readHint + " Returns a temp file path.", [:]),
            tool("native_ax_tree",
                 "Walk the AX tree of the bound app's frontmost window. JSON-friendly nested structure with role/title/label/value/id/frame/children." + readHint + " Common batch: native_screenshot + native_ax_tree to fully understand the app's state.", [
                "maxDepth": ["type": "integer", "description": "Maximum recursion depth (default 5)"],
            ]),
            tool("native_click",
                 "Click an AX element matching `query` (case-insensitive substring against title/label/role/identifier/value). Falls back to a synthesized CGEvent click at the element's center if AXPress is a no-op (covers Electron-backed surfaces)." + mutateHint, [
                "query": ["type": "string"],
            ], required: ["query"]),
            tool("native_double_click",
                 "Double-click an AX element matching `query`. CGEvent-driven — warps cursor, posts two click events with the OS click-state field set, restores cursor." + mutateHint, [
                "query": ["type": "string"],
            ], required: ["query"]),
            tool("native_right_click",
                 "Right-click an AX element matching `query` to surface its context menu. CGEvent-driven for uniform behavior across responders." + mutateHint, [
                "query": ["type": "string"],
            ], required: ["query"]),
            tool("native_hover",
                 "Hover the cursor over an AX element matching `query` for `duration` seconds, then restore. Lets tooltips and on-hover menus surface." + mutateHint, [
                "query": ["type": "string"],
                "duration": ["type": "number", "description": "Hold time in seconds (default 1.0)"],
            ], required: ["query"]),
            tool("native_type",
                 "Type text into the focused element, or into the element matched by `query`. AX setValue — reliable for AppKit text fields; Electron text inputs may need native_focus + native_key sequences instead." + mutateHint, [
                "text": ["type": "string", "description": "Text to enter (replaces current value)"],
                "query": ["type": "string", "description": "Optional query to focus before typing; if omitted, types into currently-focused element"],
            ], required: ["text"]),
            tool("native_focus",
                 "Set AX focus on the element matching `query` (kAXFocusedAttribute = true). Useful before sending keys to a specific text field." + mutateHint, [
                "query": ["type": "string"],
            ], required: ["query"]),
            tool("native_scroll",
                 "Scroll a direction in the bound app's focused window (or in the element matching `query` if given). Direction: up/down/left/right." + mutateHint, [
                "query": ["type": "string", "description": "Optional element to scroll within"],
                "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                "amount": ["type": "number", "description": "Scroll magnitude in points (default 100)"],
            ], required: ["direction"]),
            tool("native_key",
                 "Send a keyboard chord to the bound app. Format: 'cmd+s', 'shift+cmd+t', 'escape', 'return', 'f12'. Modifiers: cmd/ctrl/alt/option/shift. Activates the bound app first so the chord routes to its key window." + mutateHint, [
                "keys": ["type": "string", "description": "Chord like 'cmd+s' or single key like 'return'"],
            ], required: ["keys"]),
            tool("native_press_return",
                 "Press the Return key. Convenience for the most common form-submit / dialog-accept case." + mutateHint, [:]),
            tool("native_find",
                 "Find ALL AX elements matching `query` (case-insensitive substring against role/title/label/id/value). Returns array in document order with role/title/label/id/value/frame. Useful when you need to count matches or pick by index." + readHint, [
                "query": ["type": "string"],
            ], required: ["query"]),
            tool("native_wait_for",
                 "Poll the AX tree every ~150ms until an element matching `query` appears, or until `timeout` seconds elapse. Throws if not found in time. Default timeout 5s. Use after a click/sendkey that triggers async UI rendering." + readHint, [
                "query": ["type": "string"],
                "timeout": ["type": "number", "description": "Seconds to wait (default 5.0)"],
            ], required: ["query"]),
            tool("native_list_interactive",
                 "List interactive AX elements (button/textField/textArea/link/popUpButton/checkBox/radioButton/menuItem/tabGroup/slider/scrollBar) in the bound app. Optional `role` filter narrows further (e.g. 'AXButton')." + readHint, [
                "role": ["type": "string", "description": "Optional AX role filter, e.g. 'AXButton'"],
            ]),
            tool("native_get_element",
                 "Get full structured info for one AX element matching `query` — role/roleDescription/title/label/value/id/help/frame/enabled/focused/childrenCount. Read-only inspection. Use before native_click to verify the right element matches." + readHint, [
                "query": ["type": "string"],
            ], required: ["query"]),
            tool("native_get_content",
                 "Concatenate visible text from the focused window's AX tree (title + value + description per node, newline-separated). Lighter than native_ax_tree when you only need 'what does the screen say'." + readHint, [:]),

            // ----- iOS Simulator (Phase 5.2 first slice; no tap/swipe yet — needs idb) -----
            tool("sim_screenshot", "PNG screenshot of the bound iOS Simulator's current screen via `simctl io ... screenshot`." + readHint + " Returns a temp file path.", [:]),
            tool("sim_state", "Current state (Booted/Shutdown/etc) + name + device type for the bound simulator." + readHint, [:]),
            tool("sim_launch", "Launch an app inside the simulator by bundle id." + mutateHint, [
                "bundleId": ["type": "string", "description": "Bundle id, e.g. com.apple.Preferences"],
                "args": ["type": "array", "items": ["type": "string"], "description": "Optional launch args"],
            ], required: ["bundleId"]),
            tool("sim_terminate", "Force-quit a running app by bundle id." + mutateHint, [
                "bundleId": ["type": "string"],
            ], required: ["bundleId"]),
            tool("sim_openurl", "Open a URL in the simulator (Safari for http(s), other apps for custom schemes)." + navHint, [
                "url": ["type": "string"],
            ], required: ["url"]),
            tool("sim_install", "Install a host-side .app bundle into the simulator." + mutateHint, [
                "appPath": ["type": "string", "description": "Absolute path to the .app directory on the host"],
            ], required: ["appPath"]),
            tool("sim_uninstall", "Uninstall an app by bundle id." + mutateHint, [
                "bundleId": ["type": "string"],
            ], required: ["bundleId"]),
            tool("sim_set_appearance", "Set system appearance to 'light' or 'dark' (iOS 17+)." + mutateHint, [
                "mode": ["type": "string", "enum": ["light", "dark"]],
            ], required: ["mode"]),
            tool("sim_push", "Send a push notification payload to a bundle id." + mutateHint, [
                "bundleId": ["type": "string"],
                "payloadJson": ["type": "string", "description": "Stringified JSON payload (alert/sound/badge or aps wrapper)"],
            ], required: ["bundleId", "payloadJson"]),
            // ----- iOS Simulator gestures (require Facebook idb) -----
            // Coords: prefer host-screen `x`/`y` (top-left CG, what you'd
            // read off a screenshot). Optional `vpX`/`vpY` short-circuits
            // translation when caller already has logical viewport coords.
            // If both are present, vpX/vpY wins. Errors clearly when idb
            // isn't installed — no silent no-ops.
            tool("sim_tap",
                 "Single tap on the bound iOS Simulator. Coords are host-screen (top-left CG, matches sim_screenshot output). Translates internally to the simulator's logical viewport." + mutateHint, [
                "x": ["type": "number", "description": "Host-screen X (top-left CG). Use a screenshot to pick coords."],
                "y": ["type": "number", "description": "Host-screen Y (top-left CG)."],
                "vpX": ["type": "number", "description": "Optional: simulator-viewport X (logical pt). Overrides x if set."],
                "vpY": ["type": "number", "description": "Optional: simulator-viewport Y (logical pt). Overrides y if set."],
            ], required: ["x", "y"]),
            tool("sim_double_tap",
                 "Double-tap on the bound simulator (two taps ~130ms apart). Same coord conventions as sim_tap." + mutateHint, [
                "x": ["type": "number"],
                "y": ["type": "number"],
                "vpX": ["type": "number"],
                "vpY": ["type": "number"],
            ], required: ["x", "y"]),
            tool("sim_long_press",
                 "Long-press on the bound simulator. Same coord conventions as sim_tap." + mutateHint, [
                "x": ["type": "number"],
                "y": ["type": "number"],
                "vpX": ["type": "number"],
                "vpY": ["type": "number"],
                "duration": ["type": "number", "description": "Press duration in seconds (default 0.8)"],
            ], required: ["x", "y"]),
            tool("sim_swipe",
                 "Swipe from one point to another on the bound simulator (fast). For slow drags use sim_drag." + mutateHint, [
                "fromX": ["type": "number"],
                "fromY": ["type": "number"],
                "toX": ["type": "number"],
                "toY": ["type": "number"],
                "fromVpX": ["type": "number", "description": "Optional viewport-coord override for fromX"],
                "fromVpY": ["type": "number", "description": "Optional viewport-coord override for fromY"],
                "toVpX": ["type": "number", "description": "Optional viewport-coord override for toX"],
                "toVpY": ["type": "number", "description": "Optional viewport-coord override for toY"],
                "duration": ["type": "number", "description": "Gesture duration seconds (default 0.25)"],
            ], required: ["fromX", "fromY", "toX", "toY"]),
            tool("sim_drag",
                 "Drag from one point to another on the bound simulator (slow, default 0.5s). Like sim_swipe but with a longer hold so iOS treats it as a drag rather than a flick." + mutateHint, [
                "fromX": ["type": "number"],
                "fromY": ["type": "number"],
                "toX": ["type": "number"],
                "toY": ["type": "number"],
                "fromVpX": ["type": "number"],
                "fromVpY": ["type": "number"],
                "toVpX": ["type": "number"],
                "toVpY": ["type": "number"],
                "duration": ["type": "number", "description": "Gesture duration seconds (default 0.5)"],
            ], required: ["fromX", "fromY", "toX", "toY"]),
            tool("sim_pinch",
                 "Pinch gesture centered on a point. scale > 1 = pinch-out (zoom in), scale < 1 = pinch-in (zoom out). Uses two simultaneous swipes via idb." + mutateHint, [
                "centerX": ["type": "number"],
                "centerY": ["type": "number"],
                "centerVpX": ["type": "number"],
                "centerVpY": ["type": "number"],
                "scale": ["type": "number", "description": "Final scale relative to start (e.g. 2.0 zoom-in, 0.5 zoom-out)"],
                "duration": ["type": "number", "description": "Gesture duration seconds (default 0.4)"],
            ], required: ["centerX", "centerY", "scale"]),
            tool("sim_button",
                 "Press a hardware button on the simulator. Names: home, lock, side-button, siri, apple-pay. Use 'home' twice in quick succession (or sim_button name=home2x) for the iOS app switcher." + mutateHint, [
                "name": ["type": "string", "enum": ["home", "lock", "side-button", "siri", "apple-pay", "home2x"]],
            ], required: ["name"]),
            tool("sim_text",
                 "Type literal text into the focused responder. Tap a text field first to focus it." + mutateHint, [
                "text": ["type": "string", "description": "Text to type"],
            ], required: ["text"]),
            tool("sim_key",
                 "Send a single HID keycode to the focused responder. Common: 40=Return, 42=Backspace, 41=Escape, 43=Tab. See USB HID Usage Table." + mutateHint, [
                "keycode": ["type": "integer", "description": "HID usage code"],
            ], required: ["keycode"]),
            tool("sim_keys",
                 "Send a sequence of HID keycodes." + mutateHint, [
                "keycodes": ["type": "array", "items": ["type": "integer"], "description": "Array of HID keycodes"],
            ], required: ["keycodes"]),
            tool("sim_find_element",
                 "Find ALL elements in the simulator's iOS AX tree matching `query` (substring against label/value/type/title/help). Requires idb. Returns array of nodes with type/AXLabel/AXValue/frame/etc." + readHint, [
                "query": ["type": "string"],
            ], required: ["query"]),
            tool("sim_wait_for",
                 "Poll until an element matching `query` appears in the iOS AX tree or `timeout` elapses. Default 5s." + readHint, [
                "query": ["type": "string"],
                "timeout": ["type": "number", "description": "Seconds to wait (default 5.0)"],
            ], required: ["query"]),
            tool("sim_list_interactive",
                 "List interactive elements (Button/TextField/Switch/Cell/MenuItem/Tab/Slider/Link) in the simulator. Optional `type` filter narrows further." + readHint, [
                "type": ["type": "string", "description": "Optional iOS UI type filter (e.g. 'Button')"],
            ]),
            tool("sim_get_element",
                 "Get full structured info for the first element matching `query` from the iOS AX tree. Read-only inspection." + readHint, [
                "query": ["type": "string"],
            ], required: ["query"]),
        ]
    }

    private static func tool(
        _ name: String,
        _ description: String,
        _ properties: [String: Any],
        required: [String] = []
    ) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return [
            "name": name,
            "description": description,
            "inputSchema": schema,
        ]
    }
}
