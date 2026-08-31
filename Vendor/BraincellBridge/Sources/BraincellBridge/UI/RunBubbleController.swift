import AppKit
import SwiftUI

/// Floating "▶ Run <cmd>" pill anchored to the right edge of a bound terminal
/// window when the project has a runnable dev command and the server isn't
/// already listening. Replaces the menu-bar Run nag — the affordance now
/// lives on the actual terminal it acts upon.
///
/// Architectural twin of `BindBubbleController`: the right-edge real estate
/// of a terminal window cycles through `+` (unbound, bindable) → `▶ Run`
/// (bound, has command, server not running) → nothing (server running). One
/// predictable spot, one transition at a time.
@MainActor
final class RunBubbleController {
    var onRun: ((_ sessionId: String, _ command: String) -> Void)?
    var onDismiss: ((_ sessionId: String) -> Void)?

    struct Target: Equatable, Hashable {
        let sessionId: String
        let project: String
        let command: String
        let windowId: CGWindowID
    }

    private var panel: NSPanel?
    private var hostingController: NSHostingController<RunBubbleView>?
    private var pollTimer: Timer?
    private var targets: [String: Target] = [:]
    private var positions: [String: CGPoint] = [:]
    private var lastRenderedKey: String = ""

    func update(targets newTargets: [Target]) {
        let newDict = Dictionary(uniqueKeysWithValues: newTargets.map { ($0.sessionId, $0) })
        if newDict.keys == targets.keys && newDict == targets { return }
        targets = newDict
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
        stopTimer()
        if let hoverMonitor { NSEvent.removeMonitor(hoverMonitor) }
        hoverMonitor = nil
        panel?.close()
        panel = nil
        hostingController = nil
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

        let host = NSHostingController(rootView: RunBubbleView(
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
    /// Bigger hit radius than the bind dot — the pill is wider, hover should
    /// engage anywhere on it.
    private func updateHoverGate() {
        guard let panel = panel, !targets.isEmpty else { return }
        let mouse = NSEvent.mouseLocation
        var anyHovered = false
        for (_, pos) in positions {
            // Pill is roughly 180×30 pt centered on pos. Generous hit zone.
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

    // MARK: - Polling

    /// Same single-pass CGWindowList resolution as the bind bubble, with the
    /// same anchor-occlusion guard — pill suppressed when its anchor point is
    /// covered by a window above it in z-order.
    private func poll() {
        if targets.isEmpty { return }
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return
        }
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
            // Window must be in the snapshot to anchor to. If the terminal
            // is on a different Space / minimized, its windowId won't be in
            // `ordered` and the pill auto-hides for that target.
            guard let zIdx = ordered.firstIndex(where: { $0.wid == target.windowId }) else { continue }
            let frame = ordered[zIdx].frame
            // No anchor-occlusion check here — the Run pill is a persistent,
            // user-actionable nag tied to a specific bound session. Even if
            // the terminal is partially covered by another window the user
            // wants to see the pill (and click it without bringing the
            // terminal forward, since paste injection AX-raises the
            // specific window). A focus change should NOT make it disappear.
            // Use zIdx for clarity even though we don't gate on it.
            _ = zIdx
            // Inside the content area, just below the title bar. macOS
            // Terminal / iTerm / Ghostty title bars are typically 22–32pt;
            // 42pt down lands the pill comfortably in the first content
            // rows for any of them. Pill height is ~28pt so vertical center
            // at 42 spans ~28–56 in window coords — fully in content.
            let pillHalfWidth: CGFloat = 90
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
            let cmd = targets[sid]?.command ?? ""
            return "\(sid):\(cmd):\(Int(p.x.rounded())):\(Int(p.y.rounded()))"
        }.joined(separator: "|")
        if key == lastRenderedKey { return }
        lastRenderedKey = key

        let bubbles = sortedSids.compactMap { sid -> RunBubbleView.BubbleData? in
            guard let pos = positions[sid], let t = targets[sid] else { return nil }
            return RunBubbleView.BubbleData(
                sessionId: sid,
                position: pos,
                command: t.command,
                project: t.project
            )
        }
        hostingController?.rootView = RunBubbleView(
            bubbles: bubbles,
            onTap: { [weak self] sid in
                guard let target = self?.targets[sid] else { return }
                self?.onRun?(sid, target.command)
            },
            onDismiss: { [weak self] sid in
                self?.onDismiss?(sid)
            }
        )
    }
}

// MARK: - SwiftUI

private struct RunBubbleView: View {
    struct BubbleData: Identifiable {
        let sessionId: String
        let position: CGPoint
        let command: String
        let project: String
        var id: String { sessionId }
    }
    let bubbles: [BubbleData]
    let onTap: (String) -> Void
    let onDismiss: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var fillColor: Color { Color(red: 0.231, green: 0.510, blue: 0.965) }

    var body: some View {
        GeometryReader { geo in
            ForEach(bubbles) { bubble in
                HStack(spacing: 0) {
                    // Run target — play + command. Click to launch.
                    Button {
                        onTap(bubble.sessionId)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text(bubble.command)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .padding(.leading, 11)
                        .padding(.trailing, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Subtle vertical hairline divider between run + dismiss.
                    Rectangle()
                        .fill(Color.white.opacity(0.20))
                        .frame(width: 0.5, height: 14)

                    // Dismiss target — × on the right. Click to suppress.
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
                    .help("Dismiss — server already running")
                }
                .background(Capsule(style: .continuous).fill(fillColor))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.5)
                )
                .shadow(color: fillColor.opacity(0.40), radius: 8, y: 2)
                .position(x: bubble.position.x, y: geo.size.height - bubble.position.y)
            }
        }
    }
}
