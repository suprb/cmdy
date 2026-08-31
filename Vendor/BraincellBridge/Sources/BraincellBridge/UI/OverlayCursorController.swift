import AppKit
import SwiftUI

/// Native AI cursor + click ripple overlay. Target-agnostic: works for any
/// surface where we have a screen-space point to anchor on (Mac App AX
/// targets today; future iOS Simulator and Chrome will share the same
/// mechanic).
///
/// Architectural twin of IntentOverlayController — single borderless
/// click-through `.nonactivatingPanel` over the union of all screens, 30Hz
/// timer driving cursor auto-hide + ripple culling. Always click-through;
/// never grabs input.
///
/// Coordinate convention matches IntentOverlayController: callers pass
/// top-left CG screen coords (the AX/CGWindow native space), the controller
/// converts to bottom-left primary-screen-relative for storage, and the
/// SwiftUI view flips back to top-left inside `geo.size.height - y`.
@MainActor
final class OverlayCursorController {
    struct CursorState: Equatable {
        var from: CGPoint?         // nil = pop-in at `to`
        var to: CGPoint            // bottom-left, primary-screen-relative Y
        var startedAt: Date
        var duration: TimeInterval // seconds; 0 = instant
        var label: String
        var lastShownAt: Date
    }

    enum RippleColor: Equatable {
        case click       // bridge blue (default)
        case rightClick  // orange — context menu / destructive accent
    }

    struct Ripple: Identifiable, Equatable {
        let id = UUID()
        let screenPoint: CGPoint   // bottom-left
        let bornAt: Date
        var color: RippleColor = .click
    }

    /// iOS-style pinch visual — two finger glyphs moving along a line
    /// through `center`, animated over 0.5s. `startOffset` is the half-
    /// distance at t=0; `endOffset` at t=1. Direction is implicit
    /// (start < end → pinch-out; start > end → pinch-in).
    struct Pinch: Identifiable, Equatable {
        let id = UUID()
        let center: CGPoint        // bottom-left
        let startOffset: CGFloat
        let endOffset: CGFloat
        let bornAt: Date
    }

    struct Capture: Identifiable, Equatable {
        let id = UUID()
        let rect: CGRect          // bottom-left, primary-screen-relative origin
        let bornAt: Date
    }

    private var cursor: CursorState?
    private var ripples: [Ripple] = []
    private var captures: [Capture] = []
    private var pinches: [Pinch] = []
    private var panel: NSPanel?
    private var hostingController: NSHostingController<OverlayCursorView>?
    private var pollTimer: Timer?

    /// Cursor + label flash + click ripple at the given top-left CG screen
    /// point. Cursor tweens from its current position (if visible) to the
    /// new point over ~250ms. Ripple particle expands and fades over
    /// ~0.45s (matches the Chrome DOM cursor's `__bc-ripple` keyframe).
    func showClickAt(screenPointCGTopLeft point: CGPoint, label: String = "Click") {
        moveCursor(toTopLeftCG: point, label: label, duration: 0.25)
        let bl = bottomLeft(fromTopLeftCG: point)
        ripples.append(Ripple(screenPoint: bl, bornAt: Date()))
        ensurePanel()
        ensureTimer()
        renderView()
    }

    /// Cursor + label without ripple. Use for hover, type, or pre-click
    /// positioning when there's no actual press happening. Cursor tweens
    /// from its current position (if visible) over `duration`.
    func showCursorAt(screenPointCGTopLeft point: CGPoint, label: String, duration: TimeInterval = 0.25) {
        moveCursor(toTopLeftCG: point, label: label, duration: duration)
        ensurePanel()
        ensureTimer()
        renderView()
    }

