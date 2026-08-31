import AppKit

/// Lightweight tooltip that pops up under a status-item button after a short
/// delay (default 200ms vs macOS's ~1.5s). NSStatusItem's built-in `toolTip`
/// is too sluggish for transient affordances like the contextual bind icon —
/// users move on before the system tooltip resolves.
///
/// Usage: build once with the target button, call `setText(...)` whenever the
/// label should change. Tracking area detects mouse enter/exit; a small NSPanel
/// renders the text. Click on the button cancels the tooltip immediately.
@MainActor
final class FastTooltip {
    private weak var button: NSStatusBarButton?
    private var panel: NSPanel?
    private var label: NSTextField?
    private var trackingArea: NSTrackingArea?
    private var trackingProxy: AnyObject?   // strong ref — tracking area holds owner weakly
    private var showWorkItem: DispatchWorkItem?
    private var text: String = ""
    private let delay: TimeInterval

    init(button: NSStatusBarButton, delay: TimeInterval = 0.2) {
        self.button = button
        self.delay = delay
        installTrackingArea()
    }

    func setText(_ s: String) {
        text = s
        if let label = label, panel?.isVisible == true {
            label.stringValue = s
            sizeToFit()
        }
    }

    /// Force-hide (e.g. when the bind status item becomes invisible).
    func dismiss() {
        showWorkItem?.cancel()
        showWorkItem = nil
        panel?.orderOut(nil)
    }

    // MARK: - Tracking

    private func installTrackingArea() {
        guard let button = button else { return }
        let proxy = TooltipProxy(controller: self)
        trackingProxy = proxy
        let area = NSTrackingArea(
            rect: button.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: proxy,
            userInfo: nil
        )
        button.addTrackingArea(area)
        trackingArea = area
    }

    fileprivate func mouseEntered() {
        showWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.show() }
        }
        showWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    fileprivate func mouseExited() {
        showWorkItem?.cancel()
        showWorkItem = nil
        panel?.orderOut(nil)
    }

    // MARK: - Panel

    private func show() {
        guard !text.isEmpty else { return }
        if panel == nil { buildPanel() }
        label?.stringValue = text
        sizeToFit()
        positionUnderButton()
        panel?.orderFrontRegardless()
    }

    private func buildPanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 24),
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
        p.ignoresMouseEvents = true

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
        panel = p
        label = l
    }

    /// Resize the panel to fit the current label text, with horizontal padding.
    private func sizeToFit() {
        guard let label = label, let panel = panel else { return }
        let textSize = label.attributedStringValue.size()
        let w = max(60, ceil(textSize.width) + 16)
        let h: CGFloat = 24
        var f = panel.frame
        f.size = NSSize(width: w, height: h)
        panel.setFrame(f, display: false)
    }

    private func positionUnderButton() {
        guard let panel = panel,
              let button = button,
              let buttonWindow = button.window
        else { return }
        let buttonFrame = buttonWindow.frame
        let panelSize = panel.frame.size
        let x = buttonFrame.midX - panelSize.width / 2
        let y = buttonFrame.minY - panelSize.height - 4
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Tracking-area owners must be `NSObject` and respond to `mouseEntered:` /
/// `mouseExited:`. `FastTooltip` is `@MainActor` so we can't make it the
/// owner directly without scattered `assumeIsolated`s — proxy through this
/// tiny NSObject which holds a weak ref.
private final class TooltipProxy: NSResponder {
    weak var controller: FastTooltip?
    init(controller: FastTooltip) {
        self.controller = controller
        super.init()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseEntered(with event: NSEvent) {
        Task { @MainActor [weak self] in self?.controller?.mouseEntered() }
    }
    override func mouseExited(with event: NSEvent) {
        Task { @MainActor [weak self] in self?.controller?.mouseExited() }
    }
}
