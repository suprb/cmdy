import AppKit
import ProductIdentity
import SwiftUI
import CmdyKit

/// Drag-to-dock: drag a Cmdy terminal, native tab, or editor window
/// over a terminal window and drop zones light up: left/right/top/bottom
/// edges split, while the center tabs terminals or attaches editors.
///
/// Two kinds of drags are detected by a cheap poll while the mouse is down:
///  - a real window drag (the window's origin moves each tick), and
///  - a native tab drag, where AppKit drags a PREVIEW window that exists in
///    the window server under our pid but not in NSApp.windows — the real
///    window only lands at drop, so we merge it a beat after mouse-up.
/// Sidebar cards add a third, explicit source: their backing NSWindow may be
/// hidden and never moves, so the card announces the live controller directly.
@MainActor
final class WindowDock {
    static let shared = WindowDock()

    enum Zone {
        case left, right, top, bottom, tab

        var side: TerminalWindowController.DockSide? {
            switch self {
            case .left: return .left
            case .right: return .right
            case .top: return .top
            case .bottom: return .bottom
            case .tab: return nil
            }
        }
    }

    private var overlay: DockOverlayWindow?
    private var sidebarTabPreview: SidebarTabDragPreviewWindow?
    private weak var draggedWindow: NSWindow?     // real window being dragged, if any
    /// Once a plain window drag enters Window Grid, keep that exact window as
    /// the source while its neighbors animate underneath the pointer.
    private weak var gridDraggedWindow: NSWindow?
    /// The dragged window is hidden from the window server — the signature of a
    /// native tab tear-off (AppKit shows a preview and moves the real window
    /// silently; it only materializes at drop).
    private var draggedWasHidden = false
    private var tabDragActive = false             // preview-only drag (no mover found)
    private weak var sidebarDraggedController: TerminalWindowController?
    private weak var paneDraggedController: TerminalWindowController?
    private weak var paneDraggedPane: TerminalPane?
    private weak var targetWindow: NSWindow?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var releaseWatchdog: Timer?
    private var lastEventTick = CFAbsoluteTimeGetCurrent()
    private var lastOrigins: [Int: NSPoint] = [:]
    private var lastPhantomOrigin: NSPoint?
    private var wasDown = false
    /// A native tab preview is not itself a dockable window, so later ticks
    /// cannot identify the payload from the mover alone. Remember whether the
    /// gesture began in a real terminal/editor and reject every other window
    /// before the preview heuristics run.
    private var dragSourceEligible = false

    /// `--ui-test-overlay`: attach the zone HUD to the key window for a few
    /// seconds with the "left" zone highlighted (drawing-path diagnostics).
    func showTestOverlay(over window: NSWindow) {
        if overlay == nil { overlay = DockOverlayWindow() }
        overlay?.attach(to: window)
        overlay?.update(mouseInScreen: NSPoint(x: window.frame.minX + 40,
                                               y: window.frame.midY))
        NSLog("DOCK test overlay visible=%d frame=%@ level=%ld",
              overlay?.isVisible == true ? 1 : 0,
              NSStringFromRect(overlay?.frame ?? .zero),
              overlay?.level.rawValue ?? -1)
    }

    /// Arm drag-to-dock for a custom Navigator card after SwiftUI crosses its
    /// drag threshold. This object owns the structural result so the existing
    /// controller, split tree, PTYs, and scrollback move intact rather than
    /// being reconstructed from a snapshot.
    func beginSidebarTabDrag(_ controller: TerminalWindowController) {
        sidebarDraggedController = controller
        draggedWindow = controller.window
        draggedWasHidden = controller.window?.isVisible != true
        tabDragActive = false
        dragSourceEligible = true
        // The gesture begins only after SwiftUI crosses its drag threshold, so
        // the session is active even if the global button bit is updated a
        // fraction later on this run-loop turn.
        wasDown = true
        lastOrigins = Dictionary(uniqueKeysWithValues: NSApp.windows.map {
            ($0.windowNumber, $0.frame.origin)
        })
        DispatchQueue.main.async { [weak self] in
            guard self?.sidebarDraggedController != nil else { return }
            self?.tick()
        }
    }

