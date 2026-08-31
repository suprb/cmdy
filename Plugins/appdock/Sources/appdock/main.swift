import AppKit
import ApplicationServices
import CmdySDK

// appdock — dock ANY app's window into cmdy as a split. The chromium
// sidecar pattern, generalized: where chromium owned its CEF window and moved
// IT into the reserved strip, appdock moves a FOREIGN app's real window there
// through Accessibility. The terminal reflows around it (POST /v1/ui/inset),
// a thin grip on the seam resizes both sides, and an HTTP+MCP surface
// (DockAPI) lets agents launch / relaunch / inspect / drive the app they are
// building — the live thing, beside the conversation.

final class AppDock: NSObject, NSApplicationDelegate {
    private var cmdy: Cmdy!
    private var grip: NSWindow!            // the only window WE own — the divider
    private var gripView: DividerGrip!
    private var glue: Timer?
    private var glueInterval: TimeInterval = 0
    private let parentPid = getppid()
    private let api = DockAPI()

    // The adopted target.
    private var targetPid: pid_t?
    private var targetWindow: AXUIElement?
    private var savedFrame: CGRect?        // restore on undock
    private var urlPanelId: String?

    // Dock geometry (mirrors chromium): strip width + pane-area offsets from
    // the /v1/ui/inset response.
    private var dockWidth: CGFloat = 0
    private var postedInset: CGFloat = -1
    private var lastInsetPost = Date.distantPast
    private var dockTop: CGFloat = 44
    private var dockBottom: CGFloat = 27
    private var dockSide: CGFloat = 25
    private var dockTrailing: CGFloat = 0
    private var lastHost = NSRect.zero
    private var hotUntil = Date.distantPast
    private let pad: CGFloat = 10

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let sdk = Cmdy() else {
            fputs(
                "appdock: not launched by \(HostProductIdentity.slug) (missing \(HostProductIdentity.environmentPrefix)_* env)\n",
                stderr)
            exit(1)
        }
        cmdy = sdk
        makeGrip()

        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigTerm = src

        api.dockPid = { [weak self] pid in self?.adopt(pid: pid) ?? false }
        api.undock = { [weak self] in self?.releaseTarget() }
        api.currentTarget = { [weak self] in
            guard let self, let pid = self.targetPid, let win = self.targetWindow else { return nil }
            return (pid, win)
        }
        api.beforeScreenshot = { [weak self] in self?.tick() }
        api.start()

        cmdy.registerCommand(id: "appdock.pick", title: "Dock an App…", plugin: "AppDock")
        cmdy.registerCommand(id: "appdock.undock", title: "Undock", plugin: "AppDock")
        cmdy.registerHotKey(id: "appdock.pick", keyCode: 2 /* D */,
                               modifiers: [.command, .shift])
        cmdy.onEvent = { [weak self] event in self?.handle(event) }
        cmdy.listen()

        retime(0.1)
        NSLog("appdock: ready (waiting for a target)")

