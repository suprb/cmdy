import AppKit
import Carbon.HIToolbox
import ProductIdentity
import CmdyKit

/// Beam: capture from anywhere in macOS and drop it at any pane's prompt.
/// (A native rewrite of braincell-bridge's world→LLM flow — the terminal
/// already knows every session, so no registration hooks, no heartbeats,
/// no paste simulation.)
///
///   ⌃⌘B — beam the frontmost app's selected text
///   ⌃⌘S — beam a screenshot region (as a file path, so CLI agents Read the
///          image instead of flooding the prompt)
///
/// One pane open → it beams straight in. Several → every pane grows a
/// numbered chip right where it sits (✦ marks panes running an AI CLI);
/// press 1–9 or click a chip, Esc cancels. The text is TYPED at the prompt,
/// never run.
final class BeamManager {
    nonisolated(unsafe) static let shared = BeamManager()

    private let picker = BeamPicker()

    // MARK: - Capture

    /// Selected text of the frontmost app (Accessibility), falling back to
    /// the clipboard when the app doesn't expose its selection.
    func beamSelection() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)   // one-time permission prompt
        var text: String?
        var focused: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
                                         &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let element = unsafeBitCast(focused, to: AXUIElement.self)
            var selection: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                             &selection) == .success,
               let s = selection as? String, !s.isEmpty {
                text = s
            }
        }
        if text == nil {
            text = NSPasteboard.general.string(forType: .string)
        }
        guard let text, !text.isEmpty else {
            // Never fail silently: say WHY nothing beamed.
            NSSound.beep()
            Notifier.post(title: "Beam",
                          body: "Nothing to beam — no selected text visible (grant \(ProductIdentity.current.titleName) Accessibility in System Settings ▸ Privacy) and the clipboard is empty.")
            return
        }
        picker.pick(snippet: text)
    }

    /// Interactive region screenshot → beam the file's path.
    func beamScreenshot() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(ProductIdentity.current.slug)-beam-\(Int(Date().timeIntervalSince1970)).png")
            .path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-x", path]
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard FileManager.default.fileExists(atPath: path) else { return }   // user cancelled
                self?.picker.pick(snippet: TerminalWindowController.shellQuote(path) + " ")
            }
        }
        try? task.run()
    }

    // MARK: - Delivery

    /// Type the snippet at the pane's prompt (bracketed paste for multi-line,
    /// so AI CLIs and zsh receive it as one block) and bring the pane forward.
    static func beam(_ snippet: String, into pane: TerminalPane) {
        let payload = snippet.contains("\n")
            ? "\u{1b}[200~\(snippet)\u{1b}[201~"
            : snippet
        pane.appendPromptInput(payload)
        pane.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pane.focus()
    }

    // Process discovery is much slower than the pane API itself. Return the
    // latest snapshot immediately and refresh it away from AppKit's main queue.
    nonisolated(unsafe) private static var aiToolCache: [pid_t: (tool: String?, at: Date)] = [:]
    nonisolated(unsafe) private static var aiToolRefreshes: Set<pid_t> = []
    private static let aiToolLock = NSLock()
    private static let aiToolQueue = DispatchQueue(
        label: "\(ProductIdentity.current.slug).ai-process-scan",
                                                   qos: .utility)
    private static let aiToolTTL: TimeInterval = 2.0

    /// Name of the AI CLI running on the pane's tty, if any (for the ✦ chip).
    static func aiTool(in pane: TerminalPane) -> String? {
        let pid = pane.surface.shellPid
        guard pid > 0 else { return nil }

        let now = Date()
        var cached: String?
        var shouldRefresh = false
        aiToolLock.lock()
        if let hit = aiToolCache[pid] {
            cached = hit.tool
            if now.timeIntervalSince(hit.at) >= aiToolTTL,
               !aiToolRefreshes.contains(pid) {
                aiToolRefreshes.insert(pid)
                shouldRefresh = true
            }
        } else if !aiToolRefreshes.contains(pid) {
            aiToolRefreshes.insert(pid)
            shouldRefresh = true
        }
        aiToolLock.unlock()

        if shouldRefresh {
            aiToolQueue.async {
                let tool = computeAITool(pid: pid)
                let refreshedAt = Date()
                aiToolLock.lock()
                aiToolCache[pid] = (tool, refreshedAt)
                aiToolRefreshes.remove(pid)
                if aiToolCache.count > 64 {
                    let newest = aiToolCache.sorted { $0.value.at > $1.value.at }.prefix(64)
                    aiToolCache = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
                }
                aiToolLock.unlock()
            }
        }
        return cached
    }

    private static func computeAITool(pid: pid_t) -> String? {
        guard let tty = ps(["-o", "tty=", "-p", "\(pid)"]), !tty.isEmpty,
              let procs = ps(["-t", tty, "-o", "comm="]) else { return nil }
        let known = ["claude", "aider", "cursor", "goose", "codex", "gemini",
                     "amp", "opencode", "cline", "continue"]
        for line in procs.split(separator: "\n") {
            let name = (String(line).trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
            if name.lowercased() == "pi" { return "pi" }
            if let hit = known.first(where: { name.lowercased().contains($0) }) { return hit }
        }
        return nil
    }

    private static func ps(_ arguments: [String]) -> String? {
        guard let result = try? ProcessCapture.run(
            URL(fileURLWithPath: "/bin/ps"),
            arguments: arguments,
            timeout: 2,
            outputLimit: 64 * 1024),
            result.terminationStatus == 0 else { return nil }
        return result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Spatial pane picker: a numbered chip appears ON each pane, everywhere.
final class BeamPicker {
    private var chips: [NSWindow] = []
    private var keyMonitor: Any?
    private var targets: [(pane: TerminalPane, chip: NSWindow)] = []
    private var snippet = ""

    /// Entry point: zero panes beeps, one beams instantly, several ask.
    func pick(snippet: String) {
        dismiss()
        self.snippet = snippet
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        let panes = delegate.allControllers.flatMap { c in
            c.panes.compactMap { p in p.window != nil ? p : nil }
        }
        if panes.isEmpty { NSSound.beep(); return }
        if panes.count == 1 {
            BeamManager.beam(snippet, into: panes[0])
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        for (i, pane) in panes.prefix(9).enumerated() {
            guard let chip = makeChip(number: i + 1, pane: pane) else { continue }
            chips.append(chip)
            targets.append((pane, chip))
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.dismiss(); return nil }   // Esc
            if let ch = event.charactersIgnoringModifiers,
               let n = Int(ch), n >= 1, n <= self.targets.count {
                self.choose(self.targets[n - 1].pane)
                return nil
            }
            return event
        }
    }

    private func choose(_ pane: TerminalPane) {
        let text = snippet
        dismiss()
        BeamManager.beam(text, into: pane)
    }

    private func dismiss() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        chips.forEach { $0.orderOut(nil) }
        chips.removeAll()
        targets.removeAll()
    }

    private func makeChip(number: Int, pane: TerminalPane) -> NSWindow? {
        guard let paneWindow = pane.window else { return nil }
        let paneRect = pane.convert(pane.bounds, to: nil)
        let screenRect = paneWindow.convertToScreen(paneRect)

        let ai = BeamManager.aiTool(in: pane)
        let title = (pane.currentCwd as NSString?)?.lastPathComponent ?? "shell"
        let label = ai.map { "✦ \($0) · \(title)" } ?? title

        let view = BeamChipView(number: number, label: label, highlighted: ai != nil)
        let size = view.fittingSize
        let chip = NSWindow(
            contentRect: NSRect(x: screenRect.midX - size.width / 2,
                                y: screenRect.midY - size.height / 2,
                                width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        chip.isOpaque = false
        chip.backgroundColor = .clear
        chip.level = .floating
        chip.hasShadow = true
        chip.contentView = view
        view.onClick = { [weak self] in self?.choose(pane) }
        chip.orderFrontRegardless()
        return chip
    }
}

/// One clickable chip: big number, session label, accent ring for AI panes.
private final class BeamChipView: NSView {
    private let number: Int
    private let label: String
    private let highlighted: Bool
    var onClick: (() -> Void)?

    init(number: Int, label: String, highlighted: Bool) {
        self.number = number
        self.label = label
        self.highlighted = highlighted
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var fittingSize: NSSize {
        let text = labelAttributed()
        return NSSize(width: max(120, text.size().width + 64), height: 56)
    }

    private func labelAttributed() -> NSAttributedString {
        NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12)
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        bg.fill()
        (highlighted ? NSColor.systemPurple : NSColor.controlAccentColor).setStroke()
        bg.lineWidth = highlighted ? 3 : 2
        bg.stroke()

        let digit = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .bold),
            .foregroundColor: NSColor.controlAccentColor,
        ])
        digit.draw(at: NSPoint(x: 16, y: bounds.midY - digit.size().height / 2))

        let text = labelAttributed()
        text.draw(at: NSPoint(x: 48, y: bounds.midY - text.size().height / 2))
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
