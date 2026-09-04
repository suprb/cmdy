import AppKit
import CoreGraphics
import CEFBridge
import ChromiumSupport
import CmdySDK

// chromium — real Chromium (multi-process, GPU) as a cmdy sidecar.
//
// A plugin is an external process, so it cannot put an NSView inside
// cmdy's window. What it CAN do: own a chromeless window and glue it to
// cmdy's frontmost window like a split — visible only while cmdy is
// frontmost, tracking its frame. The controls stay properly inline: the URL
// controls live in Cmdy's persistent Extension row, the palette carries
// commands, and the pump/lifecycle live out here.
//
// The split is REAL, not just painted: the plugin reserves its strip through
// POST /v1/ui/inset, cmdy reflows its panes to end at the divider, and a
// grip on the sidecar's left edge resizes both sides like any split divider.
//
// CEF specifics mirror Braincell's proven setup: the binary re-execs as its
// own subprocess helper (GPU/renderer), the framework loads from Frameworks/
// next to the executable, and an external message pump ticks at ~60Hz.

// Subprocess short-circuit MUST run before anything else: CEF re-launches
// this same binary as its GPU/renderer/etc helpers, marked by --type=…
// (the parent must NOT take this path — CefExecuteProcess would eat it).
// Subprocesses load the framework themselves, then exec.
private func prepareCEFHelperLibraries() {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
    let executableDirectory = executable.deletingLastPathComponent()
    let libraries = executableDirectory
        .appendingPathComponent("Frameworks/Chromium Embedded Framework.framework/Libraries")
    for name in ["libGLESv2.dylib", "libEGL.dylib", "libvk_swiftshader.dylib"] {
        let link = executableDirectory.appendingPathComponent(name)
        let target = libraries.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: link.path),
              FileManager.default.fileExists(atPath: target.path) else { continue }
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    }
}

prepareCEFHelperLibraries()
if CommandLine.arguments.contains(where: { $0.hasPrefix("--type=") }) {
    let exeDir = (Bundle.main.executablePath! as NSString).deletingLastPathComponent
    let fw = exeDir + "/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework"
    _ = cef_bridge_load_library(fw)
    exit(Int32(cef_bridge_subprocess_exec()))
}

/// The split divider on the sidecar's left edge: drag to resize the browser
/// against the terminal, exactly like a pane divider. Draws nothing — the
/// card's own edge is the affordance; the resize cursor confirms it.
final class DividerGrip: NSView {
    var onDrag: ((CGFloat) -> Void)?      // horizontal delta in screen points
    var onDragEnd: (() -> Void)?
    private var lastX: CGFloat = 0

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { lastX = NSEvent.mouseLocation.x }
    override func mouseDragged(with event: NSEvent) {
        let x = NSEvent.mouseLocation.x
        onDrag?(x - lastX)
        lastX = x
    }
    override func mouseUp(with event: NSEvent) { onDragEnd?() }
}

/// Borderless sidecars do not become key or main windows by default. CEF's
/// native child view needs a key window for mouse focus and keyboard input.
final class BrowserWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class BrowserSession {
    struct CapturePresentation {
        let frame: NSRect
        let wasVisible: Bool
        let hadShadow: Bool
    }

    let hostWindow: CGWindowID
    let window: BrowserWindow
    let container: NSView
    let grip: DividerGrip
    var browser: CEFBrowserHandle?
    var visible = true
    var screenshotHold = false
    var capturePresentation: CapturePresentation?
    var dockWidth: CGFloat
    var insetSync = CmdySidecarInsetSync()
    var dockSide: CGFloat = 25
    var dockTrailing: CGFloat = 0
    var lastHost = NSRect.zero
    var hostForeground = true
    var hotUntil = Date.distantPast
    var lastBrowserSize = NSSize.zero
    var offeredAgent = false
    var controlBarID: String?

    init(hostWindow: CGWindowID, window: BrowserWindow, container: NSView,
         grip: DividerGrip, dockWidth: CGFloat) {
        self.hostWindow = hostWindow
        self.window = window
        self.container = container
        self.grip = grip
        self.dockWidth = dockWidth
    }
}

/// CEF gives its C callback one opaque pointer. Preserve the Browser session's
/// exact Cmdy host window in that pointer so simultaneous Browser sidecars
/// cannot route console results or semantic feedback to whichever window was
/// most recently active.
private final class BrowserConsoleContext {
    let api: BrowserAPI
    let hostWindow: CGWindowID
    let onPageLoaded: (CGWindowID, String) -> Void
    let onClosed: (CGWindowID, CEFBrowserHandle?) -> Void

