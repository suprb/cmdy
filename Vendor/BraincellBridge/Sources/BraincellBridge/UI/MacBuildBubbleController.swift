import AppKit
import SwiftUI

/// Floating "▶ Build & Run" pill anchored to the right edge of a terminal
/// bound to a Mac App project, when the underlying app is NOT currently
/// running. Click → triggers `MacAppAdapter.build()` then `.run()`. Pill
/// auto-hides while the app is running.
///
/// Architectural twin of `RunBubbleController` — same scaffold (panel
/// over union of screens, 30Hz CGWindowList poll, hover-gated click-
/// through, persistent semantics). Differs in:
///   - shows on bound *Mac App* sessions, not Chrome dev-server sessions
///   - clicks fire a single `onBuildAndRun(sessionId)` rather than
///     injecting a shell command
///   - while building/running, label changes to "Building…" / "Running"
///     to give visible feedback that something's happening
@MainActor
final class MacBuildBubbleController {
    enum State: Equatable {
        case idle           // ready to build & run
        case building       // mac_build in flight
        case running        // mac_run completed; pill hidden externally
        case error(String)  // last attempt failed; show red, retry on click
    }

    var onBuildAndRun: ((_ sessionId: String) -> Void)?
    var onDismiss: ((_ sessionId: String) -> Void)?

    struct Target: Equatable, Hashable {
        let sessionId: String
        let project: String
        let windowId: CGWindowID
    }

    private var panel: NSPanel?
    private var hostingController: NSHostingController<MacBuildBubbleView>?
    private var pollTimer: Timer?
    private var targets: [String: Target] = [:]
    private var positions: [String: CGPoint] = [:]
    /// Per-session UI state. Caller (BridgeAppDelegate) flips between
    /// idle / building / error; running causes the target to be removed
    /// from the targets map entirely (pill auto-hides).
    private var states: [String: State] = [:]
    private var lastRenderedKey: String = ""

    func update(targets newTargets: [Target]) {
        let newDict = Dictionary(uniqueKeysWithValues: newTargets.map { ($0.sessionId, $0) })
        if newDict.keys == targets.keys && newDict == targets { return }
        targets = newDict
        // Drop states for sessions no longer in targets.
        states = states.filter { newDict.keys.contains($0.key) }
        if !targets.isEmpty {
            if panel == nil { buildPanel() }
            panel?.orderFrontRegardless()
            ensureTimer()
            lastRenderedKey = ""
            poll()
        } else {
            positions.removeAll()
            renderView()
            stopTimer()
            panel?.orderOut(nil)
        }
    }

    func shutdown() {
        targets.removeAll()
        positions.removeAll()
        states.removeAll()
        stopTimer()
        if let hoverMonitor { NSEvent.removeMonitor(hoverMonitor) }
        hoverMonitor = nil
        panel?.close()
        panel = nil
        hostingController = nil
    }

    /// Set per-session state externally — BridgeAppDelegate flips into
    /// `.building` before kicking the async build, into `.error` on
    /// failure, drops the target on success.
    func setState(_ state: State, for sessionId: String) {
        states[sessionId] = state
        lastRenderedKey = ""
        renderView()
    }

    // MARK: - Panel