        if let name = HostProductIdentity.environmentValue("APPDOCK_AUTODOCK") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                _ = AXKit.trusted(prompt: true)
                if let app = NSWorkspace.shared.runningApplications
                    .first(where: { ($0.localizedName ?? "").lowercased() == name.lowercased() }) {
                    _ = self?.adopt(pid: app.processIdentifier)
                }
            }
        }
    }
    private var sigTerm: DispatchSourceSignal?

    // MARK: - The grip window (our only surface)

    private func makeGrip() {
        gripView = DividerGrip(frame: NSRect(x: 0, y: 0, width: 8, height: 400))
        gripView.onDrag = { [weak self] dx in self?.dividerDragged(dx) }
        gripView.onDragEnd = { [weak self] in self?.dividerDragEnded() }
        grip = NSWindow(contentRect: gripView.frame, styleMask: [.borderless],
                        backing: .buffered, defer: false)
        grip.contentView = gripView
        grip.isReleasedWhenClosed = false
        grip.backgroundColor = .clear
        grip.isOpaque = false
        grip.hasShadow = false
        grip.level = .floating
        grip.ignoresMouseEvents = false
        grip.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    }

    // MARK: - Adoption

    @discardableResult
    private func adopt(pid: pid_t) -> Bool {
        guard AXKit.trusted(prompt: false) else { return false }
        guard let window = AXKit.mainWindow(pid: pid) else { return false }
        // Remember where it was so undock can put it back.
        savedFrame = AXKit.frame(of: window)
        targetPid = pid
        targetWindow = window
        NSRunningApplication(processIdentifier: pid)?.activate()
        AXKit.raise(window)
        tick()
        return true
    }

    private func releaseTarget() {
        if let window = targetWindow, let frame = savedFrame {
            AXKit.setFrame(window, frame)   // put it back where it was
        }
        targetPid = nil
        targetWindow = nil
        savedFrame = nil
        postInset(0)
        grip.orderOut(nil)
    }

    // MARK: - Glue (hug cmdy's frontmost window; drive the target into the strip)

    private func cmdyWindowFrame() -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid == parentPid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            guard let primary = NSScreen.screens.first else { return nil }
            let h = b["Height"] ?? 0
            return NSRect(x: b["X"] ?? 0, y: primary.frame.height - (b["Y"] ?? 0) - h,
                          width: b["Width"] ?? 0, height: h)
        }
        return nil
    }

    private func currentDockWidth(for host: NSRect) -> CGFloat {
        if dockWidth == 0 { dockWidth = floor(host.width * 0.46) }
        return min(max(280, dockWidth), max(280, host.width - 420))
    }

    private func postInset(_ value: CGFloat) {
        if value == postedInset, Date().timeIntervalSince(lastInsetPost) < 2 { return }
        postedInset = value
        lastInsetPost = Date()
        cmdy.post("/v1/ui/inset", ["right": Double(value)]) { [weak self] resp in
            guard let self, let resp else { return }
            if let t = resp["top"] as? Double { self.dockTop = CGFloat(t) }
            if let b = resp["bottom"] as? Double { self.dockBottom = CGFloat(b) }
            if let s = resp["side"] as? Double { self.dockSide = CGFloat(s) }
            if let trailing = resp["trailing"] as? Double {
                self.dockTrailing = CGFloat(trailing)
            }
            self.tick()
        }
    }

    private func retime(_ interval: TimeInterval) {
        guard interval != glueInterval else { return }
        glueInterval = interval
        glue?.invalidate()
        glue = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard let pid = targetPid, let window = targetWindow else { retime(0.1); return }
        let cmdyFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == parentPid
            || NSRunningApplication(processIdentifier: pid)?.isActive == true
            || NSRunningApplication.current.isActive
        guard cmdyFrontmost, let host = cmdyWindowFrame() else {
            grip.orderOut(nil)
            retime(0.25)
            return
        }
        if host != lastHost { lastHost = host; hotUntil = Date().addingTimeInterval(1.0) }
        retime(Date() < hotUntil ? 1.0 / 60.0 : 0.12)

        let w = currentDockWidth(for: host)
        postInset(w)

        // Place the FOREIGN window in the strip (CG top-left coords). The
        // strip is the right `w` of the pane area; the app fills it minus pad.
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let stripLeftCG = host.maxX - dockTrailing - dockSide - w + pad
        let appW = max(120, w - 2 * pad)
        let appTopCG = screenH - (host.maxY - dockTop) + pad
        let appH = max(120, host.height - dockTop - dockBottom - 2 * pad)
        AXKit.setFrame(window, CGRect(x: stripLeftCG, y: appTopCG, width: appW, height: appH))

        // Our grip window sits on the seam (AppKit bottom-left coords).
        let gripFrame = NSRect(x: host.maxX - dockTrailing - dockSide - w,
                               y: host.minY + dockBottom,
                               width: 10, height: host.height - dockTop - dockBottom)
        if grip.frame != gripFrame { grip.setFrame(gripFrame, display: true) }
        if !grip.isVisible { grip.orderFront(nil) }
    }

    private func dividerDragged(_ dx: CGFloat) {
        guard targetPid != nil else { return }
        if lastHost == .zero { lastHost = cmdyWindowFrame() ?? .zero }
        guard lastHost != .zero else { return }
        dockWidth = currentDockWidth(for: lastHost) - dx
        tick()
    }
    private func dividerDragEnded() {
        guard lastHost != .zero else { return }
        lastInsetPost = .distantPast
        postInset(currentDockWidth(for: lastHost))
    }

    // MARK: - SDK events

    private func handle(_ event: [String: Any]) {
        switch event["kind"] as? String {
        case "command", "hotkey":
            switch event["id"] as? String {
            case "appdock.pick": pickApp()
            case "appdock.undock": releaseTarget()
            default: break
            }
        case "ui":
            guard let panel = event["panel"] as? String, panel == urlPanelId else { return }
            if event["event"] as? String == "submit", let name = event["value"] as? String, !name.isEmpty {
                _ = AXKit.trusted(prompt: true)
                if let app = NSWorkspace.shared.runningApplications
                    .first(where: { ($0.localizedName ?? "").lowercased().contains(name.lowercased()) }) {
                    _ = adopt(pid: app.processIdentifier)
                }
                cmdy.dismissPanel(panel)
                urlPanelId = nil
            } else if event["event"] as? String == "dismissed" {
                urlPanelId = nil
            }
        default: break
        }
    }

    private func pickApp() {
        // The palette can't enumerate apps, so accept a name via the input panel.
        cmdy.openPanel([
            "mode": "input", "title": "appdock",
            "placeholder": "app name (e.g. Calculator, Simulator)…",
            "hint": "⏎ dock its window · esc cancel",
        ]) { [weak self] id in self?.urlPanelId = id }
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseTarget()
        cmdy.post("/v1/ui/inset", ["right": 0])
        usleep(150_000)
        api.stop()
    }
}

/// The divider on the strip's left edge — invisible, cursor-only, like the
/// chromium sidecar's.
final class DividerGrip: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    private var lastX: CGFloat = 0
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { lastX = NSEvent.mouseLocation.x }
    override func mouseDragged(with event: NSEvent) {
        let x = NSEvent.mouseLocation.x; onDrag?(x - lastX); lastX = x
    }
    override func mouseUp(with event: NSEvent) { onDragEnd?() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDock()
app.delegate = delegate
app.run()
