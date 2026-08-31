import AppKit
import SwiftUI

/// Floating inspector toggle anchored to the right edge of the bound Chrome
/// window. Mirrors `BindBubbleController` in shape (transparent overlay panel,
/// AX-resolved focused window, hover-gated click-through, custom HUD tooltip).
///
/// Visible when:
///   - Frontmost app is Chrome
///   - Its focused window's CGWindowID matches one of our bound Chrome adapters
/// Click → flips inspector enabled/disabled for that session.
@MainActor
final class InspectorBubbleController {
    /// Click handler — receives the bound sessionId and the new desired state.
    var onToggle: ((_ sessionId: String, _ enabled: Bool) -> Void)?

    struct Target: Equatable, Hashable {
        let sessionId: String
        let project: String
        let windowId: CGWindowID
        let enabled: Bool
    }

    private var panel: NSPanel?
    private var hostingController: NSHostingController<InspectorView>?
    private var pollTimer: Timer?
    private var targets: [String: Target] = [:]
    private var positions: [String: CGPoint] = [:]
    private var lastRenderedKey: String = ""

    // Tooltip
    private var tooltipPanel: NSPanel?
    private var tooltipLabel: NSTextField?
    private var tooltipShowWorkItem: DispatchWorkItem?
    private var tooltipAnchor: CGPoint = .zero
    private let tooltipDelay: TimeInterval = 0.05

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
            cancelTooltip()
        }
    }

    func shutdown() {
        targets.removeAll()
        positions.removeAll()
        stopTimer()
        cancelTooltip()
        if let hoverMonitor { NSEvent.removeMonitor(hoverMonitor) }
        hoverMonitor = nil
        panel?.close()
        panel = nil
        hostingController = nil
        tooltipPanel?.close()
        tooltipPanel = nil
        tooltipLabel = nil
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
        p.ignoresMouseEvents = true

        let host = NSHostingController(rootView: InspectorView(
            bubbles: [],
            onTap: { _, _ in }
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
        var hovered: (sessionId: String, position: CGPoint)? = nil
        for (sid, pos) in positions {
            let dx = mouse.x - pos.x
            let dy = mouse.y - pos.y
            if dx * dx + dy * dy < 18 * 18 {   // 18pt hit radius matches 26pt dot
                hovered = (sid, pos)
                break
            }
        }
        panel.ignoresMouseEvents = (hovered == nil)
        if let h = hovered, let target = targets[h.sessionId] {
            let label = target.enabled
                ? "Inspector ON — click to disable"
                : "Click to enable Inspector"
            scheduleTooltip(text: label, at: h.position)
        } else {
            cancelTooltip()
        }
    }

    // MARK: - Tooltip

    private func scheduleTooltip(text: String, at position: CGPoint) {
        tooltipAnchor = position
        if tooltipPanel?.isVisible == true {
            tooltipLabel?.stringValue = text
            sizeTooltipToFit()
            positionTooltipNearBubble()
            return
        }
        // If a work item is already pending, let it fire — don't cancel +
        // reschedule on every hover-gate tick (poll runs at 30Hz, so the
        // 50ms delay would never complete).
        if tooltipShowWorkItem != nil { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.showTooltip(text: text) }
        }
        tooltipShowWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + tooltipDelay, execute: work)
    }

    private func cancelTooltip() {
        tooltipShowWorkItem?.cancel()
        tooltipShowWorkItem = nil
        tooltipPanel?.orderOut(nil)
    }

    private func showTooltip(text: String) {
        tooltipShowWorkItem = nil
        if tooltipPanel == nil { buildTooltipPanel() }
        tooltipLabel?.stringValue = text
        sizeTooltipToFit()
        positionTooltipNearBubble()
        tooltipPanel?.orderFrontRegardless()
    }

    private func buildTooltipPanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 24),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.ignoresMouseEvents = true

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.separatorColor.cgColor
        bg.translatesAutoresizingMaskIntoConstraints = false

        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: 11, weight: .medium)
        l.textColor = .labelColor
        l.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: p.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        container.addSubview(bg)
        container.addSubview(l)
        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: container.topAnchor),
            bg.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bg.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            l.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            l.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            l.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
        ])
        p.contentView = container
        tooltipPanel = p
        tooltipLabel = l
    }

    private func sizeTooltipToFit() {
        guard let label = tooltipLabel, let panel = tooltipPanel else { return }
        let textSize = label.attributedStringValue.size()
        let w = max(60, ceil(textSize.width) + 16)
        var f = panel.frame
        f.size = NSSize(width: w, height: 24)
        panel.setFrame(f, display: false)
    }

    /// Tooltip sits BELOW the bubble (which lives in the title bar). Going
    /// up would clip the menu bar; going right risks overlap with the
    /// chevron; centred under the bubble works on every monitor size.
    private func positionTooltipNearBubble() {
        guard let panel = tooltipPanel else { return }
        let size = panel.frame.size
        let x = tooltipAnchor.x - size.width / 2
        let y = tooltipAnchor.y - size.height - 14
        panel.setFrameOrigin(NSPoint(x: x, y: y))
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

    /// One CGWindowList snapshot per tick, indexed by ID. Drops bubbles whose
    /// anchor point is occluded by another window above them in z-order — same
    /// pattern as BindBubbleController so we don't draw on top of unrelated
    /// content when the target window is buried.
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
            guard let zIdx = ordered.firstIndex(where: { $0.wid == target.windowId }) else { continue }
            let frame = ordered[zIdx].frame
            let cgAnchor = CGPoint(x: frame.maxX, y: frame.midY)
            var anchorCovered = false
            if zIdx > 0 {
                for i in 0..<zIdx {
                    if ordered[i].frame.contains(cgAnchor) { anchorCovered = true; break }
                }
            }
            if anchorCovered { continue }
            // Top-right of the title bar, immediately to the LEFT of Chrome's
            // chevron customize button. Chevron sits at maxX − ~24, so the
            // bubble at maxX − 56 leaves a comfortable gap for the 26pt dot.
            // Y aligned with the chevron's vertical center.
            let cgX = frame.maxX - 56
            let cgY = frame.minY + 20
            // Re-check anchor occlusion at the actual bubble position (not the
            // window's right-mid edge).
            var topRightCovered = false
            if zIdx > 0 {
                for i in 0..<zIdx {
                    if ordered[i].frame.contains(CGPoint(x: cgX, y: cgY)) {
                        topRightCovered = true
                        break
                    }
                }
            }
            if topRightCovered { continue }
            let pos = CGPoint(x: cgX, y: screenHeight - cgY)
            newPositions[sid] = pos
        }
        positions = newPositions
        renderView()
    }

    // MARK: - View

    private func renderView() {
        let sortedSids = positions.keys.sorted()
        let key = sortedSids.map { sid -> String in
            let p = positions[sid] ?? .zero
            let enabled = targets[sid]?.enabled == true ? "1" : "0"
            return "\(sid):\(enabled):\(Int(p.x.rounded())):\(Int(p.y.rounded()))"
        }.joined(separator: "|")
        if key == lastRenderedKey { return }
        lastRenderedKey = key

        let bubbles = sortedSids.compactMap { sid -> InspectorView.BubbleData? in
            guard let pos = positions[sid], let t = targets[sid] else { return nil }
            return InspectorView.BubbleData(sessionId: sid, position: pos, enabled: t.enabled)
        }
        hostingController?.rootView = InspectorView(
            bubbles: bubbles,
            onTap: { [weak self] sid, currentEnabled in
                self?.onToggle?(sid, !currentEnabled)
            }
        )
    }
}