    /// SwiftUI normally delivers mouse-up through the local event monitor;
    /// ending from the gesture as well covers releases outside the source
    /// window. Whichever path arrives second is an intentional no-op.
    func endSidebarTabDrag() {
        guard sidebarDraggedController != nil else { return }
        wasDown = false
        dragEnded()
    }

    /// Arm the same area dropper for one live split pane. The pane stays in
    /// its source tree until mouse-up, so a cancelled drag is a true no-op.
    /// A successful drop transfers the existing view, PTY, and scrollback.
    func beginPaneDrag(
        _ pane: TerminalPane,
        from controller: TerminalWindowController
    ) {
        guard controller.panes.count > 1,
              controller.panes.contains(where: { $0 === pane }),
              pane.window === controller.window else { return }
        paneDraggedController = controller
        paneDraggedPane = pane
        draggedWindow = controller.window
        draggedWasHidden = false
        tabDragActive = false
        dragSourceEligible = true
        wasDown = true
        lastOrigins = Dictionary(uniqueKeysWithValues: NSApp.windows.map {
            ($0.windowNumber, $0.frame.origin)
        })
        showPaneDragPreview(pane)
        DispatchQueue.main.async { [weak self] in
            guard self?.paneDraggedPane != nil else { return }
            self?.tick()
        }
    }

    func endPaneDrag() {
        guard paneDraggedPane != nil else { return }
        wasDown = false
        dragEnded()
    }

    /// NSPanGestureRecognizer owns the drag stream while the pointer is over
    /// the pane affordance, so update the area dropper directly as well as via
    /// the ordinary local/global event monitors.
    func updatePaneDrag() {
        guard paneDraggedPane != nil else { return }
        tick()
    }

    private func showPaneDragPreview(_ pane: TerminalPane) {
        pane.layoutSubtreeIfNeeded()
        let bounds = pane.bounds.integral
        guard bounds.width > 1, bounds.height > 1,
              let representation = pane.bitmapImageRepForCachingDisplay(in: bounds)
        else { return }
        pane.cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        let scale = min(1, 360 / bounds.width, 240 / bounds.height)
        let size = NSSize(
            width: max(120, bounds.width * scale),
            height: max(80, bounds.height * scale))
        _ = showSidebarTabDragPreview(
            AnyView(
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()),
            size: size,
            anchor: CGPoint(x: 0.94, y: 0.08))
    }

    /// SwiftUI normally publishes the exact card frame before a gesture can
    /// cross its threshold. During the first layout pass that preference can
    /// still be zero, so derive the same card geometry from the live Navigator
    /// width rather than dropping the visual affordance entirely.
    func sidebarTabDragPreviewSize(measured: NSSize) -> NSSize {
        if measured.width > 1, measured.height > 1 {
            return measured
        }
        let width = max(
            120,
            sidebarDraggedController?.workspaceRailGeometry()
                .navigatorWidth ?? 220)
        let miniatureWidth = max(76, width - 44)
        return NSSize(
            width: width,
            height: max(54, miniatureWidth / 1.72 + 10))
    }

    /// Show a cmdy-owned representation of the exact Navigator card. Unlike a
    /// pasteboard drag image, this preview cannot perform AppKit's failed-drop
    /// return animation; it simply vanishes when the structural drop finishes.
    @discardableResult
    func showSidebarTabDragPreview(
        _ content: AnyView,
        size: NSSize,
        anchor: CGPoint
    ) -> Bool {
        guard sidebarDraggedController != nil || paneDraggedPane != nil,
              size.width > 1, size.height > 1 else { return false }
        sidebarTabPreview?.orderOut(nil)
        let preview = SidebarTabDragPreviewWindow(
            content: content,
            size: size,
            anchor: anchor,
            appearance: (sidebarDraggedController ?? paneDraggedController)?
                .window?.effectiveAppearance)
        sidebarTabPreview = preview
        preview.show(at: NSEvent.mouseLocation)
        if Self.debug {
            NSLog(
                "DOCK sidebar preview visible=%d frame=%@",
                preview.isVisible ? 1 : 0,
                NSStringFromRect(preview.frame))
        }
        return preview.isVisible
    }