    /// Two ripples in quick succession at the same point. Use for
    /// double-click / double-tap gestures. Cursor planted once with
    /// "Double-click" label.
    func showDoubleClickAt(screenPointCGTopLeft point: CGPoint, label: String = "Double-click") {
        moveCursor(toTopLeftCG: point, label: label, duration: 0.18)
        let bl = bottomLeft(fromTopLeftCG: point)
        ripples.append(Ripple(screenPoint: bl, bornAt: Date()))
        // Second ripple a tick later so they read as two separate hits.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 130_000_000)
            self?.ripples.append(Ripple(screenPoint: bl, bornAt: Date()))
            self?.renderView()
        }
        ensurePanel()
        ensureTimer()
        renderView()
    }

    /// Single ripple in the right-click color (orange) at the point. Use
    /// for right-click / two-finger-tap / long-press gestures that surface
    /// a context menu. Cursor label flips to "Right-click" by default.
    func showRightClickAt(screenPointCGTopLeft point: CGPoint, label: String = "Right-click") {
        moveCursor(toTopLeftCG: point, label: label, duration: 0.25)
        let bl = bottomLeft(fromTopLeftCG: point)
        ripples.append(Ripple(screenPoint: bl, bornAt: Date(), color: .rightClick))
        ensurePanel()
        ensureTimer()
        renderView()
    }

    /// Two-cursor pinch visual (iOS-style) — two arrows moving apart from
    /// (or together toward) the center. `scale > 1` = pinch-out (zoom in),
    /// `scale < 1` = pinch-in (zoom out). Distance is `100pt * |scale-1|`
    /// half-distance from center, animated over 0.5s. Cursor itself moves
    /// to the center as the anchor; the two finger glyphs are temporary
    /// visuals on top of the existing cursor.
    func showPinchAt(centerCGTopLeft center: CGPoint, scale: Double, label: String = "Pinch") {
        let bl = bottomLeft(fromTopLeftCG: center)
        let halfDist = 100 * abs(scale - 1.0)
        // Pinch-out starts close, ends far. Pinch-in starts far, ends close.
        let startOffset: CGFloat = scale > 1.0 ? 8.0 : CGFloat(halfDist)
        let endOffset: CGFloat = scale > 1.0 ? CGFloat(halfDist) : 8.0
        pinches.append(Pinch(
            center: bl,
            startOffset: startOffset,
            endOffset: endOffset,
            bornAt: Date()
        ))
        moveCursor(toTopLeftCG: center, label: label, duration: 0.0)
        ensurePanel()
        ensureTimer()
        renderView()
    }

    /// Internal: update `cursor` so it tweens from its current interpolated
    /// position to the new target. If no cursor is visible, pop in at the
    /// target with no `from` (instant). Duration of 0 = instant move.
    private func moveCursor(toTopLeftCG point: CGPoint, label: String, duration: TimeInterval) {
        let to = bottomLeft(fromTopLeftCG: point)
        let from: CGPoint? = {
            guard let existing = cursor else { return nil }
            // Compute where the cursor visibly IS right now (mid-tween or
            // already-arrived) so the new tween starts from the same point
            // and there's no jump.
            return Self.interpolatedPosition(of: existing, at: Date())
        }()
        cursor = CursorState(
            from: from, to: to,
            startedAt: Date(), duration: duration,
            label: label, lastShownAt: Date()
        )
    }

    /// macOS ⌘⇧4-style screenshot capture: pulsing rectangle around the
    /// captured region + cursor that sweeps from top-left to bottom-right
    /// as if dragging the selection. Total motion ~450ms; rect culls at
    /// ~750ms.
    func showScreenshotCapture(rectCGTopLeft rect: CGRect) {
        let bl = bottomLeftRect(fromTopLeftCG: rect)
        captures.append(Capture(rect: bl, bornAt: Date()))
        // Pop cursor in at the top-left of the rect (instant, no tween).
        let topLeft = CGPoint(x: rect.minX, y: rect.minY)
        showCursorAt(screenPointCGTopLeft: topLeft, label: "Screenshot", duration: 0)
        // After a short beat (so the eye registers the start point), sweep
        // to bottom-right over 400ms — mimics the user dragging a capture
        // rect. Tween animation is driven from CursorState; this just sets
        // the new target and the SwiftUI TimelineView animates the rest.
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            self?.showCursorAt(
                screenPointCGTopLeft: bottomRight,
                label: "Screenshot",
                duration: 0.4
            )
        }
        ensurePanel()
        ensureTimer()
        renderView()
    }

    func hide() {
        cursor = nil
        ripples.removeAll()
        captures.removeAll()
        pinches.removeAll()
        renderView()
        stopTimer()
        panel?.orderOut(nil)
    }

    /// Refresh the cursor's last-shown timestamp without moving it. Lets
    /// the cursor stay visible across a sequence of tool calls (visual or
    /// read-only) so the user sees a continuous "Claude is working"
    /// signal rather than a flash that disappears between calls. Called
    /// from `BridgeToolRouter.execute` for every tool dispatch.
    func heartbeat() {
        guard cursor != nil else { return }
        cursor?.lastShownAt = Date()
    }

    // MARK: - Panel

    private func ensurePanel() {
        if let p = panel { p.orderFrontRegardless(); return }
        let union = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        let p = NSPanel(
            contentRect: union,
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

        let host = NSHostingController(
            rootView: OverlayCursorView(cursor: nil, ripples: [], captures: [], pinches: [])
        )
        host.view.frame = NSRect(origin: .zero, size: union.size)
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
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func stopTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Cull stale ripples + captures, auto-hide cursor after extended
    /// inactivity. Cursor lingers MUCH longer than the Chrome DOM cursor
    /// did (4s) — it's now a "Claude is working" indicator. Every tool
    /// call from BridgeToolRouter heartbeats it, so a working session
    /// keeps the cursor pinned at the last point Claude touched. The 15s
    /// timeout is the "Claude has actually stopped" floor.
    private func tick() {
        let now = Date()
        ripples.removeAll { now.timeIntervalSince($0.bornAt) > 0.6 }
        captures.removeAll { now.timeIntervalSince($0.bornAt) > 1.6 }
        pinches.removeAll { now.timeIntervalSince($0.bornAt) > 0.7 }
        if let c = cursor, now.timeIntervalSince(c.lastShownAt) > 15.0 {
            cursor = nil
        }
        if cursor == nil && ripples.isEmpty && captures.isEmpty && pinches.isEmpty {
            stopTimer()
            panel?.orderOut(nil)
            return
        }
        renderView()
    }

    private func renderView() {
        hostingController?.rootView = OverlayCursorView(
            cursor: cursor, ripples: ripples, captures: captures, pinches: pinches
        )
    }

    // MARK: - Tween math

    /// Where the cursor visibly is at `now`. Pre-tween or duration=0 →
    /// `to`. Mid-tween → cubic ease-out interpolation between `from` and
    /// `to`. Post-tween → `to`. Static so the SwiftUI view can call it
    /// without touching the controller.
    static func interpolatedPosition(of c: CursorState, at now: Date) -> CGPoint {
        guard let from = c.from, c.duration > 0 else { return c.to }
        let elapsed = now.timeIntervalSince(c.startedAt)
        if elapsed <= 0 { return from }
        if elapsed >= c.duration { return c.to }
        let t = elapsed / c.duration
        // Cubic ease-out: starts fast, settles smoothly. Matches the feel
        // of macOS cursor warping + keeps the click target predictable.
        let eased = 1 - pow(1 - t, 3)
        return CGPoint(
            x: from.x + (c.to.x - from.x) * eased,
            y: from.y + (c.to.y - from.y) * eased
        )
    }

    // MARK: - Coord conversion

    /// AX/CG top-left screen coord → bottom-left, origin at bottom of
    /// primary screen. SwiftUI view then flips back to top-left via
    /// `geo.size.height - y` (same shape as IntentOverlayController).
    private func bottomLeft(fromTopLeftCG p: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// Same flip for a rect — store origin in bottom-left coords, keep size
    /// unchanged. The SwiftUI view treats this rect's `minY` as the
    /// bottom-left of the rect (so when re-flipping with
    /// `geo.size.height - minY`, we get the rect's top-left edge).
    private func bottomLeftRect(fromTopLeftCG r: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // Bottom of rect in CG-top-left coords = r.minY + r.height.
        // Convert to bottom-left coords: blY = primaryHeight - (minY + height).
        return CGRect(
            x: r.origin.x,
            y: primaryHeight - r.origin.y - r.size.height,
            width: r.size.width,
            height: r.size.height
        )
    }
}

// MARK: - SwiftUI

private struct OverlayCursorView: View {
    let cursor: OverlayCursorController.CursorState?
    let ripples: [OverlayCursorController.Ripple]
    let captures: [OverlayCursorController.Capture]
    let pinches: [OverlayCursorController.Pinch]

    private static let bridgeBlue = Color(red: 0.231, green: 0.510, blue: 0.965)
    private static let rightClickOrange = Color(red: 0.97, green: 0.55, blue: 0.18)

    private static func rippleColor(_ c: OverlayCursorController.RippleColor) -> Color {
        switch c {
        case .click: return bridgeBlue
        case .rightClick: return rightClickOrange
        }
    }

    /// Pulse-on (~150ms): scale 0.96 → 1.0, opacity 0 → 1.
    /// Hold (~200ms): full opacity.
    /// Fade-out (~400ms): opacity 1 → 0.
    @ViewBuilder
    private func captureRect(for cap: OverlayCursorController.Capture, now: Date) -> some View {
        let t = now.timeIntervalSince(cap.bornAt)
        let pulseIn = min(t / 0.15, 1.0)
        let fadeOut = t < 0.35 ? 1.0 : max(0.0, 1.0 - (t - 0.35) / 0.40)
        let opacity = pulseIn * fadeOut
        let scale = 0.96 + 0.04 * pulseIn
        RoundedRectangle(cornerRadius: 6)
            .stroke(Self.bridgeBlue, lineWidth: 2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Self.bridgeBlue.opacity(0.08))
            )
            .frame(width: cap.rect.width, height: cap.rect.height)
            .scaleEffect(scale)
            .opacity(opacity)
            .shadow(color: Self.bridgeBlue.opacity(0.35), radius: 8)
    }

    var body: some View {
        GeometryReader { geo in
            // Capture rects render at the back — thin pulsing border around
            // the captured region. The cursor (planted at the top-left
            // corner by showScreenshotCapture) sits on top.
            ForEach(captures) { cap in
                let topY = geo.size.height - (cap.rect.origin.y + cap.rect.height)
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
                    captureRect(for: cap, now: ctx.date)
                }
                .frame(width: cap.rect.width, height: cap.rect.height)
                .position(x: cap.rect.midX, y: topY + cap.rect.height / 2)
            }

            // Ripples render under the cursor so the arrow stays on top.
            ForEach(ripples) { ripple in
                let y = geo.size.height - ripple.screenPoint.y
                let baseColor = Self.rippleColor(ripple.color)
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
                    let t = ctx.date.timeIntervalSince(ripple.bornAt)
                    let progress = min(t / 0.45, 1.0)
                    let scale = 1.0 + 5.0 * progress
                    let opacity = max(0, 1.0 - progress)
                    Circle()
                        .fill(baseColor.opacity(0.35))
                        .frame(width: 8, height: 8)
                        .scaleEffect(scale)
                        .opacity(opacity)
                }
                .frame(width: 8, height: 8)
                // Match the Chrome ripple's +3,+2 offset from the cursor tip.
                .position(x: ripple.screenPoint.x + 3, y: y + 2)
            }

            // Pinch glyphs — two small circles spreading apart from / coming
            // together toward `center`, animated over 500ms ease-out.
            ForEach(pinches) { pinch in
                let cy = geo.size.height - pinch.center.y
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
                    let t = ctx.date.timeIntervalSince(pinch.bornAt)
                    let p = min(t / 0.5, 1.0)
                    let eased = 1 - pow(1 - p, 3)
                    let offset = pinch.startOffset + (pinch.endOffset - pinch.startOffset) * CGFloat(eased)
                    let opacity = max(0, 1.0 - max(0, p - 0.7) / 0.3)
                    ZStack {
                        // Two finger-tip glyphs on a horizontal axis through center.
                        Circle()
                            .fill(Self.bridgeBlue.opacity(0.55))
                            .frame(width: 18, height: 18)
                            .position(x: pinch.center.x - offset, y: cy)
                        Circle()
                            .fill(Self.bridgeBlue.opacity(0.55))
                            .frame(width: 18, height: 18)
                            .position(x: pinch.center.x + offset, y: cy)
                    }
                    .opacity(opacity)
                }
            }

            // Cursor + label. Position is driven by a TimelineView so
            // mid-tween motion is smooth even though the rootView gets
            // swapped on every controller renderView() call —
            // OverlayCursorController.interpolatedPosition is pure math
            // over CursorState's (from, to, startedAt, duration) fields,
            // so any new TimelineView computes the same point at the same
            // time. Anchor a 1pt invisible spacer at the cursor point;
            // arrow + label offset from it so the tip lands exactly on
            // target and the label tucks below-right.
            if let c = cursor {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
                    cursorView(c, in: geo, at: ctx.date)
                }
            }
        }
    }

    /// Cursor view at the interpolated tween position for `now`.
    @ViewBuilder
    private func cursorView(
        _ c: OverlayCursorController.CursorState,
        in geo: GeometryProxy,
        at now: Date
    ) -> some View {
        let pos = OverlayCursorController.interpolatedPosition(of: c, at: now)
        let y = geo.size.height - pos.y
        ZStack(alignment: .topLeading) {
            CursorArrowShape()
                .fill(Self.bridgeBlue)
                .overlay(CursorArrowShape().stroke(Color.white, lineWidth: 1.5))
                .frame(width: 20, height: 20)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .offset(x: -2, y: -2)   // tip at (0,0) of ZStack

            Text(c.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Self.bridgeBlue)
                )
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                .fixedSize()
                .offset(x: 14, y: 18)
        }
        .frame(width: 1, height: 1, alignment: .topLeading)
        .position(x: pos.x, y: y)
    }
}