    init(api: BrowserAPI, hostWindow: CGWindowID,
         onPageLoaded: @escaping (CGWindowID, String) -> Void,
         onClosed: @escaping (CGWindowID, CEFBrowserHandle?) -> Void) {
        self.api = api
        self.hostWindow = hostWindow
        self.onPageLoaded = onPageLoaded
        self.onClosed = onClosed
    }
}

private let nativeBrowserOperations = ChromiumBrowserOperations(
    executeJavaScript: { cef_bridge_execute_js($0, $1) },
    reload: { cef_bridge_reload($0) },
    goBack: { cef_bridge_go_back($0) },
    goForward: { cef_bridge_go_forward($0) },
    currentURL: {
        guard let raw = cef_bridge_get_url($0) else { return "" }
        defer { free(raw) }
        return String(cString: raw)
    })

final class ChromiumPlugin: NSObject, NSApplicationDelegate {
    private var cmdy: Cmdy!
    private var sessions: [CGWindowID: BrowserSession] = [:]
    private var activeHostWindow: CGWindowID?
    private var defaultDockWidth: CGFloat = 0
    private var pump: Timer?
    private var glue: Timer?
    private var glueInterval: TimeInterval = 0
    private let parentPid = getppid()    // cmdy launched us
    private let api = BrowserAPI(operations: nativeBrowserOperations)
                                              // agent↔browser HTTP layer
    private var sigTerm: DispatchSourceSignal?
    private var keyMonitor: Any?
    private let gripWidth: CGFloat = 8
    private let trackingInterval: TimeInterval = 1.0 / 240.0

    private var active: BrowserSession? {
        activeHostWindow.flatMap { sessions[$0] }
    }

    private var cacheDir: String {
        HostProductIdentity.environmentValue("CHROMIUM_CACHE")
            ?? NSHomeDirectory() + "/.cache/\(HostProductIdentity.slug)-chromium"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let sdk = Cmdy() else {
            FileHandle.standardError.write(Data(
                ("chromium: not launched by \(HostProductIdentity.name) "
                    + "(missing \(HostProductIdentity.environmentPrefix)_* env)\n").utf8))
            exit(1)
        }
        cmdy = sdk

        guard initCEF() else {
            fputs("chromium: CEF failed to initialize — is Frameworks/ populated? (README-CEF.md)\n", stderr)
            exit(1)
        }
        loadUIState()
        installEditMenu()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self,
                  event.modifierFlags
                    .intersection([.command, .option, .control, .shift]) == [.command],
                  event.charactersIgnoringModifiers?.lowercased() == "l",
                  let session = self.sessions.values.first(where: { $0.window === event.window })
            else { return event }
            self.activeHostWindow = session.hostWindow
            if let id = session.controlBarID {
                self.cmdy.updateControlBar(id, ["focus": true])
            } else {
                self.showControlBar(for: session, focus: true)
            }
            return nil
        }

        // Toggle-off in the Plugins panel is a SIGTERM: route it through
        // NSApp.terminate so applicationWillTerminate runs (inset release,
        // discovery-file cleanup, CEF shutdown).
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigTerm = src

