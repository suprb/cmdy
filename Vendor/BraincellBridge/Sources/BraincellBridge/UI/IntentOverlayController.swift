import AppKit
import SwiftUI

/// Renders Claude's *intent* directly on top of the bound Chrome window:
/// a thin pulsing strip across the top edge and a labeled ribbon centered
/// just below the title bar. Visible the entire time a tool is in flight,
/// flashes green/red on success/error, fades after ~600ms.
///
/// First slice of the perceived-latency strategy (see
/// project_bridge_perceived_latency.md): collapses the user's "I typed →
/// nothing happened → Chrome moved" attention bounce by giving Chrome itself
/// continuous visible activity for the duration of every tool call. Same
/// MCP wall-clock latency, totally different feel.
///
/// Architectural twin of BindBubble/Run/Inspector controllers — single
/// borderless NSPanel over the union of all screens, 30Hz CGWindowList
/// poll, anchored per-session to the bound Chrome window. Always
/// click-through; this overlay never takes input.
@MainActor
final class IntentOverlayController {
    enum Phase: String, Equatable {
        case composing  // Claude is streaming the tool_use block (no MCP call yet)
        case active     // tool is executing (MCP dispatch in flight)
        case success    // just finished, fading
        case error      // failed, fading
    }

    struct Intent: Equatable {
        let sessionId: String
        var label: String
        let startedAt: Date
        var phase: Phase
        var endedAt: Date?
        /// Tool name from composeStart, kept across phase transitions so we
        /// can re-resolve the label as more args arrive without losing context.
        var toolName: String?
    }

    /// AppDelegate wires this to look up the Chrome PID for a session via
    /// `appState.chromeAdapters[sid]?.chromeProcessPid`. Closure-injection
    /// keeps the controller decoupled from BridgeAppState.
    var chromeProcessPid: ((String) -> pid_t?)?

    private var intents: [String: Intent] = [:]
    private var positions: [String: PositionInfo] = [:]
    private var panel: NSPanel?
    private var hostingController: NSHostingController<IntentOverlayView>?
    private var pollTimer: Timer?
    private var lastRenderedKey: String = ""

    private struct PositionInfo: Equatable {
        let frame: CGRect       // CG coords (top-left origin)
        let screenHeight: CGFloat
    }

    /// Begin showing intent for `sessionId` in active state (MCP dispatch).
    /// If a composing intent already exists for this sessionId (from the
    /// stream proxy), transition phase rather than replacing — Claude
    /// finishes streaming the tool_use block, then dispatches; this is the
    /// transition point.
    func start(sessionId: String, label: String) {
        if var intent = intents[sessionId], intent.phase == .composing {
            intent.phase = .active
            intent.label = label
            intents[sessionId] = intent
            lastRenderedKey = ""
            renderView()
            return
        }
        intents[sessionId] = Intent(
            sessionId: sessionId,
            label: label,
            startedAt: Date(),
            phase: .active,
            endedAt: nil,
            toolName: nil
        )
        ensurePanel()
        ensureTimer()
        lastRenderedKey = ""
        poll()
    }

    /// Begin showing intent in `composing` phase — Claude has just started
    /// streaming a tool_use block, but the actual MCP dispatch hasn't fired
    /// yet. Renders gray + low-opacity so the user can distinguish "Claude
    /// is thinking about doing X" from "X is happening." Transitions to
    /// `active` when `start(sessionId:label:)` is later called from the
    /// router.
    ///
    /// Driven by `StreamProxyServer.onEvent` on `composeStart`.
    func startComposing(sessionId: String, toolName: String) {
        intents[sessionId] = Intent(
            sessionId: sessionId,
            label: "composing \(toolName)…",
            startedAt: Date(),
            phase: .composing,
            endedAt: nil,
            toolName: toolName
        )
        ensurePanel()
        ensureTimer()
        lastRenderedKey = ""
        poll()
    }

    /// Refine the label of a composing intent — called as more of the
    /// tool_use args arrive (composeDelta) or when the full args are
    /// reconstructed (composeStop). No-op if the intent isn't in
    /// composing phase.
    func updateComposing(sessionId: String, label: String) {
        guard var intent = intents[sessionId], intent.phase == .composing else { return }
        intent.label = label
        intents[sessionId] = intent
        lastRenderedKey = ""
        renderView()
    }

