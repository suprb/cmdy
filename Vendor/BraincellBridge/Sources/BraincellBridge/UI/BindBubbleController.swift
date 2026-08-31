import AppKit
import SwiftUI

struct BindBubbleHoverState: Equatable {
    static let revealRadius: CGFloat = 26
    static let clickRadius: CGFloat = 14
    static let idleDelay: TimeInterval = 1.15

    let visibleSessionId: String?
    let clickable: Bool

    static func resolve(positions: [String: CGPoint], mouse: CGPoint,
                        secondsSinceMovement: TimeInterval) -> Self {
        let nearest = positions.map { id, position -> (String, CGFloat) in
            let dx = mouse.x - position.x
            let dy = mouse.y - position.y
            return (id, dx * dx + dy * dy)
        }.min { $0.1 < $1.1 }
        guard let nearest, nearest.1 <= revealRadius * revealRadius,
              secondsSinceMovement < idleDelay else {
            return Self(visibleSessionId: nil, clickable: false)
        }
        return Self(visibleSessionId: nearest.0,
                    clickable: nearest.1 <= clickRadius * clickRadius)
    }
}

/// Floating circular "+" button anchored to the right edge of a bindable
/// terminal window — vertically centered, sticks to the window as it moves.
/// Opens Bridge's connection picker with this cmdy pane preselected.
///
/// Click → invokes `onBind(sessionId)`.
///
/// Implementation mirrors `WireOverlayController`: borderless `NSPanel` over
/// the union of all screens, transparent, click-through everywhere except on
/// the bubble. A 1/30s repeating timer polls the matching terminal window's
/// CGWindow frame and updates the bubble's position.
@MainActor
final class BindBubbleController {
    var onBind: ((_ sessionId: String) -> Void)?

    struct Target: Equatable, Hashable {
        let sessionId: String
        let project: String
        /// CGWindowID this bubble anchors to. Required — every bubble is
        /// per-window, not per-app, so multi-window terminal apps work
        /// correctly.
        let windowId: CGWindowID
    }

    private var panel: NSPanel?
    private var hostingController: NSHostingController<MultiBubbleView>?
    private var pollTimer: Timer?
    /// Active bind targets, indexed by sessionId for stable lookup.
    private var targets: [String: Target] = [:]
    /// Last computed screen positions per session — only re-renders when these
    /// change (sub-pixel jitter under 0.5pt is ignored).
    private var positions: [String: CGPoint] = [:]
    private var visibleSessionIds: Set<String> = []
    private var visualTheme = BridgeVisualTheme.fallback
    /// Snapshot of the last rendered view state, used to gate SwiftUI
    /// recomposition so the plus doesn't flicker out from 30Hz re-instantiation.
    private var lastRenderedKey: String = ""

    // Custom hover tooltip — same HUD-material recipe as FastTooltip but
    // hosted by this controller (the bubble's panel doesn't have an
    // NSStatusBarButton to attach FastTooltip to, and we want positioning
    // relative to the bubble's screen point, not a status item).
    private var tooltipPanel: NSPanel?
    private var tooltipLabel: NSTextField?
    private var tooltipShowWorkItem: DispatchWorkItem?
    private let tooltipDelay: TimeInterval = 0.05
    private var idleHideWorkItem: DispatchWorkItem?
    private var lastMouseMovement = Date.distantPast

    func setVisualTheme(_ theme: BridgeVisualTheme) {
        guard visualTheme != theme else { return }
        visualTheme = theme
        lastRenderedKey = ""
        renderView()
    }

