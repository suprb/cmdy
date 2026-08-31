import AppKit
import ApplicationServices
import CmdySDK

// sim — the iOS Simulator as a cmdy split. Wraps xcodebuild + simctl for
// the build/run/screenshot/log lifecycle (Simctl.swift), docks Simulator.app's
// window into the reserved strip (the appdock technique, built in — no
// dependency), and exposes it all to agents over HTTP + MCP (SimAPI). When the
// project is Injection-ready, edits hot-reload into the running app instead of
// forcing a rebuild — the fast inner loop.

final class Sim: NSObject, NSApplicationDelegate {
    private var cmdy: Cmdy!
    private var grip: NSWindow!
    private var gripView: DividerGrip!
    private var cardView: NSView!
    private var glue: Timer?
    private var glueInterval: TimeInterval = 0
    /// The host's pid — normally our parent. <PRODUCT>_PARENT_PID overrides it
    /// for hosted/dev runs where the plugin isn't a direct child of cmdy.
    private let parentPid = HostProductIdentity.environmentValue("PARENT_PID")
        .flatMap(Int32.init) ?? getppid()
    private let api = SimAPI()
    private let feedbackOverlay = SimFeedbackOverlay()
    private var sigTerm: DispatchSourceSignal?

    private var simWindow: AXUIElement?
    private var savedFrame: CGRect?
    private var cachedSimulatorPid: pid_t?
    private var offeredAgent = false

    // Dock geometry (mirrors chromium/appdock).
    private var postedInset: CGFloat = -1
    private var postedInsetWindow: CGWindowID?
    private var lastInsetPost = Date.distantPast
    private var pendingInset: CGFloat?
    private var insetPostWorkItem: DispatchWorkItem?
    private var dockSide: CGFloat = 25
    private var dockTrailing: CGFloat = 0
    private var lastHost = NSRect.zero
    private var host = CmdySidecarHost()
    /// Most recent key Cmdy window. Mirror commands without an explicit
    /// MCP window use this, while the native Simulator dock keeps its existing
    /// single `host` ownership below.
    private var activeCmdyWindow: CGWindowID?
    private var hostForeground = true
    private var hostLiveResize = false
    private var hotUntil = Date.distantPast
    private var wasFrontmost = false        // raise the sim on the transition into focus
    private var simHidden = false           // moved off-screen while cmdy isn't frontmost
    private var tapHoldUntil = Date.distantPast   // keep the sim on-screen through an agent tap
    /// A split ratio, rather than a fixed width, keeps the dock responsive as
    /// the Cmdy window changes size. Dragging the divider updates it.
    private var dockFraction = SimDockLayout.defaultFraction
    private var autoFitWorkItem: DispatchWorkItem?
    private var autoFitInFlight = false
    private var lastSimulatorSize = CGSize.zero
    private var lastSimulatorFrameRead = Date.distantPast
    private var blockedUpscale: (preset: String, required: CGSize)?
    private var minimumPresetSize: CGSize?
    private var presetIndexHint: Int?
    private let sizePresets = ["Physical Size", "Point Accurate", "Fit Screen", "Pixel Accurate"]
    /// Conservative ratios between Simulator's native presets. A candidate is
    /// tried only when both dock dimensions have this much room.
    private let presetScaleThresholds: [CGFloat] = [1.22, 1.15, 1.36]
    private let pad: CGFloat = 10
    private let dividerWidth: CGFloat = 20
    private let trackingInterval: TimeInterval = 1.0 / 120.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let sdk = Cmdy() else {
            FileHandle.standardError.write(Data(
                ("sim: not launched by \(HostProductIdentity.name) "
                    + "(missing \(HostProductIdentity.environmentPrefix)_* env)\n").utf8))
            exit(1)
        }
        cmdy = sdk
        makeGrip()

        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigTerm = src

        // Agent-triggered docks stay quiet (the agent sees JSON results); the
        // ⌃⌥S command / palette shows the progress panel.
        api.dockSimulator = { [weak self] in self?.adoptSimulator(showProgress: false) }
        api.undock = { [weak self] in self?.releaseSimulator() }
        api.simulatorWindow = { [weak self] in self?.simWindow }
        // Agent tap: the window may be parked off-screen (cmdy not
        // frontmost) — force it into the strip and raise it, regardless of
        // who's frontmost. The next tick restores normal hide/show behavior.
        api.prepareForTap = { [weak self] in
            guard let self, let window = self.simWindow else {
                NSLog("sim: prepareForTap — no window"); return
            }
            guard let host = self.cmdyWindowFrame() else {
                NSLog("sim: prepareForTap — no host frame"); return
            }
            self.tapHoldUntil = Date().addingTimeInterval(1.5)   // tick() must not re-hide mid-tap
            if self.simHidden, let pid = self.simulatorPid() {
                NSRunningApplication(processIdentifier: pid)?.unhide()
            }
            AXKit.raise(window)
            self.simHidden = false
            self.placeSimWindow(window, layout: self.dockLayout(window: window, host: host))
            let got = AXKit.frame(of: window) ?? .zero
            NSLog("sim: prepareForTap host=(%.0f,%.0f %.0fx%.0f) got=(%.0f,%.0f)",
                  host.origin.x, host.origin.y, host.width, host.height, got.origin.x, got.origin.y)
        }
        api.startMirror = { [weak self] windowNumber, device in
            self?.startMirror(windowNumber: windowNumber, device: device)
                ?? ["success": false, "error": "simulator mirror is unavailable"]
        }
        api.stopMirror = { [weak self] windowNumber, all in
            self?.stopMirror(windowNumber: windowNumber, all: all)
                ?? ["success": false, "error": "simulator mirror is unavailable"]
        }
        api.beginFeedback = { [weak self] in self?.beginFeedback() }
        api.start()