    func start() {
        // Keep the overlay out of the WindowServer until a real docking drag.
        // Even a transparent ordered utility window makes Mission Control
        // calculate a pathological overview on current macOS releases.
        let o = DockOverlayWindow()
        o.park()
        overlay = o

        guard localMouseMonitor == nil else { return }
        let mouseMask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseDragged, .leftMouseUp,
        ]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: mouseMask.union(.keyDown)
        ) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: mouseMask
        ) { [weak self] event in
            self?.handleMouseEvent(event)
        }
        let watchdog = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.wasDown else { return }
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    self.wasDown = false
                    self.dragEnded()
                } else if self.sidebarDraggedController != nil
                            || self.paneDraggedPane != nil {
                    // NSDraggingSession can coalesce the ordinary dragged
                    // events. Polling keeps the area dropper glued to the
                    // pointer even while the card preview is momentarily still.
                    self.tick()
                }
            }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        releaseWatchdog = watchdog
    }

    private func handleMouseEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            wasDown = true
            dragSourceEligible = Self.acceptsDragSource(event.window)
            lastOrigins = Dictionary(uniqueKeysWithValues: NSApp.windows.map {
                ($0.windowNumber, $0.frame.origin)
            })
        case .leftMouseDragged:
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastEventTick >= 1.0 / 60.0 else { return }
            lastEventTick = now
            tick()
        case .leftMouseUp:
            guard wasDown else { return }
            wasDown = false
            dragEnded()
        case .keyDown:
            if event.keyCode == 53 {
                (NSApp.delegate as? AppDelegate)?
                    .windowGridCoordinator.cancelDrag(window: gridDraggedWindow)
                cancelSidebarTabDrag()
            }
        default:
            break
        }
    }

    func cancelSidebarTabDrag() {
        sidebarDraggedController = nil
        paneDraggedController = nil
        paneDraggedPane = nil
        draggedWindow = nil
        gridDraggedWindow = nil
        draggedWasHidden = false
        tabDragActive = false
        dragSourceEligible = false
        lastPhantomOrigin = nil
        wasDown = false
        dismissSidebarTabDragPreview()
        hideOverlay()
    }

    private func dismissSidebarTabDragPreview() {
        sidebarTabPreview?.orderOut(nil)
        sidebarTabPreview = nil
    }

    private var terminalWindows: [NSWindow] {
        NSApp.orderedWindows.filter { $0.isVisible && $0.windowController is TerminalWindowController }
    }

    static func acceptsDragSource(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.windowController is TerminalWindowController
            || window.windowController is CmdyEditorWindowController
    }

    private static let debug =
        ProductIdentity.current.environmentValue("DOCK_DEBUG") == "1"
    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 == 1
        guard down else {
            if wasDown {
                wasDown = false
                dragEnded()
            } else {
                hideOverlay()
            }
            return
        }
        adoptActiveGridSource()
        guard dragSourceEligible else {
            hideOverlay()
            return
        }

        let mouse = NSEvent.mouseLocation
        sidebarTabPreview?.move(to: mouse)
        // ALL terminal windows (a mid-tear-off tab window may report !isVisible)…
        let allTerms = NSApp.windows.filter { $0.windowController is TerminalWindowController }
        // …but the window server decides what the USER can actually see.
        let onScreen = onScreenWindowNumbers()
        let terms = allTerms.filter { onScreen.contains($0.windowNumber) }
        if Self.debug {
            let known = Set(NSApp.windows.map { $0.windowNumber })
            let cg = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                .filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(ProcessInfo.processInfo.processIdentifier) }
                .map { info -> String in
                    let n = info[kCGWindowNumber as String] as? Int ?? -1
                    let b = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
                    let name = info[kCGWindowName as String] as? String ?? ""
                    return "cg#\(n)\(known.contains(n) ? "" : "*PHANTOM*") '\(name)' \(Int(b["W­idth"] ?? b["Width"] ?? 0))x\(Int(b["Height"] ?? 0)) @(\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)))"
                }
            NSLog("DOCK tick mouse=(%d,%d) terms=%d dragged=%@ tabDrag=%d | %@",
                  Int(mouse.x), Int(mouse.y), terms.count,
                  draggedWindow.map { String($0.windowNumber) } ?? "nil",
                  tabDragActive ? 1 : 0, cg.joined(separator: " | "))
        }

        // Anything of ours whose origin moved since the last tick — terminal
        // windows AND AppKit's private windows (the tab-drag preview is a small
        // untitled NSWindow that carries the tab while the real window hides).
        let appWindows = NSApp.windows.filter { $0 !== overlay }
        let movers = appWindows.filter { w in
            lastOrigins[w.windowNumber].map { $0 != w.frame.origin } ?? false
        }
        lastOrigins = Dictionary(uniqueKeysWithValues: appWindows.map { ($0.windowNumber, $0.frame.origin) })

        // A tab mid-tear-off: hidden from the screen, not miniaturized, and no
        // longer part of a tab group. That state exists ONLY during the drag.
        let detachedTabs = allTerms.filter { w in
            !onScreen.contains(w.windowNumber) && !w.isMiniaturized
                && (w.tabGroup?.windows.count ?? 1) <= 1
        }
        let previewMoving = movers.contains { !Self.acceptsDragSource($0) }

        if let gridDraggedWindow {
            // Neighbor animations also move NSWindows. Do not let the mover
            // heuristic mistake one of those windows for the user's source.
            draggedWindow = gridDraggedWindow
            draggedWasHidden = false
            tabDragActive = false
        } else if let explicitSource = sidebarDraggedController ?? paneDraggedController {
            // A Navigator card moves a SwiftUI preview, not its backing
            // NSWindow. Keep the explicitly announced controller authoritative
            // even when that tab is an inactive, ordered-out window.
            draggedWindow = explicitSource.window
            draggedWasHidden = explicitSource.window?.isVisible != true
            tabDragActive = false
        } else {
            if let hiddenMover = movers.first(where: {
                m in detachedTabs.contains { $0 === m }
            }) {
                // The real window moves while hidden (some macOS versions do this).
                draggedWindow = hiddenMover
                draggedWasHidden = true
                tabDragActive = false
            } else if previewMoving, let detached = detachedTabs.first {
                // The preview carries the tab; the hidden detached window is the payload.
                draggedWindow = detached
                draggedWasHidden = true
                tabDragActive = false
            } else if previewMoving {
                // Preview moving but the payload still officially lives in its tab
                // group — arm positional mode; the landing window is caught at drop.
                draggedWindow = nil
                tabDragActive = true
            } else if let mover = movers.first(where: {
                Self.acceptsDragSource($0)
                    && onScreen.contains($0.windowNumber)
                    && !$0.inLiveResize
            }) {
                // A plain window drag.
                draggedWindow = mover
                draggedWasHidden = false
                tabDragActive = false
            } else if draggedWindow == nil && !tabDragActive {
                // Last resort: a window-server-only preview (not even in NSApp.windows).
                // NOTE: an armed tabDragActive stays armed while the cursor hovers
                // motionless — it only clears at mouse-up.
                tabDragActive = phantomDragWindowExists(near: mouse)
                if tabDragActive { draggedWindow = nil }
            }
        }

        guard draggedWindow != nil || tabDragActive else {
            hideOverlay()
            return
        }

        let isExplicitSurfaceDrag = sidebarDraggedController != nil
            || paneDraggedPane != nil
        let optionHeld = NSEvent.modifierFlags.contains(.option)

        // In grid mode an ordinary native window drag is structural: entering
        // a neighboring rectangle reorders the recursive layout. Option keeps
        // the existing merge-to-tab/split gesture available.
        if !isExplicitSurfaceDrag, !draggedWasHidden, !tabDragActive,
           let draggedWindow,
           !draggedWindow.inLiveResize,
           let delegate = NSApp.delegate as? AppDelegate {
            if optionHeld, gridDraggedWindow != nil {
                delegate.windowGridCoordinator.cancelDrag(window: draggedWindow)
                gridDraggedWindow = nil
            } else if !optionHeld,
                      delegate.windowGridCoordinator.updateDrag(
                        window: draggedWindow, mouse: mouse) {
                gridDraggedWindow = draggedWindow
                hideOverlay()
                return
            }
        }

        // Topmost VISIBLE terminal window under the cursor, excluding the drag.
        // Sidebar cards use only the central workspace as a target; their
        // originating rail, the Inspector, and the title band are cancel areas.
        let target = terms.first { w in
            guard w !== draggedWindow else { return false }
            if isExplicitSurfaceDrag,
               let controller = w.windowController as? TerminalWindowController {
                return controller.workspaceDockTargetScreenFrame?
                    .contains(mouse) == true
            }
            return w.frame.contains(mouse)
        }
        guard let target else { hideOverlay(); return }

        // A tab drag hovering the target's own TAB BAR is just a reorder —
        // only content-area hovers arm the zones.
        if tabDragActive || draggedWasHidden {
            let inWindow = NSPoint(x: mouse.x - target.frame.minX, y: mouse.y - target.frame.minY)
            if inWindow.y > target.contentLayoutRect.maxY { hideOverlay(); return }
        }

        targetWindow = target
        if overlay == nil { overlay = DockOverlayWindow() }
        overlay?.attach(to: target,
                        screenFrame: isExplicitSurfaceDrag
                            ? (target.windowController as? TerminalWindowController)?
                                .workspaceDockTargetScreenFrame
                            : nil,
                        centerAttachesEditor: draggedWindow?.windowController
                            is CmdyEditorWindowController)
        overlay?.update(mouseInScreen: mouse)
        if Self.debug, let o = overlay {
            NSLog("DOCK overlay on #%d zone=%@ visible=%d frame=%@ number=%d",
                  target.windowNumber, String(describing: o.activeZone),
                  o.isVisible ? 1 : 0, NSStringFromRect(o.frame), o.windowNumber)
        }
    }

    /// NSWindowDelegate identifies the real source before the mover poll. A
    /// nested grid can animate four or more neighbors simultaneously, so keep
    /// that source sticky rather than allowing a moving neighbor to win array
    /// order on the next tick.
    private func adoptActiveGridSource() {
        guard let activeGridWindow = (NSApp.delegate as? AppDelegate)?
            .windowGridCoordinator.activelyDraggedWindow else { return }
        gridDraggedWindow = activeGridWindow
        dragSourceEligible = true
    }

    func adoptActiveGridSourceForTesting() -> Bool {
        adoptActiveGridSource()
        guard let active = (NSApp.delegate as? AppDelegate)?
            .windowGridCoordinator.activelyDraggedWindow else { return false }
        return gridDraggedWindow === active
    }

    /// Window numbers of our windows the window server is actually showing.
    private func onScreenWindowNumbers() -> Set<Int> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let myPid = Int(ProcessInfo.processInfo.processIdentifier)
        return Set(list.compactMap { info in
            (info[kCGWindowOwnerPID as String] as? Int) == myPid
                ? info[kCGWindowNumber as String] as? Int : nil
        })
    }

    /// True when the window server shows a moving window of ours that AppKit
    /// hasn't told us about (the native tab-drag preview).
    private func phantomDragWindowExists(near mouse: NSPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let myPid = Int(ProcessInfo.processInfo.processIdentifier)
        let known = Set(NSApp.windows.map { $0.windowNumber })
        guard let screenHeight = NSScreen.screens.first?.frame.maxY else { return false }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int) == myPid,
                  let number = info[kCGWindowNumber as String] as? Int,
                  !known.contains(number),
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            // CG coords are top-left origin; flip to AppKit's bottom-left.
            let rect = NSRect(x: b["X"] ?? 0,
                              y: screenHeight - (b["Y"] ?? 0) - (b["Height"] ?? 0),
                              width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard rect.width > 40, rect.height > 20 else { continue }
            if rect.insetBy(dx: -30, dy: -30).contains(mouse) {
                let origin = rect.origin
                defer { lastPhantomOrigin = origin }
                // It must actually be moving with the drag, not just floating.
                // Merely appearing is not enough: accessibility panels and
                // transient AppKit windows can sit near the pointer. A native
                // tab preview must move with the drag across two observations.
                if let prev = lastPhantomOrigin, prev != origin { return true }
            }
        }
        return false
    }

    private func hideOverlay() {
        overlay?.detach()
        targetWindow = nil
    }

    private func dragEnded() {
        let gridCoordinator = (NSApp.delegate as? AppDelegate)?
            .windowGridCoordinator
        let zone = overlay?.activeZone
        let dragged = gridDraggedWindow
            ?? gridCoordinator?.activelyDraggedWindow
            ?? draggedWindow
        let wasGridDrag = gridCoordinator?.isDragging(window: dragged) == true
        let hidden = draggedWasHidden
        let target = targetWindow
        let wasTabDrag = tabDragActive
        let sidebarSource = sidebarDraggedController
        let paneSource = paneDraggedController
        let draggedPane = paneDraggedPane
        let drop = NSEvent.mouseLocation
        draggedWindow = nil
        gridDraggedWindow = nil
        draggedWasHidden = false
        tabDragActive = false
        sidebarDraggedController = nil
        paneDraggedController = nil
        paneDraggedPane = nil
        dragSourceEligible = false
        lastPhantomOrigin = nil
        dismissSidebarTabDragPreview()
        hideOverlay()

        if wasGridDrag {
            gridCoordinator?.endDrag(window: dragged)
            return
        }

        if let sidebarSource,
           let delegate = NSApp.delegate as? AppDelegate {
            if let zone, let target,
               let destination = target.windowController
                    as? TerminalWindowController,
               destination !== sidebarSource {
                _ = delegate.moveWorkspaceTab(
                    sidebarSource, into: destination, side: zone.side)
            } else {
                // Releasing over any existing app window but outside its
                // central drop surface means "cancel", not "spawn a window".
                // This makes tiny drags inside the sidebar harmless.
                let remainsInsideApp = terminalWindows.contains {
                    $0.frame.contains(drop)
                }
                if !remainsInsideApp {
                    _ = delegate.tearOutWorkspaceTab(sidebarSource, at: drop)
                }
            }
            return
        }

        if let paneSource, let draggedPane {
            let delegate = NSApp.delegate as? AppDelegate
            if let zone, let target,
               let destination = target.windowController
                    as? TerminalWindowController,
               destination !== paneSource,
               let pane = paneSource.releasePaneForMove(draggedPane.paneId) {
                destination.adopt(pane, side: zone.side ?? .right)
                if paneSource.isEmptyAfterPaneMove {
                    paneSource.approveNextWindowClose()
                    paneSource.window?.close()
                }
                destination.window?.makeKeyAndOrderFront(nil)
                delegate?.refreshActionsMenu()
            } else {
                let remainsInsideApp = terminalWindows.contains {
                    $0.frame.contains(drop)
                }
                if !remainsInsideApp {
                    _ = paneSource.tearOutPane(draggedPane, at: drop)
                }
            }
            return
        }

        guard let zone, let target,
              let dst = target.windowController as? TerminalWindowController else { return }

        if let dragged, dragged !== target {
            if dragged.windowController is CmdyEditorWindowController {
                DispatchQueue.main.async { [weak self] in
                    _ = self?.dockEditorWindow(dragged, into: target, zone: zone)
                }
                return
            }
            if hidden {
                // Torn-off tab: AppKit materializes the window at the drop
                // point right after mouse-up. Keep it invisible for the beat
                // it takes to land, then merge — no standalone-window flash.
                dragged.alphaValue = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    dst.merge(window: dragged, side: zone.side)
                    dragged.alphaValue = 1   // relevant when it lands as a tab
                }
            } else {
                // Plain window drop — merge once the drag fully settles.
                DispatchQueue.main.async { dst.merge(window: dragged, side: zone.side) }
            }
        } else if wasTabDrag {
            // Preview-only drag: poll briefly for the window AppKit lands at
            // the cursor, hide it the instant it appears, then merge.
            adoptLanding(target: target, dst: dst, zone: zone,
                         drop: NSEvent.mouseLocation, attempt: 0)
        }
    }

    /// Shared by the mouse-drop path and the real-window UI smoke test.
    @discardableResult
    func dockEditorWindow(_ source: NSWindow, into target: NSWindow, zone: Zone) -> Bool {
        guard let editorController = source.windowController as? CmdyEditorWindowController,
              let editor = editorController.editorPane,
              let terminal = target.windowController as? TerminalWindowController else {
            return false
        }
        CmdyEditorManager.shared.attachEditor(
            editor, to: terminal, side: zone.side ?? .right)
        return editor.isAttached && editor.window === target
    }

    private func adoptLanding(target: NSWindow, dst: TerminalWindowController,
                              zone: Zone, drop: NSPoint, attempt: Int) {
        if let landed = terminalWindows.first(where: { w in
            w !== target && w.frame.insetBy(dx: -60, dy: -60).contains(drop)
                && (w.tabGroup?.windows.count ?? 1) <= 1
        }) {
            if Self.debug {
                NSLog("DOCK landing #%d -> #%d zone=%@ (attempt %d)",
                      landed.windowNumber, target.windowNumber,
                      String(describing: zone), attempt)
            }
            landed.alphaValue = 0   // no standalone-window flash
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                dst.merge(window: landed, side: zone.side)
                landed.alphaValue = 1   // relevant when it lands as a tab
            }
        } else if attempt < 12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.adoptLanding(target: target, dst: dst, zone: zone,
                                   drop: drop, attempt: attempt + 1)
            }
        }
    }
}

