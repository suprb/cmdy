import AppKit
import Darwin
import ApplicationServices  // AXUIElement / kAXMainAttribute / kAXRaiseAction

// Private CG/AX API: maps an AXUIElement window to its CGWindowID. Standard
// practice in this corner of macOS — used by window managers, Rectangle, BTT,
// etc. Without it we can only enumerate AX windows; we can't match them to a
// specific CGWindowID we've cached.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Sends text into the terminal that owns a given session by activating its app
/// and synthesizing ⌘V against the system pasteboard.
///
/// Per-character key injection is fragile (focus loss, IME interactions, repeats)
/// and slow for anything more than a few characters, so we always go through the
/// pasteboard.
@MainActor
enum TextInjection {

    /// Returns true only for the product host's application bundle.
    static func isTerminalApp(bundleId: String) -> Bool {
        isKnownTerminalBundle(bundleId)
    }

    /// Terminal applications are valid only as host-owned sources. Do not
    /// offer another terminal as a generic native automation target.
    static func isTerminalLikeApp(bundleId: String) -> Bool {
        if isKnownTerminalBundle(bundleId) { return true }
        return [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable",
            "dev.warp.Warp",
            "net.kovidgoyal.kitty",
            "org.alacritty",
            "com.github.wez.wezterm",
        ].contains(bundleId)
    }

    /// Bring the session's terminal app to front and paste `text` there. When
    /// `pressReturn` is true also synthesizes Return after pasting — used by the
    /// in-page inspector toolbar where pressing Return submits to Claude.
    /// `targetWindowId` (when set) AX-raises that specific window of the app
    /// before pasting, so multi-window terminal apps don't paste into whatever
    /// window happens to be key-focused.
    static func send(_ text: String, to session: TerminalSession, pressReturn: Bool = false, targetWindowId: CGWindowID? = nil) async {
        NSLog("[Bridge] TextInjection start (sessionId=%@, terminalApp=%@)", session.id, session.terminalApp)

        guard let app = resolveRunningApp(for: session) else {
            NSLog("[Bridge] TextInjection failed — no NSRunningApplication for session %@ (terminalApp=%@, pid=%d)",
                  session.id, session.terminalApp, session.pid)
            return
        }

        // Activate the target app (no options needed on macOS 14+).
        app.activate()

        // For multi-window terminal apps, app.activate() brings the app to
        // front but Cmd+V still goes to whichever window was last key-focused.
        // AX-raise the SPECIFIC bound window so the paste lands in the right
        // terminal. Best-effort — fails silently if Accessibility isn't granted.
        if let targetWindowId = targetWindowId {
            raiseWindow(withId: targetWindowId, in: app.processIdentifier)
        }

        // Snapshot pasteboard so we can restore it after pasting.
        let pb = NSPasteboard.general
        let savedString = pb.string(forType: .string)
        let savedItems = snapshotPasteboardItems(pb)

        pb.clearContents()
        pb.setString(text, forType: .string)

        // Wait for activation to actually take effect — when the call originates from
        // Chrome (e.g. inspector toolbar Send), 80ms wasn't enough and ⌘V landed in
        // Chrome instead of the terminal. Poll up to 500ms for the target app to
        // become frontmost; fall through if activation didn't happen (probably
        // Accessibility prompt pending).
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                break
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            NSLog("[Bridge] TextInjection: target app didn't become frontmost within 500ms; pasting anyway")
        }

        synthesizeCmdV()

        // Wait for paste to land before restoring the pasteboard.
        try? await Task.sleep(nanoseconds: 80_000_000)

        if pressReturn {
            synthesizeReturn()
            try? await Task.sleep(nanoseconds: 40_000_000)
        }

        restorePasteboard(pb, items: savedItems, fallbackString: savedString)