    func update(targets newTargets: [Target]) {
        let newDict = Dictionary(uniqueKeysWithValues: newTargets.map { ($0.sessionId, $0) })
        if newDict.keys == targets.keys && newDict == targets { return }
        targets = newDict
        visibleSessionIds.formIntersection(newDict.keys)
        if !targets.isEmpty {
            if panel == nil { buildPanel() }
            // Re-show panel: it might have been ordered out on a previous
            // empty-targets transition, and renderView only updates the
            // hosting controller's rootView, never the window order.
            panel?.orderFrontRegardless()
            ensureTimer()
            // Force the next renderView to actually update by clearing the
            // cached identity key — without this, if the empty-transition
            // didn't bump the key (e.g. positions empty both before and
            // after), renderView would short-circuit and the bubble
            // wouldn't reappear.
            lastRenderedKey = ""
            poll()
        } else {
            positions.removeAll()
            visibleSessionIds.removeAll()
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
        idleHideWorkItem?.cancel()
        idleHideWorkItem = nil
        if let hoverMonitor { NSEvent.removeMonitor(hoverMonitor) }
        hoverMonitor = nil
        if let localHoverMonitor { NSEvent.removeMonitor(localHoverMonitor) }
        localHoverMonitor = nil
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
        p.ignoresMouseEvents = true   // global click-through; flipped on hover

        let host = NSHostingController(rootView: MultiBubbleView(
            bubbles: [],
            theme: visualTheme,
            onTap: { _ in }
        ))
        host.view.frame = totalFrame
        host.view.autoresizingMask = [.width, .height]
        // Transparent SwiftUI host so the Canvas/button doesn't paint a backdrop.
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = host.view
        panel = p
        hostingController = host
        p.orderFrontRegardless()
        installHoverGate()
    }

    /// Status-bar overlays must be click-through globally but NOT over the
    /// bubble itself. A global mouse-moved monitor flips `ignoresMouseEvents`
    /// based on whether the cursor is within the bubble's hit radius.
    private var hoverMonitor: Any?
    private var localHoverMonitor: Any?
    private func installHoverGate() {
        if hoverMonitor != nil { return }
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateHoverGate(mouseDidMove: true) }
        }
        localHoverMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.updateHoverGate(mouseDidMove: true)
            return event
        }
    }
    private func updateHoverGate(mouseDidMove: Bool) {
        guard let panel = panel, !targets.isEmpty else { return }
        let now = Date()
        if mouseDidMove { lastMouseMovement = now }
        let mouse = NSEvent.mouseLocation
        let state = BindBubbleHoverState.resolve(
            positions: positions,
            mouse: mouse,
            secondsSinceMovement: now.timeIntervalSince(lastMouseMovement)
        )
        let nextVisible = state.visibleSessionId.map { Set([$0]) } ?? []
        if nextVisible != visibleSessionIds {
            visibleSessionIds = nextVisible
            renderView()
        }
        panel.ignoresMouseEvents = !state.clickable
        if let id = state.visibleSessionId,
           let target = targets[id], let position = positions[id] {
            scheduleTooltip(text: "Connect \(target.project)…", at: position)
            if mouseDidMove { scheduleIdleHide() }
        } else {
            cancelTooltip()
            idleHideWorkItem?.cancel()
            idleHideWorkItem = nil
        }
    }

    private func scheduleIdleHide() {
        idleHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.idleHideWorkItem = nil
                self?.updateHoverGate(mouseDidMove: false)
            }
        }
        idleHideWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + BindBubbleHoverState.idleDelay,
            execute: work
        )
    }

    // MARK: - Tooltip

    /// Anchor the tooltip relative to a specific bubble's screen position.
    /// Stored so positionTooltipNearBubble() always uses the most recent.
    private var tooltipAnchor: CGPoint = .zero

    private func scheduleTooltip(text: String, at position: CGPoint) {
        tooltipAnchor = position
        // Already showing? just refresh text and reposition (cheap, idempotent).
        if tooltipPanel?.isVisible == true {
            tooltipLabel?.stringValue = text
            sizeTooltipToFit()
            positionTooltipNearBubble()
            return
        }
        // Already scheduled? let the existing work item fire — DON'T cancel
        // and reschedule on every tick. updateHoverGate() runs at 30Hz from
        // poll(), so cancel+reschedule meant the 50ms delay never completed
        // because it kept getting reset before firing.
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
        // Clear so the next dismiss → re-hover can schedule a fresh delay.
        tooltipShowWorkItem = nil
        if tooltipPanel == nil { buildTooltipPanel() }
        tooltipLabel?.stringValue = text
        sizeTooltipToFit()
        positionTooltipNearBubble()
        tooltipPanel?.orderFrontRegardless()
    }

    private func buildTooltipPanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 24),
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
        p.ignoresMouseEvents = true   // never grabs hover, can't steal hits

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

    /// Tooltip sits to the RIGHT of the bubble (off the window's right edge),
    /// vertically aligned to the bubble's center. The bubble is anchored to
    /// the window's right edge so this places the tooltip in the desktop /
    /// adjacent-window area where it won't cover the terminal content.
    private func positionTooltipNearBubble() {
        guard let panel = tooltipPanel else { return }
        let size = panel.frame.size
        let x = tooltipAnchor.x + 14
        let y = tooltipAnchor.y - size.height / 2
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

    /// Build a single CGWindowList snapshot, then resolve each target's anchor
    /// position from that snapshot in one pass. One CGWindow query per tick,
    /// regardless of how many targets are active. Includes z-order so we can
    /// occlusion-check the bubble's anchor point — bubbles for windows whose
    /// right edge is covered by another window above them get hidden, which
    /// prevents the dot from "floating in the middle of nowhere" when its
    /// anchor window is buried but our `.floating` overlay still draws on top.
    private func poll() {
        if targets.isEmpty { return }
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        // Front-to-back ordered list of layer-0 windows + an ID index. Skip
        // our own panels — without this, the bubble overlay would 100%-occlude
        // every other window and nothing would ever render.
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
            // Find this window's z-order index in the ordered list.
            guard let zIdx = ordered.firstIndex(where: { $0.wid == target.windowId }) else { continue }
            let frame = ordered[zIdx].frame
            // Anchor point in CG coords (top-left origin).
            let cgAnchor = CGPoint(x: frame.maxX, y: frame.midY)
            // Check if any window above this one in z-order covers the anchor.
            var anchorCovered = false
            if zIdx > 0 {
                for i in 0..<zIdx {
                    if ordered[i].frame.contains(cgAnchor) { anchorCovered = true; break }
                }
            }
            if anchorCovered {
                continue
            }
            // Straddle the right edge — center on (maxX, midY). Reads as
            // "attached to" the window at its right-most point. Half of
            // the dot extends past the edge by design, similar to a
            // sticker at the edge of a sheet of paper.
            let pos = CGPoint(x: frame.maxX, y: screenHeight - frame.midY)
            newPositions[sid] = pos
        }
        positions = newPositions
        renderView()
        // Re-evaluate hover gate AFTER positions update — covers the case where
        // the bubble jumps to the cursor's existing location (e.g., the user
        // focuses a window that's already under their mouse). Without this,
        // ignoresMouseEvents stays true until the next mouse move, so the
        // bubble looks present but isn't clickable.
        updateHoverGate(mouseDidMove: false)
    }

    // MARK: - View

    private func renderView() {
        // Compose a stable identity key from sessionId+position; only re-render
        // when something material changed (prevents 30Hz SwiftUI recomposition
        // that was flickering the inner plus).
        let sortedSids = positions.keys.sorted()
        let key = sortedSids.map { sid -> String in
            let p = positions[sid] ?? .zero
            return "\(sid):\(Int(p.x.rounded())):\(Int(p.y.rounded())):\(visibleSessionIds.contains(sid))"
        }.joined(separator: "|")
            + ":\(visualTheme.background):\(visualTheme.foreground):\(visualTheme.accent):\(visualTheme.border)"
        if key == lastRenderedKey { return }
        lastRenderedKey = key

        let bubbles = sortedSids.compactMap { sid -> MultiBubbleView.BubbleData? in
            guard let pos = positions[sid] else { return nil }
            return MultiBubbleView.BubbleData(
                sessionId: sid,
                position: pos,
                visible: visibleSessionIds.contains(sid)
            )
        }
        hostingController?.rootView = MultiBubbleView(
            bubbles: bubbles,
            theme: visualTheme,
            onTap: { [weak self] sessionId in self?.onBind?(sessionId) }
        )
    }
}