/// A short-lived, noninteractive drag affordance owned by cmdy. It follows the
/// pointer at drag-window level, eases down to 94%, and is removed immediately
/// on mouse-up so there is never a return-to-sidebar animation.
private final class SidebarTabDragPreviewWindow: NSWindow {
    private let pointerAnchor: CGPoint

    init(
        content: AnyView,
        size: NSSize,
        anchor: CGPoint,
        appearance: NSAppearance?
    ) {
        pointerAnchor = anchor
        let root = SidebarTabDragPreviewContent(content: content)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.draggingWindow)))
        collectionBehavior = [
            .transient, .ignoresCycle, .fullScreenAuxiliary,
        ]
        isExcludedFromWindowsMenu = true
        isReleasedWhenClosed = false
        self.appearance = appearance
        contentView = host
    }

    func show(at mouse: NSPoint) {
        move(to: mouse)
        orderFront(nil)
    }

    func move(to mouse: NSPoint) {
        setFrameOrigin(NSPoint(
            x: mouse.x - pointerAnchor.x * frame.width,
            y: mouse.y - (1 - pointerAnchor.y) * frame.height))
    }
}

private struct SidebarTabDragPreviewContent: View {
    let content: AnyView
    @State private var lifted = false

    var body: some View {
        content
            .scaleEffect(lifted ? 0.94 : 1)
            .opacity(0.96)
            .onAppear {
                withAnimation(.easeOut(duration: 0.12)) {
                    lifted = true
                }
            }
    }
}

