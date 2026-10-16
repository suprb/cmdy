import AppKit
import ProductIdentity
import CmdyKit

/// A small card in the bottom-right corner of the key terminal window while a
/// newer release is available: plain type, one action, and a close button.
/// Closing it keeps it closed for that version; the menu item and the macOS
/// notification stay as they are.
@MainActor
final class UpdateBadgeController {
    static let shared = UpdateBadgeController()

    private var badge: UpdateBadgeView?
    private var observers: [NSObjectProtocol] = []
    /// Opens the reviewed update window (AppDelegate.checkForUpdates).
    var onOpen: (() -> Void)?

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.cmdyAppUpdateChanged, NSWindow.didBecomeKeyNotification,
                     .cmdyPreferencesChanged] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { UpdateBadgeController.shared.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        let monitor = AppUpdateMonitor.shared
        guard let release = monitor.availableUpdate,
              !monitor.isBadgeDismissed(for: release.version),
              let window = Self.hostWindow(),
              let content = window.contentView else {
            // A sheet or another app's window can be key; keep the badge where it is.
            if AppUpdateMonitor.shared.availableUpdate == nil { remove() }
            return
        }
        let view = badge ?? UpdateBadgeView()
        badge = view
        view.onAction = { [weak self, weak window] in
            if case .ready = AppUpdateMonitor.shared.downloadState {
                AppUpdateInstall.restartToUpdate(relativeTo: window)
            } else {
                self?.onOpen?()
            }
        }
        view.onClose = { [weak self] in
            AppUpdateMonitor.shared.dismissBadge(for: release.version)
            self?.remove()
        }
        view.update(release: release, state: monitor.downloadState,
                    current: monitor.currentVersion)
        // Match the terminal theme, not the system appearance.
        let ground = window.backgroundColor.usingColorSpace(.sRGB)
        let luminance = ground.map {
            0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent
        } ?? 0
        view.appearance = NSAppearance(named: luminance < 0.5 ? .darkAqua : .aqua)
        if view.superview !== content {
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
                view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            ])
            view.appear()
        } else {
            // Panes added later must not cover the card.
            content.addSubview(view, positioned: .above, relativeTo: nil)
        }
    }

    /// The key terminal window, or the frontmost one while cmdy is in the background.
    private static func hostWindow() -> NSWindow? {
        if let key = NSApp.keyWindow, key.windowController is TerminalWindowController { return key }
        if NSApp.keyWindow != nil { return nil }
        return NSApp.orderedWindows.first {
            $0.isVisible && $0.windowController is TerminalWindowController
        }
    }

    private func remove() {
        badge?.removeFromSuperview()
        badge = nil
    }
}

@MainActor
final class UpdateBadgeView: NSView {
    var onAction: (() -> Void)?
    var onClose: (() -> Void)?

    private let messageLabel = NSTextField(labelWithString: "")
    private let actionButton = PillButton()
    private let closeButton = NSButton()

    private static let cardColor = NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1) : .white
    }
    private static let borderColor = NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.08)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.16)
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            return shadow
        }()

        messageLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        messageLabel.textColor = .labelColor
        messageLabel.lineBreakMode = .byTruncatingTail

        actionButton.target = self
        actionButton.action = #selector(actionPressed)

        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.toolTip = "Hide until the next version"

        for view in [messageLabel, actionButton, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 40),
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.leadingAnchor.constraint(equalTo: messageLabel.trailingAnchor, constant: 12),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: actionButton.trailingAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Self.cardColor.cgColor
        layer?.borderColor = Self.borderColor.cgColor
    }

    // The card is a solid surface: clicks never fall through to the terminal.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) ?? (frame.contains(point) ? self : nil)
    }
    override func mouseDown(with event: NSEvent) {}

    func update(release: AppReleaseUpdate, state: AppUpdateDownloadState, current: String?) {
        let name = "\(ProductIdentity.current.displayName) \(release.version)"
        switch state {
        case .ready:
            let installing = AppUpdateInstall.isInstalling
            messageLabel.stringValue = installing ? "Installing \(name)…" : "\(name) is ready"
            actionButton.title = "Restart"
            actionButton.isEnabled = !installing
            actionButton.alphaValue = installing ? 0.5 : 1
        case .downloading:
            messageLabel.stringValue = "Downloading \(name)…"
            actionButton.title = "Details"
        case .failed:
            messageLabel.stringValue = "\(name) didn’t download"
            actionButton.title = "Retry"
        case .idle:
            messageLabel.stringValue = "\(name) is available"
            actionButton.title = release.canDownloadAutomatically ? "Update" : "View"
        }
    }

    func appear() {
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    @objc private func actionPressed() { onAction?() }
    @objc private func closePressed() { onClose?() }
}

/// A filled, fully rounded button: label-colored ground, inverted text.
@MainActor
final class PillButton: NSControl {
    private let label = NSTextField(labelWithString: "")

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue; invalidateIntrinsicContentSize() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(label.intrinsicContentSize.width) + 22, height: 24)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = NSColor.labelColor.cgColor
        label.textColor = .windowBackgroundColor
    }
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
    override func mouseDown(with event: NSEvent) { alphaValue = 0.8 }
    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            sendAction(action, to: target)
        }
    }
    override func accessibilityPerformPress() -> Bool { sendAction(action, to: target) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