// MARK: - SwiftUI

private struct InspectorView: View {
    struct BubbleData: Identifiable {
        let sessionId: String
        let position: CGPoint
        let enabled: Bool
        var id: String { sessionId }
    }
    let bubbles: [BubbleData]
    /// (sessionId, currentEnabled) — caller flips the state.
    let onTap: (String, Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// Match Chrome's inactive title-bar button style. Subtle elevation off
    /// the title-bar background — the chevron uses a similar hue.
    private var dotColor: Color {
        colorScheme == .dark
            ? Color(red: 0.27, green: 0.27, blue: 0.28)
            : Color(red: 0.93, green: 0.93, blue: 0.94)
    }
    private var glyphColor: Color {
        colorScheme == .dark
            ? Color(white: 0.85)
            : Color(white: 0.25)
    }
    /// Active: brand blue, white glyph — clear "inspector ON" affordance.
    private var activeColor: Color { Color(red: 0.231, green: 0.510, blue: 0.965) }

    private let size: CGFloat = 26   // matches Chrome's title-bar button size

    var body: some View {
        GeometryReader { geo in
            ForEach(bubbles) { bubble in
                ZStack {
                    Circle()
                        .fill(bubble.enabled ? activeColor : dotColor)
                        .frame(width: size, height: size)
                    Image(systemName: "scope")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(bubble.enabled ? .white : glyphColor)
                }
                .frame(width: size, height: size)
                .contentShape(Circle())
                .onTapGesture { onTap(bubble.sessionId, bubble.enabled) }
                .position(x: bubble.position.x, y: geo.size.height - bubble.position.y)
            }
        }
    }
}