        cmdy.registerCommand(id: "sim.dock", title: "Dock the Simulator", plugin: "Sim")
        cmdy.registerCommand(id: "sim.undock", title: "Undock the Simulator", plugin: "Sim")
        cmdy.registerCommand(id: "sim.mirror", title: "Mirror the Simulator (serve-sim)", plugin: "Sim")
        cmdy.registerCommand(id: "sim.mirror.stop", title: "Stop the Simulator Mirror", plugin: "Sim")
        cmdy.registerCommand(id: "sim.annotate", title: "Add Simulator UI Feedback", plugin: "Sim")
        cmdy.registerHotKey(id: "sim.dock", keyCode: 1 /* S */,
                               modifiers: [.control, .option])
        cmdy.onEvent = { [weak self] event in self?.handle(event) }
        cmdy.listen()
        // If cmdy dies without terminating us, restore the Simulator and
        // drop our discovery file rather than lingering as an orphan.
        cmdy.onParentExit = { [weak self] in
            self?.terminateAllMirrors()
            self?.quitSimulator()   // cmdy is gone → take the Simulator with it
            self?.api.stop()
        }

        // Hide/show the sim the instant focus changes (no polling lag): when a
        // foreign app activates, get out of its way immediately; when cmdy
        // or the Simulator activates, come back.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.simWindow != nil else { return }
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            if pid == self.parentPid || pid == self.simulatorPid() || pid == getpid() {
                self.tick()   // cmdy/sim focused → reposition on-screen
            } else {
                self.hideSimulator()
            }
        }

        retime(0.15)
        NSLog("sim: ready (simctl + xcodebuild; dock the Simulator to split it in)")
    }

    private func makeGrip() {
        // The dock window spans the whole reserved strip so its invisible grip
        // sits on the true split edge. The visible card is inset exactly like
        // Browser, and the real Simulator floats centered above it.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 800))
        root.autoresizesSubviews = true
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        cardView = NSView(frame: root.bounds.insetBy(dx: pad, dy: pad))
        cardView.autoresizingMask = [.width, .height]
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 12
        cardView.layer?.masksToBounds = true
        cardView.layer?.backgroundColor = NSColor.black.cgColor
        gripView = DividerGrip(frame: NSRect(x: 0, y: 0, width: dividerWidth, height: root.frame.height))
        gripView.autoresizingMask = [.height]
        gripView.onDrag = { [weak self] dx in
            guard let self, self.simWindow != nil else { return }
            if self.lastHost == .zero { self.lastHost = self.cmdyWindowFrame() ?? .zero }
            guard self.lastHost.width > 0 else { return }
            let current = self.lastHost.width * self.dockFraction
            let maximum = max(SimDockLayout.minimumStripWidth,
                              self.lastHost.width - SimDockLayout.minimumTerminalWidth)
            let desired = min(max(SimDockLayout.minimumStripWidth, current - dx), maximum)
            self.dockFraction = desired / self.lastHost.width
            self.hotUntil = Date().addingTimeInterval(1.0)
            self.tick()
        }
        gripView.onDragEnd = { [weak self] in
            guard let self else { return }
            self.schedulePresetFit(after: 0.05, restart: true)
            self.lastInsetPost = .distantPast
            self.tick()
        }
        root.addSubview(cardView)
        root.addSubview(gripView)
        grip = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        grip.contentView = root
        grip.isReleasedWhenClosed = false
        grip.backgroundColor = .clear
        grip.isOpaque = false
        grip.hasShadow = true
        grip.level = .floating
        grip.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    }

    // MARK: - Adopt Simulator.app's window

    private func simulatorPid() -> pid_t? {
        if let cachedSimulatorPid,
           NSRunningApplication(processIdentifier: cachedSimulatorPid)?.isTerminated == false {
            return cachedSimulatorPid
        }
        let pid = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.apple.iphonesimulator" }?.processIdentifier
        cachedSimulatorPid = pid
        return pid
    }

    /// Dock the Simulator — booting it first if nothing is running (that's the
    /// common "nothing happens" case: there was no window to adopt). A progress
    /// panel narrates the boot, which is slow when cold.
    private func adoptSimulator(showProgress: Bool = true) {
        guard AXKit.trusted(prompt: true) else {
            if showProgress { flashProgress("✗  Accessibility permission needed — System Settings ▸ Privacy ▸ Accessibility") }
            return
        }
        if let pid = simulatorPid() {
            NSRunningApplication(processIdentifier: pid)?.unhide()
        }
        // Fast path: the Simulator is already up with a window — just dock it.
        if let window = currentSimulatorWindow() {
            dock(window)
            return
        }
        // Slow path: boot + wait for the window, narrating progress.
        if showProgress { startProgress("Opening the Simulator…") }
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            if self.simulatorPid() == nil || self.currentSimulatorWindowSync() == nil {
                DispatchQueue.main.async { if showProgress { self.setProgress("Booting a device…") } }
                let r = Simctl.boot(nil)   // boots (idempotent) + opens Simulator.app
                if !r.ok {
                    DispatchQueue.main.async { if showProgress { self.flashProgress("✗  couldn't boot a simulator") } }
                    return
                }
            }
            // Poll up to ~24s for the window to appear.
            for i in 0..<60 {
                Thread.sleep(forTimeInterval: 0.4)
                var window: AXUIElement?
                DispatchQueue.main.sync { window = self.currentSimulatorWindow() }
                if let window {
                    DispatchQueue.main.async {
                        self.dock(window)
                        if showProgress { self.finishProgress() }
                    }
                    return
                }
                if showProgress, i == 6 {
                    DispatchQueue.main.async { self.setProgress("Waiting for the window…") }
                }
            }
            DispatchQueue.main.async { if showProgress { self.flashProgress("✗  the Simulator window didn't appear") } }
        }
    }

    private func currentSimulatorWindow() -> AXUIElement? {
        guard let pid = simulatorPid() else { return nil }
        return AXKit.mainWindow(pid: pid)
    }
    private func currentSimulatorWindowSync() -> AXUIElement? { currentSimulatorWindow() }

    private func dock(_ window: AXUIElement) {
        if savedFrame == nil { savedFrame = AXKit.frame(of: window) }
        simWindow = window
        lastSimulatorSize = AXKit.frame(of: window)?.size ?? .zero
        lastSimulatorFrameRead = Date()
        minimumPresetSize = nil
        presetIndexHint = nil
        // "Stay On Top" keeps it reliably ABOVE the terminal (a foreign window
        // can't be leveled any other way). It would otherwise float over every
        // app too, so the plugin hides Simulator whenever its attached Cmdy
        // surface is not active.
        if let pid = simulatorPid() {
            AXKit.setMenuChecked(pid: pid, menuTitle: "Window", itemTitle: "Stay On Top", checked: true)
        }
        AXKit.raise(window)
        tick()
        offerAgentIfNeeded()
    }

    /// Hide Simulator so it cannot cover another app. A foreign NSWindow
    /// cannot be ordered out directly; hiding its owning application is the
    /// only complete operation WindowServer does not clamp back on-screen.
    private func hideSimulator() {
        guard simWindow != nil, !simHidden else { return }
        if let pid = simulatorPid(),
           NSRunningApplication(processIdentifier: pid)?.hide() == true {
            simHidden = true
            return
        }
        // Fallback for a Simulator build that refuses application hiding.
        guard let window = simWindow, let frame = AXKit.frame(of: window) else { return }
        let screenH = NSScreen.screens.first?.frame.height ?? 1200
        AXKit.setPosition(window, CGPoint(x: frame.origin.x, y: screenH + 60))
        simHidden = true
    }

    /// Quit the Simulator when cmdy goes away — but only one we docked.
    private func quitSimulator() {
        guard simWindow != nil, let pid = simulatorPid() else { return }
        // Simulator may accept a graceful termination request without
        // actually exiting. An attached host closing is ownership: do not
        // leave a floating Simulator behind after Cmdy has gone.
        NSRunningApplication(processIdentifier: pid)?.forceTerminate()
    }

    // MARK: - Progress panel (an animated spinner while the Simulator boots)

    private var progressPanelId: String?
    private var progressStatus = ""
    private var spinnerTimer: Timer?
    private var spinnerFrame = 0
    private let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    private func spinnerLine() -> String { "\(spinner[spinnerFrame])  \(progressStatus)" }

    private func startProgress(_ status: String) {
        progressStatus = status
        spinnerFrame = 0
        // A fresh panel each time; the timer animates the braille spinner.
        cmdy.openPanel(["mode": "text", "title": "sim",
                           "body": spinnerLine(), "hint": "booting the iOS Simulator · esc to dismiss"]) { [weak self] id in
            self?.progressPanelId = id
        }
        spinnerTimer?.invalidate()
        spinnerTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self, let id = self.progressPanelId else { return }
            self.spinnerFrame = (self.spinnerFrame + 1) % self.spinner.count
            self.cmdy.updatePanel(id, ["body": self.spinnerLine()])
        }
    }

    private func setProgress(_ status: String) { progressStatus = status }

    /// Success: show a check, then dismiss after a beat.
    private func finishProgress() {
        spinnerTimer?.invalidate(); spinnerTimer = nil
        guard let id = progressPanelId else { return }
        cmdy.updatePanel(id, ["body": "✓  Simulator docked"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            if let id = self?.progressPanelId { self?.cmdy.dismissPanel(id); self?.progressPanelId = nil }
        }
    }

    /// Failure/notice: show the message, dismiss after a longer beat. Also used
    /// when there was no active panel (opens a brief one).
    private func flashProgress(_ message: String) {
        spinnerTimer?.invalidate(); spinnerTimer = nil
        if let id = progressPanelId {
            cmdy.updatePanel(id, ["body": message])
        } else {
            cmdy.openPanel(["mode": "text", "title": "sim", "body": message, "hint": "esc to dismiss"]) { [weak self] id in
                self?.progressPanelId = id
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            if let id = self?.progressPanelId { self?.cmdy.dismissPanel(id); self?.progressPanelId = nil }
        }
    }

    private func releaseSimulator() {
        let target = host.windowNumber
        if simHidden, let pid = simulatorPid() {
            NSRunningApplication(processIdentifier: pid)?.unhide()
        }
        // Turn Stay On Top back off and restore the window where it was.
        if let pid = simulatorPid() {
            AXKit.setMenuChecked(pid: pid, menuTitle: "Window", itemTitle: "Stay On Top", checked: false)
        }
        if let window = simWindow, let frame = savedFrame { AXKit.setFrame(window, frame) }
        simWindow = nil
        offeredAgent = false
        savedFrame = nil
        cachedSimulatorPid = nil
        simHidden = false
        autoFitWorkItem?.cancel()
        autoFitWorkItem = nil
        autoFitInFlight = false
        lastSimulatorSize = .zero
        blockedUpscale = nil
        minimumPresetSize = nil
        presetIndexHint = nil
        insetPostWorkItem?.cancel()
        insetPostWorkItem = nil
        pendingInset = nil
        if let target { postInset(0, windowNumber: target, force: true) }
        grip.orderOut(nil)
        host.clear()
        hostForeground = true
        hostLiveResize = false
        lastHost = .zero
    }

    // MARK: - Glue

    private func dockLayout(window: AXUIElement, host: NSRect,
                            refreshSimulatorSize: Bool = false) -> SimDockLayout {
        if refreshSimulatorSize || lastSimulatorSize == .zero,
           let size = AXKit.frame(of: window)?.size {
            lastSimulatorSize = size
            lastSimulatorFrameRead = Date()
        }
        let simulatorSize = lastSimulatorSize == .zero
            ? CGSize(width: 400, height: 800) : lastSimulatorSize
        return SimDockLayout(host: host,
                             dockSide: dockSide,
                             trailingOffset: dockTrailing,
                             fraction: dockFraction,
                             simulatorSize: simulatorSize,
                             screenHeight: NSScreen.screens.first?.frame.height ?? 0,
                             padding: pad)
    }

    private func schedulePresetFit(after delay: TimeInterval = 0.22, restart: Bool = false) {
        guard simWindow != nil, !autoFitInFlight, !hostLiveResize else { return }
        if autoFitWorkItem != nil {
            guard restart else { return }
            autoFitWorkItem?.cancel()
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.autoFitWorkItem = nil
            self.adjustSimulatorPreset()
        }
        autoFitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The real Simulator window has no continuous resize API. Walk its native
    /// Window presets after a resize and keep the largest one that truly fits.
    private func adjustSimulatorPreset() {
        guard !autoFitInFlight, !hostLiveResize, simWindow != nil,
              let pid = simulatorPid() else { return }
        autoFitInFlight = true
        NSLog("sim: fitting native size preset")
        if let window = simWindow { AXKit.raise(window) }
        NSRunningApplication(processIdentifier: pid)?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.evaluateSimulatorPreset(pid: pid)
        }
    }

    private func evaluateSimulatorPreset(pid: pid_t) {
        guard let window = simWindow, let host = cmdyWindowFrame() else {
            finishPresetChange(continueFitting: false)
            return
        }
        let detectedPreset = sizePresets.firstIndex(where: {
            AXKit.menuItemIsMarked(pid: pid, menuTitle: "Window", itemTitle: $0)
        })
        // The checkmark can lag the actual resize animation. Once Cmdy has
        // selected a preset, its measured transition is more current than AX.
        guard let current = presetIndexHint ?? detectedPreset else {
            presetIndexHint = 0
            let changed = AXKit.clickMenuItem(pid: pid, menuTitle: "Window",
                                              itemTitle: sizePresets[0])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.finishPresetChange(continueFitting: changed)
            }
            return
        }

        let layout = dockLayout(window: window, host: host, refreshSimulatorSize: true)
        NSLog("sim: preset=%@ device=%.0fx%.0f available=%.0fx%.0f fits=%d",
              sizePresets[current], layout.simulatorFrame.width, layout.simulatorFrame.height,
              layout.availableSimulatorSize.width, layout.availableSimulatorSize.height,
              layout.simulatorFits ? 1 : 0)
        let candidate: Int
        let isUpscale: Bool
        if !layout.simulatorFits {
            guard current > 0 else {
                if minimumPresetSize == nil {
                    // Simulator can expose a checked Physical Size item while
                    // its window is still at the preceding preset's size.
                    // Reapply and measure it before declaring the minimum.
                    changeSimulatorPreset(to: 0, from: 0, upscale: false, pid: pid)
                } else {
                    NSLog("sim: minimum native preset reached; waiting for more space")
                    finishPresetChange(continueFitting: false)
                }
                return
            }
            candidate = current - 1
            isUpscale = false
        } else {
            guard current < sizePresets.count - 1 else {
                finishPresetChange(continueFitting: false); return
            }
            let frame = layout.simulatorFrame.size
            let available = layout.availableSimulatorSize
            let capacity = min(available.width / max(1, frame.width),
                               available.height / max(1, frame.height))
            guard capacity >= presetScaleThresholds[current] else {
                finishPresetChange(continueFitting: false); return
            }
            candidate = current + 1
            isUpscale = true
            if let blocked = blockedUpscale, blocked.preset == sizePresets[candidate],
               (available.width + 0.5 < blocked.required.width
                || available.height + 0.5 < blocked.required.height) {
                finishPresetChange(continueFitting: false)
                return
            }
        }

        changeSimulatorPreset(to: candidate, from: current, upscale: isUpscale,
                              pid: pid)
    }

    private func changeSimulatorPreset(to candidate: Int, from current: Int, upscale: Bool,
                                       pid: pid_t) {
        let changed = AXKit.clickMenuItem(pid: pid, menuTitle: "Window",
                                          itemTitle: sizePresets[candidate])
        NSLog("sim: preset %@ -> %@ click=%d", sizePresets[current],
              sizePresets[candidate], changed ? 1 : 0)
        guard changed else {
            if candidate == 0 { minimumPresetSize = lastSimulatorSize }
            finishPresetChange(continueFitting: false)
            return
        }
        presetIndexHint = candidate
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            guard let window = self.simWindow, let host = self.cmdyWindowFrame() else {
                self.finishPresetChange(continueFitting: false)
                return
            }
            let result = self.dockLayout(window: window, host: host, refreshSimulatorSize: true)
            if upscale, !result.simulatorFits {
                self.blockedUpscale = (self.sizePresets[candidate], result.simulatorFrame.size)
                AXKit.clickMenuItem(pid: pid, menuTitle: "Window",
                                    itemTitle: self.sizePresets[current])
                self.presetIndexHint = current
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.finishPresetChange(continueFitting: false)
                }
            } else {
                if self.blockedUpscale?.preset == self.sizePresets[candidate] {
                    self.blockedUpscale = nil
                }
                if candidate == 0, !result.simulatorFits {
                    self.minimumPresetSize = result.simulatorFrame.size
                    self.finishPresetChange(continueFitting: false)
                } else {
                    self.finishPresetChange(continueFitting: true)
                }
            }
        }
    }

    private func finishPresetChange(continueFitting: Bool) {
        autoFitInFlight = false
        lastSimulatorSize = .zero
        if let parentWindow = AXKit.mainWindow(pid: parentPid) { AXKit.raise(parentWindow) }
        NSRunningApplication(processIdentifier: parentPid)?.activate()
        hotUntil = Date().addingTimeInterval(1.0)
        tick()
        if continueFitting { schedulePresetFit(after: 0.2) }
    }

    private func placeSimWindow(_ window: AXUIElement, layout: SimDockLayout) {
        AXKit.setPosition(window, layout.simulatorFrame.origin)
    }

    // MARK: - sim.mirror — the streamed alternative to the native dock.
    //
    // Spawns serve-sim (Evan Bacon, Apache-2.0 — github.com/EvanBacon/serve-sim):
    // a native Swift helper that captures the simulator framebuffer zero-copy
    // (event-driven, up to 60fps) and serves an interactive web mirror — then
    // shows it in the docked Browser. Fluid resize, multi-device, no window
    // games. The native dock (⌃⌥S) remains the zero-latency option.

    private struct MirrorProgress {
        let generation: UUID
        var panelID: String?
        var body: String
        var finalDelay: TimeInterval?
    }

    private var mirrorSlots = SimMirrorSlots()
    private var mirrorProcesses: [CGWindowID: Process] = [:]
    private var mirrorProgress: [CGWindowID: MirrorProgress] = [:]
    private var pendingMirrorLaunches: [CGWindowID: SimMirrorSlot] = [:]
    private var serveSimInstallProcess: Process?
    private let serveSimVersion = "0.1.45"

    private func mirrorHealthy(port: Int) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else {
            return false
        }
        var req = URLRequest(url: url); req.timeoutInterval = 1.0
        var ok = false
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            ok = (resp as? HTTPURLResponse)?.statusCode == 200; sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 1.5)
        return ok
    }

    /// Node tools, wherever they live (nvm first — GUI apps don't get the
    /// user's interactive shell PATH).
    private func findNodeTool(_ name: String) -> String? {
        var candidates: [String] = []
        let nvm = NSHomeDirectory() + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            for v in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                candidates.append(nvm + "/" + v + "/bin/" + name)
            }
        }
        candidates += [
            "/opt/homebrew/bin/" + name,
            "/usr/local/bin/" + name,
            "/usr/bin/" + name,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var serveSimInstallDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".cache/\(HostProductIdentity.slug)-sim/serve-sim-\(serveSimVersion)",
                isDirectory: true)
    }

    private var cachedServeSimExecutable: URL? {
        if let override = HostProductIdentity.environmentValue(
            "SERVE_SIM_EXECUTABLE"),
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let executable = serveSimInstallDirectory.appendingPathComponent(
            "node_modules/.bin/serve-sim")
        return FileManager.default.isExecutableFile(atPath: executable.path)
            ? executable : nil
    }

    private func nodeSearchPath(for executable: URL) -> String {
        let nodeDirectory = findNodeTool("node").map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        } ?? executable.deletingLastPathComponent().path
        return nodeDirectory
            + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"
            + (ProcessInfo.processInfo.environment["PATH"] ?? "")
    }

    /// Device to hand serve-sim when nothing is booted: the newest-runtime
    /// iPhone. (Legacy runtimes run under Rosetta and are not welcome here.)
    private func mirrorDeviceArg(_ requested: String?) -> String? {
        let devs = Simctl.devices()
        if let requested = requested?.trimmingCharacters(
            in: .whitespacesAndNewlines),
           !requested.isEmpty {
            return devs.first {
                $0.udid == requested
                    || $0.name.compare(
                        requested, options: .caseInsensitive) == .orderedSame
            }?.name ?? requested
        }
        if devs.contains(where: { $0.state == "Booted" }) { return nil }   // serve-sim targets booted by default
        return devs.filter { $0.name.hasPrefix("iPhone") }
            .max { $0.runtime.compare($1.runtime, options: .numeric) == .orderedAscending }?.name
    }

    private func mirrorTarget(_ requested: CGWindowID?) -> CGWindowID? {
        requested ?? activeCmdyWindow ?? host.windowNumber
    }

    private func startMirror(
        windowNumber requestedWindow: CGWindowID?,
        device requestedDevice: String?
    ) -> [String: Any] {
        guard let windowNumber = mirrorTarget(requestedWindow) else {
            let message =
                "focus a \(HostProductIdentity.titleName) window before starting the mirror"
            flashProgress("✗  \(message)")
            return ["success": false, "error": message]
        }
        if let existing = mirrorSlots.slot(for: windowNumber) {
            if mirrorHealthy(port: existing.port) {
                openMirrorInBrowser(existing)
                return mirrorResult(existing, starting: false, reused: true)
            }
            if mirrorProcesses[windowNumber]?.isRunning == true {
                openMirrorInBrowser(existing)
                return mirrorResult(existing, starting: true, reused: true)
            }
            _ = terminateMirror(in: windowNumber)
        }

        let device = mirrorDeviceArg(requestedDevice)
        guard let reservation = mirrorSlots.reserve(
            for: windowNumber,
            device: device,
            isPortAvailable: SimMirrorPortProbe.isAvailable)
        else {
            let message = "no free serve-sim preview port in 3200…3299"
            flashProgress("✗  \(message)")
            return ["success": false, "error": message]
        }
        let slot = reservation.slot
        beginMirrorProgress(slot)
        ensureServeSimAndLaunch(slot)
        // Open cmdy's Browser immediately so the surface is already visible
        // while serve-sim boots; the healthy callback navigates it again once
        // the local stream is ready.
        openMirrorInBrowser(slot)
        return mirrorResult(slot, starting: true, reused: false)
    }

    /// Resolve serve-sim once into a versioned Cmdy cache. Launching two
    /// `npx serve-sim` commands concurrently races inside npm's shared `_npx`
    /// directory; a single pinned install plus independent direct launches
    /// avoids that race and makes the runtime reproducible.
    private func ensureServeSimAndLaunch(_ slot: SimMirrorSlot) {
        if let executable = cachedServeSimExecutable {
            launchMirror(slot, executable: executable)
            return
        }
        pendingMirrorLaunches[slot.windowNumber] = slot
        updateMirrorProgress(
            slot, body: "Installing serve-sim \(serveSimVersion)…")
        if serveSimInstallProcess?.isRunning == true { return }

        guard let npm = findNodeTool("npm") else {
            failPendingMirrorLaunches(
                "serve-sim needs Node 20+ (npm not found)")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: serveSimInstallDirectory,
                withIntermediateDirectories: true)
        } catch {
            failPendingMirrorLaunches(
                "couldn't prepare the serve-sim cache: "
                    + error.localizedDescription)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: npm)
        process.arguments = [
            "install",
            "--prefix", serveSimInstallDirectory.path,
            "--no-save",
            "--no-audit",
            "--no-fund",
            "serve-sim@\(serveSimVersion)",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = nodeSearchPath(
            for: URL(fileURLWithPath: npm))
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self, weak process] _ in
            DispatchQueue.main.async {
                guard let self, let process,
                      self.serveSimInstallProcess === process else { return }
                self.serveSimInstallProcess = nil
                guard process.terminationStatus == 0,
                      let executable = self.cachedServeSimExecutable else {
                    self.failPendingMirrorLaunches(
                        "couldn't install serve-sim \(self.serveSimVersion)")
                    return
                }
                let pending = self.pendingMirrorLaunches.values.sorted {
                    $0.port < $1.port
                }
                self.pendingMirrorLaunches.removeAll()
                for pendingSlot in pending {
                    guard self.mirrorSlots.slot(
                        for: pendingSlot.windowNumber)?.generation
                            == pendingSlot.generation else { continue }
                    self.launchMirror(
                        pendingSlot, executable: executable)
                }
            }
        }
        do {
            try process.run()
            serveSimInstallProcess = process
        } catch {
            failPendingMirrorLaunches(
                "couldn't launch npm: " + error.localizedDescription)
        }
    }

    private func failPendingMirrorLaunches(_ message: String) {
        let pending = pendingMirrorLaunches.values
        pendingMirrorLaunches.removeAll()
        serveSimInstallProcess = nil
        for slot in pending {
            _ = terminateMirror(
                in: slot.windowNumber, dismissProgress: false)
            finishMirrorProgress(
                slot, message: "✗  \(message)", delay: 3)
        }
    }

    private func launchMirror(
        _ slot: SimMirrorSlot,
        executable: URL
    ) {
        guard mirrorSlots.slot(for: slot.windowNumber)?.generation
                == slot.generation,
              mirrorProcesses[slot.windowNumber] == nil else { return }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--port", "\(slot.port)"]
            + (slot.device.map { [$0] } ?? [])
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = nodeSearchPath(for: executable)
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            _ = terminateMirror(
                in: slot.windowNumber, dismissProgress: false)
            finishMirrorProgress(
                slot,
                message: "✗  couldn't launch serve-sim: "
                    + error.localizedDescription,
                delay: 3)
            return
        }
        mirrorProcesses[slot.windowNumber] = process
        updateMirrorProgress(slot, body: "Starting the simulator mirror…")

        // Wait for this window's preview server. Boot + framebuffer attach can
        // take a while, but other window sessions continue independently.
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            for i in 0..<90 {
                if self.mirrorHealthy(port: slot.port) {
                    DispatchQueue.main.async {
                        guard self.mirrorSlots.slot(
                            for: slot.windowNumber)?.generation
                                == slot.generation else { return }
                        self.finishMirrorProgress(
                            slot, message: "✓  Mirror live", delay: 0.9)
                        self.openMirrorInBrowser(slot)
                    }
                    return
                }
                if i == 20 {
                    DispatchQueue.main.async {
                        self.updateMirrorProgress(
                            slot, body: "Still starting the simulator…")
                    }
                }
                usleep(1_000_000)
            }
            DispatchQueue.main.async {
                guard self.mirrorSlots.slot(
                    for: slot.windowNumber)?.generation
                        == slot.generation else { return }
                _ = self.terminateMirror(
                    in: slot.windowNumber, dismissProgress: false)
                self.finishMirrorProgress(
                    slot,
                    message: "✗  the mirror never came up on :\(slot.port)",
                    delay: 3)
            }
        }
    }

    private func mirrorResult(
        _ slot: SimMirrorSlot,
        starting: Bool,
        reused: Bool
    ) -> [String: Any] {
        var result: [String: Any] = [
            "success": true,
            "starting": starting,
            "reused": reused,
            "window": Int(slot.windowNumber),
            "port": slot.port,
            "url": slot.url.absoluteString,
            "note": "this mirror belongs to one \(HostProductIdentity.titleName) window",
        ]
        if let device = slot.device { result["device"] = device }
        return result
    }

    private func beginMirrorProgress(_ slot: SimMirrorSlot) {
        mirrorProgress[slot.windowNumber] = MirrorProgress(
            generation: slot.generation,
            panelID: nil,
            body: "Starting the simulator mirror…",
            finalDelay: nil)
        cmdy.openPanel([
            "mode": "text",
            "title": "sim",
            "body": "Starting the simulator mirror…",
            "hint": "window-specific serve-sim session",
            "window": Int(slot.windowNumber),
        ]) { [weak self] id in
            guard let self, let id else { return }
            guard var state = self.mirrorProgress[slot.windowNumber],
                  state.generation == slot.generation else {
                self.cmdy.dismissPanel(id)
                return
            }
            state.panelID = id
            self.mirrorProgress[slot.windowNumber] = state
            self.cmdy.updatePanel(id, ["body": state.body])
            if let delay = state.finalDelay {
                self.dismissMirrorProgress(
                    windowNumber: slot.windowNumber,
                    generation: slot.generation,
                    panelID: id,
                    after: delay)
            }
        }
    }

    private func updateMirrorProgress(
        _ slot: SimMirrorSlot,
        body: String
    ) {
        guard var state = mirrorProgress[slot.windowNumber],
              state.generation == slot.generation else { return }
        state.body = body
        mirrorProgress[slot.windowNumber] = state
        if let id = state.panelID {
            cmdy.updatePanel(id, ["body": body])
        }
    }

    private func finishMirrorProgress(
        _ slot: SimMirrorSlot,
        message: String,
        delay: TimeInterval
    ) {
        guard var state = mirrorProgress[slot.windowNumber],
              state.generation == slot.generation else { return }
        state.body = message
        state.finalDelay = delay
        mirrorProgress[slot.windowNumber] = state
        guard let id = state.panelID else { return }
        cmdy.updatePanel(id, ["body": message])
        dismissMirrorProgress(
            windowNumber: slot.windowNumber,
            generation: slot.generation,
            panelID: id,
            after: delay)
    }

    private func dismissMirrorProgress(
        windowNumber: CGWindowID,
        generation: UUID,
        panelID: String,
        after delay: TimeInterval
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            [weak self] in
            guard let self,
                  let state = self.mirrorProgress[windowNumber],
                  state.generation == generation,
                  state.panelID == panelID else { return }
            self.cmdy.dismissPanel(panelID)
            self.mirrorProgress[windowNumber] = nil
        }
    }

    private func stopMirror(
        windowNumber requestedWindow: CGWindowID?,
        all: Bool
    ) -> [String: Any] {
        if all {
            let count = mirrorSlots.all.count
            terminateAllMirrors()
            return ["success": true, "stopped": count, "all": true]
        }
        guard let windowNumber = mirrorTarget(requestedWindow) else {
            return [
                "success": false,
                "error": "focus a \(HostProductIdentity.titleName) window before stopping the mirror",
            ]
        }
        let stopped = terminateMirror(in: windowNumber) != nil
        return [
            "success": true,
            "stopped": stopped,
            "window": Int(windowNumber),
        ]
    }

    /// Terminate one mirror helper AND its child. A serve-sim launcher may
    /// still spawn the real node server below it, so terminating only the
    /// direct Process can leave a server behind after its tab closes.
    @discardableResult
    private func terminateMirror(
        in windowNumber: CGWindowID,
        dismissProgress: Bool = true
    ) -> SimMirrorSlot? {
        let slot = mirrorSlots.release(windowNumber)
        pendingMirrorLaunches[windowNumber] = nil
        if let process = mirrorProcesses.removeValue(forKey: windowNumber) {
            terminateProcessTree(process)
        }
        if dismissProgress,
           let state = mirrorProgress.removeValue(forKey: windowNumber),
           let panelID = state.panelID {
            cmdy.dismissPanel(panelID)
        }
        if pendingMirrorLaunches.isEmpty {
            cancelServeSimInstall()
        }
        return slot
    }

    private func terminateAllMirrors() {
        let windows = Set(mirrorSlots.all.map(\.windowNumber))
            .union(mirrorProcesses.keys)
        for windowNumber in windows {
            _ = terminateMirror(in: windowNumber)
        }
        pendingMirrorLaunches.removeAll()
        cancelServeSimInstall()
    }

    private func cancelServeSimInstall() {
        guard let process = serveSimInstallProcess else { return }
        process.terminationHandler = nil
        serveSimInstallProcess = nil
        terminateProcessTree(process)
    }

    private func terminateProcessTree(_ process: Process) {
        let pid = process.processIdentifier
        if pid > 0 {
            // Reap the child while it is still parented to its launcher;
            // terminating the launcher first can orphan the server at launchd.
            let killer = Process()
            killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            killer.arguments = ["-P", "\(pid)"]
            try? killer.run()
            killer.waitUntilExit()
        }
        if process.isRunning { process.terminate() }
    }

    /// Show this session in the built-in Browser belonging to the same cmdy
    /// window. Browser discovery can briefly disappear while its surface is
    /// attaching, so retry that handoff instead of leaking the mirror into the
    /// user's default browser.
    private func openMirrorInBrowser(
        _ slot: SimMirrorSlot,
        attemptsRemaining: Int = 40
    ) {
        let handoff = BrowserMirrorHandoff(
            mirrorURL: slot.url,
            windowNumber: slot.windowNumber,
            discoveryURL: HostProductIdentity.configurationDirectory
                .appendingPathComponent("browser-api.json"),
            schedule: { delay, action in
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + delay, execute: action)
            },
            isCurrent: { [weak self] in
                self?.mirrorSlots.slot(for: slot.windowNumber)?.generation
                    == slot.generation
            })
        handoff.start(attemptsRemaining: attemptsRemaining)
    }

    private func cmdyWindowFrame() -> NSRect? {
        if let hostWindowNumber = host.windowNumber,
           let list = CGWindowListCopyWindowInfo([.optionIncludingWindow, .excludeDesktopElements],
                                                 hostWindowNumber) as? [[String: Any]],
           let info = list.first,
           let frame = cmdyWindowFrame(from: info) {
            return frame
        }
        if host.windowNumber != nil { return nil }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard let frame = cmdyWindowFrame(from: info),
                  let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
            host.adopt(CGWindowID(number.uint32Value))
            return frame
        }
        return nil
    }

    private func cmdyWindowFrame(from info: [String: Any]) -> NSRect? {
        guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid == parentPid,
              let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
              let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        let x = b["X"] ?? 0, y = b["Y"] ?? 0
        let w = b["Width"] ?? 0, h = b["Height"] ?? 0
        guard w >= 300, h >= 200, x > -5000, y > -5000,
              let primary = NSScreen.screens.first else { return nil }
        return NSRect(x: x, y: primary.frame.height - y - h, width: w, height: h)
    }

    private func postInset(_ value: CGFloat, windowNumber: CGWindowID? = nil,
                           force: Bool = false) {
        let target = windowNumber ?? host.windowNumber
        if value == postedInset, target == postedInsetWindow,
           Date().timeIntervalSince(lastInsetPost) < 2 { return }
        let elapsed = Date().timeIntervalSince(lastInsetPost)
        let throttle: TimeInterval = 1.0 / 30.0
        if !force, value != 0, elapsed < throttle {
            pendingInset = value
            if insetPostWorkItem == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.insetPostWorkItem = nil
                    guard let pending = self.pendingInset else { return }
                    self.pendingInset = nil
                    self.postInset(pending, windowNumber: target, force: true)
                }
                insetPostWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + (throttle - elapsed), execute: work)
            }
            return
        }
        pendingInset = nil
        postedInset = value
        postedInsetWindow = target
        lastInsetPost = Date()
        var body: [String: Any] = ["right": Double(value)]
        if let target { body["window"] = target }
        cmdy.post("/v1/ui/inset", body) { [weak self] resp in
            guard let self, let resp else { return }
            var changed = false
            if let s = resp["side"] as? Double, CGFloat(s) != self.dockSide {
                self.dockSide = CGFloat(s); changed = true
            }
            if let trailing = resp["trailing"] as? Double,
               CGFloat(trailing) != self.dockTrailing {
                self.dockTrailing = CGFloat(trailing); changed = true
            }
            if changed { self.tick() }
        }
    }

    private func retime(_ interval: TimeInterval) {
        guard interval != glueInterval else { return }
        glueInterval = interval
        glue?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = interval < 0.02 ? 0 : interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        glue = timer
    }

    private func tick() {
        guard let window = simWindow else { retime(0.15); return }
        let cmdyFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == parentPid
        let simulatorFrontmost = simulatorPid().map {
            NSRunningApplication(processIdentifier: $0)?.isActive == true
        } ?? false
        let sidecarFrontmost = NSRunningApplication.current.isActive
        let attachedSurfaceIsActive = (cmdyFrontmost && hostForeground)
            || simulatorFrontmost || sidecarFrontmost
        let shouldRemainVisible = attachedSurfaceIsActive
            || Date() < tapHoldUntil    // an agent tap is in flight — stay up
        guard shouldRemainVisible, let host = cmdyWindowFrame() else {
            hideSimulator()   // don't cover the app you switched to
            grip.orderOut(nil); retime(0.3); wasFrontmost = false; return
        }
        // Coming back into focus: raise it above the terminal again.
        if simHidden, let pid = simulatorPid() {
            NSRunningApplication(processIdentifier: pid)?.unhide()
        }
        if !wasFrontmost || simHidden { AXKit.raise(window) }
        wasFrontmost = true
        simHidden = false
        let hostSizeChanged = host.size != lastHost.size
        if host != lastHost { lastHost = host; hotUntil = Date().addingTimeInterval(1.0) }
        retime(Date() < hotUntil ? trackingInterval : 0.15)

        let previousSimulatorSize = lastSimulatorSize
        let refreshSimulatorSize = previousSimulatorSize == .zero
            || (Date() >= hotUntil && Date().timeIntervalSince(lastSimulatorFrameRead) >= 0.5)
        let layout = dockLayout(window: window, host: host,
                                refreshSimulatorSize: refreshSimulatorSize)
        let simulatorSizeChanged = previousSimulatorSize != .zero
            && lastSimulatorSize != previousSimulatorSize
        postInset(layout.stripWidth)
        placeSimWindow(window, layout: layout)
        let minimumIsExhausted = layout.isUnfittableMinimum(minimumPresetSize)
        if !hostLiveResize, !minimumIsExhausted {
            if hostSizeChanged || simulatorSizeChanged {
                schedulePresetFit(after: layout.simulatorFits ? 0.25 : 0.05,
                                  restart: true)
            } else if !layout.simulatorFits {
                schedulePresetFit(after: 0.05)
            }
        }

        // The transparent dock window owns the seam; its cardView is inset by
        // `pad` on every edge, matching Browser. Simulator shares its center.
        if grip.frame != layout.cardFrame { grip.setFrame(layout.cardFrame, display: true) }
        if !grip.isVisible {
            grip.orderFront(nil)
            AXKit.raise(window)   // the phone stays above its card
        }
    }

    private func handle(_ event: [String: Any]) {
        switch event["kind"] as? String {
        case "window-frame":
            guard let value = event["window"] as? NSNumber else { return }
            let number = CGWindowID(value.uint32Value)
            activeCmdyWindow = number
            guard host.observe(number, attached: simWindow != nil) else { return }
            hostForeground = true
            let wasLiveResizing = hostLiveResize
            hostLiveResize = (event["liveResize"] as? NSNumber)?.boolValue ?? false
            if hostLiveResize, !autoFitInFlight {
                autoFitWorkItem?.cancel()
                autoFitWorkItem = nil
            } else if wasLiveResizing, !hostLiveResize {
                schedulePresetFit(after: 0.08, restart: true)
            }
            hotUntil = Date().addingTimeInterval(0.5)
            retime(trackingInterval)
            tick()
        case "window-state":
            guard let value = event["window"] as? NSNumber else { return }
            let number = CGWindowID(value.uint32Value)
            if event["state"] as? String == "closed" {
                _ = terminateMirror(in: number)
                if activeCmdyWindow == number {
                    activeCmdyWindow = nil
                }
            }
            guard host.matches(number) else { return }
            switch event["state"] as? String {
            case "closed": closeAttachedHost()
            case "hidden":
                hostForeground = false
                hideSimulator()
                grip.orderOut(nil)
                wasFrontmost = false
            case "background":
                hostForeground = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                    self?.tick()
                }
            case "foreground", "visible":
                hostForeground = true
                tick()
            default: break
            }
        case "app-activation":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.tick()
            }
        case "companion-replaced":
            let pid = simulatorPid()
            releaseSimulator()
            if let pid { _ = NSRunningApplication(processIdentifier: pid)?.hide() }
        case "command", "hotkey":
            let requestedWindow = (event["window"] as? NSNumber).map {
                CGWindowID($0.uint32Value)
            }
            switch event["id"] as? String {
            case "sim.dock": adoptSimulator()
            case "sim.undock": releaseSimulator()
            case "sim.mirror":
                _ = startMirror(
                    windowNumber: requestedWindow, device: nil)
                offerAgentIfNeeded()
            case "sim.mirror.stop":
                _ = stopMirror(windowNumber: requestedWindow, all: false)
            case "sim.annotate": beginFeedback()
            default: break
            }
        default: break
        }
    }

    private func simulatorWindowNumber() -> CGWindowID? {
        guard let pid = simulatorPid(),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        return windows.compactMap { info -> (CGWindowID, CGFloat)? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let raw = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return nil }
            return (CGWindowID(number.uint32Value), bounds.width * bounds.height)
        }.max(by: { $0.1 < $1.1 })?.0
    }

    private func beginFeedback() {
        guard AXKit.trusted(prompt: true),
              let window = simWindow ?? currentSimulatorWindow(),
              let pid = simulatorPid() else {
            NSSound.beep()
            flashProgress("Accessibility permission and a running Simulator are required")
            return
        }
        tapHoldUntil = Date().addingTimeInterval(60)
        if simWindow == nil { dock(window) }
        feedbackOverlay.begin(window: window, simulatorPID: pid,
                              metadata: api.feedbackMetadata(), restorePID: parentPid) { [weak self] record in
            guard let self else { return }
            let stored = self.api.recordFeedback(record)
            self.cmdy.submitFeedback(stored, windowNumber: self.host.windowNumber)
            self.tapHoldUntil = .distantPast
        }
    }

    private func offerAgentIfNeeded() {
        guard !offeredAgent else { return }
        offeredAgent = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.cmdy.offerAgentAttach(windowNumber: self.host.windowNumber)
        }
    }

    private func closeAttachedHost() {
        let target = host.windowNumber
        quitSimulator()
        simWindow = nil
        offeredAgent = false
        savedFrame = nil
        cachedSimulatorPid = nil
        simHidden = false
        wasFrontmost = false
        autoFitWorkItem?.cancel()
        autoFitWorkItem = nil
        autoFitInFlight = false
        insetPostWorkItem?.cancel()
        insetPostWorkItem = nil
        pendingInset = nil
        lastSimulatorSize = .zero
        blockedUpscale = nil
        minimumPresetSize = nil
        presetIndexHint = nil
        if let target { postInset(0, windowNumber: target, force: true) }
        grip.orderOut(nil)
        host.clear()
        hostForeground = true
        hostLiveResize = false
        lastHost = .zero
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminateAllMirrors()
        quitSimulator()   // quit cmdy (or close its window) → the Simulator goes too
        var body: [String: Any] = ["right": 0]
        if let target = host.windowNumber { body["window"] = target }
        cmdy.post("/v1/ui/inset", body)
        usleep(150_000)
        api.stop()
    }
}

final class DividerGrip: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    private var lastX: CGFloat = 0
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { lastX = NSEvent.mouseLocation.x }
    override func mouseDragged(with event: NSEvent) { let x = NSEvent.mouseLocation.x; onDrag?(x - lastX); lastX = x }
    override func mouseUp(with event: NSEvent) { onDragEnd?() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Sim()
app.delegate = delegate
app.run()