        // Agent↔browser layer: any local agent can drive this sidecar over
        // HTTP (discovery: ~/.config/cmdy/browser-api.json; MCP stdio
        // shim: mcp/index.js next to the binary). Tool calls summon the
        // sidecar; they never re-navigate an existing browser.
        api.ensureBrowser = { [weak self] hostWindow in
            guard let self else { return nil }
            self.setVisible(true, hostWindow: hostWindow)
            return self.active?.browser
        }
        api.navigateBrowser = { [weak self] url, hostWindow in
            self?.navigateBrowser(to: url, hostWindow: hostWindow) ?? false
        }
        api.windowForScreenshot = { [weak self] hostWindow in
            guard let self else { return nil }
            self.setVisible(true, hostWindow: hostWindow)
            guard let session = self.active else { return nil }
            session.screenshotHold = true
            let hostIsActive =
                NSWorkspace.shared.frontmostApplication?.processIdentifier == self.parentPid
                && session.hostForeground
            let sidecarIsActive = NSRunningApplication.current.isActive
            if SidecarCapturePolicy.shouldParkOffscreen(
                hostIsActive: hostIsActive,
                sidecarIsActive: sidecarIsActive
            ) {
                session.capturePresentation = .init(
                    frame: session.window.frame,
                    wasVisible: session.window.isVisible,
                    hadShadow: session.window.hasShadow)
                let desktopBounds = NSScreen.screens
                    .map(\.frame)
                    .reduce(NSRect.null) { $0.union($1) }
                session.window.hasShadow = false
                session.window.setFrame(
                    SidecarCapturePolicy.parkedFrame(
                        for: session.window.frame,
                        desktopBounds: desktopBounds.isNull
                            ? NSRect(x: 0, y: 0, width: 1, height: 1)
                            : desktopBounds),
                    display: false)
                if !session.window.isVisible { session.window.orderFront(nil) }
            } else if !session.window.isVisible {
                session.window.orderFront(nil)
            }
            return session.window
        }
        api.screenshotDone = { [weak self] hostWindow in
            self?.finishScreenshot(hostWindow: hostWindow)
        }
        api.feedbackReceived = { [weak self] hostWindow, record in
            guard let self, let session = self.sessions[hostWindow] else { return }
            var enriched = record
            enriched["window"] = Int(session.hostWindow)
            self.cmdy.submitFeedback(
                enriched, windowNumber: session.hostWindow
            ) { [weak self] response in
                guard let self else { return }
                if response?["ok"] as? Bool == true {
                    NSLog("chromium: feedback %@ delivered to pane %@ as %@",
                          record["id"] as? String ?? "unknown",
                          response?["pane"] as? String ?? "?",
                          response?["delivery"] as? String ?? "?")
                } else {
                    let detail = response?["error"] as? String
                        ?? "the paired terminal did not accept the note"
                    NSLog("chromium: feedback delivery failed: %@", detail)
                    self.cmdy.notify(
                        title: "Browser feedback saved but not delivered",
                        body: detail)
                }
            }
        }
        api.start()

        cmdy.registerCommand(id: "chromium.toggle", title: "Show/Hide", plugin: "Browser")
        cmdy.registerCommand(id: "chromium.open", title: "Open URL…", plugin: "Browser")
        cmdy.registerCommand(id: "chromium.reload", title: "Reload", plugin: "Browser")
        cmdy.registerCommand(id: "chromium.devtools", title: "DevTools", plugin: "Browser")
        cmdy.registerCommand(id: "chromium.annotate", title: "Add UI Feedback", plugin: "Browser")
        cmdy.registerHook(id: "chromium.navigate-intent", boundary: .command, priority: 50)
        cmdy.registerHotKey(id: "chromium.toggle", keyCode: 5 /* G */,
                               modifiers: [.command, .shift])
        cmdy.onEvent = { [weak self] event in self?.handle(event) }
        cmdy.listen()
        // If cmdy dies without terminating us, shut CEF down so the profile
        // lock is released (an orphaned chromium blocks the next launch's init).
        cmdy.onParentExit = { [weak self] in
            self?.api.stop()
            self?.sessions.values.forEach {
                if let browser = $0.browser { cef_bridge_close_browser(browser) }
            }
            if cef_bridge_shutdown_and_wait(10_000) != 1 {
                fputs("chromium: timed out waiting for sandboxed CEF shutdown\n", stderr)
            }
        }

        // Follow cmdy: glue to its frontmost window, vanish with it.
        retime(0.1)
        NSLog("chromium: ready (CEF up, waiting for toggle)")