    /// Mark the intent as completed. Phase flips to .success or .error and
    /// the overlay fades over ~600ms before being removed.
    func end(sessionId: String, success: Bool, errorLabel: String? = nil) {
        guard var intent = intents[sessionId] else { return }
        intent.phase = success ? .success : .error
        intent.endedAt = Date()
        if !success, let err = errorLabel, !err.isEmpty {
            intent.label = err
        }
        intents[sessionId] = intent
        lastRenderedKey = ""
        renderView()

        // Auto-clear after fade.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self?.intents.removeValue(forKey: sessionId)
            self?.positions.removeValue(forKey: sessionId)
            self?.lastRenderedKey = ""
            if self?.intents.isEmpty == true {
                self?.stopTimer()
                self?.panel?.orderOut(nil)
            } else {
                self?.poll()
            }
        }
    }

    func hide() {
        intents.removeAll()
        positions.removeAll()
        stopTimer()
        lastRenderedKey = ""
        panel?.orderOut(nil)
    }

    // MARK: - Label builder

    /// Build a user-readable label from tool name + args. Centralizes the
    /// verb-phrase mapping so all tool calls render consistently.
    static func label(for tool: String, args: [String: Any]) -> String {
        func sel(_ a: [String: Any]) -> String { a["selector"] as? String ?? "?" }
        switch tool {
        case "navigate":
            let url = (args["url"] as? String) ?? ""
            if let comps = URLComponents(string: url), let host = comps.host {
                return "navigate → \(host)"
            }
            return "navigate"
        case "reload":           return "reload"
        case "back":             return "back"
        case "forward":          return "forward"
        case "click":            return "click \(sel(args))"
        case "double_click":     return "double-click \(sel(args))"
        case "right_click":      return "right-click \(sel(args))"
        case "hover":            return "hover \(sel(args))"
        case "focus":            return "focus \(sel(args))"
        case "type":
            let text = (args["text"] as? String) ?? ""
            let preview = text.count > 18 ? String(text.prefix(18)) + "…" : text
            return "type \"\(preview)\" → \(sel(args))"
        case "scroll":           return "scroll \(args["direction"] as? String ?? "")"
        case "press_key":        return "press \(args["key"] as? String ?? "")"
        case "drag_drop":        return "drag → drop"
        case "screenshot":       return "screenshot"
        case "find":             return "find \"\(args["query"] as? String ?? "")\""
        case "wait_for":         return "wait for \(sel(args))"
        case "list_interactive": return "list interactive"
        case "get_element":      return "get \(sel(args))"
        case "get_content":      return "read content"
        case "get_title":        return "read title"
        case "get_url":          return "read URL"
        case "get_console":      return "read console"
        case "clear_console":    return "clear console"
        case "get_forms":        return "list forms"
        case "fill_form":        return "fill form"
        case "submit_form":      return "submit form"
        case "select_option":    return "select option"
        case "set_checkbox":     return "set checkbox"
        case "get_network":      return "read network"
        case "clear_network":    return "clear network"
        case "get_failed_requests": return "failed requests"
        case "execute_js":       return "run JS"
        default:                 return tool
        }
    }

    // MARK: - Panel

    private func ensurePanel() {
        if let p = panel { p.orderFrontRegardless(); return }
        let total = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        let p = NSPanel(
            contentRect: total,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.ignoresMouseEvents = true   // pure visual, never grabs hits

        let host = NSHostingController(rootView: IntentOverlayView(items: []))
        host.view.frame = total
        host.view.autoresizingMask = [.width, .height]
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = host.view
        panel = p
        hostingController = host
        p.orderFrontRegardless()
    }

    private func ensureTimer() {
        if pollTimer != nil { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
    }
    private func stopTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Polling

    /// Resolve each active intent's anchor by looking up the Chrome PID and
    /// finding its frontmost window in CGWindowList. One window-list query
    /// per tick regardless of intent count.
    private func poll() {
        if intents.isEmpty { return }
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return }

        // Frontmost layer-0 window per pid (CGWindowList is front-to-back).
        var byPid: [pid_t: CGRect] = [:]
        for w in list {
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            let owner = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            if byPid[owner] != nil { continue }
            if let bounds = w[kCGWindowBounds as String] as? [String: Any],
               let x = bounds["X"] as? CGFloat,
               let y = bounds["Y"] as? CGFloat,
               let width = bounds["Width"] as? CGFloat,
               let height = bounds["Height"] as? CGFloat,
               width > 200, height > 100 {
                byPid[owner] = CGRect(x: x, y: y, width: width, height: height)
            }
        }

        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        var newPositions: [String: PositionInfo] = [:]
        for sid in intents.keys {
            guard let pid = chromeProcessPid?(sid), let frame = byPid[pid] else { continue }
            newPositions[sid] = PositionInfo(frame: frame, screenHeight: screenHeight)
        }
        positions = newPositions
        renderView()
    }

    // MARK: - Render

    private func renderView() {
        let now = Date()
        let items: [IntentOverlayView.Item] = intents.compactMap { sid, intent -> IntentOverlayView.Item? in
            guard let pos = positions[sid] else { return nil }
            // Top-edge strip: full window width, 2pt thick, sitting INSIDE the
            // top of the chrome (1pt down so it's not clipped by the window
            // frame on retina).
            let cgStripCenter = CGPoint(x: pos.frame.midX, y: pos.frame.minY + 1)
            // Ribbon: centered horizontally, 38pt below the window's top edge —
            // lands just below the title bar / URL bar lip on Chrome.
            let cgRibbonCenter = CGPoint(x: pos.frame.midX, y: pos.frame.minY + 38)
            let stripPos = CGPoint(x: cgStripCenter.x, y: pos.screenHeight - cgStripCenter.y)
            let ribbonPos = CGPoint(x: cgRibbonCenter.x, y: pos.screenHeight - cgRibbonCenter.y)
            let fade: CGFloat = intent.endedAt.map { ended in
                CGFloat(min(now.timeIntervalSince(ended) / 0.6, 1.0))
            } ?? 0
            return IntentOverlayView.Item(
                id: sid,
                label: intent.label,
                phase: intent.phase,
                startedAt: intent.startedAt,
                fadeProgress: fade,
                stripCenter: stripPos,
                stripWidth: pos.frame.width,
                ribbonCenter: ribbonPos
            )
        }
        // Re-render gate: identity by id+phase+fade-bucket+anchor — we want
        // smooth updates from the TimelineView (animation clock) but not 30Hz
        // SwiftUI recomposition from poll() unless something actually moved.
        let key = items.map { item -> String in
            "\(item.id):\(item.phase.rawValue):\(Int(item.stripCenter.x.rounded())):\(Int(item.stripCenter.y.rounded())):\(Int(item.stripWidth.rounded())):\(Int(item.fadeProgress * 100))"
        }.sorted().joined(separator: "|")
        if key == lastRenderedKey { return }
        lastRenderedKey = key
        hostingController?.rootView = IntentOverlayView(items: items)
    }
}