/// Bridge cursor arrow — hand-traced from the Chrome DOM cursor SVG so the
/// silhouette matches across targets. Designed at 20×20; scales uniformly.
private struct CursorArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 20.0
        var p = Path()
        p.move(to: CGPoint(x: 2.31 * s, y: 1.05 * s))
        p.addLine(to: CGPoint(x: 18.29 * s, y: 5.96 * s))
        p.addCurve(
            to: CGPoint(x: 18.44 * s, y: 7.83 * s),
            control1: CGPoint(x: 19.16 * s, y: 6.23 * s),
            control2: CGPoint(x: 19.26 * s, y: 7.43 * s)
        )
        p.addLine(to: CGPoint(x: 11.67 * s, y: 11.22 * s))
        p.addLine(to: CGPoint(x: 7.83 * s, y: 18.44 * s))
        p.addCurve(
            to: CGPoint(x: 5.96 * s, y: 18.29 * s),
            control1: CGPoint(x: 7.43 * s, y: 19.26 * s),
            control2: CGPoint(x: 6.23 * s, y: 19.16 * s)
        )
        p.addLine(to: CGPoint(x: 1.05 * s, y: 2.31 * s))
        p.addCurve(
            to: CGPoint(x: 2.31 * s, y: 1.05 * s),
            control1: CGPoint(x: 0.81 * s, y: 1.53 * s),
            control2: CGPoint(x: 1.54 * s, y: 0.81 * s)
        )
        p.closeSubpath()
        return p
    }
}