/// The translucent drop-zone HUD shown over the target window.
private final class DockOverlayWindow: NSWindow {
    private let zoneView = DockZoneView()
    private(set) weak var host: NSWindow?
    private var explicitScreenFrame: NSRect?

    var activeZone: WindowDock.Zone? { zoneView.activeZone }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true    // never interfere with the drag itself
        hasShadow = false
        level = .floating            // stay visible above the drag preview
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        isExcludedFromWindowsMenu = true
        contentView = zoneView
    }

    /// Remove the helper from the WindowServer while idle. A transparent or
    /// offscreen ordered panel still participates in Mission Control layout.
    func park() {
        alphaValue = 0
        orderOut(nil)
        setFrame(.zero, display: false)
    }

    func attach(to target: NSWindow, screenFrame: NSRect? = nil,
                centerAttachesEditor: Bool = false) {
        host = target
        explicitScreenFrame = screenFrame
        zoneView.centerAttachesEditor = centerAttachesEditor
        setFrame(screenFrame ?? target.frame, display: true)
        alphaValue = 1
        if !isVisible { orderFrontRegardless() }
    }

    func detach() {
        host = nil
        explicitScreenFrame = nil
        zoneView.activeZone = nil
        park()
    }

    func update(mouseInScreen p: NSPoint) {
        setFrame(explicitScreenFrame ?? host?.frame ?? frame, display: false)
        let local = NSPoint(x: p.x - frame.minX, y: p.y - frame.minY)
        zoneView.update(mouse: local)
    }
}

