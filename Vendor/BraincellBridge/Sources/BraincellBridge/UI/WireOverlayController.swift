import AppKit
import SwiftUI
import Combine
@preconcurrency import ObjectiveC
import ApplicationServices  // AXUIElement / kAXMainAttribute / kAXRaiseAction

// Same private API used in TextInjection / BridgeAppDelegate. Maps an AX window
// element to its CGWindowID so a session stays attached to its exact cmdy
// window when several cmdy windows are open.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Floating, click-through, full-screen NSPanel that draws a glowing bezier wire
/// from each bound terminal window to its bound Chrome window. Visual cue that
/// "this terminal is connected to that browser." Updates ~5Hz so the wire tracks
/// dragged/resized windows.
@MainActor
final class WireOverlayController: ObservableObject {
    weak var appState: BridgeAppState?
    private var panel: NSPanel?
    private var hostingController: NSHostingController<WireOverlay>?
    private var pollTimer: Timer?
    private var bindingsObserver: AnyCancellable?
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?

    /// Animated render state — what the Canvas draws each frame. Wires render
    /// only when both endpoints are visible on the current Space.
    @Published var wires: [WirePair] = []

    /// "Summon" dots — drawn when ONE side of a binding isn't on the current
    /// Space (window covered, or in another Space). Click brings the missing
    /// app's window forward.
    @Published var summonDots: [SummonDot] = []

    @Published var screenFrame: CGRect = .zero
    @Published private(set) var visualTheme = BridgeVisualTheme.fallback

    /// Mouse-tracking toggle: true means a click would land on a summon dot.
    /// Used to flip `panel.ignoresMouseEvents` so empty regions stay click-through
    /// to the apps below while dots remain interactive.
    @Published var cursorOverDot: Bool = false

    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?

    func setVisualTheme(_ theme: BridgeVisualTheme) {
        guard theme != visualTheme else { return }
        visualTheme = theme
    }

    /// Read the current activity pulse for `sessionId` if it hasn't expired.
    /// Used by `WireOverlay` to set per-wire dash direction + speed.
    func activityPulse(for sessionId: String, at now: Date) -> ActivityDirection? {
        guard let pulse = appState?.activityPulses[sessionId], pulse.until > now else { return nil }
        return pulse.direction
    }

    /// Activate the target app + AX-raise its specific bound window. `app.activate()`
    /// alone leaves the in-app window order untouched, so for multi-window terminal
    /// apps the user would see the menu bar flip but no terminal window surface.
    /// Pair with `kAXMainAttribute = true` + `kAXRaiseAction` on the matching
    /// `AXUIElement`. If `windowId` is provided, find that exact window via
    /// `_AXUIElementGetWindow`; otherwise fall back to the first window.
    func summon(_ summon: SummonDot.Summon) {
        guard let app = NSRunningApplication(processIdentifier: summon.pid) else {
            NSLog("[WireOverlay] summon: no NSRunningApplication for pid %d", summon.pid)
            return
        }
        NSLog("[WireOverlay] summon → %@ (pid %d, windowId=%@)",
              app.bundleIdentifier ?? "?", summon.pid,
              summon.windowId.map { "\($0)" } ?? "nil")
        app.activate()
        raiseWindow(of: summon.pid, matchingId: summon.windowId)
    }