        // Test hook: CMDY_CHROMIUM_AUTOSHOW=1 toggles the sidecar on
        // launch — the automated gates cannot press palette keys.
        if HostProductIdentity.environmentValue("CHROMIUM_AUTOSHOW") == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.setVisible(true)
            }
        }
    }

    // MARK: - CEF lifecycle

    /// AppKit implements the standard editing shortcuts through Edit-menu key
    /// equivalents. Accessory apps do not receive that menu automatically, so
    /// install the normal responder-chain actions for CEF's native child view.
    private func installEditMenu() {
        let main = NSMenu()
        let editRoot = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")

        func item(_ title: String, _ action: Selector, _ key: String,
                  modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let value = NSMenuItem(title: title, action: action, keyEquivalent: key)
            value.keyEquivalentModifierMask = modifiers
            return value
        }

        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", modifiers: [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))

        main.addItem(editRoot)
        main.setSubmenu(edit, for: editRoot)
        NSApp.mainMenu = main
    }

    private func initCEF() -> Bool {
        let executableDirectory = URL(fileURLWithPath: Bundle.main.executablePath!)
            .deletingLastPathComponent()
        // Marketplace builds are a self-contained, separately signed helper
        // app. Source builds retain the historical flat executable layout.
        // Keeping both layouts here lets Browser remain an ordinary removable
        // Extension without weakening Chromium's macOS sandbox.
        let bundledFrameworks = Bundle.main.privateFrameworksURL
            ?? Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Frameworks", isDirectory: true)
        let flatFrameworks = executableDirectory.appendingPathComponent(
            "Frameworks", isDirectory: true)
        let frameworks = FileManager.default.fileExists(
            atPath: bundledFrameworks.appendingPathComponent(
                "Chromium Embedded Framework.framework").path)
            ? bundledFrameworks : flatFrameworks
        let framework = frameworks.appendingPathComponent(
            "Chromium Embedded Framework.framework/Chromium Embedded Framework")
        guard FileManager.default.fileExists(atPath: framework.path),
              cef_bridge_load_library(framework.path) == 1 else { return false }

        let bundleName = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleName") as? String ?? "cmdy Browser"
        let helperName = "\(bundleName) Helper"
        let helper = frameworks.appendingPathComponent(
            "\(helperName).app/Contents/MacOS/\(helperName)")
        let helperPath: String? = FileManager.default.isExecutableFile(
            atPath: helper.path) ? helper.path : nil
        // Chromium locks its profile dir — a second instance (a gate running
        // beside a live cmdy) needs its own via CMDY_CHROMIUM_CACHE.
        guard cef_bridge_init(helperPath, cacheDir) == 1 else { return false }
        // External message pump: tick CEF on the main thread at ~60Hz.
        pump = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            cef_bridge_do_message_loop_work()
        }
        return true
    }

    private func makeSession(hostWindow: CGWindowID) -> BrowserSession {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        root.autoresizesSubviews = true
        // Browser controls live in Cmdy's persistent Extension control row,
        // so Chromium can use the complete sidecar surface.
        let container = NSView(frame: root.bounds)
        container.autoresizingMask = [.width, .height]
        container.autoresizesSubviews = true
        let grip = DividerGrip(frame: NSRect(x: 0, y: 0, width: gripWidth, height: root.frame.height))
        grip.autoresizingMask = [.height]
        grip.onDrag = { [weak self] dx in
            self?.activeHostWindow = hostWindow
            self?.dividerDragged(dx)
        }
        grip.onDragEnd = { [weak self] in
            self?.activeHostWindow = hostWindow
            self?.dividerDragEnded()
        }
        root.addSubview(container)
        root.addSubview(grip)   // above the browser: it takes the edge hits
        let window = BrowserWindow(contentRect: root.frame,
                                   styleMask: [.borderless],
                                   backing: .buffered, defer: false)
        window.contentView = root
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        // A rounded card floating inside the terminal, not a hard-edged slab.
        window.backgroundColor = .clear
        window.isOpaque = false
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        window.level = .floating            // rides above the cmdy window it hugs
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        return BrowserSession(hostWindow: hostWindow, window: window,
                              container: container, grip: grip,
                              dockWidth: defaultDockWidth)
    }

    private func ensureBrowser(url: String) {
        guard let session = active else { return }
        if session.browser == nil {
            // One retained context per asynchronous create. A host window may
            // be closed and reopened before the old CEF browser reaches
            // OnBeforeClose, so hostWindow alone is not a safe identity.
            let consoleContext = BrowserConsoleContext(
                api: api, hostWindow: session.hostWindow,
                onPageLoaded: { [weak self] hostWindow, url in
                    self?.browserDidLoad(url, hostWindow: hostWindow)
                },
                onClosed: { [weak self] hostWindow, browser in
                    self?.browserDidClose(
                        hostWindow: hostWindow, browser: browser)
                })
            let retainedContext = Unmanaged.passRetained(consoleContext)
            // Console messages feed the API: __CMDY_RESULT__ lines resolve
            // pending JS evals, everything else lands in the console buffer.
            let browser = cef_bridge_create_browser_v2(
                Unmanaged.passUnretained(session.container).toOpaque(), url,
                nil,
                { _, url, ctx in
                    guard let ctx else { return }
                    let context = Unmanaged<BrowserConsoleContext>
                        .fromOpaque(ctx).takeUnretainedValue()
                    let value = url.map { String(cString: $0) } ?? ""
                    context.onPageLoaded(context.hostWindow, value)
                },
                { _, msg, src, line, ctx in
                    guard let ctx, let msg else { return }
                    let context = Unmanaged<BrowserConsoleContext>
                        .fromOpaque(ctx).takeUnretainedValue()
                    context.api
                        .handleConsoleMessage(String(cString: msg),
                                              source: src.map { String(cString: $0) } ?? "",
                                              line: Int(line),
                                              hostWindow: context.hostWindow)
                },
                { browser, ctx in
                    guard let ctx else { return }
                    let context = Unmanaged<BrowserConsoleContext>
                        .fromOpaque(ctx).takeRetainedValue()
                    context.onClosed(context.hostWindow, browser)
                },
                retainedContext.toOpaque())
            guard let browser else {
                retainedContext.release()
                return
            }
            session.browser = browser
            if let b = session.browser {
                cef_bridge_resize_browser(b, Int32(session.container.frame.width),
                                           Int32(session.container.frame.height))
                session.lastBrowserSize = session.container.frame.size
            }
        } else if let b = session.browser {
            cef_bridge_navigate(b, url)
        }
    }

    /// One switch for user intent: creates the browser on first show, keeps
    /// the reserved strip in sync (0 when hidden), and repositions.
    private func setVisible(_ on: Bool, initialURL: String? = nil,
                            focusControl: Bool = false,
                            hostWindow: CGWindowID? = nil) {
        if let hostWindow { activeHostWindow = hostWindow }
        if on, active == nil {
            guard let target = activeHostWindow ?? frontmostCmdyWindowNumber() else { return }
            activeHostWindow = target
            sessions[target] = makeSession(hostWindow: target)
        }
        guard let session = active else { return }
        session.visible = on
        if on {
            showControlBar(for: session, value: initialURL, focus: focusControl)
        }
        if on, session.browser == nil { ensureBrowser(url: initialURL ?? currentOrHome()) }
        if on, !session.offeredAgent {
            session.offeredAgent = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.cmdy.offerAgentAttach(windowNumber: session.hostWindow)
            }
        }
        if !on {
            dismissControlBar(for: session)
            postInset(0, windowNumber: session.hostWindow)
            session.window.orderOut(nil)
            session.hostForeground = true
            session.lastHost = .zero
        }
        tick()
    }

    private func annotate(_ session: BrowserSession) {
        activeHostWindow = session.hostWindow
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.api.execute(
                    tool: "begin_feedback", arguments: [:],
                    hostWindow: session.hostWindow)
            } catch {
                NSSound.beep()
                NSLog("chromium: feedback picker failed: %@", error.localizedDescription)
            }
        }
    }

    private func showControlBar(for session: BrowserSession, value: String? = nil,
                                focus: Bool = false) {
        let id = session.controlBarID ?? "browser-\(session.hostWindow)"
        session.controlBarID = id
        let shownValue = displayURL(value ?? currentURL(for: session))
        cmdy.openControlBar([
            "id": id,
            "window": Int(session.hostWindow),
            "actions": [
                ["id": "back", "title": "←"],
                ["id": "forward", "title": "→"],
                ["id": "annotate", "title": "Annotate"],
            ],
            "placeholder": "enter URL",
            "value": shownValue,
            "inputFirst": true,
            "focus": focus,
        ])
    }

    private func dismissControlBar(for session: BrowserSession) {
        guard let id = session.controlBarID else { return }
        cmdy.dismissControlBar(id)
        session.controlBarID = nil
    }

    private func browserDidLoad(_ url: String, hostWindow: CGWindowID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let session = self.sessions[hostWindow] else { return }
            NSLog("chromium: loaded %@", url)
            if let id = session.controlBarID {
                self.cmdy.updateControlBar(id, ["value": self.displayURL(url)])
            }
        }
    }

    private func currentURL(for session: BrowserSession) -> String {
        guard let browser = session.browser, let raw = cef_bridge_get_url(browser) else { return "" }
        defer { free(raw) }
        return String(cString: raw)
    }

    private func displayURL(_ url: String) -> String {
        guard !url.isEmpty, url != "about:blank", !url.hasPrefix("file://") else { return "" }
        return url
    }

    // MARK: - The glue: hug cmdy's frontmost window

    private func cmdyWindowFrame() -> NSRect? {
        if let hostWindowNumber = activeHostWindow,
           let list = CGWindowListCopyWindowInfo([.optionIncludingWindow, .excludeDesktopElements],
                                                 hostWindowNumber) as? [[String: Any]],
           let info = list.first,
           let frame = cmdyWindowFrame(from: info) {
            return frame
        }
        if activeHostWindow != nil { return nil }
        guard let number = frontmostCmdyWindowNumber() else { return nil }
        activeHostWindow = number
        return cmdyWindowFrame()
    }

    private func frontmostCmdyWindowNumber() -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard cmdyWindowFrame(from: info) != nil,
                  let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
            return CGWindowID(number.uint32Value)
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

    /// The strip width, derived on first show and clamped so neither side
    /// collapses (browser ≥ 280, terminal ≥ 420).
    private func currentDockWidth(for host: NSRect) -> CGFloat {
        guard let session = active else { return 280 }
        if session.dockWidth == 0 { session.dockWidth = floor(host.width * 0.70) }
        return min(max(280, session.dockWidth), max(280, host.width - 420))
    }

    /// Reserve (or release) the right strip in cmdy. The response carries
    /// the pane-area geometry that lines the sidecar up with the panes.
    /// Re-posted every ~2s while visible — self-heals if the app cleared the
    /// strip (any plugin exit does) or a new window missed it.
    private func postInset(_ value: CGFloat, windowNumber: CGWindowID? = nil) {
        guard let target = windowNumber ?? activeHostWindow,
              let session = sessions[target],
              let next = session.insetSync.update(to: value) else { return }
        sendInset(next, to: target)
    }

    /// Only one inset request per Cmdy window may be in flight. Divider
    /// drags can publish hundreds of intermediate widths; the synchronizer
    /// coalesces them and guarantees that the final width is applied last.
    private func sendInset(_ value: CGFloat, to target: CGWindowID) {
        var body: [String: Any] = ["right": Double(value)]
        body["window"] = target
        cmdy.post("/v1/ui/inset", body) { [weak self] resp in
            DispatchQueue.main.async { [weak self] in
                self?.completeInset(value, for: target, response: resp)
            }
        }
    }

    private func completeInset(_ value: CGFloat, for target: CGWindowID,
                               response: [String: Any]?) {
        guard let session = sessions[target] else { return }
        let succeeded = response?["ok"] as? Bool == true
        let next = session.insetSync.complete(sent: value, succeeded: succeeded)
        if let next { sendInset(next, to: target) }

        guard succeeded, let response else { return }
        var changed = false
        if let side = response["side"] as? Double, CGFloat(side) != session.dockSide {
            session.dockSide = CGFloat(side)
            changed = true
        }
        if let trailing = response["trailing"] as? Double,
           CGFloat(trailing) != session.dockTrailing {
            session.dockTrailing = CGFloat(trailing)
            changed = true
        }
        if changed, activeHostWindow == target { tick() }
    }

    /// Reschedule the glue timer: 60Hz while the host frame is in motion
    /// (window drag/resize), 10Hz at rest — CGWindowList polling is not free.
    private func retime(_ interval: TimeInterval) {
        guard interval != glueInterval else { return }
        glueInterval = interval
        glue?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = interval < 0.02 ? 0 : interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        glue = timer
    }

    private func tick() {
        guard let session = active else { retime(0.1); return }
        if session.screenshotHold { return }
        let cmdyFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == parentPid
        let sidecarFrontmost = NSRunningApplication.current.isActive
        guard session.visible,
              (cmdyFrontmost && session.hostForeground) || sidecarFrontmost,
              let host = cmdyWindowFrame() else {
            if session.window.isVisible { session.window.orderOut(nil) }
            retime(0.1)
            return
        }
        if host != session.lastHost {
            session.lastHost = host
            session.hotUntil = Date().addingTimeInterval(1.0)
        }
        retime(Date() < session.hotUntil ? trackingInterval : 0.1)

        let w = currentDockWidth(for: host)
        postInset(w)                     // no-op unless changed or heartbeat due
        setSidecarFrame(host: host, width: w)
        if !session.window.isVisible { session.window.orderFront(nil) }
    }

    private func finishScreenshot(hostWindow: CGWindowID?) {
        let session = hostWindow.flatMap { sessions[$0] } ?? active
        guard let session else { return }
        if let presentation = session.capturePresentation {
            if !presentation.wasVisible { session.window.orderOut(nil) }
            session.window.setFrame(presentation.frame, display: false)
            session.window.hasShadow = presentation.hadShadow
            session.capturePresentation = nil
        }
        session.screenshotHold = false
        tick()
    }

    /// The card floats inside the reserved strip with a breath of padding on
    /// every side — the strip (and the terminal reflow) is `width` wide, the
    /// visible browser is inset `pad` within it, aligned to the pane area.
    private let pad: CGFloat = 10
    private func setSidecarFrame(host: NSRect, width: CGFloat) {
        guard let session = active else { return }
        let frame = CmdySidecarGeometry.cardFrame(host: host, dockSide: session.dockSide,
                                                     stripWidth: width, padding: pad,
                                                     trailingOffset: session.dockTrailing)
        if session.window.frame != frame {
            session.window.setFrame(frame, display: true)
            session.window.invalidateShadow()
        }
        let size = session.container.frame.size
        if let b = session.browser, size != session.lastBrowserSize {
            session.lastBrowserSize = size
            cef_bridge_resize_browser(b, Int32(size.width), Int32(size.height))
        }
    }

    // MARK: - Divider drag

    private func dividerDragged(_ dx: CGFloat) {
        guard let session = active, session.visible else { return }
        if session.lastHost == .zero { session.lastHost = cmdyWindowFrame() ?? .zero }
        guard session.lastHost != .zero else { return }
        session.dockWidth = currentDockWidth(for: session.lastHost) - dx
        let w = currentDockWidth(for: session.lastHost)
        setSidecarFrame(host: session.lastHost, width: w)
        postInset(w)       // coalesced while the prior inset request is in flight
    }

    private func dividerDragEnded() {
        guard let session = active, session.visible,
              session.lastHost != .zero else { return }
        postInset(currentDockWidth(for: session.lastHost))
        saveUIState()
    }

    // MARK: - UI state (divider position survives relaunch)

    private var uiStateURL: URL {
        URL(fileURLWithPath: cacheDir + "/ui.json")
    }

    private func loadUIState() {
        if let data = readUIState(),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let w = json["dockWidth"] as? Double,
           w.isFinite, w > 0, w <= 16_384 {
            defaultDockWidth = CGFloat(w)
        }
    }

    private func readUIState() -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: uiStateURL) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024 + 1),
              data.count <= 64 * 1024 else { return nil }
        return data
    }

    private func saveUIState() {
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        let width = active?.dockWidth ?? defaultDockWidth
        try? JSONSerialization.data(withJSONObject: ["dockWidth": Double(width)])
            .write(to: uiStateURL)
    }

    // MARK: - SDK events

    // SDK events arrive keyed by "kind" — {kind:"command"|"hotkey", id} and
    // {kind:"ui", panel, event: submit|dismissed|…, value} — same contract
    // bridge and detox consume. (The original handler switched on a
    // nonexistent "event" key, so the palette/menu/hotkey did nothing; the
    // automated gates never caught it because they use the AUTOSHOW hook.)
    private func handle(_ event: [String: Any]) {
        switch event["kind"] as? String {
        case "hook":
            guard let request = event["request"] as? String else { return }
            guard event["hook"] as? String == "chromium.navigate-intent",
                  let command = event["command"] as? String,
                  let url = Self.navigationURL(from: command) else {
                cmdy.respondToHook(request: request, decision: .continue)
                return
            }
            // Answer before touching AppKit: the host intentionally gives all
            // command hooks one very short shared budget.
            cmdy.respondToHook(request: request, decision: .cancel, value: "")
            DispatchQueue.main.async { [weak self] in
                _ = self?.navigateBrowser(to: url)
            }
        case "window-frame":
            guard let value = event["window"] as? NSNumber else { return }
            let number = CGWindowID(value.uint32Value)
            activeHostWindow = number
            if let session = sessions[number] {
                session.hostForeground = true
                session.hotUntil = Date().addingTimeInterval(0.5)
                retime(trackingInterval)
                tick()
            }
        case "window-state":
            guard let value = event["window"] as? NSNumber else { return }
            let number = CGWindowID(value.uint32Value)
            guard let session = sessions[number] else { return }
            switch event["state"] as? String {
            case "closed": closeAttachedHost(number)
            case "hidden":
                session.hostForeground = false
                session.window.orderOut(nil)
            case "background":
                session.hostForeground = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                    guard let self else { return }
                    if self.activeHostWindow == number { self.tick() }
                    else { session.window.orderOut(nil) }
                }
            case "foreground", "visible":
                activeHostWindow = number
                session.hostForeground = true
                tick()
            default: break
            }
        case "app-activation":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.tick()
            }
        case "companion-replaced":
            setVisible(false)
        case "command", "hotkey":
            switch event["id"] as? String {
            case "chromium.toggle":
                setVisible(!(active?.visible ?? false))
            case "chromium.open":
                askForURL()
            case "chromium.reload":
                setVisible(true)
                if let browser = active?.browser { cef_bridge_reload(browser) }
            case "chromium.devtools":
                if let b = active?.browser { cef_bridge_open_devtools(b, nil) }
            case "chromium.annotate":
                guard let session = active else { return }
                annotate(session)
            default: break
            }
        case "ui":
            guard let controlBar = event["controlBar"] as? String,
                  let session = sessions.values.first(where: { $0.controlBarID == controlBar }) else {
                return
            }
            activeHostWindow = session.hostWindow
            switch event["event"] as? String {
            case "action":
                switch event["value"] as? String {
                case "annotate": annotate(session)
                case "back":
                    if let browser = session.browser { cef_bridge_go_back(browser) }
                case "forward":
                    if let browser = session.browser { cef_bridge_go_forward(browser) }
                default: break
                }
            case "submit":
                guard let text = event["value"] as? String,
                      let url = normalizedAddress(text) else { return }
                _ = navigateBrowser(to: url)
            default: break
            }
        default: break
        }
    }

    /// Deliberately narrow: explicit browser verbs plus a destination. Shell
    /// commands and conversational requests continue through the normal host.
    private static func navigationURL(from command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\n") else { return nil }
        let patterns = [
            #"(?i)^navigate\s+to\s+(.+)$"#,
            #"(?i)^browse\s+to\s+(.+)$"#,
            #"(?i)^open\s+(.+?)\s+in\s+(?:the\s+)?browser$"#,
        ]
        var destination: String?
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                  let range = Range(match.range(at: 1), in: trimmed) else { continue }
            destination = String(trimmed[range])
            break
        }
        guard var value = destination?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if value.count >= 2,
           (value.first == "\"" && value.last == "\""
            || value.first == "'" && value.last == "'") {
            value.removeFirst()
            value.removeLast()
        }
        if value.range(of: #"^(?:https?|file|about):"#,
                       options: [.regularExpression, .caseInsensitive]) != nil {
            return value
        }
        if value.range(of: #"^(?:localhost|127\.0\.0\.1|\[::1\])(?::\d+)?(?:/|$)"#,
                       options: [.regularExpression, .caseInsensitive]) != nil {
            return "http://" + value
        }
        guard value.range(of: #"^[^\s]+\.[^\s]+(?:/.*)?$"#,
                          options: .regularExpression) != nil else { return nil }
        return "https://" + value
    }

    private func closeAttachedHost(_ target: CGWindowID) {
        guard let session = sessions[target] else { return }
        let wasActive = activeHostWindow == target
        dismissControlBar(for: session)
        postInset(0, windowNumber: target)
        session.window.orderOut(nil)
        if let browser = session.browser { cef_bridge_close_browser(browser) }
        sessions[target] = nil
        if wasActive { activeHostWindow = nil }
    }

    private func browserDidClose(
        hostWindow: CGWindowID, browser: CEFBrowserHandle?
    ) {
        // A stale close callback must never clear a newer browser generation
        // that reused the same terminal window ID.
        guard let browser, sessions[hostWindow]?.browser == browser else { return }
        sessions[hostWindow]?.browser = nil
    }

    @discardableResult
    private func navigateBrowser(to url: String,
                                 hostWindow: CGWindowID? = nil) -> Bool {
        if let hostWindow { activeHostWindow = hostWindow }
        let hadBrowser = active?.browser != nil
        setVisible(true, initialURL: url, hostWindow: hostWindow)
        guard active?.browser != nil else { return false }
        if hadBrowser { ensureBrowser(url: url) }
        return true
    }

    private func askForURL() {
        setVisible(true, focusControl: true)
    }

    private func normalizedAddress(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.range(of: #"^(?:https?|file|about):"#,
                       options: [.regularExpression, .caseInsensitive]) != nil {
            return value
        }
        if value.range(of: #"^(?:localhost|127\.0\.0\.1|\[::1\])(?::\d+)?(?:/|$)"#,
                       options: [.regularExpression, .caseInsensitive]) != nil {
            return "http://" + value
        }
        if !value.contains(" "), value.contains(".") { return "https://" + value }
        guard let query = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return "https://www.google.com/search?q=\(query)"
    }

    private func currentOrHome() -> String {
        if let b = active?.browser, let raw = cef_bridge_get_url(b) {
            defer { free(raw) }
            let s = String(cString: raw)
            if !s.isEmpty, s != "about:blank" { return s }
        }
        return BrowserStartPage.install(in: cacheDir)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Best-effort strip release: give the request a beat to leave the
        // process (its completion would land on main, which is us). cmdy
        // also clears the strip when any plugin process exits — the belt to
        // this suspender.
        for session in sessions.values {
            dismissControlBar(for: session)
            cmdy.post("/v1/ui/inset", ["right": 0, "window": session.hostWindow])
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        usleep(150_000)
        api.stop()
        for session in sessions.values {
            if let browser = session.browser { cef_bridge_close_browser(browser) }
        }
        if cef_bridge_shutdown_and_wait(10_000) != 1 {
            fputs("chromium: timed out waiting for sandboxed CEF shutdown\n", stderr)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no dock icon — we live inside cmdy's world
let delegate = ChromiumPlugin()
app.delegate = delegate
app.run()