/// Draws the five zones; the one under the cursor fills in.
private final class DockZoneView: NSView {
    var centerAttachesEditor = false {
        didSet { if centerAttachesEditor != oldValue { needsDisplay = true } }
    }
    var activeZone: WindowDock.Zone? {
        didSet { if activeZone != oldValue { needsDisplay = true } }
    }

    func update(mouse p: NSPoint) {
        let b = bounds
        guard b.contains(p) else { activeZone = nil; return }
        // Match the drawn rects: per-axis 24% bands, corners resolved by
        // whichever axis the cursor is deeper into.
        let inLeft = p.x < b.width * 0.24
        let inRight = p.x > b.width * 0.76
        let inTop = p.y > b.height * 0.76
        let inBottom = p.y < b.height * 0.24
        let xDepth = inLeft ? (b.width * 0.24 - p.x) / (b.width * 0.24)
                   : inRight ? (p.x - b.width * 0.76) / (b.width * 0.24) : 0
        let yDepth = inTop ? (p.y - b.height * 0.76) / (b.height * 0.24)
                   : inBottom ? (b.height * 0.24 - p.y) / (b.height * 0.24) : 0
        if xDepth > 0 || yDepth > 0 {
            if xDepth >= yDepth { activeZone = inLeft ? .left : .right }
            else { activeZone = inTop ? .top : .bottom }
        } else {
            activeZone = .tab
        }
    }

