import AppKit
import ProductIdentity
import CmdyKit

/// Native AppKit scrolling and hit behavior without a permanent gutter.
/// Only the system-drawn scrubber is visible over the terminal surface.
private final class TerminalScroller: NSScroller {
    var onInteraction: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        drawKnob()
    }

    override func mouseEntered(with event: NSEvent) {
        onInteraction?()
        super.mouseEntered(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        onInteraction?()
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }
}

/// Compact controls that belong to one split rather than to the window. The
/// handle deliberately uses a pan recognizer instead of AppKit's pasteboard
/// drag API: WindowDock moves the existing TerminalPane (and therefore its
/// live PTY and scrollback) when the gesture lands.
private final class PaneDragHandleView: NSView {
    var onClick: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragChanged: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private let icon = NSImageView(frame: .zero)
    private var hoverTrackingArea: NSTrackingArea?
    private var isPointerInside = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "Detach Pane (or drag)"

        let configuration = NSImage.SymbolConfiguration(
            pointSize: 9.5, weight: .regular)
        icon.image = NSImage(
            systemSymbolName: "arrow.up.right",
            accessibilityDescription: "Drag Pane Out")?
            .withSymbolConfiguration(configuration)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 21),
            heightAnchor.constraint(equalToConstant: 21),
        ])

        let click = NSClickGestureRecognizer(
            target: self, action: #selector(handleClick(_:)))
        click.numberOfClicksRequired = 1
        addGestureRecognizer(click)
        addGestureRecognizer(NSPanGestureRecognizer(
            target: self, action: #selector(handlePan(_:))))
        applyInteractionOpacity()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Keep the pan recognizer as the concrete hit target. Letting the image
    /// view win here made the control look interactive while its parent never
    /// received a drag sequence in the full-size content titlebar.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    var contentTintColor: NSColor? {
        get { icon.contentTintColor }
        set { icon.contentTintColor = newValue }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        applyInteractionOpacity()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        applyInteractionOpacity()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    private func applyInteractionOpacity() {
        alphaValue = isPointerInside ? 0.8 : 0.3
    }

    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onClick?()
    }

    @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            onDragBegan?()
        case .changed:
            onDragChanged?()
        case .ended, .cancelled, .failed:
            onDragEnded?()
        default:
            break
        }
    }
}

private final class PaneSplitCloseButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var isPointerPressed = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func prepareInteractionOpacity() {
        applyInteractionOpacity()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        applyInteractionOpacity()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        applyInteractionOpacity()
    }

    override func mouseDown(with event: NSEvent) {
        isPointerPressed = true
        applyInteractionOpacity()
        defer {
            isPointerPressed = false
            applyInteractionOpacity()
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    private func applyInteractionOpacity() {
        alphaValue = isPointerPressed ? 1 : (isPointerInside ? 0.8 : 0.3)
    }
}

/// A theme-aware pair of split controls. Split panes keep the quiet controls
/// present; each glyph brightens independently on hover like the main toolbar.
private final class PaneSplitAffordanceView: NSView {
    var onClose: (() -> Void)?
    var onDetach: (() -> Void)? {
        didSet { dragHandle.onClick = onDetach }
    }
    var onDragBegan: (() -> Void)? {
        didSet { dragHandle.onDragBegan = onDragBegan }
    }
    var onDragChanged: (() -> Void)? {
        didSet { dragHandle.onDragChanged = onDragChanged }
    }
    var onDragEnded: (() -> Void)? {
        didSet { dragHandle.onDragEnded = onDragEnded }
    }

    private let dragHandle = PaneDragHandleView(frame: .zero)
    private let closeButton = PaneSplitCloseButton(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close Split")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(
                pointSize: 9.5, weight: .regular))
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.focusRingType = .none
        closeButton.refusesFirstResponder = true
        closeButton.toolTip = "Close Split"
        closeButton.target = self
        closeButton.action = #selector(closeSplit(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.prepareInteractionOpacity()

        let stack = NSStackView(views: [dragHandle, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            dragHandle.widthAnchor.constraint(equalToConstant: 21),
            closeButton.widthAnchor.constraint(equalToConstant: 21),
        ])
        alphaValue = 1
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    func applyTheme(_ theme: Theme) {
        let foreground = theme.ns(theme.foreground)
        dragHandle.contentTintColor = foreground
        closeButton.contentTintColor = foreground
    }

    var isBare: Bool {
        !wantsLayer || (layer?.backgroundColor?.alpha ?? 0) == 0
    }

    var closeButtonCenterInWindow: NSPoint {
        closeButton.convert(
            NSPoint(x: closeButton.bounds.midX, y: closeButton.bounds.midY),
            to: nil)
    }

    var detachButtonCenterInWindow: NSPoint {
        dragHandle.convert(
            NSPoint(x: dragHandle.bounds.midX, y: dragHandle.bounds.midY),
            to: nil)
    }

    @objc private func closeSplit(_ sender: Any?) {
        onClose?()
    }
}

/// One shell session: terminal surface + block store + inline overlay +
/// OSC 133 wiring + file-drop handling. A window hosts one or more panes in
/// nested split views; everything session-scoped lives here so splits come
/// for free. Talks to the engine ONLY through the TerminalCore protocols.
private final class TerminalPaneKeyRouter {
    static let shared = TerminalPaneKeyRouter()

    private var handlers: [ObjectIdentifier: (NSEvent) -> NSEvent?] = [:]
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self,
                  let controller = event.window?.windowController
                    as? TerminalWindowController,
                  let pane = controller.focusedPane,
                  let handler = handlers[ObjectIdentifier(pane)]
            else { return event }
            return handler(event)
        }
    }

    func register(
        _ pane: TerminalPane,
        handler: @escaping (NSEvent) -> NSEvent?
    ) {
        handlers[ObjectIdentifier(pane)] = handler
    }

    func unregister(_ pane: TerminalPane) {
        handlers.removeValue(forKey: ObjectIdentifier(pane))
    }
}