// MARK: - SwiftUI

private struct MultiBubbleView: View {
    struct BubbleData: Identifiable {
        let sessionId: String
        let position: CGPoint
        let visible: Bool
        var id: String { sessionId }
    }
    let bubbles: [BubbleData]
    let theme: BridgeVisualTheme
    let onTap: (String) -> Void

    private var dotColor: Color { theme.accentColor }
    private var plusColor: Color { theme.backgroundColor }
    private var ringColor: Color { theme.foregroundColor.opacity(0.42) }

    var body: some View {
        GeometryReader { geo in
            ForEach(bubbles) { bubble in
                ZStack {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 16, height: 16)
                    // Plus = two crossed rects with explicit frames. Beats
                    // SF Symbol at this small size: deterministic, no font
                    // metric quirks, no flicker on re-render.
                    Rectangle()
                        .fill(plusColor)
                        .frame(width: 8, height: 1.8)
                    Rectangle()
                        .fill(plusColor)
                        .frame(width: 1.8, height: 8)
                }
                .frame(width: 28, height: 28)
                .overlay(
                    Circle()
                        .strokeBorder(ringColor, lineWidth: 0.75)
                        .frame(width: 16, height: 16)
                )
                .shadow(color: dotColor.opacity(0.20), radius: 3, y: 1)
                .contentShape(Circle())
                .onTapGesture { onTap(bubble.sessionId) }
                .opacity(bubble.visible ? 1 : 0)
                .animation(.easeInOut(duration: 0.18), value: bubble.visible)
                .position(x: bubble.position.x, y: geo.size.height - bubble.position.y)
            }
        }
    }
}