    private func raiseWindow(of pid: pid_t, matchingId target: CGWindowID?) {
        let appRef = AXUIElementCreateApplication(pid)
        var windowsRef: AnyObject?
        let getStatus = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef)
        guard getStatus == .success, let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            NSLog("[WireOverlay] AX raise: couldn't read windows for pid %d (status=%d)", pid, getStatus.rawValue)
            return
        }
        // Specific window match if requested.
        if let target = target {
            for window in windows {
                var wid: CGWindowID = 0
                if _AXUIElementGetWindow(window, &wid) == .success, wid == target {
                    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    NSLog("[WireOverlay] AX raised specific window %u", target)
                    return
                }
            }
            NSLog("[WireOverlay] AX raise: target window %u not found among %d AX windows; raising first",
                  target, windows.count)
        }
        // Fallback: raise first window.
        if let first = windows.first {
            AXUIElementSetAttributeValue(first, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(first, kAXRaiseAction as CFString)
        }
    }

    /// Read accessor for the cached terminal window id of a session. Used by
    /// `TextInjection` to AX-raise the SPECIFIC bound window before pasting,
    /// so commands ("Run dev server", "Send to Claude") land in the right
    /// terminal even when the user has multiple windows of the same app.
    func boundTerminalWindowId(for sessionId: String) -> CGWindowID? {
        stickyTerminalWindowId[sessionId]
    }

    /// Pick the terminal window that this session actually lives in, NOT just
    /// the frontmost terminal window of the app. Two-pass:
    ///
    /// 1. **AX title match** — walk the terminal app's windows via AX, pick the
    ///    one whose `kAXTitleAttribute` contains the session's project basename
    ///    or tty short name (e.g. "cc" or "ttys005"). This is the specific
    ///    window for this session even when the popover steals focus or some
    ///    unrelated terminal window is frontmost.
    /// 2. **Frontmost-of-app fallback** — original behavior, kept for the case
    ///    where the title-match fails (no project name, AX denied, etc.).
    ///
    /// Why the change: when the user clicks "Bind Chrome" in the popover, the
    /// popover steals focus, and the previously-frontmost terminal window may
    /// be a totally unrelated one (e.g. the shell that's running the bridge
    /// binary itself). The wire would then anchor to that unrelated window.
    /// AX title match is the same heuristic used by `bindableSessions()` — so
    /// the bind bubble and the bind action consult the same model of which
    /// window belongs to which session.
    func stickToTerminalWindowAtBindTime(forSession session: TerminalSession) {
        if let windowId = session.windowId {
            stickyTerminalWindowId[session.id] = windowId
            return
        }
        let terminalPid = resolvedTerminalAppPid(for: session)

        // Pass 1: AX title match.
        if let wid = axWindowMatchingSession(session, terminalPid: terminalPid) {
            stickyTerminalWindowId[session.id] = wid
            NSLog("[WireOverlay] Stuck terminal window %u for session %@ (AX-title-match)",
                  wid, session.id)
            return
        }

        // Pass 2: frontmost-of-app fallback.
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return }
        for w in list {
            let owner = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if owner == terminalPid && layer == 0,
               let wid = windowID(of: w) {
                stickyTerminalWindowId[session.id] = wid
                NSLog("[WireOverlay] Stuck terminal window %u for session %@ (frontmost-of-app fallback)",
                      wid, session.id)
                return
            }
        }
    }

    /// Walk the terminal app's AX window list and return the CGWindowID of the
    /// first window whose title contains the session's project basename OR tty
    /// short name. AX needs Accessibility (already required for the bridge),
    /// not Screen Recording — so works even when CGWindowList titles are empty.
    private func axWindowMatchingSession(_ session: TerminalSession, terminalPid: pid_t) -> CGWindowID? {
        let projectName = (session.projectPath as NSString?)?.lastPathComponent ?? ""
        let ttyShort = (session.tty as NSString).lastPathComponent
        if projectName.isEmpty && ttyShort.isEmpty { return nil }

        let app = AXUIElementCreateApplication(terminalPid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }

        for window in windows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            let title = (titleRef as? String) ?? ""
            let matchesProject = !projectName.isEmpty && title.contains(projectName)
            let matchesTty = !ttyShort.isEmpty && title.contains(ttyShort)
            guard matchesProject || matchesTty else { continue }
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(window, &wid) == .success, wid != 0 {
                return wid
            }
        }
        return nil
    }

    /// Target positions, updated at poll rate (~5Hz). Each animation tick lerps
    /// `wires` toward `targets` so window drags don't make the wire snap.
    private var targets: [WirePair] = []
    private var pollCounter: Int = 0

    init(appState: BridgeAppState) {
        self.appState = appState
        // Re-evaluate visibility whenever bindings change.
        bindingsObserver = appState.bindings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshVisibility() }
        // Re-position the panel if the screen layout changes.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.repositionForCurrentScreens() }
        }
    }

    deinit {
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func shutdown() {
        bindingsObserver?.cancel()
        bindingsObserver = nil
        stopPolling()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        localMouseMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        summonDots.removeAll()
        panel?.close()
        panel = nil
        hostingController = nil
    }

    /// Show the overlay if there's at least one drawable binding (Chrome
    /// OR Mac App). Hide + stop polling otherwise. Idempotent — safe to
    /// call repeatedly.
    ///
    /// Bug fix: this used to gate on Chrome bindings only. Mac App
    /// bindings had wire targets computed correctly in `recomputeWires`,
    /// but the panel was never shown + the poll loop was never started, so
    /// nothing rendered. Adding a Chrome binding alongside flipped the
    /// gate on and made the Mac App wire appear too.
    func refreshVisibility() {
        guard let appState = appState else { return }
        // TargetAdapter protocol: any session with an adapter is drawable.
        // Replaces the per-target switch (which silently broke for new
        // adapter types until the case was added explicitly — same trap
        // as the other audit-enum-sites bugs).
        let hasDrawableBinding = !appState.allAdapters().isEmpty
        if hasDrawableBinding {
            ensurePanel()
            // Re-order to front in case the panel exists but was orderedOut
            // by a previous "no bindings" pass. ensurePanel() short-circuits
            // when panel != nil (since orderOut keeps the panel alive but
            // hidden), so without this re-order the post-rebind wire stays
            // invisible after a close and subsequent rebind.
            panel?.orderFrontRegardless()
            startPolling()
        } else {
            stopPolling()
            panel?.orderOut(nil)
        }
    }

    // MARK: - Panel setup

    private func ensurePanel() {
        if panel != nil { return }

        let frame = unionScreenFrame()
        screenFrame = frame

        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        // Default to click-through; we toggle this off when the cursor is over
        // a summon dot so the click can be captured.
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false

        let host = NSHostingController(rootView: WireOverlay(controller: self))
        host.view.frame = NSRect(origin: .zero, size: frame.size)
        p.contentViewController = host

        p.orderFrontRegardless()
        panel = p
        hostingController = host

        startMouseTracking()
    }

    /// Watch the global cursor position. When it enters a 22pt radius around any
    /// summon dot, flip the panel to non-click-through so the dot can be tapped;
    /// otherwise stay click-through so empty regions pass through to underlying
    /// apps. Single global monitor — cheap and reliable.
    private func startMouseTracking() {
        if mouseMonitor != nil { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateClickThrough() }
        }
        // Also tick on local events so it works even when bridge is foreground.
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            Task { @MainActor [weak self] in self?.updateClickThrough() }
            return event
        }
    }

    private func updateClickThrough() {
        guard let panel = panel else { return }
        if summonDots.isEmpty {
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            cursorOverDot = false
            return
        }
        let mouse = NSEvent.mouseLocation  // screen coords (bottom-left origin)
        // Convert to canvas coords.
        let canvasMouse = canvasPoint(fromBottomLeftScreen: mouse)
        let hit = summonDots.contains { dot in
            let dx = dot.position.x - canvasMouse.x
            let dy = dot.position.y - canvasMouse.y
            return (dx * dx + dy * dy) <= 22 * 22
        }
        if hit != cursorOverDot {
            cursorOverDot = hit
        }
        if panel.ignoresMouseEvents == hit {
            panel.ignoresMouseEvents = !hit
        }
    }

    /// Translate mouse position (NSScreen coords, bottom-left origin) into the
    /// canvas's top-left coord space inside the union frame.
    private func canvasPoint(fromBottomLeftScreen p: CGPoint) -> CGPoint {
        let canvasX = p.x - screenFrame.minX
        let canvasY = screenFrame.maxY - p.y
        return CGPoint(x: canvasX, y: canvasY)
    }

    private func repositionForCurrentScreens() {
        let frame = unionScreenFrame()
        screenFrame = frame
        panel?.setFrame(frame, display: true)
        hostingController?.view.frame = NSRect(origin: .zero, size: frame.size)
    }

    /// Bounding box of all attached screens, in screen coordinates (bottom-left origin).
    private func unionScreenFrame() -> CGRect {
        var union = CGRect.zero
        for screen in NSScreen.screens {
            union = union.isEmpty ? screen.frame : union.union(screen.frame)
        }
        return union
    }

    // MARK: - Polling

    private func startPolling() {
        if pollTimer != nil { return }
        // Single 60Hz tick that does two things:
        //   - Every frame: lerp `wires` toward `targets` so window drags ease in.
        //   - Every 12th frame (~5Hz): re-query window positions to refresh targets.
        pollCounter = 0
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        recomputeWires()         // initial target snapshot
        wires = targets          // first frame: snap to target so wire appears instantly
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        wires = []
        targets = []
    }

    /// One animation frame: re-poll on the 12-tick boundary, ease toward targets,
    /// publish if changed.
    private func tick() {
        pollCounter += 1
        if pollCounter % 12 == 0 {
            recomputeWires()
        }

        // Frame-rate-independent exponential ease. lambda=18 → ~half the gap
        // closed every ~38ms. Smooth even when windows are dragged fast.
        let dt: Double = 1.0 / 60.0
        let factor = CGFloat(1 - exp(-dt * 18))

        var next: [WirePair] = []
        next.reserveCapacity(targets.count)
        for target in targets {
            if let current = wires.first(where: { $0.id == target.id }) {
                let start = lerp(current.start, target.start, t: factor)
                let end = lerp(current.end, target.end, t: factor)
                next.append(WirePair(id: target.id, start: start, end: end))
            } else {
                // Newly-bound session — snap straight to its position so the
                // wire doesn't visibly fly in from (0,0).
                next.append(target)
            }
        }
        if next != wires {
            wires = next
        }
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Look up screen positions for each bound (terminal app window, Chrome window) pair
    /// and rebuild `targets` for wires (both visible) + `summonDots` (one missing).
    private func recomputeWires() {
        guard let appState = appState else { return }
        var nextWires: [WirePair] = []
        var nextDots: [SummonDot] = []

        // Snapshot the window list ONCE per recompute so all visibility checks
        // share the same z-order. CGWindowList returns front-to-back.
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windowList = (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []

        // Prune sticky window-id caches for sessions that no longer have a binding.
        let activeIds = Set(appState.bindings.bindings.keys)
        stickyTerminalWindowId = stickyTerminalWindowId.filter { activeIds.contains($0.key) }
        stickyChromeWindowId = stickyChromeWindowId.filter { activeIds.contains($0.key) }

        // Dedupe wires/summon-dots by terminal windowId. Apple Terminal tabs
        // share a CGWindowID, so two sibling sessions (auto-bound on a new
        // tab in the same project) would otherwise render two identical
        // wires stacked at the same anchor — a visual mess. The rule is:
        // same window with a same-dir tab → one wire; different
        // windows for the same project → one wire each.
        var emittedTerminalWindowIds: Set<CGWindowID> = []

        // TargetAdapter unified loop. Replaces four parallel iteration
        // blocks (Chrome / Mac App / Sim / Native) that were structurally
        // identical except for adapter type, summon label, and chrome's
        // sticky window cache. Now: one loop, queries each adapter for
        // its anchorPid + windowFrame via the TargetAdapter protocol.
        // Adding a 5th adapter just needs the type added to the summon-
        // label switch (cosmetic — defaults to "Show app" if missing).
        for (sessionId, adapter) in appState.allAdapters() {
            guard let session = appState.registry.session(id: sessionId),
                  let appPid = adapter.anchorPid else { continue }

            let terminalPid = resolvedTerminalAppPid(for: session)
            let termFrame = stickyWindowFrame(
                sessionId: sessionId,
                cache: \.stickyTerminalWindowId,
                ownerPid: terminalPid,
                in: windowList,
                pickFresh: { self.matchingTerminalWindowFrame(forSession: session, ownerPid: terminalPid, in: windowList) }
            )
            // Adapter knows where its window is (Chrome via CGWindowList,
            // Mac/Native via AX focused-window, Sim via Simulator.app
            // bounds). Fall back to a generic frontmost-of-pid lookup.
            let appFrame = adapter.windowFrame()
                ?? frontmostWindowFrame(forOwnerPid: appPid, in: windowList)

            let termWid = stickyTerminalWindowId[sessionId]
            if let wid = termWid, emittedTerminalWindowIds.contains(wid) { continue }
            if let wid = termWid { emittedTerminalWindowIds.insert(wid) }

            // Summon label per adapter type — purely cosmetic. New
            // adapter types fall through to the generic "Show app".
            let appSummonLabel: String
            switch adapter {
            case is ChromeAdapter:    appSummonLabel = "Show Chrome"
            case is MacAppAdapter:    appSummonLabel = "Show app"
            case is SimulatorAdapter: appSummonLabel = "Show Simulator"
            case is NativeAppAdapter: appSummonLabel = "Show app"
            default:                  appSummonLabel = "Show app"
            }

            switch (termFrame, appFrame) {
            case let (term?, app?):
                let termCenter = CGPoint(x: term.midX, y: term.midY)
                let appCenter = CGPoint(x: app.midX, y: app.midY)
                let termAttach: CGPoint
                let appAttach: CGPoint
                if termCenter.x < appCenter.x {
                    termAttach = CGPoint(x: term.maxX, y: term.midY)
                    appAttach = CGPoint(x: app.minX, y: app.midY)
                } else {
                    termAttach = CGPoint(x: term.minX, y: term.midY)
                    appAttach = CGPoint(x: app.maxX, y: app.midY)
                }
                nextWires.append(WirePair(
                    id: sessionId,
                    start: canvasPoint(from: termAttach),
                    end: canvasPoint(from: appAttach)
                ))

            case let (term?, nil):
                // Terminal visible, app hidden — summon dot on terminal's right.
                let attach = CGPoint(x: term.maxX, y: term.midY)
                nextDots.append(SummonDot(
                    id: "\(sessionId)/app",
                    position: canvasPoint(from: attach),
                    summon: .init(pid: appPid, windowId: nil),
                    label: appSummonLabel
                ))

            case let (nil, app?):
                // App visible, terminal hidden — summon dot on app's left.
                let attach = CGPoint(x: app.minX, y: app.midY)
                let cachedWid = stickyTerminalWindowId[sessionId]
                nextDots.append(SummonDot(
                    id: "\(sessionId)/terminal",
                    position: canvasPoint(from: attach),
                    summon: .init(pid: terminalPid, windowId: cachedWid),
                    label: "Show Terminal"
                ))

            case (nil, nil):
                continue
            }
        }

        targets = nextWires
        if nextDots != summonDots {
            summonDots = nextDots
        }
    }


    /// Pick the SPECIFIC terminal window for this session — not just the largest
    /// of the app. Returns nil if no match is found OR the matched window is
    /// substantially occluded (caller summons it forward instead of drawing a
    /// wire to a window the user can't see). `kCGWindowName` requires Screen
    /// Recording permission on Sonoma+; without it we fall back to the largest
    /// window (still subject to the occlusion gate).
    private func matchingTerminalWindowFrame(forSession session: TerminalSession, ownerPid: pid_t, in list: [[String: Any]]) -> CGRect? {
        // Collect (index in list, raw window dict) for this app's normal windows.
        var app: [(index: Int, w: [String: Any])] = []
        for (idx, w) in list.enumerated() {
            let owner = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if owner == ownerPid && layer == 0 {
                app.append((idx, w))
            }
        }
        if app.isEmpty { return nil }

        // Build match keys: project basename + tty short name (e.g. "ttys006").
        var keys: [String] = []
        if let proj = session.projectPath, !proj.isEmpty {
            keys.append((proj as NSString).lastPathComponent)
        }
        let ttyShort = (session.tty as NSString).lastPathComponent
        if !ttyShort.isEmpty && ttyShort != "unknown" { keys.append(ttyShort) }

        // Prefer title-match (precise targeting when Screen Recording is granted).
        for entry in app {
            let title = (entry.w[kCGWindowName as String] as? String) ?? ""
            if title.isEmpty { continue }
            for key in keys where title.localizedCaseInsensitiveContains(key) {
                if let r = rect(from: entry.w),
                   isWindowVisible(at: entry.index, frame: r, in: list) {
                    return r
                }
            }
        }
        // Fallback: largest window of the app, gated by occlusion.
        let largest = app.compactMap { entry -> (Int, CGRect)? in
            guard let r = rect(from: entry.w) else { return nil }
            return (entry.index, r)
        }.max { a, b in a.1.area < b.1.area }
        guard let best = largest else { return nil }
        return isWindowVisible(at: best.0, frame: best.1, in: list) ? best.1 : nil
    }

    /// PID of the bridge process itself. Used to filter our own windows out of
    /// the occluder set (the wire panel covers all screens — without this it
    /// would make every other window look 100% occluded).
    private let ownPid: pid_t = ProcessInfo.processInfo.processIdentifier

    /// Per-session sticky window choice. Without this, every recompute picks the
    /// "largest of the app" or "first title match," and switching focus to a
    /// different terminal/Chrome window of the same app makes the wire jump to
    /// it. Cache once at bind/first-frame, reuse until that specific windowID
    /// disappears (window closed).
    private var stickyTerminalWindowId: [String: CGWindowID] = [:]
    private var stickyChromeWindowId: [String: CGWindowID] = [:]

    /// True when at least 50% of `frame` is visible — i.e. windows above this one
    /// in z-order (earlier indices in the front-to-back `list`) cover less than
    /// half of it. Conservative: we sum intersection areas without subtracting
    /// double-overlap regions, so the visible-area estimate is a lower bound.
    /// That's the right side to err on for our use case — better to show a
    /// summon dot occasionally than draw a wire into a buried window.
    private func isWindowVisible(at index: Int, frame: CGRect, in list: [[String: Any]]) -> Bool {
        let area = frame.area
        if area <= 0 { return false }
        var occluded: CGFloat = 0
        for i in 0..<index {
            // Skip our own windows — the full-screen wire panel and the popover
            // would otherwise count as 100% occluders for every other window.
            let ownerPid = (list[i][kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            if ownerPid == ownPid { continue }
            guard let occluder = rect(from: list[i]) else { continue }
            let intersect = frame.intersection(occluder)
            if !intersect.isNull && intersect.width > 0 && intersect.height > 0 {
                occluded += intersect.area
                if occluded / area >= 0.5 { return false }  // early-out
            }
        }
        return true
    }

    private func rect(from window: [String: Any]) -> CGRect? {
        guard let bd = window[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return CGRect(x: bd["X"] ?? 0, y: bd["Y"] ?? 0, width: bd["Width"] ?? 0, height: bd["Height"] ?? 0)
    }

    /// Resolve the per-session window frame using the sticky cache when available.
    /// If the cached windowID is still present (same owner, visible enough), use
    /// it. Otherwise call `pickFresh` to choose a new window and cache its id.
    /// This is what makes the wire stay anchored to the SPECIFIC window the user
    /// originally bound, not jump to whichever sibling window of the app is
    /// currently focused.
    private func stickyWindowFrame(
        sessionId: String,
        cache: ReferenceWritableKeyPath<WireOverlayController, [String: CGWindowID]>,
        ownerPid: pid_t,
        in list: [[String: Any]],
        pickFresh: () -> CGRect?
    ) -> CGRect? {
        if let cached = self[keyPath: cache][sessionId] {
            for (idx, w) in list.enumerated() {
                let wid = windowID(of: w)
                if wid == cached {
                    let owner = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
                    if owner != ownerPid { break }  // stale cache (PID changed)
                    if let r = rect(from: w),
                       isWindowVisible(at: idx, frame: r, in: list) {
                        return r
                    }
                    return nil  // window exists but isn't visible enough — summon dot
                }
            }
            // Window with that ID is gone (closed). Fall through and re-pick.
            self[keyPath: cache].removeValue(forKey: sessionId)
        }

        guard let fresh = pickFresh() else { return nil }
        // Find the window in the list whose frame matches what pickFresh returned,
        // and cache its ID for stability on subsequent ticks.
        for w in list {
            let owner = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            if owner != ownerPid { continue }
            if let r = rect(from: w), r == fresh, let wid = windowID(of: w) {
                self[keyPath: cache][sessionId] = wid
                break
            }
        }
        return fresh
    }

    private func windowID(of window: [String: Any]) -> CGWindowID? {
        guard let n = window[kCGWindowNumber as String] as? NSNumber else { return nil }
        return CGWindowID(n.uint32Value)
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}

extension WireOverlayController {

    // MARK: - Window discovery

    /// CGWindowList returns frames in screen coordinates with origin at the TOP-left
    /// of the primary display (Y grows downward). Convert to NSScreen-style
    /// coordinates (bottom-left origin), then to the overlay panel's coordinate
    /// space (which is in NSScreen coords, with origin = unionScreenFrame.origin).
    private func canvasPoint(from screenTopLeftPoint: CGPoint) -> CGPoint {
        // Primary screen's frame.origin.y in flipped coords is screenFrame's max y.
        let unionMaxY = screenFrame.maxY
        let nsY = unionMaxY - screenTopLeftPoint.y
        // Canvas coords: SwiftUI Canvas inside the panel uses top-left origin.
        // Panel's content rect spans [0, frame.size.height] with top at the union top.
        let canvasY = unionMaxY - nsY
        let canvasX = screenTopLeftPoint.x - screenFrame.minX
        return CGPoint(x: canvasX, y: canvasY)
    }

    /// Find the largest on-screen window owned by `pid` that's also substantially
    /// VISIBLE — not covered >50% by other windows above it in z-order. Returns
    /// nil if there's no such window or the candidate is too occluded; the caller
    /// treats nil as "draw a summon dot instead of a wire."
    private func frontmostWindowFrame(forOwnerPid pid: pid_t, in list: [[String: Any]]) -> CGRect? {
        // Collect this app's normal-layer windows.
        var candidates: [(index: Int, frame: CGRect)] = []
        for (idx, w) in list.enumerated() {
            let owner = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            if owner != pid { continue }
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if layer != 0 { continue }
            guard let r = rect(from: w) else { continue }
            candidates.append((idx, r))
        }
        if candidates.isEmpty { return nil }
        // Pick the largest by area (matches the heuristic we used before).
        candidates.sort { $0.frame.area > $1.frame.area }
        let best = candidates[0]
        return isWindowVisible(at: best.index, frame: best.frame, in: list) ? best.frame : nil
    }

    /// session.pid is the shell PID; the terminal APP that owns the window is an
    /// ancestor. Walk up via `sysctl` until we hit a known terminal bundle.
    private func resolvedTerminalAppPid(for session: TerminalSession) -> pid_t {
        var pid: pid_t = pid_t(session.pid)
        for _ in 0..<8 {
            if let app = NSRunningApplication(processIdentifier: pid),
               let bid = app.bundleIdentifier,
               TextInjection.isTerminalApp(bundleId: bid) {
                return pid
            }
            let parent = parentPID(of: pid)
            if parent <= 1 { break }
            pid = parent
        }
        return pid_t(session.pid)
    }

    private func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { ptr -> Int32 in
            sysctl(ptr.baseAddress, u_int(ptr.count), &info, &size, nil, 0)
        }
        if result != 0 || size == 0 { return -1 }
        return info.kp_eproc.e_ppid
    }
}

// MARK: - Wire model

struct WirePair: Identifiable, Equatable {
    let id: String       // session id
    let start: CGPoint   // attach point on the terminal window edge
    let end: CGPoint     // attach point on the Chrome window edge
}

/// Drawn when one side of a binding isn't visible on the current Space. Clickable —
/// taps activate the missing app and AX-raise the specific bound window.
struct SummonDot: Identifiable, Equatable {
    /// Target identifies the app (pid) and optionally the SPECIFIC window
    /// within it (CGWindowID). Without windowId, AX raises the first window
    /// of the app — fine for Chrome with our isolated profile (one window per
    /// process), wrong for multi-window terminals.
    struct Summon: Equatable {
        let pid: pid_t
        let windowId: CGWindowID?
    }
    let id: String
    let position: CGPoint
    let summon: Summon
    let label: String
}

// MARK: - Canvas view

/// SwiftUI Canvas that draws each wire as a clean dotted bezier. One wire per
/// binding. Dot direction encodes data-flow direction:
///   - idle             → slow ambient drift terminal → browser
///   - outbound active  → fast flow terminal → browser  (Claude using MCP)
///   - inbound active   → fast flow browser → terminal  (inspector inject)
struct WireOverlay: View {
    @ObservedObject var controller: WireOverlayController

    var body: some View {
        let theme = controller.visualTheme
        ZStack(alignment: .topLeading) {
            TimelineView(.animation(minimumInterval: 1/60)) { context in
                Canvas { ctx, size in
                    let now = context.date.timeIntervalSinceReferenceDate
                    for wire in controller.wires {
                        let pulse = controller.activityPulse(for: wire.id, at: Date())
                        drawWire(in: &ctx, wire: wire, time: now,
                                 pulse: pulse, theme: theme)
                    }
                }
            }
            .allowsHitTesting(false)

            // Clickable summon dots — only shown when the partner window isn't
            // visible on the current Space.
            ForEach(controller.summonDots) { dot in
                Button {
                    controller.summon(dot.summon)
                } label: {
                    Circle()
                        .fill(theme.accentColor)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().fill(theme.backgroundColor).frame(width: 4, height: 4))
                        .overlay(Circle().stroke(theme.foregroundColor.opacity(0.35), lineWidth: 0.75))
                        .shadow(color: theme.accentColor.opacity(0.18), radius: 3)
                }
                .buttonStyle(.plain)
                .help(dot.label)
                .position(dot.position)
            }
        }
        .frame(width: max(controller.screenFrame.width, 1),
               height: max(controller.screenFrame.height, 1))
    }

    private func drawWire(in ctx: inout GraphicsContext, wire: WirePair,
                          time: TimeInterval, pulse: ActivityDirection?,
                          theme: BridgeVisualTheme) {
        let wireColor = theme.accentColor
        var path = Path()
        path.move(to: wire.start)
        let dx = wire.end.x - wire.start.x
        let pull = max(80, abs(dx) * 0.45)
        let c1 = CGPoint(x: wire.start.x + (dx >= 0 ? pull : -pull), y: wire.start.y)
        let c2 = CGPoint(x: wire.end.x   - (dx >= 0 ? pull : -pull), y: wire.end.y)
        path.addCurve(to: wire.end, control1: c1, control2: c2)

        // Solid blue stroke. Activity direction is encoded by an animated
        // gradient overlay (a brighter "comet" sliding along the wire),
        // not by dash motion — solid lines feel calmer and more architectural.
        ctx.stroke(path,
                   with: .color(wireColor.opacity(0.72)),
                   style: StrokeStyle(lineWidth: 1.8,
                                       lineCap: .round,
                                       lineJoin: .round))

        // Active pulse: overlay a brighter gradient that slides along the path.
        // Solid line + sliding bright spot reads as "data flowing" without
        // the busyness of a fully-dashed line.
        if let pulse = pulse {
            let speed: CGFloat = pulse == .outbound ? -1.6 : 1.6
            let phase = CGFloat(time) * speed
            // Phase wraps 0..1 along the path's length; gradient highlight
            // shifts with phase to suggest motion.
            let gradient = Gradient(stops: [
                .init(color: wireColor.opacity(0), location: 0),
                .init(color: theme.foregroundColor.opacity(0.78), location: 0.5),
                .init(color: wireColor.opacity(0), location: 1),
            ])
            let pStart = CGPoint(x: wire.start.x + (wire.end.x - wire.start.x) * (phase.truncatingRemainder(dividingBy: 1)),
                                 y: wire.start.y)
            let pEnd = CGPoint(x: pStart.x + (wire.end.x - wire.start.x) * 0.18,
                               y: wire.start.y + (wire.end.y - wire.start.y) * 0.18)
            ctx.stroke(path,
                       with: .linearGradient(gradient,
                                             startPoint: pStart,
                                             endPoint: pEnd),
                       style: StrokeStyle(lineWidth: 1.8,
                                          lineCap: .round,
                                          lineJoin: .round))
        }

        // Endpoint plugs — solid blue dot with a small white pip. Slightly bigger
        // when activity is firing so the user feels the "ping."
        let active = pulse != nil
        let r: CGFloat = active ? 6.5 : 5
        for end in [wire.start, wire.end] {
            let outer = CGRect(x: end.x - r, y: end.y - r, width: r*2, height: r*2)
            ctx.fill(Path(ellipseIn: outer), with: .color(wireColor))
            ctx.stroke(Path(ellipseIn: outer),
                       with: .color(theme.foregroundColor.opacity(0.32)),
                       lineWidth: 0.75)
            let pip: CGFloat = 1.8
            let inner = CGRect(x: end.x - pip, y: end.y - pip, width: pip*2, height: pip*2)
            ctx.fill(Path(ellipseIn: inner), with: .color(theme.backgroundColor))
        }
    }
}