final class TerminalPane: DropView, InlinePanelHost, ExtensionSurfaceHost,
                          ExtensionControlBarHost, NSMenuDelegate {

    let surface: TerminalPaneHost
    let blockStore = BlockStore()
    var extensionControlBarTargetID: String { paneId }
    private let blockOverlay = BlockOverlayView()
    private let scrollIndicator = TerminalScroller(frame: .zero)
    private let splitAffordance = PaneSplitAffordanceView(frame: .zero)
    private var surfaceBottomConstraint: NSLayoutConstraint?
    private var blockOverlayBottomConstraint: NSLayoutConstraint?
    private var scrollIndicatorBottomConstraint: NSLayoutConstraint?
    private var splitAffordanceBottom: NSLayoutConstraint?
    private var splitAffordanceAvailable = false
    private var requestedTopContentInset: CGFloat = 0
    private var scrollFadeWorkItem: DispatchWorkItem?
    private var lastScrollIndicatorPosition = 1.0
    private var lastScrollIndicatorVisualOffset: CGFloat = 0
    private var lastLiveTop = 0
    private let initialCwd: String?
    /// Where the user's input begins (OSC 133;B = prompt end) — the anchor for
    /// ghost-text: typed = row text from this column to the cursor.
    private var inputStart: (row: Int, col: Int)?
    private var ghostSuffix: String?
    private var keyTimes: [CFAbsoluteTime] = []   // rolling window for typing rate

    /// Stable identity for the plugin API.
    let paneId = UUID().uuidString
    /// tty name of this pane's shell (e.g. "ttys004"), resolved once.
    private(set) lazy var ttyName: String? = {
        let pid = surface.shellPid
        guard pid > 0 else { return nil }
        guard let result = try? ProcessCapture.run(
            URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-o", "tty=", "-p", "\(pid)"],
            timeout: 2,
            outputLimit: 4_096),
            result.terminationStatus == 0 else { return nil }
        let out = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (!out.isEmpty && out != "??") ? out : nil
    }()

    private(set) var currentCwd: String?
    private(set) var oscTitle = ""
    private(set) var cols = 80
    private(set) var rows = 24

    /// Title / cwd / size / block state changed — the controller refreshes chrome.
    var onStateChanged: ((TerminalPane) -> Void)?
    /// Terminal output or viewport content changed. The controller throttles
    /// this richer signal before refreshing contextual Inspector resources.
    var onViewportChanged: ((TerminalPane) -> Void)?
    /// The shell exited — the controller removes the pane (or closes the window).
    var onClosed: ((TerminalPane) -> Void)?
    /// A command finished (used for finished-while-away notifications).
    var onCommandFinished: ((TerminalPane, Block) -> Void)?
    /// A command began and received its stable Surface Protocol block id.
    var onCommandStarted: ((TerminalPane, Block) -> Void)?
    /// A `# request` line was submitted for local-first command translation.
    var onAskRequested: ((TerminalPane, String) -> Void)?
    /// The process asked for attention (BEL / OSC 9 / OSC 777) while the
    /// user wasn't looking at this pane.
    var onAttention: ((TerminalPane, String) -> Void)?
    /// Split-only chrome. The owning controller supplies these callbacks so an
    /// adopted pane immediately targets its new split tree.
    var onSplitCloseRequested: ((TerminalPane) -> Void)?
    var onSplitDetachRequested: ((TerminalPane) -> Void)?
    var onSplitDragBegan: ((TerminalPane) -> Void)?
    var onSplitDragChanged: ((TerminalPane) -> Void)?
    var onSplitDragEnded: ((TerminalPane) -> Void)?
    /// Amber-dot state: set by requestAttention, cleared the moment the
    /// pane is focused in the key window of the active app.
    private(set) var wantsAttention = false
    private(set) var attentionText = ""
    private var appliedTheme = Preferences.shared.theme
    private(set) var paneAppearance = TerminalTabAppearance()
    var inheritedAppearanceProvider:
        (() -> (theme: String, shader: String, font: String))?
    var onAppearanceChanged: ((TerminalPane) -> Void)?
    private static let inheritedAppearanceSelection = "$cmdy.tab"
    /// Scrollback text from a previous run, replayed (dimmed) before the shell
    /// starts when restoring a session.
    var pendingRestoreText: String?

    init(cwd: String?) {
        initialCwd = cwd
        surface = TerminalEngineFactory.makePaneHost(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        super.init(frame: .zero)

        surface.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface.view)
        let surfaceBottom = surface.view.bottomAnchor.constraint(
            equalTo: bottomAnchor)
        surfaceBottomConstraint = surfaceBottom
        NSLayoutConstraint.activate([
            surface.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.view.topAnchor.constraint(equalTo: topAnchor),
            surfaceBottom,
        ])

        blockOverlay.surface = surface
        blockOverlay.store = blockStore
        blockOverlay.contentTopInset = 0
        blockOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blockOverlay)
        let overlayBottom = blockOverlay.bottomAnchor.constraint(
            equalTo: bottomAnchor)
        blockOverlayBottomConstraint = overlayBottom
        NSLayoutConstraint.activate([
            blockOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            blockOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            blockOverlay.topAnchor.constraint(equalTo: topAnchor),
            overlayBottom,
        ])

        scrollIndicator.translatesAutoresizingMaskIntoConstraints = false
        scrollIndicator.scrollerStyle = .legacy
        scrollIndicator.controlSize = .small
        scrollIndicator.target = self
        scrollIndicator.action = #selector(scrollIndicatorChanged(_:))
        scrollIndicator.onInteraction = { [weak self] in
            self?.revealScrollIndicator()
        }
        addSubview(scrollIndicator, positioned: .above, relativeTo: blockOverlay)
        let scrollerBottom = scrollIndicator.bottomAnchor.constraint(
            equalTo: bottomAnchor)
        scrollIndicatorBottomConstraint = scrollerBottom
        NSLayoutConstraint.activate([
            scrollIndicator.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollIndicator.topAnchor.constraint(equalTo: topAnchor),
            scrollerBottom,
            scrollIndicator.widthAnchor.constraint(equalToConstant:
                NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy)),
        ])
        scrollIndicator.isHidden = true

        splitAffordance.onClose = { [weak self] in
            guard let self else { return }
            self.onSplitCloseRequested?(self)
        }
        splitAffordance.onDetach = { [weak self] in
            guard let self else { return }
            self.onSplitDetachRequested?(self)
        }
        splitAffordance.onDragBegan = { [weak self] in
            guard let self else { return }
            self.onSplitDragBegan?(self)
        }
        splitAffordance.onDragChanged = { [weak self] in
            guard let self else { return }
            self.onSplitDragChanged?(self)
        }
        splitAffordance.onDragEnded = { [weak self] in
            guard let self else { return }
            self.onSplitDragEnded?(self)
        }
        addSubview(splitAffordance, positioned: .above, relativeTo: scrollIndicator)
        let affordanceBottom = splitAffordance.bottomAnchor.constraint(
            equalTo: bottomAnchor, constant: -4)
        splitAffordanceBottom = affordanceBottom
        NSLayoutConstraint.activate([
            affordanceBottom,
            splitAffordance.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -7),
            splitAffordance.widthAnchor.constraint(equalToConstant: 46),
            splitAffordance.heightAnchor.constraint(equalToConstant: 24),
        ])
        splitAffordance.isHidden = true
        splitAffordance.applyTheme(appliedTheme)

        let terminalMenu = NSMenu(title: "Terminal")
        terminalMenu.delegate = self
        menu = terminalMenu
        surface.view.menu = terminalMenu
        blockOverlay.menu = terminalMenu

        surface.onSizeChanged = { [weak self] newCols, newRows in
            guard let self else { return }
            self.cols = newCols
            self.rows = newRows
            self.onStateChanged?(self)
        }
        surface.onBell = { [weak self] in
            self?.requestAttention(text: "")
        }
        surface.onNotification = { [weak self] title, body in
            self?.requestAttention(text: body.isEmpty ? title : "\(title) — \(body)")
        }
        surface.onTitleChanged = { [weak self] title in
            guard let self, self.oscTitle != title else { return }
            self.oscTitle = title
            self.onStateChanged?(self)
        }
        surface.onCwdChanged = { [weak self] directory in
            guard let self else { return }
            // OSC 7 arrives as "file://host/path" — store a plain filesystem
            // path (what new tabs/panes inherit and what sessions persist).
            let cwd: String?
            if let d = directory, d.hasPrefix("file://") {
                cwd = URL(string: d)?.path ?? d
            } else {
                cwd = directory
            }
            guard self.currentCwd != cwd else { return }
            self.currentCwd = cwd
            self.onStateChanged?(self)
            PluginManager.shared.scheduleProjectExtensionReconcile()
            (NSApp.delegate as? AppDelegate)?.refreshActionsMenu()
        }
        surface.onProcessTerminated = { [weak self] _ in
            guard let self else { return }
            self.onClosed?(self)
        }
        surface.onViewportChanged = { [weak self] in
            guard let self else { return }
            self.refreshOverlayState()
            let position = self.surface.scrollPosition
            let visualOffset = self.surface.visualScrollOffset
            let moved = abs(position - self.lastScrollIndicatorPosition) > 0.000_001
                || abs(visualOffset - self.lastScrollIndicatorVisualOffset) > 0.1
            self.lastScrollIndicatorPosition = position
            self.lastScrollIndicatorVisualOffset = visualOffset
            self.refreshScrollIndicator(reveal: moved)
            self.onViewportChanged?(self)
        }
        surface.onVisualScrollChanged = { [weak self] in
            guard let self else { return }
            // Pixel-only movement needs only the overlay's cached layer. The
            // model, prompt blocks, ghost source, and scrollbar value did not
            // change, so avoid repeating that work at trackpad frequency.
            self.blockOverlay.refreshIfNeeded()
        }
        surface.onPasteRequest = { [weak self] text in
            guard let self else { return text }
            let decision = PluginManager.shared.decide(.paste, payload: [
                "pane": self.paneId,
                "cwd": self.currentCwd ?? "",
                "text": text,
            ])
            switch decision.action {
            case .continue:
                self.notePromptInsertion(text)
                return text
            case .replace:
                if let value = decision.value { self.notePromptInsertion(value) }
                return decision.value
            case .cancel: return nil
            }
        }
        surface.onTerminalMouseDown = { [weak self] in
            guard let self else { return }
            if self.inlinePanelTakesFocus {
                self.dismissInlinePanel()
            } else if self.windowInlinePanelTakesFocus {
                (self.window?.windowController as? TerminalWindowController)?
                    .dismissWindowInlinePanel(refocus: true)
            }
        }
        surface.onOpenLink = { [weak self] url in
            TerminalLinkOpener.open(url, windowNumber: self?.window?.windowNumber)
        }

        // Drag files/folders into the pane → insert their shell-escaped paths.
        onDropPaths = { [weak self] paths in
            guard let self else { return }
            let text = paths.map { TerminalWindowController.shellQuote($0) }.joined(separator: " ") + " "
            self.appendPromptInput(text)
        }

        // OSC 133 semantic prompt markers -> BlockStore.
        surface.engine.registerOscHandler(code: 133) { [weak self] slice in
            let payload = String(decoding: slice, as: UTF8.self)
            if Thread.isMainThread {
                self?.handleOSC133(payload)
            } else {
                DispatchQueue.main.async { self?.handleOSC133(payload) }
            }
        }
        blockStore.onChange = { [weak self] in
            guard let self else { return }
            self.updateBlockStyles()
            self.blockOverlay.blockDataChanged()
            self.onStateChanged?(self)
        }

        // Zooming/resizing rewraps the buffer and moves every absolute row the
        // blocks anchor to. Logical (unwrapped) lines survive reflow untouched,
        // so anchors round-trip through logical-line indices across the resize.
        surface.willReflowBuffer = { [weak self] in self?.snapshotBlockAnchors() }
        surface.didReflowBuffer = { [weak self] in self?.restoreBlockAnchors() }

        // Key monitor: SID keypress blips, and Tab/→ accepting the ghost suggestion
        // (only intercepted while a suggestion is visible and this pane has focus).
        TerminalPaneKeyRouter.shared.register(self) { [weak self] event in
            guard let self, event.window === self.window, self.isFocused else { return event }
            let modifiers = event.modifierFlags
                .intersection([.command, .option, .control, .shift])
            if self.isTerminalFocused,
               !modifiers.contains(.command),
               event.characters?.isEmpty == false {
                self.hasUserActivity = true
            }
            if modifiers == [.command],
               event.charactersIgnoringModifiers?.lowercased() == "l",
               let bar = self.extensionControlBar, !bar.isHidden {
                bar.focusInput()
                return nil
            }
            if modifiers.isEmpty, event.keyCode == 125,
               self.inlinePanel == nil, self.extensionSurfaceView == nil,
               !self.blockStore.isRunning,
               !self.surface.engine.isCurrentBufferAlternate,
               let input = self.currentInputText(),
               input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let bar = self.extensionControlBar, !bar.isHidden {
                bar.focusFirstAction()
                return nil
            }
            if modifiers.isEmpty, [36, 76].contains(event.keyCode),
               self.isTerminalFocused, self.inlinePanel == nil {
                PluginManager.shared.feedbackPromptDidSubmit(in: self.paneId)
            }
            // Activity telemetry for reactive shaders (ripple, typing energy).
            let now = CFAbsoluteTimeGetCurrent()
            self.surface.activityKeypressTime = now
            self.keyTimes.append(now)
            self.keyTimes.removeAll { now - $0 > 2 }
            self.surface.activityTypingRate = Float(self.keyTimes.count) / 2.0
            if Preferences.shared.sounds, !event.isARepeat {
                Retrobleeps.keyBlip()
            }
            if ![36, 76].contains(event.keyCode) {
                self.trackPromptDraft(event)
            }
            if self.commandAssistanceID != nil {
                if event.keyCode == 53 {   // esc
                    self.dismissCommandAssistance()
                    return nil
                }
                if [36, 76].contains(event.keyCode),
                   event.modifierFlags.contains(.command) {
                    if !self.acceptCommandAssistance() { NSSound.beep() }
                    return nil
                }
                if [36, 76].contains(event.keyCode) {
                    self.dismissCommandAssistance(refocus: false)
                } else if event.modifierFlags
                    .intersection([.command, .control, .option]).isEmpty,
                          let chars = event.characters, !chars.isEmpty,
                          !chars.unicodeScalars.contains(where: {
                              CharacterSet.controlCharacters.contains($0)
                          }) {
                    // Normal typing wins immediately; assistance never traps
                    // the prompt or forces a modal interaction.
                    self.dismissCommandAssistance(refocus: false)
                }
            }
            if [36, 76].contains(event.keyCode),
               modifiers.isEmpty,
               self.inlinePanel == nil,
               let command = self.currentInputText() {
                if IntegrationDoctor.interceptAgentLaunch(command, in: self) {
                    return nil
                }
                if let request = Self.assistantRequest(from: command),
                   let onAskRequested = self.onAskRequested {
                    self.promptDraft = ""
                    self.promptDraftIsReliable = true
                    self.surface.send(txt: "\u{15}")
                    onAskRequested(self, request)
                    return nil
                }
                let decision = PluginManager.shared.decide(.command, payload: [
                    "pane": self.paneId,
                    "cwd": self.currentCwd ?? "",
                    "command": command,
                ])
                switch decision.action {
                case .continue:
                    self.promptDraftIsReliable = false
                case .cancel:
                    // An empty replacement means the extension handled the
                    // intent itself (for example Browser navigation), so clear
                    // the prompt instead of leaving a command that can repeat.
                    if decision.value == "" {
                        self.promptDraft = ""
                        self.promptDraftIsReliable = true
                        self.surface.send(txt: "\u{15}")
                    }
                    if let reason = decision.reason, !reason.isEmpty {
                        Notifier.post(title: "Command cancelled", body: reason)
                    }
                    return nil
                case .replace:
                    guard let replacement = decision.value else { return event }
                    self.replacePromptInput(with: replacement, submit: true)
                    return nil
                }
            } else if [36, 76].contains(event.keyCode) {
                self.promptDraftIsReliable = false
            }
            guard self.inlinePanel == nil,   // panel owns the keyboard while open
                  let suffix = self.ghostSuffix, !suffix.isEmpty,
                  Self.isGhostAcceptanceKey(
                    keyCode: event.keyCode,
                    modifiers: event.modifierFlags)
            else { return event }
            if self.promptDraftIsReliable { self.promptDraft += suffix }
            self.surface.send(txt: suffix)
            self.setGhost(nil)
            return nil
        }

    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        TerminalPaneKeyRouter.shared.unregister(self)
    }

    /// Unmodified Tab accepts fish-style ghost text. When no hint is visible,
    /// the event is untouched and zsh receives its normal completion key.
    static func isGhostAcceptanceKey(keyCode: UInt16,
                                     modifiers: NSEvent.ModifierFlags) -> Bool {
        let relevant = modifiers.intersection([.command, .option, .control, .shift])
        return relevant.isEmpty && [48, 124].contains(keyCode)
    }

    func startShell() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let env = ShellIntegration.makeEnvironment(
            shellPath: shell,
            integrationEnabled: Preferences.shared.shellIntegration,
            cleanPrompt: Preferences.shared.cleanPrompt)

        if let restored = pendingRestoreText, !restored.isEmpty {
            // Dimmed so it reads as history, with a rule where the new shell begins.
            let text = restored.replacingOccurrences(of: "\n", with: "\r\n")
            surface.engine.feed(text: "\u{1b}[2m" + text +
                "\r\n\u{1b}[0m\u{1b}[2m── restored session ──\u{1b}[0m\r\n")
            pendingRestoreText = nil
        }
        surface.startProcess(executable: shell, args: ["-l"], environment: env,
                             currentDirectory: initialCwd)
    }

    // MARK: - Inline panel (in-terminal UI: palette, AI, agent — no floating windows)

    private(set) var inlinePanel: InlinePanel?
    private(set) var inlinePanelBottomConstraint: NSLayoutConstraint?
    private(set) var inlinePanelHeightConstraint: NSLayoutConstraint?
    private var inlinePanelTakesFocus = false
    private var windowInlinePanelPresented = false
    private var windowInlinePanelTakesFocus = false
    private(set) var extensionControlBar: ExtensionControlBar?
    private var extensionControlBarBottomConstraint: NSLayoutConstraint?
    private(set) var extensionControlBarHeightConstraint: NSLayoutConstraint?
    private(set) var extensionSurfaceView: NativeSurfaceView?
    private var commandAssistanceID: String?
    private var commandAssistanceSuggestion: String?
    /// A lightweight copy of straightforward prompt typing. OSC 133 remains
    /// canonical, but this closes the race where Return arrives before the
    /// echoed cells have reached the render snapshot.
    private var promptDraft = ""
    private var promptDraftIsReliable = false
    /// Untouched prompt output is disposable; any user-directed terminal
    /// interaction makes window close confirmation conservative thereafter.
    private var hasUserActivity = false

    var canPresentAutomaticAssistance: Bool {
        inlinePanel == nil && !windowInlinePanelPresented
            && extensionSurfaceView == nil && commandAssistanceID == nil
    }

    private func resolvedInlinePanelBottomOffset() -> CGFloat {
        if let controller = window?.windowController as? TerminalWindowController {
            // Preserve the full-size panel, but translate the complete block
            // down through both the window inset, its own bottom padding, and
            // one and a half terminal rows. Upper split panes stay flush with
            // their divider.
            let gap = controller.inlinePanelBottomOffset(for: self)
            return gap > 0 ? surface.cellSize.height * 1.5 - gap * 2 : 0
        }
        // Headless tests and panes not installed in a window yet have no
        // border geometry to measure, so model the same complete-block drop.
        return surface.cellSize.height * 1.5 - Preferences.shared.contentMargin * 2
    }

    private func reserveVisibleInlinePanelHeight(_ height: CGFloat? = nil) {
        guard let panel = inlinePanel else { return }
        let panelHeight = height ?? panel.intrinsicContentSize.height
        let overflow = max(0, -(inlinePanelBottomConstraint?.constant ?? 0))
        surface.bottomContentInset = max(0, panelHeight - overflow)
    }

    private func reserveVisibleControlBarHeight(_ height: CGFloat? = nil) {
        guard let bar = extensionControlBar, !bar.isHidden,
              inlinePanel == nil, extensionSurfaceView == nil else { return }
        let barHeight = height ?? bar.preferredHeight
        let overflow = max(0, -(extensionControlBarBottomConstraint?.constant ?? 0))
        surface.bottomContentInset = max(0, barHeight - overflow)
    }

    private func restoreControlBarIfAvailable() {
        guard inlinePanel == nil, !windowInlinePanelPresented,
              extensionSurfaceView == nil else { return }
        if let bar = extensionControlBar {
            bar.isHidden = false
            reserveVisibleControlBarHeight()
        } else {
            surface.bottomContentInset = 0
        }
    }

    @discardableResult
    func presentExtensionControlBar() -> ExtensionControlBar {
        if let existing = extensionControlBar {
            existing.isHidden = inlinePanel != nil || windowInlinePanelPresented
                || extensionSurfaceView != nil
            if !existing.isHidden { reserveVisibleControlBarHeight() }
            return existing
        }
        let bar = ExtensionControlBar(frame: .zero)
        bar.themeOverride = appliedTheme
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        let bottomConstraint = bar.bottomAnchor.constraint(
            equalTo: bottomAnchor, constant: resolvedInlinePanelBottomOffset())
        let heightConstraint = bar.heightAnchor.constraint(
            equalToConstant: bar.preferredHeight)
        extensionControlBarBottomConstraint = bottomConstraint
        extensionControlBarHeightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomConstraint,
            heightConstraint,
        ])
        bar.metrics = { [weak self] in
            guard let surface = self?.surface else {
                return (Preferences.shared.resolvedFont(), 0, 10)
            }
            return (surface.font, surface.cellSize.height, surface.contentXOrigin)
        }
        bar.onHeightChanged = { [weak self, weak bar] height in
            guard let self, let bar, self.extensionControlBar === bar else { return }
            self.extensionControlBarHeightConstraint?.constant = height
            self.reserveVisibleControlBarHeight(height)
        }
        bar.onEscape = { [weak self] in self?.focus() }
        bar.onInputFocusChanged = { [weak self] focused in
            self?.surface.hostCursorHidden = focused
        }
        extensionControlBar = bar
        bar.isHidden = inlinePanel != nil || windowInlinePanelPresented
            || extensionSurfaceView != nil
        bar.refreshMetrics()
        if !bar.isHidden { reserveVisibleControlBarHeight() }
        refreshScrollIndicator()
        return bar
    }

    func dismissExtensionControlBar(_ bar: ExtensionControlBar) {
        guard extensionControlBar === bar else { return }
        extensionControlBar = nil
        extensionControlBarBottomConstraint = nil
        extensionControlBarHeightConstraint = nil
        bar.onHeightChanged = nil
        bar.onEscape = nil
        bar.onInputFocusChanged = nil
        bar.metrics = nil
        bar.removeFromSuperview()
        if inlinePanel == nil, !windowInlinePanelPresented,
           extensionSurfaceView == nil {
            surface.bottomContentInset = 0
        }
        surface.hostCursorHidden = false
        refreshScrollIndicator()
    }

    func focusExtensionControlBar(_ bar: ExtensionControlBar) {
        guard extensionControlBar === bar, !bar.isHidden else { return }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        bar.focusInput()
    }

    /// Dock a fresh inline panel at the bottom of this pane. `takeFocus: false`
    /// leaves the terminal typing (agent log view — Enter must reach the shell).
    @discardableResult
    func presentInlinePanel(takeFocus: Bool = true) -> InlinePanel {
        (window?.windowController as? TerminalWindowController)?
            .dismissWindowInlinePanel(refocus: false)
        dismissCommandAssistance(refocus: false)
        if let surfaceView = extensionSurfaceView {
            surfaceView.dismiss()
            if extensionSurfaceView === surfaceView { dismissExtensionSurface(surfaceView) }
        }
        dismissInlinePanel(refocus: false)
        extensionControlBar?.isHidden = true
        let panel = InlinePanel(frame: .zero)
        panel.themeOverride = appliedTheme
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        let bottomConstraint = panel.bottomAnchor.constraint(
            equalTo: bottomAnchor, constant: resolvedInlinePanelBottomOffset())
        let heightConstraint = panel.heightAnchor.constraint(
            equalToConstant: panel.intrinsicContentSize.height)
        inlinePanelBottomConstraint = bottomConstraint
        inlinePanelHeightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            // A bottom-edge pane extends through the measured window inset;
            // upper split panes remain flush with their own divider.
            bottomConstraint,
            heightConstraint,
        ])
        panel.onDismiss = { [weak self] in self?.dismissInlinePanel() }
        // The grid gives up rows for the panel — content pushes up rather
        // than being covered (the shader keeps painting behind the panel).
        panel.onHeightChanged = { [weak self, weak panel] height in
            guard let self, let panel, self.inlinePanel === panel else { return }
            self.inlinePanelHeightConstraint?.constant = height
            self.reserveVisibleInlinePanelHeight(height)
        }
        // The panel adopts the grid's own metrics: font, line height (cell
        // height incl. line-height multiplier), left origin, and the exact
        // baseline used by the Metal glyph renderer.
        panel.metrics = { [weak self] in
            guard let tv = self?.surface else {
                let font = Preferences.shared.resolvedFont()
                return (font, 0, 10, font.ascender)
            }
            return (
                tv.font,
                tv.cellSize.height,
                tv.contentXOrigin,
                tv.textBaselineFromRowTop
            )
        }
        inlinePanel = panel
        refreshScrollIndicator()
        inlinePanelTakesFocus = takeFocus
        if takeFocus {
            surface.hostCursorHidden = true
            DispatchQueue.main.async { [weak self, weak panel] in
                guard let panel else { return }
                self?.window?.makeFirstResponder(panel)
            }
        }
        return panel
    }

    func dismissInlinePanel(refocus: Bool = true) {
        guard let p = inlinePanel else { return }
        inlinePanel = nil
        inlinePanelTakesFocus = false
        surface.hostCursorHidden = false
        // A picked palette item runs on the next main-loop turn and can change
        // theme/font preferences. The removed panel observes that change and
        // relayouts, so detach its height callback before it can restore the
        // stale reservation after we clear it below.
        p.onHeightChanged = nil
        p.onDismiss = nil
        p.metrics = nil
        p.removeFromSuperview()
        inlinePanelBottomConstraint = nil
        inlinePanelHeightConstraint = nil
        if extensionSurfaceView == nil { restoreControlBarIfAvailable() }
        refreshScrollIndicator()
        if refocus { focus() }
    }

    /// A window-level inline panel (currently Integration Doctor) spans every
    /// split, including Browser. This pane still owns its terminal reservation
    /// and focus state so the grid moves up exactly as it does for a local
    /// inline panel.
    func prepareForWindowInlinePanel(takeFocus: Bool) {
        windowInlinePanelPresented = true
        windowInlinePanelTakesFocus = takeFocus
        dismissCommandAssistance(refocus: false)
        if let surfaceView = extensionSurfaceView {
            surfaceView.dismiss()
            if extensionSurfaceView === surfaceView {
                dismissExtensionSurface(surfaceView)
            }
        }
        dismissInlinePanel(refocus: false)
        extensionControlBar?.isHidden = true
        surface.hostCursorHidden = takeFocus
        refreshScrollIndicator()
    }

    func reserveWindowInlinePanelHeight(_ height: CGFloat) {
        guard windowInlinePanelPresented else { return }
        surface.bottomContentInset = max(0, height)
        refreshScrollIndicator()
    }

    func finishWindowInlinePanel(refocus: Bool) {
        guard windowInlinePanelPresented else { return }
        windowInlinePanelPresented = false
        windowInlinePanelTakesFocus = false
        surface.hostCursorHidden = false
        if extensionSurfaceView == nil { restoreControlBarIfAvailable() }
        refreshScrollIndicator()
        if refocus { focus() }
    }

    @objc private func scrollIndicatorChanged(_ sender: NSScroller) {
        switch sender.hitPart {
        case .decrementLine: surface.scrollUp(lines: 1)
        case .incrementLine: surface.scrollDown(lines: 1)
        case .decrementPage: surface.scrollUp(lines: max(1, surface.engine.rows - 1))
        case .incrementPage: surface.scrollDown(lines: max(1, surface.engine.rows - 1))
        default:
            let tail = surface.engine.liveScreenTopRow
            guard tail > 0 else { return }
            surface.scrollTo(row: Int((sender.doubleValue * Double(tail)).rounded()))
        }
    }

    private func refreshScrollIndicator(reveal: Bool = false) {
        let canShow = surface.showsScroller && surface.canScroll
            && inlinePanel == nil && !windowInlinePanelPresented
            && extensionSurfaceView == nil
        let wasHidden = scrollIndicator.isHidden
        scrollIndicator.isHidden = !canShow
        guard canShow else {
            scrollFadeWorkItem?.cancel()
            scrollFadeWorkItem = nil
            scrollIndicator.alphaValue = 0
            return
        }
        let total = max(1, surface.engine.bufferLineCount)
        scrollIndicator.knobProportion = min(1, CGFloat(surface.engine.rows) / CGFloat(total))
        scrollIndicator.doubleValue = surface.scrollPosition
        scrollIndicator.needsDisplay = true
        if reveal || wasHidden { revealScrollIndicator() }
    }

    private func revealScrollIndicator() {
        guard !scrollIndicator.isHidden else { return }
        scrollFadeWorkItem?.cancel()
        scrollIndicator.alphaValue = 1

        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.scrollIndicator.isHidden else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.scrollIndicator.animator().alphaValue = 0
            }
        }
        scrollFadeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: work)
    }

    func presentCommandAssistance(id: String, body: String) {
        dismissCommandAssistance(refocus: false)
        commandAssistanceID = id
        commandAssistanceSuggestion = nil
        blockOverlay.commandAssistance = CommandAssistanceOverlay(
            id: id,
            anchorRow: surface.engine.scrollInvariantCursorRow + 1,
            body: body,
            hint: "esc dismiss")
        focus()
    }

    @discardableResult
    func updateCommandAssistance(id: String, explanation: String,
                                 suggestion: String?, source: String,
                                 findingSuggestion: Bool = false) -> Bool {
        guard commandAssistanceID == id,
              var assistance = blockOverlay.commandAssistance else { return false }
        commandAssistanceSuggestion = suggestion
        var body = explanation
        if let suggestion { body += "\n\ntry: \(suggestion)" }
        assistance.body = body
        if suggestion != nil {
            assistance.hint = "\(source) · cmd+return insert · return run · esc dismiss"
        } else if findingSuggestion {
            assistance.hint = "\(source) · finding a command… · esc dismiss"
        } else {
            assistance.hint = "\(source) · esc dismiss"
        }
        blockOverlay.commandAssistance = assistance
        return true
    }

    func dismissCommandAssistance(refocus: Bool = true) {
        guard commandAssistanceID != nil else { return }
        commandAssistanceID = nil
        commandAssistanceSuggestion = nil
        blockOverlay.commandAssistance = nil
        if refocus { focus() }
    }

    @discardableResult
    func acceptCommandAssistance() -> Bool {
        guard commandAssistanceID != nil,
              let suggestion = commandAssistanceSuggestion else { return false }
        dismissCommandAssistance(refocus: false)
        replacePromptInput(with: suggestion)
        focus()
        return true
    }

    static func assistantRequest(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }
        if trimmed.hasPrefix("#") {
            let request = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            return request.isEmpty ? nil : request
        }
        return ErrorAssistant.isNaturalLanguageRequest(trimmed) ? trimmed : nil
    }

    // MARK: - Extension surfaces

    var extensionSurfacePaneID: String { paneId }

    func resolveSurfaceBlock(_ requested: String) -> String? {
        switch requested {
        case "current": return blockStore.blocks.last?.id
        case "last": return blockStore.lastCompletedBlock?.id
        default: return blockStore.blocks.contains(where: { $0.id == requested })
            ? requested : nil
        }
    }

    @discardableResult
    func presentExtensionSurface(_ document: SurfaceDocument) -> NativeSurfaceView {
        (window?.windowController as? TerminalWindowController)?
            .dismissWindowInlinePanel(refocus: false)
        dismissCommandAssistance(refocus: false)
        dismissInlinePanel(refocus: false)
        extensionControlBar?.isHidden = true
        if let existing = extensionSurfaceView {
            existing.removeFromSuperview()
            extensionSurfaceView = nil
        }
        let view = NativeSurfaceView(document: document)
        view.themeOverride = appliedTheme
        view.metrics = { [weak self] in
            guard let surface = self?.surface else {
                return (Preferences.shared.resolvedFont(), 0, 10)
            }
            return (surface.font, surface.cellSize.height, surface.contentXOrigin)
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        view.onHeightChanged = { [weak self] height in
            self?.surface.bottomContentInset = height
        }
        extensionSurfaceView = view
        surface.bottomContentInset = view.preferredHeight
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view else { return }
            self.window?.makeFirstResponder(view)
        }
        return view
    }

    func dismissExtensionSurface(_ view: NativeSurfaceView) {
        guard extensionSurfaceView === view else { return }
        extensionSurfaceView = nil
        view.onHeightChanged = nil
        view.metrics = nil
        view.removeFromSuperview()
        if inlinePanel == nil { restoreControlBarIfAvailable() }
        focus()
    }

    // MARK: - Reflow-proof block anchors

    /// logical[row] = index of the logical (unwrapped) line the row belongs to.
    private static func logicalTable(_ term: TerminalEngine) -> [Int] {
        let n = term.bufferLineCount
        var table = [Int](); table.reserveCapacity(n)
        var idx = -1
        for row in 0..<n {
            if !term.isBufferRowWrapped(row) { idx += 1 }
            table.append(max(0, idx))
        }
        return table
    }

    private var reflowTable: [Int]?
    private var reflowCursorLogical = 0
    private var reflowCols = 0

    private func snapshotBlockAnchors() {
        let term = surface.engine
        guard !term.isCurrentBufferAlternate else { reflowTable = nil; return }
        reflowCols = term.cols
        let table = Self.logicalTable(term)
        reflowTable = table
        let cursorRow = min(max(0, term.scrollInvariantCursorRow), table.count - 1)
        reflowCursorLogical = table.isEmpty ? 0 : table[cursorRow]
    }

    private func restoreBlockAnchors() {
        guard let table = reflowTable else { return }
        reflowTable = nil
        let term = surface.engine
        guard term.cols != reflowCols else { return }   // rows-only: no rewrap, rows are stable
        // Logical map of the rewrapped buffer: starts[i] = first row of
        // logical line i; newTable[row] = logical line of that row.
        var starts: [Int] = []
        var newTable = [Int](); newTable.reserveCapacity(term.bufferLineCount)
        var idx = -1
        for row in 0..<term.bufferLineCount {
            if !term.isBufferRowWrapped(row) { idx += 1; starts.append(row) }
            newTable.append(max(0, idx))
        }
        guard !starts.isEmpty, let oldLast = table.last else { return }
        // Anchor logical indices to the CURSOR's logical line — the one
        // reference reflow provably keeps: a rewrap at the scrollback cap
        // trims the top (shifting top-relative indices for cursor and blocks
        // EQUALLY), and growing the window pads blank lines onto the tail
        // (below the cursor, so cursor-relative distances don't move).
        let cursorRow = min(max(0, term.scrollInvariantCursorRow), newTable.count - 1)
        let cursorLogicalNew = newTable[cursorRow]
        let cursorLogicalOld = reflowCursorLogical
        blockStore.remapRows { old in
            let logical = (old >= 0 && old < table.count) ? table[old] : oldLast
            let newLogical = cursorLogicalNew - (cursorLogicalOld - logical)
            if newLogical < 0 { return -1 }   // trimmed away → dropped by remapRows
            return starts[min(newLogical, starts.count - 1)]
        }
        // The remap already accounts for any reflow-induced trim — resync the
        // 20Hz trim watcher so it doesn't shift the fresh rows a second time.
        lastDroppedLines = term.scrollbackDroppedLines
        lastLiveTop = term.liveScreenTopRow
        inputStart = nil          // ghost re-anchors at the next OSC 133;B
        setGhost(nil)
        if var assistance = blockOverlay.commandAssistance {
            assistance.anchorRow = term.scrollInvariantCursorRow + 1
            blockOverlay.commandAssistance = assistance
        }
    }

    func shutdown() {
        (window?.windowController as? TerminalWindowController)?
            .dismissWindowInlinePanel(from: self, refocus: false)
        TerminalPaneKeyRouter.shared.unregister(self)
        surface.terminate()   // don't orphan the child shell
    }

    /// Shift the grid down inside the view (flush mode: chrome floats over the
    /// shader). The overlay's row math follows the same offset.
    func setTopContentInset(_ inset: CGFloat) {
        requestedTopContentInset = max(0, inset)
        applyPaneChrome()
    }

    /// Split actions get a quiet pane-local bottom rail. Shrinking the terminal
    /// and overlay instead of floating controls over them keeps glyphs, text
    /// selection, and the I-beam out of the actions' pointer targets.
    private func applyPaneChrome() {
        let bottomInset: CGFloat = splitAffordanceAvailable ? 32 : 0
        surfaceBottomConstraint?.constant = -bottomInset
        blockOverlayBottomConstraint?.constant = -bottomInset
        scrollIndicatorBottomConstraint?.constant = -bottomInset
        if surface.topContentInset != requestedTopContentInset {
            surface.topContentInset = requestedTopContentInset
        }
        if blockOverlay.contentTopInset != requestedTopContentInset {
            blockOverlay.contentTopInset = requestedTopContentInset
            blockOverlay.needsDisplay = true
        }
    }

    func setSplitAffordanceVisible(_ visible: Bool) {
        splitAffordanceAvailable = visible
        applyPaneChrome()
        updateSplitAffordanceVisibility()
    }

    private func updateSplitAffordanceVisibility() {
        splitAffordance.isHidden = !splitAffordanceAvailable
        if let window {
            window.invalidateCursorRects(for: splitAffordance)
        }
    }

    var splitAffordanceDiagnostic: (visible: Bool, frame: NSRect,
                                    dragHelp: String?, closeHelp: String?,
                                    bottomClearance: CGFloat,
                                    bare: Bool) {
        (visible: !splitAffordance.isHidden,
         frame: splitAffordance.frame,
         dragHelp: splitAffordance.subviews.first?.subviews.first?.toolTip,
         closeHelp: splitAffordance.subviews.first?.subviews.last?.toolTip,
         bottomClearance: surface.view.frame.minY - bounds.minY,
         bare: splitAffordance.isBare)
    }

    func requestSplitCloseForTesting() {
        onSplitCloseRequested?(self)
    }

    func splitAffordanceClosePointerTestTarget()
        -> (screenPoint: NSPoint, receivesHit: Bool, hitView: String)? {
        guard !splitAffordance.isHidden, let window else { return nil }
        let windowPoint = splitAffordance.closeButtonCenterInWindow
        let contentPoint = window.contentView?.convert(windowPoint, from: nil)
        let hit = contentPoint.flatMap { window.contentView?.hitTest($0) }
        let receivesHit = hit is PaneSplitCloseButton
        return (
            window.convertPoint(toScreen: windowPoint), receivesHit,
            hit.map { String(describing: type(of: $0)) } ?? "nil")
    }

    func splitAffordanceDetachPointerTestTarget()
        -> (screenPoint: NSPoint, receivesHit: Bool, hitView: String)? {
        guard !splitAffordance.isHidden, let window else { return nil }
        let windowPoint = splitAffordance.detachButtonCenterInWindow
        let contentPoint = window.contentView?.convert(windowPoint, from: nil)
        let hit = contentPoint.flatMap { window.contentView?.hitTest($0) }
        let receivesHit = hit is PaneDragHandleView
        return (
            window.convertPoint(toScreen: windowPoint), receivesHit,
            hit.map { String(describing: type(of: $0)) } ?? "nil")
    }

    func splitAffordanceRect(in view: NSView) -> NSRect? {
        guard !splitAffordance.isHidden, view.window === window else { return nil }
        return splitAffordance.convert(splitAffordance.bounds, to: view)
    }

    /// True when this pane's terminal is (or contains) the window's first responder.
    var isFocused: Bool {
        guard let fr = window?.firstResponder as? NSView else { return false }
        return fr === surface.view || fr.isDescendant(of: self)
    }

    /// True only when the VT surface owns keys. Inline panels and native
    /// extension surfaces are descendants too, but must keep their shortcuts.
    var isTerminalFocused: Bool { window?.firstResponder === surface.view }
    var isCommandAssistanceVisible: Bool { commandAssistanceID != nil }

    func focus() { window?.makeFirstResponder(surface.view) }

    // MARK: - Pane appearance context menu

    func restoreAppearance(_ restored: TerminalTabAppearance) {
        paneAppearance = TerminalTabAppearance.restored(
            themeName: restored.themeName,
            shaderName: restored.shaderName,
            fontName: restored.fontName)
    }

    func resolvedThemeName(inherited: String) -> String {
        paneAppearance.resolvedThemeName(global: inherited)
    }

    func resolvedShaderName(inherited: String) -> String {
        paneAppearance.resolvedShaderName(global: inherited)
    }

    func resolvedFontName(inherited: String) -> String {
        paneAppearance.resolvedFontName(global: inherited)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let copy = NSMenuItem(
            title: "Copy", action: NSSelectorFromString("copy:"),
            keyEquivalent: "")
        copy.target = surface.view
        copy.isEnabled = !surface.selectedText().isEmpty
        menu.addItem(copy)

        let paste = NSMenuItem(
            title: "Paste", action: NSSelectorFromString("paste:"),
            keyEquivalent: "")
        paste.target = surface.view
        menu.addItem(paste)
        menu.addItem(.separator())

        let inherited: (theme: String, shader: String, font: String) =
            inheritedAppearanceProvider?()
            ?? (theme: Preferences.shared.themeName,
                shader: Preferences.shared.shaderName,
                font: Preferences.shared.fontName)
        menu.addItem(appearanceMenuItem(
            title: "Theme",
            inheritedTitle: "Tab — \(inherited.theme)",
            selected: paneAppearance.themeName,
            choices: Theme.names,
            action: #selector(selectPaneTheme(_:))))
        menu.addItem(appearanceMenuItem(
            title: "Shader",
            inheritedTitle: "Tab — \(inherited.shader)",
            selected: paneAppearance.shaderName,
            choices: Preferences.shaderNames + UserShaders.names,
            action: #selector(selectPaneShader(_:)),
            displayName: { name in
                name.hasPrefix("user/")
                    ? String(name.dropFirst("user/".count)) : name
            }))
        let fontChoices = TerminalAppearanceFontCatalog.choices
        let inheritedFontTitle = TerminalAppearanceFontCatalog.displayName(
            for: inherited.font)
        menu.addItem(appearanceMenuItem(
            title: "Font",
            inheritedTitle: "Tab — \(inheritedFontTitle)",
            selected: paneAppearance.fontName,
            choices: fontChoices.map(\.name),
            action: #selector(selectPaneFont(_:)),
            displayName: TerminalAppearanceFontCatalog.displayName(for:)))
    }

    private func appearanceMenuItem(
        title: String,
        inheritedTitle: String,
        selected: String?,
        choices: [String],
        action: Selector,
        displayName: (String) -> String = { $0 }
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        let inherited = NSMenuItem(
            title: inheritedTitle, action: action, keyEquivalent: "")
        inherited.target = self
        inherited.representedObject = Self.inheritedAppearanceSelection
        inherited.state = selected == nil ? .on : .off
        submenu.addItem(inherited)
        submenu.addItem(.separator())
        for choice in choices {
            let option = NSMenuItem(
                title: displayName(choice), action: action, keyEquivalent: "")
            option.target = self
            option.representedObject = choice
            option.state = selected == choice ? .on : .off
            submenu.addItem(option)
        }
        item.submenu = submenu
        return item
    }

    @objc private func selectPaneTheme(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        let requested = value == Self.inheritedAppearanceSelection ? nil : value
        let validated = TerminalTabAppearance.restored(
            themeName: requested, shaderName: nil).themeName
        guard paneAppearance.themeName != validated else { return }
        paneAppearance.themeName = validated
        onAppearanceChanged?(self)
    }

    @objc private func selectPaneShader(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        let requested = value == Self.inheritedAppearanceSelection ? nil : value
        let validated = TerminalTabAppearance.restored(
            themeName: nil, shaderName: requested).shaderName
        guard paneAppearance.shaderName != validated else { return }
        paneAppearance.shaderName = validated
        onAppearanceChanged?(self)
    }

    @objc private func selectPaneFont(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        let requested = value == Self.inheritedAppearanceSelection ? nil : value
        let validated = TerminalAppearanceFontCatalog.validated(requested)
        guard paneAppearance.fontName != validated else { return }
        paneAppearance.fontName = validated
        onAppearanceChanged?(self)
    }

    // MARK: - Preferences / theme (terminal-level; window chrome stays in the controller)

    func applyPreferences(theme themeOverride: Theme? = nil,
                          shaderName shaderOverride: String? = nil,
                          fontName fontOverride: String? = nil) {
        let p = Preferences.shared
        let theme = themeOverride ?? p.theme
        let shaderName = shaderOverride ?? p.shaderName
        let shaderMode = shaderName.hasPrefix("user/")
            ? -1 : (Preferences.shaderNames.firstIndex(of: shaderName) ?? 0)
        appliedTheme = theme
        splitAffordance.applyTheme(theme)
        inlinePanelBottomConstraint?.constant = resolvedInlinePanelBottomOffset()
        extensionControlBarBottomConstraint?.constant = resolvedInlinePanelBottomOffset()
        reserveVisibleInlinePanelHeight()
        if p.automaticErrorHelp {
            surface.engine.setCommandFinishedHostMessageProvider { command, output, exit in
                guard exit != 0 else { return nil }
                return ErrorAssistant.normalizeExplanation(
                    ErrorAssistant.deterministicExplanation(
                        command: command.isEmpty ? "(unknown command)" : command,
                        output: output, exitCode: exit, cwd: nil))
            }
        } else {
            surface.engine.setCommandFinishedHostMessageProvider(nil)
        }
        if !p.automaticErrorHelp,
           let assistanceID = commandAssistanceID,
           !assistanceID.hasPrefix("ask-") {
            dismissCommandAssistance(refocus: false)
        }

        surface.lineHeightMultiplier = p.lineHeight   // set before font so cells recompute
        let leftInset = p.contentMargin
        surface.leftContentInset = leftInset
        surface.rightContentInset = leftInset
        surface.showsScroller = true
        let font = fontOverride.map {
            TerminalAppearanceFontCatalog.resolvedFont(
                name: $0, size: p.fontSize)
        } ?? p.resolvedFont()
        surface.font = font
        // Font and line-height changes alter the deliberate one-row drop.
        inlinePanelBottomConstraint?.constant = resolvedInlinePanelBottomOffset()
        extensionControlBarBottomConstraint?.constant = resolvedInlinePanelBottomOffset()
        inlinePanel?.themeOverride = theme
        inlinePanel?.refreshMetrics()
        extensionControlBar?.themeOverride = theme
        extensionControlBar?.refreshMetrics()
        extensionSurfaceView?.themeOverride = theme
        reserveVisibleInlinePanelHeight()
        reserveVisibleControlBarHeight()
        surface.textRenderingModeName = p.textRenderingMode
        surface.installColors(theme.ansi)
        surface.nativeForegroundColor = theme.ns(theme.foreground)
        surface.nativeBackgroundColor = theme.ns(theme.background)
        surface.caretColor = theme.ns(theme.foreground)
        surface.caretTextColor = theme.ns(theme.background)   // char under a block cursor
        surface.selectedTextBackgroundColor = theme.ns(theme.foreground).withAlphaComponent(0.30)
        let backgroundBrightness = theme.ns(theme.background)
            .usingColorSpace(.deviceGray)?.whiteComponent ?? 0
        scrollIndicator.knobStyle = backgroundBrightness < 0.5
            ? .light : .dark
        surface.failedBlockForegroundColor = NSColor.systemRed
        surface.failedBlockBackgroundColor = NSColor.systemRed.withAlphaComponent(0.16)
        surface.engine.setCursorStyle(p.cursorStyle)
        refreshScrollIndicator()
        surface.optionAsMetaKey = p.optionAsMeta

        // GPU-only: Metal is cmdy's identity, not a preference.
        do { try surface.setUseMetal(true) }
        catch { NSLog("cmdy: Metal renderer unavailable: \(error)") }
        // User shaders compile at runtime; errors surface as a notification
        // so the edit-save-look loop works without a console.
        if shaderMode == -1, let src = UserShaders.source(named: shaderName) {
            if let error = surface.setUserShader(src) {
                NSLog("cmdy: user shader failed: %@", error)
                Notifier.post(title: "shader error",
                              body: String(error.split(separator: "\n").first ?? "compile failed"))
            }
        } else {
            surface.setUserShader(nil)
        }
        surface.shaderMode = shaderMode
        surface.smoothCursor = p.smoothCursor
        surface.cursorGlideSpeed = p.cursorGlideSpeed
        surface.cursorGlideMaxDistance = p.cursorGlideMaxDistance
        surface.smoothScroll = p.smoothScroll

        blockOverlay.ghostFont = font   // cell-aligned with the grid
        blockOverlay.ghostColor = theme.ns(theme.foreground).withAlphaComponent(0.38)
        blockOverlay.separatorColor = theme.ns(theme.foreground).withAlphaComponent(0.08)
        updateBlockStyles()

        surface.view.needsDisplay = true
    }

    // MARK: - Blocks

    private func handleOSC133(_ payload: String) {
        guard let (kind, exit) = BlockStore.parse(payload) else { return }
        checkForClear()   // catches `clear` instantly (its D marker fires right after the wipe)
        let row = surface.engine.scrollInvariantCursorRow
        switch kind {
        case "A": blockStore.promptStarted(row: row)
        case "C":
            hasUserActivity = true
            promptDraft = ""
            promptDraftIsReliable = false
            if commandAssistanceID != nil { dismissCommandAssistance(refocus: false) }
            // At preexec the cursor has moved to the output line, so the typed
            // command sits on rows [promptRow ... row-1]. Read + join them.
            let pRow = blockStore.promptRows.last ?? row
            let endLine = max(pRow, row - 1)
            let cmdText = (pRow...endLine)
                .compactMap { $0 >= 0 ? surface.engine.scrollbackLineText(row: $0) : nil }
                .joined()
            let command = TerminalWindowController.stripPrompt(cmdText)
            blockStore.commandStarted(row: row, promptRow: pRow,
                                      command: command, cwd: currentCwd)
            if let block = blockStore.blocks.last { onCommandStarted?(self, block) }
        case "D":
            if blockStore.commandFinished(row: row, exitCode: exit) {
                if Preferences.shared.sounds, let e = exit, e != 0 { Retrobleeps.errorBuzz() }
                if let block = blockStore.lastCompletedBlock {
                    if exit == nil || exit == 0 {
                        HistoryStore.shared.record(block.commandText)
                    } else {
                        HistoryStore.shared.reject(block.commandText)
                    }
                    onCommandFinished?(self, block)
                }
            }
        case "B":
            // Prompt just ended: user input starts here (ghost-text anchor).
            inputStart = (row, surface.engine.cursorColumn)
            promptDraft = ""
            promptDraftIsReliable = true
        default: break
        }
        if kind == "C" { inputStart = nil }
    }

    /// Current prompt input for the command decision boundary. This reads the
    /// semantic OSC 133 input range; alternate-screen applications and running
    /// commands never enter the hook path.
    private func currentInputText() -> String? {
        let semantic = semanticCurrentInputText()
        if promptDraftIsReliable {
            // An external integration can write directly to the PTY without
            // using the pane helper. Do not let an empty local draft hide a
            // non-empty canonical line in that case.
            if promptDraft.isEmpty, let semantic, !semantic.isEmpty { return semantic }
            return promptDraft
        }
        return semantic
    }

    private func semanticCurrentInputText() -> String? {
        let term = surface.engine
        guard !blockStore.isRunning, !term.isCurrentBufferAlternate,
              let start = inputStart else { return nil }
        let endRow = term.scrollInvariantCursorRow
        guard endRow >= start.row else { return nil }
        var text = ""
        for row in start.row...endRow {
            let lower = row == start.row ? min(start.col, term.cols) : 0
            let upper = row == endRow ? min(term.cursorColumn, term.cols) : term.cols
            guard lower <= upper else { continue }
            text += term.scrollbackLineText(row: row, columns: lower..<upper) ?? ""
            if row < endRow, !term.isBufferRowWrapped(row + 1) { text += "\n" }
        }
        return text
    }

    private func notePromptInsertion(_ text: String) {
        if !text.isEmpty { hasUserActivity = true }
        guard promptDraftIsReliable else { return }
        guard !text.contains("\n"), !text.contains("\r") else {
            promptDraftIsReliable = false
            return
        }
        promptDraft += text
    }

    func appendPromptInput(_ text: String) {
        notePromptInsertion(text)
        surface.send(txt: text)
    }

    func replacePromptInput(with text: String, submit: Bool = false) {
        if submit || !text.isEmpty { hasUserActivity = true }
        promptDraft = submit ? "" : text
        promptDraftIsReliable = !submit
        surface.send(txt: "\u{15}" + text + (submit ? "\r" : ""))
    }

    /// Replace an interactive agent TUI's input without making the staged
    /// natural-language text look like a shell command to Cmdy's command
    /// decision boundary.
    func stageAgentPromptInput(_ text: String) {
        if !text.isEmpty { hasUserActivity = true }
        promptDraft = ""
        promptDraftIsReliable = false
        surface.send(txt: "\u{15}" + text)
    }

    /// Keep a race-free draft for ordinary linear typing. Editing operations
    /// that can move or transform the line deliberately fall back to OSC 133
    /// plus the terminal model instead of guessing at shell behavior.
    private func trackPromptDraft(_ event: NSEvent) {
        guard inlinePanel == nil, promptDraftIsReliable else { return }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if event.keyCode == 51, flags.isEmpty {
            if !promptDraft.isEmpty { promptDraft.removeLast() }
            return
        }
        if flags.contains(.control),
           event.charactersIgnoringModifiers?.lowercased() == "u" {
            promptDraft = ""
            return
        }
        if ghostSuffix != nil,
           Self.isGhostAcceptanceKey(keyCode: event.keyCode,
                                     modifiers: event.modifierFlags) {
            return
        }
        if flags == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            // The surface's paste callback records the actual post-plugin text.
            return
        }
        if [48, 53, 115, 116, 117, 119, 121, 123, 124, 125, 126].contains(event.keyCode)
            || !flags.isEmpty {
            promptDraftIsReliable = false
            return
        }
        guard let chars = event.characters, !chars.isEmpty,
              !chars.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return }
        promptDraft += chars
    }

    /// A newly opened shell with only its prompt/banner is safe to discard.
    /// Commands, typed input, alternate-screen apps, images, or native terminal
    /// surfaces retain the existing close confirmation.
    var isDisposableEmptySession: Bool {
        guard !hasUserActivity,
              blockStore.blocks.isEmpty,
              !blockStore.isRunning,
              !surface.engine.isCurrentBufferAlternate,
              surface.engine.kittyImageCount == 0,
              inlinePanel == nil,
              extensionSurfaceView == nil,
              commandAssistanceID == nil
        else { return false }
        let input = currentInputText() ?? promptDraft
        return input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Ghost-text autocomplete

    private func setGhost(_ hint: GhostHint?) {
        ghostSuffix = hint?.text
        blockOverlay.ghost = hint
    }

    /// Recomputed every overlay tick: suggest the most recent history command
    /// extending what's typed so far (fish-style), drawn dimmed after the cursor.
    private func updateGhost() {
        let term = surface.engine
        guard Preferences.shared.ghostText,
              !blockStore.isRunning,                       // only at a prompt
              !term.isCurrentBufferAlternate,              // never inside vim & co
              let start = inputStart else { setGhost(nil); return }
        let row = term.scrollInvariantCursorRow
        let col = term.cursorColumn
        // Single-line input on the prompt row, cursor after the prompt.
        guard row == start.row, col > start.col,
              let line = term.scrollbackLineText(row: row) else { setGhost(nil); return }
        // Cursor must be at the end of the input (the line is right-trimmed,
        // so a cursor past line-end also counts as EOL).
        guard col >= line.count else { setGhost(nil); return }
        let typed = String(line.dropFirst(min(start.col, line.count)))
        guard typed.count >= 2, !typed.isEmpty,
              let match = HistoryStore.shared.suggestion(for: typed, cwd: currentCwd)
        else { setGhost(nil); return }
        let screenRow = row - term.currentTopRow
        guard screenRow >= 0, screenRow < term.rows else { setGhost(nil); return }
        setGhost(GhostHint(text: String(match.dropFirst(typed.count)),
                           screenRow: screenRow, col: col))
    }

    /// Recent commands (newest first) for the Blocks menu / palette.
    func recentCommands(limit: Int = 15) -> [(label: String, promptRow: Int, command: String)] {
        blockStore.blocks.suffix(min(max(limit, 0), 1_000)).reversed().map { b in
            let status = b.running ? "…" : (b.exitCode == 0 ? "✓" : "✗")
            let cmd = b.commandText.isEmpty ? "(command)" : b.commandText
            let dur = b.durationText.map { "  ·  \($0)" } ?? ""
            return ("\(status)  \(cmd)\(dur)", b.promptRow, b.commandText)
        }
    }

    func jumpToRow(_ row: Int) { surface.scrollTo(row: row) }

    /// The last `maxLines` of scrollback as plain text (for session persistence).
    func recentScrollbackText(maxLines: Int = 300) -> String {
        let term = surface.engine
        let end = term.scrollInvariantCursorRow
        let start = max(0, end - maxLines)
        guard end > start else { return "" }
        var lines = term.scrollbackLineTexts(rows: start...end)
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    /// What session-restore saves: only THIS session's real content. Without
    /// this, every restart re-saved the previous restore's dim banner +
    /// divider and the layers snowballed (dim banner stacks, double rules).
    func scrollbackForSession() -> String {
        Self.sanitizeForSave(recentScrollbackText())
    }

    static func sanitizeForSave(_ raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        // Keep only what came after the LAST restore divider — everything
        // above it is a stale earlier layer.
        if let divider = lines.lastIndex(where: { $0.contains("── restored session ──") }) {
            lines.removeSubrange(...divider)
        }
        // Drop the boot banner block (our own fixed format: header → Ready!).
        // Matches the old name too so pre-rename sessions clean up.
        let bannerNames = [ProductIdentity.current.displayName]
            + ProductIdentity.current.legacyNames
        if let start = lines.firstIndex(where: { line in
            bannerNames.contains(where: { line.contains("\($0) v1") })
        }),
           let end = lines[start...].firstIndex(where: { $0.contains("Ready!") }) {
            lines.removeSubrange(start...end)
        }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Plain text of a block's current output. Running blocks end at the live
    /// screen tail so the Inspector can recognize a dev-server URL before the
    /// process exits.
    func outputText(for block: Block) -> String {
        let end = block.endRow ?? (surface.engine.liveScreenTopRow + surface.engine.rows)
        guard end > block.commandRow else { return "" }
        var lines = (block.commandRow..<end).map { surface.engine.scrollbackLineText(row: $0) ?? "" }
        while let last = lines.last, last.isEmpty { lines.removeLast() }   // trim trailing blanks
        return lines.joined(separator: "\n")
    }

    /// Copy the output of the most recently finished command to the clipboard.
    func copyLastCommandOutput() {
        guard let block = blockStore.lastCompletedBlock else { NSSound.beep(); return }
        let text = outputText(for: block)
        guard !text.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Block navigation

    func jumpToPreviousPrompt() {
        let top = surface.engine.currentTopRow
        if let target = blockStore.promptRows.filter({ $0 < top }).max() {
            surface.scrollTo(row: target)
        }
    }

    func jumpToNextPrompt() {
        let top = surface.engine.currentTopRow
        if let target = blockStore.promptRows.filter({ $0 > top }).min() {
            surface.scrollTo(row: target)
        } else {
            surface.scrollTo(row: surface.engine.liveScreenTopRow)   // back to live/bottom
        }
    }

    func clearBuffer() {
        dismissCommandAssistance(refocus: false)
        // Feed through the SURFACE (not engine.feed) so the repaint is
        // scheduled — the engine's own feed() mutates the buffer without redrawing.
        surface.feed(text: "\u{1b}[3J\u{1b}[H\u{1b}[2J")
        blockStore.reset()   // block rows are now invalid
        lastLiveTop = surface.engine.liveScreenTopRow
        blockOverlay.display()          // redraw overlay immediately, no poll wait
    }

    /// Forget stale blocks when the scrollback shrinks (screen/scrollback clear).
    private func checkForClear() {
        let liveTop = surface.engine.liveScreenTopRow
        if liveTop < lastLiveTop {
            dismissCommandAssistance(refocus: false)
            blockStore.reset()
            blockOverlay.display()          // overlay: instant
        }
        lastLiveTop = liveTop
    }

    private var lastDroppedLines = 0

    /// Poll for scroll changes (redraw overlay) + backstop clear detection.
    /// Attention is only *worth signalling* when the user isn't already
    /// looking at this pane — otherwise the bell was the message.
    private func requestAttention(text: String) {
        guard Preferences.shared.attentionSignals else { return }
        let looking = NSApp.isActive && window?.isKeyWindow == true && isFocused
        guard !looking else { return }
        let wasWanting = wantsAttention
        wantsAttention = true
        attentionText = text
        if !wasWanting {
            onAttention?(self, text)
            onStateChanged?(self)
        }
    }

    private func refreshOverlayState() {
        // Focus dissolves attention on the next viewport/focus event.
        if wantsAttention, NSApp.isActive, window?.isKeyWindow == true, isFocused {
            wantsAttention = false
            attentionText = ""
            onStateChanged?(self)
        }
        guard window?.occlusionState.contains(.visible) ?? false else { return }
        checkForClear()
        // Scrollback trimming shifts every absolute row — rebase the blocks.
        let term = surface.engine
        let dropped = term.scrollbackDroppedLines
        if dropped > lastDroppedLines {
            let delta = dropped - lastDroppedLines
            blockStore.rebase(droppedLines: delta)
            if var assistance = blockOverlay.commandAssistance {
                assistance.anchorRow -= delta
                if assistance.anchorRow < 0 {
                    dismissCommandAssistance(refocus: false)
                } else {
                    blockOverlay.commandAssistance = assistance
                }
            }
            lastLiveTop = term.liveScreenTopRow
            lastDroppedLines = dropped
        }
        updateGhost()
        updateBlockStyles()
        blockOverlay.refreshIfNeeded()
    }

    /// Failed prompts are styled in the row geometry itself. No separate dot,
    /// hit target, or permanent gutter is created.
    private func updateBlockStyles() {
        let failed = Set(blockStore.blocks.compactMap { block -> Int? in
            !block.running && block.exitCode != 0 ? block.promptRow : nil
        })
        if surface.failedBlockRows != failed { surface.failedBlockRows = failed }
    }

}

extension Block {
    /// "1.3s" / "2m 14s" — nil while running or for sub-100ms commands.
    var durationText: String? {
        guard let end = finishedAt else { return nil }
        let s = end.timeIntervalSince(startedAt)
        if s < 0.1 { return nil }
        if s < 60 { return String(format: "%.1fs", s) }
        return "\(Int(s) / 60)m \(Int(s) % 60)s"
    }
    var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }
}