// MARK: - SwiftUI

private struct IntentOverlayView: View {
    struct Item: Identifiable, Equatable {
        let id: String
        let label: String
        let phase: IntentOverlayController.Phase
        let startedAt: Date
        let fadeProgress: CGFloat
        let stripCenter: CGPoint    // bottom-left coords
        let stripWidth: CGFloat
        let ribbonCenter: CGPoint   // bottom-left coords
    }
    let items: [Item]

    var body: some View {
        GeometryReader { geo in
            ForEach(items) { item in
                let visibility = max(0, 1.0 - item.fadeProgress)
                // Position helpers — bottom-left → top-left flip.
                let stripY = geo.size.height - item.stripCenter.y
                let ribbonY = geo.size.height - item.ribbonCenter.y

                // Edge strip — pulses while active, settles to solid on terminal phase.
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                    let t = context.date.timeIntervalSince(item.startedAt)
                    let pulse: Double = item.phase == .active ? (0.55 + 0.45 * (0.5 + 0.5 * sin(t * 5))) : 1.0
                    Rectangle()
                        .fill(stripColor(for: item.phase))
                        .frame(width: item.stripWidth, height: 2)
                        .opacity(pulse * Double(visibility))
                }
                .frame(width: item.stripWidth, height: 2)
                .position(x: item.stripCenter.x, y: stripY)

                // Intent ribbon — capsule with phase icon + label.
                HStack(spacing: 6) {
                    Image(systemName: phaseIcon(for: item.phase))
                        .font(.system(size: 10, weight: .bold))
                    Text(item.label)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(.white)
                .padding(.leading, 10)
                .padding(.trailing, 11)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous).fill(stripColor(for: item.phase))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(color: stripColor(for: item.phase).opacity(0.40), radius: 7, y: 2)
                .opacity(visibility)
                .position(x: item.ribbonCenter.x, y: ribbonY)
            }
        }
    }

    private func stripColor(for phase: IntentOverlayController.Phase) -> Color {
        switch phase {
        case .composing: return Color.gray.opacity(0.65)                       // pre-MCP, lower-key
        case .active:    return Color(red: 0.231, green: 0.510, blue: 0.965)   // bridge blue
        case .success:   return Color(red: 0.20, green: 0.78, blue: 0.42)
        case .error:     return Color(red: 0.95, green: 0.32, blue: 0.32)
        }
    }
    private func phaseIcon(for phase: IntentOverlayController.Phase) -> String {
        switch phase {
        case .composing: return "ellipsis"
        case .active:    return "circle.dotted"
        case .success:   return "checkmark"
        case .error:     return "exclamationmark.triangle.fill"
        }
    }
}