        NSLog("[Bridge] TextInjection done (sessionId=%@)", session.id)
    }

    // MARK: - Resolving the target app

    /// Try direct PID lookup first (works when the session pid IS the terminal app).
    /// If the registered pid is a child process (e.g. claude/zsh inside the terminal),
    /// fall back to bundle-id lookup, then walk up the parent chain.
    private static func resolveRunningApp(for session: TerminalSession) -> NSRunningApplication? {
        if let direct = NSRunningApplication(processIdentifier: pid_t(session.pid)),
           direct.bundleIdentifier == BridgeHostIdentity.bundleIdentifier {
            return direct
        }

        if let bundleId = bundleId(forTerminalApp: session.terminalApp) {
            let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            if let first = candidates.first {
                return first
            }
        }

        // Walk up the parent chain via sysctl, looking for an ancestor whose owning
        // app matches a known terminal bundle id.
        var pid = session.pid
        for _ in 0..<8 {
            let parent = parentPID(of: pid)
            if parent <= 1 { break }
            if let app = NSRunningApplication(processIdentifier: pid_t(parent)),
               let bid = app.bundleIdentifier,
               isKnownTerminalBundle(bid) {
                return app
            }
            pid = parent
        }

        NSLog("[Bridge] Could not resolve %@ for session %@ (terminalApp=%@).",
              BridgeHostIdentity.displayName, session.id, session.terminalApp)
        return nil
    }

    /// Bridge belongs to the product host, not a generic terminal injector.
    private static func bundleId(forTerminalApp app: String) -> String? {
        app.caseInsensitiveCompare(BridgeHostIdentity.slug) == .orderedSame
            ? BridgeHostIdentity.bundleIdentifier : nil
    }

    private static func isKnownTerminalBundle(_ bundleId: String) -> Bool {
        bundleId == BridgeHostIdentity.bundleIdentifier
    }

    // MARK: - sysctl parent-pid lookup

    private static func parentPID(of pid: Int32) -> Int32 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { ptr -> Int32 in
            sysctl(ptr.baseAddress, u_int(ptr.count), &info, &size, nil, 0)
        }
        if result != 0 || size == 0 { return -1 }
        return info.kp_eproc.e_ppid
    }

    // MARK: - Keystroke synthesis

    private static func synthesizeCmdV() {
        // keyCode 9 = "V"
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) else {
            NSLog("[Bridge] Failed to synthesize CGEvent for ⌘V")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Find the AX window matching `targetId` in the app and raise it.
    /// Enumerates the app's windows via AX and resolves each to its CGWindowID
    /// via the private `_AXUIElementGetWindow` so we can match the cached id
    /// from the wire overlay's sticky cache.
    private static func raiseWindow(withId targetId: CGWindowID, in pid: pid_t) {
        let appRef = AXUIElementCreateApplication(pid)
        var windowsRef: AnyObject?
        let getStatus = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef)
        guard getStatus == .success, let windows = windowsRef as? [AXUIElement] else {
            NSLog("[Bridge] raiseWindow: couldn't enumerate AX windows for pid %d (status=%d)", pid, getStatus.rawValue)
            return
        }
        for window in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(window, &wid) == .success, wid == targetId {
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                NSLog("[Bridge] raiseWindow: raised window id=%u in pid %d", targetId, pid)
                return
            }
        }
        NSLog("[Bridge] raiseWindow: target window id=%u not found among %d AX windows for pid %d",
              targetId, windows.count, pid)
    }

    private static func synthesizeReturn() {
        // keyCode 36 = Return
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false) else {
            NSLog("[Bridge] Failed to synthesize CGEvent for Return")
            return
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Pasteboard helpers (mirror SelectionCapture)

    private static func snapshotPasteboardItems(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.compactMap { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restorePasteboard(_ pb: NSPasteboard, items: [NSPasteboardItem], fallbackString: String?) {
        pb.clearContents()
        if !items.isEmpty {
            pb.writeObjects(items)
        } else if let s = fallbackString {
            pb.setString(s, forType: .string)
        }
    }
}