    private func buildPanel() {
        let totalFrame = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        let p = NSPanel(
            contentRect: totalFrame,
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
        p.ignoresMouseEvents = true   // global click-through; flipped on hover

        let host = NSHostingController(rootView: MacBuildBubbleView(
            bubbles: [],
            onTap: { _ in },
            onDismiss: { _ in }
        ))
        host.view.frame = totalFrame
        host.view.autoresizingMask = [.width, .height]
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = host.view
        panel = p
        hostingController = host
        p.orderFrontRegardless()
        installHoverGate()
    }

    private var hoverMonitor: Any?
    private func installHoverGate() {
        if hoverMonitor != nil { return }
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateHoverGate() }
        }
    }
    private func updateHoverGate() {
        guard let panel = panel, !targets.isEmpty else { return }
        let mouse = NSEvent.mouseLocation
        var anyHovered = false
        for (_, pos) in positions {
            let dx = mouse.x - pos.x
            let dy = mouse.y - pos.y
            if abs(dx) < 110 && abs(dy) < 22 {
                anyHovered = true
                break
            }
        }
        panel.ignoresMouseEvents = !anyHovered
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

    // MARK: - Polling (mirrors RunBubbleController)

    private func poll() {
        if targets.isEmpty { return }
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        var ordered: [(wid: CGWindowID, frame: CGRect)] = []
        for w in list {
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            let owner = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            if owner == ownPid { continue }
            let wid = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            if let bounds = w[kCGWindowBounds as String] as? [String: Any],
               let x = bounds["X"] as? CGFloat,
               let y = bounds["Y"] as? CGFloat,
               let width = bounds["Width"] as? CGFloat,
               let height = bounds["Height"] as? CGFloat {
                ordered.append((wid, CGRect(x: x, y: y, width: width, height: height)))
            }
        }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        var newPositions: [String: CGPoint] = [:]
        for (sid, target) in targets {
            guard ordered.contains(where: { $0.wid == target.windowId }) else { continue }
            let frame = ordered.first(where: { $0.wid == target.windowId })!.frame
            // Same anchor recipe as RunBubble — pill inside content area,
            // just below the title bar at the right edge. Stack neatly with
            // the Run pill if both somehow apply (shouldn't in practice
            // since binding is one-target-per-session today).
            let pillHalfWidth: CGFloat = 95
            let cgX = frame.maxX - pillHalfWidth + 7
            let cgY = frame.minY + 57
            let pos = CGPoint(x: cgX, y: screenHeight - cgY)
            newPositions[sid] = pos
        }
        positions = newPositions
        renderView()
        updateHoverGate()
    }

    // MARK: - View

    private func renderView() {
        let sortedSids = positions.keys.sorted()
        let key = sortedSids.map { sid -> String in
            let p = positions[sid] ?? .zero
            let st = states[sid] ?? .idle
            return "\(sid):\(stateKey(st)):\(Int(p.x.rounded())):\(Int(p.y.rounded()))"
        }.joined(separator: "|")
        if key == lastRenderedKey { return }
        lastRenderedKey = key

        let bubbles = sortedSids.compactMap { sid -> MacBuildBubbleView.BubbleData? in
            guard let pos = positions[sid], let t = targets[sid] else { return nil }
            return MacBuildBubbleView.BubbleData(
                sessionId: sid,
                position: pos,
                project: t.project,
                state: states[sid] ?? .idle
            )
        }
        hostingController?.rootView = MacBuildBubbleView(
            bubbles: bubbles,
            onTap: { [weak self] sid in
                self?.onBuildAndRun?(sid)
            },
            onDismiss: { [weak self] sid in
                self?.onDismiss?(sid)
            }
        )
    }

    private func stateKey(_ s: State) -> String {
        switch s {
        case .idle: return "idle"
        case .building: return "building"
        case .running: return "running"
        case .error(let msg): return "error:\(msg)"
        }
    }
}

// MARK: - SwiftUI

private struct MacBuildBubbleView: View {
    struct BubbleData: Identifiable {
        let sessionId: String
        let position: CGPoint
        let project: String
        let state: MacBuildBubbleController.State
        var id: String { sessionId }
    }
    let bubbles: [BubbleData]
    let onTap: (String) -> Void
    let onDismiss: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            ForEach(bubbles) { bubble in
                HStack(spacing: 0) {
                    Button {
                        onTap(bubble.sessionId)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: icon(for: bubble.state))
                                .font(.system(size: 9, weight: .bold))
                            Text(label(for: bubble.state))
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .padding(.leading, 11)
                        .padding(.trailing, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(bubble.state == .building)

                    Rectangle()
                        .fill(Color.white.opacity(0.20))
                        .frame(width: 0.5, height: 14)

                    Button {
                        onDismiss(bubble.sessionId)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss — manage build manually")
                }
                .background(Capsule(style: .continuous).fill(fillColor(for: bubble.state)))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.5)
                )
                .shadow(color: fillColor(for: bubble.state).opacity(0.40), radius: 8, y: 2)
                .position(x: bubble.position.x, y: geo.size.height - bubble.position.y)
            }
        }
    }

    // Keep the visual language tight: blue when ready, amber while
    // building, red on error. Hammer icon matches the popover binding
    // badge so the user connects "this terminal is bound to a Mac app
    // project" with this affordance.
    private func icon(for state: MacBuildBubbleController.State) -> String {
        switch state {
        case .idle:     return "hammer.fill"
        case .building: return "hourglass"
        case .running:  return "checkmark.circle.fill"
        case .error:    return "exclamationmark.triangle.fill"
        }
    }
    private func label(for state: MacBuildBubbleController.State) -> String {
        switch state {
        case .idle:     return "Build & Run"
        case .building: return "Building…"
        case .running:  return "Running"
        case .error(let msg): return "Error: \(msg.prefix(40))"
        }
    }
    private func fillColor(for state: MacBuildBubbleController.State) -> Color {
        switch state {
        case .idle:     return Color(red: 0.231, green: 0.510, blue: 0.965)   // bridge blue
        case .building: return Color(red: 0.85,  green: 0.55,  blue: 0.10)    // amber
        case .running:  return Color(red: 0.20,  green: 0.78,  blue: 0.42)    // green
        case .error:    return Color(red: 0.95,  green: 0.32,  blue: 0.32)    // red
        }
    }
}