    private func zoneRect(_ zone: WindowDock.Zone) -> NSRect {
        let b = bounds.insetBy(dx: 10, dy: 10)
        switch zone {
        case .left: return NSRect(x: b.minX, y: b.minY, width: b.width * 0.24, height: b.height)
        case .right: return NSRect(x: b.maxX - b.width * 0.24, y: b.minY, width: b.width * 0.24, height: b.height)
        case .top: return NSRect(x: b.minX, y: b.maxY - b.height * 0.24, width: b.width, height: b.height * 0.24)
        case .bottom: return NSRect(x: b.minX, y: b.minY, width: b.width, height: b.height * 0.24)
        case .tab: return NSRect(x: b.midX - b.width * 0.14, y: b.midY - b.height * 0.14,
                                 width: b.width * 0.28, height: b.height * 0.28)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        for zone: WindowDock.Zone in [.left, .right, .top, .bottom, .tab] {
            let path = NSBezierPath(roundedRect: zoneRect(zone), xRadius: 10, yRadius: 10)
            if zone == activeZone {
                accent.withAlphaComponent(0.30).setFill()
                path.fill()
                accent.setStroke()
            } else {
                accent.withAlphaComponent(0.35).setStroke()
            }
            path.lineWidth = zone == activeZone ? 3 : 1.5
            path.stroke()
        }
        if let zone = activeZone {
            let text: String
            switch zone {
            case .left: text = "◧ Split Left"
            case .right: text = "◨ Split Right"
            case .top: text = "⬒ Split Top"
            case .bottom: text = "⬓ Split Bottom"
            case .tab: text = centerAttachesEditor ? "Attach Editor" : "⧉ Add as Tab"
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
            let size = (text as NSString).size(withAttributes: attrs)
            let r = zoneRect(zone)
            (text as NSString).draw(at: NSPoint(x: r.midX - size.width / 2,
                                                y: r.midY - size.height / 2),
                                    withAttributes: attrs)
        }
    }
}
